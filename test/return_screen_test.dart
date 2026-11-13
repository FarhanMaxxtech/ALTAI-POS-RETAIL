import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/presentation/return_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'returns_test.dart' show FakeTeam;

void main() {
  Future<void> open(WidgetTester tester) async {
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
        )));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('the receipt box is on top, the reader line under it, no Scan button, no EPC box', (tester) async {
    await open(tester);
    final receipt = tester.getRect(field('StoreHub receipt no., order no. or ID'));
    final reader = tester.getRect(find.textContaining('put them near the reader'));
    expect(receipt.top, lessThan(reader.top));
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
    expect(find.byType(TextField), findsOneWidget); // only the receipt box
  });
}
