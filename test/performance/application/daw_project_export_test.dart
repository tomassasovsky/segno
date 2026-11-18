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
                    'pcmRef': 'loops/track0-lane0.wav',
                  },
                ],
              },
            ],
          },
      }),
    );
  }

  /// The render's stem index, listing [lanes] (#1824).
  void writeIndex(List<Map<String, Object>> lanes) =>
      File('${dir.path}/stems/stems.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'lanes': lanes}));

  /// A rendered lane stem holding [bytes], and the index that lists it
  /// (#1824).
  File writeStem(List<int> bytes) {
    writeIndex(const [
      {'channel': 0, 'lane': 0, 'dry': 'stems/dry/track0-lane0.wav'},
    ]);
    return File('${dir.path}/stems/dry/track0-lane0.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  test('writes project.als and fx-chains.txt from the bundle and leaves its '
      'audio alone', () async {
    writeManifest(withTrack: true);
    final stem = writeStem([1, 2, 3, 4]);
    final stamp = stem.lastModifiedSync();

    final tracks = await writeProject();

    expect(tracks, hasLength(1));
    expect(File('${dir.path}/project.als').existsSync(), isTrue);
    expect(File('${dir.path}/fx-chains.txt').existsSync(), isTrue);
    expect(stem.readAsBytesSync(), [1, 2, 3, 4]);
    // The bundle is a Live Project, so Live saves the set in place (#1837).
    final info = Directory('${dir.path}/Ableton Project Info');
    expect(info.existsSync(), isTrue);
    expect(info.listSync(), isEmpty);
    expect(stem.lastModifiedSync(), stamp);
  });

  test("writes both files through the take's durable writer (#1801)", () async {
    writeManifest(withTrack: true);
    writeStem([0]);

    await writeProject();

    expect(written, ['project.als', 'fx-chains.txt']);
  });

  test('writes no project.als for a take with no tracks, since Live cannot '
      'open one', () async {
    writeManifest();

    expect(await writeProject(), isEmpty);
    expect(File('${dir.path}/project.als').existsSync(), isFalse);
    expect(Directory('${dir.path}/Ableton Project Info').existsSync(), isFalse);
    expect(File('${dir.path}/fx-chains.txt').existsSync(), isTrue);
  });

  test('removes a project.als an earlier version wrote for a take with no '
      'tracks, which Live refuses', () async {
    writeManifest();
    writeIndex(const []);
    File('${dir.path}/project.als').writeAsBytesSync([1, 2, 3]);
    Directory('${dir.path}/Ableton Project Info').createSync();

    expect(await writeProject(), isEmpty);
    expect(File('${dir.path}/project.als').existsSync(), isFalse);
    expect(Directory('${dir.path}/Ableton Project Info').existsSync(), isFalse);
  });

  test('never replaces a project with one that has no stems: a take with '
      'no stem index leaves its project as it was (#1824)', () async {
    writeManifest(withTrack: true);
    File('${dir.path}/project.als').writeAsBytesSync([1, 2, 3]);

    await expectLater(writeProject(), throwsA(isA<StemsNotRendered>()));
    expect(File('${dir.path}/project.als').readAsBytesSync(), [1, 2, 3]);
    expect(
      const StemsNotRendered('/take').toString(),
      'StemsNotRendered: /take has no stems/stems.json',
    );
  });

  test('writes the project again into a bundle that is already a Live '
      'Project', () async {
    writeManifest(withTrack: true);
    writeStem([0]);
    await writeProject();

    expect(await writeProject(), hasLength(1));
    expect(Directory('${dir.path}/Ableton Project Info').existsSync(), isTrue);
  });

  test('reads the manifest afresh on every call', () async {
    writeManifest();
    expect(await writeProject(), isEmpty);

    writeStem([0]);
    writeManifest(withTrack: true);

    expect(await writeProject(), hasLength(1));
  });

  test('throws what the write throws, so the caller can report it', () async {
    writeManifest(withTrack: true);
    writeStem([0]);
    // A directory where the Live Set goes: the write fails for real.
    Directory('${dir.path}/project.als').createSync();

    await expectLater(writeProject(), throwsA(isA<FileSystemException>()));
  });

  test('a Live Project folder that cannot be made leaves the previous '
      'project whole', () async {
    writeManifest(withTrack: true);
    writeStem([0]);
    File('${dir.path}/project.als').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/Ableton Project Info').writeAsBytesSync([0]);

    await expectLater(writeProject(), throwsA(isA<FileSystemException>()));

    expect(File('${dir.path}/project.als').readAsBytesSync(), [1, 2, 3]);
  });
}
