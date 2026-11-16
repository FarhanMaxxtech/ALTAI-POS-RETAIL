import 'package:altai_pos/features/home/home_screen.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'basket_screen_test.dart' show FakeApi;
import 'returns_test.dart' show FakeTeam;
import 'support/fake_tag_reader.dart';

void main() {
  final reader = FakeTagReader();

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: HomeScreen(
          api: FakeApi(),
          returns: ReturnsApi(FakeTeam().api),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          onLogout: () {},
          tagReader: reader,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('after login: the two choices', (tester) async {
    await open(tester);
    expect(find.text('Scan for Checkout'), findsOneWidget);
    expect(find.text('Return / Refund'), findsOneWidget);
    expect(find.byTooltip('Log out'), findsOneWidget);
  });

  testWidgets('Scan for Checkout: one tap, the checkout opens and reads at once; back asks first', (tester) async {
    await open(tester);
    reader.next
      ..clear()
      ..addAll(['E2801160000000A1']);
    await tester.tap(find.text('Scan for Checkout'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // the checkout slides in: no settling, it's reading
    expect(find.text('Checkout'), findsOneWidget); // straight to the checkout, no Scan page
    expect(find.text('Reader on'), findsOneWidget); // reading already: no Scan or Stop button at all
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
    expect(find.widgetWithText(AltaiButton, 'Stop scanning'), findsNothing);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 800)); // the item lands in the basket as it's read
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Classic Tee'), findsOneWidget);
    expect(find.text('Last read'), findsNothing);
    expect(find.textContaining('E280 1160'), findsNothing); // no EPCs on screen, only products
    expect(find.byTooltip('Log out'), findsNothing); // logging out is on the start page

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this checkout?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('Scan for Checkout'), findsOneWidget);
  });

  testWidgets('Return / Refund opens the return screen', (tester) async {
    await open(tester);
    await tester.tap(find.text('Return / Refund'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // it reads at once
    expect(find.text('Return & refund'), findsOneWidget);
    expect(find.text('Reader on'), findsOneWidget); // reading at once, nothing to tap
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
    expect(find.widgetWithText(AltaiButton, 'Stop scanning'), findsNothing);
  });
}
