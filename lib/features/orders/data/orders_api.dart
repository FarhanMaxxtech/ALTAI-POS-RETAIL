import '../domain/order.dart';

/// Paid StoreHub orders waiting for their items to be scanned.
///
/// In the design these come from the Altai server, which reads StoreHub every few seconds (the
/// StoreHub token stays on the server, never on the tablet). Those server calls don't exist yet, so
/// the app uses [FakeOrdersApi] for now. When the team adds them, a real class implements this.
abstract class OrdersApi {
  /// True while the orders are made up: the screens say "Demo" and nothing changes in stock.
  bool get isDemo;

  /// Orders of this store that still need a scan, oldest first.
  Future<List<StoreHubOrder>> pending(String storeId);

  /// The cashier scanned every tagged item: the server marks [epcs] Sold, linked to the order.
  Future<void> complete(StoreHubOrder order, List<String> epcs, {required String staffName});
}

/// Made-up orders, so the screens can be tried before the server is ready. Nothing is sent anywhere.
///
/// [addFromTags] makes an order out of tags really read on the tablet, so the matching can be tried
/// with real items.
class FakeOrdersApi implements OrdersApi {
  FakeOrdersApi({DateTime Function()? clock, this.delay = const Duration(milliseconds: 400)})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration delay; // feels like a network call
  final List<StoreHubOrder> _orders = [];
  final List<({String refId, List<String> epcs})> completed = [];
  int _next = 1;
  bool _seeded = false;

  @override
  bool get isDemo => true;

  /// Every demo order, done or not (for tests).
  List<StoreHubOrder> get all => List.unmodifiable(_orders);

  void _seed(String storeId) {
    if (_seeded) return;
    _seeded = true;
    final now = _clock();
    _orders.addAll([
      StoreHubOrder(
        refId: 'demo-ref-1',
        invoiceNumber: demoReceiptNo(now.subtract(const Duration(minutes: 14)), 1),
        storeId: storeId,
        registerId: '1',
        paidAt: now.subtract(const Duration(minutes: 14)),
        lines: const [
          OrderLine(sku: 'CT-BLK-M', name: 'Classic Tee', variation: 'Black / M', qty: 2),
          OrderLine(sku: 'BAG-PAPER', name: 'Paper bag', qty: 1, exempt: true),
        ],
      ),
      StoreHubOrder(
        refId: 'demo-ref-2',
        invoiceNumber: demoReceiptNo(now.subtract(const Duration(minutes: 2)), 2),
        storeId: storeId,
        registerId: '1',
        paidAt: now.subtract(const Duration(minutes: 2)),
        lines: const [
          OrderLine(sku: 'JN-32', name: 'Slim Jeans', variation: '32', qty: 1),
          OrderLine(sku: 'CT-BLK-L', name: 'Classic Tee', variation: 'Black / L', qty: 1),
        ],
      ),
    ]);
  }

  @override
  Future<List<StoreHubOrder>> pending(String storeId) async {
    await Future<void>.delayed(delay);
    _seed(storeId);
    final list = _orders.where((o) => o.storeId == storeId && o.status != OrderStatus.completed).toList()
      ..sort((a, b) => a.paidAt.compareTo(b.paidAt));
    return list;
  }

  @override
  Future<void> complete(StoreHubOrder order, List<String> epcs, {required String staffName}) async {
    await Future<void>.delayed(delay);
    final i = _orders.indexWhere((o) => o.refId == order.refId);
    if (i >= 0) _orders[i] = _orders[i].withStatus(OrderStatus.completed);
    completed.add((refId: order.refId, epcs: epcs));
  }

  /// A demo order with one line per SKU of the [tags] read (inspector results with `sku`,
  /// `product_name`, `variation`). Unknown tags are left out. Null when no tag had a SKU.
  StoreHubOrder? addFromTags(String storeId, List<Map<String, dynamic>> tags) {
    final lines = <String, ({String name, String? variation, int qty})>{};
    for (final t in tags) {
      final sku = t['sku'] as String?;
      if (t['found'] != true || sku == null || sku.isEmpty) continue;
      final l = lines[sku];
      lines[sku] = (
        name: l?.name ?? (t['product_name'] as String? ?? sku),
        variation: l?.variation ?? t['variation'] as String?,
        qty: (l?.qty ?? 0) + 1,
      );
    }
    if (lines.isEmpty) return null;
    final order = StoreHubOrder(
      refId: 'demo-tags-$_next',
      invoiceNumber: demoReceiptNo(_clock(), _next++),
      storeId: storeId,
      registerId: '1',
      paidAt: _clock(),
      lines: [
        for (final e in lines.entries)
          OrderLine(sku: e.key, name: e.value.name, variation: e.value.variation, qty: e.value.qty),
      ],
    );
    _orders.add(order);
    return order;
  }
}

/// A receipt no. shaped like StoreHub's: register 002 + yymmdd + hhmmss + one more digit.
String demoReceiptNo(DateTime t, int n) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '002${two(t.year % 100)}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}${n % 10}';
}
