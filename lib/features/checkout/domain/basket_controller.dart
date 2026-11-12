import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api_client.dart';
import '../data/checkout_api.dart';
import '../data/store_tags.dart';
import 'basket.dart';
import 'receipt_no.dart';
import 'checkout_summary.dart';
import '../../catalog/data/catalog_api.dart';
import '../../returns/domain/exchange.dart';

/// Why a sale has no StoreHub receipt. Saved in the remark instead of the receipt number.
const noReceiptReasons = ['StoreHub offline', 'Receipt lost', 'Staff purchase', 'Other'];

enum BasketPhase {
  scanning, // adding items
  sending, // waiting for the team's API
  done, // recorded
  retry, // no answer reached us: Try again first checks whether it was recorded, then sends
  uncertain, // may or may not be recorded: only a person can tell
}

/// The basket on screen: items, their checks, and sending it.
///
/// After [BasketPhase.retry] the basket is frozen. Its client ref may already be recorded, so the
/// tags under that ref must stay exactly as they were. The team's API has no "send once" guard, so
/// Try again looks for the client ref in today's checkouts before sending anything a second time.
class BasketController extends ChangeNotifier {
  BasketController({
    required this.api,
    required this.storeId,
    this.staffName = '',
    this.catalog,
    this.known,
    this.checkDelay = const Duration(milliseconds: 250),
    DateTime Function()? clock,
  }) : _clientRef = newClientRef(),
       _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const maxItems = 200;

  final CheckoutApi api;
  final String storeId;
  final String staffName; // saved in the remark of each sale
  final Duration checkDelay; // readers send tags in bursts, so wait and check them together
  /// The store's tags kept on the tablet (names shown at once). Null = none.
  final StoreTags? known;
  final CatalogApi? catalog;
  final Map<String, SkuInfo> _info = {}; // sku → picture + team price

  /// The picture of one item, or null.
  String? imageOf(BasketItem item) => item.sku == null ? null : _info[item.sku]?.image;

  final Map<String, BasketItem> _items = {};
  String _clientRef;
  Timer? _timer;
  int _generation = 0; // answers for an older basket are ignored

  BasketPhase phase = BasketPhase.scanning;
  String? message; // shown to the cashier
  String? trxId; // set when done

  /// The StoreHub receipt this sale belongs to: what joins it to the StoreHub sale.
  String receiptNo = '';

  /// Set instead of [receiptNo] when there's no receipt. Null = a receipt is expected.
  String? noReceiptReason;

  /// Set while this basket holds the new items of an exchange (step 2 of 2).
  ExchangeReturn? exchange;

  /// Starts step 2 of an exchange: the returned items are already back in stock.
  void startExchange(ExchangeReturn returned) {
    if (phase != BasketPhase.scanning || _items.isNotEmpty) return;
    exchange = returned;
    message = null;
    notifyListeners();
  }

  /// True when today's StoreHub sales can be searched, so the cashier may type only the last 4 digits.
  bool findByEnding = false;

  /// The last 4 digits typed, waiting for Find. Null otherwise.
  String? get receiptEnding {
    final no = receiptNo.replaceAll(RegExp(r'\s'), '');
    return findByEnding && noReceiptReason == null && RegExp(r'^\d{4}$').hasMatch(no) ? no : null;
  }

  /// Is the typed receipt no. a StoreHub one? See [checkReceiptNo].
  ({String? error, String? warning}) get receiptCheck {
    if (noReceiptReason != null) return (error: null, warning: null);
    if (receiptEnding case final end?) {
      return (error: "Tap Find to look up today's StoreHub sale ending in $end.", warning: null);
    }
    return checkReceiptNo(receiptNo, _clock());
  }

  bool get hasReceipt =>
      noReceiptReason != null || (CheckoutApi.cleanReceipt(receiptNo).isNotEmpty && receiptCheck.error == null);

  List<BasketItem> get items => _items.values.toList(growable: false);
  int get okCount => _items.values.where((i) => i.state == ItemState.ok).length;

  /// Pieces read and not refused: the count the cashier sees straight away, before the checks finish.
  int get pieceCount => _items.values.where((i) => i.state != ItemState.problem).length;
  int get checkingCount => _items.values.where((i) => i.state == ItemState.checking).length;
  bool get isChecking => _items.values.any((i) => i.state == ItemState.checking);
  bool get hasProblems => _items.values.any((i) => i.state == ItemState.problem);
  bool get canComplete =>
      phase == BasketPhase.scanning && _items.isNotEmpty && !isChecking && !hasProblems && hasReceipt;

  /// What still stops Confirm, in words for the cashier. Null when nothing does.
  String? get missing {
    if (_items.isEmpty) return null;
    if (hasProblems) return 'Remove or re-check the red tags to continue.';
    if (!hasReceipt) return receiptCheck.error ?? 'Enter the StoreHub receipt number.';
    return null;
  }

  void setReceipt(String value) {
    if (phase != BasketPhase.scanning) return; // a frozen basket keeps the receipt it was sent with
    receiptNo = value;
    notifyListeners();
  }

  /// [reason] from [noReceiptReasons], or null to go back to entering a receipt.
  void setNoReceipt(String? reason) {
    if (phase != BasketPhase.scanning) return;
    noReceiptReason = reason;
    if (reason != null) receiptNo = '';
    notifyListeners();
  }

  /// Earlier sales on the same receipt (today and yesterday), so staff can tell a second scan of
  /// the same receipt from more items for it. Empty when there's no receipt.
  Future<List<CheckoutSummary>> earlierOnReceipt() =>
      noReceiptReason != null ? Future.value(const []) : api.findByReceipt(storeId, receiptNo);

  /// The team's price of one item, or null if there's no price (or it isn't loaded yet).
  String? priceOf(BasketItem item) => item.sku == null ? null : _info[item.sku]?.price;

  /// True once the price of this item has been looked up (even if there was none).
  bool priceLoaded(BasketItem item) => item.sku != null && (catalog == null || _info.containsKey(item.sku));

  /// Total of the ready items that have a price, in cents.
  int get totalCents => _items.values
      .where((i) => i.state == ItemState.ok)
      .map((i) => toCents(priceOf(i)) ?? 0)
      .fold(0, (sum, c) => sum + c);

  /// Ready items whose price is looked up but missing.
  int get unpricedCount =>
      _items.values.where((i) => i.state == ItemState.ok && priceLoaded(i) && priceOf(i) == null).length;

  /// Tags with no product behind them, left out of this basket for good: the reader keeps reading
  /// them while they're on the pad, so they must not come back on the next round.
  final Set<String> _leftOut = {};

  /// Tags the cashier removed, with how many reader rounds in a row each one has been missing. Still
  /// on the pad (read every round), a removed item stays out. Taken away for [comeBackAfter] rounds
  /// (about 2 seconds) and then read again, it's added back: the customer wants it after all.
  final Map<String, int> _removed = {};
  static const comeBackAfter = 3;

  /// One round of the USB reader: [epcs] is all it read this round, maybe nothing.
  void readRound(List<String> epcs) {
    final seen = parseTags(epcs.join(' ')).epcs.toSet();
    for (final epc in _removed.keys.toList()) {
      final missing = _removed[epc]!;
      if (!seen.contains(epc)) {
        _removed[epc] = missing + 1; // not on the pad this round
      } else if (missing >= comeBackAfter) {
        _removed.remove(epc); // it was away, now it's back: read it in again
      } else {
        _removed[epc] = 0; // still on the pad
      }
    }
    if (seen.isNotEmpty) addText(epcs.join(' '));
  }

  /// Text from the reader or a paste. Tags already in the basket are ignored, so a piece read
  /// several times by the pad still counts once.
  void addText(String text) {
    if (phase != BasketPhase.scanning) return;
    final parsed = parseTags(text);
    var added = 0;
    var full = false;
    for (final epc in parsed.epcs) {
      if (_items.containsKey(epc) || _leftOut.contains(epc) || _removed.containsKey(epc)) continue;
      if (_items.length >= maxItems) {
        full = true;
        break;
      }
      // A tag the store's list knows shows its name at once; the check below still decides.
      final k = known?[epc];
      _items[epc] = BasketItem(
        epc,
        productName: k?.productName,
        productCode: k?.productCode,
        variation: k?.variation,
        sku: k?.sku,
      );
      added++;
    }
    // The reader reads the same items every round: only something new replaces the message, so an
    // error ("can't be checked out on its own", unknown tags) stays until the cashier sees it.
    if (full) {
      message = 'A basket can hold $maxItems items.';
    } else if (parsed.invalid > 0) {
      message = '${parsed.invalid} entry not recognised as a tag.';
    } else if (added > 0) {
      message = null;
    }
    if (added > 0) {
      _scheduleCheck();
      if (known != null) _loadCatalog();
    }
    notifyListeners();
  }

  void remove(String epc) {
    if (phase != BasketPhase.scanning) return;
    if (_items.remove(epc) != null) _removed[epc] = 0; // still on the pad: don't read it back in yet
    message = null;
    notifyListeners();
  }

  /// Empties the screen for the next customer. Never reuses the old client ref.
  void reset() {
    _timer?.cancel();
    _generation++;
    _items.clear();
    _leftOut.clear();
    _removed.clear();
    _info.clear();
    _loading.clear();
    _clientRef = newClientRef();
    ignoredUnknown = 0;
    phase = BasketPhase.scanning;
    message = null;
    trxId = null;
    receiptNo = '';
    noReceiptReason = null;
    exchange = null;
    notifyListeners();
  }

  void recheck() {
    if (phase != BasketPhase.scanning) return;
    for (final item in items) {
      if (item.state == ItemState.problem) _items[item.epc] = BasketItem(item.epc);
    }
    message = null;
    _scheduleCheck();
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
        if (i.state == ItemState.checking) i.epc,
    ];
    for (var i = 0; i < waiting.length; i += CheckoutApi.inspectLimit) {
      final end = (i + CheckoutApi.inspectLimit).clamp(0, waiting.length);
      final batch = waiting.sublist(i, end);
      try {
        // Each tag shows as soon as it's checked; the full list at the end catches any left.
        final tags = await api.inspect(
          batch,
          onEach: (t) {
            if (generation != _generation) return;
            _apply(t);
            notifyListeners();
            _loadCatalog();
          },
        );
        if (generation != _generation) return;
        tags.forEach(_apply);
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
    if (generation == _generation) await _loadCatalog();
  }

  void _apply(Map<String, dynamic> t) {
    final epc = t['epc'] as String;
    if (_items[epc]?.state != ItemState.checking) return;
    if (t['found'] == false) {
      // No product behind this tag (a loose or test tag): not an item, so it's left out.
      _items.remove(epc);
      _leftOut.add(epc);
      ignoredUnknown++;
      message = '${ignoredUnknown == 1 ? '1 unknown tag' : '$ignoredUnknown unknown tags'} ignored (no product).';
      return;
    }
    _items[epc] = itemFromInspection(t, storeId);
  }

  /// Tags with no product, left out of this basket.
  int ignoredUnknown = 0;

  final Set<String> _loading = {}; // SKUs whose picture + price are on the way

  /// Fetches picture + team price for each ready SKU not looked up yet, all at once, as soon as the
  /// SKU is known (not after the whole basket is checked).
  Future<void> _loadCatalog() async {
    final c = catalog;
    if (c == null) return;
    final generation = _generation;
    final skus = {
      for (final i in _items.values)
        // Ready items, and still-checking ones the store's list already named: the price is there when the check ends.
        if (i.state != ItemState.problem && i.sku != null && !_info.containsKey(i.sku) && !_loading.contains(i.sku)) i.sku!,
    };
    _loading.addAll(skus);
    await Future.wait([
      for (final sku in skus)
        c.lookup(sku).catchError((Object _) => const SkuInfo()).then((info) {
          _loading.remove(sku);
          if (generation != _generation) return;
          _info[sku] = info; // no picture/price is fine, the sale still goes on
          notifyListeners();
        }),
    ]);
  }

  Future<void> complete() async {
    if (phase == BasketPhase.scanning && !canComplete) return;
    if (phase != BasketPhase.scanning && phase != BasketPhase.retry) return;
    final again = phase == BasketPhase.retry;
    phase = BasketPhase.sending;
    message = null;
    notifyListeners();

    try {
      if (again) {
        // The first send got no answer. If it was recorded anyway, sending again would sell the
        // same pieces twice, so look for it first.
        final found = await api.findByRef(storeId, _clientRef);
        if (found != null) {
          trxId = found;
          phase = BasketPhase.done;
          notifyListeners();
          return;
        }
      }
      trxId = await api.checkout(
        storeId: storeId,
        clientRef: _clientRef,
        epcs: _items.keys.toList(),
        staffName: staffName,
        receiptNo: receiptNo,
        noReceiptReason: noReceiptReason ?? '',
        exchangeFor: exchange?.receiptNo ?? '',
      );
      phase = BasketPhase.done;
    } on ApiException catch (e) {
      _handleFailure(e);
    }
    notifyListeners();
  }

  void _handleFailure(ApiException e) {
    message = checkoutErrorForCashier(e.message);
    if (e.noAnswer || (e.status ?? 0) >= 500) {
      phase = BasketPhase.retry; // may or may not be recorded: Try again checks first
    } else {
      // Refused, session expired or no API key: stock unchanged, staff can fix it and send again.
      phase = BasketPhase.scanning;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
