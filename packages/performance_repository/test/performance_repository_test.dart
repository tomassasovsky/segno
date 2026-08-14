import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:wav_codec/wav_codec.dart';

import 'helpers/fake_performance_engine.dart';
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

/// A [File] whose [lastModifiedSync] throws — an `IOOverrides` hook modeling
/// an entry the filesystem refuses to stat, so a test can drive the prune's
/// skip-and-continue branch deterministically. Only the members the prune
/// touches on the manifest file are implemented; anything else is a test bug
/// and throws.
class _ThrowingMtimeFile implements File {
  _ThrowingMtimeFile(this._inner);

  final File _inner;

  @override
  bool existsSync() => _inner.existsSync();

  @override
  DateTime lastModifiedSync() =>
      throw const FileSystemException('mtime unreadable');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'not reached by _pruneRecovered on the manifest file: $invocation',
  );
}

/// A [Directory] whose [listSync] throws — an `IOOverrides` hook modeling a
/// recovered/ area the filesystem refuses to enumerate (fsck-damaged perms,
/// a yanked exports volume), so a test can drive the prune's skip-the-area
/// branch deterministically. [existsSync]/[createSync] delegate (the same
/// path is legitimately touched by the salvage's move); anything else is a
/// test bug and throws.
class _ThrowingListDirectory implements Directory {
  _ThrowingListDirectory(this._inner);

  final Directory _inner;

  @override
  bool existsSync() => _inner.existsSync();

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => throw const FileSystemException('unreadable directory');

  @override
  void createSync({bool recursive = false}) =>
      _inner.createSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'not reached by boot recovery on the recovered dir: $invocation',
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

  group('arm', () {
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
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));

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
            masterEffects: [BuiltInEffect(type: TrackEffectType.filter)],
            masterChainEnabled: false,
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
        // Master insert.
        expect(
          armSnapshot.masterEffects.single.typeCode,
          TrackEffectType.filter.code,
        );
        expect(armSnapshot.masterChainEnabled, isFalse);
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

    test(
      'is refused while an offline render is in flight, and works again '
      'once it completes (#671)',
      () async {
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 40,
        );

        final result = await repo.arm();

        // The refusal is a silent no-op success — the same shape as the
        // already-armed path and disarm's guard window; the observable is
        // the state that never changed, not the return value.
        expect(result, EngineResult.ok);
        expect(repo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);
        expect(Directory('${tempDir.path}/exports').existsSync(), isFalse);

        engine.renderProgress = PerformanceRenderProgress.empty;
        await repo.arm();
        expect(repo.armedDirectory, isNotNull);
        expect(engine.perfArmed, isTrue);
      },
    );

    test(
      'is refused while a boot-salvage finalize (recoverCapture) is in '
      'flight — the window where no armed directory exists to no-op on '
      '(#671)',
      () async {
        final dir = '${tempDir.path}/exports/perf-crashed';
        Directory(dir).createSync(recursive: true);
        writeNativeSidecar(dir);
        writeRawPcm('$dir/master.pcm', Float32List.fromList([0.1, 0.2]));

        final recovery = repo.recoverCapture(dir);
        final result = await repo.arm();

        expect(result, EngineResult.ok);
        expect(repo.armedDirectory, isNull);
        expect(engine.perfArmCalls, 0);

        await recovery;
        await repo.arm();
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
        writeRawPcm('$crashed/master.pcm', Float32List.fromList([0.1, 0.2]));

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
        expect(result, EngineResult.ok, reason: 'same silent-ok shape');
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
          engine: engine,
          exportsRoot: () => rootGate.future,
          now: () => clock,
        );
        addTearDown(gatedRepo.dispose);

        final arm1 = gatedRepo.arm(); // entry gate passes, parks on root
        final arm2 = gatedRepo.arm(); // overlaps arm1's suspended window
        rootGate.complete('${tempDir.path}/exports');

        expect(await arm1, EngineResult.ok);
        expect(await arm2, EngineResult.ok, reason: 'same silent-ok shape');

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
        writeRawPcm('$dirA/master.pcm', Float32List.fromList([0.1, 0.2]));

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
        expect(result, EngineResult.ok, reason: 'same silent-ok shape');
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
      writeRawPcm(
        '${r.armedDirectory!}/master.pcm',
        Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
      );
      writeRawPcm(
        '${r.armedDirectory!}/input-0.pcm',
        Float32List.fromList([0.5, 0.6, 0.7, 0.8]),
      );
    }

    test('converts master + captured-input raw PCM to WAV', () async {
      await armAndSeedNative(engine, repo);
      final dir = repo.armedDirectory!;

      final result = await repo.disarm();
      expect(result, EngineResult.ok);
      expect(engine.perfArmed, isFalse);

      final master = WavCodec.decodeFloat32(
        File('$dir/master.wav').readAsBytesSync(),
      );
      expect(master.channels, 2);
      expect(master.samples, Float32List.fromList([0.1, 0.2, 0.3, 0.4]));

      final input0 = WavCodec.decodeFloat32(
        File('$dir/live-input-0.wav').readAsBytesSync(),
      );
      expect(input0.channels, 2);
      expect(input0.samples, Float32List.fromList([0.5, 0.6, 0.7, 0.8]));
    });

    test(
      'merges arm + disarm snapshots into performance.json, finalized true',
      () async {
        engine.seedLane(0, 0, Float32List.fromList([1, 1]));
        await armAndSeedNative(engine, repo);
        final dir = repo.armedDirectory!;

        await repo.disarm();

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
        writeRawPcm(
          '${dir.path}/master.pcm',
          Float32List.fromList([0.25, 0.5]),
        );

        await repo.recoverCapture(dir.path);

        expect(File('${dir.path}/master.wav').existsSync(), isTrue);
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

  group('runBootRecovery (silent boot salvage, #679)', () {
    /// A crashed capture: unfinalized sidecar plus raw master PCM, the same
    /// fixture shape the recoverCapture tests use.
    String seedCrashed(String slug) {
      final dir = '${tempDir.path}/exports/$slug';
      Directory(dir).createSync(recursive: true);
      writeNativeSidecar(dir);
      writeRawPcm('$dir/master.pcm', Float32List.fromList([0.1, 0.2]));
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
          File('$recovered/master.wav').existsSync(),
          isTrue,
          reason: 'the salvage converts the raw PCM to usable audio',
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
      'prunes recovered entries older than recoveredRetention and keeps '
      'fresh ones',
      () async {
        final recoveredRoot = '${tempDir.path}/exports/recovered';
        final old = '$recoveredRoot/perf-old';
        final fresh = '$recoveredRoot/perf-fresh';
        Directory(old).createSync(recursive: true);
        Directory(fresh).createSync(recursive: true);
        writeNativeSidecar(old, finalized: true);
        writeNativeSidecar(fresh, finalized: true);
        // Age is the sidecar's mtime (recovery time); the injected clock is
        // "now". One entry past the window, one comfortably inside it.
        File('$old/performance.json').setLastModifiedSync(
          clock.subtract(
            PerformanceRepository.recoveredRetention + const Duration(days: 1),
          ),
        );
        File('$fresh/performance.json').setLastModifiedSync(
          clock.subtract(const Duration(days: 1)),
        );

        await repo.runBootRecovery();

        expect(Directory(old).existsSync(), isFalse);
        expect(Directory(fresh).existsSync(), isTrue);
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
        // A directory squatting on the finalize's WAV target: the PCM
        // conversion's writeAsBytes fails on it.
        Directory('$dir/master.wav').createSync();

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
        expect(result, EngineResult.ok, reason: 'same silent-ok shape');
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
        // A directory squatting on the finalize's WAV target: this
        // capture's salvage throws mid-finalize.
        Directory('$bad/master.wav').createSync();
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
      'an unreadable recovered/ area skips the prune whole without taking '
      'the rest of boot recovery down (#679 r3)',
      () async {
        final recoveredRoot = '${tempDir.path}/exports/recovered';
        Directory(recoveredRoot).createSync(recursive: true);
        final crashed = seedCrashed('perf-crashed');

        final testZone = Zone.current;
        await IOOverrides.runZoned(
          () => repo.runBootRecovery(),
          createDirectory: (path) {
            // Real directories must be constructed outside the override
            // zone, or the Directory() factory would re-enter this callback
            // forever.
            final real = testZone.run(() => Directory(path));
            return path == recoveredRoot ? _ThrowingListDirectory(real) : real;
          },
        );

        expect(
          Directory(crashed).existsSync(),
          isFalse,
          reason:
              'the crashed capture still recovered — a broken prune must '
              'not abort the boot',
        );
        expect(
          Directory('$recoveredRoot/perf-crashed').existsSync(),
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
          engine: engine,
          exportsRoot: () async => throw const FileSystemException('gone'),
          now: () => clock,
        );
        addTearDown(brokenRepo.dispose);

        await brokenRepo.runBootRecovery(); // must complete, not throw
      },
    );

    test(
      'survives the boot scan itself failing after prune/sweep already ran '
      '(the root resolves once, then the volume goes away)',
      () async {
        var rootCalls = 0;
        final flakyRepo = PerformanceRepository(
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
              'prune/sweep consumed the first resolution; the scan '
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
      'prune ages an entry missing its sidecar by the directory mtime — a '
      'freshly created sidecar-less entry stays',
      () async {
        final bare = '${tempDir.path}/exports/recovered/perf-bare';
        Directory(bare).createSync(recursive: true);

        await repo.runBootRecovery();

        expect(
          Directory(bare).existsSync(),
          isTrue,
          reason:
              'no sidecar to stamp recovery time: the fallback is the '
              "directory's own (fresh) mtime, well inside retention",
        );
      },
    );

    test(
      'an entry the filesystem refuses to stat is skipped by the prune — '
      'its prunable sibling still goes, and boot does not crash',
      () async {
        final recoveredRoot = '${tempDir.path}/exports/recovered';
        final unreadable = '$recoveredRoot/perf-unreadable';
        final old = '$recoveredRoot/perf-old';
        Directory(unreadable).createSync(recursive: true);
        Directory(old).createSync(recursive: true);
        writeNativeSidecar(unreadable, finalized: true);
        writeNativeSidecar(old, finalized: true);
        // Both entries are old enough to prune; only the readable one may
        // actually go.
        final oldStamp = clock.subtract(
          PerformanceRepository.recoveredRetention + const Duration(days: 1),
        );
        File('$unreadable/performance.json').setLastModifiedSync(oldStamp);
        File('$old/performance.json').setLastModifiedSync(oldStamp);

        final testZone = Zone.current;
        await IOOverrides.runZoned(
          () => repo.runBootRecovery(),
          createFile: (path) {
            // Real files must be constructed outside the override zone, or
            // the File() factory would re-enter this callback forever.
            final real = testZone.run(() => File(path));
            return path == '$unreadable/${PerformanceRepository.manifestName}'
                ? _ThrowingMtimeFile(real)
                : real;
          },
        );

        expect(
          Directory(unreadable).existsSync(),
          isTrue,
          reason: 'an unstatable entry is skipped, never guessed at',
        );
        expect(
          Directory(old).existsSync(),
          isFalse,
          reason: 'the loop continued past the failure to its sibling',
        );
      },
    );

    test(
      'never prunes an entry whose mtime predates the sanity floor — an '
      'RTC-less boot stamps near-epoch mtimes that a later-corrected clock '
      'would misread as decades of age (#679 r2)',
      () async {
        final nearEpoch = '${tempDir.path}/exports/recovered/perf-preclock';
        Directory(nearEpoch).createSync(recursive: true);
        writeNativeSidecar(nearEpoch, finalized: true);
        File(
          '$nearEpoch/performance.json',
        ).setLastModifiedSync(DateTime.utc(1970, 1, 2));

        await repo.runBootRecovery();

        expect(
          Directory(nearEpoch).existsSync(),
          isTrue,
          reason: 'a clearly-wrong timestamp must never justify a delete',
        );
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
      expect(
        repo.captureProgress,
        (elapsed: Duration.zero, overrun: false, selfStopped: false),
      );
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
}
