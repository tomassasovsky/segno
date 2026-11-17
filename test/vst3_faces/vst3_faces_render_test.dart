@Tags(['vst3-faces', 'skip_very_good_optimization'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';
import 'vst3_faces.dart';

/// Where the pictures go: `--dart-define=SEGNO_VST3_FACES_OUT=<dir>`, which
/// `packages/segno_engine/vst3/install.sh` passes. Without it nothing renders.
const String _out = String.fromEnvironment('SEGNO_VST3_FACES_OUT');

/// Only the face of this engine code, while trying one out
/// (`--dart-define=SEGNO_VST3_FACES_ONLY=<code>`).
const int _only = int.fromEnvironment(
  'SEGNO_VST3_FACES_ONLY',
  defaultValue: -1,
);

/// Renders the pictures Segno.vst3's editors draw (#1815), from the faces'
/// committed layout ([kVst3FacesManifest]); the plugin build bundles them.
///
/// It refuses to render art for a layout the manifest does not hold: the
/// plugin places the pictures by the manifest, so the two must agree.
void main() {
  setUpAll(() async {
    if (_out.isEmpty) return;
    await loadFxStompArt();
  });

  testWidgets(
    'renders every face',
    (tester) async {
      final manifest = encodeVst3Manifest(await vst3FacesManifest(tester));
      expect(
        File('${repoRoot.path}/$kVst3FacesManifest').readAsStringSync(),
        manifest,
        reason:
            'the committed manifest is stale: run '
            'test/vst3_faces/vst3_faces_test.dart with --update-goldens',
      );
      final out = Directory(_out)..createSync(recursive: true);
      for (final type in vst3Kinds) {
        if (_only >= 0 && type.code != _only) continue;
        final face = Vst3Face.of(type);
        if (face == null) continue;
        await renderVst3Face(tester, await layOutVst3Face(tester, face), out);
      }
      File('${out.path}/faces.json').writeAsStringSync(manifest);

      // The same face renders to the same bytes, so a reinstall changes only
      // what the console's drawing changed.
      final again = Directory.systemTemp.createTempSync('vst3_faces');
      addTearDown(() => again.deleteSync(recursive: true));
      final face = Vst3Face.of(
        vst3Kinds.firstWhere(
          (t) => (_only < 0 || t.code == _only) && Vst3Face.of(t) != null,
        ),
      )!;
      await renderVst3Face(tester, await layOutVst3Face(tester, face), again);
      for (final file in again.listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        expect(
          file.readAsBytesSync(),
          File('${out.path}/$name').readAsBytesSync(),
          reason: '$name renders differently the second time',
        );
      }
    },
    skip: _out.isEmpty,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
