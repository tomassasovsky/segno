import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno_engine/segno_engine.dart';

import 'helpers/fake_performance_engine.dart';

/// The Library's view of finished recordings (#1178 Part 7): the listing,
/// the parts of #1198's format, the DAW package, Delete and Preview.
void main() {
  late Directory tempDir;
  late String root;
  late FakePerformanceEngine engine;
  late GuardRegistry guards;
  late PerformanceRepository repo;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('segno_capture_library');
    root = '${tempDir.path}/exports';
    Directory(root).createSync();
    engine = FakePerformanceEngine();
    guards = GuardRegistry();
    repo = PerformanceRepository(
      guards: guards,
      engine: engine,
      exportsRoot: () async => root,
    );
  });

  tearDown(() {
    repo.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// Writes a take at `<root>/<under>/<name>` with sidecar [slug] and
  /// returns its directory. [parts] is the sidecar's `parts` array (#1198);
  /// [files] are written with the given byte counts.
  String take(
    String name, {
    String? slug,
    bool finalized = true,
    String under = '',
    Object? parts,
    int captureFrames = 4800,
    List<int> capturedInputs = const [],
    Map<String, int> files = const {},
  }) {
    final dir = under.isEmpty ? '$root/$name' : '$root/$under/$name';
    Directory(dir).createSync(recursive: true);
    File('$dir/performance.json').writeAsStringSync(
      jsonEncode({
        'slug': slug ?? name,
        'sample_rate': 48000,
        'capture_frames': captureFrames,
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': capturedInputs,
        },
        'parts': ?parts,
        'finalized': finalized,
      }),
    );
    for (final entry in files.entries) {
      File('$dir/${entry.key}')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(entry.value));
    }
    return dir;
  }

  Map<String, Object> part(
    int stream,
    int index,
    String file, {
    int frames = 1000,
    int bytes = 8084,
  }) => {
    'stream': stream,
    'index': index,
    'file': file,
    'frames': frames,
    'bytes': bytes,
    'overs': 0,
  };

  group('listCaptures', () {
    test('lists finished takes newest first, with the recovered ones kept '
        'and marked', () async {
      take('perf-20261006-201500');
      take('perf-20261006-221500');
      take('perf-20261005-090000', under: 'recovered');

      final list = await repo.listCaptures();

      expect(list.map((c) => c.name), [
        'perf-20261006-221500',
        'perf-20261006-201500',
        'perf-20261005-090000',
      ]);
      expect(list.map((c) => c.recovered), [false, false, true]);
      expect(list.last.path, '$root/recovered/perf-20261005-090000');
      expect(list.first.startedAt, DateTime(2026, 10, 6, 22, 15));
    });

    test('names a renamed take by its directory and dates it by the slug it '
        'was armed under', () async {
      take('Evening loop', slug: 'perf-20261006-201500');

      final only = (await repo.listCaptures()).single;

      expect(only.name, 'Evening loop');
      expect(only.startedAt, DateTime(2026, 10, 6, 20, 15));
    });

    test('leaves out unfinalized takes, salvage output that has not moved, '
        'unreadable sidecars and loose files', () async {
      take('perf-20261006-201500', finalized: false);
      final stranded = take('perf-20261006-201600');
      File(
        '$stranded/${PerformanceRepository.recoveryMarkerName}',
      ).writeAsStringSync('');
      Directory('$root/broken').createSync();
      File('$root/broken/performance.json').writeAsStringSync('{');
      Directory('$root/empty').createSync();
      File('$root/loose.wav').writeAsStringSync('');
      take('perf-20261006-201700');

      final list = await repo.listCaptures();

      expect(list.map((c) => c.name), ['perf-20261006-201700']);
    });

    test('lists nothing when the exports root does not exist', () async {
      Directory(root).deleteSync(recursive: true);
      expect(await repo.listCaptures(), isEmpty);
    });

    test("reads #1198's parts in stream and index order, and sums the main "
        "output's frames", () async {
      take(
        'perf-20261006-201500',
        parts: [
          part(1, 1, 'input-0-001.wav', frames: 30),
          part(0, 2, 'master-002.wav', frames: 200),
          part(0, 1, 'master-001.wav'),
        ],
      );

      final only = (await repo.listCaptures()).single;

      expect(only.parts.map((p) => p.file), [
        'master-001.wav',
        'master-002.wav',
        'input-0-001.wav',
      ]);
      expect(only.masterParts, hasLength(2));
      expect(only.durationFrames, 1200);
      expect(only.sampleRate, 48000);
      expect(only.duration, const Duration(milliseconds: 25));
    });

    test('a parts list that does not read gives no parts, and the length '
        'from the capture count', () async {
      take(
        'perf-20261006-201500',
        captureFrames: 9600,
        parts: [
          {'stream': 0, 'index': 1, 'file': '../escape.wav'},
        ],
      );

      final only = (await repo.listCaptures()).single;

      expect(only.parts, isEmpty);
      expect(only.durationFrames, 9600);
    });

    test(
      'a take written before the parts format reads its single files',
      () async {
        take(
          'perf-20261006-201500',
          capturedInputs: [3, 1],
          files: {
            'master.wav': 100,
            'live-input-1.wav': 60,
            // Input 3's file is missing: it is left out, not guessed at.
          },
        );

        final only = (await repo.listCaptures()).single;

        expect(only.parts, const [
          CapturePart(
            stream: 0,
            index: 1,
            file: 'master.wav',
            frames: 4800,
            bytes: 100,
          ),
          CapturePart(
            stream: 2,
            index: 1,
            file: 'live-input-1.wav',
            frames: 4800,
            bytes: 60,
          ),
        ]);
        expect(only.durationFrames, 4800);
      },
    );

    test('says whether the DAW project is in the bundle', () async {
      take('perf-20261006-201500', files: {'project.als': 10});
      take('perf-20261006-201600');

      final list = await repo.listCaptures();

      expect(list.map((c) => c.hasDawProject), [false, true]);
    });
  });

  group('CapturePart.fromJson', () {
    test('refuses every malformed field', () {
      final good = part(0, 1, 'master-001.wav');
      expect(CapturePart.fromJson(good).file, 'master-001.wav');
      for (final bad in <Map<String, Object>>[
        {...good, 'stream': -1},
        {...good, 'stream': 'x'},
        {...good, 'index': 0},
        {...good, 'file': ''},
        {...good, 'file': 'a/b.wav'},
        {...good, 'file': r'a\b.wav'},
        {...good, 'frames': -1},
        {...good, 'bytes': -1},
      ]) {
        expect(
          () => CapturePart.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('dawPackageFiles', () {
    test('lists the parts, the rendered stems and the project files that '
        'exist, keeping their paths in the bundle', () async {
      take(
        'perf-20261006-201500',
        parts: [
          part(0, 1, 'master-001.wav'),
          part(0, 2, 'master-002.wav'),
          part(1, 1, 'input-0-001.wav'),
        ],
        files: {
          'master-001.wav': 10,
          'input-0-001.wav': 10,
          'stems/wet/track1.wav': 4,
          'stems/wet/track0.wav': 4,
          'stems/dry/track0.wav': 4,
          'stems/dry/notes.txt': 4,
          'project.als': 4,
          'events.log': 4,
        },
      );
      final capture = (await repo.listCaptures()).single;

      expect(repo.dawPackageFiles(capture), [
        'master-001.wav',
        'input-0-001.wav',
        'stems/dry/track0.wav',
        'stems/wet/track0.wav',
        'stems/wet/track1.wav',
        'project.als',
      ]);
    });
  });

  test(
    'dawPackageFiles of a take not rendered yet is its audio alone',
    () async {
      take(
        'perf-20261006-201500',
        parts: [part(0, 1, 'master-001.wav')],
        files: {'master-001.wav': 10},
      );
      final capture = (await repo.listCaptures()).single;

      expect(repo.dawPackageFiles(capture), ['master-001.wav']);
    },
  );

  group('deleteCapture', () {
    test('deletes a finished take, recovered or not', () async {
      take('perf-20261006-201500');
      take('perf-20261005-090000', under: 'recovered');

      for (final capture in await repo.listCaptures()) {
        await repo.deleteCapture(capture);
      }

      expect(await repo.listCaptures(), isEmpty);
      expect(Directory(root).existsSync(), isTrue);
      expect(Directory('$root/recovered').existsSync(), isTrue);
    });

    test('refuses anything that is not a finished take', () async {
      final dir = take('perf-20261006-201500', finalized: false);
      final outside = Directory('${tempDir.path}/elsewhere')..createSync();
      // A finished take, but not one of this repository's.
      final foreign = '${outside.path}/perf-20261006-201500';
      Directory(foreign).createSync();
      File(
        '$root/perf-20261006-201500/performance.json',
      ).copySync('$foreign/performance.json');
      File('$foreign/performance.json').writeAsStringSync(
        File('$foreign/performance.json').readAsStringSync().replaceFirst(
          '"finalized":false',
          '"finalized":true',
        ),
      );
      CaptureSummary at(String path) => CaptureSummary(
        path: path,
        name: 'x',
        durationFrames: 0,
        sampleRate: 48000,
        parts: const [],
      );

      for (final path in [
        dir,
        outside.path,
        foreign,
        '$root/recovered',
        root,
      ]) {
        await expectLater(
          repo.deleteCapture(at(path)),
          throwsArgumentError,
          reason: path,
        );
      }
      expect(Directory(dir).existsSync(), isTrue);
      expect(outside.existsSync(), isTrue);
      expect(Directory(foreign).existsSync(), isTrue);
    });

    test('is refused while a render may be writing into a bundle', () async {
      take('perf-20261006-201500');
      final capture = (await repo.listCaptures()).single;
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 40,
      );

      await expectLater(
        repo.deleteCapture(capture),
        throwsA(isA<PerformanceCaptureBusy>()),
      );
      expect(Directory(capture.path).existsSync(), isTrue);
    });

    test('is refused by the guard table during a shutdown, and holds its '
        'guard only while it deletes', () async {
      take('perf-20261006-201500');
      final capture = (await repo.listCaptures()).single;
      final restart = guards.enter(
        GuardKind.restart,
        const GuardScope.internal(),
        purpose: 'restart',
      );

      await expectLater(
        repo.deleteCapture(capture),
        throwsA(isA<GuardRefused>()),
      );
      expect(Directory(capture.path).existsSync(), isTrue);

      restart.release();
      await repo.deleteCapture(capture);
      expect(guards.active, isEmpty);
    });
  });

  group('Preview', () {
    test("plays the main output's first part", () async {
      take(
        'perf-20261006-201500',
        parts: [
          part(1, 1, 'input-0-001.wav'),
          part(0, 2, 'master-002.wav'),
          part(0, 1, 'master-001.wav'),
        ],
        files: {'master-001.wav': 10, 'master-002.wav': 10},
      );
      final capture = (await repo.listCaptures()).single;

      final started = await repo.startAudition(capture);

      expect(started.result, EngineResult.ok);
      expect(engine.auditionPaths, ['${capture.path}/master-001.wav']);
    });

    test(
      'a take without a main-output file is refused before the engine',
      () async {
        take('perf-20261006-201500', parts: [part(0, 1, 'master-001.wav')]);
        take('perf-20261006-201600', parts: [part(1, 1, 'input-0-001.wav')]);

        for (final capture in await repo.listCaptures()) {
          final started = await repo.startAudition(capture);
          expect(started.result, EngineResult.invalid);
        }
        expect(engine.auditionPaths, isEmpty);
      },
    );

    test('the waveform spans every main-output part, each in proportion to '
        'its length', () async {
      take(
        'perf-20261006-201500',
        parts: [
          part(0, 1, 'master-001.wav', frames: 3000),
          part(0, 2, 'master-002.wav'),
        ],
        files: {'master-001.wav': 10, 'master-002.wav': 10},
      );
      final capture = (await repo.listCaptures()).single;
      engine.peaksOf = (path, buckets) => Float32List.fromList(
        List.filled(buckets, path.endsWith('001.wav') ? 0.25 : 0.5),
      );

      final peaks = await repo.readPeaks(capture, buckets: 8);

      expect(engine.peaksRequests.map((r) => r.$2), [6, 2]);
      expect(peaks, [0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.5, 0.5]);
    });

    test('no waveform when a part does not read or there is none', () async {
      take(
        'perf-20261006-201500',
        parts: [
          part(0, 1, 'master-001.wav'),
          part(0, 2, 'master-002.wav'),
        ],
        files: {'master-001.wav': 10},
      );
      take('perf-20261006-201600', parts: <Object>[]);
      engine.peaksOf = (_, buckets) => Float32List(buckets);

      for (final capture in await repo.listCaptures()) {
        expect(await repo.readPeaks(capture, buckets: 8), isNull);
      }
    });
  });
}
