import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api_client.dart';
import '../../catalog/data/catalog_api.dart';
import '../../checkout/data/checkout_api.dart';
import '../../checkout/domain/basket.dart';
import '../data/returns_api.dart';

enum ReturnPhase {
  scanning, // adding items, receipt and reason
  sending, // waiting for the team's API
  done, // back in stock: refund on StoreHub
  retry, // no answer reached us: Try again first checks whether it was saved
  notApproved, // saved but not approved, so stock isn't back: Try again approves the same one
}

/// Why customers bring things back. Saved in the adjustment's remark.
const returnReasons = ['Wrong size', 'Defective', 'Changed mind', 'Other'];

/// What can stop a tag from being returned. A tag with a store is still in stock (never sold), so it
/// can't come back; a sold tag has no store.
BasketItem returnItemFromInspection(Map<String, dynamic> t) {
  final epc = t['epc'] as String;
  BasketItem item(ItemState state, [String? problem]) => BasketItem(epc,
      state: state,
      problem: problem,
      productName: t['product_name'] as String?,
      variation: t['variation'] as String?,
      sku: t['sku'] as String?);

  if (t['found'] == false) return item(ItemState.problem, 'Not registered to any product');
  if (t['found'] != true) return item(ItemState.problem, 'Could not check this tag');
  if (t['pending_transaction'] == true) {
    return item(ItemState.problem, 'Held by a pending transfer, count or adjustment');
  }
  if (t['store_id'] != null) {
    return item(
      ItemState.problem,
      "Still in stock at ${t['store_name'] ?? 'a store'}: it was never sold, so it can't be returned",
    );
  }
  return item(ItemState.ok);
}

/// The return on screen: items coming back, the receipt, the reason, and sending it.
///
/// Like checkout, it changes live stock, so it's careful: once sent, the items are frozen under one
/// client ref, and Try again never saves a second adjustment for the same return.
class ReturnController extends ChangeNotifier {
  ReturnController({
    required this.inspector,
    required this.api,
    required this.storeId,
    this.staffName = '',
    this.catalog,
    this.checkDelay = const Duration(milliseconds: 250),
  }) : _clientRef = newClientRef();

  static const maxItems = 200;

  final CheckoutApi inspector; // the same tag checks as checkout
  final ReturnsApi api;
  final String storeId;
  final String staffName;
  final CatalogApi? catalog;
  final Duration checkDelay;

  final Map<String, BasketItem> _items = {};

  /// Tags with no product, left out of this return.
  int ignoredUnknown = 0;
  final Map<String, SkuInfo> _info = {}; // sku → picture + team price
  String _clientRef;
  Timer? _timer;
  int _generation = 0; // answers for an older return are ignored

  ReturnPhase phase = ReturnPhase.scanning;
  String? message;
  String receiptNo = '';
  String? reason;
  String? trxId; // set once saved

  List<BasketItem> get items => _items.values.toList(growable: false);
  int get okCount => _items.values.where((i) => i.state == ItemState.ok).length;
  bool get isChecking => _items.values.any((i) => i.state == ItemState.checking);
  bool get hasProblems => _items.values.any((i) => i.state == ItemState.problem);

  /// What's still missing before it can be sent, in words for staff. Null when ready.
  String? get missing {
    if (_items.isEmpty) return 'Scan the items coming back.';
    if (isChecking) return 'Checking the items…';
    if (hasProblems) return 'Remove the red items to continue.';
    if (receiptNo.trim().isEmpty) return 'Enter or scan the receipt / order number.';
    if (reason == null) return 'Pick a reason.';
    return null;
  }

  bool get canSubmit => phase == ReturnPhase.scanning && missing == null;

  String? priceOf(BasketItem item) => item.sku == null ? null : _info[item.sku]?.price;
  String? imageOf(BasketItem item) => item.sku == null ? null : _info[item.sku]?.image;

  /// What to refund on StoreHub: the team's price of each item coming back, in cents.
  int get refundCents => _items.values
      .where((i) => i.state == ItemState.ok)
      .map((i) => toCents(priceOf(i)) ?? 0)
      .fold(0, (sum, c) => sum + c);

  /// Items coming back whose price is looked up but missing.
  int get unpricedCount => _items.values
      .where((i) => i.state == ItemState.ok && i.sku != null && _info.containsKey(i.sku) && priceOf(i) == null)
      .length;

  /// Tags left out of this return: no product behind them, or taken out by the cashier. The reader
  /// keeps reading while they're still on the pad, so they must not come back on the next round.
  final Set<String> _leftOut = {};

  void addText(String text) {
    if (phase != ReturnPhase.scanning) return;
    final parsed = parseTags(text);
    var added = 0;
    var full = false;
    for (final epc in parsed.epcs) {
      if (_items.containsKey(epc) || _leftOut.contains(epc)) continue;
      if (_items.length >= maxItems) {
        full = true;
        break;
      }
      _items[epc] = BasketItem(epc);
      added++;
    }
    message = full
        ? 'A return can hold $maxItems items.'
        : parsed.invalid > 0
            ? '${parsed.invalid} entry not recognised as a tag.'
            : null;
    if (added > 0) _scheduleCheck();
    notifyListeners();
  }

  void remove(String epc) {
    if (phase != ReturnPhase.scanning) return;
    if (_items.remove(epc) != null) _leftOut.add(epc); // still on the pad: don't read it back in
    message = null;
    notifyListeners();
  }

  void setReceipt(String value) {
    if (phase != ReturnPhase.scanning) return;
    receiptNo = value;
    notifyListeners();
  }

  void setReason(String value) {
    if (phase != ReturnPhase.scanning) return;
    reason = value;
    notifyListeners();
  }

  /// Empties the screen for the next return. Never reuses the old client ref.
  void reset() {
    _timer?.cancel();
    _generation++;
    _items.clear();
    _leftOut.clear();
    _info.clear();
    _clientRef = newClientRef();
    phase = ReturnPhase.scanning;
    message = null;
    receiptNo = '';
    reason = null;
    trxId = null;
    notifyListeners();
  }

  void _scheduleCheck() {
    _timer?.cancel();
    _timer = Timer(checkDelay, _checkItems);
  }

  Future<void> _checkItems() async {
    final generation = _generation;
    final waiting = [
      for (final i in _items.values)
        if (i.state == ItemState.checking) i.epc
    ];
    for (var i = 0; i < waiting.length; i += CheckoutApi.inspectLimit) {
      final end = (i + CheckoutApi.inspectLimit).clamp(0, waiting.length);
      final batch = waiting.sublist(i, end);
      try {
        final tags = await inspector.inspect(batch);
        if (generation != _generation) return;
        for (final t in tags) {
          if (t['found'] == false) {
            // No product behind this tag: not an item coming back, so it's left out.
            if (_items.remove(t['epc']) != null) {
              _leftOut.add(t['epc'] as String);
              ignoredUnknown++;
              message = '${ignoredUnknown == 1 ? '1 unknown tag' : '$ignoredUnknown unknown tags'} ignored (no product).';
            }
            continue;
          }
          final item = returnItemFromInspection(t);
          if (_items.containsKey(item.epc)) _items[item.epc] = item;
        }
      } on ApiException catch (e) {
        if (generation != _generation) return;
        if (e.sessionExpired) message = e.message;
        for (final epc in batch) {
          if (_items.containsKey(epc)) {
            _items[epc] = BasketItem(epc, state: ItemState.problem, problem: 'Could not check: ${e.message}');
          }
        }
      }
      notifyListeners();
    }
    if (generation == _generation) await _loadPrices();
  }

  Future<void> _loadPrices() async {
    final c = catalog;
    if (c == null) return;
    final skus = {
      for (final i in _items.values)
        if (i.state == ItemState.ok && i.sku != null && !_info.containsKey(i.sku)) i.sku!
    };
    for (final sku in skus) {
      try {
        _info[sku] = await c.lookup(sku);
      } on ApiException {
        _info[sku] = const SkuInfo(); // no price: staff read it off the receipt
      }
    }
    notifyListeners();
  }

  String get _remark => ReturnsApi.remark(
      receiptNo: receiptNo.trim(), reason: reason ?? '', staffName: staffName, clientRef: _clientRef);

  /// Saves the adjustment, then approves it. Try again after a problem picks up where it stopped.
  Future<void> submit() async {
    if (phase == ReturnPhase.scanning && !canSubmit) return;
    if (phase != ReturnPhase.scanning && phase != ReturnPhase.retry && phase != ReturnPhase.notApproved) return;
    final from = phase;
    phase = ReturnPhase.sending;
    message = null;
    notifyListeners();

    // Step 1: save (unless it's already saved).
    if (from != ReturnPhase.notApproved) {
      try {
        // After no answer the first save may have gone through: look for it before saving again.
        final found = from == ReturnPhase.retry ? await api.findByRef(storeId, _clientRef) : null;
        trxId = found ?? await api.save(storeId: storeId, epcs: _items.keys.toList(), remark: _remark);
      } on ApiException catch (e) {
        message = _markStillInStock(e.message) ?? e.message;
        // Refused: nothing saved, staff can fix it and send again. No answer: may be saved, check first.
        phase = e.noAnswer || (e.status ?? 0) >= 500 ? ReturnPhase.retry : ReturnPhase.scanning;
        notifyListeners();
        return;
      }
    }

    // Step 2: approve. This puts the stock back.
    try {
      await api.approve(trxId!, remark: _remark);
      phase = ReturnPhase.done;
    } on ApiException catch (e) {
      message = e.message;
      phase = e.noAnswer || (e.status ?? 0) >= 500 ? ReturnPhase.retry : ReturnPhase.notApproved;
    }
    notifyListeners();
  }

  /// The server refuses a return of a piece that is still in a store's stock ("EPC [..] is already
  /// assigned to Subang Jaya (GB1) - cannot adjust in again"): it was never sold, so it can't come
  /// back. Marks those pieces red and returns a message for the cashier; null if it's another error.
  String? _markStillInStock(String error) {
    final hits = RegExp(r'EPC \[([0-9A-Fa-f]+)\] is already assigned to (.+?)\s*-\s*cannot adjust in')
        .allMatches(error)
        .toList();
    if (hits.isEmpty) return null;
    for (final m in hits) {
      final epc = m.group(1)!.toUpperCase();
      final old = _items[epc];
      if (old == null) continue;
      _items[epc] = BasketItem(epc,
          state: ItemState.problem,
          problem: "Still in stock at ${m.group(2)}: it was never sold, so it can't be returned",
          productName: old.productName,
          variation: old.variation,
          sku: old.sku);
    }
    return '${hits.length == 1 ? '1 piece is' : '${hits.length} pieces are'} still in stock, so not sold. '
        'Remove the red ${hits.length == 1 ? 'one' : 'ones'} and submit again. Nothing was saved.';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
