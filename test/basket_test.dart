import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/checkout/domain/basket_controller.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:flutter_test/flutter_test.dart';

const tagA = 'E2801160000000A1';
const tagB = 'E2801160000000B2';

/// Stands in for the team's API. No network, so tests can't touch real stock.
class FakeApi implements CheckoutApi {
  final refs = <String>[];
  final receipts = <String>[]; // receipt no. or no-receipt reason sent with each checkout
  List<CheckoutSummary> earlier = []; // what findByReceipt finds
  final sentEpcs = <List<String>>[];
  Object? nextError;
  bool recordedDespiteError = false; // the send failed on our side but the team's API kept it
  String? recordedRef; // what findByRef will find
  int findCalls = 0;
  int inspectCalls = 0;
  Map<String, dynamic> Function(String epc) tag = (epc) => {
    'epc': epc,
    'found': true,
    'store_id': '12',
    'product_name': 'Classic Tee',
    'sku': 'CT',
    'pending_transaction': false,
  };

  @override
  Future<List<Map<String, dynamic>>> inspect(
    List<String> epcs, {
    void Function(Map<String, dynamic> tag)? onEach,
  }) async {
    inspectCalls++;
    return epcs.map(tag).toList();
  }

  @override
  Future<String> checkout({
    required String storeId,
    required String clientRef,
    required List<String> epcs,
    String staffName = '',
    String receiptNo = '',
    String noReceiptReason = '',
    String exchangeFor = '',
  }) async {
    refs.add(clientRef);
    receipts.add(receiptNo.isNotEmpty ? receiptNo : 'none: $noReceiptReason');
    sentEpcs.add(epcs);
    final e = nextError;
    if (e != null) {
      nextError = null;
      if (recordedDespiteError) recordedRef = clientRef;
      throw e;
    }
    recordedRef = clientRef;
    return '501';
  }

  @override
  Future<String?> findByRef(String storeId, String clientRef) async {
    findCalls++;
    return recordedRef == clientRef ? '501' : null;
  }

  @override
  Future<List<CheckoutSummary>> recent(String storeId, {DateTime? from, DateTime? to}) async => [];

  @override
  Future<CheckoutDetail> detail(String id) async => const CheckoutDetail(lines: []);

  @override
  Future<List<CheckoutSummary>> findByReceipt(String storeId, String receiptNo) async => earlier;
}

void main() {
  late FakeApi api;
  late BasketController basket;

  setUp(() {
    api = FakeApi();
    basket = BasketController(api: api, storeId: '12', checkDelay: Duration.zero)..setReceipt('SH-0001');
  });
  tearDown(() => basket.dispose());

  Future<void> scan(String text) async {
    basket.addText(text);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  test('parseTags cleans text, drops repeats and counts bad entries', () {
    final r = parseTags('e2801160000000a1\nE2801160000000A1, nope  E2801160000000B2');
    expect(r.epcs, [tagA, tagB]);
    expect(r.invalid, 1);
  });

  test('itemFromInspection explains why a piece cannot be sold', () {
    expect(itemFromInspection({'epc': tagA, 'found': false}, '12').problem, contains('Not registered'));
    expect(itemFromInspection({'epc': tagA, 'found': null}, '12').problem, contains('Could not check'));
    expect(
      itemFromInspection({'epc': tagA, 'found': true, 'store_id': '12', 'pending_transaction': true}, '12').problem,
      contains('pending'),
    );
    expect(
      itemFromInspection({'epc': tagA, 'found': true, 'store_id': '13', 'store_name': 'Pavilion'}, '12').problem,
      'Belongs to Pavilion',
    );
    expect(itemFromInspection({'epc': tagA, 'found': true, 'store_id': '12'}, '12').state, ItemState.ok);
  });

  test('a piece read many times counts once, and all pieces in a burst are checked together', () async {
    basket.addText(tagA);
    basket.addText(tagB);
    await scan(tagA);
    expect(basket.items.length, 2);
    expect(api.inspectCalls, 1);
    expect(basket.canComplete, isTrue);
  });

  test('a basket with a problem cannot be completed until the piece is removed', () async {
    api.tag = (epc) => {'epc': epc, 'found': epc == tagA, 'store_id': '12'};
    await scan('$tagA $tagB');
    expect(basket.canComplete, isFalse);
    await basket.complete();
    expect(api.refs, isEmpty);

    basket.remove(tagB);
    expect(basket.canComplete, isTrue);
    await basket.complete();
    expect(basket.phase, BasketPhase.done);
    expect(basket.trxId, '501');
    expect(api.sentEpcs.single, [tagA]);
  });

  test('no answer and not recorded: frozen, Try again checks, then sends the same ref', () async {
    await scan(tagA);
    api.nextError = ApiException('No Wi-Fi');
    await basket.complete();
    expect(basket.phase, BasketPhase.retry);

    await scan(tagB);
    expect(basket.items.length, 1, reason: 'the basket must not change while unconfirmed');

    await basket.complete();
    expect(api.findCalls, 1);
    expect(basket.phase, BasketPhase.done);
    expect(api.refs.length, 2);
    expect(api.refs[0], api.refs[1]);
  });

  test('no answer but recorded anyway: Try again finds it and never sends twice', () async {
    await scan(tagA);
    api.nextError = ApiException('The server took too long to answer.');
    api.recordedDespiteError = true;
    await basket.complete();
    expect(basket.phase, BasketPhase.retry);

    await basket.complete();
    expect(basket.phase, BasketPhase.done);
    expect(basket.trxId, '501');
    expect(api.refs.length, 1, reason: 'sending again would sell the same pieces twice');
  });

  test('refused by the team API: back to the basket, nothing recorded', () async {
    await scan(tagA);
    api.nextError = ApiException('Tag not in store', status: 200, refused: true);
    await basket.complete();
    expect(basket.phase, BasketPhase.scanning);
    expect(basket.message, 'Tag not in store');
    expect(basket.canComplete, isTrue);
  });

  test('next customer gets a new ref and an empty basket', () async {
    await scan(tagA);
    await basket.complete();
    basket.reset();
    expect(basket.items, isEmpty);
    expect(basket.receiptNo, isEmpty, reason: 'the next customer has their own receipt');
    basket.setReceipt('SH-0002');
    await scan(tagA);
    await basket.complete();
    expect(api.refs[0], isNot(api.refs[1]));
    expect(api.receipts, ['SH-0001', 'SH-0002']);
  });

  test('no receipt: Confirm stays off until a receipt or a reason is given', () async {
    basket.setReceipt('  ');
    await scan(tagA);
    expect(basket.canComplete, isFalse);
    expect(basket.missing, 'Enter or scan the StoreHub receipt number.');

    basket.setNoReceipt('StoreHub offline');
    expect(basket.canComplete, isTrue);
    await basket.complete();
    expect(api.receipts.single, 'none: StoreHub offline');
  });

  test('the remark carries the receipt, cleaned, and reads back', () {
    final remark = CheckoutApi.remark('abc', 'Aina', at: DateTime(2026, 11, 5, 9, 5, 1), receiptNo: ' sh 0012 ');
    expect(remark, 'Altai POS · Aina · 09:05:01 · rcpt SH0012 · ref abc');
    final s = CheckoutSummary.fromTeam({'trxDate': '2026-11-05', 'remark': remark});
    expect(s.receipt, 'SH0012');
    expect(s.cashier, 'Aina');

    final none = CheckoutApi.remark('abc', '', noReceiptReason: 'Receipt lost');
    final n = CheckoutSummary.fromTeam({'trxDate': '2026-11-05', 'remark': none});
    expect(n.receipt, isNull);
    expect(n.noReceiptReason, 'Receipt lost');
    expect(n.cashier, isNull);
  });
}
