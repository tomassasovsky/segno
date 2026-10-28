import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

import '../../../../helpers/helpers.dart';

void main() {
  const labels = ['LEVEL', 'TONE', 'TIME', 'MIX', 'SIZE', 'DECAY'];

  FxStompFace face(String module, int knobs, {bool lit = true}) => FxStompFace(
    spec: kFxStompSpecs[module]!,
    lit: lit,
    knobs: [
      for (var i = 0; i < knobs; i++)
        FxStompKnob(label: labels[i], setting: i / 5),
    ],
  );

  Future<void> pump(
    WidgetTester tester,
    FxStompFace face, {
    Size box = const Size(300, 300),
  }) => tester.pumpApp(
    Center(
      child: SizedBox.fromSize(
        size: box,
        child: FxStompPedal(face: face),
      ),
    ),
  );

  /// What is drawn, not the box: a tight box is filled and the pedal
  /// centred in it.
  Rect drawn(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(FxStompPedal),
      matching: find.byType(Stack),
    ),
  );

  for (final (module, kind) in const [
    ('Delay', FxStompFaceKind.treadle),
    ('Reverb', FxStompFaceKind.box),
    ('Pumper', FxStompFaceKind.window),
    ('Compressor', FxStompFaceKind.module),
    ('Wah', FxStompFaceKind.rocker),
  ]) {
    testWidgets('a ${kind.name} face keeps its own proportions', (
      tester,
    ) async {
      expect(kFxStompSpecs[module]!.face, kind);
      await pump(tester, face(module, kind.maxKnobs));

      final rect = drawn(tester);
      expect(rect.width / rect.height, closeTo(kind.size.aspectRatio, .01));
      expect(rect.center, tester.getCenter(find.byType(FxStompPedal)));
      expect(tester.takeException(), isNull);
    });
  }

  for (final count in [1, 2, 3, 4]) {
    testWidgets('a treadle with $count knobs draws each one', (tester) async {
      await pump(tester, face('Delay', count));

      expect(knobsOf(tester), count);
      expect(tester.takeException(), isNull);
    });
  }

  for (final count in [4, 5, 6]) {
    testWidgets('a box and a module with $count knobs draw each one', (
      tester,
    ) async {
      await pump(tester, face('Reverb', count));
      expect(knobsOf(tester), count);

      await pump(tester, face('Compressor', count));
      expect(knobsOf(tester), count);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a face never draws more knobs than it holds', (tester) async {
    await pump(tester, face('Delay', 6));
    expect(knobsOf(tester), 4);

    await pump(tester, face('Whammy', 2));
    expect(knobsOf(tester), 0);
  });

  testWidgets('a bypassed pedal still draws', (tester) async {
    await pump(tester, face('Delay', 3, lit: false));

    expect(find.byType(FxStompPedal), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('no knob label overlaps another, or another knob, on any face', () {
    // The longest real controls, in the test font, whose glyphs are wider
    // than the app's.
    const long = [
      'OCTAVE 1 LEVEL',
      'GATE THRESHOLD',
      'AMB-DUB MIX',
      'ATTACK LENGTH',
      'SCALE ROOT',
      'OCTAVE 2 LEVEL',
    ];
    for (final kind in FxStompFaceKind.values) {
      for (var count = 1; count <= kind.maxKnobs; count++) {
        final rects = fxStompLabelBounds(kind, long.take(count).toList());
        final knobs = fxStompKnobBounds(kind, count);
        for (final (i, label) in rects.indexed) {
          for (final (k, knob) in knobs.indexed) {
            if (k == i) continue;
            expect(
              label.overlaps(knob),
              isFalse,
              reason:
                  '${kind.name} with $count knobs: ${long[i]} runs into '
                  'knob ${k + 1}',
            );
          }
        }
        for (var a = 0; a < rects.length; a++) {
          for (var b = a + 1; b < rects.length; b++) {
            expect(
              rects[a].overlaps(rects[b]),
              isFalse,
              reason:
                  '${kind.name} with $count knobs: ${long[a]} and '
                  '${long[b]}',
            );
          }
        }
      }
    }
  });

  testWidgets('the pedal is a picture to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, face('Delay', 3));

    expect(find.bySemanticsLabel('LEVEL'), findsNothing);
    semantics.dispose();
  });
}

/// How many knobs the pedal draws: each is a layer of its own.
int knobsOf(WidgetTester tester) =>
    find
        .descendant(
          of: find.byType(FxStompPedal),
          matching: find.byType(RepaintBoundary),
        )
        .evaluate()
        .length -
    1;
