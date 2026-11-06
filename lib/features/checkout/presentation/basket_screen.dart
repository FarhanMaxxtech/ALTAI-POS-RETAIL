import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/barcode_scan_screen.dart';
import '../../../shared/beeper.dart';
import '../../../shared/keyboard.dart';
import '../../catalog/data/catalog_api.dart';
import '../../orders/data/orders_api.dart';
import '../../orders/presentation/orders_screen.dart';
import '../../returns/data/returns_api.dart';
import '../../returns/domain/exchange.dart';
import '../../returns/presentation/return_screen.dart';
import '../data/checkout_api.dart';
import '../domain/basket.dart';
import '../domain/basket_controller.dart';
import '../domain/checkout_summary.dart';
import 'recent_screen.dart';
import 'scan_page.dart';

/// The tablet's main screen: read the items, check them, record the sale.
///
/// The EPC box keeps the keyboard focus because a USB RFID pad or reader in keyboard mode "types"
/// each tag and presses Enter. A pad with its own connection only has to call controller.addText.
class BasketScreen extends StatefulWidget {
  const BasketScreen({
    super.key,
    required this.api,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    required this.onLogout,
    this.onChangeStore,
    this.catalog,
    this.returns,
    this.orders,
    this.barcodeScanner = scanBarcode,
    this.askReceiptOnScan = false,
  });

  final CheckoutApi api;
  final String storeId;
  final String storeName;
  final String staffName;
  final VoidCallback onLogout;

  /// Back to the store list (staying logged in). Null = the store can't be changed here.
  final VoidCallback? onChangeStore;

  /// Pictures and the team's prices. Null = no pictures.
  final CatalogApi? catalog;

  /// Customer returns. Null = no Return & refund button.
  final ReturnsApi? returns;

  /// Paid StoreHub orders to scan items against. Null = no StoreHub orders button.
  final OrdersApi? orders;

  /// Reads the receipt's barcode with the camera. Null = cancelled.
  final Future<String?> Function(BuildContext context) barcodeScanner;

  /// Asks for the receipt as soon as the first items are read, so the cashier types it while the
  /// tags are checked in the background (the wait is hidden behind something useful).
  final bool askReceiptOnScan;

  @override
  State<BasketScreen> createState() => _BasketScreenState();
}

/// Ready pieces of one SKU (one colour and size of a product).
class _Variant {
  _Variant(this.sku, this.first);

  final String sku;
  final BasketItem first; // gives the variation, picture and price
  final List<String> epcs = [];

  int get qty => epcs.length;
}

/// Ready pieces of one product, shown as one row. Its variants are in the row's dropdown.
class _Line {
  _Line(this.key, this.first);

  final String key; // product code, else name, else SKU
  final BasketItem first; // gives the name and picture
  final Map<String, _Variant> variants = {}; // sku → variant, newest first

  int get qty => variants.values.fold(0, (sum, v) => sum + v.qty);
  List<String> get epcs => [for (final v in variants.values) ...v.epcs];
  _Variant? get only => variants.length == 1 ? variants.values.first : null;
}

int _skuCount(List<_Line> lines) => lines.fold(0, (sum, l) => sum + l.variants.length);

class _BasketScreenState extends State<BasketScreen> {
  late final BasketController _basket = BasketController(
    api: widget.api,
    storeId: widget.storeId,
    staffName: widget.staffName,
    catalog: widget.catalog,
  );
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _receipt = TextEditingController();
  final _beeper = Beeper();

  int _lastCount = 0; // how many items were in the basket last time
  final Map<String, int> _lastQty = {}; // sku → qty last time, to notice which line grew
  String? _flashSku; // the line that just got one more piece (green for a moment)
  bool _reading = false; // "Reading…" for a moment after each tag
  bool _typing = false; // on-screen keyboard shown (only when staff want to type an EPC)
  bool _askedReceipt = false; // the receipt pop-up shows once per basket
  Timer? _flashTimer;
  Timer? _readingTimer;

  bool get _showPrices => widget.catalog != null;

  @override
  void initState() {
    super.initState();
    _basket.addListener(_onBasketChanged);
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _readingTimer?.cancel();
    _basket.removeListener(_onBasketChanged);
    _basket.dispose();
    _input.dispose();
    _focus.dispose();
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
    // One beep each time a new tag lands in the basket.
    final count = _basket.items.length;
    if (_lastCount == 0 && count > 0) _maybeAskReceipt();
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

    // Flash the line whose quantity just went up.
    String? grown;
    final qty = {for (final l in _lines()) l.key: l.qty};
    for (final e in qty.entries) {
      if (e.value > (_lastQty[e.key] ?? 0)) grown = e.key;
    }
    _lastQty
      ..clear()
      ..addAll(qty);
    if (grown != null) {
      _flashTimer?.cancel();
      setState(() => _flashSku = grown);
      _flashTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _flashSku = null);
      });
    }
  }

  void _addTyped([String? _]) {
    _basket.addText(_input.text);
    _input.clear();
    _focus.requestFocus();
  }

  /// The RFID pad types like a hardware keyboard, so the on-screen keyboard stays hidden
  /// (it would cover half the screen). The keyboard button in the EPC box shows it for typing.
  void _toggleKeyboard() {
    setState(() => _typing = !_typing);
    _focus.unfocus(); // the new keyboard type applies the next time the box gets focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      if (_typing) showKeyboard();
    });
  }

  /// A reader in keyboard mode types into whichever box has the focus. If tags landed in the
  /// receipt box, move them to the basket instead.
  static final _looksLikeTags = RegExp(r'^[0-9A-Fa-f]{24,}(\s+[0-9A-Fa-f]{24,})*$');

  void _receiptSubmitted(String value) {
    if (_looksLikeTags.hasMatch(value.trim())) {
      _basket.addText(value);
      _receipt.clear();
      _basket.setReceipt('');
    }
    _focus.requestFocus(); // next: the items
  }

  void _maybeAskReceipt() {
    if (!widget.askReceiptOnScan || _askedReceipt) return;
    if (_basket.hasReceipt || _basket.exchange != null || _basket.phase != BasketPhase.scanning) return;
    _askedReceipt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _askReceipt();
    });
  }

  /// The receipt pop-up. Tags the reader types into it still go to the basket.
  Future<void> _askReceipt() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ReceiptPrompt(basket: _basket, initial: _receipt.text, looksLikeTags: _looksLikeTags),
    );
    if (!mounted) return;
    if (result == _noReceipt) {
      await _pickNoReceipt();
      return;
    }
    if (result != null) {
      _receipt.text = result;
      _basket.setReceipt(result);
    }
    _focus.requestFocus();
  }

  /// The Scan page: items on the reader, press Scan, all of them come back here at once.
  Future<void> _openScanPage() async {
    final tags = await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (!mounted) return;
    if (tags != null && tags.isNotEmpty) _basket.addText(tags.join(' '));
    _focus.requestFocus();
  }

  /// Camera barcode → receipt box, then back to the EPC box for the items.
  Future<void> _scanReceipt() async {
    final value = await widget.barcodeScanner(context);
    if (!mounted) return;
    if (value != null) {
      _receipt.text = value;
      _basket.setReceipt(value);
    }
    _focus.requestFocus();
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
      _basket.setNoReceipt(reason);
    }
    _focus.requestFocus();
  }

  void _nextCustomer() {
    _basket.reset();
    _receipt.clear();
    _askedReceipt = false;
    _lastCount = 0;
    _lastQty.clear();
    _focus.requestFocus();
  }

  void _changeStore() {
    if (_basket.items.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clear or complete this basket before changing store.')));
      return;
    }
    widget.onChangeStore?.call();
  }

  void _openReturns(ReturnsApi returns) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ReturnScreen(
              inspector: widget.api,
              api: returns,
              storeId: widget.storeId,
              storeName: widget.storeName,
              staffName: widget.staffName,
              catalog: widget.catalog,
            ),
          ),
        )
        .then((_) => _focus.requestFocus());
  }

  /// Exchange, step 1: the items coming back (the return screen). Step 2 is this basket, for the new items.
  Future<void> _openExchange(ReturnsApi returns) async {
    if (_basket.items.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clear or complete this basket before starting an exchange.')));
      return;
    }
    final returned = await Navigator.of(context).push<ExchangeReturn>(
      MaterialPageRoute(
        builder: (_) => ReturnScreen(
          inspector: widget.api,
          api: returns,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          barcodeScanner: widget.barcodeScanner,
          exchange: true,
        ),
      ),
    );
    if (!mounted) return;
    if (returned != null) _basket.startExchange(returned);
    _focus.requestFocus();
  }

  /// The money that changes hands in an exchange, or null when this basket isn't one.
  String? get _exchangeDifference {
    final e = _basket.exchange;
    if (e == null || !_showPrices) return null;
    return exchangeDifferenceText(_basket.totalCents, e.refundCents, formatRm);
  }

  void _openOrders(OrdersApi orders) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => OrdersScreen(
              orders: orders,
              inspector: widget.api,
              storeId: widget.storeId,
              storeName: widget.storeName,
              staffName: widget.staffName,
            ),
          ),
        )
        .then((_) => _focus.requestFocus());
  }

  void _openRecent() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => RecentScreen(
              api: widget.api,
              storeId: widget.storeId,
              storeName: widget.storeName,
              catalog: widget.catalog,
            ),
          ),
        )
        .then((_) => _focus.requestFocus());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The on-screen keyboard covers the bottom instead of squeezing the screen
      // (the EPC box is at the top, so it stays visible).
      resizeToAvoidBottomInset: false,
      appBar: AltaiAppBar(
        title: 'Checkout',
        subtitle: widget.storeName,
        onSubtitleTap: widget.onChangeStore == null ? null : _changeStore,
        actions: [
          if (widget.orders case final orders?)
            AppBarIcon(Icons.receipt_long_rounded, tooltip: 'StoreHub orders', onPressed: () => _openOrders(orders)),
          if (widget.returns case final returns?)
            AppBarIcon(
              Icons.assignment_return_rounded,
              tooltip: 'Return & refund',
              onPressed: () => _openReturns(returns),
            ),
          if (widget.returns case final returns?)
            AppBarIcon(Icons.swap_horiz_rounded, tooltip: 'Exchange', onPressed: () => _openExchange(returns)),
          AppBarIcon(Icons.history_rounded, tooltip: 'Recent checkouts', onPressed: _openRecent),
          AppBarText(widget.staffName),
          AppBarIcon(Icons.logout_rounded, tooltip: 'Log out', onPressed: widget.onLogout),
        ],
      ),
      body: ListenableBuilder(
        listenable: _basket,
        builder: (context, _) => switch (_basket.phase) {
          BasketPhase.scanning => _scanning(context),
          BasketPhase.sending => _sending(context),
          BasketPhase.done => _done(context),
          BasketPhase.uncertain => _Outcome(
            icon: Icons.help_outline_rounded,
            title: 'Check before scanning again',
            body: '${_basket.message}',
            action: 'Start a new basket',
            onAction: _nextCustomer,
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
    );
  }

  /* ---------------- Scanning ---------------- */

  Widget _scanning(BuildContext context) {
    final c = context.altai;
    final lines = _lines();
    final problems = _basket.items.reversed.where((i) => i.state == ItemState.problem).toList();
    final checkingItems = _basket.items.reversed.where((i) => i.state == ItemState.checking).toList();
    final checking = checkingItems.length;

    final left = Padding(
      padding: const EdgeInsets.fromLTRB(D.space4, D.space4, D.space4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_basket.exchange case final e?) ...[_exchangeBanner(context, e), const SizedBox(height: D.space2)],
          _receiptBar(context),
          const SizedBox(height: D.space2),
          _scanBar(context, problems.length),
          if (_basket.message != null) ...[const SizedBox(height: D.space3), AltaiNotice(_basket.message!)],
          const SizedBox(height: D.space3),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Scanned items',
                  style: AltaiType.label.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink),
                ),
              ),
              if (checking > 0) ...[
                AltaiBadge('Checking $checking…', tone: BadgeTone.brand),
                const SizedBox(width: D.space2),
              ],
              if (lines.isNotEmpty) AltaiBadge(plural(lines.length, 'product')),
            ],
          ),
          const SizedBox(height: D.space2),
          Expanded(
            child: lines.isEmpty && problems.isEmpty && checking == 0
                ? const SingleChildScrollView(child: _EmptyState())
                : ListView(
                    padding: const EdgeInsets.only(bottom: D.space4),
                    children: [
                      if (problems.isNotEmpty) ...[
                        _ProblemHeader(onRecheck: _basket.recheck),
                        const SizedBox(height: D.space2),
                        for (final p in problems)
                          Padding(
                            padding: const EdgeInsets.only(bottom: D.space2),
                            child: _ProblemRow(item: p, onRemove: () => _basket.remove(p.epc)),
                          ),
                        const SizedBox(height: D.space4),
                      ],
                      // Read but not checked yet: grey rows straight away, filled in as each check ends.
                      for (final i in checkingItems.take(_maxPlaceholders))
                        Padding(
                          key: ValueKey('checking-${i.epc}'),
                          padding: const EdgeInsets.only(bottom: D.space2),
                          child: _CheckingRow(epc: i.epc),
                        ),
                      if (checking > _maxPlaceholders)
                        Padding(
                          padding: const EdgeInsets.only(bottom: D.space2),
                          child: Text(
                            '+ ${checking - _maxPlaceholders} more being checked',
                            style: AltaiType.caption.copyWith(color: c.inkMuted),
                          ),
                        ),
                      if (lines.isNotEmpty) ...[
                        _LineHeader(showPrice: _showPrices),
                        const SizedBox(height: D.space2),
                        for (final l in lines)
                          Padding(
                            key: ValueKey(l.key),
                            padding: const EdgeInsets.only(bottom: D.space2),
                            child: _LineRow(
                              line: l,
                              flashing: _flashSku == l.key,
                              image: _basket.imageOf(l.first),
                              showPrice: _showPrices,
                              priceLoaded: l.variants.values.every((v) => _basket.priceLoaded(v.first)),
                              cents: _cents,
                              onRemoveLine: () {
                                for (final e in l.epcs) {
                                  _basket.remove(e);
                                }
                              },
                            ),
                          ),
                      ],
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
            children: [
              Expanded(child: left),
              VerticalDivider(width: 1, color: c.border),
              SizedBox(width: 280, child: _summary(context, lines)),
            ],
          );
        }
        // Narrow screen (portrait): the summary becomes a bar at the bottom.
        return Column(
          children: [
            Expanded(child: left),
            Divider(height: 1, color: c.border),
            _summaryBar(context, lines),
          ],
        );
      },
    );
  }

  /// Exchange, step 2: what came back, and what to do now.
  Widget _exchangeBanner(BuildContext context, ExchangeReturn e) {
    final c = context.altai;
    final original = CheckoutApi.cleanReceipt(e.receiptNo);
    final noReceiptYet = CheckoutApi.cleanReceipt(_basket.receiptNo).isEmpty && _basket.noReceiptReason == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(D.space3, D.space2, D.space2, D.space2),
      decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
      child: Row(
        children: [
          Icon(Icons.swap_horiz_rounded, color: c.brandInk),
          const SizedBox(width: D.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Exchange · 2 of 2: new items',
                  style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
                ),
                Text(
                  '${plural(e.pieces, 'pc')} back in stock from receipt $original'
                  '${_showPrices ? ' (RM ${formatRm(e.refundCents)})' : ''}. '
                  'Scan the new items and enter the receipt of the new StoreHub sale.',
                  style: AltaiType.caption.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ),
          if (noReceiptYet)
            TextButton(
              onPressed: () {
                _receipt.text = original;
                _basket.setReceipt(original);
                _focus.requestFocus();
              },
              child: const Text('Same receipt'),
            ),
        ],
      ),
    );
  }

  /// Which StoreHub sale this is: typed, scanned with a barcode gun (it types + Enter) or the camera.
  Widget _receiptBar(BuildContext context) {
    final c = context.altai;
    final reason = _basket.noReceiptReason;
    if (reason != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: D.space3, vertical: D.space2),
        decoration: BoxDecoration(color: c.warningTint, borderRadius: BorderRadius.circular(D.radiusMd)),
        child: Row(
          children: [
            Icon(Icons.receipt_long_rounded, color: c.warning),
            const SizedBox(width: D.space3),
            Expanded(
              child: Text(
                'No receipt: $reason',
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: () => _basket.setNoReceipt(null), child: const Text('Enter a receipt')),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _receipt,
            onTap: showKeyboard,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: AltaiType.body.copyWith(fontSize: 16, color: c.ink),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'StoreHub receipt no.',
              hintText: 'Type it, or scan the barcode',
              prefixIcon: const Icon(Icons.receipt_long_rounded),
              suffixIcon: IconButton(
                tooltip: 'Scan barcode with camera',
                onPressed: _scanReceipt,
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ),
            onChanged: _basket.setReceipt,
            onSubmitted: _receiptSubmitted,
          ),
        ),
        const SizedBox(width: D.space2),
        TextButton(onPressed: _pickNoReceipt, child: const Text('No receipt')),
      ],
    );
  }

  Widget _scanBar(BuildContext context, int problemCount) {
    final c = context.altai;
    final items = _basket.items;
    final last = items.isEmpty ? null : items.last;
    return Container(
      padding: const EdgeInsets.all(D.space3),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                child: Text('EPC', style: AltaiType.label.copyWith(color: c.inkMuted)),
              ),
              const SizedBox(width: D.space3),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  keyboardType: _typing ? TextInputType.text : TextInputType.none,
                  style: AltaiType.epc.copyWith(color: c.ink),
                  decoration: InputDecoration(
                    hintText: 'Scan or type EPC',
                    hintStyle: AltaiType.epc.copyWith(color: c.inkMuted),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: D.space3, vertical: D.space3),
                    suffixIcon: IconButton(
                      tooltip: _typing ? 'Hide keyboard' : 'Type an EPC',
                      color: c.inkMuted,
                      onPressed: _toggleKeyboard,
                      icon: Icon(_typing ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined),
                    ),
                  ),
                  onSubmitted: _addTyped,
                ),
              ),
              const SizedBox(width: D.space3),
              AltaiButton('Scan', onPressed: _openScanPage, variant: AltaiButtonVariant.primary, icon: Icons.sensors_rounded),
              const SizedBox(width: D.space2),
              // "Add" is only active when something is typed.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _input,
                builder: (context, v, _) => AltaiButton(
                  'Add',
                  onPressed: v.text.trim().isEmpty ? null : _addTyped,
                  icon: Icons.add_rounded,
                ),
              ),
              const SizedBox(width: D.space3),
              ReaderStatusPill(reading: _reading),
            ],
          ),
          const SizedBox(height: D.space2),
          Padding(
            padding: const EdgeInsets.only(left: 44 + D.space3),
            child: Wrap(
              spacing: D.space3,
              runSpacing: D.space1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (last == null)
                  Text(
                    'Place items on the pad, or type an EPC and tap Add.',
                    style: AltaiType.caption.copyWith(color: c.inkMuted),
                  )
                else ...[
                  Text('Last read', style: AltaiType.caption.copyWith(color: c.inkMuted)),
                  Text(formatEpc(last.epc), style: AltaiType.epc.copyWith(fontSize: 14, color: c.ink)),
                  if (last.state == ItemState.problem)
                    Text(
                      'Problem tag',
                      style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.danger),
                    ),
                ],
                if (problemCount > 0)
                  AltaiBadge(
                    '${plural(problemCount, 'tag')} need attention',
                    tone: BadgeTone.danger,
                    icon: Icons.warning_amber_rounded,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /* ---------------- Summary ---------------- */

  Widget _summary(BuildContext context, List<_Line> lines) {
    final c = context.altai;
    final unpriced = _basket.unpricedCount;
    return Container(
      color: c.surfaceRaised,
      // Scrolls when the screen is short (e.g. keyboard open); otherwise the buttons sit at the bottom.
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: const EdgeInsets.all(D.space4),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: (box.maxHeight - 2 * D.space4).clamp(0, double.infinity)),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Store', style: AltaiType.caption.copyWith(color: c.inkMuted)),
                  Text(
                    widget.storeName,
                    style: AltaiType.label.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink),
                  ),
                  const SizedBox(height: D.space3),
                  Container(
                    padding: const EdgeInsets.all(D.space3),
                    decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TOTAL QTY',
                          style: AltaiType.caption.copyWith(fontWeight: FontWeight.w600, color: c.inkMuted),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${_basket.pieceCount}',
                            style: AltaiType.qtyTotal.copyWith(fontSize: 44, height: 1.05, color: c.brandInk),
                          ),
                        ),
                        Text(
                          _basket.isChecking ? 'pcs · checking ${_basket.checkingCount}…' : 'pcs',
                          style: AltaiType.caption.copyWith(color: c.ink),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: D.space2),
                  _SummaryRow(label: 'Products', value: '${lines.length}'),
                  _SummaryRow(label: 'SKUs', value: '${_skuCount(lines)}'),
                  if (_showPrices)
                    _SummaryRow(
                      label: 'Total',
                      value: 'RM ${formatRm(_basket.totalCents)}',
                      note: unpriced > 0 ? '${plural(unpriced, 'item')} without price' : null,
                    ),
                  if (_basket.exchange case final e? when _showPrices) ...[
                    _SummaryRow(label: 'Returned', value: '- RM ${formatRm(e.refundCents)}'),
                    const SizedBox(height: D.space2),
                    Text(
                      _exchangeDifference!,
                      style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.brandInk),
                    ),
                  ],
                  const Spacer(),
                  if (_basket.missing case final missing?) ...[
                    Text(
                      missing,
                      style: AltaiType.caption.copyWith(color: c.danger),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: D.space3),
                  ],
                  AltaiButton('Clear all', onPressed: _basket.items.isEmpty ? null : _nextCustomer, expand: true),
                  const SizedBox(height: D.space2),
                  AltaiButton(
                    _basket.isChecking ? 'Checking…' : 'Confirm & submit',
                    onPressed: _basket.canComplete ? () => _confirm(lines) : null,
                    variant: AltaiButtonVariant.primary,
                    icon: Icons.check_rounded,
                    expand: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _summaryBar(BuildContext context, List<_Line> lines) {
    final c = context.altai;
    return Container(
      color: c.surfaceRaised,
      padding: const EdgeInsets.all(D.space4),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Text('${_basket.pieceCount}', style: AltaiType.qty.copyWith(color: c.brandInk)),
            const SizedBox(width: D.space1),
            Text('pcs', style: AltaiType.label.copyWith(color: c.inkMuted)),
            const SizedBox(width: D.space4),
            Expanded(
              child: _showPrices
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'RM ${formatRm(_basket.totalCents)}',
                        style: AltaiType.heading.copyWith(color: c.ink),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            AltaiButton('Clear', onPressed: _basket.items.isEmpty ? null : _nextCustomer),
            const SizedBox(width: D.space3),
            AltaiButton(
              'Confirm',
              onPressed: _basket.canComplete ? () => _confirm(lines) : null,
              variant: AltaiButtonVariant.primary,
              icon: Icons.check_rounded,
            ),
          ],
        ),
      ),
    );
  }

  /// Last look before the sale is recorded: Complete changes live stock and can't be undone.
  Future<void> _confirm(List<_Line> lines) async {
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
            padding: const EdgeInsets.all(D.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Everything above the buttons scrolls on a short screen; Back and Submit stay in view.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Confirm checkout', style: AltaiType.title.copyWith(fontSize: 28, color: c.ink)),
                        Text(
                          '${plural(_skuCount(lines), 'SKU')} at ${widget.storeName} will be recorded as sold. '
                          'This changes stock and can\'t be undone.',
                          style: AltaiType.body.copyWith(color: c.inkMuted),
                        ),
                        const SizedBox(height: D.space3),
                        Row(
                          children: [
                            Icon(Icons.receipt_long_rounded, size: 20, color: c.inkMuted),
                            const SizedBox(width: D.space2),
                            Expanded(
                              child: Text(
                                receipt.isNotEmpty ? 'Receipt $receipt' : 'No receipt: ${_basket.noReceiptReason}',
                                style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
                              ),
                            ),
                          ],
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
                        const SizedBox(height: D.space6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: D.space6, vertical: D.space4),
                          decoration: BoxDecoration(
                            color: c.brandTint,
                            borderRadius: BorderRadius.circular(D.radiusMd),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('$qty', style: AltaiType.qtyTotal.copyWith(color: c.brandInk)),
                              const SizedBox(width: D.space3),
                              Padding(
                                padding: const EdgeInsets.only(bottom: D.space2),
                                child: Text(
                                  'pcs total',
                                  style: AltaiType.heading.copyWith(fontWeight: FontWeight.w400, color: c.ink),
                                ),
                              ),
                              const SizedBox(width: D.space4),
                              Expanded(
                                child: _showPrices
                                    ? Padding(
                                        padding: const EdgeInsets.only(bottom: D.space2),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            'RM ${formatRm(_basket.totalCents)}',
                                            style: AltaiType.title.copyWith(color: c.ink),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: D.space4),
                        Divider(color: c.border),
                        Column(
                          children: [
                            for (final l in lines)
                              for (final v in l.variants.values) ...[
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: D.space2),
                                  child: Row(
                                    children: [
                                      ProductThumb(url: _basket.imageOf(v.first), size: 40),
                                      const SizedBox(width: D.space3),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l.first.productName ?? v.sku,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AltaiType.label.copyWith(fontSize: 16, color: c.ink),
                                            ),
                                            Text(
                                              [v.first.variation, 'SKU ${v.sku}'].whereType<String>().join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AltaiType.caption.copyWith(color: c.inkMuted),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text('× ${v.qty}', style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                                    ],
                                  ),
                                ),
                                Divider(height: 1, color: c.border),
                              ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: D.space4),
                Row(
                  children: [
                    Expanded(
                      child: AltaiButton(
                        'Back',
                        onPressed: () => Navigator.of(context).pop(false),
                        large: true,
                        expand: true,
                      ),
                    ),
                    const SizedBox(width: D.space3),
                    Expanded(
                      flex: 2,
                      child: AltaiButton(
                        'Submit',
                        onPressed: () => Navigator.of(context).pop(true),
                        variant: AltaiButtonVariant.primary,
                        icon: Icons.check_rounded,
                        large: true,
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
    if (ok == true) {
      _basket.complete();
    } else {
      _focus.requestFocus();
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

  Widget _done(BuildContext context) {
    final c = context.altai;
    final lines = _lines();
    final qty = lines.fold(0, (sum, l) => sum + l.qty);
    final variants = [
      for (final l in lines)
        for (final v in l.variants.values) (l, v),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(D.space6),
          child: Column(
            children: [
              StatusCircle(icon: Icons.check_rounded, color: c.brand, onColor: c.onBrand),
              const SizedBox(height: D.space4),
              Text('Good to go', style: AltaiType.title.copyWith(fontSize: 32, color: c.ink)),
              const SizedBox(height: D.space1),
              Text(
                [
                  '${plural(qty, 'pc')} across ${plural(_skuCount(lines), 'SKU')}',
                  'Transaction ${_basket.trxId}',
                  if (CheckoutApi.cleanReceipt(_basket.receiptNo) case final r when r.isNotEmpty) 'Receipt $r',
                ].join(' · '),
                style: AltaiType.body.copyWith(color: c.inkMuted),
                textAlign: TextAlign.center,
              ),
              Text(
                _exchangeDifference ?? 'Take payment on StoreHub as usual.',
                style: AltaiType.body.copyWith(color: c.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: D.space6),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: c.surfaceRaised,
                    borderRadius: BorderRadius.circular(D.radiusMd),
                    border: Border.all(color: c.border),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: D.space1),
                    itemCount: variants.length,
                    separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
                    itemBuilder: (context, i) {
                      final (l, v) = variants[i];
                      final cents = _cents(v);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: D.space2),
                        child: Row(
                          children: [
                            ProductThumb(url: _basket.imageOf(v.first), size: 44),
                            const SizedBox(width: D.space3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.first.productName ?? v.sku,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AltaiType.label.copyWith(fontSize: 16, color: c.ink),
                                  ),
                                  Text(
                                    [v.first.variation, 'SKU ${v.sku}'].whereType<String>().join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AltaiType.caption.copyWith(color: c.inkMuted),
                                  ),
                                ],
                              ),
                            ),
                            Text('× ${v.qty}', style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                            if (_showPrices)
                              SizedBox(
                                width: 120,
                                child: Text(
                                  cents == null ? 'No price' : 'RM ${formatRm(cents)}',
                                  textAlign: TextAlign.end,
                                  style: cents == null
                                      ? AltaiType.caption.copyWith(color: c.warning)
                                      : AltaiType.label.copyWith(fontSize: 16, color: c.ink),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_showPrices) ...[
                const SizedBox(height: D.space4),
                Row(
                  children: [
                    Text('Total', style: AltaiType.heading.copyWith(color: c.inkMuted)),
                    const Spacer(),
                    Text('RM ${formatRm(_basket.totalCents)}', style: AltaiType.title.copyWith(color: c.ink)),
                  ],
                ),
              ],
              const SizedBox(height: D.space6),
              AltaiButton(
                'Next customer',
                onPressed: _nextCustomer,
                variant: AltaiButtonVariant.primary,
                icon: Icons.qr_code_scanner_rounded,
                large: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
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

/// What the receipt pop-up returns for "No receipt" (a receipt number can't look like this).
const _noReceipt = '<no receipt>';

/// Asks for the StoreHub receipt while the tags are checked behind it, and shows how far the checks are.
class _ReceiptPrompt extends StatefulWidget {
  const _ReceiptPrompt({required this.basket, required this.initial, required this.looksLikeTags});

  final BasketController basket;
  final String initial;
  final RegExp looksLikeTags;

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
    if (widget.looksLikeTags.hasMatch(v.trim())) {
      widget.basket.addText(v); // the reader typed tags here: they belong in the basket
      _box.clear();
      return;
    }
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

/// At most this many grey "checking" rows; the rest are counted in one line.
const _maxPlaceholders = 8;

/// A piece that's read but not checked yet: its tag now, its name and price in a moment.
class _CheckingRow extends StatelessWidget {
  const _CheckingRow({required this.epc});

  final String epc;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: D.space3, vertical: D.space2),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: _thumbCol,
            height: _thumbCol,
            decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(D.radiusSm)),
          ),
          const SizedBox(width: D.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 140,
                  height: 12,
                  decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(D.radiusSm)),
                ),
                const SizedBox(height: D.space1),
                Text(
                  formatEpc(epc),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AltaiType.epc.copyWith(fontSize: 12, color: c.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: D.space2),
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(D.space8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(D.radiusMd),
          border: Border.all(color: c.borderStrong, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sell_outlined, size: 40, color: c.brandInk),
            const SizedBox(height: D.space2),
            Text('No tags read yet.', style: AltaiType.body.copyWith(color: c.inkMuted)),
            Text(
              'Place items on the pad, or type an EPC and tap Add.',
              style: AltaiType.body.copyWith(color: c.inkMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// Column widths of the item table (header and rows must match).
const _thumbCol = 40.0;
const _priceCol = 104.0;
const _qtyCol = 56.0;
const _chevCol = 28.0;

class _LineHeader extends StatelessWidget {
  const _LineHeader({required this.showPrice});

  final bool showPrice;

  @override
  Widget build(BuildContext context) {
    final s = AltaiType.caption.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      color: context.altai.inkMuted,
    );
    return Padding(
      padding: const EdgeInsets.only(left: D.space3, right: D.space2),
      child: Row(
        children: [
          const SizedBox(width: _thumbCol + D.space3),
          Expanded(child: Text('ITEM', style: s)),
          if (showPrice)
            SizedBox(
              width: _priceCol,
              child: Text('PRICE', style: s, textAlign: TextAlign.end),
            ),
          SizedBox(
            width: _qtyCol,
            child: Text('QTY', style: s, textAlign: TextAlign.end),
          ),
          const SizedBox(width: _chevCol + D.space1),
        ],
      ),
    );
  }
}

/// Shrinks [child] to fit its column instead of overflowing (big totals, big quantities).
Widget _fit(Widget child) => FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: child);

/// One product: picture, name, SKU, price, quantity. Tap it to see its variants.
class _LineRow extends StatefulWidget {
  const _LineRow({
    required this.line,
    required this.flashing,
    required this.image,
    required this.showPrice,
    required this.priceLoaded,
    required this.cents,
    required this.onRemoveLine,
  });

  final _Line line;
  final bool flashing;
  final String? image;
  final bool showPrice;
  final bool priceLoaded;
  final int? Function(_Variant v, [int? qty]) cents; // price in cents, null = no price
  final VoidCallback onRemoveLine;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _open = false; // showing the variants of this product

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final line = widget.line;
    final only = line.only;

    // Total for the product; null when any variant has no price.
    int? total = 0;
    for (final v in line.variants.values) {
      final x = widget.cents(v);
      total = (total == null || x == null) ? null : total + x;
    }

    final Widget price;
    if (!widget.priceLoaded) {
      price = Text(
        '…',
        style: AltaiType.label.copyWith(color: c.inkMuted),
        textAlign: TextAlign.end,
      );
    } else if (total == null) {
      price = Text(
        'No price',
        style: AltaiType.caption.copyWith(color: c.warning),
        textAlign: TextAlign.end,
      );
    } else {
      final each = only != null && only.qty > 1 ? widget.cents(only, 1) : null;
      price = _fit(
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'RM ${formatRm(total)}',
              style: AltaiType.label.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
            ),
            if (each != null)
              Text('RM ${formatRm(each)} each', style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted)),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: widget.flashing ? c.brandTint : c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: widget.flashing ? c.brandTint : c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(D.space2, D.space1 + 2, D.space2, D.space1 + 2),
                  child: Row(
                    children: [
                      ProductThumb(url: widget.image, size: _thumbCol),
                      const SizedBox(width: D.space3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.first.productName ?? only?.sku ?? line.key,
                              style: AltaiType.label.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Several sizes or colours: all their SKUs.
                            Text(
                              'SKU ${line.variants.keys.join(', ')}',
                              style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (widget.flashing) ...[
                        const AltaiBadge('+1', tone: BadgeTone.brand),
                        const SizedBox(width: D.space2),
                      ],
                      if (widget.showPrice) SizedBox(width: _priceCol, child: price),
                      SizedBox(
                        width: _qtyCol,
                        child: _fit(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text('${line.qty}', style: AltaiType.qty.copyWith(fontSize: 20, color: c.brandInk)),
                              const SizedBox(width: 2),
                              Text('pcs', style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: D.space1),
                      SizedBox(
                        width: _chevCol,
                        child: AnimatedRotation(
                          turns: _open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 24,
                            color: c.inkMuted,
                            semanticLabel: _open ? 'Hide variants' : 'Show variants',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_open)
              Container(
                width: double.infinity,
                color: c.surfaceSunken,
                padding: const EdgeInsets.fromLTRB(D.space3, D.space1, D.space2, D.space1),
                child: Column(
                  children: [
                    for (final v in line.variants.values)
                      _VariantRow(
                        variant: v,
                        showPrice: widget.showPrice,
                        cents: widget.cents(v),
                        each: line.variants.length > 1 || v.qty > 1 ? widget.cents(v, 1) : null,
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: widget.onRemoveLine,
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text('Remove product', style: AltaiType.caption.copyWith(fontWeight: FontWeight.w600)),
                        style: TextButton.styleFrom(foregroundColor: c.danger),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One colour/size inside a product's dropdown.
class _VariantRow extends StatelessWidget {
  const _VariantRow({required this.variant, required this.showPrice, required this.cents, required this.each});

  final _Variant variant;
  final bool showPrice;
  final int? cents; // all its pieces
  final int? each; // one piece, shown when it helps

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final v = variant;
    final label = v.first.variation;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: _thumbCol + D.space3),
          Expanded(
            child: Text(
              label == null || label.isEmpty ? 'No variation' : label,
              style: AltaiType.caption.copyWith(fontWeight: FontWeight.w600, color: c.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showPrice)
            SizedBox(
              width: _priceCol,
              child: _fit(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      cents == null ? 'No price' : 'RM ${formatRm(cents!)}',
                      style: AltaiType.caption.copyWith(color: cents == null ? c.warning : c.ink),
                    ),
                    if (cents != null && each != null)
                      Text(
                        'RM ${formatRm(each!)} each',
                        style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted),
                      ),
                  ],
                ),
              ),
            ),
          SizedBox(
            width: _qtyCol,
            child: _fit(
              Text(
                '× ${v.qty}',
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
              ),
            ),
          ),
          const SizedBox(width: D.space1 + _chevCol), // lines up with the row above
        ],
      ),
    );
  }
}

class _ProblemHeader extends StatelessWidget {
  const _ProblemHeader({required this.onRecheck});

  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Row(
      children: [
        Icon(Icons.error_outline_rounded, color: c.danger),
        const SizedBox(width: D.space2),
        Expanded(
          child: Text('Needs attention', style: AltaiType.heading.copyWith(color: c.danger)),
        ),
        AltaiButton(
          'Check again',
          onPressed: onRecheck,
          variant: AltaiButtonVariant.ghost,
          icon: Icons.refresh_rounded,
        ),
      ],
    );
  }
}

class _ProblemRow extends StatelessWidget {
  const _ProblemRow({required this.item, required this.onRemove});

  final BasketItem item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final name = item.productName;
    return Container(
      padding: const EdgeInsets.fromLTRB(D.space4, D.space3, D.space2, D.space3),
      decoration: BoxDecoration(
        color: c.dangerTint,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.problem ?? 'Cannot be sold',
                  style: AltaiType.bodyStrong.copyWith(fontSize: 18, color: c.danger),
                ),
                Text(
                  [
                    ?name,
                    if (item.variation != null) item.variation!,
                    formatEpc(item.epc),
                  ].join(' · '),
                  style: AltaiType.caption.copyWith(color: c.ink),
                ),
              ],
            ),
          ),
          AltaiButton('Remove', onPressed: onRemove, variant: AltaiButtonVariant.ghost, icon: Icons.close_rounded),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: D.space1 + 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label, style: AltaiType.caption.copyWith(fontSize: 15, color: c.inkMuted)),
              const SizedBox(width: D.space3),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(value, style: AltaiType.qty.copyWith(fontSize: 19, color: c.ink)),
                ),
              ),
            ],
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(bottom: D.space2),
            child: Text(
              note!,
              style: AltaiType.caption.copyWith(color: c.warning),
              textAlign: TextAlign.end,
            ),
          ),
        Divider(height: 1, color: c.border),
      ],
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
        child: Padding(
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
