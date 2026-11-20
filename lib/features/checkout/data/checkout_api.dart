import '../../../core/api_client.dart';
import '../domain/checkout_summary.dart';

/// Tag checks and sales, straight to the team's API.
class CheckoutApi {
  CheckoutApi(this._api);

  final ApiClient _api;

  /// How many tags the basket checks in one go.
  static const inspectLimit = 50;

  /// TagLookup takes one tag per call, and a reader sends many at once: at most this many run together,
  /// so a scan burst doesn't flood their server (same limit as the rfid_counter app).
  static const _maxParallel = 5;

  /// Everything we can tell about each tag, in the order given:
  ///   - ONE Stock/EpcList call for the whole list: which store each tag is in
  ///   - Stock/TagLookup per tag: what it is, and whether an unfinished transfer/count/adjustment holds it
  /// Each map has `epc`, `found` (true, false = unknown tag, null = couldn't check), `sku`, `product_name`,
  /// `variation`, `store_id`, `store_name`, `pending_transaction` (see itemFromInspection).
  ///
  /// [onEach] gets each tag as soon as its own check is done, so the screen can show it straight away
  /// instead of waiting for the whole batch.
  Future<List<Map<String, dynamic>>> inspect(
    List<String> epcs, {
    void Function(Map<String, dynamic> tag)? onEach,
  }) async {
    final storeOf = <String, Map<String, dynamic>>{};
    final listCall = _api
        .post('Stock/EpcList', {
          'epc': '',
          'productName': '',
          'storeId': '',
          'page': 1,
          'pageSize': epcs.length,
          'epcs': epcs,
        })
        .then((res) {
          for (final r in (res['data'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) {
            storeOf[r['epc'].toString().toUpperCase()] = r;
          }
        })
        .catchError((Object e) {
          if (e is ApiException && e.sessionExpired) throw e;
          // Without it we still have TagLookup's store; a tag with no store at all is marked below.
        });

    // TagLookup usually knows the store too; only a tag without one waits for the list.
    Map<String, dynamic> withStore(Map<String, dynamic> t) => t['found'] == true
        ? {
            ...t,
            'store_id': t['store_id'] ?? _str(storeOf[t['epc']]?['storeId']),
            'store_name': t['store_name'] ?? storeOf[t['epc']]?['storeName'],
          }
        : t;

    final results = List<Map<String, dynamic>?>.filled(epcs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < epcs.length) {
        final i = next++;
        final t = await _lookup(epcs[i]);
        results[i] = t;
        if (onEach != null) {
          if (t['found'] == true && t['store_id'] == null) await listCall;
          onEach(withStore(t));
        }
      }
    }

    await Future.wait([listCall, for (var w = 0; w < _maxParallel && w < epcs.length; w++) worker()]);

    return [for (final t in results) withStore(t!)];
  }

  Future<Map<String, dynamic>> _lookup(String epc) async {
    try {
      final d = await _api.post('Stock/TagLookup', {'epc': epc});
      return {
        'epc': epc,
        'found': true,
        'sku': d['sku']?.toString(),
        'product_name': d['productName']?.toString(),
        'product_code': d['productCode']?.toString(),
        'variation': d['varLabel']?.toString(),
        'store_id': _str(d['currentStoreId'] ?? d['storeId']),
        'store_name': d['storeName']?.toString(),
        'pending_transaction': d['isPendingTransaction'] == true || d['isPending'] == true || d['pending'] == true,
        'multiplier': int.tryParse(d['multiplier']?.toString() ?? '') ?? 1,
      };
    } on ApiException catch (e) {
      if (e.sessionExpired) rethrow; // stops the whole check: staff must log in
      if (e.refused) return {'epc': epc, 'found': false}; // TagLookup answers { error } for an unknown tag
      // no_answer: no Wi-Fi or no internet, so the tag can be checked again later.
      return {'epc': epc, 'found': null, 'error': e.message, 'no_answer': e.noAnswer};
    }
  }

  /// One page of the store's tag list (Stock/EpcList by store): kept on the tablet by StoreTags.
  Future<({List<Map<String, dynamic>> rows, int total})> storeTagPage(String storeId, int page, {int pageSize = 200}) async {
    final res = await _api.post('Stock/EpcList', {
      'epc': '',
      'productName': '',
      'storeId': storeId,
      'page': page,
      'pageSize': pageSize,
    });
    final rows = (res['data'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final total = int.tryParse('${res['recordsTotal']}') ?? rows.length;
    return (rows: rows, total: total);
  }

  /// Stock/Checkout: records the sale and takes the tags out of the store's stock. Returns the team's
  /// transaction number.
  ///
  /// [receiptNo] is the StoreHub receipt of the sale, so the cross-check can match it with StoreHub;
  /// without one, [noReceiptReason] says why. For the new items of an exchange, [exchangeFor] is the
  /// ORIGINAL sale's receipt (StoreHub doesn't link the two). [clientRef] is new for each sale and the
  /// same when sending again after no answer: if the first one was saved after all, the team's API
  /// answers with that one ("duplicate") instead of selling the pieces twice.
  Future<String> checkout({
    required String storeId,
    required String clientRef,
    required List<String> epcs,
    String staffName = '',
    String receiptNo = '',
    String noReceiptReason = '',
    String exchangeFor = '',
  }) async {
    final receipt = fit(cleanReceipt(receiptNo), 50);
    final original = fit(cleanReceipt(exchangeFor), 50);
    final reason = fit(noReceiptReason.trim(), 100);
    final res = await _api.post('Stock/Checkout', {
      'storeId': storeId,
      'trxDate': _day(DateTime.now()),
      'remark': remark(staffName),
      'epcs': epcs,
      'clientRef': clientRef,
      if (receipt.isNotEmpty) 'receiptNo': receipt else if (reason.isNotEmpty) 'noReceiptReason': reason,
      if (original.isNotEmpty) 'exchangeReceiptNo': original,
    });
    final trxId = res['trxId'];
    // Recorded, but we can't show which transaction: treated like no answer, so sending again settles it.
    if (trxId == null) throw ApiException('The server sent no transaction number.', status: 502);
    return trxId.toString();
  }

  /// The free note saved with each sale: "Altai POS · Aina · 14:32:05". The time is there because the
  /// team's list only keeps the date. (The receipt, the reason and the ref have their own fields now.)
  static String remark(String staffName, {DateTime? at}) {
    final t = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      'Altai POS',
      if (staffName.isNotEmpty) staffName.replaceAll('·', ' '),
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
    ].join(' · ');
  }

  /// At most [max] characters: the team's API refuses a longer field.
  static String fit(String text, int max) => text.length <= max ? text : text.substring(0, max);

  /// "  sh-0012 " → "SH-0012". Spaces and the "·" separator are dropped, so it reads back cleanly.
  static String cleanReceipt(String receiptNo) =>
      receiptNo.replaceAll('·', '').replaceAll(RegExp(r'\s+'), '').toUpperCase();

  /// Earlier checkouts in this store (the last 30 days) on the same StoreHub receipt, newest first.
  Future<List<CheckoutSummary>> findByReceipt(String storeId, String receiptNo) async {
    final receipt = cleanReceipt(receiptNo);
    if (receipt.isEmpty) return const [];
    final now = DateTime.now();
    final rows = await _list(storeId, from: now.subtract(const Duration(days: 30)), to: now, receiptNo: receipt);
    return rows.map(CheckoutSummary.fromTeam).where((c) => c.receipt == receipt).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Checkouts in this store from [from] to [to] (whole days, default today and yesterday),
  /// newest first.
  Future<List<CheckoutSummary>> recent(String storeId, {DateTime? from, DateTime? to}) async {
    return (await _list(storeId, from: from, to: to)).map(CheckoutSummary.fromTeam).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Stock/CheckoutInfo: one checkout with the items in it.
  Future<CheckoutDetail> detail(String id) async {
    final res = await _api.get('Stock/CheckoutInfo', {'id': id});
    // Their answer is sometimes wrapped in { data: … }.
    final data = res['data'];
    return CheckoutDetail.fromTeam(data is Map<String, dynamic> ? data : res);
  }

  Future<List<Map<String, dynamic>>> _list(String storeId, {DateTime? from, DateTime? to, String? receiptNo}) async {
    final now = DateTime.now();
    final res = await _api.get('Stock/CheckoutList', {
      'storeId': storeId,
      'dateFrom': _day(from ?? now.subtract(const Duration(days: 1))),
      'dateTo': _day(to ?? now),
      'receiptNo': ?receiptNo,
    });
    return (res['data'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
  }

  /// 2026-11-03. The tablet's own date (it runs on Malaysia time).
  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String? _str(Object? v) => v == null || v.toString().isEmpty ? null : v.toString();
}
