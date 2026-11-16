import 'package:altai_pos/features/catalog/data/catalog_api.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:altai_pos/features/checkout/presentation/basket_screen.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/domain/exchange.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tag_reader.dart';

import 'returns_test.dart' show FakeTeam;

/// Tags starting with A are a Classic Tee (RM 49.90), with B a pair of jeans (RM 59.90).
class FakeApi implements CheckoutApi {
  @override
  Future<({List<Map<String, dynamic>> rows, int total})> storeTagPage(
    String storeId,
    int page, {
    int pageSize = 200,
  }) async => (rows: const <Map<String, dynamic>>[], total: 0);
  String? receiptNo;
  String? exchangeFor;

  @override
  Future<List<Map<String, dynamic>>> inspect(
    List<String> epcs, {
    void Function(Map<String, dynamic> tag)? onEach,
  }) async => [
    for (final epc in epcs)
      {
        'epc': epc,
        'found': true,
        'store_id': '12',
        'product_name': epc.startsWith('A') ? 'Classic Tee' : 'Slim Jeans',
        'sku': epc.startsWith('A') ? 'CT-BLK-M' : 'JN-32',
      },
  ];

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
    this.receiptNo = receiptNo;
    this.exchangeFor = exchangeFor;
    return '501';
  }

  @override
  Future<String?> findByRef(String storeId, String clientRef) async => null;

  @override
  Future<List<CheckoutSummary>> recent(String storeId, {DateTime? from, DateTime? to}) async => [];

  @override
  Future<CheckoutDetail> detail(String id) async => const CheckoutDetail(lines: []);

  @override
  Future<List<CheckoutSummary>> findByReceipt(String storeId, String receiptNo) async => [];
}

class FakeCatalog implements CatalogApi {
  @override
  Future<SkuInfo> lookup(String sku) async => SkuInfo(price: sku == 'CT-BLK-M' ? '49.90' : '59.90');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder textBox(String hintOrLabel) => find.byWidgetPredicate(
  (w) => w is TextField && (w.decoration?.hintText == hintOrLabel || w.decoration?.labelText == hintOrLabel),
);

void main() {
  final reader = FakeTagReader();
  test('the money that changes hands', () {
    String rm(int c) => formatRm(c);
    expect(exchangeDifferenceText(5990, 4990, rm), 'Customer pays RM 10.00 more on StoreHub');
    expect(exchangeDifferenceText(2990, 4990, rm), 'Refund RM 20.00 on StoreHub');
    expect(exchangeDifferenceText(4990, 4990, rm), 'No money changes hands');
  });

  test('the new items name the original receipt in their remark', () {
    final remark = CheckoutApi.remark('abc', 'Aina', receiptNo: 'SH-0020', exchangeFor: 'sh-0012');
    expect(remark, endsWith(' · rcpt SH-0020 · exch SH-0012 · ref abc'));
    final s = CheckoutSummary.fromTeam({'trxDate': '2026-11-05', 'remark': remark});
    expect(s.exchangeFor, 'SH-0012');
    expect(s.receipt, 'SH-0020');
    expect(s.cashier, 'Aina');
  });

  testWidgets('exchange: items back, then the new items on the same receipt', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeApi();
    final team = FakeTeam();
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: BasketScreen(
          tagReader: reader,
          api: api,
          returns: ReturnsApi(team.api),
          catalog: FakeCatalog(),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          onLogout: () {},
        ),
      ),
    );

    // Step 1: the return.
    await tester.tap(find.byTooltip('Exchange'));
    await tester.pumpAndSettle();
    expect(find.text('Exchange · 1 of 2: items back'), findsOneWidget);
    await tester.enterText(textBox('StoreHub receipt no., order no. or ID'), '0022607201446208');
    await scanWithReader(tester, reader, ['A2801160000000A1']);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong size'));
    await tester.pump();
    await tester.tap(find.text('Return & next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(team.calls, containsAll(['Stock/Adjustment', 'Stock/AdjustmentApproveNoScan']));

    // Step 2: back on checkout, for the new items.
    expect(find.text('Exchange · 2 of 2: new items'), findsOneWidget);
    await tester.tap(find.text('Same receipt'));
    await tester.pump();
    await scanWithReader(tester, reader, ['B2801160000000B1']);
    await tester.pumpAndSettle();
    expect(find.text('Customer pays RM 10.00 more on StoreHub'), findsOneWidget);

    await tester.tap(find.text('Confirm & submit'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Exchange: 1 pc already back in stock from receipt 0022607201446208'), findsOneWidget);
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(find.text('Good to go'), findsOneWidget);
    expect(find.text('Customer pays RM 10.00 more on StoreHub'), findsOneWidget);
    expect((api.receiptNo, api.exchangeFor), ('0022607201446208', '0022607201446208'));

    await tester.tap(find.text('Next customer'));
    await tester.pumpAndSettle();
    expect(find.text('Exchange · 2 of 2: new items'), findsNothing);
  });

  testWidgets('no exchange while the basket has items', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: BasketScreen(
          tagReader: reader,
          api: FakeApi(),
          returns: ReturnsApi(FakeTeam().api),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          onLogout: () {},
          askReceiptOnScan: false,
        ),
      ),
    );
    await scanWithReader(tester, reader, ['A2801160000000A1']);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Exchange'));
    await tester.pumpAndSettle();
    expect(find.text('Clear or complete this basket before starting an exchange.'), findsOneWidget);
    expect(find.text('Exchange · 1 of 2: items back'), findsNothing);
  });
}
