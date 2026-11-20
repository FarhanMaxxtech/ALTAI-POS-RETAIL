import '../../../core/api_client.dart';
import '../../checkout/data/checkout_api.dart';

/// Where a saved return is. A resend with the same clientRef answers with the first one's.
enum ReturnSaved {
  pending, // saved, not approved yet: approve it
  approved, // already approved (stock already back): nothing more to do
  voided, // cancelled on the server: nothing back in stock
}

/// What Stock/Adjustment answered.
typedef SavedReturn = ({String trxId, ReturnSaved status});

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
  ///
  /// [receiptNo] is the ORIGINAL sale's StoreHub receipt, [reason] why it came back. [clientRef] is
  /// new for each return and the same when sending again after no answer: if the first one was
  /// saved, the team's API answers with it ("duplicate") and says whether it's approved already.
  ///
  /// [qtys] says how many pieces come back per SKU (the same "qtys" the handheld app sends). Without
  /// it a bundle tag puts back its whole "multiply by" (5 for a 5-piece tag), but a checkout takes
  /// out only 1 per tag, so stock would go up by more than was sold.
  Future<SavedReturn> save({
    required String storeId,
    required List<String> epcs,
    required String remark,
    required String clientRef,
    String receiptNo = '',
    String reason = '',
    Map<String, int> qtys = const {},
  }) async {
    final receipt = CheckoutApi.fit(CheckoutApi.cleanReceipt(receiptNo), 50);
    final why = CheckoutApi.fit(reason.trim(), 100);
    final res = await _api.post('Stock/Adjustment', {
      'storeId': storeId,
      'trxType': 'ADI',
      'trxDate': _day(DateTime.now()),
      'remark': remark,
      'epcs': epcs,
      'clientRef': clientRef,
      if (receipt.isNotEmpty) 'receiptNo': receipt,
      if (why.isNotEmpty) 'reason': why,
      if (qtys.isNotEmpty)
        'qtys': [
          for (final q in qtys.entries) {'sku': q.key, 'qty': q.value},
        ],
    });
    final trxId = res['trxId'] ?? res['id'];
    // Saved, but we can't tell which one: treated like no answer, so sending again settles it.
    if (trxId == null) throw ApiException('The server sent no transaction number.', status: 502);
    // Only a resend says where it is: "0" pending, "1"/"2" approved, "4" voided.
    final status = res['duplicate'] == true ? res['status']?.toString() : null;
    return (
      trxId: trxId.toString(),
      status: switch (status) {
        '1' || '2' => ReturnSaved.approved,
        '4' => ReturnSaved.voided,
        _ => ReturnSaved.pending,
      },
    );
  }

  /// Stock/AdjustmentApproveNoScan: this is what puts the pieces back in stock.
  Future<void> approve(String trxId, {required String remark}) =>
      _api.post('Stock/AdjustmentApproveNoScan', {'id': trxId, 'remark': remark});

  /// The free note saved with each return: "Altai POS return · Aina · 14:32:05". (The receipt, the
  /// reason and the ref have their own fields now.)
  static String remark(String staffName, {DateTime? at}) =>
      CheckoutApi.remark(staffName, at: at).replaceFirst('Altai POS', 'Altai POS return');

  /// 2026-11-03. The tablet's own date (it runs on Malaysia time).
  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
