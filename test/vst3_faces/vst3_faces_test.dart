import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';

import '../helpers/helpers.dart';
import 'vst3_faces.dart';

/// The layout Segno.vst3's editors read (#1815): the committed
/// [kVst3FacesManifest] is what the console's drawing code lays out now, and
/// every control drives one of its plugin's parameters.
///
/// `--update-goldens` rewrites the manifest; then reinstall the plugins
/// (`packages/segno_engine/vst3/install.sh`) to render their art.
void main() {
  setUpAll(loadFxStompArt);

  testWidgets('the committed manifest is what the faces lay out', (
    tester,
  ) async {
    final text = encodeVst3Manifest(await vst3FacesManifest(tester));
    final file = File('${repoRoot.path}/$kVst3FacesManifest');
    if (autoUpdateGoldenFiles) {
      file.writeAsStringSync(text);
      return;
    }
    expect(
      file.readAsStringSync(),
      text,
      reason:
          'the pedal faces changed: run this test with --update-goldens and '
          'reinstall Segno.vst3',
    );
  });

  testWidgets('the layout is the same every time', (tester) async {
    final first = encodeVst3Manifest(await vst3FacesManifest(tester));
    final second = encodeVst3Manifest(await vst3FacesManifest(tester));
    expect(second, first);
  });

  testWidgets('every control drives a parameter of its plugin', (tester) async {
    final ids = _paramsHeaderIds();
    for (final type in vst3Kinds) {
      final face = Vst3Face.of(type);
      if (face == null) continue;
      final layout = await layOutVst3Face(tester, face);
      final window = Offset.zero & layout.size;
      final params = type.params;
      expect(
        layout.controls.where((c) => c.kind == Vst3ControlKind.footswitch),
        hasLength(1),
        reason: '${type.label} has one footswitch',
      );
      for (final c in layout.controls) {
        final where = '${type.label} ${c.kind.name} ${c.param}';
        expect(window.contains(c.rect.topLeft), isTrue, reason: where);
        expect(
          window.contains(c.rect.bottomRight - const Offset(1e-6, 1e-6)),
          isTrue,
          reason: where,
        );
        if (c.kind == Vst3ControlKind.footswitch) {
          expect(c.param, ids['kBypassId'], reason: where);
          continue;
        }
        expect(c.param, inInclusiveRange(0, params.length - 1), reason: where);
        final param = params[c.param];
        switch (c.kind) {
          case Vst3ControlKind.buttons:
            expect(fxParamIsChoice(param), isTrue, reason: where);
            expect(c.buttons, hasLength(param.steps), reason: where);
          case Vst3ControlKind.select:
            expect(fxParamIsChoice(param), isTrue, reason: where);
            expect(c.names, hasLength(param.steps), reason: where);
          case Vst3ControlKind.knob || Vst3ControlKind.slider:
            expect(
              c.frames,
              param.steps > 1 ? param.steps : kVst3Frames,
              reason: where,
            );
          case Vst3ControlKind.footswitch:
            break;
        }
      }
      // Every setting is on the face or in the panel, and every choice has
      // its selector.
      for (var p = 0; p < params.length; p++) {
        final kinds = layout.controls
            .where((c) => c.param == p)
            .map((c) => c.kind);
        expect(kinds, isNotEmpty, reason: '${type.label} param $p');
        if (fxParamIsChoice(params[p])) {
          expect(
            kinds.any(
              (k) =>
                  k == Vst3ControlKind.buttons || k == Vst3ControlKind.select,
            ),
            isTrue,
            reason: '${type.label} choice $p',
          );
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

  test('a kind no console pedal stands for has no face', () {
    expect(Vst3Face.of(TrackEffectType.distortion), isNull);
    expect(Vst3Face.of(TrackEffectType.delay), isNotNull);
  });
}

/// The fixed parameter ids in `params.h`, by name.
Map<String, int> _paramsHeaderIds() {
  final header = File('${repoRoot.path}/packages/segno_engine/vst3/params.h')
      .readAsStringSync();
  return {
    for (final m in RegExp(r'(k\w+Id) = (\d+),').allMatches(header))
      m[1]!: int.parse(m[2]!),
  };
}
