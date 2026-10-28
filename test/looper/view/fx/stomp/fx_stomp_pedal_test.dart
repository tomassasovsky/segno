import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';

import '../../../../helpers/helpers.dart';

void main() {
  const knobLabels = ['LEVEL', 'TONE', 'TIME', 'MIX'];

  FxStompFace face({
    String name = 'DELAY',
    String? subtitle = "ED'S RACK",
    int knobs = 3,
    Color colour = const Color(0xFF2BC8CF),
  }) => FxStompFace(
    name: name,
    subtitle: subtitle,
    colour: colour,
    knobs: [
      for (var i = 0; i < knobs; i++)
        FxStompKnob(label: knobLabels[i], setting: i / 3),
    ],
  );

  Future<void> pump(
    WidgetTester tester,
    FxStompFace face, {
    Size box = const Size(225, 331),
  }) => tester.pumpApp(
    Center(
      child: SizedBox.fromSize(
        size: box,
        child: FxStompPedal(face: face),
      ),
    ),
  );

  for (final count in [1, 2, 3, 4]) {
    testWidgets('a pedal with $count knobs labels each one', (tester) async {
      await pump(tester, face(knobs: count));

      for (var i = 0; i < 4; i++) {
        expect(
          find.text(knobLabels[i]),
          i < count ? findsOneWidget : findsNothing,
        );
      }
      expect(find.text('DELAY'), findsOneWidget);
      expect(find.text('CHECK'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a long name shrinks to fit the treadle', (tester) async {
    await pump(tester, face(name: 'LOW-PASS FILTER', knobs: 4));

    final pedal = tester.getRect(find.byType(FxStompPedal));
    final name = tester.getRect(find.text('LOW-PASS FILTER'));
    // The treadle is 386 of the pedal's 450 units wide.
    expect(name.width, lessThanOrEqualTo(pedal.width * 386 / 450));
    expect(name.left, greaterThan(pedal.left));
    expect(name.right, lessThan(pedal.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pedal with no subtitle prints only its name', (tester) async {
    await pump(tester, face(subtitle: null));

    expect(find.text('DELAY'), findsOneWidget);
    expect(find.text("ED'S RACK"), findsNothing);
  });

  testWidgets('a pedal keeps its proportions in any box', (tester) async {
    await pump(tester, face(), box: const Size(300, 300));

    // What is drawn, not the box: a tight box is filled and the pedal
    // centred in it.
    final drawn = tester.getRect(
      find.descendant(
        of: find.byType(FxStompPedal),
        matching: find.byType(Stack),
      ),
    );
    expect(drawn.height, closeTo(300, 0.5));
    expect(drawn.width, closeTo(300 * 450 / 662, 0.5));
    expect(drawn.center, tester.getCenter(find.byType(FxStompPedal)));
  });

  testWidgets('a light enclosure is printed dark, a dark one light', (
    tester,
  ) async {
    Color ink() => tester.widget<Text>(find.text('DELAY')).style!.color!;

    await pump(tester, face(colour: const Color(0xFFFEFCFE)));
    expect(ink().computeLuminance(), lessThan(.1));

    await pump(tester, face(colour: const Color(0xFF001021)));
    expect(ink().computeLuminance(), greaterThan(.8));
  });

  testWidgets('the pedal is a picture to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, face());

    expect(find.bySemanticsLabel('DELAY'), findsNothing);
    semantics.dispose();
  });
}
