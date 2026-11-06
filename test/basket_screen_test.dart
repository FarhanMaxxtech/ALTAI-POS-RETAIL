import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:altai_pos/features/checkout/presentation/basket_screen.dart';
import 'package:altai_pos/features/orders/data/orders_api.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tag_reader.dart';

class FakeApi implements CheckoutApi {
  @override
  Future<({List<Map<String, dynamic>> rows, int total})> storeTagPage(
    String storeId,
    int page, {
    int pageSize = 200,
  }) async => (rows: const <Map<String, dynamic>>[], total: 0);
  Object? nextError;
  int sends = 0;

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
        'product_name': 'Classic Tee',
        'variation': 'Black / M',
        'sku': 'CT-BLK-M',
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
    sends++;
    final e = nextError;
    if (e != null) {
      nextError = null;
      throw e;
    }
    return '501';
  }

  @override
  Future<String?> findByRef(String storeId, String clientRef) async => null; // the failed send wasn't kept

  @override
  Future<List<CheckoutSummary>> recent(String storeId, {DateTime? from, DateTime? to}) async => [];

  @override
  Future<CheckoutDetail> detail(String id) async => const CheckoutDetail(lines: []);

  List<CheckoutSummary> earlier = []; // what findByReceipt finds

  @override
  Future<List<CheckoutSummary>> findByReceipt(String storeId, String receiptNo) async => earlier;
}

Finder textBox(String hintOrLabel) => find.byWidgetPredicate(
  (w) => w is TextField && (w.decoration?.hintText == hintOrLabel || w.decoration?.labelText == hintOrLabel),
);

void main() {
  final reader = FakeTagReader();
  late FakeApi api;

  setUp(() => api = FakeApi());

  Future<void> open(WidgetTester tester, {bool ask = false, OrdersApi? orders}) => tester.pumpWidget(
    MaterialApp(
      theme: altaiTheme(Brightness.light),
      home: BasketScreen(
          tagReader: reader,
        api: api,
        storeId: '12',
        storeName: 'MidValley',
        staffName: 'Aina',
        onLogout: () {},
        askReceiptOnScan: ask,
        orders: orders,
      ),
    ),
  );

  Future<void> scan(WidgetTester tester, String epc) async {
    await scanWithReader(tester, reader, [epc]);
    await tester.pump();
  }

  Future<void> receipt(WidgetTester tester, String no) async {
    await tester.enterText(textBox('StoreHub receipt no.'), no);
    await tester.pump();
  }

  // Confirm opens the last-look dialog; Submit there records the sale.
  Future<void> confirmAndSubmit(WidgetTester tester) async {
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
  }

  testWidgets('scan, see the item, complete, next customer', (tester) async {
    await open(tester);
    expect(find.text('No tags read yet.'), findsOneWidget);

    await scan(tester, 'E2801160000000A1');
    expect(find.text('Classic Tee'), findsWidgets);
    expect(
      tester.widget<AltaiButton>(find.widgetWithText(AltaiButton, 'Confirm')).onPressed,
      isNull,
      reason: 'no receipt yet',
    );

    await receipt(tester, '0022607201446208');
    await confirmAndSubmit(tester);
    expect(find.text('Good to go'), findsOneWidget);
    expect(find.textContaining('Transaction 501'), findsOneWidget);
    expect(find.textContaining('Receipt 0022607201446208'), findsOneWidget);
    expect(api.sends, 1);

    await tester.tap(find.text('Next customer'));
    await tester.pumpAndSettle();
    expect(find.text('No tags read yet.'), findsOneWidget);
  });

  testWidgets('no connection: says so, and Try again finishes the same basket', (tester) async {
    await open(tester);
    await scan(tester, 'E2801160000000A1');
    await receipt(tester, '0022607201446208');
    api.nextError = ApiException('Could not reach the server. Check the Wi-Fi.');

    await confirmAndSubmit(tester);
    expect(find.text('No confirmation yet'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Good to go'), findsOneWidget);
    expect(api.sends, 2);
  });

  testWidgets('a receipt already used: the last look warns before Submit', (tester) async {
    api.earlier = [
      CheckoutSummary(
        createdAt: DateTime(2026, 11, 5, 14, 2, 11),
        trxId: '499',
        remark: 'Altai POS · Aina · 14:02:11 · rcpt 0022607201446208 · ref x',
      ),
    ];
    await open(tester);
    await scan(tester, 'E2801160000000A1');
    await receipt(tester, '0022607201446208');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already on transaction 499 at 14:02:11'), findsOneWidget);
  });

  testWidgets('no receipt: pick a reason, then Confirm works', (tester) async {
    await open(tester);
    await scan(tester, 'E2801160000000A1');
    await tester.tap(find.text('No receipt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('StoreHub offline'));
    await tester.pumpAndSettle();
    expect(find.text('No receipt: StoreHub offline'), findsOneWidget);
    await confirmAndSubmit(tester);
    expect(find.text('Good to go'), findsOneWidget);
  });

  testWidgets('receipt: type the last 4 digits, Find fills in today\'s StoreHub sale', (tester) async {
    final orders = FakeOrdersApi(delay: Duration.zero);
    await tester.runAsync(() => orders.pending('12')); // today's demo sales
    final full = orders.all[1].invoiceNumber; // 16 digits
    final end = full.substring(12);
    await open(tester, orders: orders);

    await receipt(tester, end);
    expect(find.text("Tap Find to look up today's StoreHub sale ending in $end."), findsOneWidget);
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(textBox('StoreHub receipt no.')).controller!.text, full);
    expect(find.text('Find'), findsNothing);

    // No sale today ends like this: says so, the box stays as typed.
    await receipt(tester, '0000');
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No StoreHub sale today ending in 0000'), findsOneWidget);
    expect(tester.widget<TextField>(textBox('StoreHub receipt no.')).controller!.text, '0000');
  });
}
