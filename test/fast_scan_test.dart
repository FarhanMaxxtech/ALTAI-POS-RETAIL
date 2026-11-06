import 'dart:async';

import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/presentation/basket_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tag_reader.dart';

/// Tag checks that finish only when the test says so, one tag at a time, like a slow network.
class SlowApi implements CheckoutApi {
  final Map<String, Completer<Map<String, dynamic>>> pending = {};

  void finish(String epc) => pending[epc]!.complete({
    'epc': epc,
    'found': true,
    'store_id': '12',
    'product_name': 'Classic Tee',
    'variation': 'Black / M',
    'sku': 'CT-BLK-M',
  });

  @override
  Future<List<Map<String, dynamic>>> inspect(List<String> epcs, {void Function(Map<String, dynamic> tag)? onEach}) {
    return Future.wait([
      for (final e in epcs)
        (pending[e] = Completer<Map<String, dynamic>>()).future.then((t) {
          onEach?.call(t);
          return t;
        }),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder textBox(String hintOrLabel) => find.byWidgetPredicate(
  (w) => w is TextField && (w.decoration?.hintText == hintOrLabel || w.decoration?.labelText == hintOrLabel),
);

const a = 'E28011600000000000000A01';
const b = 'E28011600000000000000A02';
const c = 'E28011600000000000000A03';

void main() {
  final reader = FakeTagReader();
  late SlowApi api;

  Future<void> open(WidgetTester tester, {bool ask = true}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api = SlowApi();
    await tester.pumpWidget(
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
        ),
      ),
    );
  }

  Future<void> scan(WidgetTester tester, String text) async {
    await scanWithReader(tester, reader, text.split(' '));
    await tester.pump();
  }

  testWidgets('the count shows at once; each row fills in as its own check ends', (tester) async {
    await open(tester, ask: false);
    await scan(tester, '$a $b $c');

    // Nothing checked yet, but the cashier already sees 3 pieces and 3 grey rows.
    expect(find.text('3'), findsOneWidget);
    expect(find.text('pcs · checking 3…'), findsOneWidget);
    expect(find.text('Classic Tee'), findsNothing);
    expect(find.byKey(ValueKey('checking-$a')), findsOneWidget);

    // One tag answers: it shows straight away, without waiting for the other two.
    api.finish(b);
    await tester.pump();
    expect(find.text('Classic Tee'), findsOneWidget);
    expect(find.byKey(ValueKey('checking-$b')), findsNothing);
    expect(find.text('pcs · checking 2…'), findsOneWidget);

    api.finish(a);
    api.finish(c);
    await tester.pumpAndSettle();
    expect(find.text('pcs'), findsWidgets);
    expect(find.text('3'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the receipt pop-up: typed while the tags are checked', (tester) async {
    await open(tester);
    await scan(tester, '$a $b');
    await tester.pump();

    expect(find.text('StoreHub receipt no.'), findsWidgets);
    expect(find.text('2 pcs read · checking 2…'), findsOneWidget);

    api.finish(a);
    api.finish(b);
    await tester.pump();
    expect(find.text('2 pcs read and checked'), findsOneWidget);

    await tester.enterText(textBox('Receipt no. from the iPad'), '0022607201446208');
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt no. from the iPad'), findsNothing);
    expect(tester.widget<TextField>(textBox('StoreHub receipt no.')).controller!.text, '0022607201446208');
    expect(find.text('Confirm & submit'), findsOneWidget);
  });

  testWidgets('Later closes it, and it doesn\'t come back for the same basket', (tester) async {
    await open(tester);
    await scan(tester, a);
    await tester.pump();
    api.finish(a); // (spinners never settle, so finish before waiting)
    await tester.pump();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt no. from the iPad'), findsNothing);

    await scan(tester, b);
    await tester.pump();
    expect(find.text('Receipt no. from the iPad'), findsNothing);
    api.finish(b);
    await tester.pumpAndSettle();
  });

  testWidgets('No receipt in the pop-up asks why', (tester) async {
    await open(tester);
    await scan(tester, a);
    await tester.pump();
    api.finish(a);
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('No receipt')));
    await tester.pumpAndSettle();
    expect(find.text('No StoreHub receipt: why?'), findsOneWidget);
    await tester.tap(find.text('StoreHub offline'));
    await tester.pumpAndSettle();
    expect(find.text('No receipt: StoreHub offline'), findsOneWidget);
  });
}
