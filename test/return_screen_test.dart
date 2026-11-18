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

  testWidgets('reads at once: the reasons, the receipt box, no Scan button, no EPC box', (tester) async {
    await open(tester);
    expect(find.text('Wrong size'), findsOneWidget); // the reasons are the chips over the cards
    expect(find.textContaining('put them near the reader'), findsOneWidget);
    expect(find.byKey(const ValueKey('receipt-field')), findsOneWidget);
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
    // Only the receipt box and the top bar's search: no box to type tags into.
    expect(find.byType(TextField), findsNWidgets(2));
  });
}
