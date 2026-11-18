/// A paid StoreHub order the cashier scans the items for (the "order-driven" checkout).
///
/// The Altai server reads StoreHub (GET /transactions) and keeps each new sale as "Pending scan".
/// The tablet lists them, the cashier picks one and scans the items against it. Only lines with
/// itemType = Item come here; discounts and service charges don't.
library;

enum OrderStatus {
  pendingScan('Pending scan'),
  partiallyScanned('Partially scanned'),
  completed('Completed'),
  cancelled('Cancelled');

  const OrderStatus(this.label);
  final String label;
}

/// One product line of the order: what StoreHub says the customer paid for.
class OrderLine {
  const OrderLine({required this.sku, required this.name, required this.qty, this.variation, this.exempt = false});

  final String sku; // StoreHub's productId, mapped to the SKU (child level for variants)
  final String name;
  final String? variation;
  final int qty;

  /// No RFID tag (a service, a paper bag): never blocks the order.
  final bool exempt;
}

class StoreHubOrder {
  const StoreHubOrder({
    required this.refId,
    required this.invoiceNumber,
    required this.storeId,
    required this.registerId,
    required this.paidAt,
    required this.lines,
    this.status = OrderStatus.pendingScan,
    this.soldEpcs = const [],
    this.returned = const {},
    this.returnedEpcs = const {},
  });

  final String refId; // StoreHub's unique id, used to avoid duplicates
  final String invoiceNumber; // the receipt number the customer gets
  final String storeId; // our store
  final String registerId;
  final DateTime paidAt; // Malaysia time
  final List<OrderLine> lines;
  final OrderStatus status;

  /// The tags scanned out on this order. Empty when unknown: then a return matches by SKU only.
  final List<String> soldEpcs;

  /// Pieces already returned, per SKU.
  final Map<String, int> returned;

  /// Tags already returned on this order.
  final Set<String> returnedEpcs;

  /// Pieces that need a tag scanned.
  int get taggedQty => lines.where((l) => !l.exempt).fold(0, (sum, l) => sum + l.qty);

  int get totalQty => lines.fold(0, (sum, l) => sum + l.qty);

  /// Unscanned for too long: the customer may have walked out without the scan (the gate alarms).
  bool isLate(DateTime now, {Duration after = const Duration(minutes: 10)}) => now.difference(paidAt) > after;

  StoreHubOrder withStatus(OrderStatus s, {List<String>? soldEpcs}) => StoreHubOrder(
    refId: refId,
    invoiceNumber: invoiceNumber,
    storeId: storeId,
    registerId: registerId,
    paidAt: paidAt,
    lines: lines,
    status: s,
    soldEpcs: soldEpcs ?? this.soldEpcs,
    returned: returned,
    returnedEpcs: returnedEpcs,
  );

  /// The order after a return of [pieces] (SKU → pieces) on [epcs].
  StoreHubOrder withReturn(Map<String, int> pieces, Iterable<String> epcs) => StoreHubOrder(
    refId: refId,
    invoiceNumber: invoiceNumber,
    storeId: storeId,
    registerId: registerId,
    paidAt: paidAt,
    lines: lines,
    status: status,
    soldEpcs: soldEpcs,
    returned: {
      ...returned,
      for (final e in pieces.entries) e.key: (returned[e.key] ?? 0) + e.value,
    },
    returnedEpcs: {...returnedEpcs, ...epcs},
  );

  /// Pieces of [sku] that can still come back on this order (0 when it isn't on it).
  int returnableQty(String? sku) {
    final line = lines.where((l) => l.sku == sku && !l.exempt).firstOrNull;
    return line == null ? 0 : (line.qty - (returned[sku] ?? 0)).clamp(0, line.qty);
  }
}

/// Why a scanned tag can't go on this order. Null = it fits.
///
/// [sku] is the tag's SKU, [alreadyScanned] how many tags of that SKU are on the order so far.
String? rejectReason(StoreHubOrder order, String? sku, int alreadyScanned) {
  final line = order.lines.where((l) => l.sku == sku).firstOrNull;
  if (sku == null || line == null) return 'Not in this order';
  if (line.exempt) return 'This item needs no scan';
  if (alreadyScanned >= line.qty) return 'Order has only ${line.qty} of this';
  return null;
}

/// Why a scanned tag can't come back on this order. Null = it fits.
///
/// [sku] is the tag's SKU, [alreadyComing] how many pieces of that SKU are already coming back in
/// this return.
String? returnRejectReason(StoreHubOrder order, {required String epc, String? sku, required int alreadyComing}) {
  if (order.returnedEpcs.contains(epc)) return 'Already returned on this order';
  if (order.soldEpcs.isNotEmpty && !order.soldEpcs.contains(epc)) return 'Not sold on this order';
  final line = order.lines.where((l) => l.sku == sku && !l.exempt).firstOrNull;
  if (sku == null || line == null) return 'Not in this order';
  final left = order.returnableQty(sku);
  if (left == 0) return 'All ${line.qty} already returned';
  if (alreadyComing >= left) return 'Order has only $left of this to return';
  return null;
}

/// "2 min ago", "1 h 5 min ago".
String ageText(DateTime paidAt, DateTime now) {
  final m = now.difference(paidAt).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  final h = m ~/ 60;
  return m % 60 == 0 ? '$h h ago' : '$h h ${m % 60} min ago';
}
