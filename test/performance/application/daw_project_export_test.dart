import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/performance/application/daw_project_export.dart';

void main() {
  late Directory dir;
  late List<String> written;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('segno_daw_project');
    written = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Stands in for `PerformanceRepository.writeTakeFile`, which is tested
  /// there: records each file it is given and writes it in place.
  Future<void> write(String take, String name, List<int> bytes) async {
    written.add(name);
    await File('$take/$name').writeAsBytes(bytes);
  }

  Future<List<DawTrack>> writeProject() =>
      writeDawProject(dir.path, write: write);

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

    final tracks = await writeProject();

    expect(tracks, hasLength(1));
    expect(File('${dir.path}/project.als').existsSync(), isTrue);
    expect(File('${dir.path}/fx-chains.txt').existsSync(), isTrue);
    expect(stem.readAsBytesSync(), [1, 2, 3, 4]);
    expect(stem.lastModifiedSync(), stamp);
  });

  test("writes both files through the take's durable writer (#1801)", () async {
    writeManifest(withTrack: true);
    File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);

    await writeProject();

    expect(written, ['project.als', 'fx-chains.txt']);
  });

  test('writes no project.als for a take with no tracks, since Live cannot '
      'open one', () async {
    writeManifest();

    expect(await writeProject(), isEmpty);
    expect(File('${dir.path}/project.als').existsSync(), isFalse);
    expect(File('${dir.path}/fx-chains.txt').existsSync(), isTrue);
  });

  test('removes a project.als an earlier version wrote for a take with no '
      'tracks, which Live refuses', () async {
    writeManifest();
    File('${dir.path}/project.als').writeAsBytesSync([1, 2, 3]);

    expect(await writeProject(), isEmpty);
    expect(File('${dir.path}/project.als').existsSync(), isFalse);
  });

  test('reads the manifest afresh on every call', () async {
    writeManifest();
    expect(await writeProject(), isEmpty);

    File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    writeManifest(withTrack: true);

    expect(await writeProject(), hasLength(1));
  });

  test('throws what the write throws, so the caller can report it', () async {
    writeManifest(withTrack: true);
    File('${dir.path}/stems/wet/track0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    // A directory where the Live Set goes: the write fails for real.
    Directory('${dir.path}/project.als').createSync();

    await expectLater(writeProject(), throwsA(isA<FileSystemException>()));
  });
}
