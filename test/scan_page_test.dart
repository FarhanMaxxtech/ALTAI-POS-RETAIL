import 'package:altai_pos/features/checkout/presentation/scan_page.dart';
import 'package:altai_pos/shared/altai_theme.dart';
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

String? count(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('scan-count'))).data;

void main() {
  late List<String>? result;

  Future<void> open(WidgetTester tester, TagReader usb) async {
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
              ).push<List<String>>(MaterialPageRoute(builder: (_) => ScanPage(reader: usb))),
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

  testWidgets('Scan reads round after round, stops when nothing new, all go back', (tester) async {
    final usb = ScriptedReader([
      [a, b],
      [a, b, c],
      [c],
    ]);
    await open(tester, usb);
    expect(find.text('USB reader connected'), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // no typing box any more

    await tester.tap(find.text('Scan'));
    await tester.pump();
    expect(find.text('Reading… keep the items on the reader'), findsOneWidget);
    await rounds(tester, 8);
    expect(count(tester), '3');
    expect(find.text('Done reading'), findsOneWidget);
    // 2 rounds with new tags, then 2 with nothing new ([c] again, then empty): stop.
    expect(usb.reads, 4);

    await tester.tap(find.text('Add 3 to basket'));
    await tester.pumpAndSettle();
    expect(result, [a, b, c]);
  });

  testWidgets('Stop keeps what was read; Scan again starts over', (tester) async {
    final usb = ScriptedReader([
      [a],
      [b],
      [b],
      [c],
    ]);
    await open(tester, usb);
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Stop'));
    await rounds(tester, 1); // the round in progress still counts
    expect(count(tester), '1');
    expect(find.text('Add 1 to basket'), findsOneWidget);

    await tester.tap(find.text('Scan again'));
    await tester.pump();
    expect(count(tester), '0');
    await rounds(tester, 8);
    await tester.tap(find.text('Add 2 to basket'));
    await tester.pumpAndSettle();
    expect(result, [b, c]);
  });

  testWidgets('asks Android for access first, and shows reader errors', (tester) async {
    final usb = ScriptedReader([], initial: ReaderState.needsPermission);
    await open(tester, usb);
    expect(find.text('USB reader found: allow the app to use it'), findsOneWidget);

    usb.failWith = ReaderException('The reader did not answer.');
    await tester.tap(find.text('Scan'));
    await tester.pump();
    expect(usb.asked, isTrue);
    await rounds(tester, 1);
    expect(find.text('The reader did not answer.'), findsOneWidget);
    expect(find.text('Nothing read'), findsOneWidget);
  });

  testWidgets('no reader plugged in: says so, and Scan does not start', (tester) async {
    final usb = ScriptedReader([], initial: ReaderState.none);
    await open(tester, usb);
    expect(find.text('No RFID reader plugged in'), findsOneWidget);
    await tester.tap(find.text('Scan'));
    await tester.pump();
    expect(find.textContaining('No RFID reader. Plug the reader'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    usb.initial = ReaderState.ready; // plugged in now
    await tester.tap(find.text('Look again'));
    await tester.pump();
    expect(find.text('USB reader connected'), findsOneWidget);
  });
}
