import 'package:altai_pos/features/auth/domain/staff.dart';
import 'package:altai_pos/features/auth/presentation/store_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const midValley = Store(id: '12', name: 'MidValley');
  const pavilion = Store(id: '14', name: 'Pavilion');
  const bukitBintang = Store(id: '15', name: 'Bukit Bintang');

  Future<List<Store>> open(WidgetTester tester, List<Store> stores, {Store? last}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picked = <Store>[];
    await tester.pumpWidget(MaterialApp(
      theme: altaiTheme(Brightness.light),
      home: StoreScreen(
        loadStores: () async => stores,
        staffName: 'Aina',
        lastStore: last,
        onPicked: picked.add,
      ),
    ));
    // (Not settling: with one store the picker hands it on at once and keeps its spinner up.)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return picked;
  }

  testWidgets('after login: the account\'s stores, the last one used first', (tester) async {
    final picked = await open(tester, [midValley, pavilion, bukitBintang], last: pavilion);
    expect(find.text('Which store are you in?'), findsOneWidget);
    expect(find.text('Last used on this tablet'), findsOneWidget);
    // Pavilion first, then the rest by name.
    final order = [for (final n in ['Pavilion', 'Bukit Bintang', 'MidValley']) tester.getTopLeft(find.text(n)).dy];
    expect(order, orderedEquals([...order]..sort()));

    await tester.tap(find.text('MidValley'));
    expect(picked, [midValley]);
  });

  testWidgets('only one store: no choice to make, straight in', (tester) async {
    final picked = await open(tester, [midValley]);
    expect(picked, [midValley]);
  });

  testWidgets('no stores: says so', (tester) async {
    final picked = await open(tester, []);
    expect(find.text('This account has no stores. Ask your manager.'), findsOneWidget);
    expect(picked, isEmpty);
  });
}
