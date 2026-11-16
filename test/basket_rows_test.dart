import 'package:altai_pos/features/catalog/data/catalog_api.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/checkout_summary.dart';
import 'package:altai_pos/features/checkout/presentation/basket_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tag_reader.dart';

/// Tags: A… = Classic Tee in two sizes, B… = Slim Jeans, C… = a product with a long name.
class FakeApi implements CheckoutApi {
  @override
  Future<({List<Map<String, dynamic>> rows, int total})> storeTagPage(
    String storeId,
    int page, {
    int pageSize = 200,
  }) async => (rows: const <Map<String, dynamic>>[], total: 0);
  static Map<String, dynamic> _tag(String epc) {
    final (code, name, sku, variation) = switch (epc[0]) {
      'A' => ('CT', 'Classic Tee', epc[1] == '1' ? 'CT-BLK-M' : 'CT-BLK-L', epc[1] == '1' ? 'Black / M' : 'Black / L'),
      'B' => ('JN', 'Slim Jeans', 'JN-32', '32'),
      'D' => ('D${epc.substring(1, 3)}', 'Product ${epc.substring(1, 3)}', 'SKU-${epc.substring(1, 3)}', 'Size M'),
      _ => ('LX', 'Limited edition heavyweight oversized hoodie with embroidery', 'LX-GRN-XXL', 'Forest green / XXL'),
    };
    return {
      'epc': epc,
      'found': true,
      'store_id': '12',
      'product_code': code,
      'product_name': name,
      'sku': sku,
      'variation': variation,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> inspect(
    List<String> epcs, {
    void Function(Map<String, dynamic> tag)? onEach,
  }) async => [for (final e in epcs) _tag(e)];

  @override
  Future<String> checkout({
    required String storeId,
    required String clientRef,
    required List<String> epcs,
    String staffName = '',
    String receiptNo = '',
    String noReceiptReason = '',
    String exchangeFor = '',
  }) async => '501';

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
  Future<SkuInfo> lookup(String sku) async => SkuInfo(price: sku.startsWith('LX') ? '12499.00' : '49.90');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String epc(String prefix, int i) => '$prefix${i.toString().padLeft(15, '0')}';

void main() {
  final reader = FakeTagReader();
  Future<void> open(WidgetTester tester, Size size, double textScale, {double navBar = 0}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(bottom: navBar); // Android's back / home bar
    tester.view.viewPadding = FakeViewPadding(bottom: navBar);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: aboveSystemBars(context, child),
        ),
        home: BasketScreen(
          tagReader: reader,
          api: FakeApi(),
          catalog: FakeCatalog(),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          onLogout: () {},
        ),
      ),
    );
  }

  Future<void> scanAll(WidgetTester tester) async {
    final tags = [
      for (var i = 0; i < 3; i++) epc('A1', i),
      for (var i = 0; i < 2; i++) epc('A2', i),
      for (var i = 0; i < 4; i++) epc('B0', i),
      for (var i = 0; i < 120; i++) epc('C0', i), // a big quantity and a big total
    ];
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'StoreHub receipt no.'),
      '0022607201446208',
    );
    await scanWithReader(tester, reader, tags);
    await tester.pumpAndSettle();
  }

  testWidgets('Confirm & submit stays above Android\'s navigation bar', (tester) async {
    await open(tester, const Size(1280, 800), 1.0, navBar: 48);
    await scanAll(tester);
    final button = tester.getRect(find.text('Confirm & submit'));
    expect(button.bottom, lessThanOrEqualTo(800 - 48));
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, textScale) in [
    ('landscape', const Size(1280, 800), 1.0),
    ('portrait', const Size(800, 1280), 1.0),
    ('landscape, big text', const Size(1280, 800), 1.3), // the tablet's font size turned up
  ]) {
    testWidgets('one row per product, variants in the dropdown, nothing overflows ($name)', (tester) async {
      await open(tester, size, textScale);
      await scanAll(tester);

      // Classic Tee: one row for both sizes.
      expect(find.text('Classic Tee'), findsOneWidget);
      // The SKU sits under the name; a product in two sizes lists both.
      expect(find.text('SKU JN-32'), findsOneWidget);
      expect(find.text('SKU CT-BLK-L, CT-BLK-M'), findsOneWidget);
      expect(find.text('RM 199.60'), findsOneWidget); // 4 × 49.90
      expect(find.text('RM 49.90 each'), findsOneWidget);

      await tester.tap(find.text('Classic Tee'));
      await tester.pumpAndSettle();
      expect(find.text('Black / M'), findsOneWidget);
      expect(find.text('SKU CT-BLK-M'), findsNothing); // no SKU in the dropdown
      expect(find.text('× 3'), findsOneWidget);
      expect(find.text('Black / L'), findsOneWidget);
      expect(find.text('× 2'), findsOneWidget);

      expect(find.byTooltip('Remove one piece'), findsNothing); // no minus button in the dropdown

      // Open every row so the list is long: it scrolls rather than overflows.
      await tester.tap(find.text('Slim Jeans'));
      await tester.tap(find.textContaining('Limited edition'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The last look and the done screen fit too.
      await tester.tap(find.textContaining('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text('Black / L · SKU CT-BLK-L'), findsOneWidget);
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Good to go'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('done screen and last look on the tablet: 10+ SKUs in view before scrolling', (tester) async {
    // The tablet (SM-X610) in landscape: 2560 × 1600 px at 2.125 = 1205 × 753, less Android's bars.
    await open(tester, const Size(1205, 753), 1.0, navBar: 48);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'StoreHub receipt no.'),
      '0022607201446208',
    );
    await scanWithReader(tester, reader, [for (var i = 10; i < 22; i++) epc('D$i', 0)]); // 12 SKUs
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Confirm'));
    await tester.pumpAndSettle();
    // The last look: only its item list scrolls; the buttons stay in view.
    expect(find.byKey(const ValueKey('confirm-items')), findsOneWidget);
    expect(tester.getRect(find.text('Submit')).bottom, lessThanOrEqualTo(753 - 48));
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    final list = tester.getRect(find.byType(ListView).last);
    final fullyShown = find
        .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('done-'))
        .evaluate()
        .where((e) => tester.getRect(find.byWidget(e.widget)).bottom <= list.bottom + 0.5)
        .length;
    expect(fullyShown, greaterThanOrEqualTo(10));
    expect(tester.takeException(), isNull);
  });
}
