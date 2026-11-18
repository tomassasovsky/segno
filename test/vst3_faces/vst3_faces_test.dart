// It loads the app's fonts, which stay registered for every test after it in
// the same isolate and change their text layout: Very Good's optimized run
// keeps it in an isolate of its own.
@Tags(['skip_very_good_optimization'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';

import '../helpers/helpers.dart';
import 'vst3_faces.dart';

/// The layout Segno.vst3's editors read (#1815) and the value texts its
/// plugins print: the committed [kVst3FacesManifest] is what the console's
/// drawing code lays out now, every parameter but the switch has exactly
/// one control, and [kVst3ValueTexts] is what the console prints for every
/// parameter.
///
/// `--update-goldens` rewrites both; then reinstall the plugins
/// (`packages/segno_engine/vst3/install.sh`) to render their art.
void main() {
  setUpAll(loadFxStompArt);

  /// Compares [text] with the committed [path], or rewrites it.
  void expectCommitted(String path, String text) {
    final file = File('${repoRoot.path}/$path');
    if (autoUpdateGoldenFiles) {
      file.writeAsStringSync(text);
      return;
    }
    expect(
      file.readAsStringSync(),
      text,
      reason:
          '$path is stale: run this test with --update-goldens and reinstall '
          'Segno.vst3',
    );
  }

  testWidgets('the committed manifest is what the faces lay out', (
    tester,
  ) async {
    final first = encodeVst3Manifest(await vst3FacesManifest(tester));
    expectCommitted(kVst3FacesManifest, first);
    // And it lays out the same every time.
    expect(encodeVst3Manifest(await vst3FacesManifest(tester)), first);
  });

  testWidgets('the committed value texts are what the console prints', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expectCommitted(
      kVst3ValueTexts,
      encodeVst3ValueTexts(vst3ValueTexts(l10n)),
    );
  });

  test('every parameter but the switch has exactly one control', () {
    final manifest = jsonDecode(
      File('${repoRoot.path}/$kVst3FacesManifest').readAsStringSync(),
    ) as Map<String, Object?>;
    final faces = manifest['faces']! as List<Object?>;
    expect(faces, isNotEmpty);
    for (final entry in faces.cast<Map<String, Object?>>()) {
      final type = TrackEffectType.fromCode(entry['type']! as int);
      final controls = (entry['controls']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final ids = [
        for (var p = 0; p < type.params.length; p++) p,
        kVst3InputId,
        kVst3OutputId,
        kVst3PlacementId,
        kVst3LevelId,
      ];
      final playing = [
        for (final c in controls)
          if (c['display'] != true) c['param']! as int,
      ];
      for (final id in ids) {
        expect(
          playing.where((p) => p == id),
          hasLength(1),
          reason: '${type.label}: parameter $id',
        );
      }
      expect(
        [
          for (final c in controls)
            if (c['control'] == 'footswitch') c['param'],
        ],
        [kVst3EnabledId],
        reason: '${type.label}: one footswitch, the switch',
      );
      expect(
        playing.toSet().difference({...ids, kVst3EnabledId}),
        isEmpty,
        reason: '${type.label}: every control drives a parameter',
      );
    }
  });

  testWidgets('every control fits its parameter', (tester) async {
    for (final type in vst3Kinds) {
      final face = Vst3Face.of(type);
      if (face == null) continue;
      final layout = await layOutVst3Face(tester, face);
      final window = Offset.zero & layout.size;
      for (final c in layout.controls) {
        final where = '${type.label} ${c.kind.name} ${c.param}';
        expect(window.contains(c.rect.topLeft), isTrue, reason: where);
        expect(
          window.contains(c.rect.bottomRight - const Offset(1e-6, 1e-6)),
          isTrue,
          reason: where,
        );
        if (c.kind == Vst3ControlKind.footswitch) continue;
        final positions = vst3Positions(type, c.param);
        final choice = c.param < type.params.length
            ? fxParamIsChoice(type.params[c.param])
            : positions > 1;
        switch (c.kind) {
          case Vst3ControlKind.buttons:
            expect(choice, isTrue, reason: where);
            expect(c.buttons, hasLength(positions), reason: where);
          case Vst3ControlKind.select:
            expect(choice, isTrue, reason: where);
            expect(c.names, hasLength(positions), reason: where);
          case Vst3ControlKind.knob:
            expect(c.display, choice, reason: where);
            expect(c.frames, face.framesOf(c.param), reason: where);
          case Vst3ControlKind.slider:
            expect(choice, isFalse, reason: where);
            expect(c.frames, face.framesOf(c.param), reason: where);
            expect(c.readout, isNotNull, reason: where);
            expect(c.rect.contains(c.readout!.rect.center), isTrue);
          case Vst3ControlKind.readout:
            expect(choice, isFalse, reason: where);
            expect(c.display, isTrue, reason: where);
            expect(c.readout, isNotNull, reason: where);
            expect(c.rect.contains(c.readout!.rect.center), isTrue);
          case Vst3ControlKind.footswitch:
            break;
        }
      }
      // The moving pictures never overlap, so drawing one never covers
      // another.
      final pictures = [
        layout.led,
        for (final c in layout.controls)
          if (c.frames > 0) c.rect,
      ];
      for (var i = 0; i < pictures.length; i++) {
        for (var j = i + 1; j < pictures.length; j++) {
          final overlap = pictures[i].intersect(pictures[j]);
          expect(
            overlap.width <= 0 || overlap.height <= 0,
            isTrue,
            reason: '${type.label}: pictures $i and $j overlap',
          );
        }
      }
    }
  });

  testWidgets('every control shows its value, and no value covers another '
      'or a label or a control', (tester) async {
    for (final type in vst3Kinds) {
      final face = Vst3Face.of(type);
      if (face == null) continue;
      final layout = await layOutVst3Face(tester, face);
      final controls = layout.controls;
      bool any(bool Function(Vst3Control) test) => controls.any(test);
      final values = <(Rect, Vst3Control)>[];
      for (final c in controls) {
        final where = '${type.label} ${c.kind.name} ${c.param}';
        switch (c.kind) {
          case Vst3ControlKind.knob when c.display:
            // A choice's knob: its selector names the position.
            expect(
              any(
                (o) =>
                    o.param == c.param &&
                    (o.kind == Vst3ControlKind.select ||
                        o.kind == Vst3ControlKind.buttons),
              ),
              isTrue,
              reason: where,
            );
          case Vst3ControlKind.knob:
            // On the face, or as a row of the panel; not both.
            final row = any(
              (o) => o.param == c.param && o.kind == Vst3ControlKind.readout,
            );
            expect(c.value != null, !row, reason: where);
            if (c.value case final v?) values.add((v, c));
          case Vst3ControlKind.slider || Vst3ControlKind.readout:
            expect(c.readout, isNotNull, reason: where);
            values.add((c.readout!.rect, c));
          case Vst3ControlKind.select || Vst3ControlKind.buttons:
            // A picture of each position, which prints or lights it.
            expect(c.frames, vst3Positions(type, c.param), reason: where);
          case Vst3ControlKind.footswitch:
            // The LED shows it.
            expect(layout.led.isEmpty, isFalse, reason: where);
        }
      }
      for (var i = 0; i < values.length; i++) {
        final (rect, owner) = values[i];
        final where = '${type.label}: the value of ${owner.param}';
        for (var j = i + 1; j < values.length; j++) {
          expect(
            rect.overlaps(values[j].$1),
            isFalse,
            reason: '$where covers the value of ${values[j].$2.param}',
          );
        }
        if (owner.kind == Vst3ControlKind.knob) {
          // A chip stays clear of every knob, label, the title, the LED and
          // the footswitch, and of the panel's controls; it may cover the
          // face's painting.
          for (final o in layout.obstacles) {
            expect(rect.overlaps(o), isFalse, reason: '$where covers $o');
          }
        }
        for (final c in controls) {
          if (identical(c, owner)) continue;
          // A panel value sits beside no knob; a knob's chip clears every
          // knob's pictures, which the editor draws over it.
          if (c.kind == Vst3ControlKind.knob &&
              owner.kind != Vst3ControlKind.knob) {
            continue;
          }
          if (c.kind == Vst3ControlKind.footswitch) continue;
          expect(
            rect.overlaps(c.rect),
            isFalse,
            reason: '$where covers ${c.kind.name} ${c.param}',
          );
        }
        if (owner.track case final track?) {
          expect(rect.overlaps(track), isFalse, reason: '$where on its track');
        }
      }
    }
  });

  test('a kind no console pedal stands for has no face', () {
    expect(Vst3Face.of(TrackEffectType.distortion), isNull);
    expect(Vst3Face.of(TrackEffectType.delay), isNotNull);
  });
}
