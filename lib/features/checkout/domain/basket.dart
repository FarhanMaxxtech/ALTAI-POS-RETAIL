import 'dart:math';

/// Plain rules for a basket of tagged pieces. No Flutter and no HTTP here, so it's easy to test.

enum ItemState { checking, ok, problem }

/// One physical piece, identified by its RFID tag.
class BasketItem {
  const BasketItem(
    this.epc, {
    this.state = ItemState.checking,
    this.productName,
    this.productCode,
    this.variation,
    this.sku,
    this.problem,
  });

  final String epc;
  final ItemState state;
  final String? productName;
  final String? productCode; // the same for every colour and size of one product
  final String? variation;
  final String? sku;

  /// Why it can't be sold, in words for the cashier.
  final String? problem;
}

final _epcPattern = RegExp(r'^[0-9A-F]{8,64}$');

/// Splits what the reader typed or staff pasted into clean tags.
/// Returns the good tags (upper-case, no repeats) and how many pieces of text weren't tags.
({List<String> epcs, int invalid}) parseTags(String text) {
  final epcs = <String>{};
  var invalid = 0;
  for (final part in text.split(RegExp(r'[\s,;]+'))) {
    if (part.isEmpty) continue;
    final epc = part.toUpperCase();
    if (_epcPattern.hasMatch(epc)) {
      epcs.add(epc);
    } else {
      invalid++;
    }
  }
  return (epcs: epcs.toList(), invalid: invalid);
}

/// What the tablet learned about a tag, from the backend's tag inspector.
BasketItem itemFromInspection(Map<String, dynamic> t, String storeId) {
  final epc = t['epc'] as String;
  BasketItem problem(String text) => BasketItem(
    epc,
    state: ItemState.problem,
    problem: text,
    productName: t['product_name'] as String?,
    productCode: t['product_code'] as String?,
    variation: t['variation'] as String?,
    sku: t['sku'] as String?,
  );

  if (t['found'] == false) return problem('Not registered to any product');
  if (t['found'] != true) {
    return problem(t['error'] == null ? 'Could not check this tag' : 'Could not check: ${t['error']}');
  }
  if (t['pending_transaction'] == true) {
    return problem('Held by a pending transfer, count or adjustment');
  }
  final tagStore = t['store_id'] as String?;
  if (tagStore == null) return problem('Not in any store: probably already sold');
  if (tagStore != storeId) {
    return problem('Belongs to ${t['store_name'] ?? 'another store'}');
  }
  return BasketItem(
    epc,
    state: ItemState.ok,
    productName: t['product_name'] as String?,
    productCode: t['product_code'] as String?,
    variation: t['variation'] as String?,
    sku: t['sku'] as String?,
  );
}

/// A random id for one basket. The backend uses it to make sure a basket is recorded only once.
String newClientRef([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// "49.90" → 4990. Done with text, not floats, so no rounding errors.
/// Returns null when there's no price.
int? toCents(String? price) {
  if (price == null) return null;
  final parts = price.split('.');
  final ringgit = int.tryParse(parts[0]);
  if (ringgit == null) return null;
  final sen = parts.length > 1 ? int.tryParse(parts[1].padRight(2, '0').substring(0, 2)) ?? 0 : 0;
  return ringgit * 100 + sen;
}

/// 4990 → "49.90"
String formatRm(int cents) => '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
