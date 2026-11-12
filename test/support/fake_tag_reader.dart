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

/// What the cashier does to read items: Checkout and Return read straight into their list (Scan,
/// unless the screen already reads, then Stop scanning); the StoreHub orders Scan page needs its own
/// Scan and "Add N to …". Pumps a fixed time instead of settling: the reader and the basket's
/// "checking" spinners never settle.
Future<void> scanWithReader(WidgetTester tester, FakeTagReader reader, List<String> epcs) async {
  reader.next
    ..clear()
    ..addAll(epcs);
  Finder stop() => find.widgetWithText(AltaiButton, 'Stop scanning');
  if (stop().evaluate().isEmpty) {
    await tester.tap(find.widgetWithText(AltaiButton, 'Scan').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // a Scan page slides in (StoreHub orders)
    if (stop().evaluate().isEmpty) await tester.tap(find.widgetWithText(AltaiButton, 'Scan').last);
  }
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 800)); // the reader keeps reading…
  }
  await tester.tap(stop()); // …until the cashier stops it
  await tester.pump(const Duration(milliseconds: 800));
  final add = find.textContaining(RegExp(r'^Add \d+ to '));
  if (add.evaluate().isNotEmpty) {
    await tester.tap(add); // the Scan page hands its tags back
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }
}
