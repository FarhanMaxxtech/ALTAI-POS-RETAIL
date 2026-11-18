import 'package:altai_pos/features/orders/data/orders_api.dart';
import 'package:altai_pos/features/orders/presentation/order_history_screen.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'basket_screen_test.dart' show FakeApi;
import 'returns_test.dart' show FakeTeam;
import 'support/fake_tag_reader.dart';

void main() {
  final now = DateTime(2026, 11, 17, 15, 0);
  late FakeOrdersApi orders;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    orders = FakeOrdersApi(clock: () => now, delay: Duration.zero);
    await tester.pumpWidget(MaterialApp(
      theme: altaiTheme(Brightness.light),
      home: OrderHistoryScreen(
        orders: orders,
        inspector: FakeApi(),
        returns: ReturnsApi(FakeTeam().api),
        storeId: '12',
        storeName: 'MidValley',
        staffName: 'Aina',
        tagReader: FakeTagReader(),
        clock: () => now,
      ),
    ));
    await tester.pumpAndSettle();
  }

  String receipt(String ref) => orders.all.firstWhere((o) => o.refId == ref).invoiceNumber;

  test('history: completed orders only, in the days asked, newest first', () async {
    final api = FakeOrdersApi(clock: () => now, delay: Duration.zero);
    final today = await api.history('12', from: DateTime(2026, 11, 17), to: DateTime(2026, 11, 17, 23, 59));
    expect(today.map((o) => o.refId), ['demo-done-3', 'demo-done-4']);
    final week = await api.history('12', from: DateTime(2026, 11, 11), to: DateTime(2026, 11, 17, 23, 59));
    expect(week, hasLength(4));
  });

  testWidgets('today by default; days, time of day and the last 4 digits filter it', (tester) async {
    await open(tester);
    expect(find.text('2 orders · 5 pieces'), findsOneWidget);
    expect(find.text(receipt('demo-done-3')), findsOneWidget);
    expect(find.text(receipt('demo-ref-1')), findsNothing); // not paid-and-scanned: not history

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    expect(find.text('4 orders · 9 pieces'), findsOneWidget);

    // Morning only: the 11:20 order, not the 13:48 one.
    await tester.tap(find.text('Any time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Morning (before 12:00)'));
    await tester.pumpAndSettle();
    expect(find.text(receipt('demo-done-4')), findsOneWidget);
    expect(find.text(receipt('demo-done-3')), findsNothing);

    // Back to any time, then the last 4 digits of one receipt.
    await tester.tap(find.text('00:00 – 11:59'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any time').last);
    await tester.pumpAndSettle();
    final r = receipt('demo-done-5');
    await tester.enterText(find.byKey(const ValueKey('top-search')), r.substring(12));
    await tester.pumpAndSettle();
    expect(find.text('1 order · 3 pieces'), findsOneWidget);
    expect(find.text(r), findsOneWidget);
  });

  testWidgets('Return opens the return screen with the order\'s receipt no. filled in', (tester) async {
    await open(tester);
    final r = receipt('demo-done-3');
    await tester.tap(find.descendant(of: find.byKey(ValueKey('order-$r')), matching: find.text('Return')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // no settling: the return screen reads
    expect(find.text('Return items'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('receipt-field'))).controller!.text, r);
  });

  testWidgets('tap an order: its items, with Return and Exchange', (tester) async {
    await open(tester);
    final r = receipt('demo-done-3');
    await tester.tap(find.text(r));
    await tester.pumpAndSettle();
    expect(find.text('Order $r'), findsOneWidget);
    expect(find.text('Slim Jeans'), findsOneWidget);
    expect(find.text('Exchange'), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Order $r'), findsNothing);
  });
}
