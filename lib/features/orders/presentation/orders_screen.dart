import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/rfid_reader.dart';
import '../../checkout/presentation/scan_page.dart';
import '../../checkout/data/checkout_api.dart';
import '../data/orders_api.dart';
import '../domain/order.dart';
import 'order_scan_screen.dart';

/// Paid StoreHub orders of this store that still need their items scanned. The cashier picks one,
/// usually the newest, and scans its items. The list refreshes by itself.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({
    super.key,
    required this.orders,
    required this.inspector,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    this.refreshEvery = const Duration(seconds: 10),
    this.tagReader = const UsbTagReader(),
  });

  /// The USB RFID reader the Scan page drives.
  final TagReader tagReader;

  final OrdersApi orders;
  final CheckoutApi inspector;
  final String storeId;
  final String storeName;
  final String staffName;
  final Duration refreshEvery;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<StoreHubOrder>? _list;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.refreshEvery, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.orders.pending(widget.storeId);
      if (!mounted) return;
      setState(() {
        _list = list;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the orders. Check the connection.');
    }
  }

  Future<void> _open(StoreHubOrder order) async {
    _timer?.cancel();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => OrderScanScreen(
          order: order,
          inspector: widget.inspector,
          orders: widget.orders,
          storeId: widget.storeId,
          staffName: widget.staffName,
          tagReader: widget.tagReader,
        ),
      ),
    );
    if (!mounted) return;
    _timer = Timer.periodic(widget.refreshEvery, (_) => _load());
    _load();
  }

  Future<void> _demoFromTags(FakeOrdersApi fake) async {
    final order = await showDialog<StoreHubOrder>(
      context: context,
      builder: (_) => _DemoOrderDialog(
        fake: fake,
        inspector: widget.inspector,
        storeId: widget.storeId,
        tagReader: widget.tagReader,
      ),
    );
    if (order != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final list = _list;
    final now = DateTime.now();
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'StoreHub orders',
        subtitle: widget.storeName,
        onBack: () => Navigator.of(context).pop(),
        actions: [AppBarIcon(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _load)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(D.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.orders case final FakeOrdersApi fake) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(D.space3, D.space2, D.space2, D.space2),
                decoration: BoxDecoration(color: c.warningTint, borderRadius: BorderRadius.circular(D.radiusMd)),
                child: Row(
                  children: [
                    Icon(Icons.science_outlined, color: c.warning),
                    const SizedBox(width: D.space3),
                    Expanded(
                      child: Text(
                        'Demo orders: the Altai server doesn\'t send StoreHub orders yet. Nothing here changes stock.',
                        style: AltaiType.caption.copyWith(color: c.ink),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _demoFromTags(fake),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Demo order from tags'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: D.space3),
            ],
            if (_error case final e?) ...[AltaiNotice(e, warning: true), const SizedBox(height: D.space3)],
            Expanded(
              child: list == null
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                  ? Center(
                      child: Text(
                        'No orders waiting. New StoreHub sales show up here.',
                        style: AltaiType.body.copyWith(color: c.inkMuted),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: D.space2),
                        // Newest at the top: that's usually the customer at the counter.
                        itemBuilder: (context, i) => _row(context, list[list.length - 1 - i], now),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, StoreHubOrder o, DateTime now) {
    final c = context.altai;
    final late = o.isLate(now);
    final names = {for (final l in o.lines) l.name}.join(', ');
    return Material(
      color: c.surfaceRaised,
      borderRadius: BorderRadius.circular(D.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(D.radiusMd),
        onTap: () => _open(o),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: D.space3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(D.radiusMd),
            border: Border.all(color: late ? c.warning : c.border),
          ),
          child: Row(
            children: [
              Icon(Icons.receipt_long_rounded, color: c.brandInk),
              const SizedBox(width: D.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.invoiceNumber, style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                    Text(
                      '${plural(o.totalQty, 'pc')} · $names',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AltaiType.caption.copyWith(color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: D.space3),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Paid ${ageText(o.paidAt, now)}',
                    style: AltaiType.caption.copyWith(color: late ? c.warning : c.inkMuted),
                  ),
                  const SizedBox(height: D.space1),
                  late
                      ? const AltaiBadge('Not scanned yet', tone: BadgeTone.warning, icon: Icons.schedule_rounded)
                      : AltaiBadge(o.status.label, tone: BadgeTone.brand),
                ],
              ),
              const SizedBox(width: D.space2),
              Icon(Icons.chevron_right_rounded, color: c.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Demo only: read some real tags and make an order of them, to try the matching with real items.
class _DemoOrderDialog extends StatefulWidget {
  const _DemoOrderDialog({
    required this.fake,
    required this.inspector,
    required this.storeId,
    required this.tagReader,
  });

  final FakeOrdersApi fake;
  final CheckoutApi inspector;
  final String storeId;
  final TagReader tagReader;

  @override
  State<_DemoOrderDialog> createState() => _DemoOrderDialogState();
}

class _DemoOrderDialogState extends State<_DemoOrderDialog> {
  final Set<String> _tags = {};
  bool _busy = false;
  String? _error;

  Future<void> _scan() async {
    final tags = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => ScanPage(reader: widget.tagReader, target: 'demo order')),
    );
    if (tags != null && mounted) setState(() => _tags.addAll(tags));
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = <Map<String, dynamic>>[];
      final tags = _tags.toList();
      for (var i = 0; i < tags.length; i += CheckoutApi.inspectLimit) {
        found.addAll(
          await widget.inspector.inspect(tags.sublist(i, (i + CheckoutApi.inspectLimit).clamp(0, tags.length))),
        );
      }
      final order = widget.fake.addFromTags(widget.storeId, found);
      if (!mounted) return;
      if (order == null) {
        setState(() {
          _busy = false;
          _error = 'None of these tags has a product.';
        });
      } else {
        Navigator.of(context).pop(order);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not check the tags.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return AlertDialog(
      title: const Text('Demo order from tags'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Read a few items. The demo order gets one line per SKU read. Then scan them on the order, '
              'and try an item that isn\'t in it.',
              style: AltaiType.caption.copyWith(color: c.inkMuted),
            ),
            const SizedBox(height: D.space3),
            AltaiButton(
              'Scan items',
              onPressed: _busy ? null : _scan,
              variant: AltaiButtonVariant.primary,
              icon: Icons.sensors_rounded,
            ),
            const SizedBox(height: D.space2),
            Text('${plural(_tags.length, 'tag')} read', style: AltaiType.label.copyWith(color: c.ink)),
            if (_error case final e?) ...[const SizedBox(height: D.space2), AltaiNotice(e, warning: true)],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _busy || _tags.isEmpty ? null : _create, child: Text(_busy ? 'Checking…' : 'Make order')),
      ],
    );
  }
}
