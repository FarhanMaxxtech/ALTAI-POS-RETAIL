import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/pos_layout.dart';
import '../../../shared/reader_session.dart';
import '../../../shared/reader_widgets.dart';
import '../../../shared/rfid_reader.dart';
import '../../catalog/data/catalog_api.dart';
import '../../checkout/data/checkout_api.dart';
import '../../checkout/domain/basket.dart';
import '../../orders/data/orders_api.dart';
import '../../orders/domain/order.dart';
import '../data/returns_api.dart';
import '../domain/exchange.dart';
import '../domain/return_controller.dart';

/// Return & refund (Figma "New 07–08"): the items go back into this store's stock here; the money
/// goes back on StoreHub.
///
/// With [exchange] it's step 1 of an exchange: once the items are back in stock the screen closes and
/// hands an [ExchangeReturn] to the checkout, where the new items are scanned.
///
/// The items coming back are read straight from the USB RFID reader as cards, like at checkout:
/// it reads the whole time the screen is open (paused only while the confirm box is up).
class ReturnScreen extends StatefulWidget {
  const ReturnScreen({
    super.key,
    required this.inspector,
    required this.api,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    this.catalog,
    this.exchange = false,
    this.tagReader = const UsbTagReader(),
    this.onReturned,
    this.initialReceipt,
    this.order,
    this.orders,
  });

  final CheckoutApi inspector;
  final ReturnsApi api;
  final String storeId;
  final String storeName;
  final String staffName;
  final CatalogApi? catalog;

  /// Step 1 of an exchange: closes with an [ExchangeReturn] once the items are back in stock.
  final bool exchange;

  /// The USB RFID reader this screen drives.
  final TagReader tagReader;

  /// A return went through, with this many pieces (for the start page's "Returns today").
  final void Function(int pieces)? onReturned;

  /// The order picked in the order history: its receipt no. is filled in.
  final String? initialReceipt;

  /// The order the items come back on (picked in the order history): each tag is checked against it.
  final StoreHubOrder? order;

  /// Completed StoreHub orders: lets the cashier find the order by its last 4 digits, and is told
  /// what came back. Null = no order lookup.
  final OrdersApi? orders;

  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends State<ReturnScreen> {
  late final ReturnController _return = ReturnController(
      inspector: widget.inspector,
      api: widget.api,
      storeId: widget.storeId,
      staffName: widget.staffName,
      catalog: widget.catalog,
      order: widget.order);
  final _receipt = TextEditingController();
  final _beeper = Beeper();
  late final ReaderSession _reader =
      ReaderSession(reader: widget.tagReader, onTags: _return.readRound);
  int _lastCount = 0;
  bool _handedBack = false; // exchange: the result is passed back once
  bool _pausedNow = false; // the confirm box is open: the reader waits
  ReturnPhase _lastPhase = ReturnPhase.scanning;
  String _query = '';

  bool get _showPrices => widget.catalog != null;

  @override
  void initState() {
    super.initState();
    if (widget.order case final o?) _receipt.text = o.invoiceNumber;
    if (widget.initialReceipt case final r?) {
      _receipt.text = r;
      _return.setReceipt(r);
    }
    _return.addListener(_onChanged);
    _reader.addListener(_onReaderChanged);
    _reader.start();
  }

  void _onReaderChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _reader.removeListener(_onReaderChanged);
    _reader.dispose();
    _return.removeListener(_onChanged);
    _return.dispose();
    _receipt.dispose();
    _beeper.dispose();
    super.dispose();
  }

  void _onChanged() {
    final count = _return.items.length;
    if (count > _lastCount) {
      HapticFeedback.lightImpact();
      _beeper.ok();
    }
    _lastCount = count;

    // Back to scanning (a new return, or the submit didn't go through): read again.
    final phase = _return.phase;
    if (phase != _lastPhase && phase == ReturnPhase.scanning && !_pausedNow) _reader.start();
    if (phase != _lastPhase && phase == ReturnPhase.done) {
      if (!widget.exchange) widget.onReturned?.call(_return.pieceCount);
      // The order remembers what came back, so the same pieces can't come back on it again.
      if ((_return.order, widget.orders) case (final o?, final api?)) {
        final epcs = [for (final i in _return.items) if (i.state == ItemState.ok) i.epc];
        api.recordReturn(o, _return.piecesBySku, epcs).catchError((_) {});
      }
    }
    _lastPhase = phase;

    if (widget.exchange && _return.phase == ReturnPhase.done && !_handedBack) {
      _handedBack = true;
      final result = ExchangeReturn(
        receiptNo: _return.receiptNo.trim(),
        pieces: _return.pieceCount,
        refundCents: _showPrices ? _return.refundCents : 0,
        trxId: _return.trxId ?? '',
        items: _cameBack(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(result);
      });
    }
  }

  /// What came back, one entry per SKU, for step 2 of the exchange.
  List<ExchangeItem> _cameBack() {
    final bySku = <String, ({BasketItem first, int pieces, int? cents})>{};
    for (final i in _return.items) {
      if (i.state != ItemState.ok) continue;
      final key = i.sku ?? i.epc;
      final unit = toCents(_return.priceOf(i));
      final pcs = _return.pcsOf(i);
      final old = bySku[key];
      final cents = unit == null || (old != null && old.cents == null) ? null : (old?.cents ?? 0) + unit * pcs;
      bySku[key] = (first: old?.first ?? i, pieces: (old?.pieces ?? 0) + pcs, cents: _showPrices ? cents : null);
    }
    return [
      for (final e in bySku.values)
        ExchangeItem(
          name: e.first.productName ?? e.first.sku ?? 'Unknown item',
          variation: e.first.variation,
          sku: e.first.sku,
          pieces: e.pieces,
          cents: e.cents,
        ),
    ];
  }

  /// The receipt typed is the last 4 digits (or all 16) of an order: find it among the completed
  /// orders of the last 30 days.
  bool get _canFind {
    final no = _receipt.text.replaceAll(RegExp(r'\s'), '');
    return widget.orders != null && _return.order == null && RegExp(r'^(\d{4}|\d{16})$').hasMatch(no);
  }

  Future<void> _findOrder() async {
    final api = widget.orders;
    final no = _receipt.text.replaceAll(RegExp(r'\s'), '');
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    List<StoreHubOrder> found;
    try {
      final recent = await api.history(widget.storeId, from: now.subtract(const Duration(days: 30)), to: now);
      found = [for (final o in recent) if (o.invoiceNumber.endsWith(no)) o];
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not load the orders. Check the connection.')));
      return;
    }
    if (!mounted) return;
    if (found.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('No completed order in the last 30 days ending in $no.')));
      return;
    }
    final pick = found.length == 1 ? found.single : await _chooseOrder(found, no);
    if (pick == null || !mounted) return;
    _receipt.text = pick.invoiceNumber;
    _return.useOrder(pick);
  }

  Future<StoreHubOrder?> _chooseOrder(List<StoreHubOrder> found, String no) {
    final c = context.altai;
    String two(int v) => v.toString().padLeft(2, '0');
    return showDialog<StoreHubOrder>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Orders ending in $no', style: AltaiType.heading.copyWith(color: c.ink)),
        children: [
          for (final o in found)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(o),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: D.space2),
                child: Text(
                  '${o.invoiceNumber} · ${two(o.paidAt.day)}/${two(o.paidAt.month)} '
                  '${two(o.paidAt.hour)}:${two(o.paidAt.minute)} · ${plural(o.totalQty, 'pc')}',
                  style: AltaiType.body.copyWith(color: c.ink),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _newReturn() {
    _return.reset();
    _receipt.clear();
    _lastCount = 0;
    _reader.start();
  }

  /// A return that may be half done stays on screen until it's finished.
  bool get _canLeave {
    final phase = _return.phase;
    if (phase == ReturnPhase.scanning || phase == ReturnPhase.done) return true;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Finish this return first: tap Try again.')));
    return false;
  }

  Future<bool> _mayLeave() async => _canLeave;

  /// Last look: this changes live stock and can't be undone from the tablet.
  Future<void> _confirm() async {
    // What's on screen is what comes back: no new tags while the cashier checks it.
    _pausedNow = true;
    _reader.stop();
    final c = context.altai;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.exchange ? 'Confirm exchange: items back' : 'Confirm return',
            style: AltaiType.title.copyWith(fontWeight: FontWeight.w700, color: c.ink)),
        content: Text(
          widget.exchange
              ? '${plural(_return.pieceCount, 'pc')} go back into stock at ${widget.storeName}. '
                  'Next, scan the new items the customer takes.'
              : '${plural(_return.pieceCount, 'pc')} go back into stock at ${widget.storeName}.'
                  '${_showPrices ? ' Refund RM ${formatRm(_return.refundCents)} on StoreHub.' : ''}',
          style: AltaiType.body.copyWith(color: c.inkMuted),
        ),
        actions: [
          AltaiButton('Back', onPressed: () => Navigator.of(context).pop(false)),
          AltaiButton('Submit',
              onPressed: () => Navigator.of(context).pop(true),
              variant: AltaiButtonVariant.primary,
              icon: Icons.check_rounded),
        ],
      ),
    );
    _pausedNow = false;
    if (ok == true) {
      _return.submit();
    } else if (mounted && _return.phase == ReturnPhase.scanning) {
      _reader.start(); // Back: keep reading
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _return,
      builder: (context, _) => PopScope(
        canPop: _return.phase == ReturnPhase.scanning || _return.phase == ReturnPhase.done,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _canLeave;
        },
        child: AppShell(
          section: Section.returns,
          searchHint: 'Search items coming back…',
          onSearch: (q) => setState(() => _query = q.trim().toLowerCase()),
          onRefresh: _return.phase == ReturnPhase.scanning ? _reader.start : null,
          refreshTooltip: 'Read again',
          offline: _return.offline,
          beforeLeave: _mayLeave,
          onBack: widget.exchange ? () => Navigator.of(context).maybePop() : null,
          body: switch (_return.phase) {
            ReturnPhase.scanning => _scanning(context),
            ReturnPhase.sending => _sending(context),
            ReturnPhase.done => widget.exchange ? _sending(context) : _done(context), // closes by itself
            ReturnPhase.retry => _Problem(
                icon: Icons.wifi_off_rounded,
                title: 'No confirmation yet',
                body: '${_return.message} It is safe to try again: this return can only be saved once.',
                onRetry: _return.submit),
            ReturnPhase.notApproved => _Problem(
                icon: Icons.hourglass_top_rounded,
                title: 'Saved, but stock isn\'t back yet',
                body: '${_return.message} Try again approves the same return.',
                onRetry: _return.submit),
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

  String? _amount(BasketItem i) {
    if (!_showPrices) return null;
    final unit = toCents(_return.priceOf(i));
    return unit == null ? 'No price' : 'RM ${formatRm(unit * _return.pcsOf(i))}';
  }

  Widget _scanning(BuildContext context) {
    final c = context.altai;
    final items = _return.items.reversed.toList();
    final shown = [
      ...items.where((i) => i.state == ItemState.problem),
      ...items.where((i) => i.state != ItemState.problem),
    ].where(_matches).toList();

    final middle = Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBar(
            chips: [
              for (final r in returnReasons)
                FilterChoice(r, selected: _return.reason == r, onTap: () => _return.setReason(r)),
            ],
            trailing: const BarNote('Reason'),
          ),
          if (widget.exchange) ...[
            const SizedBox(height: 12),
            const ExchangeSteps(
              step: 1,
              title: 'Exchange · 1 of 2: items back',
              note: 'Scan what the customer brings back. Next, the new items they take.',
            ),
          ],
          if (_reader.error != null) ...[const SizedBox(height: 12), ReaderProblem(session: _reader)],
          if (_return.offline) ...[const SizedBox(height: 12), const PageNotice(offlineText)],
          if (_return.message != null) ...[
            const SizedBox(height: 12),
            PageNotice(_return.message!, icon: Icons.warning_amber_rounded, danger: true),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: items.isEmpty
                ? _EmptyState(reading: _reader.reading)
                : ItemGrid(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final i in shown)
                        switch (i.state) {
                          ItemState.problem => ItemCard(
                            key: ValueKey('problem-${i.epc}'),
                            look: CardLook.problem,
                            title: i.productName ?? 'Unknown item',
                            subtitle: i.problem ?? '',
                            goesAwayAt: _return.goesAwayAt(i.epc),
                            onTap: () => _details(i),
                          ),
                          ItemState.checking => ItemCard(
                            key: ValueKey('checking-${i.epc}'),
                            look: CardLook.checking,
                            title: i.productName ?? 'Reading tag…',
                            subtitle: i.variation ?? formatEpc(i.epc),
                          ),
                          ItemState.ok => ItemCard(
                            key: ValueKey('card-${i.epc}'),
                            title: i.productName ?? 'Unknown item',
                            subtitle: [
                              i.variation ?? i.sku ?? '',
                              if (i.multiplier > 1) 'Bundle ×${i.multiplier}',
                            ].where((s) => s.isNotEmpty).join(' · '),
                            bottom: _amount(i),
                            qty: _return.pcsOf(i),
                            image: _return.imageOf(i),
                            onTap: () => _details(i),
                          ),
                        },
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
            children: [Expanded(child: middle), SidePanel(child: _panel(context))],
          );
        }
        // Narrow screen (portrait): the order panel goes under the cards; a short screen scrolls.
        const panelHeight = 420.0;
        final middleHeight = (box.maxHeight - panelHeight).clamp(320.0, double.infinity);
        final panel = Container(
          height: panelHeight,
          decoration: BoxDecoration(color: c.surfaceRaised, border: Border(top: BorderSide(color: c.border))),
          padding: const EdgeInsets.all(16),
          child: _panel(context),
        );
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [SizedBox(height: middleHeight, child: middle), panel],
          ),
        );
      },
    );
  }

  /// A card's details: a bundle's pieces (− / +), and Remove.
  Future<void> _details(BasketItem item) async {
    final c = context.altai;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: _return,
        builder: (context, _) {
          final i = _return.items.where((x) => x.epc == item.epc).firstOrNull ?? item;
          final problem = i.state == ItemState.problem;
          return AlertDialog(
            title: Text(i.productName ?? 'Unknown item',
                style: AltaiType.title.copyWith(color: problem ? c.danger : c.ink)),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (problem) Text(i.problem ?? '', style: AltaiType.body.copyWith(color: c.ink)),
                  if (i.variation case final v?) PanelRow('Colour / size', v),
                  if (i.sku case final s?) PanelRow('SKU', s),
                  if (_amount(i) case final a? when !problem) PanelRow('Refund', a),
                  if (i.multiplier > 1 && !problem) ...[
                    const SizedBox(height: D.space2),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Pieces coming back (bundle ×${i.multiplier})',
                              style: AltaiType.label.copyWith(color: c.inkMuted)),
                        ),
                        _PcsPill(
                          pcs: _return.pcsOf(i),
                          onLess: _return.canRemovePc(i) ? () => _return.changePcs(i.epc, -1) : null,
                          onMore: _return.canAddPc(i) ? () => _return.changePcs(i.epc, 1) : null,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              AltaiButton('Remove', onPressed: () => Navigator.pop(context, true), variant: AltaiButtonVariant.danger),
              AltaiButton('Close', onPressed: () => Navigator.pop(context, false), variant: AltaiButtonVariant.primary),
            ],
          );
        },
      ),
    );
    if (remove == true) _return.remove(item.epc);
  }

  /* ---------------- The panel on the right ---------------- */


  Widget _panel(BuildContext context) {
    final c = context.altai;
    final ok = _return.items.reversed.where((i) => i.state == ItemState.ok).toList();
    final problems = _return.items.where((i) => i.state == ItemState.problem).length;
    final order = _return.order;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (order != null)
          _OrderBox(
            order: order,
            onChange: widget.order == null && widget.orders != null
                ? () {
                    _receipt.clear();
                    _return.setReceipt('');
                    _return.useOrder(null);
                  }
                : null,
          )
        else
          ReceiptField(
            controller: _receipt,
            label: 'StoreHub receipt no.',
            hint: widget.orders == null ? 'Receipt no., order no. or ID' : 'Last 4 digits, or the whole receipt no.',
            keyboardType: TextInputType.text,
            onChanged: _return.setReceipt,
            onSubmitted: (_) {
              if (_canFind) _findOrder();
            },
            ok: _canFind ? 'Tap Find to look up the order' : null,
            suffix: _canFind
                ? Padding(
                    padding: const EdgeInsets.only(right: D.space1),
                    child: TextButton(onPressed: _findOrder, child: const Text('Find')),
                  )
                : null,
          ),
        const SizedBox(height: 12),
        Expanded(
          child: order != null
              ? _orderLines(context, order)
              : ok.isEmpty
              ? Center(
                  child: Text(
                    _return.offline
                        ? 'Waiting for the internet…'
                        : _return.isChecking
                        ? 'Checking the items…'
                        : 'Nothing scanned yet',
                    style: AltaiType.label.copyWith(color: c.inkMuted),
                  ),
                )
              : ListView.separated(
                  itemCount: ok.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, n) {
                    final i = ok[n];
                    final unit = toCents(_return.priceOf(i));
                    return PanelLine(
                      key: ValueKey('line-${i.epc}'),
                      qty: _return.pcsOf(i),
                      name: i.productName ?? 'Unknown item',
                      detail: i.variation ?? i.sku,
                      amount: !_showPrices ? null : (unit == null ? '–' : formatRm(unit * _return.pcsOf(i))),
                      shaded: n.isEven,
                    );
                  },
                ),
        ),
        const SizedBox(height: 12),
        PanelRow('Pieces coming back', '${_return.pieceCount}'),
        if (problems > 0) PanelRow('Needs attention', '$problems', valueColor: c.danger),
        PanelRow('Reason', _return.reason ?? '–'),
        if (_showPrices) PanelTotal('Refund', 'RM ${formatRm(_return.refundCents)}'),
        const SizedBox(height: 10),
        if (_return.missing case final m?)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(m,
                textAlign: TextAlign.center,
                style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: c.inkMuted)),
          ),
        PanelButtons(
          clear: 'Clear',
          onClear: _return.items.isEmpty && _receipt.text.isEmpty ? null : _newReturn,
          confirm: widget.exchange ? 'Return & next' : 'Return items',
          onConfirm: _return.canSubmit ? _confirm : null,
        ),
      ],
    );
  }


  /// The order's items, each with how many are coming back now: the matched ones are green.
  Widget _orderLines(BuildContext context, StoreHubOrder order) {
    final c = context.altai;
    final coming = _return.piecesBySku;
    final lines = order.lines.where((l) => !l.exempt).toList();
    return ListView.separated(
      itemCount: lines.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, n) {
        final l = lines[n];
        final now = coming[l.sku] ?? 0;
        final before = order.returned[l.sku] ?? 0;
        final left = order.returnableQty(l.sku);
        return Container(
          key: ValueKey('order-line-${l.sku}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: now > 0 ? c.brandTint : c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
            border: now > 0 ? Border.all(color: c.brandBorder) : null,
          ),
          child: Row(
            children: [
              Icon(
                now > 0 ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: now > 0 ? c.brandInk : c.inkMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AltaiType.label.copyWith(
                            fontWeight: FontWeight.w600, color: left == 0 ? c.inkMuted : c.ink)),
                    Text(
                      [?l.variation, if (before > 0) '$before returned before'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AltaiType.caption.copyWith(fontSize: 13, color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$now / $left',
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w700, color: now > 0 ? c.brandInk : c.inkMuted),
              ),
            ],
          ),
        );
      },
    );
  }

  /* ---------------- Other phases ---------------- */

  Widget _sending(BuildContext context) {
    final c = context.altai;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
        const SizedBox(height: D.space4),
        Text('Putting the items back in stock…', style: AltaiType.heading.copyWith(color: c.ink)),
      ]),
    );
  }

  /// Figma "New 08 Return - back in stock".
  Widget _done(BuildContext context) {
    final c = context.altai;
    final unpriced = _return.unpricedCount;
    final nav = ShellScope.maybeOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(D.space6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle),
              child: Icon(Icons.check_rounded, size: 52, color: c.onBrand),
            ),
            const SizedBox(height: 28),
            Text('Back in stock', style: AltaiType.title.copyWith(fontSize: 32, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 4),
            Text(
              '${plural(_return.pieceCount, 'piece')} · Receipt ${_return.receiptNo.trim()} · Adjustment ${_return.trxId}',
              style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
              decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(16)),
              child: Column(children: [
                Text('Now refund on StoreHub',
                    style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: c.logoGreenBottom)),
                if (_showPrices)
                  Text('RM ${formatRm(_return.refundCents)}',
                      style: AltaiType.qtyTotal.copyWith(fontSize: 56, color: c.brandInk)),
                const SizedBox(height: 4),
                Text(
                  unpriced > 0
                      ? '${plural(unpriced, 'item')} had no price here: check the receipt.'
                      : 'Use the amount on the receipt if it differs (discounts).',
                  style: AltaiType.caption.copyWith(color: c.logoGreenBottom),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
            const SizedBox(height: 32),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(
                width: 240,
                child: AltaiButton('Back to checkout',
                    onPressed: () => nav == null ? Navigator.of(context).pop() : nav.open(Section.checkout),
                    expand: true),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 240,
                child: AltaiButton('New return',
                    onPressed: _newReturn,
                    variant: AltaiButtonVariant.primary,
                    icon: Icons.assignment_return_outlined,
                    expand: true),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Nothing read yet.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.reading});

  final bool reading;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(14)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
          child: Column(children: [
            Container(
              width: 128,
              height: 128,
              decoration: BoxDecoration(color: c.brandTint, shape: BoxShape.circle),
              child: Icon(Icons.assignment_return_outlined, size: 56, color: c.brandInk),
            ),
            const SizedBox(height: 28),
            Text('Items coming back: put them near the reader.',
                textAlign: TextAlign.center,
                style: AltaiType.title.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 6),
            Text(reading ? 'Reader on: they come in on their own.' : 'Reader off',
                textAlign: TextAlign.center, style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted)),
          ]),
        ),
      ),
    );
  }
}

/// A bundle's pieces as one small pill: − 3 +. A null callback greys its side out.
class _PcsPill extends StatelessWidget {
  const _PcsPill({required this.pcs, this.onLess, this.onMore});

  final int pcs;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    Widget side(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          color: c.brandInk,
          disabledColor: c.border,
          tooltip: tip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        );
    return Container(
      decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(Icons.remove_rounded, 'One piece less', onLess),
          SizedBox(
            width: 28,
            child: Text(
              '$pcs',
              textAlign: TextAlign.center,
              style: AltaiType.qty.copyWith(fontSize: 18, color: c.brandInk),
            ),
          ),
          side(Icons.add_rounded, 'One piece more', onMore),
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.icon, required this.title, required this.body, required this.onRetry});

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(D.space6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            StatusCircle(icon: icon, color: c.warningTint, onColor: c.warning),
            const SizedBox(height: D.space4),
            Text(title, style: AltaiType.title.copyWith(fontSize: 28, color: c.ink), textAlign: TextAlign.center),
            const SizedBox(height: D.space2),
            Text(body, style: AltaiType.body.copyWith(color: c.inkMuted), textAlign: TextAlign.center),
            const SizedBox(height: D.space6),
            AltaiButton('Try again', onPressed: onRetry, variant: AltaiButtonVariant.primary, large: true),
          ]),
        ),
      ),
    );
  }
}

/// The order the items come back on, at the top of the panel.
class _OrderBox extends StatelessWidget {
  const _OrderBox({required this.order, this.onChange});

  final StoreHubOrder order;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    String two(int v) => v.toString().padLeft(2, '0');
    final t = order.paidAt;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.brandTint,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.brand, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long_outlined, color: c.brandInk),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Order ${order.invoiceNumber}',
                    key: const ValueKey('return-order'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w700, color: c.ink)),
                Text(
                  'Paid ${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)} · '
                  '${plural(order.totalQty, 'pc')}',
                  style: AltaiType.caption.copyWith(fontSize: 13, color: c.brandInk),
                ),
              ],
            ),
          ),
          if (onChange != null) TextButton(onPressed: onChange, child: const Text('Change')),
        ],
      ),
    );
  }
}
