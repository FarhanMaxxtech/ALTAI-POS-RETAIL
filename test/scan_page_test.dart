import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/data/store_tags.dart';
import 'package:altai_pos/features/checkout/presentation/scan_page.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:altai_pos/shared/rfid_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const a = 'E28011600000000000000A01';
const b = 'E28011600000000000000A02';
const c = 'E28011600000000000000A03';

/// A USB reader that answers each read round from a script.
class ScriptedReader implements TagReader {
  ScriptedReader(this.rounds, {this.initial = ReaderState.ready});
  final List<List<String>> rounds;
  ReaderState initial;
  int reads = 0;
  bool asked = false;
  Object? failWith;

  @override
  Future<ReaderState> state() async => initial;

  @override
  Future<bool> askPermission() async {
    asked = true;
    initial = ReaderState.ready;
    return true;
  }

  @override
  Future<List<String>> read(Duration time) async {
    await Future<void>.delayed(time);
    if (failWith != null) throw failWith!;
    final i = reads++;
    return i < rounds.length ? rounds[i] : const <String>[];
  }
}

/// The server's tag check: a and b are Slim Jeans 32, anything else has no product.
class NamingInspector implements CheckoutApi {
  @override
  Future<List<Map<String, dynamic>>> inspect(List<String> epcs, {void Function(Map<String, dynamic> tag)? onEach}) async {
    final out = [
      for (final e in epcs)
        e == c
            ? {'epc': e, 'found': false}
            : {'epc': e, 'found': true, 'sku': 'JN-32', 'product_name': 'Slim Jeans', 'variation': '32'},
    ];
    out.forEach(onEach ?? (_) {});
    return out;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String? count(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('scan-count'))).data;

Finder button(String text) => find.widgetWithText(AltaiButton, text);

void main() {
  late List<String>? result;

  Future<void> open(WidgetTester tester, TagReader usb, {StoreTags? known, CheckoutApi? inspector}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await Navigator.of(
                context,
              ).push<List<String>>(MaterialPageRoute(builder: (_) => ScanPage(reader: usb, known: known, inspector: inspector))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> rounds(WidgetTester tester, int n) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 800));
    }
  }

  /// The cashier taps the spinning button to end the scan; the round in progress still counts.
  Future<void> stop(WidgetTester tester) async {
    await tester.tap(button('Stop scanning'));
    await rounds(tester, 1);
  }

  testWidgets('Scan: the button spins and keeps reading until tapped again; the items are listed', (tester) async {
    final usb = ScriptedReader([
      [a, b],
      [a, b, c],
      [c],
    ]);
    await open(tester, usb);
    expect(find.text('USB reader connected'), findsOneWidget);
    expect(find.text('Scanned items show here.'), findsOneWidget);

    await tester.tap(button('Scan'));
    await tester.pump();
    // The same button, now spinning: Stop scanning.
    expect(find.descendant(of: button('Stop scanning'), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(button('Scan'), findsNothing);

    await rounds(tester, 10);
    expect(usb.reads, greaterThanOrEqualTo(10)); // nothing new for many rounds: still reading
    expect(button('Stop scanning'), findsOneWidget);
    expect(count(tester), '3');

    await stop(tester);
    expect(button('Stop scanning'), findsNothing);
    expect(find.text('SCANNED ITEMS (3)'), findsOneWidget);
    expect(find.byKey(const ValueKey('scanned-$c')), findsOneWidget);

    // Done: Scan becomes Remove all; Scan again and Add to basket are there.
    expect(button('Scan'), findsNothing);
    expect(button('Remove all'), findsOneWidget);
    expect(button('Scan again'), findsOneWidget);

    await tester.tap(button('Add 3 to basket'));
    await tester.pumpAndSettle();
    expect(result, [a, b, c]);
  });

  testWidgets('Scan again adds the new batch to the list; nothing is replaced', (tester) async {
    final usb = ScriptedReader([
      [a], [], // first scan: one tag
      [b, a], [c], // second scan: b and c are new, a counts once
    ]);
    await open(tester, usb);
    await tester.tap(button('Scan'));
    await rounds(tester, 1);
    await stop(tester);
    expect(count(tester), '1');

    await tester.tap(button('Scan again'));
    await rounds(tester, 2);
    await stop(tester);
    expect(count(tester), '3');
    await tester.tap(button('Add 3 to basket'));
    await tester.pumpAndSettle();
    expect(result, [a, b, c]);
  });

  testWidgets('Stop scanning keeps what was read; Remove all empties the list after asking', (tester) async {
    final usb = ScriptedReader([
      [a],
      [b],
    ]);
    await open(tester, usb);
    await tester.tap(button('Scan'));
    await tester.pump(const Duration(milliseconds: 400));
    await stop(tester); // the round in progress still counts
    expect(count(tester), '1');

    await tester.tap(button('Remove all'));
    await tester.pumpAndSettle();
    expect(find.text('Remove all 1 scanned tags?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(count(tester), '1');

    await tester.tap(button('Remove all'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Remove all')));
    await tester.pumpAndSettle();
    expect(count(tester), '0');
    expect(button('Scan'), findsOneWidget); // back to the start
  });

  testWidgets('tags the store list knows show their product', (tester) async {
    final known = StoreTags(
      (page) async => (
        rows: [
          {'epc': a, 'sku': 'CT-BLK-M', 'productName': 'Classic Tee', 'varLabel': 'Black / M'},
        ],
        total: 1,
      ),
    );
    await known.load();
    await open(tester, ScriptedReader([[a, b]]), known: known);
    await tester.tap(button('Scan'));
    await rounds(tester, 1);
    await stop(tester);
    expect(find.text('Classic Tee'), findsOneWidget);
    expect(find.text('Black / M'), findsOneWidget);
  });

  testWidgets('tags the store list does not know: the server names them; same SKU on one row', (tester) async {
    await open(tester, ScriptedReader([[a, b, c]]), inspector: NamingInspector());
    await tester.tap(button('Scan'));
    await rounds(tester, 1);
    await stop(tester);
    expect(find.text('Slim Jeans'), findsOneWidget);
    expect(find.text('× 2'), findsOneWidget); // a and b are the same SKU
    expect(count(tester), '2'); // c has no product: dropped from the list
    expect(find.text('1 unknown tag ignored (no product).'), findsOneWidget);
    expect(find.textContaining('E280'), findsNothing); // product names, not EPCs
  });

  testWidgets('asks Android for access first, and shows reader errors', (tester) async {
    final usb = ScriptedReader([], initial: ReaderState.needsPermission);
    await open(tester, usb);
    expect(find.text('USB reader found: allow the app to use it'), findsOneWidget);

    usb.failWith = ReaderException('The reader did not answer.');
    await tester.tap(button('Scan'));
    await tester.pump();
    expect(usb.asked, isTrue);
    await rounds(tester, 1);
    expect(find.text('The reader did not answer.'), findsOneWidget);
    expect(button('Scan'), findsOneWidget); // nothing read: Scan again from the start
  });

  testWidgets('no reader plugged in: says so, and Scan does not start', (tester) async {
    final usb = ScriptedReader([], initial: ReaderState.none);
    await open(tester, usb);
    expect(find.text('No RFID reader plugged in'), findsOneWidget);
    await tester.tap(button('Scan'));
    await tester.pump();
    expect(find.textContaining('No RFID reader. Plug the reader'), findsOneWidget);
    expect(button('Stop scanning'), findsNothing);

    usb.initial = ReaderState.ready; // plugged in now
    await tester.tap(find.text('Look again'));
    await tester.pump();
    expect(find.text('USB reader connected'), findsOneWidget);
  });

  testWidgets('the same unknown tag read on every round counts once', (tester) async {
    await open(tester, ScriptedReader([for (var i = 0; i < 8; i++) [a, c]]), inspector: NamingInspector());
    await tester.tap(button('Scan'));
    await rounds(tester, 8);
    await stop(tester);
    expect(find.text('1 unknown tag ignored (no product).'), findsOneWidget);
    expect(count(tester), '1'); // only a
  });

  testWidgets('scanning for a StoreHub order: other products are red and left out', (tester) async {
    result = null;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final usb = ScriptedReader([
      [a, b],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await Navigator.of(context).push<List<String>>(
                MaterialPageRoute(
                  builder: (_) => ScanPage(
                    reader: usb,
                    inspector: OneOfEach(),
                    target: 'order',
                    allowedSkus: const {'CT-BLK-M'},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(button('Scan'));
    await rounds(tester, 1);
    await stop(tester);

    expect(find.text('Not in this order'), findsOneWidget); // the jeans
    expect(find.textContaining('1 item is not in this order'), findsOneWidget);
    expect(count(tester), '1');
    await tester.tap(button('Add 1 to order'));
    await tester.pumpAndSettle();
    expect(result, [a]); // only the tee goes on
  });
}

/// a = Classic Tee (CT-BLK-M), anything else = Slim Jeans (JN-32).
class OneOfEach implements CheckoutApi {
  @override
  Future<List<Map<String, dynamic>>> inspect(List<String> epcs, {void Function(Map<String, dynamic> tag)? onEach}) async {
    final out = [
      for (final e in epcs)
        e == a
            ? {'epc': e, 'found': true, 'sku': 'CT-BLK-M', 'product_name': 'Classic Tee', 'variation': 'Black / M'}
            : {'epc': e, 'found': true, 'sku': 'JN-32', 'product_name': 'Slim Jeans', 'variation': '32'},
    ];
    out.forEach(onEach ?? (_) {});
    return out;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
