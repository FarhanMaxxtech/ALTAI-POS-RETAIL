import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:altai_pos/shared/rfid_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// A USB reader for tests: the next read gives [next], later reads give nothing.
class FakeTagReader implements TagReader {
  final List<String> next = [];

  @override
  Future<ReaderState> state() async => ReaderState.ready;

  @override
  Future<bool> askPermission() async => true;

  @override
  Future<List<String>> read(Duration time) async {
    await Future<void>.delayed(time);
    final got = List<String>.of(next);
    next.clear();
    return got;
  }
}

/// What the cashier does on Checkout: Scan → (Scan, if the page didn't start reading by itself) →
/// Stop scanning → Add to basket. Pumps a fixed time instead of
/// settling, because the basket's "checking" spinners never settle.
Future<void> scanWithReader(WidgetTester tester, FakeTagReader reader, List<String> epcs) async {
  reader.next
    ..clear()
    ..addAll(epcs);
  await tester.tap(find.widgetWithText(AltaiButton, 'Scan'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600)); // the page slides in
  // Checkout and Return start reading by themselves; other Scan pages (StoreHub orders) need the tap.
  if (find.widgetWithText(AltaiButton, 'Stop scanning').evaluate().isEmpty) {
    await tester.tap(find.widgetWithText(AltaiButton, 'Scan').last); // .last = the Scan page on top
  }
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 800)); // the reader keeps reading…
  }
  await tester.tap(find.widgetWithText(AltaiButton, 'Stop scanning')); // …until the cashier stops it
  await tester.pump(const Duration(milliseconds: 800));
  await tester.tap(find.textContaining(RegExp(r'^Add \d+ to ')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600)); // back on Checkout
}
