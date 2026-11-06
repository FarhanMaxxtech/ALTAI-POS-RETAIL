/// One checkout from the team's Stock/CheckoutList, for the Recent screen.
class CheckoutSummary {
  const CheckoutSummary({required this.createdAt, this.id, this.trxId, this.remark, this.storeName});

  final DateTime createdAt;
  final String? id; // the record id, for Stock/CheckoutInfo
  final String? trxId; // the team's transaction number
  final String? remark; // "Altai POS · Aina · 14:32:05 · rcpt SH-0012 · ref …" for sales from this app
  final String? storeName;

  /// True when the time of day is known (not just the date).
  bool get hasTime => createdAt.hour != 0 || createdAt.minute != 0 || createdAt.second != 0;

  /// The list has no item count or time of day, only trxDate (a date, sometimes with a time).
  /// Sales from this app also carry the time in their remark, so the time comes from there.
  factory CheckoutSummary.fromTeam(Map<String, dynamic> j) => CheckoutSummary(
    createdAt: withRemarkTime(
      DateTime.tryParse(j['trxDate']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      j['remark']?.toString(),
    ),
    id: (j['id'] ?? j['trxId'])?.toString(),
    trxId: (j['trxId'] ?? j['id'])?.toString(),
    remark: j['remark']?.toString(),
    storeName: j['storeName']?.toString(),
  );

  /// Who rang it up, read back from our own remark. Null for sales made elsewhere.
  /// Older remarks have no time: "Altai POS · Aina · ref …".
  String? get cashier {
    final parts = remark?.split(' · ') ?? const [];
    if (parts.length < 3 || parts.first != 'Altai POS') return null;
    final name = parts[1];
    return _time.hasMatch(name) || name.startsWith('ref ') || name.startsWith('rcpt ') || name.startsWith('no rcpt')
        ? null
        : name;
  }

  /// The StoreHub receipt number, read back from our own remark. Null when there was none.
  String? get receipt {
    final parts = remark?.split(' · ') ?? const [];
    if (parts.isEmpty || parts.first != 'Altai POS') return null;
    for (final p in parts) {
      if (p.startsWith('rcpt ')) return p.substring(5);
    }
    return null;
  }

  /// For the new items of an exchange: the original sale's receipt. Null otherwise.
  String? get exchangeFor {
    for (final p in remark?.split(' · ') ?? const <String>[]) {
      if (p.startsWith('exch ')) return p.substring(5);
    }
    return null;
  }

  /// Why there was no receipt ("StoreHub offline"), or null.
  String? get noReceiptReason {
    for (final p in remark?.split(' · ') ?? const <String>[]) {
      if (p.startsWith('no rcpt: ')) return p.substring(9);
    }
    return null;
  }
}

final _time = RegExp(r'^(\d{2}):(\d{2}):(\d{2})$');

/// [date] with the time of day from our remark ("… · 14:32:05 · ref …"), when it has one.
DateTime withRemarkTime(DateTime date, String? remark) {
  if (date.hour != 0 || date.minute != 0 || date.second != 0) return date; // their date already has a time
  for (final part in remark?.split(' · ') ?? const <String>[]) {
    final m = _time.firstMatch(part);
    if (m != null) {
      return DateTime(date.year, date.month, date.day, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    }
  }
  return date;
}

/// One line of a recorded checkout: a SKU and how many pieces of it were sold.
class CheckoutLine {
  const CheckoutLine({required this.sku, required this.qty, this.productCode, this.productName, this.variation});

  final String sku;
  final int qty;
  final String? productCode;
  final String? productName;
  final String? variation; // "Black / M"

  factory CheckoutLine.fromTeam(Map<String, dynamic> j) => CheckoutLine(
    sku: j['sku']?.toString() ?? '-',
    qty: j['qty'] is num ? (j['qty'] as num).toInt() : int.tryParse(j['qty']?.toString() ?? '') ?? 0,
    productCode: j['productCode']?.toString(),
    productName: j['productName']?.toString(),
    variation: j['varLabel']?.toString(),
  );
}

/// A checkout with its item lines, from the team's Stock/CheckoutInfo.
class CheckoutDetail {
  const CheckoutDetail({required this.lines, this.trxId, this.remark, this.storeName, this.trxDate});

  final List<CheckoutLine> lines;
  final String? trxId;
  final String? remark;
  final String? storeName;
  final String? trxDate;

  int get totalQty => lines.fold(0, (sum, l) => sum + l.qty);

  factory CheckoutDetail.fromTeam(Map<String, dynamic> j) => CheckoutDetail(
    lines: (j['lines'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>().map(CheckoutLine.fromTeam).toList(),
    trxId: (j['trxId'] ?? j['id'])?.toString(),
    remark: j['remark']?.toString(),
    storeName: j['storeName']?.toString(),
    trxDate: j['trxDate']?.toString(),
  );
}
