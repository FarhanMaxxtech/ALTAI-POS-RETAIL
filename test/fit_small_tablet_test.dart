import 'package:altai_pos/shared/altai_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only smaller tablets are drawn smaller', () {
    expect(FitSmallTablet.scaleFor(360), 1.0); // a phone
    expect(FitSmallTablet.scaleFor(753), 1.0); // the 11" Galaxy Tab S9 FE
    expect(FitSmallTablet.scaleFor(601), closeTo(0.835, 0.001)); // the Galaxy Tab A11
  });

  testWidgets('Galaxy Tab A11: the screens get the room of the bigger tablet, and taps still land', (tester) async {
    tester.view.physicalSize = const Size(1007, 601);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Size? seen;
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      builder: aboveSystemBars,
      home: Builder(builder: (context) {
        seen = MediaQuery.sizeOf(context);
        return Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: TextButton(onPressed: () => tapped++, child: const Text('Corner')),
          ),
        );
      }),
    ));
    expect(seen!.width, closeTo(1007 / 0.8347, 1));
    expect(seen!.height, closeTo(720, 1));
    await tester.tap(find.text('Corner'));
    expect(tapped, 1);
    // Drawn inside the real screen.
    final corner = tester.getBottomRight(find.text('Corner'));
    expect(corner.dx, lessThanOrEqualTo(1007));
    expect(corner.dy, lessThanOrEqualTo(601));
  });
}
