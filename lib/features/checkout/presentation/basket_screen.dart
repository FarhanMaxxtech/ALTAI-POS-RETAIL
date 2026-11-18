import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/keyboard.dart';
import '../../../shared/pos_layout.dart';
import '../../../shared/reader_session.dart';
import '../../../shared/reader_widgets.dart';
import '../../../shared/rfid_reader.dart';
import '../../catalog/data/catalog_api.dart';
import '../../orders/data/orders_api.dart';
import '../../orders/domain/order.dart';
import '../../returns/data/returns_api.dart';
import '../../returns/domain/exchange.dart';
import '../../returns/presentation/return_screen.dart';
import '../data/checkout_api.dart';
import '../data/store_tags.dart';
import '../domain/basket.dart';
import '../domain/basket_controller.dart';
import '../domain/checkout_summary.dart';

/// The tablet's main screen: read the items, check them, record the sale (Figma "New 03–06, 11").
///
/// Items come in straight from the USB RFID reader: it reads the whole time the screen is open, and
/// each tag lands as a card as it's read. The cashier never taps Scan or Stop; the screen pauses
/// the reader on its own (the confirm box, Exchange) and reads again after.
///
/// Left: the cards, one per colour/size, with All / Ready / Needs attention. Right: the order panel
/// with the StoreHub receipt, the lines, the total, Clear and Confirm.
class BasketScreen extends StatefulWidget {
  const BasketScreen({
    super.key,
    required this.api,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    this.onBack,
    this.initialTags = const [],
    this.catalog,
    this.returns,
    this.orders,
    this.askReceiptOnScan = false,
    this.tagReader = const UsbTagReader(),
    this.storeTags,
    this.onSold,
    this.initialExchange,
  });

  final CheckoutApi api;
  final String storeId;
  final String storeName;
  final String staffName;

  /// Android's back button: back to the start page. Null = this is the first screen.
  final VoidCallback? onBack;

  /// Tags already read elsewhere: in the basket from the start.
  final List<String> initialTags;

  /// Pictures and the team's prices. Null = no pictures.
  final CatalogApi? catalog;

  /// Customer returns. Null = no Exchange button.
  final ReturnsApi? returns;

  /// Paid StoreHub orders. Non-null = the receipt can be found from its last 4 digits.
  final OrdersApi? orders;

  /// Asks for the receipt as soon as the first items are read, so the cashier types it while the
  /// tags are checked in the background (the wait is hidden behind something useful).
  final bool askReceiptOnScan;

  /// The USB RFID reader this screen drives.
  final TagReader tagReader;

  /// The store's tags kept on the tablet, so scanned pieces show their names at once. Null = none.
  final StoreTags? storeTags;

  /// A sale was recorded, with this many pieces (for the start page's "Pieces sold").
  final void Function(int pieces)? onSold;

  /// Exchange started from the order history: the items are already back, now the new ones.
  final ExchangeReturn? initialExchange;

  @override
  State<BasketScreen> createState() => _BasketScreenState();
}

/// Ready pieces of one SKU (one colour and size of a product): one card.
class _Variant {
  _Variant(this.sku, this.first);

  final String sku;
  final BasketItem first; // gives the variation, picture and price
  final List<String> epcs = [];

  int get qty => epcs.length;
}

/// Ready pieces of one product, with its variants.
class _Line {
  _Line(this.key, this.first);

  final String key; // product code, else name, else SKU
  final BasketItem first; // gives the name and picture
  final Map<String, _Variant> variants = {}; // sku → variant, newest first

  int get qty => variants.values.fold(0, (sum, v) => sum + v.qty);
}

/// Which cards show.
enum _Filter { all, ready, attention }

class _BasketScreenState extends State<BasketScreen> {
  late final BasketController _basket = BasketController(
    api: widget.api,
    storeId: widget.storeId,
    staffName: widget.staffName,
    catalog: widget.catalog,
    known: widget.storeTags,
  );
  final _receipt = TextEditingController();
  final _beeper = Beeper();
  late final ReaderSession _reader = ReaderSession(reader: widget.tagReader, onTags: _basket.readRound);

  int _lastCount = 0; // how many items were in the basket last time
  bool _reading = false; // "Reading…" for a moment after each tag
  bool _askedReceipt = false; // the receipt pop-up shows once per basket
  bool _pausedNow = false; // another screen or the confirm box is open: the reader waits
  BasketPhase _lastPhase = BasketPhase.scanning;
  Timer? _readingTimer;
  _Filter _filter = _Filter.all;
  String _query = '';
  String? _found; // "Today's sale found", after Find

  bool get _showPrices => widget.catalog != null;

  @override
  void initState() {
    super.initState();
    _basket.findByEnding = widget.orders != null; // today's StoreHub sales can be searched
    _basket.addListener(_onBasketChanged);
    _reader.addListener(_onReaderChanged);
    if (widget.initialExchange case final e?) _basket.startExchange(e);
    if (widget.initialTags.isNotEmpty) _basket.addText(widget.initialTags.join(' '));
    _reader.start();
  }

  void _onReaderChanged() {
    if (mounted) setState(() {});
  }

  /// Opens another screen with the reader paused (so its tags don't land in this basket), and reads
  /// again on the way back.
  Future<T?> _paused<T>(Future<T?> Function() open) async {
    _pausedNow = true;
    _reader.stop();
    final result = await open();
    _pausedNow = false;
    if (mounted && _basket.phase == BasketPhase.scanning) _reader.start();
    return result;
  }

  /// Before leaving the checkout: scanned items not yet sold are cleared, so ask first.
  Future<bool> _mayLeave() async {
    if (_basket.phase == BasketPhase.sending) return false; // recording the sale: wait for it
    if (_basket.phase != BasketPhase.scanning || _basket.items.isEmpty) return true;
    final c = context.altai;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Leave this checkout?', style: AltaiType.heading.copyWith(color: c.ink)),
        content: Text(
          'The ${plural(_basket.items.length, 'scanned item')} will be cleared. Nothing has been sold.',
          style: AltaiType.body.copyWith(color: c.inkMuted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    return leave == true && mounted;
  }

  /// Android's back button.
  Future<void> _leave() async {
    final back = widget.onBack;
    if (back != null && await _mayLeave()) back();
  }

  @override
  void dispose() {
    _readingTimer?.cancel();
    _reader.removeListener(_onReaderChanged);
    _reader.dispose();
    _basket.removeListener(_onBasketChanged);
    _basket.dispose();
    _receipt.dispose();
    _beeper.dispose();
    super.dispose();
  }

  /// Ready items grouped by product, then by SKU. Newest first.
  List<_Line> _lines() {
    final byProduct = <String, _Line>{};
    for (final i in _basket.items.reversed) {
      if (i.state != ItemState.ok) continue;
      final sku = i.sku ?? i.epc;
      final line = byProduct[i.productCode ?? i.productName ?? sku] ??= _Line(i.productCode ?? i.productName ?? sku, i);
      (line.variants[sku] ??= _Variant(sku, i)).epcs.add(i.epc);
    }
    return byProduct.values.toList();
  }

  /// Price of [qty] pieces of a variant, in cents. Null = no price.
  int? _cents(_Variant v, [int? qty]) {
    final unit = toCents(_basket.priceOf(v.first));
    return unit == null ? null : unit * (qty ?? v.qty);
  }

  void _onBasketChanged() {
    final count = _basket.items.length;
    if (_lastCount == 0 && count > 0) _maybeAskReceipt(); // reading goes on behind the pop-up
    final phase = _basket.phase;
    // Back to scanning (a new basket, or the sale didn't go through): read again.
    if (phase != _lastPhase && phase == BasketPhase.scanning && !_pausedNow) _reader.start();
    if (phase != _lastPhase && phase == BasketPhase.done) widget.onSold?.call(_basket.okCount);
    _lastPhase = phase;
    // One beep each time a new tag lands in the basket.
    if (count > _lastCount) {
      HapticFeedback.lightImpact();
      _beeper.ok();
      _readingTimer?.cancel();
      setState(() => _reading = true);
      _readingTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => _reading = false);
      });
    }
    _lastCount = count;
  }

  void _maybeAskReceipt() {
    if (!widget.askReceiptOnScan || _askedReceipt) return;
    if (_basket.hasReceipt || _basket.exchange != null || _basket.phase != BasketPhase.scanning) return;
    _askedReceipt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _askReceipt();
    });
  }

  void _setReceipt(String value) {
    _found = null;
    _basket.setReceipt(value);
  }

  /// The receipt pop-up (also the top bar's Find receipt).
  Future<void> _askReceipt() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ReceiptPrompt(basket: _basket, initial: _receipt.text),
    );
    if (!mounted) return;
    if (result == _noReceipt) {
      await _pickNoReceipt();
      return;
    }
    if (result != null) {
      _receipt.text = result;
      _setReceipt(result);
      if (_basket.receiptEnding != null) _findByEnding();
    }
  }

  /// The cashier typed the last 4 digits: find today's StoreHub sale that ends with them, among
  /// the sales still waiting for their items (from the Altai server, which reads StoreHub).
  Future<void> _findByEnding() async {
    final end = _basket.receiptEnding;
    final orders = widget.orders;
    if (end == null || orders == null) return;
    final messenger = ScaffoldMessenger.of(context);
    List<StoreHubOrder> today;
    try {
      today = await orders.pending(widget.storeId);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Could not load today's StoreHub sales. Type all 16 digits.")),
      );
      return;
    }
    if (!mounted) return;
    final now = DateTime.now();
    final matches = [
      for (final o in today)
        if (CheckoutApi.cleanReceipt(o.invoiceNumber).endsWith(end) &&
            o.paidAt.year == now.year &&
            o.paidAt.month == now.month &&
            o.paidAt.day == now.day)
          o,
    ]..sort((a, b) => b.paidAt.compareTo(a.paidAt)); // newest first: usually the customer here
    StoreHubOrder? pick;
    if (matches.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text('No StoreHub sale today ending in $end. Check the iPad, or type all 16 digits.')),
      );
      return;
    } else if (matches.length == 1) {
      pick = matches.single;
    } else {
      pick = await _chooseSale(matches, end);
    }
    if (pick == null || !mounted) return;
    final no = CheckoutApi.cleanReceipt(pick.invoiceNumber);
    _receipt.text = no;
    _setReceipt(no);
    setState(() => _found = "Today's sale found");
  }

  /// Several of today's sales end in the same 4 digits: the cashier picks one.
  Future<StoreHubOrder?> _chooseSale(List<StoreHubOrder> matches, String end) {
    final c = context.altai;
    String two(int v) => v.toString().padLeft(2, '0');
    return showDialog<StoreHubOrder>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Sales today ending in $end', style: AltaiType.heading.copyWith(color: c.ink)),
        children: [
          for (final o in matches)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(o),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: D.space2),
                child: Text(
                  '${CheckoutApi.cleanReceipt(o.invoiceNumber)} · paid ${two(o.paidAt.hour)}:${two(o.paidAt.minute)} · '
                  '${plural(o.totalQty, 'pc')}',
                  style: AltaiType.body.copyWith(color: c.ink),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickNoReceipt() async {
    final c = context.altai;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('No StoreHub receipt: why?', style: AltaiType.heading.copyWith(color: c.ink)),
        children: [
          for (final r in noReceiptReasons)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: D.space2),
                child: Text(r, style: AltaiType.body.copyWith(color: c.ink)),
              ),
            ),
        ],
      ),
    );
    if (reason != null) {
      _receipt.clear();
      _found = null;
      _basket.setNoReceipt(reason);
    }
  }

  /// Clear, and Next customer: a new empty basket, reading again.
  void _newBasket() {
    _basket.reset();
    _receipt.clear();
    _found = null;
    _askedReceipt = false;
    _lastCount = 0;
    _filter = _Filter.all;
    _reader.start();
  }

  /// Exchange, step 1: the items coming back (the return screen). Step 2 is this basket, for the new items.
  Future<void> _openExchange(ReturnsApi returns) async {
    if (_basket.items.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clear or complete this basket before starting an exchange.')));
      return;
    }
    final returned = await _paused(
      () => Navigator.of(context).push<ExchangeReturn>(
        shellRoute(
          context,
          ReturnScreen(
            tagReader: widget.tagReader,
            inspector: widget.api,
            api: returns,
            storeId: widget.storeId,
            storeName: widget.storeName,
            staffName: widget.staffName,
            catalog: widget.catalog,
            exchange: true,
            orders: widget.orders,
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (returned != null) {
      _basket.startExchange(returned);
      _reader.start(); // step 2: the new items
    }
  }

  /// The money that changes hands in an exchange, or null when this basket isn't one.
  String? get _exchangeDifference {
    final e = _basket.exchange;
    if (e == null || !_showPrices) return null;
    return exchangeDifferenceText(_basket.totalCents, e.refundCents, formatRm);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: ListenableBuilder(
        listenable: _basket,
        builder: (context, _) => AppShell(
          section: Section.checkout,
          searchHint: 'Search scanned items…',
          onSearch: (q) => setState(() => _query = q.trim().toLowerCase()),
          onRefresh: _basket.phase == BasketPhase.scanning ? _basket.recheck : null,
          refreshTooltip: 'Check again',
          offline: _basket.offline,
          action: ShellAction(
            'Find receipt',
            Icons.receipt_long_outlined,
            _basket.phase == BasketPhase.scanning ? _askReceipt : null,
          ),
          beforeLeave: _mayLeave,
          body: switch (_basket.phase) {
            BasketPhase.scanning => _scanning(context),
            BasketPhase.sending => _sending(context),
            BasketPhase.done => _done(context),
            BasketPhase.uncertain => _Outcome(
              icon: Icons.help_outline_rounded,
              title: 'Check before scanning again',
              body: '${_basket.message}',
              action: 'Start a new basket',
              onAction: _newBasket,
            ),
            BasketPhase.retry => _Outcome(
              icon: Icons.wifi_off_rounded,
              title: 'No confirmation yet',
              body: '${_basket.message} It is safe to try again: this basket can only be recorded once.',
              action: 'Try again',
              onAction: _basket.complete,
            ),
          },
        ),
      ),
    );
  }

  /* ---------------- Scanning ---------------- */

  bool _matches(BasketItem i) {
    if (_query.isEmpty) return true;
    return [i.productName, i.variation, i.sku, i.problem].any((t) => t != null && t.toLowerCase().contains(_query));
  }

  Widget _scanning(BuildContext context) {
    final c = context.altai;
    final lines = _lines();
    final problems = _basket.items.reversed.where((i) => i.state == ItemState.problem).toList();
    final checking = _basket.items.reversed.where((i) => i.state == ItemState.checking).toList();
    final variants = [
      for (final l in lines)
        for (final v in l.variants.values) (l, v),
    ];
    final readyCards = variants.length;
    final all = readyCards + problems.length + checking.length;

    final cards = <Widget>[
      if (_filter != _Filter.ready)
        for (final p in problems.where(_matches))
          ItemCard(
            key: ValueKey('problem-${p.epc}'),
            look: CardLook.problem,
            title: p.productName ?? 'Unknown item',
            subtitle: p.problem ?? 'Cannot be sold',
            goesAwayAt: _basket.goesAwayAt(p.epc),
            onTap: () => _problemDetails(p),
          ),
      if (_filter == _Filter.all) ...[
        for (final i in checking.where(_matches).take(_maxPlaceholders))
          ItemCard(
            key: ValueKey('checking-${i.epc}'),
            look: CardLook.checking,
            title: i.productName ?? 'Reading tag…',
            subtitle: i.variation ?? _shortEpc(i.epc),
          ),
      ],
      if (_filter != _Filter.attention)
        for (final (l, v) in variants)
          if (_matches(v.first))
            ItemCard(
              key: ValueKey('card-${v.sku}'),
              title: l.first.productName ?? v.sku,
              subtitle: v.first.variation ?? 'SKU ${v.sku}',
              bottom: _priceText(v),
              qty: v.qty,
              image: _basket.imageOf(v.first),
              onTap: () => _variantDetails(l, v),
            ),
    ];

    final middle = Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBar(
            chips: [
              FilterChoice(
                'All  $all',
                selected: _filter == _Filter.all,
                onTap: () => setState(() => _filter = _Filter.all),
              ),
              FilterChoice(
                'Ready  $readyCards',
                selected: _filter == _Filter.ready,
                onTap: () => setState(() => _filter = _Filter.ready),
              ),
              FilterChoice(
                'Needs attention  ${problems.length}',
                selected: _filter == _Filter.attention,
                onTap: () => setState(() => _filter = _Filter.attention),
              ),
            ],
            trailing: BarNote(
              _reader.reading ? (_reading ? 'Reading…' : 'Reader on') : 'Reader off',
              dot: _reader.reading ? c.brand : c.inkMuted,
            ),
          ),
          if (_basket.exchange case final e?) ...[const SizedBox(height: 12), _exchangeBanner(context, e)],
          if (_reader.error != null) ...[const SizedBox(height: 12), ReaderProblem(session: _reader)],
          if (_basket.offline) ...[const SizedBox(height: 12), const PageNotice(offlineText)],
          if (_basket.message != null) ...[
            const SizedBox(height: 12),
            PageNotice(_basket.message!, icon: Icons.warning_amber_rounded, danger: true),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: all == 0
                ? const _EmptyState()
                : cards.isEmpty
                ? Center(
                    child: Text('Nothing here', style: AltaiType.body.copyWith(color: c.inkMuted)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ItemGrid(padding: const EdgeInsets.only(bottom: 24), children: cards),
                      ),
                      if (_filter == _Filter.all && checking.length > _maxPlaceholders)
                        Padding(
                          padding: const EdgeInsets.only(bottom: D.space2),
                          child: Text(
                            '+ ${checking.length - _maxPlaceholders} more being checked',
                            style: AltaiType.caption.copyWith(color: c.inkMuted),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: middle),
              SidePanel(child: _panel(context, lines, problems.length, checking.length)),
            ],
          );
        }
        // Narrow screen (portrait): the order panel goes under the cards; a short screen scrolls.
        const panelHeight = 420.0;
        final middleHeight = (box.maxHeight - panelHeight).clamp(320.0, double.infinity);
        final panel = Container(
          height: panelHeight,
          decoration: BoxDecoration(
            color: c.surfaceRaised,
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: _panel(context, lines, problems.length, checking.length),
        );
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: middleHeight, child: middle),
              panel,
            ],
          ),
        );
      },
    );
  }

  String? _priceText(_Variant v) {
    if (!_showPrices) return null;
    if (!_basket.priceLoaded(v.first)) return '…';
    final each = _cents(v, 1);
    return each == null ? 'No price' : 'RM ${formatRm(each)}';
  }

  /// A card's details: all its pieces, and Remove.
  Future<void> _variantDetails(_Line l, _Variant v) async {
    final c = context.altai;
    final each = _cents(v, 1);
    final total = _cents(v);
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.first.productName ?? v.sku, style: AltaiType.title.copyWith(color: c.ink)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (v.first.variation case final variation?) PanelRow('Colour / size', variation),
              PanelRow('SKU', v.sku),
              PanelRow('Pieces', '${v.qty}'),
              if (v.first.multiplier > 1) PanelRow('Bundle', '×${v.first.multiplier}'),
              if (_showPrices) ...[
                PanelRow('Price', each == null ? 'No price' : 'RM ${formatRm(each)} each'),
                if (total != null) PanelRow('Line total', 'RM ${formatRm(total)}'),
              ],
            ],
          ),
        ),
        actions: [
          AltaiButton('Remove', onPressed: () => Navigator.pop(context, true), variant: AltaiButtonVariant.danger),
          AltaiButton('Close', onPressed: () => Navigator.pop(context, false), variant: AltaiButtonVariant.primary),
        ],
      ),
    );
    if (remove == true) {
      for (final e in v.epcs) {
        _basket.remove(e);
      }
    }
  }

  /// A red card's details: why it can't be sold. It goes away by itself; Remove takes it now.
  Future<void> _problemDetails(BasketItem p) async {
    final c = context.altai;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(p.productName ?? 'Unknown item', style: AltaiType.title.copyWith(color: c.danger)),
        content: SizedBox(
          width: 420,
          child: Text(
            [p.problem ?? 'Cannot be sold', ?p.variation].join('\n'),
            style: AltaiType.body.copyWith(color: c.ink),
          ),
        ),
        actions: [
          AltaiButton('Check again', onPressed: () => Navigator.pop(context, false), icon: Icons.refresh_rounded),
          AltaiButton('Remove', onPressed: () => Navigator.pop(context, true), variant: AltaiButtonVariant.danger),
        ],
      ),
    );
    if (remove == true) {
      _basket.remove(p.epc);
    } else if (remove == false) {
      _basket.recheck();
    }
  }

  /// Exchange, step 2: what came back, and what to do now.
  Widget _exchangeBanner(BuildContext context, ExchangeReturn e) {
    final original = CheckoutApi.cleanReceipt(e.receiptNo);
    final noReceiptYet = CheckoutApi.cleanReceipt(_basket.receiptNo).isEmpty && _basket.noReceiptReason == null;
    return ExchangeSteps(
      step: 2,
      title: 'Exchange · 2 of 2: new items',
      note: '${plural(e.pieces, 'pc')} back in stock from receipt $original. '
          'Scan the new items, then enter the receipt of the new StoreHub sale.',
      action: noReceiptYet
          ? TextButton(
              onPressed: () {
                _receipt.text = original;
                _setReceipt(original);
              },
              style: _stripLink,
              child: const Text('Same receipt'),
            )
          : null,
    );
  }

  /* ---------------- The order panel ---------------- */

  Widget _panel(BuildContext context, List<_Line> lines, int problems, int checking) {
    final c = context.altai;
    final returns = _basket.exchange == null ? widget.returns : null; // no second exchange inside one
    final reason = _basket.noReceiptReason;
    final rows = [
      for (final l in lines)
        for (final v in l.variants.values) (l, v),
    ];
    final pieces = _basket.pieceCount;
    final piecesText = checking == 0
        ? '$pieces'
        : checking == pieces
        ? '$checking checking'
        : '$pieces · checking $checking';
    final hint = _basket.items.isEmpty
        ? 'Scan items to continue'
        : _basket.isChecking && !_basket.hasProblems
        ? (_basket.offline ? 'Items are checked once online' : 'Checking the items…')
        : _basket.missing;
    final unpriced = _basket.unpricedCount;

    Widget exchangeButton() =>
        TintButton('Exchange', tooltip: 'Exchange', onPressed: returns == null ? null : () => _openExchange(returns));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reason != null)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(color: c.warningTint, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, color: c.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No receipt: $reason',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
                  ),
                ),
                TextButton(
                  onPressed: () => _basket.setNoReceipt(null),
                  style: _stripLink,
                  child: const Text('Enter a receipt'),
                ),
              ],
            ),
          )
        else
          ReceiptField(
            controller: _receipt,
            label: 'StoreHub receipt no.',
            hint: widget.orders == null ? 'Scan or type the receipt no.' : 'Last 4 digits, or all 16',
            onChanged: _setReceipt,
            onSubmitted: (_) {
              if (_basket.receiptEnding != null) _findByEnding();
            },
            error: _basket.receiptCheck.error,
            warning: _basket.receiptCheck.warning,
            ok: _found,
            suffix: _basket.receiptEnding == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: D.space1),
                    child: TextButton(onPressed: _findByEnding, child: const Text('Find')),
                  ),
          ),
        const SizedBox(height: 12),
        if (reason == null && _receipt.text.isEmpty)
          Row(
            children: [
              Expanded(child: TintButton('No receipt', onPressed: _pickNoReceipt)),
              if (returns != null) ...[const SizedBox(width: 8), Expanded(child: exchangeButton())],
            ],
          ),
        const SizedBox(height: 12),
        Expanded(
          child: _basket.exchange != null
              ? _exchangeLines(context, _basket.exchange!, rows)
              : rows.isEmpty
              ? Center(
                  child: Text(
                    _basket.offline
                        ? 'Waiting for the internet…'
                        : checking > 0
                        ? 'Checking ${plural(checking, 'item')}…'
                        : 'Nothing scanned yet',
                    style: AltaiType.label.copyWith(color: c.inkMuted),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final (l, v) = rows[i];
                    final cents = _cents(v);
                    return PanelLine(
                      key: ValueKey('line-${v.sku}'),
                      qty: v.qty,
                      name: l.first.productName ?? v.sku,
                      detail: v.first.variation,
                      amount: !_showPrices ? null : (cents == null ? '–' : formatRm(cents)),
                      shaded: i.isEven,
                    );
                  },
                ),
        ),
        if (reason == null && _receipt.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            height: 44,
            padding: const EdgeInsets.only(left: 14),
            decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Receipt',
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.brandInk),
                  ),
                ),
                TextButton(onPressed: _pickNoReceipt, style: _stripLink, child: const Text('No receipt')),
                if (returns != null) ...[
                  Text('·', style: AltaiType.label.copyWith(color: c.brandInk)),
                  TextButton(onPressed: () => _openExchange(returns), style: _stripLink, child: const Text('Exchange')),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        PanelRow('Pieces', piecesText),
        if (problems > 0) PanelRow('Needs attention', '$problems', valueColor: c.danger),
        if (_basket.exchange case final e? when _showPrices) ...[
          PanelRow('New items', 'RM ${formatRm(_basket.totalCents)}'),
          PanelRow('Coming back', '- RM ${formatRm(e.refundCents)}'),
          _differenceTotal(_basket.totalCents - e.refundCents),
        ] else if (_showPrices || _basket.items.isEmpty)
          PanelTotal('Total', 'RM ${formatRm(_showPrices ? _basket.totalCents : 0)}'),
        if (unpriced > 0)
          Text(
            '${plural(unpriced, 'item')} without price',
            textAlign: TextAlign.end,
            style: AltaiType.caption.copyWith(color: c.warning),
          ),
        if (_exchangeDifference case final d?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              d,
              style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.brandInk),
            ),
          ),
        const SizedBox(height: 10),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              hint,
              textAlign: TextAlign.center,
              style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: c.inkMuted),
            ),
          ),
        PanelButtons(
          clear: 'Clear',
          onClear: _basket.items.isEmpty && _receipt.text.isEmpty ? null : _newBasket,
          confirm: _basket.isChecking ? 'Checking…' : 'Confirm',
          onConfirm: _basket.canComplete ? () => _confirm(lines) : null,
        ),
      ],
    );
  }

  /// "Customer pays RM 30.00", "Refund RM 20.00" or "Difference RM 0.00".
  Widget _differenceTotal(int diff) => PanelTotal(
    diff > 0 ? 'Customer pays' : (diff < 0 ? 'Refund' : 'Difference'),
    'RM ${formatRm(diff.abs())}',
  );

  /// Step 2 of an exchange: what came back (from step 1), then the new items.
  Widget _exchangeLines(BuildContext context, ExchangeReturn e, List<(_Line, _Variant)> rows) {
    final c = context.altai;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Text(text, style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: c.inkMuted)),
    );
    return ListView(
      children: [
        heading('Coming back'),
        for (final (i, item) in e.items.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: PanelLine(
              key: ValueKey('back-${item.sku ?? item.name}'),
              qty: item.pieces,
              name: item.name,
              detail: item.variation,
              amount: !_showPrices ? null : (item.cents == null ? '–' : '- ${formatRm(item.cents!)}'),
              shaded: i.isEven,
            ),
          ),
        if (e.items.isEmpty) PanelLine(qty: e.pieces, name: plural(e.pieces, 'piece'), shaded: true),
        heading('New items'),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Scan the new items',
              textAlign: TextAlign.center,
              style: AltaiType.label.copyWith(color: c.inkMuted),
            ),
          ),
        for (final (i, (l, v)) in rows.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: PanelLine(
              key: ValueKey('line-${v.sku}'),
              qty: v.qty,
              name: l.first.productName ?? v.sku,
              detail: v.first.variation,
              amount: !_showPrices ? null : (_cents(v) == null ? '–' : formatRm(_cents(v)!)),
              shaded: i.isEven,
            ),
          ),
      ],
    );
  }

  /// Last look before the sale is recorded (Figma "New 05"): Submit changes live stock and can't be undone.
  Future<void> _confirm(List<_Line> lines) async {
    // What's on screen is what gets sold: no new tags while the cashier checks it.
    _pausedNow = true;
    _reader.stop();
    // Was this receipt already used? A second sale on it is fine (more items), a repeat isn't.
    var earlier = const <CheckoutSummary>[];
    var couldNotCheck = false;
    try {
      earlier = await _basket.earlierOnReceipt();
    } on ApiException {
      couldNotCheck = true;
    }
    if (!mounted) return;
    final c = context.altai;
    final qty = lines.fold(0, (sum, l) => sum + l.qty);
    final receipt = CheckoutApi.cleanReceipt(_basket.receiptNo);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(D.space6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The header stays put; only the item list below scrolls. Back and Submit stay in view.
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Confirm checkout',
                          style: AltaiType.title.copyWith(fontSize: 28, fontWeight: FontWeight.w700, color: c.ink),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "This takes the items out of stock and can't be undone.",
                          style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted),
                        ),
                        const SizedBox(height: 20),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: StatusPill(
                            receipt.isNotEmpty ? 'Receipt $receipt' : 'No receipt: ${_basket.noReceiptReason}',
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                        if (earlier.isNotEmpty) ...[
                          const SizedBox(height: D.space3),
                          AltaiNotice(
                            'Receipt $receipt is already on ${_earlierText(earlier)}. '
                            'Submit only if these are more items for the same receipt.',
                            warning: true,
                          ),
                        ],
                        if (couldNotCheck) ...[
                          const SizedBox(height: D.space3),
                          const AltaiNotice('Could not check whether this receipt was used before.', warning: true),
                        ],
                        if (_basket.exchange case final e?) ...[
                          const SizedBox(height: D.space3),
                          AltaiNotice(
                            'Exchange: ${plural(e.pieces, 'pc')} already back in stock from receipt '
                            '${CheckoutApi.cleanReceipt(e.receiptNo)}.'
                            '${_exchangeDifference == null ? '' : ' ${_exchangeDifference!}.'}',
                          ),
                        ],
                        if (lines.any((l) => l.variants.values.any((v) => v.first.multiplier > 1))) ...[
                          const SizedBox(height: D.space3),
                          const AltaiNotice(
                            'This basket has a bundle tag. Altai records 1 pc for it and marks the whole tag as sold, '
                            'so the rest of the bundle can\'t be sold after. Check with the manager first.',
                            warning: true,
                          ),
                        ],
                        const SizedBox(height: 16),
                        Container(
                          height: 84,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(14)),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text('$qty', style: AltaiType.qtyTotal.copyWith(fontSize: 48, color: c.brandInk)),
                              const SizedBox(width: 10),
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  qty == 1 ? 'piece' : 'pieces',
                                  style: AltaiType.label.copyWith(fontSize: 16, color: c.brandInk),
                                ),
                              ),
                              const SizedBox(width: D.space4),
                              Expanded(
                                child: _showPrices
                                    ? FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          'RM ${formatRm(_basket.totalCents)}',
                                          style: AltaiType.title.copyWith(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w700,
                                            color: c.ink,
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    key: const ValueKey('confirm-items'),
                    shrinkWrap: true,
                    children: [
                      for (final l in lines)
                        for (final v in l.variants.values)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l.first.productName ?? v.sku,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AltaiType.label.copyWith(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: c.ink,
                                        ),
                                      ),
                                      Text(
                                        [
                                          ?v.first.variation,
                                          'SKU ${v.sku}',
                                          if (_cents(v, 1) case final each?) 'RM ${formatRm(each)} each',
                                          if (v.first.multiplier > 1) 'Bundle ×${v.first.multiplier}',
                                        ].join(' · '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: AltaiType.caption.copyWith(fontSize: 13, color: c.inkMuted),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: D.space3),
                                Text(
                                  '× ${v.qty}',
                                  style: AltaiType.label.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: c.brandInk,
                                  ),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AltaiButton('Back', onPressed: () => Navigator.of(context).pop(false), expand: true),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: AltaiButton(
                        'Submit',
                        onPressed: () => Navigator.of(context).pop(true),
                        variant: AltaiButtonVariant.primary,
                        icon: Icons.check_rounded,
                        expand: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _pausedNow = false;
    if (ok == true) {
      _basket.complete();
    } else if (mounted && _basket.phase == BasketPhase.scanning) {
      _reader.start(); // Back: keep reading
    }
  }

  /* ---------------- Other phases ---------------- */

  Widget _sending(BuildContext context) {
    final c = context.altai;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
          const SizedBox(height: D.space4),
          Text('Recording the sale…', style: AltaiType.heading.copyWith(color: c.ink)),
        ],
      ),
    );
  }

  /// The sale is recorded (Figma "New 06 Checkout - good to go").
  Widget _done(BuildContext context) {
    final c = context.altai;
    final dark = c.logoGreenBottom;
    final lines = _lines();
    final qty = lines.fold(0, (sum, l) => sum + l.qty);
    final variants = [
      for (final l in lines)
        for (final v in l.variants.values) (l, v),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle),
                  child: Icon(Icons.check_rounded, size: 38, color: c.onBrand),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Good to go',
                        style: AltaiType.title.copyWith(fontSize: 28, fontWeight: FontWeight.w700, color: dark),
                      ),
                      Text(
                        [
                          plural(qty, 'piece'),
                          'Transaction ${_basket.trxId}',
                          if (CheckoutApi.cleanReceipt(_basket.receiptNo) case final r when r.isNotEmpty) 'Receipt $r',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: dark),
                      ),
                      Text(
                        _exchangeDifference ?? 'Take payment on StoreHub as usual.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: dark),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(14)),
              // Many items: smaller rows, so 10+ stay in view without scrolling.
              child: LayoutBuilder(
                builder: (context, box) {
                  final compact = variants.length * 61 + 16 > box.maxHeight;
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: variants.length,
                    separatorBuilder: (_, _) => Divider(height: 1, indent: 76, endIndent: 24, color: c.border),
                    itemBuilder: (context, i) {
                      final (l, v) = variants[i];
                      final cents = _cents(v);
                      final each = _cents(v, 1);
                      return SizedBox(
                        key: ValueKey('done-${v.sku}'),
                        height: compact ? 36 : 60,
                        child: Row(
                          children: [
                            const SizedBox(width: 18),
                            CircleAvatar(
                              radius: compact ? 14 : 22,
                              backgroundColor: c.brandTint,
                              child: Icon(Icons.checkroom_rounded, size: compact ? 16 : 24, color: c.brandInk),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.first.productName ?? v.sku,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AltaiType.label.copyWith(
                                      fontSize: compact ? 14 : 16,
                                      height: compact ? 1.1 : null,
                                      fontWeight: FontWeight.w600,
                                      color: c.ink,
                                    ),
                                  ),
                                  Text(
                                    [
                                      ?v.first.variation,
                                      'SKU ${v.sku}',
                                      if (each != null) 'RM ${formatRm(each)} each',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AltaiType.caption.copyWith(
                                      fontSize: compact ? 11 : 13,
                                      height: compact ? 1.1 : null,
                                      color: c.inkMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '× ${v.qty}',
                              style: AltaiType.label.copyWith(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: c.brandInk,
                              ),
                            ),
                            if (_showPrices)
                              SizedBox(
                                width: 136,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    cents == null ? 'No price' : 'RM ${formatRm(cents)}',
                                    style: cents == null
                                        ? AltaiType.caption.copyWith(color: c.warning)
                                        : AltaiType.label.copyWith(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w600,
                                            color: c.ink,
                                          ),
                                  ),
                                ),
                              ),
                            const SizedBox(width: 24),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_showPrices) ...[
                Text('Total', style: AltaiType.heading.copyWith(color: c.inkMuted)),
                const SizedBox(width: 12),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'RM ${formatRm(_basket.totalCents)}',
                      style: AltaiType.title.copyWith(fontSize: 26, fontWeight: FontWeight.w700, color: c.ink),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 12),
              SizedBox(
                width: 280,
                child: AltaiButton(
                  'Next customer',
                  onPressed: _newBasket,
                  variant: AltaiButtonVariant.primary,
                  icon: Icons.person_add_alt_1_rounded,
                  expand: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "E2801160600002084D0A1" → "E280 1160 …0A1": enough to tell tags apart while they're checked.
String _shortEpc(String epc) {
  final e = epc.toUpperCase();
  if (e.length <= 11) return formatEpc(e);
  return '${e.substring(0, 4)} ${e.substring(4, 8)} …${e.substring(e.length - 3)}';
}

/// "transaction 501 at 14:02:11" or "2 checkouts, latest transaction 503 at 14:02:11".
String _earlierText(List<CheckoutSummary> earlier) {
  final latest = earlier.first;
  String two(int n) => n.toString().padLeft(2, '0');
  final t = latest.createdAt;
  final at = latest.hasTime ? ' at ${two(t.hour)}:${two(t.minute)}:${two(t.second)}' : '';
  final one = 'transaction ${latest.trxId}$at';
  return earlier.length == 1 ? one : '${earlier.length} checkouts, latest $one';
}

/* ---------------- Pieces of the scanning screen ---------------- */

/// The small links in the receipt strip ("No receipt · Exchange").
final _stripLink = TextButton.styleFrom(
  textStyle: AltaiType.label.copyWith(fontWeight: FontWeight.w600),
  padding: const EdgeInsets.symmetric(horizontal: 8),
  minimumSize: const Size(0, 40),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// What the receipt pop-up returns for "No receipt" (a receipt number can't look like this).
const _noReceipt = '<no receipt>';

/// At most this many grey "checking" cards; the rest are counted in one line.
const _maxPlaceholders = 12;

/// Asks for the StoreHub receipt while the tags are checked behind it, and shows how far the checks are.
class _ReceiptPrompt extends StatefulWidget {
  const _ReceiptPrompt({required this.basket, required this.initial});

  final BasketController basket;
  final String initial;

  @override
  State<_ReceiptPrompt> createState() => _ReceiptPromptState();
}

class _ReceiptPromptState extends State<_ReceiptPrompt> {
  late final _box = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _box.dispose();
    super.dispose();
  }

  void _submit(String v) {
    if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final basket = widget.basket;
    return AlertDialog(
      title: Text('StoreHub receipt no.', style: AltaiType.heading.copyWith(color: c.ink)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _box,
              autofocus: true,
              onTap: showKeyboard,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: AltaiType.body.copyWith(color: c.ink),
              decoration: const InputDecoration(
                hintText: 'Receipt no. from the iPad',
                prefixIcon: Icon(Icons.receipt_long_rounded),
              ),
              onSubmitted: _submit,
            ),
            const SizedBox(height: D.space3),
            // The checks keep going behind this box.
            ListenableBuilder(
              listenable: basket,
              builder: (context, _) {
                final checking = basket.checkingCount;
                return Row(
                  children: [
                    if (checking > 0)
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Icon(Icons.check_circle_rounded, size: 18, color: c.brandInk),
                    const SizedBox(width: D.space2),
                    Expanded(
                      child: Text(
                        checking > 0
                            ? '${plural(basket.pieceCount, 'pc')} read · checking $checking…'
                            : '${plural(basket.pieceCount, 'pc')} read and checked',
                        style: AltaiType.caption.copyWith(color: c.inkMuted),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(_noReceipt), child: const Text('No receipt')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Later')),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _box,
          builder: (context, v, _) =>
              TextButton(onPressed: v.text.trim().isEmpty ? null : () => _submit(v.text), child: const Text('OK')),
        ),
      ],
    );
  }
}

/// Nothing read yet (Figma "New 04 Checkout - empty").
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(14)),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 40),
                Container(
                  width: 128,
                  height: 128,
                  decoration: BoxDecoration(color: c.brandTint, shape: BoxShape.circle),
                  child: Icon(Icons.sensors_rounded, size: 60, color: c.brandInk),
                ),
                const SizedBox(height: 28),
                Text(
                  'Put the items near the reader',
                  textAlign: TextAlign.center,
                  style: AltaiType.title.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: c.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  'They come in on their own, one card per product.',
                  textAlign: TextAlign.center,
                  style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen message when a sale isn't confirmed (no answer, or maybe recorded).
class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(D.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusCircle(icon: icon, color: c.warningTint, onColor: c.warning),
              const SizedBox(height: D.space4),
              Text(
                title,
                style: AltaiType.title.copyWith(fontSize: 28, color: c.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: D.space2),
              Text(
                body,
                style: AltaiType.body.copyWith(color: c.inkMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: D.space6),
              AltaiButton(action, onPressed: onAction, variant: AltaiButtonVariant.primary, large: true),
            ],
          ),
        ),
      ),
    );
  }
}
