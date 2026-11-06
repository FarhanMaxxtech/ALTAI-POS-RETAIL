import '../../../core/api_client.dart';

/// Customer returns, straight to the team's API.
///
/// Stock goes back through a Stock In adjustment (ADI, the same type the rfid_counter app's Stock In
/// uses): save it, then approve it. The refund itself is paid out on StoreHub.
///
/// Not confirmed by the team yet: try one item on a test merchant before staff use it.
class ReturnsApi {
  ReturnsApi(this._api);

  final ApiClient _api;

  /// Stock/Adjustment (ADI). Saves the return; stock doesn't change until [approve].
  /// Returns the team's transaction number.
  Future<String> save({required String storeId, required List<String> epcs, required String remark}) async {
    final res = await _api.post('Stock/Adjustment', {
      'storeId': storeId,
      'trxType': 'ADI',
      'trxDate': _day(DateTime.now()),
      'remark': remark,
      'epcs': epcs,
    });
    final trxId = res['trxId'] ?? res['id'];
    // Saved, but we can't tell which one: treated like no answer, so findByRef settles it.
    if (trxId == null) throw ApiException('The server sent no transaction number.', status: 502);
    return trxId.toString();
  }

  /// Stock/AdjustmentApproveNoScan: this is what puts the pieces back in stock.
  Future<void> approve(String trxId, {required String remark}) =>
      _api.post('Stock/AdjustmentApproveNoScan', {'id': trxId, 'remark': remark});

  /// The remark saved with each return: "Return · receipt R-1042 · Wrong size · Aina · ref 3f9c…".
  /// The ref lets [findByRef] tell later whether a return was saved.
  static String remark({
    required String receiptNo,
    required String reason,
    required String staffName,
    required String clientRef,
  }) =>
      [
        'Return',
        'receipt $receiptNo',
        reason,
        if (staffName.isNotEmpty) staffName,
        'ref $clientRef',
      ].join(' · ');

  /// After a return got no answer: was it saved anyway? Looks for its ref in today's and yesterday's
  /// adjustments. Returns its transaction number, or null if it isn't there.
  Future<String?> findByRef(String storeId, String clientRef) async {
    final now = DateTime.now();
    final res = await _api.get('Stock/AdjustmentList', {
      'storeId': storeId,
      'dateFrom': _day(now.subtract(const Duration(days: 1))),
      'dateTo': _day(now),
    });
    for (final r in (res['data'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>()) {
      if ((r['remark']?.toString() ?? '').contains('ref $clientRef')) {
        return (r['id'] ?? r['trxId']).toString(); // approve takes the record id
      }
    }
    return null;
  }

  /// 2026-11-03. The tablet's own date (it runs on Malaysia time).
  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
