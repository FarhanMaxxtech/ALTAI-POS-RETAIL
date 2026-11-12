import 'dart:async';

import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:altai_pos/shared/rfid_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// A USB reader for tests. A read gives [next] after one round; with nothing in [next] it waits
/// (with no timer) until [give], so a screen that reads the whole time doesn't leave a timer behind.
class FakeTagReader implements TagReader {
  final List<String> next = [];
  Completer<void>? _wake; // the newest read waiting for tags

  /// Puts [epcs] on the reader: the newest waiting read gets them.
  void give(List<String> epcs) {
    next
      ..clear()
      ..addAll(epcs);
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<ReaderState> state() async => ReaderState.ready;

  @override
  Future<bool> askPermission() async => true;

  @override
  Future<List<String>> read(Duration time) async {
    if (next.isEmpty) {
      final w = _wake = Completer<void>();
      await w.future; // an older read left waiting is never woken: its screen stopped it
    }
    await Future<void>.delayed(time);
    final got = List<String>.of(next);
    next.clear();
    return got;
  }
}

/// What the cashier does to read items. Checkout and Return read on their own: just put the tags
/// on the reader and wait. The StoreHub orders Scan page still has its own Scan, Stop scanning and
/// "Add N to …". Pumps a fixed time instead of settling: the basket's "checking" spinners never settle.
Future<void> scanWithReader(WidgetTester tester, FakeTagReader reader, List<String> epcs) async {
  Finder button(String label) => find.widgetWithText(AltaiButton, label);
  final orders = button('Scan').evaluate().isNotEmpty; // only the orders Scan page has one
  if (orders && button('Stop scanning').evaluate().isEmpty) {
    await tester.tap(button('Scan').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // a Scan page slides in
    if (button('Stop scanning').evaluate().isEmpty) await tester.tap(button('Scan').last);
    await tester.pump();
  }
  reader.give(epcs);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 800)); // one round, then the tags land
  }
  if (orders && button('Stop scanning').evaluate().isNotEmpty) {
    await tester.tap(button('Stop scanning'));
    await tester.pump(const Duration(milliseconds: 800));
  }
  final add = find.textContaining(RegExp(r'^Add \d+ to '));
  if (add.evaluate().isNotEmpty) {
    await tester.tap(add); // the Scan page hands its tags back
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }
}
