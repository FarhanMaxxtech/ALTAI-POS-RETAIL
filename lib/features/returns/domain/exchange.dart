/// What an exchange's first step (the return) hands to the checkout that follows.
///
/// On StoreHub an exchange is a refund on the original receipt plus a new sale, so the checkout asks
/// for the new sale's receipt and keeps this one in its remark ("exch R-1042") to link the two.
class ExchangeReturn {
  const ExchangeReturn({
    required this.receiptNo,
    required this.pieces,
    required this.refundCents,
    required this.trxId,
    this.items = const [],
  });

  final String receiptNo; // the original sale's receipt, as entered
  final int pieces; // items back in stock
  final int refundCents; // their team price; 0 when prices aren't shown
  final String trxId; // the return's adjustment

  /// What came back, one entry per SKU: shown next to the new items in step 2.
  final List<ExchangeItem> items;
}

/// One SKU that came back in an exchange.
class ExchangeItem {
  const ExchangeItem({required this.name, required this.pieces, this.variation, this.sku, this.cents});

  final String name;
  final String? variation;
  final String? sku;
  final int pieces;
  final int? cents; // all its pieces, at the team price; null = no price
}

/// "Customer pays RM 30.00 more on StoreHub" / "Refund RM 20.00 on StoreHub" / "No money changes hands".
/// [formatRm] turns cents into "30.00".
String exchangeDifferenceText(int newCents, int refundCents, String Function(int cents) formatRm) {
  final diff = newCents - refundCents;
  if (diff > 0) return 'Customer pays RM ${formatRm(diff)} more on StoreHub';
  if (diff < 0) return 'Refund RM ${formatRm(-diff)} on StoreHub';
  return 'No money changes hands';
}
