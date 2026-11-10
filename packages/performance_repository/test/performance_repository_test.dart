import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:performance_repository/src/legacy_capture.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:wav_codec/wav_codec.dart';

import 'helpers/fake_performance_engine.dart';
import 'helpers/fake_storage_io.dart';
import 'helpers/native_capture_fixture.dart';

/// A [File] whose [readAsString] parks on [_gate] before delegating — an
/// `IOOverrides` hook that holds a finalize provably mid-flight so a test
/// can interleave a second finalize underneath it deterministically. Only
/// the members the finalize path touches on the manifest file are
/// implemented; anything else is a test bug and throws.
class _GatedReadFile implements File {
  _GatedReadFile(this._inner, this._gate);

  final File _inner;
  final Future<void> _gate;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    await _gate;
    return _inner.readAsString(encoding: encoding);
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _inner.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'not reached by _finalize on the manifest file: $invocation',
  );
}

/// Fails the selected asynchronous write while leaving the earlier contents
/// untouched, as a full disk or revoked export volume can do after native arm.
class _FailWriteFile implements File {
  _FailWriteFile(this._inner);

  final File _inner;

  @override
  bool existsSync() => _inner.existsSync();

  @override
  void deleteSync({bool recursive = false}) =>
      _inner.deleteSync(recursive: recursive);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await _inner.writeAsString('{"truncated":', flush: true);
    throw const FileSystemException('arm snapshot write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'not reached by arm snapshot write: $invocation',
  );
}

class _ThrowAfterArmEngine extends FakePerformanceEngine {
  bool throwSnapshot = false;
  bool throwOutputFx = false;
  bool throwDisarmOnce = false;

  @override
  EngineSnapshot snapshot() {
    if (throwSnapshot && perfArmed) throw StateError('snapshot unavailable');
    return super.snapshot();
  }

  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) {
    if (throwOutputFx) throw StateError('output chain unavailable');
    return super.outputFxSnapshot(bus: bus);
  }

  @override
  EngineResult perfDisarm() {
    if (throwDisarmOnce) {
      throwDisarmOnce = false;
      perfDisarmCalls++;
      throw StateError('native cleanup unavailable');
    }
    return super.perfDisarm();
  }
}

/// The finalized `performance.json` on its way in, refusing to be written —
/// the finalize of a take whose disk filled at the end.
class _ManifestWriteFails implements File {
  _ManifestWriteFails(this._inner);

  final File _inner;

  @override
  String get path => _inner.path;

  @override
  bool existsSync() => _inner.existsSync();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _inner.readAsString(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async => throw const FileSystemException('No space left on device');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'not reached by finalize on the manifest: $invocation',
  );
}

void main() {
  late Directory tempDir;
  late FakePerformanceEngine engine;
  late PerformanceRepository repo;
  late DateTime clock;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('segno_perf');
    engine = FakePerformanceEngine();
    clock = DateTime(2026, 7, 6, 14, 30, 15);
    repo = PerformanceRepository(
      storageIo: fakeStorageIo,
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
    );
  });

  tearDown(() {
    repo.dispose();
    tempDir.deleteSync(recursive: true);
  });

  test('exportsRoot exposes the injected exports-root resolver', () async {
    // Public surface, not a convenience: the app's free-space gate (#640)
    // measures the volume a capture WOULD land on while still idle, before
    // arm has created anything for armedDirectory to point at.
    expect(await repo.exportsRoot(), '${tempDir.path}/exports');
  });

  group('volumeSpace (#806, #1177)', () {
    // A capture re-checks the volume it is filling. Asking the engine keeps
    // that a syscall; the `df` it replaced was a fork() of the whole app,
    // twelve times a minute, for the length of a take.
    test('reports what the engine measured, total and free', () {
      engine
        ..totalBytes = 65536
        ..freeBytes = 4096;
      expect(
        repo.volumeSpace('/data'),
        const VolumeSpace(totalBytes: 65536, freeBytes: 4096),
      );
    });

    test('passes a platform that cannot answer straight through as null', () {
      engine.freeBytes = null;
      expect(repo.volumeSpace('/data'), isNull);
    });
  });

  group('arm', () {
    test('passes the reserve to the engine, and none when not given '
        '(#1198)', () async {
      await repo.arm();
      expect(engine.lastPerfTarget!.reserveBytes, isNull);
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      await repo.disarm();

      final reserved = PerformanceRepository(
        storageIo: fakeStorageIo,
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock.add(const Duration(minutes: 1)),
        guards: GuardRegistry(),
        reserveBytes: 1000000000,
      );
      await reserved.arm();
      expect(engine.lastPerfTarget!.reserveBytes, 1000000000);
    });

    test('a take on a USB drive keeps no reserve there (#1177)', () async {
      final reserved = PerformanceRepository(
        storageIo: fakeStorageIo,
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
        guards: GuardRegistry(),
        reserveBytes: 1000000000,
      );
      await reserved.arm(
        root: '${tempDir.path}/usb/Segno/Performances',
        scope: const GuardScope.removable(1),
      );
      expect(engine.lastPerfTarget!.reserveBytes, isNull);
      expect(
        reserved.minimumFreeBytesToArmAt(root: '${tempDir.path}/usb'),
        reserved.minimumFreeBytesToArm - 1000000000,
      );
    });

    test('a settled snapshot write failure keeps live capture owned until '
        'the engine confirms a stop', () async {
      var snapshotWrites = 0;
      final testZone = Zone.current;
      final failed = IOOverrides.runZoned(
        () => repo.arm(),
        createFile: (path) {
          final real = testZone.run(() => File(path));
          if (path.endsWith('/arm-snapshot.json.pending') &&
              ++snapshotWrites == 1) {
            return _FailWriteFile(real);
          }
          return real;
        },
      );
      await expectLater(failed, throwsA(isA<FileSystemException>()));
      expect(snapshotWrites, 1);
      expect(engine.perfArmed, isTrue);
      expect(repo.armedDirectory, engine.lastPerfCaptureDir);
      expect(Directory(repo.armedDirectory!).existsSync(), isTrue);
      expect(
        File('${repo.armedDirectory}/arm-snapshot.json').existsSync(),
        isFalse,
      );
      expect(
        File('${repo.armedDirectory}/arm-snapshot.json.pending').existsSync(),
        isFalse,
      );

      engine.perfDisarmResult = EngineResult.device;
      expect(await repo.disarm(), EngineResult.device);
      expect(repo.armedDirectory, engine.lastPerfCaptureDir);
      expect(engine.perfArmed, isTrue);
      expect(await repo.arm(), EngineResult.ok);
      expect(engine.perfArmCalls, 1);

      engine.perfDisarmResult = EngineResult.ok;
      expect(await repo.disarm(), EngineResult.ok);
      expect(engine.perfArmed, isFalse);
    });

    test('waits for the callback to acknowledge a queued arm before reading '
        'its selected destination', () async {
      final queued = Completer<void>();
      engine
        ..perfArmQueues = true
        ..onPerfArmQueued = queued.complete
        ..perfCaptureBusAtArm = 1;
      final arming = repo.arm();
      await queued.future.timeout(const Duration(seconds: 5));
      expect(engine.perfArmPending, isTrue);
      expect(repo.armedDirectory, engine.lastPerfCaptureDir);
      expect(engine.perfArmed, isFalse);
      engine.acknowledgePerfArm();

      expect(await arming, EngineResult.ok);
      final json =
          jsonDecode(
                File(
                  '${repo.armedDirectory}/arm-snapshot.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(json['captureBus'], 1);
      expect(json['captureMask'], 0xC);
    });

    test('a queued arm that never acknowledges is canceled and cannot '
        'alias a later capture', () async {
      engine.perfArmQueues = true;
      expect(await repo.arm(), EngineResult.device);
      final abandoned = engine.lastPerfCaptureDir!;
      expect(engine.perfDisarmCalls, 1);
      expect(engine.perfArmPending, isFalse);
      expect(repo.armedDirectory, isNull);
      expect(Directory(abandoned).existsSync(), isTrue);

      engine.perfArmQueues = false;
      expect(await repo.arm(), EngineResult.ok);
      expect(repo.armedDirectory, isNot(abandoned));
      expect(engine.lastPerfCaptureDir, repo.armedDirectory);
    });

    test('a post-arm snapshot exception stops capture and preserves its '
        'directory', () async {
      final broken = _ThrowAfterArmEngine()..throwSnapshot = true;
      final localRepo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(localRepo.dispose);

      await expectLater(localRepo.arm(), throwsStateError);
      expect(broken.perfDisarmCalls, 1);
      expect(broken.perfArmed, isFalse);
      expect(localRepo.armedDirectory, isNull);
      expect(Directory(broken.lastPerfCaptureDir!).existsSync(), isTrue);
    });

    test('a post-arm output-chain exception keeps ownership when stop is '
        'refused, then disarms without inventing an arm snapshot', () async {
      final broken = _ThrowAfterArmEngine()
        ..throwOutputFx = true
        ..perfDisarmResult = EngineResult.device;
      final localRepo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(localRepo.dispose);

      await expectLater(localRepo.arm(), throwsStateError);
      final dir = broken.lastPerfCaptureDir!;
      expect(localRepo.armedDirectory, dir);
      expect(broken.perfArmed, isTrue);
      expect(File('$dir/arm-snapshot.json').existsSync(), isFalse);
      writeNativeSidecar(dir);

      broken.perfDisarmResult = EngineResult.ok;
      expect(await localRepo.disarmAndFinalize(), EngineResult.ok);
      final manifest =
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest.containsKey('armSnapshot'), isFalse);
    });

    test('a thrown native cleanup after post-arm getter failure retains '
        'visible ownership for an immediate disarm retry', () async {
      final broken = _ThrowAfterArmEngine()
        ..throwOutputFx = true
        ..throwDisarmOnce = true;
      final localRepo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(localRepo.dispose);
      final statuses = <PerformanceCaptureStatus>[];
      final sub = localRepo.captureStatus.listen(statuses.add);
      addTearDown(sub.cancel);

      await expectLater(localRepo.arm(), throwsStateError);
      await pumpEventQueue();
      final dir = broken.lastPerfCaptureDir!;
      expect(statuses.last, PerformanceCaptureStatus.armed);
      expect(localRepo.armedDirectory, dir);
      expect(broken.perfArmed, isTrue);
      expect(broken.perfDisarmCalls, 1);
      expect(File('$dir/arm-snapshot.json').existsSync(), isFalse);
      expect(await localRepo.arm(), EngineResult.ok);
      expect(broken.perfArmCalls, 1);

      writeNativeSidecar(dir);
      expect(await localRepo.disarm(), EngineResult.ok);
      expect(broken.perfArmed, isFalse);
      expect(localRepo.armedDirectory, isNull);
      final manifest =
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest.containsKey('armSnapshot'), isFalse);
    });

    test('creates the slugged bundle directory and arms the engine', () async {
      final result = await repo.arm();
      expect(result, EngineResult.ok);
      expect(
        repo.armedDirectory,
        '${tempDir.path}/exports/perf-20260706-143015',
      );
      expect(Directory(repo.armedDirectory!).existsSync(), isTrue);
      expect(engine.perfArmed, isTrue);
      expect(engine.lastPerfCaptureDir, repo.armedDirectory);
    });

    test('a root puts this take under it, and the next arm without one '
        'goes back to the exports root (#1177)', () async {
      final usb = '${tempDir.path}/media/1-SEGNO_USB/Segno/Performances';
      expect(await repo.arm(root: usb), EngineResult.ok);
      expect(repo.armedDirectory, '$usb/perf-20260706-143015');
      expect(Directory(repo.armedDirectory!).existsSync(), isTrue);
      expect(engine.lastPerfCaptureDir, repo.armedDirectory);
      await repo.disarmAndFinalize();

      clock = clock.add(const Duration(minutes: 1));
      expect(await repo.arm(), EngineResult.ok);
      expect(repo.armedDirectory, startsWith('${tempDir.path}/exports/'));
    });

    test('setFollowOutput forwards the policy to the engine, and the arm '
        "snapshot records the take's policy and destination 0's facts "
        '(slice 3b)', () async {
      expect(repo.setFollowOutput(follow: true), EngineResult.ok);
      expect(engine.perfFollowOutput, isTrue);
      engine
        ..outputLevels = [0.5, 1]
        ..outputMuted = [true, false];

      await repo.arm();
      final dir = repo.armedDirectory!;
      final armJson =
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(armJson['followOutput'], isTrue);
      expect(armJson.containsKey('captureBus'), isFalse);
      expect(armJson['outputLevel'], 0.5);
      expect(armJson['outputMuted'], isTrue);
    });

    test('the arm snapshot records the destination the engine settles on '
        'INSIDE the arm, not the one the pre-arm snapshot named', () async {
      // The gate moves while this arm exports lanes and writes the manifest:
      // the engine picks destination 1, so the manifest must say 1 and carry
      // ITS facts, or the offline render replays the wrong level rides.
      engine
        ..perfCaptureBus = 0
        ..perfCaptureBusAtArm = 1
        ..outputLevels = [1, 0.25]
        ..outputMuted = [true, false];

      await repo.arm();
      final dir = repo.armedDirectory!;
      final armJson =
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(armJson['captureBus'], 1);
      expect(armJson['outputLevel'], 0.25);
      expect(armJson.containsKey('outputMuted'), isFalse);
    });

    test(
      'the take keeps the policy settled at arm after pre-arm I/O',
      () async {
        engine
          ..perfFollowOutput = false
          ..perfFollowOutputAtArm = true;
        expect(await repo.arm(), EngineResult.ok);
        final manifest =
            jsonDecode(
                  File(
                    '${repo.armedDirectory}/arm-snapshot.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest['followOutput'], isTrue);
        engine.perfFollowOutput = false;
        expect(engine.snapshot().perfFollowOutput, isTrue);
        expect(PerformanceArmSnapshot.fromJson(manifest).followOutput, isTrue);
      },
    );

    test(
      'the arm snapshot stores the selected output chain and mask',
      () async {
        engine
          ..perfCaptureBus = 0
          ..perfCaptureBusAtArm = 1
          ..perfOutputEnabledMask = 0xC;
        engine.outputChains[0] = OutputFxSnapshot(
          effects: [
            OutputEffectSnapshot(
              type: TrackEffectType.reverb.code,
              params: TrackEffectType.reverb.defaultParams,
            ),
          ],
        );
        engine.outputChains[1] = OutputFxSnapshot(
          effects: [
            OutputEffectSnapshot(
              type: TrackEffectType.drive.code,
              params: TrackEffectType.drive.defaultParams,
            ),
          ],
          chainEnabled: false,
        );
        expect(await repo.arm(), EngineResult.ok);
        final manifest =
            jsonDecode(
                  File(
                    '${repo.armedDirectory}/arm-snapshot.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest['captureBus'], 1);
        expect(manifest['captureMask'], 0xC);
        expect(manifest['outputEnabledMask'], 0xC);
        expect(manifest['outputChainEnabled'], isFalse);
        final effects = manifest['outputEffects'] as List<dynamic>;
        expect(
          (effects.single as Map<String, dynamic>)['type'],
          TrackEffectType.drive.code,
        );
      },
    );

    test('an engine with no captured destination refuses the arm', () async {
      engine
        ..perfCaptureBus = -1
        ..perfCaptureBusAtArm = -1
        ..outputLevels = const []
        ..outputMuted = const [];

      expect(await repo.arm(), EngineResult.invalid);
      expect(repo.armedDirectory, isNull);
      expect(engine.perfArmed, isFalse);
    });

    test(
      'empty arm lanes preserve settings without PCM through finalize',
      () async {
        engine.seedLane(
          0,
          0,
          Float32List(0),
          trackState: TrackState.empty,
          volume: 0.6,
          laneVolume: 0.4,
          lanePan: -0.5,
          laneMuted: true,
        );
        final effect = BuiltInEffect(type: TrackEffectType.drive);
        expect(
          await repo.arm(
            chains: PerformanceChains(
              laneChains: [
                PerformanceLaneChain(
                  channel: 0,
                  lane: 0,
                  effects: [effect],
                  chainEnabled: false,
                ),
              ],
            ),
          ),
          EngineResult.ok,
        );
        final dir = repo.armedDirectory!;
        expect(Directory('$dir/loops').existsSync(), isFalse);
        writeNativeSidecar(dir, captureFrames: 128);
        expect(await repo.disarmAndFinalize(), EngineResult.ok);
        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        final track = manifest.armSnapshot!.tracks.single;
        expect(track.state, TrackState.empty);
        expect(track.volume, 0.6);
        final lane = track.lanes.single;
        expect(lane.lengthFrames, 0);
        expect(lane.deferred, isTrue);
        expect(lane.pcmFile, isNull);
        expect(lane.volume, 0.4);
        expect(lane.pan, -0.5);
        expect(lane.muted, isTrue);
        expect(lane.outputMask, 3);
        expect(lane.effects.single.typeCode, TrackEffectType.drive.code);
        expect(lane.chainEnabled, isFalse);
        expect(manifest.disarmSnapshot!.tracks, isEmpty);
        expect(Directory('$dir/loops').existsSync(), isFalse);
      },
    );

    test('writes the arm-time snapshot for every settled lane', () async {
      engine
        ..seedLane(0, 0, Float32List.fromList([1, 1, 1, 1]))
        ..seedLane(1, 0, Float32List.fromList([0.5, 0.5]));

      await repo.arm();
      final dir = repo.armedDirectory!;

      final armJson =
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>;
      final armSnapshot = PerformanceArmSnapshot.fromJson(armJson);
      expect(armSnapshot.tracks, hasLength(2));

      final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
      expect(track0.lanes, hasLength(1));
      expect(track0.lanes.single.deferred, isFalse);
      expect(track0.lanes.single.pcmFile, 'loops/track0-lane0.wav');
      expect(
        File('$dir/loops/track0-lane0.wav').existsSync(),
        isTrue,
        reason: 'settled lane PCM is written as a WAV immediately at arm',
      );

      final decoded = WavCodec.decodeFloat32(
        File('$dir/loops/track0-lane0.wav').readAsBytesSync(),
      );
      expect(decoded.samples, Float32List.fromList([1, 1, 1, 1]));
    });

    test(
      'writes a heard image as a stereo WAV beside the clean take (#1713)',
      () async {
        final heard = Float32List.fromList([.5, -.5, .5, -.5]);
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]), heard: heard)
          ..seedLane(1, 0, Float32List.fromList([1, 1]));

        await repo.arm();
        final dir = repo.armedDirectory!;

        final armJson =
            jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
                as Map<String, dynamic>;
        final tracks = PerformanceArmSnapshot.fromJson(armJson).tracks;
        final lane0 = tracks.firstWhere((t) => t.channel == 0).lanes.single;
        expect(lane0.heardFile, 'loops/track0-lane0-heard.wav');
        final wav = WavCodec.decodeFloat32(
          File('$dir/${lane0.heardFile}').readAsBytesSync(),
        );
        expect(wav.channels, 2);
        expect(wav.samples, heard);
        expect(lane0.toJson()['heardPcmRef'], lane0.heardFile);

        // A take without one names none.
        final lane1 = tracks.firstWhere((t) => t.channel == 1).lanes.single;
        expect(lane1.heardFile, isNull);
        expect(lane1.toJson().containsKey('heardPcmRef'), isFalse);
        expect(File('$dir/loops/track1-lane0-heard.wav').existsSync(), isFalse);
      },
    );

    test(
      "captures each track's mute and solo flags in the arm manifest",
      () async {
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]), muted: true)
          ..seedLane(1, 0, Float32List.fromList([1, 1]), solo: true);

        await repo.arm();
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.muted, isTrue);
        expect(track0.solo, isFalse);
        final track1 = armSnapshot.tracks.firstWhere((t) => t.channel == 1);
        expect(track1.muted, isFalse);
        expect(track1.solo, isTrue);
      },
    );

    test(
      'the arm-time manifest never carries takeId, even for a lane whose '
      'settled take id is > 0 (#819) — only the disarm pass stamps it, and '
      'the renderer reads it only from the disarm snapshot',
      () async {
        // A pre-recorded loop settled BEFORE arm still has a settled take id
        // in the snapshot; the arm pass must not persist it.
        engine.seedLane(
          0,
          0,
          Float32List.fromList([1, 1, 1, 1]),
          settledTakeId: 5,
        );

        await repo.arm();
        final dir = repo.armedDirectory!;

        final raw =
            jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
                as Map<String, dynamic>;
        final rawTracks = raw['tracks'] as List<dynamic>;
        final rawT0 =
            rawTracks.firstWhere(
                  (t) => (t as Map<String, dynamic>)['channel'] == 0,
                )
                as Map<String, dynamic>;
        final rawLane0 =
            (rawT0['lanes'] as List<dynamic>).first as Map<String, dynamic>;
        expect(rawLane0.containsKey('takeId'), isFalse);
        expect(
          PerformanceArmSnapshot.fromJson(
            raw,
          ).tracks.single.lanes.single.takeId,
          0,
        );
      },
    );

    test(
      "persists the engine snapshot's tempo verbatim in the arm-time "
      'crash-survival snapshot (#281)',
      () async {
        engine.tempoBpm = 87.5;

        await repo.arm();
        final dir = repo.armedDirectory!;

        final armJson =
            jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(armJson['tempoBpm'], 87.5);
        expect(PerformanceArmSnapshot.fromJson(armJson).tempoBpm, 87.5);
      },
    );

    test(
      "marks a mid-overdub track's lanes as deferred, no PCM export",
      () async {
        engine.markCapturing(0);

        await repo.arm();
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.lanes.single.deferred, isTrue);
        expect(track0.lanes.single.pcmFile, isNull);
        expect(Directory('$dir/loops').existsSync(), isFalse);
      },
    );

    test(
      'also defers a track mid-first-pass (TrackState.recording), not just '
      'mid-overdub',
      () async {
        engine.markCapturing(0, state: TrackState.recording);

        await repo.arm();
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.lanes.single.deferred, isTrue);
        expect(Directory('$dir/loops').existsSync(), isFalse);
      },
    );

    test(
      'embeds the lane + monitor effect chains supplied via PerformanceChains',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        final chain = BuiltInEffect(type: TrackEffectType.delay);

        await repo.arm(
          chains: PerformanceChains(
            laneChains: [
              PerformanceLaneChain(channel: 0, lane: 0, effects: [chain]),
            ],
            monitors: [
              PerformanceMonitorState(
                input: 0,
                enabled: true,
                outputMask: 0x3,
                volume: 0.75,
                muted: false,
                effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            ],
            limiterEnabled: true,
            limiterCeiling: 0.9,
          ),
        );
        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        final lane = armSnapshot.tracks.single.lanes.single;
        expect(lane.effects, hasLength(1));
        expect(lane.effects.single.typeCode, TrackEffectType.delay.code);

        expect(armSnapshot.limiterEnabled, isTrue);
        expect(armSnapshot.limiterCeiling, 0.9);
        expect(armSnapshot.monitors, hasLength(1));
        final monitor = armSnapshot.monitors.single;
        expect(monitor['input'], 0);
        expect(monitor['volume'], 0.75);
        final monitorEffects = monitor['effects'] as List<dynamic>;
        expect(
          (monitorEffects.single as Map<String, dynamic>)['type'],
          TrackEffectType.reverb.code,
        );
      },
    );

    test(
      'writes the BUS stages and every chain-enabled flag into the '
      'arm-snapshot (R20/R3)',
      () async {
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]))
          ..outputChain = OutputFxSnapshot(
            effects: [
              OutputEffectSnapshot(
                type: TrackEffectType.filter.code,
                params: TrackEffectType.filter.defaultParams,
              ),
            ],
            chainEnabled: false,
          );

        await repo.arm(
          chains: PerformanceChains(
            laneChains: [
              PerformanceLaneChain(
                channel: 0,
                lane: 0,
                chainEnabled: false,
                effects: [BuiltInEffect(type: TrackEffectType.delay)],
              ),
            ],
            monitors: [
              PerformanceMonitorState(
                input: 0,
                enabled: true,
                outputMask: 0x3,
                volume: 1,
                muted: false,
                chainEnabled: false,
                effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            ],
            trackChains: [
              PerformanceTrackChain(
                channel: 0,
                chainEnabled: false,
                effects: [BuiltInEffect(type: TrackEffectType.drive)],
              ),
            ],
          ),
        );

        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        // The marker, so a reader can tell these omissions from a legacy
        // snapshot's silence.
        expect(
          armSnapshot.fxStagesVersion,
          PerformanceArmSnapshot.currentFxStagesVersion,
        );
        // Loop stage: the lane's chain flag reached the file, keyed to the
        // right (channel, lane).
        expect(armSnapshot.tracks.single.lanes.single.chainEnabled, isFalse);
        // Input stage.
        expect(armSnapshot.monitors.single['chainEnabled'], isFalse);
        // Track stage.
        expect(armSnapshot.trackChains.single.channel, 0);
        expect(armSnapshot.trackChains.single.chainEnabled, isFalse);
        expect(
          armSnapshot.trackChains.single.effects.single.typeCode,
          TrackEffectType.drive.code,
        );
        // The actual captured output destination.
        expect(
          armSnapshot.outputEffects.single.typeCode,
          TrackEffectType.filter.code,
        );
        expect(armSnapshot.outputChainEnabled, isFalse);
      },
    );

    test(
      'a lane the rig defines NO chain for is written dry and engaged, not '
      "given a sibling lane's chain",
      () async {
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]))
          ..seedLane(1, 0, Float32List.fromList([1, 1]));

        await repo.arm(
          chains: PerformanceChains(
            laneChains: [
              PerformanceLaneChain(
                channel: 1,
                lane: 0,
                chainEnabled: false,
                effects: [BuiltInEffect(type: TrackEffectType.delay)],
              ),
            ],
          ),
        );

        final dir = repo.armedDirectory!;
        final armSnapshot = PerformanceArmSnapshot.fromJson(
          jsonDecode(File('$dir/arm-snapshot.json').readAsStringSync())
              as Map<String, dynamic>,
        );

        final track0 = armSnapshot.tracks.firstWhere((t) => t.channel == 0);
        expect(track0.lanes.single.effects, isEmpty);
        expect(track0.lanes.single.chainEnabled, isTrue);
        final track1 = armSnapshot.tracks.firstWhere((t) => t.channel == 1);
        expect(track1.lanes.single.chainEnabled, isFalse);
      },
    );

    test(
      'is idempotent while already armed: no new directory, no re-arm',
      () async {
        await repo.arm();
        final firstDir = repo.armedDirectory;
        final callsBefore = engine.perfArmCalls;

        final result = await repo.arm();
        expect(result, EngineResult.ok);
        expect(repo.armedDirectory, firstDir);
        expect(engine.perfArmCalls, callsBefore);
      },
    );

    test(
      'cleans up the created directory when the engine refuses to arm',
      () async {
        engine.perfArmResult = EngineResult.device;
        final result = await repo.arm();
        expect(result, EngineResult.device);
        expect(repo.armedDirectory, isNull);
        expect(
          Directory(
            '${tempDir.path}/exports/perf-20260706-143015',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'disambiguates the slug when the directory already exists, without '
      'touching the pre-existing bundle',
      () async {
        final existing = Directory(
          '${tempDir.path}/exports/perf-20260706-143015',
        )..createSync(recursive: true);
        final marker = File('${existing.path}/master.wav')
          ..writeAsStringSync('pre-existing bundle content');

        await repo.arm();

        expect(
          repo.armedDirectory,
          '${tempDir.path}/exports/perf-20260706-143015-1',
        );
        expect(
          marker.readAsStringSync(),
          'pre-existing bundle content',
          reason:
              'the collision-avoidance path must never overwrite '
              'an existing bundle',
        );
      },
    );

    test(
      'propagates when the exports root cannot be created (system boundary)',
      () async {
        // A plain file sitting where the exports root directory needs to go:
        // Directory.create() cannot succeed over it.
        File('${tempDir.path}/exports').createSync(recursive: true);
        await expectLater(repo.arm(), throwsA(isA<FileSystemException>()));
      },
    );

    test('publishes armed on captureStatus', () async {
      final statuses = <PerformanceCaptureStatus>[];
      final sub = repo.captureStatus.listen(statuses.add);
      await repo.arm();
      await pumpEventQueue();
      await sub.cancel();
      expect(statuses, [
        PerformanceCaptureStatus.idle,
        PerformanceCaptureStatus.armed,
      ]);
    });

    test('is refused as a take still being saved while a delivery holds '
        'it, and works again once every hold is released (#1638)', () async {
      final refusals = <PerformanceArmRefusal>[];
      final sub = repo.armRefusals.listen(refusals.add);
      addTearDown(sub.cancel);

      final first = repo.holdArm();
      final second = repo.holdArm();
      expect(repo.armBusy, PerformanceArmBusy.finalizing);
      expect(await repo.arm(), EngineResult.notReady);
      await Future<void>.delayed(Duration.zero);
      expect(
        refusals.map((r) => (r as PerformanceArmBusyRefusal).busy),
        [PerformanceArmBusy.finalizing],
      );

      first
        ..release()
        ..release(); // a second release changes nothing
      expect(repo.armBusy, PerformanceArmBusy.finalizing);
      second.release();
      expect(repo.armBusy, isNull);
      expect(await repo.arm(), EngineResult.ok);
      expect(repo.armedDirectory, isNotNull);
    });

    test('a render reads as rendering even while a delivery holds the gate '
        '(#1638)', () async {
      final hold = repo.holdArm();
      addTearDown(hold.release);
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 10,
      );
      expect(repo.armBusy, PerformanceArmBusy.rendering);
    });

    test(
      'is refused while an offline render is in flight, says why, and works '
      'again once it completes (#671, #1633)',
      () async {
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 40,
        );
        final refusals = <PerformanceArmRefusal>[];
        final sub = repo.armRefusals.listen(refusals.add);
        addTearDown(sub.cancel);

        expect(repo.armBusy, PerformanceArmBusy.rendering);
        final result = await repo.arm();

        expect(result, EngineResult.notReady);
        await Future<void>.delayed(Duration.zero);
        expect(
          refusals.map((r) => (r as PerformanceArmBusyRefusal).busy),
          [PerformanceArmBusy.rendering],
        );
        expect(repo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);
        expect(Directory('${tempDir.path}/exports').existsSync(), isFalse);

        engine.renderProgress = PerformanceRenderProgress.empty;
        expect(repo.armBusy, isNull);
        expect(await repo.arm(), EngineResult.ok);
        expect(repo.armedDirectory, isNotNull);
        expect(engine.perfArmed, isTrue);
        expect(refusals, hasLength(1), reason: 'an arm that works is quiet');
      },
    );

    test(
      'is refused while a boot-salvage finalize (recoverCapture) is in '
      'flight — the window where no armed directory exists to no-op on — '
      'and says a take is finalizing (#671, #1633)',
      () async {
        final dir = '${tempDir.path}/exports/perf-crashed';
        Directory(dir).createSync(recursive: true);
        writeNativeSidecar(dir);
        writeOpenPart('$dir/master-001.wav', Float32List.fromList([0.1, 0.2]));
        final refusals = <PerformanceArmRefusal>[];
        final sub = repo.armRefusals.listen(refusals.add);
        addTearDown(sub.cancel);

        final recovery = repo.recoverCapture(dir);
        expect(repo.armBusy, PerformanceArmBusy.finalizing);
        final result = await repo.arm();

        expect(result, EngineResult.notReady);
        await Future<void>.delayed(Duration.zero);
        expect(
          refusals.map((r) => (r as PerformanceArmBusyRefusal).busy),
          [PerformanceArmBusy.finalizing],
        );
        expect(repo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);

        await recovery;
        expect(await repo.arm(), EngineResult.ok);
        expect(repo.armedDirectory, isNotNull);
      },
    );

    test(
      'is still refused when the salvage starts only after arm has already '
      'passed its entry gate — the gate is re-checked after arm suspends '
      'across its awaits (#671)',
      () async {
        final crashed = '${tempDir.path}/exports/perf-crashed';
        Directory(crashed).createSync(recursive: true);
        writeNativeSidecar(crashed);
        writeOpenPart(
          '$crashed/master-001.wav',
          Float32List.fromList([0.1, 0.2]),
        );

        // The salvage's finalize hands straight over to its render (exactly
        // the production handover), so the refusal window stays covered at
        // arm's re-check no matter which async chain the event loop finishes
        // first.
        engine.renderProgressAfterBegin = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );

        // Park arm on its very first await (the exports-root lookup) so the
        // salvage provably enters the window AFTER arm's entry gate passed.
        final rootGate = Completer<String>();
        final gatedRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () => rootGate.future,
          now: () => clock,
        );
        addTearDown(gatedRepo.dispose);

        final statuses = <PerformanceCaptureStatus>[];
        final sub = gatedRepo.captureStatus.listen(statuses.add);

        final arming = gatedRepo.arm(); // entry gate passes, parks on root
        final recovery = gatedRepo.recoverCapture(crashed); // enters window
        rootGate.complete('${tempDir.path}/exports');

        final result = await arming;
        expect(result, EngineResult.notReady, reason: 'the re-check refuses');
        expect(gatedRepo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);

        await recovery;
        await pumpEventQueue();
        unawaited(sub.cancel());
        expect(
          statuses,
          everyElement(isNot(PerformanceCaptureStatus.armed)),
          reason: 'the resumed arm must not clobber the in-flight salvage',
        );
      },
    );

    test(
      'a second arm overlapping one still in flight is refused, and never '
      "deletes the winning arm's live capture directory (#671)",
      () async {
        // Park arm1 on its first await (the exports-root lookup) so arm2
        // provably overlaps it: without the in-flight gate both would pass
        // the entry gate, resolve the SAME slug (the collision loop is
        // synchronous, the create is not), and the loser's re-check cleanup
        // would delete the winner's just-armed directory out from under the
        // engine's drain thread.
        final rootGate = Completer<String>();
        final gatedRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () => rootGate.future,
          now: () => clock,
        );
        addTearDown(gatedRepo.dispose);

        final arm1 = gatedRepo.arm(); // entry gate passes, parks on root
        final arm2 = gatedRepo.arm(); // overlaps arm1's suspended window
        rootGate.complete('${tempDir.path}/exports');

        expect(await arm1, EngineResult.ok);
        expect(await arm2, EngineResult.ok, reason: 'the same press twice');

        expect(gatedRepo.armedDirectory, isNotNull);
        expect(
          Directory(gatedRepo.armedDirectory!).existsSync(),
          isTrue,
          reason:
              "the overlapping arm must not delete the winner's live "
              'capture directory',
        );
        expect(engine.perfArmCalls, 1);
        expect(engine.perfArmed, isTrue);
      },
    );

    test(
      'stays refused while a parked salvage finalize outlives a second '
      'finalize that finishes first — the in-flight gate counts overlapping '
      'finalizes instead of resetting on the first finisher (#671)',
      () async {
        // dirA: the salvage target, parked mid-finalize on a gated manifest
        // read (an IOOverrides fs hook — no production seam needed).
        final dirA = '${tempDir.path}/exports/perf-crashed';
        Directory(dirA).createSync(recursive: true);
        writeNativeSidecar(dirA);
        writeOpenPart('$dirA/master-001.wav', Float32List.fromList([0.1, 0.2]));

        // dirB: armed live, then disarmed with NO sidecar on disk — the
        // documented early-return finalize, the fastest possible finisher.
        await repo.arm();
        clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

        final readGate = Completer<void>();
        final testZone = Zone.current;
        final salvage = IOOverrides.runZoned(
          () => repo.recoverCapture(dirA),
          createFile: (path) {
            // Real files must be constructed outside the override zone, or
            // the File() factory would re-enter this callback forever.
            final real = testZone.run(() => File(path));
            return path == '$dirA/${PerformanceRepository.manifestName}'
                ? _GatedReadFile(real, readGate.future)
                : real;
          },
        );

        // The salvage is now provably parked mid-flight; dirB's finalize
        // starts AND completes underneath it.
        expect(await repo.disarm(), EngineResult.ok);
        expect(repo.armedDirectory, isNull);

        final result = await repo.arm();
        expect(result, EngineResult.notReady);
        expect(
          repo.armedDirectory,
          isNull,
          reason:
              "dirB's completed finalize must not reopen arm's gate while "
              "dirA's salvage is still mid-flight",
        );
        expect(engine.perfArmCalls, 1);

        readGate.complete();
        await salvage;
        await repo.arm();
        expect(repo.armedDirectory, isNotNull);
        expect(engine.perfArmCalls, 2);
      },
    );
  });

  group('disarm', () {
    Future<void> armAndSeedNative(
      FakePerformanceEngine e,
      PerformanceRepository r,
    ) async {
      await r.arm();
      // Past the disarm double-press guard window (D-GUARD) — this helper's
      // callers arm then disarm within the same test body, which a fixed
      // fake clock would otherwise always land inside.
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      writeNativeSidecar(
        r.armedDirectory!,
        capturedInputs: const [0],
      );
      writeOpenPart(
        '${r.armedDirectory!}/master-001.wav',
        Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
        tornBytes: 4,
      );
      writeOpenPart(
        '${r.armedDirectory!}/input-0-001.wav',
        Float32List.fromList([0.5, 0.6, 0.7, 0.8]),
        stream: 1,
      );
    }

    test('a disarm whose lane export or engine disarm throws reports the '
        'take armed again, never leaving it finalizing (#1639)', () async {
      final broken = _ThrowAfterArmEngine();
      final localRepo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(localRepo.dispose);
      final statuses = <PerformanceCaptureStatus>[];
      final sub = localRepo.captureStatus.listen(statuses.add);
      addTearDown(sub.cancel);
      expect(await localRepo.arm(), EngineResult.ok);
      final dir = localRepo.armedDirectory!;

      broken.throwSnapshot = true;
      await expectLater(localRepo.disarmAndFinalize(), throwsStateError);
      await pumpEventQueue();
      expect(statuses.last, PerformanceCaptureStatus.armed);
      expect(localRepo.armedDirectory, dir);
      expect(broken.perfArmed, isTrue);

      broken
        ..throwSnapshot = false
        ..throwDisarmOnce = true;
      await expectLater(localRepo.disarmAndFinalize(), throwsStateError);
      await pumpEventQueue();
      expect(statuses.last, PerformanceCaptureStatus.armed);
      expect(localRepo.armedDirectory, dir);

      writeNativeSidecar(dir);
      expect(await localRepo.disarmAndFinalize(), EngineResult.ok);
      await pumpEventQueue();
      expect(statuses.last, PerformanceCaptureStatus.done);
    });

    test('an arm while the take is still finalizing is refused as a take '
        'being saved, not taken for the same press twice (#1638)', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;
      final refusals = <PerformanceArmRefusal>[];
      final sub = repo.armRefusals.listen(refusals.add);
      addTearDown(sub.cancel);

      final readGate = Completer<void>();
      final testZone = Zone.current;
      final finalizing = IOOverrides.runZoned(
        repo.disarm,
        createFile: (path) {
          final real = testZone.run(() => File(path));
          return path == '$dir/${PerformanceRepository.manifestName}'
              ? _GatedReadFile(real, readGate.future)
              : real;
        },
      );
      await pumpEventQueue();
      expect(repo.armedDirectory, dir, reason: 'still finalizing');

      expect(await repo.arm(), EngineResult.notReady);
      await Future<void>.delayed(Duration.zero);
      expect(
        refusals.map((r) => (r as PerformanceArmBusyRefusal).busy),
        [PerformanceArmBusy.finalizing],
      );

      readGate.complete();
      expect(await finalizing, EngineResult.ok);
    });

    test('discarding a take cancels the render its finalize started, so '
        'the render slot is free for the next take (#1638)', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;
      engine.renderProgressAfterBegin = const PerformanceRenderProgress(
        done: false,
        progressPercent: 5,
      );
      expect(await repo.disarm(), EngineResult.ok);
      expect(repo.armBusy, PerformanceArmBusy.rendering);

      // Another take's directory leaves the render alone.
      await repo.discardUnfinalized('${tempDir.path}/exports/perf-other');
      expect(engine.renderCancelCalls, 0);

      await repo.discardUnfinalized(dir);
      expect(engine.renderCancelCalls, 1);
      expect(Directory(dir).existsSync(), isFalse);
      expect(repo.armBusy, isNull);
      expect(await repo.arm(), EngineResult.ok);
    });

    test('seals the open parts a crash left, dropping a torn frame, and '
        'converts nothing (#1198)', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;

      final result = await repo.disarm();
      expect(result, EngineResult.ok);
      expect(engine.perfArmed, isFalse);

      // Two whole stereo frames: 16 data bytes, the torn 4 dropped.
      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 16, 16));
      expect(File('$dir/master-001.wav').lengthSync(), 84 + 16);
      expect(partSizes('$dir/input-0-001.wav'), (84 - 8 + 16, 16));
      final payload = ByteData.sublistView(
        File('$dir/master-001.wav').readAsBytesSync(),
        84,
      );
      expect(
        [for (var i = 0; i < 4; i++) payload.getFloat32(i * 4, Endian.little)],
        Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
      );
      expect(File('$dir/master.wav').existsSync(), isFalse);
      expect(File('$dir/live-input-0.wav').existsSync(), isFalse);
    });

    test(
      'floors a mono part to whole mono frames, read from its header',
      () async {
        await repo.arm();
        clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
        final dir = repo.armedDirectory!;
        writeNativeSidecar(dir, masterChannels: 1);
        writeOpenPart(
          '$dir/master-001.wav',
          Float32List.fromList([0.1, 0.2, 0.3]),
          channels: 1,
          tornBytes: 2,
        );

        await repo.disarm();

        // Three mono frames: 12 bytes, not floored to stereo's 8.
        expect(partSizes('$dir/master-001.wav'), (84 - 8 + 12, 12));
        expect(File('$dir/master-001.wav').lengthSync(), 84 + 12);
      },
    );

    test('keeps a sealed part to the frames its header names, and leaves a '
        'file that is not a part alone', () async {
      await repo.arm();
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      final dir = repo.armedDirectory!;
      writeNativeSidecar(dir);
      writeOpenPart('$dir/master-001.wav', Float32List.fromList([0.1, 0.2]));
      // Sealed already: its sizes are what the drain patched.
      File('$dir/master-001.wav').openSync(mode: FileMode.append)
        ..setPositionSync(4)
        ..writeFromSync([84, 0, 0, 0])
        ..setPositionSync(80)
        ..writeFromSync([8, 0, 0, 0])
        ..setPositionSync(84 + 8)
        ..writeFromSync([1, 2, 3])
        ..closeSync();
      writeOpenPart('$dir/notes-001.txt', Float32List.fromList([0.1]));

      await repo.disarm();

      expect(partSizes('$dir/master-001.wav'), (84, 8));
      expect(File('$dir/master-001.wav').lengthSync(), 84 + 8);
      expect(partSizes('$dir/notes-001.txt'), (0, 0));
      expect(File('$dir/notes-001.txt').lengthSync(), 84 + 4);
    });

    test(
      'merges arm + disarm snapshots into performance.json, finalized true',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;

        final nativeFile = File('$dir/performance.json');
        final native =
            jsonDecode(nativeFile.readAsStringSync()) as Map<String, dynamic>;
        final layers = [
          {
            'kind': 0,
            'restore_id': 0,
            'channel': 0,
            'slot': 2,
            'generation': 3,
            'frame': 64,
            'frame_count': 128,
            'lane_count': 1,
            'filename': 'layer-0-64-2.pcm',
          },
          {
            'kind': 1,
            'restore_id': 1,
            'channel': 0,
            'slot': 0,
            'generation': 0,
            'frame': 256,
            'frame_count': 128,
            'lane_count': 2,
            'filename': 'restore-0-1.pcm',
          },
        ];
        native['layers'] = layers;
        nativeFile.writeAsStringSync(jsonEncode(native));
        await repo.disarm();
        final finalized =
            jsonDecode(nativeFile.readAsStringSync()) as Map<String, dynamic>;
        expect(finalized['layers'], equals(layers));

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.finalized, isTrue);
        expect(manifest.armSnapshot, isNotNull);
        expect(manifest.disarmSnapshot, isNotNull);
        expect(manifest.armSnapshot!.tracks.single.channel, 0);
        // Native fields survive the merge untouched.
        expect(manifest.sampleRate, 48000);
      },
    );

    test(
      'the disarm snapshot RE-READS the engine tempo — arm over an empty '
      'grid at 96, dial in 120 before the first loop, and the finalized '
      'manifest carries 120 as its authoritative tempo, keeping the stale '
      'arm-time 96 only as the crash-salvage fallback (D6, #281)',
      () async {
        engine.tempoBpm = 96;
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        // D6's tempo lock only engages once grid content exists, so a tempo
        // set (or re-derived by the first loop) after an arm-over-empty-grid
        // was never visible to the arm-time read.
        engine.tempoBpm = 120;

        await repo.disarm();

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.disarmSnapshot!.tempoBpm, 120);
        expect(manifest.armSnapshot!.tempoBpm, 96);
      },
    );

    test(
      'a track recorded fresh while armed has its PCM in the disarm snapshot',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        // Recorded (and finished) only AFTER arm — the arm snapshot saw an
        // empty track.
        engine.seedLane(2, 0, Float32List.fromList([0.9, 0.9, 0.9]));

        await repo.disarm();

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(
          manifest.armSnapshot!.tracks.where((t) => t.channel == 2),
          isEmpty,
          reason: 'track 2 was empty at arm time',
        );
        final disarmTrack = manifest.disarmSnapshot!.tracks.firstWhere(
          (t) => t.channel == 2,
        );
        expect(disarmTrack.lanes.single.deferred, isFalse);
        expect(
          File('$dir/${disarmTrack.lanes.single.pcmFile}').existsSync(),
          isTrue,
        );
      },
    );

    test(
      'the settled take id crosses the snapshot onto the disarm lane-0 entry '
      "as takeId (#819) — the renderer's take-identity anchor",
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        // Two settled tracks recorded during the capture, each carrying the
        // engine snapshot's monotonic settled take id (channel 1's is not 1 —
        // a clear-then-re-record bumped it, exactly the case the old first-END
        // ordinal proxy mis-anchored).
        engine
          ..seedLane(0, 0, Float32List.fromList([0.5, 0.5]), settledTakeId: 1)
          ..seedLane(1, 0, Float32List.fromList([0.4, 0.4]), settledTakeId: 3);

        await repo.disarm();

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        final t0 = manifest.disarmSnapshot!.tracks.firstWhere(
          (t) => t.channel == 0,
        );
        final t1 = manifest.disarmSnapshot!.tracks.firstWhere(
          (t) => t.channel == 1,
        );
        expect(t0.lanes.single.takeId, 1);
        expect(t1.lanes.single.takeId, 3);
        // And it is presence-keyed on the raw JSON, on lane 0 only.
        final raw =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        final rawTracks =
            (raw['disarmSnapshot'] as Map<String, dynamic>)['tracks']
                as List<dynamic>;
        final rawT1 =
            rawTracks.firstWhere(
                  (t) => (t as Map<String, dynamic>)['channel'] == 1,
                )
                as Map<String, dynamic>;
        final rawLane0 =
            (rawT1['lanes'] as List<dynamic>).first as Map<String, dynamic>;
        expect(rawLane0['takeId'], 3);
      },
    );

    test(
      'a settled lane with no take id (0) omits takeId from the manifest',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        // settledTakeId defaults to 0 — a pre-take-id / never-finalized track.
        engine.seedLane(3, 0, Float32List.fromList([0.2, 0.2]));

        await repo.disarm();

        final raw =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        final rawTracks =
            (raw['disarmSnapshot'] as Map<String, dynamic>)['tracks']
                as List<dynamic>;
        final rawT3 =
            rawTracks.firstWhere(
                  (t) => (t as Map<String, dynamic>)['channel'] == 3,
                )
                as Map<String, dynamic>;
        final rawLane0 =
            (rawT3['lanes'] as List<dynamic>).first as Map<String, dynamic>;
        expect(rawLane0.containsKey('takeId'), isFalse);
      },
    );

    test(
      'deletes the crash-survival arm-snapshot.json after finalize',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        await repo.disarm();
        expect(File('$dir/arm-snapshot.json').existsSync(), isFalse);
      },
    );

    test('is a no-op success when not armed', () async {
      expect(await repo.disarm(), EngineResult.ok);
    });

    test(
      'a disarm within disarmGuardWindow of arm is ignored (D-GUARD), '
      'capture stays armed',
      () async {
        await repo.arm();
        final dir = repo.armedDirectory;

        final result = await repo.disarm();

        expect(result, EngineResult.ok);
        expect(
          repo.armedDirectory,
          dir,
          reason: 'the guard must leave capture armed, not finalize it',
        );
        expect(engine.perfDisarmCalls, 0);
      },
    );

    test('a disarm past disarmGuardWindow of arm proceeds normally', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory;

      final result = await repo.disarm();

      expect(result, EngineResult.ok);
      expect(repo.armedDirectory, isNull);
      expect(
        jsonDecode(File('$dir/performance.json').readAsStringSync())
            as Map<String, dynamic>,
        containsPair('finalized', true),
      );
    });

    test(
      'leaves capture armed and skips finalize when the engine refuses to '
      'disarm',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.perfDisarmResult = EngineResult.device;

        final result = await repo.disarm();
        expect(result, EngineResult.device);
        expect(repo.armedDirectory, dir);

        final native =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(native['finalized'], isFalse);
      },
    );

    test('disarmAndFinalize is equivalent to disarm', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;
      await repo.disarmAndFinalize();
      final manifest =
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest['finalized'], isTrue);
    });

    test(
      'starts the offline dry-stem render (part 7) once finalized, exposed '
      'via renderProgress/renderTrackStatuses',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.mockRenderTrackStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];

        expect(repo.renderProgress, PerformanceRenderProgress.empty);
        expect(repo.renderTrackStatuses, isEmpty);

        await repo.disarm();

        expect(engine.renderBeginCalls, 1);
        expect(engine.lastRenderCaptureDir, dir);
        expect(repo.renderProgress.done, isTrue);
        expect(repo.renderTrackStatuses, hasLength(1));
        expect(repo.renderTrackStatuses.single.succeeded, isTrue);
      },
    );

    test(
      'still finalizes the bundle when renderBegin fails to even start '
      '(e.g. a render already in flight)',
      () async {
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;
        engine.renderBeginResult = EngineResult.alreadyRunning;

        await repo.disarm();

        expect(engine.renderBeginCalls, 1);
        final manifest =
            jsonDecode(File('$dir/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(
          manifest['finalized'],
          isTrue,
          reason:
              'the bundle is already complete and valid without its '
              'stems — a render that never started must not block that',
        );
      },
    );
  });

  group('persistLiveLanes', () {
    test(
      'exports settled lanes but skips a capturing track (D-CLEAR)',
      () async {
        await repo.arm();
        final dir = repo.armedDirectory!;
        engine
          ..seedLane(0, 0, Float32List.fromList([1, 1]))
          ..markCapturing(1);

        await repo.persistLiveLanes();

        expect(File('$dir/loops/track0-lane0.wav').existsSync(), isTrue);
        expect(File('$dir/loops/track1-lane0.wav').existsSync(), isFalse);
      },
    );

    test('is a no-op when not armed', () async {
      await repo.persistLiveLanes();
      // No exception, no directory created.
      expect(Directory('${tempDir.path}/exports').existsSync(), isFalse);
    });

    test('overwrites a prior export when called again (idempotent)', () async {
      await repo.arm();
      final dir = repo.armedDirectory!;
      engine.seedLane(0, 0, Float32List.fromList([1, 1]));
      await repo.persistLiveLanes();
      engine.seedLane(0, 0, Float32List.fromList([2, 2, 2]));
      await repo.persistLiveLanes();

      final decoded = WavCodec.decodeFloat32(
        File('$dir/loops/track0-lane0.wav').readAsBytesSync(),
      );
      expect(decoded.samples, Float32List.fromList([2, 2, 2]));
    });
  });

  group('findUnfinalized / recoverCapture', () {
    test('finds a capture dir whose sidecar lacks finalized: true', () async {
      final root = Directory('${tempDir.path}/exports');
      final crashed = Directory('${root.path}/perf-crashed')
        ..createSync(recursive: true);
      writeNativeSidecar(crashed.path);

      final finished = Directory('${root.path}/perf-finished')
        ..createSync(recursive: true);
      writeNativeSidecar(finished.path, finalized: true);

      final found = await repo.findUnfinalized();
      expect(
        found,
        [UnfinalizedCapture(directory: crashed.path, slug: 'perf-crashed')],
      );
    });

    test('never treats the backing store as a capture (#1200)', () async {
      // The backing player's managed copies live in `Backing tracks/` under
      // the same exports root; neither it nor an asset directory inside it
      // carries a sidecar, so salvage must pass it by.
      final root = Directory('${tempDir.path}/exports');
      final asset = Directory('${root.path}/Backing tracks/0123456789abcdef')
        ..createSync(recursive: true);
      File('${asset.path}/info.json').writeAsStringSync('{}');
      File('${asset.path}/Evening lights.wav').writeAsBytesSync([0, 1, 2]);

      expect(await repo.findUnfinalized(), isEmpty);
      expect(asset.existsSync(), isTrue);
    });

    test('treats an unreadable (corrupt) sidecar as unfinalized', () async {
      final root = Directory('${tempDir.path}/exports');
      final corrupt = Directory('${root.path}/perf-corrupt')
        ..createSync(recursive: true);
      File(
        '${corrupt.path}/performance.json',
      ).writeAsStringSync('{not valid json');

      final found = await repo.findUnfinalized();
      expect(
        found,
        [UnfinalizedCapture(directory: corrupt.path, slug: 'perf-corrupt')],
      );
    });

    test(
      'recoverCapture finalizes a crashed capture without a live disarm pass',
      () async {
        final root = Directory('${tempDir.path}/exports');
        final dir = Directory('${root.path}/perf-crashed')
          ..createSync(recursive: true);
        writeNativeSidecar(dir.path);
        writeOpenPart(
          '${dir.path}/master-001.wav',
          Float32List.fromList([0.25, 0.5]),
        );

        await repo.recoverCapture(dir.path);

        expect(partSizes('${dir.path}/master-001.wav'), (84 - 8 + 8, 8));
        final manifest =
            jsonDecode(File('${dir.path}/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
        expect(manifest['disarmSnapshot'], isNull);
      },
    );

    test(
      'recoverCapture restores the arm snapshot from its crash-survival file',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await repo
            .arm(); // writes arm-snapshot.json, never disarmed (the "crash")
        final dir = repo.armedDirectory!;
        writeNativeSidecar(
          dir,
        ); // the drain thread's last (finalized: false) write

        await repo.recoverCapture(dir);

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.armSnapshot, isNotNull);
        expect(manifest.finalized, isTrue);
      },
    );

    test(
      "a crash-salvaged manifest keeps the arm snapshot's tempo as the only "
      'tempo evidence — there is no disarm pass to re-read it (#281)',
      () async {
        engine.tempoBpm = 96;
        await repo.arm(); // writes arm-snapshot.json, never disarmed
        final dir = repo.armedDirectory!;
        writeNativeSidecar(dir);

        await repo.recoverCapture(dir);

        final manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.armSnapshot!.tempoBpm, 96);
        expect(
          manifest.disarmSnapshot,
          isNull,
          reason:
              'no live engine at salvage time — daw_export falls back to '
              "the arm snapshot's tempo for exactly this case",
        );
      },
    );

    test(
      'recoverCapture is a graceful no-op when performance.json is missing',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-no-sidecar')
          ..createSync(recursive: true);
        await repo.recoverCapture(dir.path); // must not throw
        expect(File('${dir.path}/performance.json').existsSync(), isFalse);
      },
    );

    test(
      'recoverCapture is a graceful no-op when performance.json is corrupt',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-corrupt')
          ..createSync(recursive: true);
        File('${dir.path}/performance.json').writeAsStringSync('{not json');

        await repo.recoverCapture(dir.path); // must not throw

        expect(
          File('${dir.path}/performance.json').readAsStringSync(),
          '{not json',
          reason: 'an unparseable sidecar is left untouched, not overwritten',
        );
      },
    );

    test(
      "does not leak a prior finalize's armSnapshot/disarmSnapshot into a "
      'later re-finalize that has none of its own',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await repo.arm();
        final dir = repo.armedDirectory!;
        writeNativeSidecar(dir);

        await repo.recoverCapture(dir); // first finalize: has an armSnapshot
        var manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(manifest.armSnapshot, isNotNull);

        // arm-snapshot.json was deleted by the first finalize; a second
        // recovery pass has nothing of its own to contribute.
        await repo.recoverCapture(dir);
        manifest = PerformanceManifest.fromJson(
          jsonDecode(File('$dir/performance.json').readAsStringSync())
              as Map<String, dynamic>,
        );
        expect(
          manifest.armSnapshot,
          isNull,
          reason:
              "the first finalize's armSnapshot must not leak through "
              'a second finalize pass that supplies none',
        );
      },
    );

    test('discardUnfinalized deletes the capture directory outright', () async {
      final root = Directory('${tempDir.path}/exports');
      final crashed = Directory('${root.path}/perf-crashed')
        ..createSync(recursive: true);
      writeNativeSidecar(crashed.path);

      await repo.discardUnfinalized(crashed.path);

      expect(crashed.existsSync(), isFalse);
    });

    test(
      'discardUnfinalized is a no-op when the directory no longer exists',
      () async {
        await repo.discardUnfinalized('${tempDir.path}/exports/never-existed');
      },
    );
  });

  group('a capture from before #1198 (#1078)', () {
    /// Floats that are exact in float32, so a read-back compares equal.
    Float32List ramp(int count, {double scale = 1 / 64}) =>
        Float32List.fromList([for (var i = 0; i < count; i++) i * scale]);

    Map<String, dynamic> readSidecar(String dir) =>
        jsonDecode(File('$dir/performance.json').readAsStringSync())
            as Map<String, dynamic>;

    Float32List payload(String path) {
      final bytes = File(path).readAsBytesSync();
      return Float32List.fromList(
        Float32List.view(
          Uint8List.fromList(bytes.sublist(84)).buffer,
        ),
      );
    }

    String seedLegacy(
      String slug, {
      int masterChannels = 2,
      List<int> inputs = const [],
      Float32List? master,
      Map<int, Float32List> inputSamples = const {},
    }) {
      final dir = '${tempDir.path}/exports/$slug';
      Directory(dir).createSync(recursive: true);
      // Written before takes had ids.
      writeNativeSidecar(
        dir,
        masterChannels: masterChannels,
        capturedInputs: inputs,
        takeId: null,
      );
      writeRawPcm('$dir/master.pcm', master ?? ramp(8));
      for (final MapEntry(key: input, value: samples) in inputSamples.entries) {
        writeRawPcm('$dir/input-$input.pcm', samples);
      }
      return dir;
    }

    PerformanceRepository smallParts({
      StorageIo Function() storageIo = fakeStorageIo,
    }) => PerformanceRepository(
      storageIo: storageIo,
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
      // 84-byte header plus three stereo frames per part.
      partBytes: 84 + 3 * 8,
    );

    test('is converted into float parts, samples unchanged, and its raw '
        'files are removed', () async {
      final master = ramp(14)..[3] = 1.5;
      final input = ramp(6, scale: -1 / 32);
      final dir = seedLegacy(
        'perf-legacy',
        inputs: const [0],
        master: master,
        inputSamples: {0: input},
      );
      final local = smallParts();
      addTearDown(local.dispose);

      await local.recoverCapture(dir);

      // Seven stereo frames: parts of 3, 3 and 1; the input's three frames
      // fill one part.
      expect(
        [
          for (final i in [1, 2, 3]) payload('$dir/master-00$i.wav'),
        ],
        [
          Float32List.sublistView(master, 0, 6),
          Float32List.sublistView(master, 6, 12),
          Float32List.sublistView(master, 12, 14),
        ],
      );
      expect(payload('$dir/input-0-001.wav'), input);
      expect(File('$dir/master-004.wav').existsSync(), isFalse);
      expect(File('$dir/master.pcm').existsSync(), isFalse);
      expect(File('$dir/input-0.pcm').existsSync(), isFalse);
      expect(File('$dir/master.wav').existsSync(), isFalse);

      final sidecar = readSidecar(dir);
      expect(sidecar['finalized'], isTrue);
      expect(sidecar['encoding'], 'f32');
      expect(sidecar['overs'], 1);
      final parts = [
        for (final p in sidecar['parts'] as List<dynamic>)
          TakePart.fromJson(p as Map<String, dynamic>),
      ];
      expect(
        [for (final p in parts) (p.stream, p.index, p.file, p.frames)],
        [
          (0, 1, 'master-001.wav', 3),
          (0, 2, 'master-002.wav', 3),
          (0, 3, 'master-003.wav', 1),
          (1, 1, 'input-0-001.wav', 3),
        ],
      );
      for (final p in parts) {
        final bytes = File('$dir/${p.file}').readAsBytesSync();
        expect(p.bytes, bytes.length);
        expect(p.sha256, fakeDigest(Uint8List.sublistView(bytes, 84)));
      }
      expect([for (final p in parts) p.overs], [1, 0, 0, 0]);
      // Every part names the same take, by stream and index.
      final takeId = sidecar['take_id'] as String;
      for (final p in parts) {
        final header = RecordedPartHeader.decode(
          File('$dir/${p.file}').readAsBytesSync(),
        );
        expect(
          header.takeId.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          takeId,
        );
        expect((header.stream, header.partIndex), (p.stream, p.index));
      }
      expect(FakeStorageIo.synced, contains(dir));
      expect(engine.lastRenderCaptureDir, dir);
    });

    test('a mono master becomes mono parts, a torn trailing frame dropped, '
        'and an empty stream one empty part', () async {
      final dir = seedLegacy(
        'perf-mono',
        masterChannels: 1,
        inputs: const [2],
        master: ramp(5),
        inputSamples: {2: Float32List(0)},
      );
      File('$dir/master.pcm').writeAsBytesSync([1, 2], mode: FileMode.append);
      final local = smallParts();
      addTearDown(local.dispose);

      await local.recoverCapture(dir);

      // Mono: 6 frames fit a 24-byte payload, so five frames are one part.
      expect(payload('$dir/master-001.wav'), ramp(5));
      expect(File('$dir/master-001.wav').lengthSync(), 84 + 20);
      expect(File('$dir/input-2-001.wav').lengthSync(), 84);
      final parts = readSidecar(dir)['parts'] as List<dynamic>;
      expect(parts.map((p) => (p as Map)['frames']), [5, 0]);
    });

    test('reads it a bounded chunk at a time, whatever its length', () {
      final dir = '${tempDir.path}/bounded';
      Directory(dir).createSync(recursive: true);
      final samples = ramp(3 * (1 << 18) + 6, scale: 1 / 1024);
      writeRawPcm('$dir/master.pcm', samples);
      var largest = 0;
      var reads = 0;

      final parts = convertRawStream(
        pcmPath: '$dir/master.pcm',
        dir: dir,
        stream: 0,
        channels: 2,
        sampleRate: 48000,
        takeId: Uint8List(16),
        partBytes: 84 + 8 * (1 << 18),
        onRead: (bytes) {
          reads++;
          if (bytes > largest) largest = bytes;
        },
      );

      expect(largest, legacyChunkBytes);
      expect(reads, greaterThan(3));
      expect(parts.map((p) => p.frames), [1 << 18, (1 << 17) + 3]);
      expect(
        [...payload('$dir/master-001.wav'), ...payload('$dir/master-002.wav')],
        samples,
      );
    });

    test('a failed part write deletes the parts it made and leaves the raw '
        'file', () {
      final dir = '${tempDir.path}/failing';
      Directory(dir).createSync(recursive: true);
      writeRawPcm('$dir/master.pcm', ramp(10));
      // The second part's name is taken by a directory: its create fails.
      Directory('$dir/master-002.wav').createSync();

      expect(
        () => convertRawStream(
          pcmPath: '$dir/master.pcm',
          dir: dir,
          stream: 0,
          channels: 2,
          sampleRate: 48000,
          takeId: Uint8List(16),
          partBytes: 84 + 2 * 8,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('$dir/master-001.wav').existsSync(), isFalse);
      expect(File('$dir/master.pcm').lengthSync(), 40);
    });

    test('with less free space than its largest stream needs, nothing is '
        'touched and it is reported as not recovered', () async {
      final dir = seedLegacy(
        'perf-tight',
        inputs: const [0],
        master: ramp(8),
        inputSamples: {0: ramp(4)},
      );
      Map<String, Uint8List> files() => {
        for (final f in Directory(dir).listSync())
          if (!_name(f.path).startsWith('.'))
            _name(f.path): File(f.path).readAsBytesSync(),
      };
      final before = files();
      // Four stereo frames in two parts need 32 bytes and two headers.
      engine.freeBytes = 32 + 2 * 84 - 1;
      final local = smallParts();
      addTearDown(local.dispose);

      await local.runBootRecovery();

      expect(files(), before);
      expect(local.unrecoveredTakes, [dir]);

      // One byte more and the next start converts it.
      engine.freeBytes = 32 + 2 * 84;
      await local.runBootRecovery();
      expect(local.unrecoveredTakes, isEmpty);
      expect(
        File(
          '${tempDir.path}/exports/recovered/perf-tight/master-001.wav',
        ).existsSync(),
        isTrue,
      );
    });

    test(
      'the room for a conversion includes the reserve a take keeps',
      () async {
        final dir = seedLegacy('perf-reserve', master: ramp(8));
        final reserved = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          partBytes: 84 + 3 * 8,
          reserveBytes: 1000,
        );
        addTearDown(reserved.dispose);
        engine.freeBytes = 32 + 2 * 84 + 999;

        await reserved.runBootRecovery();
        expect(reserved.unrecoveredTakes, [dir]);
        expect(File('$dir/master.pcm').lengthSync(), 32);

        engine.freeBytes = 32 + 2 * 84 + 1000;
        await reserved.runBootRecovery();
        expect(reserved.unrecoveredTakes, isEmpty);
      },
    );

    test('a stream that fails keeps its raw file; the streams before it stay '
        'converted and listed, and the next start finishes', () async {
      final dir = seedLegacy(
        'perf-cut',
        inputs: const [0],
        master: ramp(4),
        inputSamples: {0: ramp(4)},
      );
      final failing = smallParts(storageIo: _inputsUnreadable);
      addTearDown(failing.dispose);

      await failing.runBootRecovery();

      expect(failing.unrecoveredTakes, [dir]);
      expect(File('$dir/master.pcm').existsSync(), isFalse);
      expect(File('$dir/input-0.pcm').lengthSync(), 16);
      expect(File('$dir/input-0-001.wav').existsSync(), isFalse);
      final interim = readSidecar(dir);
      expect(interim['finalized'], isFalse);
      expect(
        (interim['parts'] as List<dynamic>).map((p) => (p as Map)['file']),
        ['master-001.wav'],
      );
      final masterBytes = File('$dir/master-001.wav').readAsBytesSync();

      final next = smallParts();
      addTearDown(next.dispose);
      await next.runBootRecovery();

      final recovered = '${tempDir.path}/exports/recovered/perf-cut';
      expect(next.unrecoveredTakes, isEmpty);
      expect(File('$recovered/master-001.wav').readAsBytesSync(), masterBytes);
      expect(payload('$recovered/input-0-001.wav'), ramp(4));
      final parts = readSidecar(recovered)['parts'] as List<dynamic>;
      expect(
        parts.map((p) => (p as Map)['file']),
        ['master-001.wav', 'input-0-001.wav'],
      );
      // The input's parts name the take the master's do.
      expect(
        RecordedPartHeader.decode(
          File('$recovered/input-0-001.wav').readAsBytesSync(),
        ).takeId,
        RecordedPartHeader.decode(masterBytes).takeId,
      );
    });

    test(
      'a cut after a stream was listed but before its raw file went only '
      'removes that file; parts a cut left unlisted are made again',
      () async {
        final dir = seedLegacy(
          'perf-resume',
          inputs: const [0],
          master: ramp(4),
          inputSamples: {0: ramp(4)},
        );
        final first = smallParts(storageIo: _inputsUnreadable);
        addTearDown(first.dispose);
        await first.recoverCapture(dir);
        // As if the cut came before the removal: the raw file is back, and a
        // half-written part of the next stream sits unlisted beside it.
        writeRawPcm('$dir/master.pcm', ramp(4, scale: 1 / 8));
        File('$dir/input-0-001.wav').writeAsBytesSync([1, 2, 3]);
        final listed = File('$dir/master-001.wav').readAsBytesSync();

        final next = smallParts();
        addTearDown(next.dispose);
        await next.recoverCapture(dir);

        expect(File('$dir/master.pcm').existsSync(), isFalse);
        expect(File('$dir/master-001.wav').readAsBytesSync(), listed);
        expect(payload('$dir/input-0-001.wav'), ramp(4));
        expect(readSidecar(dir)['finalized'], isTrue);
      },
    );

    test('a listed part that is gone, with its raw file gone too, leaves the '
        'take as it is', () async {
      final dir = seedLegacy(
        'perf-lost',
        inputs: const [0],
        master: ramp(4),
        inputSamples: {0: ramp(4)},
      );
      final first = smallParts(storageIo: _inputsUnreadable);
      addTearDown(first.dispose);
      await first.recoverCapture(dir);
      File('$dir/master-001.wav').deleteSync();

      final next = smallParts();
      addTearDown(next.dispose);
      await next.runBootRecovery();

      expect(next.unrecoveredTakes, [dir]);
      expect(File('$dir/input-0.pcm').lengthSync(), 16);
      expect(File('$dir/input-0-001.wav').existsSync(), isFalse);
    });

    test('the parts a cut conversion left unlisted are removed before the '
        'room for the conversion is measured', () async {
      final dir = seedLegacy('perf-strays', master: ramp(8));
      // A cut 1 part into the conversion: an unlisted part of 108 bytes.
      writeRawPcm('$dir/master-001.wav', ramp(27));
      final measuring = _StrayAwareEngine(dir, free: 200);
      final local = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: measuring,
        exportsRoot: () async => '${tempDir.path}/exports',
        partBytes: 84 + 3 * 8,
      );
      addTearDown(local.dispose);

      await local.recoverCapture(dir);

      expect(readSidecar(dir)['finalized'], isTrue);
      expect(
        payload('$dir/master-001.wav'),
        Float32List.sublistView(ramp(8), 0, 6),
      );
    });

    test('a directory sync that fails after the interim sidecar is in place '
        'keeps both its parts and the raw file', () async {
      final dir = seedLegacy('perf-sync', master: ramp(4));
      _FailSecondSync.calls = 0;
      final local = smallParts(storageIo: _failSecondSync);
      addTearDown(local.dispose);

      await local.recoverCapture(dir);

      final interim = readSidecar(dir);
      expect(interim['finalized'], isFalse);
      expect(
        (interim['parts'] as List<dynamic>).map((p) => (p as Map)['file']),
        ['master-001.wav'],
      );
      expect(File('$dir/master-001.wav').existsSync(), isTrue);
      expect(File('$dir/master.pcm').lengthSync(), 16);

      final next = smallParts();
      addTearDown(next.dispose);
      await next.recoverCapture(dir);
      expect(readSidecar(dir)['finalized'], isTrue);
      expect(File('$dir/master.pcm').existsSync(), isFalse);
    });

    test('a finalize whose directory sync fails still finishes: the take is '
        'finalized, its render starts and the repository is idle', () async {
      final local = PerformanceRepository(
        storageIo: _syncAlwaysFails,
        guards: GuardRegistry(),
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(local.dispose);
      await local.arm();
      clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
      final dir = local.armedDirectory!;
      writeNativeSidecar(dir);

      expect(await local.disarm(), EngineResult.ok);

      expect(readSidecar(dir)['finalized'], isTrue);
      expect(local.armedDirectory, isNull);
      expect(engine.lastRenderCaptureDir, dir);
    });

    test('a take the drain wrote as parts is never converted, even beside a '
        'stray raw file', () async {
      final dir = '${tempDir.path}/exports/perf-parts';
      Directory(dir).createSync(recursive: true);
      writeNativeSidecar(dir);
      final sidecar = readSidecar(dir)..['take_id'] = '0' * 32;
      File('$dir/performance.json').writeAsStringSync(jsonEncode(sidecar));
      writeOpenPart('$dir/master-001.wav', Float32List.fromList([0.1, 0.2]));
      writeRawPcm('$dir/master.pcm', ramp(8));

      await repo.recoverCapture(dir);

      expect(readSidecar(dir)['finalized'], isTrue);
      expect(partSizes('$dir/master-001.wav'), (84 - 8 + 8, 8));
      expect(File('$dir/master.pcm').lengthSync(), 32);
    });

    test('a sidecar whose parts do not read is left as it is', () async {
      final dir = seedLegacy('perf-odd');
      final sidecar = readSidecar(dir)..['parts'] = 'not a list';
      File('$dir/performance.json').writeAsStringSync(jsonEncode(sidecar));
      final local = smallParts();
      addTearDown(local.dispose);

      await local.runBootRecovery();

      expect(local.unrecoveredTakes, [dir]);
      expect(File('$dir/master.pcm').lengthSync(), 32);
      expect(File('$dir/master-001.wav').existsSync(), isFalse);
    });

    test('a layout no conversion can trust is left as it is', () async {
      final dir = seedLegacy('perf-layout');
      final sidecar = readSidecar(dir)
        ..['channel_layout'] = {'master_channels': 3};
      File('$dir/performance.json').writeAsStringSync(jsonEncode(sidecar));

      await repo.runBootRecovery();

      expect(repo.unrecoveredTakes, [dir]);
      expect(File('$dir/master.pcm').lengthSync(), 32);
    });
  });

  group('runBootRecovery (silent boot salvage, #679)', () {
    /// A crashed capture: unfinalized sidecar plus an open master part, the
    /// same fixture shape the recoverCapture tests use.
    String seedCrashed(String slug) {
      final dir = '${tempDir.path}/exports/$slug';
      Directory(dir).createSync(recursive: true);
      writeNativeSidecar(dir);
      writeOpenPart('$dir/master-001.wav', Float32List.fromList([0.1, 0.2]));
      return dir;
    }

    test(
      'finalizes + renders an unfinalized capture into recovered/ under its '
      'own slug, and the original bundle is gone',
      () async {
        final crashed = seedCrashed('perf-crashed');

        await repo.runBootRecovery();

        final recovered = '${tempDir.path}/exports/recovered/perf-crashed';
        expect(Directory(crashed).existsSync(), isFalse);
        expect(
          partSizes('$recovered/master-001.wav'),
          (84 - 8 + 8, 8),
          reason: 'the salvage seals the open part so the take plays',
        );
        final manifest =
            jsonDecode(File('$recovered/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
        expect(
          engine.lastRenderCaptureDir,
          crashed,
          reason: 'the stem render ran against the bundle before the move',
        );
        expect(
          File(
            '$recovered/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isFalse,
          reason: 'a completed salvage removes its own marker',
        );
      },
    );

    test('recovers silently: no captureStatus emission at any point', () async {
      seedCrashed('perf-crashed');
      final statuses = <PerformanceCaptureStatus>[];
      final sub = repo.captureStatus.listen(statuses.add);

      await repo.runBootRecovery();
      await pumpEventQueue();
      unawaited(sub.cancel());

      expect(statuses, [PerformanceCaptureStatus.idle]);
    });

    test('is a quiet no-op when there is nothing to recover', () async {
      await repo.runBootRecovery();
      expect(
        Directory('${tempDir.path}/exports/recovered').existsSync(),
        isFalse,
        reason: 'no recovered/ area is created for nothing',
      );
    });

    test(
      'never deletes a recovered take, however long ago it landed — '
      'recovered audio is kept until the user removes it',
      () async {
        final recoveredRoot = '${tempDir.path}/exports/recovered';
        final old = '$recoveredRoot/perf-old';
        Directory(old).createSync(recursive: true);
        writeNativeSidecar(old, finalized: true);
        File(
          '$old/${PerformanceRepository.recoveredAtStampName}',
        ).writeAsStringSync(
          clock
              .subtract(const Duration(days: 3650))
              .millisecondsSinceEpoch
              .toString(),
        );

        await repo.runBootRecovery();

        expect(Directory(old).existsSync(), isTrue);
      },
    );

    test(
      'a salvage that cannot finalize (corrupt sidecar) keeps the raw '
      'bundle in place for the next boot, without crashing',
      () async {
        final dir = '${tempDir.path}/exports/perf-corrupt';
        Directory(dir).createSync(recursive: true);
        File('$dir/performance.json').writeAsStringSync('{not json');

        await repo.runBootRecovery();

        expect(
          Directory(dir).existsSync(),
          isTrue,
          reason: 'never delete what could not be rendered',
        );
        expect(
          Directory(
            '${tempDir.path}/exports/recovered/perf-corrupt',
          ).existsSync(),
          isFalse,
        );
        expect(engine.renderBeginCalls, 0);
      },
    );

    test(
      'a salvage whose finalize THROWS keeps the raw bundle in place for '
      'the next boot, without crashing',
      () async {
        final dir = seedCrashed('perf-crashed');
        // A directory where the finalized sidecar is written: publishing
        // it fails.
        Directory('$dir/performance.json.publishing').createSync();

        await repo.runBootRecovery();

        expect(Directory(dir).existsSync(), isTrue);
        expect(
          Directory('${tempDir.path}/exports/recovered').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'arm is refused for the whole background salvage (#671 gates), and '
      'works again once the render completes and the bundle has moved',
      () async {
        seedCrashed('perf-crashed');
        // The salvage's finalize hands straight over to an in-flight render
        // (the production handover), so runBootRecovery parks waiting on the
        // render poll.
        engine.renderProgressAfterBegin = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final pollingRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          now: () => clock,
          bootRecoveryPollInterval: const Duration(milliseconds: 5),
        );
        addTearDown(pollingRepo.dispose);

        final recovery = pollingRepo.runBootRecovery();
        // Wait until the salvage provably holds the gate (its render has
        // begun) before arming — pumpEventQueue alone races the salvage's
        // real file I/O, and an arm landing in that gap would legitimately
        // win and defer the salvage instead (the armed-bail tests below).
        while (engine.renderBeginCalls == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }

        final result = await pollingRepo.arm();
        expect(result, EngineResult.notReady);
        expect(pollingRepo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);

        engine.renderProgress = PerformanceRenderProgress.empty;
        await recovery;
        expect(
          Directory(
            '${tempDir.path}/exports/recovered/perf-crashed',
          ).existsSync(),
          isTrue,
        );
        await pollingRepo.arm();
        expect(pollingRepo.armedDirectory, isNotNull);
      },
    );

    test(
      'defers salvage entirely while a capture is armed — the armed session '
      'owns the drain thread and the single render slot (#679 r2)',
      () async {
        await repo.arm();
        final armedDir = repo.armedDirectory!;
        // The drain thread keeps the live capture's sidecar at
        // finalized: false the whole session — exactly what makes it look
        // salvageable to a scan that does not exclude it.
        writeNativeSidecar(armedDir);
        final crashed = seedCrashed('perf-crashed');

        await repo.runBootRecovery();

        expect(repo.armedDirectory, armedDir);
        expect(Directory(armedDir).existsSync(), isTrue);
        expect(
          File(
            '$armedDir/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isFalse,
          reason: 'the live capture was never even marked for salvage',
        );
        expect(
          Directory(crashed).existsSync(),
          isTrue,
          reason:
              'the sibling defers to the next boot too — its salvage render '
              "would steal the armed take's one global render slot",
        );
        expect(engine.renderBeginCalls, 0);
        expect(
          Directory('${tempDir.path}/exports/recovered').existsSync(),
          isFalse,
        );
      },
    );

    test(
      "an arm landing in the boot scan's await gap wins: the resumed "
      'recovery finds the armed session and defers everything, leaving the '
      'live directory untouched (#679 r2)',
      () async {
        final crashed = seedCrashed('perf-crashed');
        // Park runBootRecovery on its very first await (the exports-root
        // lookup) so the arm provably lands AFTER recovery started but
        // BEFORE any salvage took its finalize guard.
        final rootGate = Completer<String>();
        var rootCalls = 0;
        final gatedRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () {
            rootCalls++;
            return rootCalls == 1
                ? rootGate.future
                : Future.value('${tempDir.path}/exports');
          },
          now: () => clock,
        );
        addTearDown(gatedRepo.dispose);

        final recovery = gatedRepo.runBootRecovery(); // parks on the root
        await gatedRepo.arm(); // lands in the gap, owns the engine
        final armedDir = gatedRepo.armedDirectory!;
        writeNativeSidecar(armedDir); // the drain's finalized: false sidecar
        rootGate.complete('${tempDir.path}/exports');
        await recovery;

        expect(gatedRepo.armedDirectory, armedDir);
        expect(
          Directory(armedDir).existsSync(),
          isTrue,
          reason:
              'the salvage must never finalize/rename the live capture '
              'out from under the drain thread',
        );
        expect(
          File(
            '$armedDir/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isFalse,
        );
        expect(Directory(crashed).existsSync(), isTrue);
        expect(
          engine.renderBeginCalls,
          0,
          reason: "no salvage render may squat on the armed take's slot",
        );
      },
    );

    test(
      "one capture's failing salvage neither aborts its siblings nor "
      'escapes as an unhandled error (#679 r2)',
      () async {
        final bad = seedCrashed('perf-a-bad');
        // A directory where the finalized sidecar is written: this
        // capture's salvage throws mid-finalize.
        Directory('$bad/performance.json.publishing').createSync();
        seedCrashed('perf-b-good');

        // Deterministic regardless of listSync order: an unguarded loop
        // would either propagate the throw out of this await (bad first)
        // or strand the sibling unrecovered (good first) — both outcomes
        // below can only hold together under the per-capture guard.
        await repo.runBootRecovery();

        expect(Directory(bad).existsSync(), isTrue);
        expect(
          Directory(
            '${tempDir.path}/exports/recovered/perf-b-good',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'a wedged stem render times out instead of parking recovery forever; '
      "the finalized bundle keeps its marker and the next boot's sweep "
      'finishes the move (#679 r2)',
      () async {
        engine.renderProgressAfterBegin = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final timingRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          now: () => clock,
          bootRecoveryPollInterval: const Duration(milliseconds: 2),
          bootRecoveryRenderTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(timingRepo.dispose);
        final dir = seedCrashed('perf-crashed');

        await timingRepo.runBootRecovery(); // returns: the wait is bounded

        expect(Directory(dir).existsSync(), isTrue);
        expect(
          File(
            '$dir/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isTrue,
          reason: 'the marker stays until the move actually lands',
        );
        expect(
          Directory('${tempDir.path}/exports/recovered').existsSync(),
          isFalse,
        );

        // Next boot: the wedged render did not survive the reboot; the
        // stranded bundle is re-salvaged — stem render re-attempted, not
        // just moved stemless.
        engine
          ..renderProgressAfterBegin = null
          ..renderProgress = PerformanceRenderProgress.empty;
        await timingRepo.runBootRecovery();
        final moved = '${tempDir.path}/exports/recovered/perf-crashed';
        expect(Directory(moved).existsSync(), isTrue);
        expect(
          File(
            '$moved/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isFalse,
        );
        expect(Directory(dir).existsSync(), isFalse);
        expect(
          engine.renderBeginCalls,
          2,
          reason:
              'the sweep re-attempts the stems the first boot never got — '
              'a stranded bundle must not land in recovered/ stemless',
        );
      },
    );

    test(
      'stops the salvage loop while a prior salvage render still squats the '
      "engine's one render slot — the sibling is neither finalized nor "
      'moved stemless (#679 r3)',
      () async {
        // Every renderBegin leaves an in-flight render behind, and nothing
        // ever completes it — capture A times out on its own render.
        engine.renderProgressAfterBegin = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final timingRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          now: () => clock,
          bootRecoveryPollInterval: const Duration(milliseconds: 2),
          bootRecoveryRenderTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(timingRepo.dispose);
        final a = seedCrashed('perf-a');
        final b = seedCrashed('perf-b');

        await timingRepo.runBootRecovery();

        // listSync order is not guaranteed, so assert order-agnostically:
        // exactly ONE capture was salvaged (timed out, marked, finalized);
        // the other was never touched — not marked, not finalized, and
        // above all not moved stemless with its marker gone.
        expect(
          engine.renderBeginCalls,
          1,
          reason:
              'the loop must stop at the squatted slot, not push B '
              'through a renderBegin the engine would refuse',
        );
        expect(
          Directory('${tempDir.path}/exports/recovered').existsSync(),
          isFalse,
        );
        final markers = [
          for (final dir in [a, b])
            File(
              '$dir/${PerformanceRepository.recoveryMarkerName}',
            ).existsSync(),
        ];
        expect(markers.where((m) => m).length, 1);
        expect(Directory(a).existsSync(), isTrue);
        expect(Directory(b).existsSync(), isTrue);
      },
    );

    test(
      'a well-formed but wrong-shaped sidecar (JSON of the wrong type) is '
      'kept for the next boot and does not take its sibling — or the boot '
      'call — down with it (#679 r3)',
      () async {
        final bad = '${tempDir.path}/exports/perf-a-badshape';
        Directory(bad).createSync(recursive: true);
        // Well-formed JSON, wrong shape: the decode CAST throws a TypeError
        // (an Error, not an Exception) — the case a blanket `on Exception`
        // guard silently misses.
        File('$bad/performance.json').writeAsStringSync('[1, 2, 3]');
        seedCrashed('perf-b-good');

        await repo.runBootRecovery(); // must complete, not throw

        expect(Directory(bad).existsSync(), isTrue);
        expect(
          Directory(
            '${tempDir.path}/exports/recovered/perf-b-good',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'sweeps a finalized bundle stranded with its recovery marker into '
      'recovered/, and never touches an unmarked finished take (#679 r2)',
      () async {
        // Stranded: finalized AND still marked — a crash landed between a
        // previous boot's finalize and its rename.
        final stranded = '${tempDir.path}/exports/perf-stranded';
        Directory(stranded).createSync(recursive: true);
        writeNativeSidecar(stranded, finalized: true);
        File(
          '$stranded/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        // A normal finished take: finalized, no marker — the user's data.
        final take = '${tempDir.path}/exports/perf-finished-take';
        Directory(take).createSync(recursive: true);
        writeNativeSidecar(take, finalized: true);

        await repo.runBootRecovery();

        final moved = '${tempDir.path}/exports/recovered/perf-stranded';
        expect(Directory(moved).existsSync(), isTrue);
        expect(
          File(
            '$moved/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isFalse,
        );
        expect(Directory(stranded).existsSync(), isFalse);
        expect(
          Directory(take).existsSync(),
          isTrue,
          reason:
              'finished takes also live finalized in the exports root — '
              'only the marker distinguishes stranded salvage output',
        );
      },
    );

    test(
      'survives an exports root that cannot be resolved at boot — nothing '
      'to recover, and no unhandled error out of the unawaited call',
      () async {
        final brokenRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => throw const FileSystemException('gone'),
          now: () => clock,
        );
        addTearDown(brokenRepo.dispose);

        await brokenRepo.runBootRecovery(); // must complete, not throw
      },
    );

    test(
      'survives the boot scan itself failing after the sweep already ran '
      '(the root resolves once, then the volume goes away)',
      () async {
        var rootCalls = 0;
        final flakyRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async {
            rootCalls++;
            if (rootCalls > 1) throw const FileSystemException('vanished');
            return '${tempDir.path}/exports';
          },
          now: () => clock,
        );
        addTearDown(flakyRepo.dispose);
        seedCrashed('perf-crashed');

        await flakyRepo.runBootRecovery(); // must complete, not throw

        expect(
          rootCalls,
          2,
          reason:
              'the sweep consumed the first resolution; the scan '
              're-resolved, failed, and was contained',
        );
      },
    );

    test(
      'a sweep move the filesystem refuses skips that entry — the stranded '
      "bundle stays, marker intact, for the next boot's retry",
      () async {
        final stranded = '${tempDir.path}/exports/perf-stranded';
        Directory(stranded).createSync(recursive: true);
        writeNativeSidecar(stranded, finalized: true);
        File(
          '$stranded/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        // A plain FILE squatting where the recovered/ area must go: the
        // move's createSync throws FileSystemException.
        File('${tempDir.path}/exports/recovered').createSync();

        await repo.runBootRecovery(); // must complete, not throw

        expect(Directory(stranded).existsSync(), isTrue);
        expect(
          File(
            '$stranded/${PerformanceRepository.recoveryMarkerName}',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'hasBootRecoveryWork counts a stranded finalized bundle as work, not '
      'only crashed captures — the app probe keys the busy flag off it, and '
      "a stranded-only boot's re-render holds arm just as long (#679 r4)",
      () async {
        expect(await repo.hasBootRecoveryWork(), isFalse);

        // Stranded only: finalized + marker, nothing unfinalized anywhere —
        // exactly the boot findUnfinalized alone reports as "no work".
        final stranded = '${tempDir.path}/exports/perf-stranded';
        Directory(stranded).createSync(recursive: true);
        writeNativeSidecar(stranded, finalized: true);
        File(
          '$stranded/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        expect(await repo.hasBootRecoveryWork(), isTrue);

        // Crashed only.
        Directory(stranded).deleteSync(recursive: true);
        seedCrashed('perf-crashed');
        expect(await repo.hasBootRecoveryWork(), isTrue);
      },
    );

    test(
      'hasBootRecoveryWork is false when the exports root cannot be '
      "resolved, mirroring runBootRecovery's own no-op on that boot",
      () async {
        final brokenRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => throw const FileSystemException('gone'),
          now: () => clock,
        );
        addTearDown(brokenRepo.dispose);

        expect(await brokenRepo.hasBootRecoveryWork(), isFalse);
      },
    );

    test(
      "boot-2 re-salvage of a stranded bundle preserves the manifest's "
      'armSnapshot byte-for-byte — no second finalize runs to strip it '
      '(#679 r4)',
      () async {
        // A real crashed capture WITH an arm snapshot: armed by a first
        // repository "session" (which writes arm-snapshot.json), then the
        // process dies — a fresh repository per boot stands in for the
        // restarts, since arm() latches _armedDir for the process lifetime.
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        final sessionRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          now: () => clock,
        );
        await sessionRepo.arm();
        final dir = sessionRepo.armedDirectory!;
        writeNativeSidecar(dir); // the drain's finalized: false sidecar
        sessionRepo.dispose(); // crash: no disarm ever runs

        // Boot 1: the salvage finalizes — folding arm-snapshot.json into
        // the manifest and deleting that file — but its render times out,
        // stranding the bundle.
        engine.renderProgressAfterBegin = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final boot1 = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => '${tempDir.path}/exports',
          now: () => clock,
          bootRecoveryPollInterval: const Duration(milliseconds: 2),
          bootRecoveryRenderTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(boot1.dispose);
        await boot1.runBootRecovery();
        final manifestAfterBoot1 = File(
          '$dir/performance.json',
        ).readAsStringSync();
        expect(
          manifestAfterBoot1,
          contains('armSnapshot'),
          reason: 'the first finalize folded the crash-survival file in',
        );
        expect(File('$dir/arm-snapshot.json').existsSync(), isFalse);

        // Boot 2: the render can run; the stranded path must go straight
        // to render + move — a second finalize would resolve the arm
        // snapshot only from the now-deleted crash-survival file and
        // rewrite the manifest without it.
        engine
          ..renderProgressAfterBegin = null
          ..renderProgress = PerformanceRenderProgress.empty;
        await repo.runBootRecovery();

        final moved =
            '${tempDir.path}/exports/recovered/${dir.split('/').last}';
        expect(
          File('$moved/performance.json').readAsStringSync(),
          manifestAfterBoot1,
          reason:
              'the manifest — armSnapshot, chains, routing — must survive '
              'the re-salvage byte-for-byte',
        );
      },
    );

    test(
      'the recovered-at stamp is written on the SOURCE before the rename — '
      'a move that dies mid-way leaves the stamp with the bundle, and the '
      'retry re-stamps at ITS landing, so the stamp records the arrival, '
      'never a month-old first attempt (#679 r6)',
      () async {
        // Boot 1: the move fails after the stamp (a file squatting where
        // recovered/ must go) — the crash-window simulation.
        final stranded = '${tempDir.path}/exports/perf-stranded';
        Directory(stranded).createSync(recursive: true);
        writeNativeSidecar(stranded, finalized: true);
        File(
          '$stranded/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        File('${tempDir.path}/exports/recovered').createSync();
        final boot1Clock = clock;

        await repo.runBootRecovery();

        final sourceStamp = File(
          '$stranded/${PerformanceRepository.recoveredAtStampName}',
        );
        expect(
          sourceStamp.readAsStringSync(),
          boot1Clock.millisecondsSinceEpoch.toString(),
          reason:
              'stamped strictly before the rename: the failed move left '
              'the stamp with the bundle, not in limbo',
        );

        // A month passes unpowered; boot 2 clears the squatter and the
        // sweep finishes the move.
        clock = clock.add(const Duration(days: 40));
        final boot2Clock = clock;
        File('${tempDir.path}/exports/recovered').deleteSync();

        await repo.runBootRecovery();

        final moved = '${tempDir.path}/exports/recovered/perf-stranded';
        expect(Directory(moved).existsSync(), isTrue);
        expect(
          File(
            '$moved/${PerformanceRepository.recoveredAtStampName}',
          ).readAsStringSync(),
          boot2Clock.millisecondsSinceEpoch.toString(),
          reason: 'the landing re-stamps: the stamp records the arrival',
        );

        // Later boots keep it: recovered audio is never deleted.
        clock = clock.add(const Duration(days: 400));
        await repo.runBootRecovery();
        expect(Directory(moved).existsSync(), isTrue);
      },
    );

    test(
      'a recovered-slug collision lands the second salvage under a suffixed '
      'name instead of overwriting the first',
      () async {
        final crashed = seedCrashed('perf-crashed');
        final prior = '${tempDir.path}/exports/recovered/perf-crashed';
        Directory(prior).createSync(recursive: true);
        writeNativeSidecar(prior, finalized: true);
        final marker = File('$prior/master.wav')
          ..writeAsStringSync('prior recovery');

        await repo.runBootRecovery();

        expect(Directory(crashed).existsSync(), isFalse);
        expect(
          Directory('$prior-1').existsSync(),
          isTrue,
          reason: 'the new salvage takes the suffixed slot',
        );
        expect(marker.readAsStringSync(), 'prior recovery');
      },
    );
  });

  group('captureProgress', () {
    test('reads zero/false when not armed', () {
      expect(repo.captureProgress, (
        elapsed: Duration.zero,
        overrun: false,
        selfStopped: false,
        stopReason: PerfStopReason.none,
      ));
    });

    test('reads elapsed time and overrun from the engine snapshot', () {
      engine
        ..perfFrames =
            48000 // 1 second at the fake's 48kHz sample rate
        ..perfOverruns = 3;

      final progress = repo.captureProgress;
      expect(progress.elapsed, const Duration(seconds: 1));
      expect(progress.overrun, isTrue);
    });

    test('flags overrun on silence-filled frames with no ring overrun', () {
      // #710: the take carried audible silence while perfOverruns read 0,
      // because the drain can fall behind for reasons the ring never sees.
      engine
        ..perfFrames = 48000
        ..perfOverruns = 0
        ..perfZeroFilledFrames = 128;

      expect(repo.captureProgress.overrun, isTrue);
    });

    test('carries why the engine stopped the take (#1198)', () {
      engine
        ..perfStopped = true
        ..perfStopReason = PerfStopReason.slowStorage;

      final progress = repo.captureProgress;
      expect(progress.selfStopped, isTrue);
      expect(progress.stopReason, PerfStopReason.slowStorage);
    });
  });

  group('renameCapture', () {
    late Directory root;

    setUp(() {
      root = Directory('${tempDir.path}/exports')..createSync(recursive: true);
    });

    test('renames the bundle folder to the sanitized slug', () async {
      final dir = Directory('${root.path}/perf-old')
        ..createSync(recursive: true);

      final renamed = await repo.renameCapture(dir.path, 'My Take!');

      expect(renamed, '${root.path}/My Take');
      expect(Directory(renamed).existsSync(), isTrue);
      expect(dir.existsSync(), isFalse);
    });

    test(
      'is a no-op that returns the same path when the slug is unchanged',
      () async {
        final dir = Directory('${root.path}/perf-same')
          ..createSync(recursive: true);

        final renamed = await repo.renameCapture(dir.path, 'perf-same');

        expect(renamed, dir.path);
        expect(dir.existsSync(), isTrue);
      },
    );

    test(
      'throws ArgumentError when the name folds to nothing usable',
      () async {
        final dir = Directory('${root.path}/perf-blank')
          ..createSync(recursive: true);

        await expectLater(
          repo.renameCapture(dir.path, '!!!'),
          throwsArgumentError,
        );
      },
    );

    test(
      'refuses the reserved name "recovered" — case-insensitively, since a '
      'case-insensitive exports volume would make the renamed take BE the '
      'salvage area, adopted by future salvages '
      '(#679 r5)',
      () async {
        final dir = Directory('${root.path}/perf-a')
          ..createSync(recursive: true);
        final marker = File('${dir.path}/master.wav')
          ..writeAsStringSync('the take');

        // The same refusal path as an unusable name — the UI pre-validates
        // with performanceCaptureSlug, so both surfaces show the inline
        // invalid-name error instead of a dead Save.
        await expectLater(
          repo.renameCapture(dir.path, 'recovered'),
          throwsArgumentError,
        );
        await expectLater(
          repo.renameCapture(dir.path, 'Recovered'),
          throwsArgumentError,
        );
        await expectLater(
          repo.renameCapture(dir.path, '  recovered  '),
          throwsArgumentError,
        );

        expect(dir.existsSync(), isTrue);
        expect(marker.readAsStringSync(), 'the take');
        expect(Directory('${root.path}/recovered').existsSync(), isFalse);
      },
    );

    test(
      'throws PerformanceNameCollision when the target slug already exists, '
      'carrying the colliding slug and a human-readable message naming it',
      () async {
        final dir = Directory('${root.path}/perf-a')
          ..createSync(recursive: true);
        Directory('${root.path}/Taken').createSync(recursive: true);

        await expectLater(
          repo.renameCapture(dir.path, 'Taken'),
          throwsA(
            isA<PerformanceNameCollision>()
                .having((e) => e.slug, 'slug', 'Taken')
                // The message is the class's contract: callers that do not
                // localize fall back to toString, which must name the
                // colliding folder rather than read as a raw type dump.
                .having((e) => e.toString(), 'toString', contains('Taken')),
          ),
        );
      },
    );
  });

  group('capture guard (#1198)', () {
    late GuardRegistry guards;
    late PerformanceRepository guarded;

    setUp(() {
      guards = GuardRegistry();
      guarded = PerformanceRepository(
        storageIo: fakeStorageIo,
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
        guards: guards,
      );
    });

    tearDown(() => guarded.dispose());

    List<GuardKind> blockingDeviceChange() => [
      for (final op in guards.blockers(
        GuardKind.deviceChange,
        const GuardScope.internal(),
      ))
        op.kind,
    ];

    test('a take on a volume holds its guard there: an eject of that '
        'volume is refused, one of another is not', () async {
      await guarded.arm(
        root: '${tempDir.path}/usb',
        scope: const GuardScope.removable(3),
      );
      expect(guarded.armedDirectory, isNotNull);

      expect(
        guards.blockers(GuardKind.eject, const GuardScope.removable(3)),
        [
          const ActiveOperation(
            kind: GuardKind.capture,
            scope: GuardScope.removable(3),
            purpose: PerformanceRepository.capturePurpose,
          ),
        ],
      );
      expect(
        guards.blockers(GuardKind.eject, const GuardScope.removable(4)),
        isEmpty,
      );
      await guarded.disarmAndFinalize();
    });

    /// What the table holds while the finalize is under way: read as soon
    /// as the engine has been disarmed, when the finalize is waiting on its
    /// first file read.
    Future<List<GuardKind>> activeWhileFinalizing() async {
      final disarms = engine.perfDisarmCalls;
      final done = guarded.disarmAndFinalize();
      while (engine.perfDisarmCalls == disarms) {
        await Future<void>.delayed(Duration.zero);
      }
      final kinds = [for (final op in guards.active) op.kind];
      await done;
      expect(guards.active, isEmpty);
      return kinds;
    }

    test('a take on a drive holds its guard through the finalize, which '
        'writes to that drive (#1177)', () async {
      await guarded.arm(
        root: '${tempDir.path}/usb',
        scope: const GuardScope.removable(3),
      );
      expect(await activeWhileFinalizing(), [GuardKind.capture]);
    });

    test('a take on Internal lets its guard go before the finalize', () async {
      await guarded.arm();
      expect(await activeWhileFinalizing(), isEmpty);
    });

    test('arm is refused at its commit while a device change is in '
        'flight, and says so', () async {
      final change = guards.enter(
        GuardKind.deviceChange,
        const GuardScope.internal(),
        purpose: 'audio apply',
      );
      final refusals = <PerformanceArmRefusal>[];
      final sub = guarded.armRefusals.listen(refusals.add);
      addTearDown(sub.cancel);

      expect(await guarded.arm(), EngineResult.notReady);
      await Future<void>.delayed(Duration.zero);
      expect(engine.perfArmCalls, 0);
      expect(guarded.armedDirectory, isNull);
      expect(
        Directory('${tempDir.path}/exports/perf-20260706-143015').existsSync(),
        isFalse,
      );
      final refused = (refusals.single as PerformanceArmGuardRefusal).refusal;
      expect(refused.wants, GuardKind.capture);
      expect(refused.blockers.single.purpose, 'audio apply');

      change.release();
      expect(await guarded.arm(), EngineResult.ok);
      expect(engine.perfArmCalls, 1);
    });

    test('a take holds the guard until it is finalized', () async {
      expect(await guarded.arm(), EngineResult.ok);
      expect(blockingDeviceChange(), [GuardKind.capture]);
      expect(
        guards.active.single.purpose,
        PerformanceRepository.capturePurpose,
      );

      engine.perfDisarmResult = EngineResult.device;
      expect(await guarded.disarmAndFinalize(), EngineResult.device);
      expect(blockingDeviceChange(), [GuardKind.capture]);

      engine.perfDisarmResult = EngineResult.ok;
      expect(await guarded.disarmAndFinalize(), EngineResult.ok);
      expect(blockingDeviceChange(), isEmpty);
    });

    test('a finalize that throws after the engine disarmed still releases '
        'the guard', () async {
      expect(await guarded.arm(), EngineResult.ok);
      writeNativeSidecar(guarded.armedDirectory!);
      final testZone = Zone.current;
      await expectLater(
        IOOverrides.runZoned(
          guarded.disarmAndFinalize,
          createFile: (path) {
            final real = testZone.run(() => File(path));
            return path.endsWith('/performance.json.publishing')
                ? _ManifestWriteFails(real)
                : real;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(engine.perfDisarmCalls, 1);
      expect(guards.active, isEmpty);
    });

    test('an arm the engine refuses releases the guard', () async {
      engine.perfArmResult = EngineResult.device;
      expect(await guarded.arm(), EngineResult.device);
      expect(guards.active, isEmpty);
    });

    test('an arm that never acknowledges releases the guard once '
        'cancelled', () async {
      engine.perfArmQueues = true;
      expect(await guarded.arm(), EngineResult.device);
      expect(guarded.armedDirectory, isNull);
      expect(guards.active, isEmpty);
    });
  });
}

String _name(String path) => path.split(RegExp(r'[/\\]')).last;

/// A [StorageIo] that cannot read a captured input's part: the master
/// converts, the input fails.
StorageIo _inputsUnreadable() => _InputsUnreadable();

class _InputsUnreadable extends FakeStorageIo {
  @override
  FileDigest digestFile(String path, {int offset = 0, int? length}) =>
      _name(path).startsWith('input-')
      ? const FileUnreadable()
      : super.digestFile(path, offset: offset, length: length);
}

/// An engine whose volume frees the room of every unlisted part a cut
/// conversion left in [dir] once it is deleted.
class _StrayAwareEngine extends FakePerformanceEngine {
  _StrayAwareEngine(this.dir, {required this.free});

  final String dir;
  final int free;

  @override
  VolumeSpace? volumeSpace(String path) {
    final stray = File('$dir/master-001.wav');
    final used = stray.existsSync() ? stray.lengthSync() : 0;
    return VolumeSpace(totalBytes: 1 << 40, freeBytes: free - used);
  }
}

/// A [StorageIo] whose second directory sync fails: the parts' sync works,
/// the interim sidecar's does not.
StorageIo _failSecondSync() => _FailSecondSync();

class _FailSecondSync extends FakeStorageIo {
  static int calls = 0;

  @override
  void syncDirectory(String path) {
    calls++;
    if (calls == 2) throw FileSystemException('sync failed', path);
    super.syncDirectory(path);
  }
}

StorageIo _syncAlwaysFails() => _SyncAlwaysFails();

class _SyncAlwaysFails extends FakeStorageIo {
  @override
  void syncDirectory(String path) =>
      throw FileSystemException('sync failed', path);
}
