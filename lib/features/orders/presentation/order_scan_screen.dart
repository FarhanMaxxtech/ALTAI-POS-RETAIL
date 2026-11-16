import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/rfid_reader.dart';
import '../../checkout/presentation/scan_page.dart';
import '../../checkout/data/checkout_api.dart';
import '../data/orders_api.dart';
import '../domain/order.dart';
import '../domain/order_scan_controller.dart';

/// Scan the items of one paid StoreHub order. Wrong items and extra pieces are refused on the spot.
/// The items are read with the Scan page (the USB RFID reader), like at checkout.
class OrderScanScreen extends StatefulWidget {
  const OrderScanScreen({
    super.key,
    required this.order,
    required this.inspector,
    required this.orders,
    required this.storeId,
    required this.staffName,
    this.tagReader = const UsbTagReader(),
  });

  final StoreHubOrder order;
  final CheckoutApi inspector;
  final OrdersApi orders;
  final String storeId;
  final String staffName;

  /// The USB RFID reader the Scan page drives.
  final TagReader tagReader;

  @override
  State<OrderScanScreen> createState() => _OrderScanScreenState();
}

class _OrderScanScreenState extends State<OrderScanScreen> {
  late final _scan = OrderScanController(
    order: widget.order,
    inspector: widget.inspector,
    orders: widget.orders,
    storeId: widget.storeId,
    staffName: widget.staffName,
  );
  final _beeper = Beeper();
  int _lastOk = 0;
  int _lastRejected = 0;

  StoreHubOrder get _order => widget.order;

  @override
  void initState() {
    super.initState();
    _scan.addListener(_onChanged);
  }

  @override
  void dispose() {
    _scan.removeListener(_onChanged);
    _scan.dispose();
    _beeper.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_scan.rejected.length > _lastRejected) {
      HapticFeedback.heavyImpact();
      _beeper.error();
    } else if (_scan.scannedQty > _lastOk) {
      HapticFeedback.lightImpact();
      _beeper.ok();
    }
    _lastOk = _scan.scannedQty;
    _lastRejected = _scan.rejected.length;
  }

  /// The Scan page: the order's items on the reader, Scan, and they all come back here.
  Future<void> _scanItems() async {
    final tags = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => ScanPage(
        reader: widget.tagReader,
        inspector: widget.inspector,
        target: 'order',
        allowedSkus: {
          for (final l in widget.order.lines)
            if (!l.exempt) l.sku,
        },
      )),
    );
    if (!mounted) return;
    if (tags != null && tags.isNotEmpty) _scan.addText(tags.join(' '));
  }

  /// Leaving with tags scanned loses them (the order stays pending), so ask first.
  Future<void> _back() async {
    if (_scan.phase == OrderScanPhase.done) return Navigator.of(context).pop(true);
    if (_scan.scannedQty > 0 && _scan.phase == OrderScanPhase.scanning) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Leave this order?'),
          content: Text(
            'The ${plural(_scan.scannedQty, 'piece')} scanned so far will be cleared. '
            'The order stays on the list.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AltaiAppBar(
          title: 'Order ${_order.invoiceNumber}',
          subtitle: widget.orders.isDemo ? 'Demo order' : null,
          onBack: _back,
          actions: [
            AppBarText(widget.staffName),
            const SizedBox(width: D.space3),
          ],
        ),
        body: ListenableBuilder(
          listenable: _scan,
          builder: (context, _) => switch (_scan.phase) {
            OrderScanPhase.scanning => _scanning(context),
            OrderScanPhase.sending => _sending(context),
            OrderScanPhase.done => _done(context),
          },
        ),
      ),
    );
  }

  Widget _scanning(BuildContext context) {
    final c = context.altai;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(D.space4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _epcBox(context),
                if (_scan.message case final m?) ...[const SizedBox(height: D.space2), AltaiNotice(m, warning: true)],
                const SizedBox(height: D.space3),
                Expanded(
                  child: ListView(
                    children: [
                      Text('ITEMS ON THE RECEIPT', style: AltaiType.label.copyWith(color: c.inkMuted)),
                      const SizedBox(height: D.space2),
                      for (final l in _order.lines) _lineRow(context, l),
                      if (_scan.rejected.isNotEmpty) ...[
                        const SizedBox(height: D.space4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'REFUSED (${_scan.rejected.length})',
                                style: AltaiType.label.copyWith(color: c.danger),
                              ),
                            ),
                            TextButton(onPressed: _scan.clearRejected, child: const Text('Clear')),
                          ],
                        ),
                        for (final r in _scan.rejected) _rejectedRow(context, r),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 280, child: _summary(context)),
      ],
    );
  }

  Widget _epcBox(BuildContext context) {
    final c = context.altai;
    return Container(
      padding: const EdgeInsets.all(D.space3),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.sensors_rounded, color: c.brandInk),
          const SizedBox(width: D.space3),
          Expanded(
            child: Text(
              'Put the items of this order on the reader, then tap Scan.',
              style: AltaiType.body.copyWith(color: c.ink),
            ),
          ),
          if (_scan.checkingCount > 0) ...[
            const SizedBox(width: D.space3),
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: D.space2),
            Text('Checking ${_scan.checkingCount}', style: AltaiType.caption.copyWith(color: c.inkMuted)),
          ],
          const SizedBox(width: D.space3),
          AltaiButton(
            'Scan',
            onPressed: _scanItems,
            variant: AltaiButtonVariant.primary,
            icon: Icons.sensors_rounded,
            large: true,
          ),
        ],
      ),
    );
  }

  Widget _lineRow(BuildContext context, OrderLine l) {
    final c = context.altai;
    final got = _scan.scannedOf(l.sku);
    final full = l.exempt || got == l.qty;
    return Container(
      margin: const EdgeInsets.only(bottom: D.space2),
      padding: const EdgeInsets.symmetric(horizontal: D.space3, vertical: D.space2),
      decoration: BoxDecoration(
        color: full ? c.brandTint : c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: full ? c.brandTint : c.border),
      ),
      child: Row(
        children: [
          Icon(
            l.exempt
                ? Icons.do_not_disturb_on_outlined
                : full
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: full ? c.brandInk : c.inkMuted,
          ),
          const SizedBox(width: D.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink),
                ),
                Text(
                  [?l.variation, 'SKU ${l.sku}'].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AltaiType.caption.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: D.space3),
          if (l.exempt)
            Text('No tag needed', style: AltaiType.caption.copyWith(color: c.inkMuted))
          else
            Text('$got / ${l.qty}', style: AltaiType.bodyStrong.copyWith(color: full ? c.brandInk : c.ink)),
        ],
      ),
    );
  }

  Widget _rejectedRow(BuildContext context, RejectedTag r) {
    final c = context.altai;
    return Container(
      margin: const EdgeInsets.only(bottom: D.space1),
      padding: const EdgeInsets.symmetric(horizontal: D.space3, vertical: D.space2),
      decoration: BoxDecoration(color: c.dangerTint, borderRadius: BorderRadius.circular(D.radiusSm)),
      child: Row(
        children: [
          Icon(Icons.block_rounded, size: 20, color: c.danger),
          const SizedBox(width: D.space2),
          Expanded(
            child: Text(
              r.name ?? 'Unknown item',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AltaiType.caption.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: D.space2),
          Text(
            r.reason,
            style: AltaiType.caption.copyWith(fontWeight: FontWeight.w600, color: c.danger),
          ),
        ],
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final c = context.altai;
    final need = _order.taggedQty;
    return Container(
      color: c.surfaceRaised,
      padding: const EdgeInsets.all(D.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Receipt', style: AltaiType.caption.copyWith(color: c.inkMuted)),
          Text(
            _order.invoiceNumber,
            style: AltaiType.label.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink),
          ),
          Text('Paid ${ageText(_order.paidAt, DateTime.now())}', style: AltaiType.caption.copyWith(color: c.inkMuted)),
          const SizedBox(height: D.space3),
          Container(
            padding: const EdgeInsets.all(D.space3),
            decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SCANNED', style: AltaiType.label.copyWith(color: c.brandInk)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_scan.scannedQty} / $need',
                    style: AltaiType.qtyTotal.copyWith(fontSize: 48, color: c.ink),
                  ),
                ),
                Text('pieces with a tag', style: AltaiType.caption.copyWith(color: c.inkMuted)),
              ],
            ),
          ),
          const Spacer(),
          if (!_scan.allMatched)
            Padding(
              padding: const EdgeInsets.only(bottom: D.space2),
              child: Text(
                _scan.checkingCount > 0
                    ? 'Checking tags…'
                    : '${plural(need - _scan.scannedQty, 'piece')} still to scan.',
                style: AltaiType.caption.copyWith(color: c.inkMuted),
              ),
            ),
          AltaiButton(
            'Complete order',
            onPressed: _scan.allMatched ? _scan.complete : null,
            variant: AltaiButtonVariant.primary,
            icon: Icons.check_rounded,
            expand: true,
          ),
        ],
      ),
    );
  }

  Widget _sending(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
        const SizedBox(height: D.space4),
        Text('Completing the order…', style: AltaiType.heading.copyWith(color: context.altai.ink)),
      ],
    ),
  );

  Widget _done(BuildContext context) {
    final c = context.altai;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(D.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusCircle(icon: Icons.check_rounded, color: c.brand, onColor: c.onBrand),
            const SizedBox(height: D.space4),
            Text('Order complete', style: AltaiType.title.copyWith(fontSize: 32, color: c.ink)),
            const SizedBox(height: D.space1),
            Text(
              widget.orders.isDemo
                  ? 'Demo: nothing was changed in stock.'
                  : '${plural(_scan.scannedQty, 'piece')} marked sold. The gate lets them out.',
              textAlign: TextAlign.center,
              style: AltaiType.body.copyWith(color: c.inkMuted),
            ),
            const SizedBox(height: D.space6),
            AltaiButton(
              'Back to orders',
              onPressed: () => Navigator.of(context).pop(true),
              variant: AltaiButtonVariant.primary,
              large: true,
            ),
          ],
        ),
      ),
    );
  }
}
