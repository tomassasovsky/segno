import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';
import 'vst3_faces.dart';

/// Where the pictures go: `--dart-define=SEGNO_VST3_FACES_OUT=<dir>`, which
/// `packages/segno_engine/vst3/build.sh` passes. Without it nothing renders.
const String _out = String.fromEnvironment('SEGNO_VST3_FACES_OUT');

/// Only the face of this engine code, while trying one out
/// (`--dart-define=SEGNO_VST3_FACES_ONLY=<code>`).
const int _only = int.fromEnvironment(
  'SEGNO_VST3_FACES_ONLY',
  defaultValue: -1,
);

/// How many suites share the faces: `vst3_faces_render_<k>_test.dart`, one
/// per shard, which `build.sh` runs side by side (#1771). One suite renders
/// in one isolate, a picture at a time, so a single one took six and a half
/// minutes on CI's macOS runner.
const int kVst3RenderShards = 3;

/// Renders the pictures Segno.vst3's editors draw (#1815) for every face
/// whose position among the faces is [shard] modulo [kVst3RenderShards], from
/// the faces' committed layout ([kVst3FacesManifest]); the plugin build
/// bundles them.
///
/// Shard 0 also refuses to render art for a layout the manifest does not
/// hold, and writes the manifest beside the pictures: the plugin places the
/// pictures by the manifest, so the two must agree.
void vst3FacesRenderSuite({required int shard}) {
  setUpAll(() async {
    if (_out.isEmpty) return;
    await loadFxStompArt();
  });

  testWidgets(
    'renders every face of shard $shard of $kVst3RenderShards',
    (tester) async {
      final out = Directory(_out)..createSync(recursive: true);
      if (shard == 0) {
        // One suite per shard, or the faces of a missing one never render.
        expect(
          Directory('${repoRoot.path}/test/vst3_faces')
              .listSync()
              .where(
                (f) =>
                    RegExp(r'vst3_faces_render_\d+_test\.dart$')
                        .hasMatch(f.path),
              )
              .length,
          kVst3RenderShards,
          reason: 'one vst3_faces_render_<k>_test.dart per shard',
        );
        final manifest = encodeVst3Manifest(await vst3FacesManifest(tester));
        expect(
          File('${repoRoot.path}/$kVst3FacesManifest').readAsStringSync(),
          manifest,
          reason:
              'the committed manifest is stale: run '
              'test/vst3_faces/vst3_faces_test.dart with --update-goldens',
        );
        File('${out.path}/faces.json').writeAsStringSync(manifest);
      }
      final all = [for (final type in vst3Kinds) ?Vst3Face.of(type)];
      final faces = [
        for (final (i, face) in all.indexed)
          if (i % kVst3RenderShards == shard &&
              (_only < 0 || face.type.code == _only))
            face,
      ];
      for (final face in faces) {
        await renderVst3Face(tester, await layOutVst3Face(tester, face), out);
      }
      if (faces.isEmpty) return;

      // The same face renders to the same bytes, so a reinstall changes only
      // what the console's drawing changed.
      final again = Directory.systemTemp.createTempSync('vst3_faces');
      addTearDown(() => again.deleteSync(recursive: true));
      await renderVst3Face(
        tester,
        await layOutVst3Face(tester, faces.first),
        again,
      );
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
