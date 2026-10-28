import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

import '../../../../helpers/helpers.dart';

void main() {
  const labels = ['LEVEL', 'TONE', 'TIME', 'MIX', 'SIZE', 'DECAY'];

  FxStompFace face(
    String module,
    int knobs, {
    FxStompLed led = FxStompLed.on,
  }) => FxStompFace(
    spec: kFxStompSpecs[module]!,
    led: led,
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
    find
        .descendant(
          of: find.byType(FxStompPedal),
          matching: find.byType(Stack),
        )
        .first,
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
    testWidgets('a treadle draws with $count knobs', (tester) async {
      await pump(tester, face('Delay', count));
      expect(tester.takeException(), isNull);
    });
  }

  for (final count in [4, 5, 6]) {
    testWidgets('a box and a module draw with $count knobs', (
      tester,
    ) async {
      await pump(tester, face('Reverb', count));

      await pump(tester, face('Compressor', count));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a bypassed pedal still draws', (tester) async {
    await pump(tester, face('Delay', 3, led: FxStompLed.off));
    await pump(tester, face('Delay', 3, led: FxStompLed.still));

    expect(find.byType(FxStompPedal), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('no knob label overlaps another label, another knob or its scale, '
      'or leaves its panel, on any face', () {
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
        // A module's knobs carry a scale out to 56 around their 38.
        final scale = kind == FxStompFaceKind.module ? 56.0 - 38 : 0.0;
        final knobs = [
          for (final knob in fxStompKnobBounds(kind, count))
            knob.inflate(scale),
        ];
        // A window's labels print on its panel, which ends at 350.
        if (kind == FxStompFaceKind.window) {
          for (final (i, label) in rects.indexed) {
            expect(
              label.bottom,
              lessThanOrEqualTo(350),
              reason: '${kind.name} with $count knobs: ${long[i]}',
            );
          }
        }
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
}
