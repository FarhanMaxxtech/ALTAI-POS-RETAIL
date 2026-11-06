import 'dart:convert';

import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/presentation/recent_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

const info = {
  'id': 501,
  'storeName': 'MidValley',
  'trxDate': '2026-11-03',
  'remark': 'Altai POS · Aina · ref abc',
  'lines': [
    {'sku': 'CT-BLK-M', 'productCode': 'CT', 'productName': 'Classic Tee', 'varLabel': 'Black / M', 'qty': 2},
    {'sku': 'JN-32', 'productCode': 'JN', 'productName': 'Slim Jeans', 'varLabel': '32', 'qty': '1'},
  ],
};

/// The team's API, faked: a list with one checkout, and its details.
CheckoutApi fakeApi({bool wrapped = false, List<String>? seen}) => CheckoutApi(ApiClient(
    client: MockClient((req) async {
      seen?.add(req.url.toString());
      if (req.url.path.endsWith('Stock/CheckoutList')) {
        return json({
          'data': [
            {'id': 501, 'trxDate': '2026-11-03', 'remark': 'Altai POS · Aina · ref abc'}
          ]
        });
      }
      return json(wrapped ? {'data': info} : info);
    }),
    baseUrl: 'https://team.test/rest',
    apiKey: 'test-key'));

void main() {
  test('reads the item lines of one checkout', () async {
    final seen = <String>[];
    final d = await fakeApi(seen: seen).detail('501');
    expect(seen.single, 'https://team.test/rest/Stock/CheckoutInfo?id=501');
    expect(d.lines.map((l) => '${l.productName} ${l.variation} ×${l.qty}'),
        ['Classic Tee Black / M ×2', 'Slim Jeans 32 ×1']);
    expect(d.totalQty, 3);
  });

  test('also reads an answer wrapped in { data }', () async {
    final d = await fakeApi(wrapped: true).detail('501');
    expect(d.lines, hasLength(2));
  });

  testWidgets('tap a recent checkout to see its items', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: RecentScreen(api: fakeApi(), storeId: '12', storeName: 'MidValley')));
    await tester.pumpAndSettle();
    expect(find.text('Transaction 501'), findsOneWidget);

    await tester.tap(find.text('Transaction 501'));
    await tester.pumpAndSettle();
    expect(find.text('Classic Tee'), findsOneWidget);
    expect(find.text('Black / M'), findsOneWidget);
    expect(find.text('× 2'), findsOneWidget);
    expect(find.text('Slim Jeans'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // total pieces
  });
}
