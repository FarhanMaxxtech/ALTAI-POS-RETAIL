import 'dart:convert';

import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:altai_pos/features/checkout/presentation/recent_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

void main() {
  test('the remark carries the time; the list only has the date', () {
    final s = CheckoutSummary.fromTeam(
        {'id': 1, 'trxDate': '2026-11-03', 'remark': CheckoutApi.remark('abc', 'Aina', at: DateTime(2026, 11, 3, 14, 32, 5))});
    expect(s.remark, 'Altai POS · Aina · 14:32:05 · ref abc');
    expect(s.createdAt, DateTime(2026, 11, 3, 14, 32, 5));
    expect(s.hasTime, isTrue);
    expect(s.cashier, 'Aina');
  });

  test('older remarks without a time still give the cashier, and no time', () {
    final s = CheckoutSummary.fromTeam({'id': 1, 'trxDate': '2026-11-03', 'remark': 'Altai POS · Aina · ref abc'});
    expect(s.cashier, 'Aina');
    expect(s.hasTime, isFalse);
  });

  test('a sale with no cashier name has no cashier', () {
    expect(CheckoutSummary.fromTeam({'remark': CheckoutApi.remark('abc', '')}).cashier, isNull);
  });

  testWidgets('filters by cashier and searches transaction no.', (tester) async {
    final seen = <Uri>[];
    final api = CheckoutApi(ApiClient(
        client: MockClient((req) async {
          seen.add(req.url);
          return json({
            'data': [
              {'id': 501, 'trxDate': '2026-11-03', 'remark': 'Altai POS · Aina · 14:32:05 · ref a'},
              {'id': 502, 'trxDate': '2026-11-03', 'remark': 'Altai POS · Ben · 15:01:00 · ref b'},
              {'id': 613, 'trxDate': '2026-11-03', 'remark': 'Altai POS · Aina · 16:10:00 · ref c'},
            ]
          });
        }),
        baseUrl: 'https://team.test/rest',
        apiKey: 'test-key'));
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(MaterialApp(
        theme: altaiTheme(Brightness.light), home: RecentScreen(api: api, storeId: '12', storeName: 'MidValley')));
    await tester.pumpAndSettle();
    expect(find.text('3 checkouts shown'), findsOneWidget);
    expect(find.text('16:10:00'), findsOneWidget);
    // Today only by default.
    expect(seen.single.queryParameters['dateFrom'], seen.single.queryParameters['dateTo']);

    await tester.tap(find.text('All cashiers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ben').last);
    await tester.pumpAndSettle();
    expect(find.text('1 checkout shown'), findsOneWidget);
    expect(find.text('Transaction 502'), findsOneWidget);

    await tester.tap(find.text('Ben').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All cashiers').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '61');
    await tester.pumpAndSettle();
    expect(find.text('1 checkout shown'), findsOneWidget);
    expect(find.text('Transaction 613'), findsOneWidget);

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    expect(seen.last.queryParameters['dateFrom'], isNot(seen.last.queryParameters['dateTo']));
  });
}
