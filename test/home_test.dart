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
  var loggedOut = 0;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    loggedOut = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: HomeScreen(
          api: FakeApi(),
          returns: ReturnsApi(FakeTeam().api),
          storeId: '12',
          storeName: 'MidValley',
          staffName: 'Aina',
          onLogout: () => loggedOut++,
          tagReader: reader,
          clock: () => DateTime(2026, 11, 17, 9, 30),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('after login: a greeting, the two choices, today\'s numbers and the menu', (tester) async {
    await open(tester);
    expect(find.text('Good morning, Aina'), findsOneWidget);
    expect(find.text('MidValley · Tuesday 17 Nov 2026'), findsOneWidget);
    expect(find.text('Checkout'), findsWidgets); // the big choice and the menu
    expect(find.text('Return & refund'), findsOneWidget);
    expect(find.text('Checkouts today'), findsOneWidget);
    expect(find.text('Orders'), findsNothing); // no StoreHub orders on this tablet
    expect(find.byTooltip('Log out'), findsOneWidget);

    await tester.tap(find.byTooltip('Log out'));
    await tester.pumpAndSettle();
    expect(loggedOut, 1);
  });

  testWidgets('Checkout: one tap, the checkout opens and reads at once; leaving asks first', (tester) async {
    await open(tester);
    reader.next
      ..clear()
      ..addAll(['E2801160000000A1']);
    await tester.tap(find.text('Put the items near the reader. They come in on their own; then enter the StoreHub receipt.'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // no settling: it's reading
    expect(find.text('Find receipt'), findsOneWidget); // straight to the checkout, no Scan page
    expect(find.text('Reader on'), findsOneWidget); // reading already: no Scan or Stop button at all
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
    expect(find.widgetWithText(AltaiButton, 'Stop scanning'), findsNothing);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 800)); // the item lands in the basket as it's read
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Classic Tee'), findsWidgets);
    expect(find.textContaining('E280 1160'), findsNothing); // no EPCs on screen, only products

    // The menu's Home: items not sold yet, so it asks first.
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this checkout?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('Good morning, Aina'), findsOneWidget);
  });

  testWidgets('the menu\'s Return opens the return screen, reading at once', (tester) async {
    await open(tester);
    await tester.tap(find.text('Return'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // it reads at once
    expect(find.text('Wrong size'), findsOneWidget); // the reasons
    expect(find.text('Return items'), findsOneWidget);
    expect(find.text('Reader on: they come in on their own.'), findsOneWidget); // nothing to tap
    expect(find.widgetWithText(AltaiButton, 'Scan'), findsNothing);
  });
}
