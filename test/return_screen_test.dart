import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/presentation/return_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'returns_test.dart' show FakeTeam;

void main() {
  Future<void> open(WidgetTester tester, {String? cameraReads}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final team = FakeTeam();
    await tester.pumpWidget(MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: ReturnScreen(
          inspector: CheckoutApi(team.api),
          api: ReturnsApi(team.api),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          barcodeScanner: (_) async => cameraReads, // no real camera in tests
        )));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('the receipt box is on top, the EPC box under it', (tester) async {
    await open(tester);
    final receipt = tester.getRect(field('StoreHub receipt no., order no. or ID'));
    final epc = tester.getRect(field('Items coming back'));
    expect(receipt.top, lessThan(epc.top));
  });

  testWidgets('scan the receipt barcode with the camera', (tester) async {
    await open(tester, cameraReads: 'SH-000123');
    await tester.tap(find.byTooltip('Scan barcode with camera'));
    await tester.pumpAndSettle();
    expect(find.text('SH-000123'), findsOneWidget);
    expect(find.text('Enter or scan the receipt / order number.'), findsNothing);
  });

  testWidgets('cancelling the camera leaves the box as it was', (tester) async {
    await open(tester);
    await tester.enterText(field('StoreHub receipt no., order no. or ID'), 'ORD-77');
    await tester.tap(find.byTooltip('Scan barcode with camera'));
    await tester.pumpAndSettle();
    expect(find.text('ORD-77'), findsOneWidget);
  });
}
