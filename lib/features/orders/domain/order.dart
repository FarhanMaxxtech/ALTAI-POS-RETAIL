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
  });

  final String refId; // StoreHub's unique id, used to avoid duplicates
  final String invoiceNumber; // the receipt number the customer gets
  final String storeId; // our store
  final String registerId;
  final DateTime paidAt; // Malaysia time
  final List<OrderLine> lines;
  final OrderStatus status;

  /// Pieces that need a tag scanned.
  int get taggedQty => lines.where((l) => !l.exempt).fold(0, (sum, l) => sum + l.qty);

  int get totalQty => lines.fold(0, (sum, l) => sum + l.qty);

  /// Unscanned for too long: the customer may have walked out without the scan (the gate alarms).
  bool isLate(DateTime now, {Duration after = const Duration(minutes: 10)}) => now.difference(paidAt) > after;

  StoreHubOrder withStatus(OrderStatus s) => StoreHubOrder(
    refId: refId,
    invoiceNumber: invoiceNumber,
    storeId: storeId,
    registerId: registerId,
    paidAt: paidAt,
    lines: lines,
    status: s,
  );
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

/// "2 min ago", "1 h 5 min ago".
String ageText(DateTime paidAt, DateTime now) {
  final m = now.difference(paidAt).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  final h = m ~/ 60;
  return m % 60 == 0 ? '$h h ago' : '$h h ${m % 60} min ago';
}
