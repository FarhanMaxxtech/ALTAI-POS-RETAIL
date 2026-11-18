import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/orders/data/orders_api.dart';
import 'package:altai_pos/features/orders/domain/order.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/checkout/domain/basket_controller.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:altai_pos/features/orders/presentation/orders_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tag_reader.dart';

/// Tags by first letter (tags are hex): A = CT-BLK-M, C = CT-BLK-L, B = JN-32, D = in another store, else unknown.
class FakeInspector implements CheckoutApi {
  @override
  Future<List<Map<String, dynamic>>> inspect(
    List<String> epcs, {
    void Function(Map<String, dynamic> tag)? onEach,
  }) async => [
    for (final e in epcs)
      switch (e[0]) {
        'A' => _tag(e, 'CT-BLK-M', 'Classic Tee', 'Black / M'),
        'C' => _tag(e, 'CT-BLK-L', 'Classic Tee', 'Black / L'),
        'B' => _tag(e, 'JN-32', 'Slim Jeans', '32'),
        'D' => {..._tag(e, 'JN-32', 'Slim Jeans', '32'), 'store_id': '99', 'store_name': 'Pavilion'},
        _ => {'epc': e, 'found': false},
      },
  ];

  static Map<String, dynamic> _tag(String epc, String sku, String name, String variation) => {
    'epc': epc,
    'found': true,
    'store_id': '12',
    'sku': sku,
    'product_name': name,
    'variation': variation,
  };

  final sold = <List<String>>[]; // what each checkout recorded

  @override
  Future<List<CheckoutSummary>> findByReceipt(String storeId, String receiptNo) async => [];

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
    sold.add(epcs);
    return '501';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String tag(String prefix, int i) => '$prefix${i.toString().padLeft(23, '0')}';

final order = StoreHubOrder(
  refId: 'r1',
  invoiceNumber: 'SH-0012',
  storeId: '12',
  registerId: '1',
  paidAt: DateTime(2026, 11, 5, 14),
  lines: const [
    OrderLine(sku: 'CT-BLK-M', name: 'Classic Tee', qty: 2),
    OrderLine(sku: 'BAG-PAPER', name: 'Paper bag', qty: 1, exempt: true),
  ],
);

void main() {
  final reader = FakeTagReader();
  test('a tag fits only if its SKU is on the order and the line isn\'t full', () {
    expect(rejectReason(order, 'CT-BLK-M', 0), isNull);
    expect(rejectReason(order, 'CT-BLK-M', 1), isNull);
    expect(rejectReason(order, 'CT-BLK-M', 2), 'Order has only 2 of this');
    expect(rejectReason(order, 'JN-32', 0), 'Not in this order');
    expect(rejectReason(order, null, 0), 'Not in this order');
    expect(rejectReason(order, 'BAG-PAPER', 0), 'This item needs no scan');
    expect(order.taggedQty, 2);
    expect(order.totalQty, 3);
  });

  test('late after 10 minutes, and the age in words', () {
    final paid = DateTime(2026, 11, 5, 14);
    expect(order.isLate(paid.add(const Duration(minutes: 10))), isFalse);
    expect(order.isLate(paid.add(const Duration(minutes: 11))), isTrue);
    expect(ageText(paid, paid.add(const Duration(seconds: 20))), 'just now');
    expect(ageText(paid, paid.add(const Duration(minutes: 7))), '7 min ago');
    expect(ageText(paid, paid.add(const Duration(minutes: 65))), '1 h 5 min ago');
  });

  group('checkout of an order', () {
    late BasketController basket;
    setUp(() {
      basket = BasketController(api: FakeInspector(), storeId: '12', staffName: 'Aina', checkDelay: Duration.zero)
        ..useOrder(order);
    });
    tearDown(() => basket.dispose());
    Future<void> read(String text) async {
      basket.addText(text);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Map<String, String?> red() => {
      for (final i in basket.items)
        if (i.state == ItemState.problem) i.epc[0]: i.problem,
    };

    test('the order\'s receipt no. is used, and no receipt check gets in the way', () {
      expect(basket.receiptNo, 'SH-0012');
      expect(basket.hasReceipt, isTrue);
      expect(basket.orderLeft, 2); // the paper bag needs no tag
    });

    test('wrong items, extra pieces and other stores\' tags are refused', () async {
      await read('${tag('A', 1)} ${tag('B', 1)} ${tag('A', 2)} ${tag('A', 3)} ${tag('D', 1)} ${tag('F', 1)}');
      expect(basket.scannedBySku, {'CT-BLK-M': 2});
      expect(red(), {'B': 'Not in this order', 'A': 'Order has only 2 of this', 'D': 'Belongs to Pavilion'});
      expect(basket.ignoredUnknown, 1); // F has no product: left out, not refused
      expect(basket.orderLeft, 0);
    });

    test('Confirm only when every item on the order is scanned', () async {
      await read(tag('A', 1));
      expect(basket.canComplete, isFalse);
      expect(basket.missing, 'Scan every item on the order: 1 piece to go');
      await read(tag('A', 2));
      expect(basket.canComplete, isTrue);
    });

    test('the same tag read twice counts once', () async {
      await read(tag('A', 1));
      await read('${tag('A', 1)} ${tag('A', 1)}');
      expect(basket.scannedBySku, {'CT-BLK-M': 1});
      expect(red(), isEmpty);
    });

    test('picking the order after scanning checks the items again', () async {
      basket.useOrder(null);
      await read('${tag('A', 1)} ${tag('B', 1)}');
      expect(red(), isEmpty); // a free checkout: anything from this store
      basket.useOrder(order);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(red(), {'B': 'Not in this order'});
    });
  });

  test('a demo order from real tags: one line per SKU', () async {
    final fake = FakeOrdersApi(delay: Duration.zero);
    final tags = await FakeInspector().inspect([tag('A', 1), tag('A', 2), tag('B', 1), tag('F', 1)]);
    final o = fake.addFromTags('12', tags)!;
    expect(o.invoiceNumber, matches(RegExp(r'^\d{16}$'))); // shaped like a StoreHub receipt no.
    expect([for (final l in o.lines) '${l.sku} x${l.qty}'], ['CT-BLK-M x2', 'JN-32 x1']);
    expect(
      fake.addFromTags('12', [
        {'epc': 'F', 'found': false},
      ]),
      isNull,
    );
    expect((await fake.pending('12')).map((o) => o.invoiceNumber), contains(o.invoiceNumber));
  });

  for (final (name, size) in [('landscape', Size(1280, 800)), ('portrait', Size(800, 1280))]) {
    testWidgets('pick an order, scan it, complete it ($name)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final orders = FakeOrdersApi(delay: Duration.zero);
      await tester.pumpWidget(
        MaterialApp(
          theme: altaiTheme(Brightness.light),
          home: OrdersScreen(
            tagReader: reader,
            orders: orders,
            inspector: FakeInspector(),
            storeId: '12',
            storeName: 'MidValley',
            staffName: 'Aina',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Two demo orders, both waiting for their items; the old one's paid time is flagged.
      final older = orders.all[0].invoiceNumber, newer = orders.all[1].invoiceNumber;
      expect(older, matches(RegExp(r'^\d{16}$')));
      expect(find.text(older), findsOneWidget);
      expect(find.text(newer), findsOneWidget);
      expect(find.text('Not scanned yet'), findsNWidgets(2));
      expect(find.text('Not scanned  2'), findsOneWidget);
      expect(find.textContaining('Demo orders'), findsOneWidget);

      await tester.tap(find.text(newer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600)); // no settling: the checkout reads at once
      // The checkout, with every item on the order before anything is scanned.
      expect(find.text('Order $newer'), findsOneWidget);
      expect(find.text('0 / 1'), findsNWidgets(2)); // Slim Jeans and Classic Tee Black / L
      expect(find.text('Reader on'), findsOneWidget); // reading at once: no Scan page, no Scan button
      expect(find.text('Scan'), findsNothing);
      bool confirmOn() => tester.widget<TextButton>(find.widgetWithText(TextButton, 'Confirm')).onPressed != null;

      Future<void> scanTags(String text) async {
        await scanWithReader(tester, reader, text.split(' '));
        await tester.pump(const Duration(milliseconds: 300));
      }

      await scanTags('${tag('B', 1)} ${tag('A', 1)}');
      expect(find.text('1 / 1'), findsOneWidget); // the jeans
      expect(find.text('Not in this order'), findsOneWidget); // the Black / M tee: a red card
      expect(confirmOn(), isFalse);
      await tester.pump(const Duration(seconds: 12)); // the red card goes away by itself

      await scanTags(tag('C', 1));
      expect(find.text('1 / 1'), findsNWidgets(2));
      expect(confirmOn(), isTrue);
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Submit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Good to go'), findsOneWidget);
      expect(orders.completed.single.epcs, unorderedEquals([tag('B', 1), tag('C', 1)]));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text(newer), findsNothing); // done orders leave the list
      expect(find.text(older), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('leaving a half-scanned order asks first', (tester) async {
    final demo = FakeOrdersApi(delay: Duration.zero);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: OrdersScreen(
          tagReader: reader,
          orders: demo,
          inspector: FakeInspector(),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(demo.all[0].invoiceNumber));
    await tester.pumpAndSettle();
    await scanWithReader(tester, reader, [tag('A', 1)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this checkout?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('Demo order'), findsOneWidget); // back on the orders list
  });
}
