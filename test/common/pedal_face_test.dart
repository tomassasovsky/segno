import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/pedal_face.dart';

/// The face is a PORT, not a drawing: every outline comes from the design
/// study's own path constants. These pin the transcription, because a hand
/// copy is exactly the kind of thing that drifts silently.
///
/// What this pins is that the port QUOTES the study's outlines. That the
/// `Path` calls under each quote build that outline is pinned by the setup
/// screen's goldens, which run on the author's machine only — so a coordinate
/// typed wrong here fails the goldens, and an outline the study changed fails
/// everywhere.
void main() {
  const study = 'docs/design/pedal-hardware-widget.js';
  const port = 'lib/common/pedal_face.dart';

  /// Comment markers and line breaks carry no meaning here: the port quotes
  /// the long outlines across two lines.
  String squash(String source) =>
      source.replaceAll('///', '').replaceAll(RegExp(r'\s+'), '');

  test('every outline the study draws is quoted in the port', () {
    final js = File(study).readAsStringSync();
    final dart = squash(File(port).readAsStringSync());
    // Every SVG path literal in the study — a new one added there fails here
    // until the port carries it too.
    final outlines = RegExp(
      "'(M[^']+)'",
    ).allMatches(js).map((m) => m.group(1)!).toSet();
    expect(
      outlines,
      hasLength(7),
      reason:
          'the study should hold the body, pad, two hinges, two rolled edges '
          'and the nameplate',
    );
    for (final outline in outlines) {
      expect(
        dart.contains(squash(outline)),
        isTrue,
        reason: '$port does not quote $outline from $study',
      );
    }
  });

  test("the grip grid is the study's", () {
    final js = File(study).readAsStringSync();
    // The pitch and origin are written into the study as one expression; the
    // port spells them as constants, so this is what holds the two together.
    expect(js.contains('42 + (col - 2) * 11.6373'), isTrue);
    expect(js.contains('39.47 + row * 12'), isTrue);
    expect(js.contains('row < 6'), isTrue);
    expect(js.contains('col < 5'), isTrue);
    expect(js.contains("circle(x, y, 4), '#101316'"), isTrue);
    expect(js.contains('circle(x, y - .18, 3.1)'), isTrue);
  });

  test("the face keeps the plate's proportions", () {
    // The pen places a 159.16 x 216 instance in every 216-tall cap slot.
    expect(PedalFace.widthFor(216), closeTo(159.16, 0.01));
    expect(
      PedalFace.artSize.width / PedalFace.artSize.height,
      closeTo(159.16 / 216, 0.0001),
    );
  });

  test('the painter repaints for a selection and for nothing else', () {
    const unselected = PedalFacePainter(selected: false);
    const selected = PedalFacePainter(selected: true);
    expect(unselected.shouldRepaint(selected), isTrue);
    expect(selected.shouldRepaint(selected), isFalse);
  });

  testWidgets('the legend sits on the nameplate, not on the grips', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 159.16,
            height: 216,
            child: PedalFace(
              selected: false,
              legend: Text('TRACK 1', key: Key('legend')),
            ),
          ),
        ),
      ),
    );

    final legend = tester.getRect(find.byKey(const Key('legend')));
    final face = tester.getRect(find.byType(PedalFace));
    final scale = face.height / PedalFace.artSize.height;
    final plate = Rect.fromLTRB(
      face.left + PedalFace.namePlate.left * scale,
      face.top + PedalFace.namePlate.top * scale,
      face.left + PedalFace.namePlate.right * scale,
      face.top + PedalFace.namePlate.bottom * scale,
    );
    // Edge by edge rather than Rect.contains, whose right and bottom are
    // exclusive: a legend that exactly fills the nameplate is on it.
    expect(legend.left, greaterThanOrEqualTo(plate.left - 0.01));
    expect(legend.top, greaterThanOrEqualTo(plate.top - 0.01));
    expect(legend.right, lessThanOrEqualTo(plate.right + 0.01));
    expect(legend.bottom, lessThanOrEqualTo(plate.bottom + 0.01));
    // And well clear of the first row of grips.
    expect(legend.bottom, lessThan(face.top + 39.47 * scale));
  });
}
