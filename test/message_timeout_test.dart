import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/checkout/domain/basket_controller.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/domain/return_controller.dart';
import 'package:altai_pos/shared/reading_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'basket_test.dart' show FakeApi;
import 'returns_test.dart' show FakeTeam, json;

const tag = 'E2801160000000A1';

/// Lets the check timer fire and its answers arrive.
Future<void> tick(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

// testWidgets runs on a fake clock, so tester.pump(...) moves time on without waiting.
void main() {
  test('short messages stay about 5 s, long ones longer, never over 12 s', () {
    expect(readingTime('Done.'), const Duration(seconds: 5));
    expect(readingTime('x' * 100), const Duration(seconds: 10));
    expect(readingTime('x' * 500), const Duration(seconds: 12));
  });

  testWidgets('checkout: an error goes away by itself once there was time to read it', (tester) async {
    final b = BasketController(api: FakeApi(), storeId: '12');
    b.message = 'A basket can hold 200 items.';
    await tester.pump(const Duration(seconds: 4));
    expect(b.message, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    expect(b.message, isNull);
    b.dispose();
  });

  testWidgets('checkout: the same error again does not keep it up longer; a new one starts over', (tester) async {
    final b = BasketController(api: FakeApi(), storeId: '12');
    b.message = '1 unknown tag ignored (no product).';
    await tester.pump(const Duration(seconds: 4));
    b.message = '1 unknown tag ignored (no product).';
    await tester.pump(const Duration(seconds: 3));
    expect(b.message, isNull);
    b.message = '2 unknown tags ignored (no product).';
    await tester.pump(const Duration(seconds: 4));
    expect(b.message, isNotNull);
    b.dispose();
  });

  testWidgets('checkout: on the Try again screen the message stays', (tester) async {
    final b = BasketController(api: FakeApi(), storeId: '12');
    b.phase = BasketPhase.retry;
    b.message = 'No answer from the server.';
    await tester.pump(const Duration(seconds: 30));
    expect(b.message, 'No answer from the server.');
    b.dispose();
  });

  testWidgets('return: an error goes away by itself, but stays on the Try again screen', (tester) async {
    final team = FakeTeam();
    final r = ReturnController(inspector: CheckoutApi(team.api), api: ReturnsApi(team.api), storeId: '12');
    r.message = 'A return can hold 200 items.';
    await tester.pump(const Duration(seconds: 7));
    expect(r.message, isNull);

    r.phase = ReturnPhase.retry;
    r.message = 'No answer from the server.';
    await tester.pump(const Duration(seconds: 30));
    expect(r.message, 'No answer from the server.');
    r.dispose();
  });

  testWidgets('checkout: a red item from another store goes away by itself and stays out while on the pad',
      (tester) async {
    final api = FakeApi()
      ..tag = (epc) => {'epc': epc, 'found': true, 'store_id': '99', 'store_name': 'Bukit Bintang', 'sku': 'CT'};
    final b = BasketController(api: api, storeId: '12', checkDelay: Duration.zero);
    b.readRound([tag]);
    await tick(tester);
    expect(b.items.single.state, ItemState.problem);
    await tester.pump(const Duration(seconds: 4));
    expect(b.items, hasLength(1)); // still there to read
    await tester.pump(const Duration(seconds: 8));
    expect(b.items, isEmpty);
    b.readRound([tag]); // still on the pad
    await tick(tester);
    expect(b.items, isEmpty);
    b.dispose();
  });

  testWidgets('checkout: no internet shows the notice, items wait and are checked once it is back',
      (tester) async {
    final api = FakeApi();
    final normal = api.tag;
    api.tag = (epc) => {'epc': epc, 'found': null, 'error': 'Could not reach the server.', 'no_answer': true};
    final b = BasketController(api: api, storeId: '12', checkDelay: Duration.zero);
    b.readRound([tag]);
    await tick(tester);
    expect(b.offline, isTrue);
    expect(b.items.single.state, ItemState.checking); // no red row
    api.tag = normal; // Wi-Fi back
    await tester.pump(const Duration(seconds: 3));
    expect(b.offline, isFalse);
    expect(b.items.single.state, ItemState.ok);
    b.dispose();
  });

  testWidgets('return: a piece still in stock goes away by itself', (tester) async {
    final team = FakeTeam()
      ..override = (path) => path == 'Stock/TagLookup'
          ? json({'sku': 'CT', 'productName': 'Classic Tee', 'storeId': '12', 'storeName': 'Subang Jaya'})
          : null;
    final r = ReturnController(
        inspector: CheckoutApi(team.api), api: ReturnsApi(team.api), storeId: '12', checkDelay: Duration.zero);
    r.readRound([tag]);
    await tick(tester);
    expect(r.items.single.state, ItemState.problem);
    await tester.pump(const Duration(seconds: 13));
    expect(r.items, isEmpty);
    r.dispose();
  });

  testWidgets('return: no internet shows the notice, items wait and are checked once it is back',
      (tester) async {
    final team = FakeTeam();
    var wifi = false;
    team.override = (path) => wifi ? null : throw http.ClientException('no Wi-Fi');
    final r = ReturnController(
        inspector: CheckoutApi(team.api), api: ReturnsApi(team.api), storeId: '12', checkDelay: Duration.zero);
    r.readRound([tag]);
    await tick(tester);
    expect(r.offline, isTrue);
    expect(r.items.single.state, ItemState.checking);
    wifi = true;
    await tester.pump(const Duration(seconds: 3));
    expect(r.offline, isFalse);
    expect(r.items.single.state, ItemState.ok);
    r.dispose();
  });
}
