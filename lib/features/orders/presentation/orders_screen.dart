import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/pos_layout.dart';
import '../../../shared/rfid_reader.dart';
import '../../catalog/data/catalog_api.dart';
import '../../checkout/data/checkout_api.dart';
import '../../checkout/data/store_tags.dart';
import '../../checkout/presentation/basket_screen.dart';
import '../../checkout/presentation/scan_page.dart';
import '../../returns/data/returns_api.dart';
import '../data/orders_api.dart';
import '../domain/order.dart';

/// Paid StoreHub orders of this store that still need their items scanned. The cashier picks one,
/// usually the newest, and the checkout opens with every item on it, each with its scan progress.
/// The list refreshes by itself.
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
    this.catalog,
    this.returns,
    this.storeTags,
    this.onSold,
  });

  final CatalogApi? catalog;
  final ReturnsApi? returns;
  final StoreTags? storeTags;
  final void Function(int pieces)? onSold;

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
  DateTime? _loadedAt; // "Updated just now"
  String _query = '';
  _Tab _tab = _Tab.waiting;

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
        _loadedAt = DateTime.now();
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the orders. Check the connection.');
    }
  }

  Future<void> _open(StoreHubOrder order) async {
    _timer?.cancel();
    await Navigator.of(context).push<bool>(
      shellRoute(
        context,
        BasketScreen(
          order: order,
          api: widget.inspector,
          orders: widget.orders,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          returns: widget.returns,
          storeTags: widget.storeTags,
          tagReader: widget.tagReader,
          onSold: widget.onSold,
          onBack: () => Navigator.of(context).pop(),
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
    final pending = _list;
    final now = DateTime.now();
    final fake = widget.orders is FakeOrdersApi ? widget.orders as FakeOrdersApi : null;
    final scanned = fake == null
        ? const <StoreHubOrder>[]
        : fake.all.where((o) => o.storeId == widget.storeId && o.status == OrderStatus.completed).toList();
    final q = _query.trim();
    bool hit(StoreHubOrder o) => q.isEmpty || o.invoiceNumber.contains(q);
    final shown = switch (_tab) {
      _Tab.waiting => [...?pending],
      _Tab.scanned => scanned,
      _Tab.all => [...?pending, ...scanned],
    }.where(hit).toList()
      ..sort((a, b) => b.paidAt.compareTo(a.paidAt)); // newest at the top: usually the customer at the counter
    final loaded = _loadedAt;
    return AppShell(
      section: Section.orders,
      searchHint: 'Search receipt no.…',
      onSearch: (v) => setState(() => _query = v),
      onRefresh: _load,
      action: fake == null ? null : ShellAction('Demo order', Icons.add_rounded, () => _demoFromTags(fake)),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilterBar(
              chips: [
                FilterChoice('Not scanned  ${pending?.length ?? 0}',
                    selected: _tab == _Tab.waiting, onTap: () => setState(() => _tab = _Tab.waiting)),
                FilterChoice('Scanned  ${scanned.length}',
                    selected: _tab == _Tab.scanned, onTap: () => setState(() => _tab = _Tab.scanned)),
                FilterChoice('All  ${(pending?.length ?? 0) + scanned.length}',
                    selected: _tab == _Tab.all, onTap: () => setState(() => _tab = _Tab.all)),
              ],
              trailing: loaded == null ? null : BarNote('Updated ${ageText(loaded, now)}'),
            ),
            if (fake != null) ...[
              const SizedBox(height: 12),
              const PageNotice(
                'Demo orders: the Altai server doesn\'t send StoreHub orders yet. Nothing here changes stock.',
                icon: Icons.science_outlined,
              ),
            ],
            if (_error case final e?) ...[const SizedBox(height: 12), PageNotice(e)],
            const SizedBox(height: 12),
            Expanded(
              child: pending == null
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                  ? Center(
                      child: Text(
                        _tab == _Tab.scanned ? 'No scanned orders yet.' : 'No orders waiting. New StoreHub sales show up here.',
                        style: AltaiType.body.copyWith(color: c.inkMuted),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 24),
                        child: TableCard(
                          header: const Row(
                            children: [
                              SizedBox(width: _receiptCol, child: ColumnTitle('Receipt no.')),
                              Expanded(child: ColumnTitle('Items')),
                              SizedBox(width: _paidCol, child: ColumnTitle('Paid')),
                              SizedBox(width: _statusCol + _chevCol, child: ColumnTitle('Status')),
                            ],
                          ),
                          rows: [for (final o in shown) _row(context, o, now)],
                        ),
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
    final done = o.status == OrderStatus.completed;
    final late = !done && o.isLate(now);
    final names = {for (final l in o.lines) l.name}.join(', ');
    final age = ageText(o.paidAt, now);
    return InkWell(
      onTap: done ? null : () => _open(o),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: _receiptCol,
              child: Text(o.invoiceNumber,
                  style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink)),
            ),
            Expanded(
              child: Text(
                '${plural(o.totalQty, 'pc')} · $names',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.ink),
              ),
            ),
            SizedBox(
              width: _paidCol,
              child: Text(
                age[0].toUpperCase() + age.substring(1),
                style: AltaiType.label.copyWith(color: late ? c.warning : c.inkMuted),
              ),
            ),
            SizedBox(
              width: _statusCol,
              child: Align(
                alignment: Alignment.centerLeft,
                child: done
                    ? const StatusPill('Scanned', icon: Icons.check_circle_rounded)
                    : const StatusPill('Not scanned yet', icon: Icons.schedule_rounded),
              ),
            ),
            SizedBox(width: _chevCol, child: done ? null : Icon(Icons.chevron_right_rounded, size: 26, color: c.inkMuted)),
          ],
        ),
      ),
    );
  }
}

enum _Tab { waiting, scanned, all }

const _receiptCol = 236.0;
const _paidCol = 150.0;
const _statusCol = 170.0;
const _chevCol = 32.0;

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
      MaterialPageRoute(builder: (_) => ScanPage(reader: widget.tagReader, inspector: widget.inspector, target: 'demo order')),
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
