import 'package:altai_pos/features/checkout/presentation/scan_page.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const a = 'E28011600000000000000A01';
const b = 'E28011600000000000000A02';
const c = 'E28011600000000000000A03';

String? count(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('scan-count'))).data;

void main() {
  late List<String>? result;

  Future<void> open(WidgetTester tester) async {
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
              onPressed: () async =>
                  result = await Navigator.of(context).push<List<String>>(
                    MaterialPageRoute(builder: (_) => const ScanPage()),
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> reader(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  testWidgets(
    'press Scan, the reader types many tags, reading stops by itself, all go back',
    (tester) async {
      await open(tester);
      expect(find.text('Nothing read yet'), findsOneWidget);

      await tester.tap(find.text('Scan'));
      await tester.pump();
      expect(
        find.text('Reading… keep the items on the reader'),
        findsOneWidget,
      );

      await reader(tester, a);
      await reader(tester, '$b $c');
      await reader(tester, a); // the same tag again counts once
      expect(count(tester), '3');

      await tester.pump(const Duration(seconds: 2)); // quiet: reading ends
      expect(find.text('Done reading'), findsOneWidget);
      await tester.tap(find.text('Add 3 to basket'));
      await tester.pumpAndSettle();
      expect(result, [a, b, c]);
    },
  );

  testWidgets('tags read before Scan are kept; Scan again starts over', (
    tester,
  ) async {
    await open(tester);
    await reader(tester, a);
    expect(
      find.text('already read, press Scan to read the rest'),
      findsOneWidget,
    );
    await tester.tap(find.text('Scan'));
    await tester.pump(
      const Duration(seconds: 3),
    ); // nothing new: stops after the minimum
    expect(find.text('Add 1 to basket'), findsOneWidget);

    await tester.tap(find.text('Scan again'));
    await tester.pump();
    expect(count(tester), '0');
    await reader(tester, b);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Add 1 to basket'));
    await tester.pumpAndSettle();
    expect(result, [b]);
  });
}
