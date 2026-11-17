import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket_controller.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/domain/return_controller.dart';
import 'package:altai_pos/shared/reading_time.dart';
import 'package:flutter_test/flutter_test.dart';

import 'basket_test.dart' show FakeApi;
import 'returns_test.dart' show FakeTeam;

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
}
