import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/performance/application/daw_project_export.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('segno_daw_project'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A finalized take's sidecar; [withTrack] gives it one channel whose
  /// lane points at a rendered stem.
  void writeManifest({bool withTrack = false}) {
    File('${dir.path}/performance.json').writeAsStringSync(
      jsonEncode({
        'slug': 'perf-20261006-201500',
        'sample_rate': 48000,
        'capture_frames': 4800,
        'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
        'overrun_count': 0,
        'overrun_gaps': <Map<String, dynamic>>[],
        'layers': <Map<String, dynamic>>[],
        'finalized': true,
        if (withTrack)
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/wet/track0.wav',
                  },
                ],
              },
            ],
          },
      }),
    );
  }

  test('writes project.als and fx-chains.txt from the bundle and leaves its '
      'audio alone', () async {
    writeManifest(withTrack: true);
    final stem = File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);
    final stamp = stem.lastModifiedSync();

    final tracks = await writeDawProject(dir.path);

    expect(tracks, hasLength(1));
    expect(File('${dir.path}/project.als').existsSync(), isTrue);
    expect(File('${dir.path}/fx-chains.txt').existsSync(), isTrue);
    expect(stem.readAsBytesSync(), [1, 2, 3, 4]);
    expect(stem.lastModifiedSync(), stamp);
  });

  test('reads the manifest afresh on every call', () async {
    writeManifest();
    expect(await writeDawProject(dir.path), isEmpty);

    File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    writeManifest(withTrack: true);

    expect(await writeDawProject(dir.path), hasLength(1));
  });

  test('throws what the write throws, so the caller can report it', () async {
    writeManifest(withTrack: true);
    File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    // A directory where the Live Set goes: the write fails for real.
    Directory('${dir.path}/project.als').createSync();

    await expectLater(
      writeDawProject(dir.path),
      throwsA(isA<FileSystemException>()),
    );
  });
}
