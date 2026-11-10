import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/performance/application/daw_project_export.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno_engine/segno_engine.dart'
    show
        EngineResult,
        EngineSnapshot,
        LaneSnapshot,
        LatencyState,
        PerfTarget,
        PerformanceRenderProgress,
        PerformanceRenderTrackStatus,
        TrackSnapshot,
        TrackState;

import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../../helpers/helpers.dart';

/// `events.log`'s 12-byte header: `PLEV` magic + 4 reserved bytes + a
/// little-endian int32 sample rate (docs/formats/performance-event-log-format
/// .md), reproduced here the same way `EventLogReader` itself does, so a test
/// fixture can write a log with at least one entry.
Uint8List _eventLogHeader({int sampleRate = 48000}) {
  final out = Uint8List(12)..setRange(0, 4, 'PLEV'.codeUnits);
  ByteData.sublistView(out).setInt32(8, sampleRate, Endian.little);
  return out;
}

Uint8List _eventLogEntry({int frame = 0, int code = 7}) {
  final bytes = ByteData(28)
    ..setUint64(0, frame, Endian.little)
    ..setInt32(8, code, Endian.little);
  return bytes.buffer.asUint8List();
}

void writeManifest(
  String dir, {
  String? stoppedEarly,
  bool finalized = true,
  int zeroFilledFrames = 0,
}) {
  final json = {
    'slug': dir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last,
    'sample_rate': 48000,
    'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
    'capture_frames': 4800,
    'overrun_count': 0,
    'zero_filled_frames': zeroFilledFrames,
    'overrun_gaps': <Map<String, dynamic>>[],
    'layers': <Map<String, dynamic>>[],
    'stopped_early': ?stoppedEarly,
    'finalized': finalized,
  };
  File(
    '$dir/performance.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// Waits for [cubit] to reach [PerformanceRecorderCompleted] — the render
/// pipeline's tail writes `.als`/`fx-chains.txt` via real (non-microtask)
/// file I/O, so `pumpEventQueue()` alone cannot reliably observe it; this
/// polls the actual stream instead, with a generous timeout so a genuine
/// regression still fails loudly rather than hanging.
Future<PerformanceRecorderCompleted> waitForCompleted(
  PerformanceRecorderCubit cubit,
) async {
  final state = cubit.state;
  if (state is PerformanceRecorderCompleted) return state;
  return cubit.stream
      .firstWhere((s) => s is PerformanceRecorderCompleted)
      .timeout(const Duration(seconds: 5))
      .then((s) => s as PerformanceRecorderCompleted);
}

/// One stopped track with one settled lane: a completion over it exports one
/// DAW track.
const _settledLaneSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  outputChannels: 2,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    TrackSnapshot(
      state: TrackState.stopped,
      volume: 1,
      muted: false,
      lengthFrames: 4800,
      undoDepth: 0,
      rms: 0,
      peak: 0,
      lanes: [
        LaneSnapshot(
          inputChannel: 0,
          outputMask: 0x1,
          volume: 1,
          muted: false,
          lengthFrames: 4800,
          rms: 0,
          peak: 0,
        ),
      ],
    ),
  ],
);

void main() {
  late Directory tempDir;
  late FakeAudioEngine engine;
  late PerformanceRepository performance;
  late DateTime clock;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('segno_perf_cubit');
    engine = FakeAudioEngine();
    clock = DateTime(2026, 7, 6, 14, 30, 15);
    performance = PerformanceRepository(
      storageIo: fakeStorageIo,
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => '${tempDir.path}/exports',
      now: () => clock,
    );
  });

  tearDown(() {
    performance.dispose();
    tempDir.deleteSync(recursive: true);
  });

  PerformanceRecorderCubit build({
    DateTime Function()? now,
    Future<int?> Function(String path)? freeSpaceBytes,
    PerformanceChains Function()? currentChains,
    Duration armedTickInterval = const Duration(milliseconds: 10),
    bool Function()? takeLocked,
  }) => PerformanceRecorderCubit(
    performance: performance,
    armedTickInterval: armedTickInterval,
    renderPollInterval: const Duration(milliseconds: 10),
    now: now ?? (() => clock),
    freeSpaceBytes: freeSpaceBytes ?? (_) async => null,
    currentChains: currentChains ?? PerformanceChains.new,
    takeLocked: takeLocked ?? () => false,
  );

  /// Arms via the repository directly and seeds a real `events.log` +
  /// `performance.json` in the armed directory so a subsequent disarm has
  /// something non-trivial to finalize/render — mirrors
  /// `performance_repository_test.dart`'s own native-sidecar fixture style.
  Future<String> armWithLog(
    PerformanceRepository repo, {
    int entries = 1,
    int zeroFilledFrames = 0,
  }) async {
    await repo.arm();
    final dir = repo.armedDirectory!;
    final bytes = BytesBuilder()..add(_eventLogHeader());
    for (var i = 0; i < entries; i++) {
      bytes.add(_eventLogEntry(frame: i * 100));
    }
    File('$dir/events.log').writeAsBytesSync(bytes.toBytes());
    writeManifest(
      dir,
      finalized: false,
      zeroFilledFrames: zeroFilledFrames,
    );
    return dir;
  }

  /// Arms, disarms, and waits for a full [PerformanceRecorderCompleted] with
  /// a [PerformanceRecordDone] result — the shared "already-finished
  /// capture" starting point for the [renameCompletedCapture] tests, which
  /// act on a state past the render pipeline.
  Future<PerformanceRecorderCubit> completedCubit() async {
    engine.renderStatuses = const [
      PerformanceRenderTrackStatus(channel: 0, succeeded: true),
    ];
    final cubit = build();
    addTearDown(cubit.close);
    await armWithLog(performance);
    await pumpEventQueue();
    clock = clock.add(const Duration(seconds: 5));
    await cubit.toggleArm();
    await waitForCompleted(cubit);
    return cubit;
  }

  group('load', () {
    blocTest<PerformanceRecorderCubit, PerformanceRecorderState>(
      'recovers an unfinalized capture at boot with no prompt and no '
      'dialog-triggering state — only the honest busy flag while the '
      'salvage actually runs — and the bundle lands finalized under '
      'recovered/ (#679)',
      setUp: () {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => const [
        // The record button reads this to disable — every press during the
        // salvage is refused by the repository's gates, and a live-looking
        // control that silently eats presses reads as dead (#679 r2).
        PerformanceRecorderIdle(recovering: true),
        PerformanceRecorderIdle(),
      ],
      verify: (_) {
        expect(
          Directory('${tempDir.path}/exports/perf-crashed').existsSync(),
          isFalse,
        );
        final manifest =
            jsonDecode(
                  File(
                    '${tempDir.path}/exports/recovered/perf-crashed/'
                    'performance.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
      },
    );

    blocTest<PerformanceRecorderCubit, PerformanceRecorderState>(
      'stays plain idle when there is nothing unfinalized',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => <PerformanceRecorderState>[],
    );

    test(
      'keeps the recovering flag up past load() while a timed-out salvage '
      "render still holds arm's gate, and clears it once the render "
      'settles (#679 r3)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        // A render the engine still reports in flight when runBootRecovery
        // returns (the repository's own timeout/slot handling is pinned in
        // its package tests) — exactly the window where arm is refused with
        // no Finalizing/Rendering state on screen to explain it.
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.load();

        expect(
          cubit.state,
          const PerformanceRecorderIdle(recovering: true),
          reason:
              "the live render still holds arm's render gate — clearing "
              'now would re-enable a button whose every press is refused',
        );

        engine.renderProgress = PerformanceRenderProgress.empty;
        await cubit.stream
            .firstWhere((s) => s == const PerformanceRecorderIdle())
            .timeout(const Duration(seconds: 5));
      },
    );

    test(
      'a pedal or MIDI arm while the salvage still renders says why, keeps '
      'the recovering flag, which still clears when the render settles, and '
      'arms once it has (#1633)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        // The pedal and MIDI controls reach the repository directly.
        expect(await performance.arm(), EngineResult.notReady);
        await pumpEventQueue();
        expect(
          cubit.state,
          const PerformanceRecorderIdle(
            recovering: true,
            busyWith: PerformanceArmBusy.rendering,
            refusal: 1,
          ),
        );
        // A second press is a new state, so it gets its own answer.
        expect(await performance.arm(), EngineResult.notReady);
        await pumpEventQueue();
        expect(
          cubit.state,
          const PerformanceRecorderIdle(
            recovering: true,
            busyWith: PerformanceArmBusy.rendering,
            refusal: 2,
          ),
        );

        engine.renderProgress = PerformanceRenderProgress.empty;
        await cubit.stream
            .firstWhere((s) => s == const PerformanceRecorderIdle())
            .timeout(const Duration(seconds: 5));
        expect(await performance.arm(), EngineResult.ok);
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());
      },
    );

    test(
      'a stranded-only boot (finalized bundle awaiting its move, nothing '
      'unfinalized) still shows the recovering flag until its re-attempted '
      'render settles (#679 r4)',
      () async {
        // The case findUnfinalized alone cannot see: finalized + marker.
        final stranded = Directory('${tempDir.path}/exports/perf-stranded')
          ..createSync(recursive: true);
        writeManifest(stranded.path);
        File(
          '${stranded.path}/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        // The re-attempted stem render holds arm's gate past load().
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 10,
        );
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.load();

        expect(
          cubit.state,
          const PerformanceRecorderIdle(recovering: true),
          reason:
              'a probe blind to stranded bundles would leave the record '
              'button enabled-looking while every press is refused',
        );

        engine.renderProgress = PerformanceRenderProgress.empty;
        await cubit.stream
            .firstWhere((s) => s == const PerformanceRecorderIdle())
            .timeout(const Duration(seconds: 5));
      },
    );

    test(
      'a recovery that blows up cannot wedge the recovering flag — the '
      'clearing emission runs in a finally (#679 r3)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        var rootCalls = 0;
        final blowingRepo = PerformanceRepository(
          storageIo: fakeStorageIo,
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async {
            rootCalls++;
            // The probe's scan resolves; recovery's own resolution throws
            // an Error — the kind no runtime guard is meant to catch.
            if (rootCalls > 1) throw StateError('bug');
            return '${tempDir.path}/exports';
          },
          now: () => clock,
        );
        addTearDown(blowingRepo.dispose);
        final cubit = PerformanceRecorderCubit(
          performance: blowingRepo,
          armedTickInterval: const Duration(milliseconds: 10),
          renderPollInterval: const Duration(milliseconds: 10),
          now: () => clock,
          freeSpaceBytes: (_) async => null,
        );
        addTearDown(cubit.close);

        await expectLater(cubit.load(), throwsStateError);

        expect(
          cubit.state,
          const PerformanceRecorderIdle(),
          reason:
              'the bug is the bug — a record button dead until restart '
              'must not be its second casualty',
        );
      },
    );

    test('is latched: a second call does not re-run recovery', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      // A capture crashed AFTER boot recovery already ran: the latch means
      // it stays put until the next boot's load().
      final dir = Directory('${tempDir.path}/exports/perf-crashed')
        ..createSync(recursive: true);
      writeManifest(dir.path, finalized: false);
      await cubit.load();

      expect(dir.existsSync(), isTrue);
      expect(cubit.state, const PerformanceRecorderIdle());
    });
  });

  group('toggleArm', () {
    test('idle -> armed on first call', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(cubit.state, isA<PerformanceRecorderArmed>());
    });

    test('takeLocked leaves idle unarmed', () async {
      final cubit = build(takeLocked: () => true);
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(cubit.state, isA<PerformanceRecorderIdle>());
    });

    test('stamps the provider chains into the arm snapshot', () async {
      // The bug this guards: every call site used to arm with no chains at
      // all, so the snapshot documented an empty rig and a wet stem exported
      // identical to its dry source.
      final cubit = build(
        currentChains: () => const PerformanceChains(
          monitors: [
            PerformanceMonitorState(
              input: 1,
              enabled: true,
              outputMask: 0x2,
              volume: 0.5,
              muted: false,
              effects: [],
            ),
          ],
          limiterEnabled: true,
          limiterCeiling: 0.8,
        ),
      );
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      final snapshot =
          jsonDecode(
                File(
                  '${performance.armedDirectory}/arm-snapshot.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(snapshot['limiterOn'], isTrue);
      expect(snapshot['limiterCeiling'], 0.8);
      expect(snapshot['monitors'], hasLength(1));
      expect((snapshot['monitors'] as List).single, containsPair('input', 1));
    });

    test('reads the chains at arm time, not at construction', () async {
      // The rig changes between captures, so the provider is called per arm
      // rather than resolved once when the cubit is built.
      var calls = 0;
      final cubit = build(
        currentChains: () {
          calls++;
          return const PerformanceChains();
        },
      );
      addTearDown(cubit.close);
      expect(calls, 0);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(calls, 1);
    });

    test(
      'armed -> disarm path on a second call after the guard window',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        // The double-press guard (D-GUARD) now lives in
        // PerformanceRepository.disarm itself, keyed off the SHARED `clock`
        // this cubit's `performance` reads — not the cubit's own `now`.
        clock = clock.add(const Duration(seconds: 2));
        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isNot(isA<PerformanceRecorderArmed>()));
      },
    );

    test(
      'a disarm attempted within 1s of arm is ignored (double-press guard)',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        clock = clock.add(const Duration(milliseconds: 500));
        await cubit.toggleArm();
        await pumpEventQueue();

        // Still armed: the disarm was swallowed by the guard.
        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(engine.perfDisarmCalls, 0);
      },
    );

    test('is refused while finalizing/rendering, and the finishing state '
        'counts the press so it can say why (#1633)', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.toggleArm();
      await pumpEventQueue();

      // A render that never finishes on its own, so the cubit is
      // deterministically caught mid-Rendering rather than racing a real
      // disarm+render pipeline that might settle before the assertions run.
      // Installed only after the arm above: the repository's own gate (#671)
      // now refuses arm while a render is in flight, so setting this first
      // would refuse the very arm the test needs.
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 50,
      );

      // Kick off a disarm directly on the repository so the cubit is driven
      // into finalizing/rendering without going through toggleArm's own
      // guard, then attempt an arm mid-flight.
      final disarming = performance.disarmAndFinalize();
      await cubit.stream.firstWhere(
        (s) => s is! PerformanceRecorderIdle && s is! PerformanceRecorderArmed,
      );
      expect(cubit.state, isNot(isA<PerformanceRecorderIdle>()));

      await cubit.toggleArm(); // refused: not idle
      expect(engine.perfArmCalls, 1, reason: 'no second arm went through');
      expect(
        cubit.state,
        anyOf(
          isA<PerformanceRecorderFinalizing>()
              .having((s) => s.refusal, 'refusal', 1)
              .having(
                (s) => (s.refusedWith! as PerformanceArmBusyRefusal).busy,
                'busy',
                PerformanceArmBusy.finalizing,
              ),
          isA<PerformanceRecorderRendering>()
              .having((s) => s.refusal, 'refusal', 1)
              .having(
                (s) => (s.refusedWith! as PerformanceArmBusyRefusal).busy,
                'busy',
                PerformanceArmBusy.rendering,
              ),
        ),
      );

      // The empty take is discarded after the disarm returns: let that file
      // work end before tear-down deletes its directory (#1366).
      await disarming;
      await waitForCompleted(cubit);
    });

    test(
      'a pedal-path repository arm mid-render is refused too, and the '
      'Rendering state is not yanked (#671)',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        // Never-finishing render, installed after the arm above so the gate
        // under test doesn't refuse the setup itself.
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 30,
        );
        clock = clock.add(const Duration(seconds: 5));
        unawaited(performance.disarmAndFinalize());
        await cubit.stream
            .firstWhere((s) => s is PerformanceRecorderRendering)
            .timeout(const Duration(seconds: 5));

        // The pedal's MODE long-press calls the repository directly,
        // bypassing toggleArm — the repository's own gate must refuse it, or
        // the armed status would clobber the render flow out from under the
        // cubit (and its result dialog).
        expect(await performance.arm(), EngineResult.notReady);
        await pumpEventQueue();

        expect(performance.armedDirectory, isNull);
        expect(engine.perfArmCalls, 1, reason: 'only the initial arm');
        expect(
          cubit.state,
          isA<PerformanceRecorderRendering>()
              .having((s) => s.percent, 'percent', 30)
              .having((s) => s.refusal, 'refusal', 1),
          reason: 'the render keeps its face and counts the refused press',
        );

        // Once the render completes the gate lifts and the pedal can arm a
        // fresh capture again.
        engine.renderProgress = PerformanceRenderProgress.empty;
        await waitForCompleted(cubit);
        await performance.arm();
        expect(performance.armedDirectory, isNotNull);
      },
    );

    test('a finalize that throws lands on idle saying the take was not '
        'saved, and Capture arms again (#1639)', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));
      final testZone = Zone.current;
      await IOOverrides.runZoned(
        cubit.toggleArm,
        createFile: (path) {
          final real = testZone.run(() => File(path));
          return path.endsWith('/performance.json.publishing')
              ? _ManifestWriteFails(real)
              : real;
        },
      );
      await pumpEventQueue();
      expect(
        cubit.state,
        const PerformanceRecorderIdle(
          takeFailed: PerformanceTakeFailure.notSaved,
        ),
      );
      expect(performance.armBusy, isNull, reason: 'the hold is released');

      await cubit.toggleArm();
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());
    });

    test('a stop that fails before the engine stops returns to the same '
        'take, keeping when it started, and the next stop delivers it '
        '(#1639)', () async {
      final broken = _DisarmThrowsOnce();
      final repo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(repo.dispose);
      final cubit = PerformanceRecorderCubit(
        performance: repo,
        armedTickInterval: const Duration(milliseconds: 10),
        renderPollInterval: const Duration(milliseconds: 10),
        now: () => clock,
        freeSpaceBytes: (_) async => null,
      );
      addTearDown(cubit.close);
      final states = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.toggleArm();
      await pumpEventQueue();
      final dir = repo.armedDirectory!;
      writeManifest(dir, finalized: false);
      File('$dir/events.log').writeAsBytesSync(
        (BytesBuilder()
              ..add(_eventLogHeader())
              ..add(_eventLogEntry()))
            .toBytes(),
      );
      clock = clock.add(const Duration(seconds: 5));

      broken.throwDisarm = true;
      await cubit.toggleArm();
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());
      expect(repo.armedDirectory, dir);
      expect(repo.armBusy, isNull, reason: 'the hold is released');
      final finalizing = states.indexWhere(
        (s) => s is PerformanceRecorderFinalizing,
      );
      expect(finalizing, isNonNegative);
      expect(states[finalizing + 1], isA<PerformanceRecorderArmed>());

      broken.throwDisarm = false;
      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(
        completed.duration,
        const Duration(seconds: 5),
        reason: "the failed stop must not restart the take's clock",
      );
    });

    test('a manifest of the wrong shape after the render still completes '
        'the take instead of staying on rendering (#1639)', () async {
      final cubit = build();
      addTearDown(cubit.close);
      final dir = await armWithLog(performance);
      await pumpEventQueue();
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 50,
      );
      clock = clock.add(const Duration(seconds: 5));
      await cubit.toggleArm();
      await cubit.stream
          .firstWhere((s) => s is PerformanceRecorderRendering)
          .timeout(const Duration(seconds: 5));

      // Well-formed JSON whose fields have the wrong types: reading it
      // throws a cast error, not an I/O one.
      File('$dir/performance.json').writeAsStringSync('{"slug": 5}');
      engine.renderProgress = PerformanceRenderProgress.empty;
      final completed = await waitForCompleted(cubit);
      expect(completed.result, PerformanceRecordDone(dir));
      expect(completed.tracks, isEmpty);
    });

    test('a delivery that throws anywhere else lands on idle saying the '
        'take was not finished, and Capture arms again (#1639)', () async {
      final broken = _RenderStatusThrows();
      final repo = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: broken,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(repo.dispose);
      final cubit = PerformanceRecorderCubit(
        performance: repo,
        armedTickInterval: const Duration(milliseconds: 10),
        renderPollInterval: const Duration(milliseconds: 10),
        now: () => clock,
        freeSpaceBytes: (_) async => null,
      );
      addTearDown(cubit.close);
      await armWithLog(repo);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));
      await cubit.toggleArm();
      await cubit.stream
          .firstWhere(
            (s) => s is PerformanceRecorderIdle && s.takeFailed != null,
          )
          .timeout(const Duration(seconds: 5));
      expect(
        cubit.state,
        const PerformanceRecorderIdle(
          takeFailed: PerformanceTakeFailure.notFinished,
        ),
      );
      expect(repo.armBusy, isNull, reason: 'the hold is released');

      await cubit.toggleArm();
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());
    });

    test(
      'a pedal arm after the stem render, while the DAW project is still '
      'being written, is refused as a take being saved, and arms once the '
      'take is delivered (#1638)',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 90,
        );
        clock = clock.add(const Duration(seconds: 5));
        unawaited(performance.disarmAndFinalize());
        await cubit.stream
            .firstWhere((s) => s is PerformanceRecorderRendering)
            .timeout(const Duration(seconds: 5));

        // The engine's render ends; this cubit has not delivered the take
        // yet. In the same synchronous turn, a pedal press arrives.
        engine.renderProgress = PerformanceRenderProgress.empty;
        expect(performance.armBusy, PerformanceArmBusy.finalizing);
        final refused = performance.arm();
        final completed = waitForCompleted(cubit);
        expect(await refused, EngineResult.notReady);
        expect(engine.perfArmCalls, 1, reason: 'only the first take');

        await completed;
        expect(performance.armBusy, isNull);
        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());
      },
    );

    test('a finalize that throws releases the delivery hold, so Capture is '
        'available again (#1638)', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));
      final testZone = Zone.current;
      await expectLater(
        IOOverrides.runZoned(
          performance.disarmAndFinalize,
          createFile: (path) {
            final real = testZone.run(() => File(path));
            return path.endsWith('/performance.json.publishing')
                ? _ManifestWriteFails(real)
                : real;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      await pumpEventQueue();
      expect(performance.armBusy, isNull);
      expect(await performance.arm(), EngineResult.ok);
    });

    test(
      'a short take discarded while its render runs frees the render slot: '
      'the next press arms instead of being refused as rendering (#1638)',
      () async {
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.toggleArm();
        await pumpEventQueue();
        // The drain's sidecar, so the finalize starts the take's render.
        writeManifest(performance.armedDirectory!, finalized: false);
        // Past the 1 s double-press guard, under the 2 s short-take bound.
        clock = clock.add(const Duration(milliseconds: 1500));
        // The render the disarm's finalize starts is still running.
        engine.renderProgress = const PerformanceRenderProgress(
          done: false,
          progressPercent: 0,
        );
        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isTrue);
        expect(engine.renderCancelCalls, 1);
        expect(performance.armBusy, isNull);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());
      },
    );

    test(
      'arms normally once boot recovery has completed — no leftover prompt '
      'state ever blocks the toolbar (#679)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-crashed')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        expect(cubit.state, const PerformanceRecorderIdle());

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(engine.perfArmCalls, 1);
      },
    );

    blocTest<PerformanceRecorderCubit, PerformanceRecorderState>(
      'is refused while the boot salvage is still running, before the '
      'free-space probe, and says why without dropping the recovering flag '
      '(#679 r2, #1633)',
      build: build,
      seed: () => const PerformanceRecorderIdle(recovering: true),
      act: (cubit) => cubit.toggleArm(),
      expect: () => const <PerformanceRecorderState>[
        PerformanceRecorderIdle(
          recovering: true,
          busyWith: PerformanceArmBusy.finalizing,
          refusal: 1,
        ),
      ],
      verify: (_) => expect(engine.perfArmCalls, 0),
    );

    test(
      'arms again from a settled Completed state, not stuck forever '
      '(D-REARM)',
      () async {
        final cubit = await completedCubit();
        expect(cubit.state, isA<PerformanceRecorderCompleted>());

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(
          engine.perfArmCalls,
          2,
          reason: 'one arm from completedCubit(), one from the re-arm',
        );
      },
    );

    test(
      'arms again from a discarded-short Completed state too (D-REARM)',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        // Past the 1s double-press guard, but still under the 2s
        // short-capture threshold, with no events.log — auto-discards.
        clock = clock.add(const Duration(milliseconds: 1500));
        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isTrue);

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(engine.perfArmCalls, 2);
      },
    );
  });

  group('reactive status-stream driving', () {
    test(
      'disarmAndFinalize called directly on the repository still drives the '
      "cubit through Finalizing -> Rendering -> Completed (SessionCubit's "
      'auto-disarm path)',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        // Advance the clock past the 2s short-capture window so this counts
        // as a real (long enough) capture.
        clock = clock.add(const Duration(seconds: 5));

        final states = <PerformanceRecorderState>[];
        final sub = cubit.stream.listen(states.add);

        await performance.disarmAndFinalize(); // bypasses cubit.toggleArm
        await waitForCompleted(cubit);
        await sub.cancel();

        expect(
          states.any((s) => s is PerformanceRecorderFinalizing),
          isTrue,
        );
        expect(
          states.any((s) => s is PerformanceRecorderRendering),
          isTrue,
        );
        expect(states.last, isA<PerformanceRecorderCompleted>());
      },
    );
  });

  group('glitch flag (#710)', () {
    test(
      'a capture whose only silence-fill lands after the last armed tick '
      'still finalizes with hadGlitch set',
      () async {
        // The drain thread's FINAL cycle — the one disarm joins — flushes
        // whatever was still buffered, so it can silence-fill after the
        // armed ticker is already cancelled. A tick interval far longer than
        // this test's runtime guarantees the ONLY reading that can see the
        // counter is the one taken at the Finalizing transition.
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build(armedTickInterval: const Duration(minutes: 1));
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        // No ring overrun: exactly #710's signature — the take carries
        // silence while the overrun counter reads clean.
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 256,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: LatencyState.idle,
          measuredLatencyMs: 0,
          perfZeroFilledFrames: 128,
        );

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);

        expect(completed.hadGlitch, isTrue);
      },
    );

    test(
      'the manifest carries the glitch when the engine counters are already '
      'gone',
      () async {
        // Belt-and-braces path: the sidecar is the durable record of what the
        // drain wrote, so a reconfigure between the final cycle and finalize
        // (a device change, say) cannot launder a glitched take into a clean
        // one. The engine snapshot here reads perfectly clean.
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build(armedTickInterval: const Duration(minutes: 1));
        addTearDown(cubit.close);
        await armWithLog(performance, zeroFilledFrames: 192);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);

        expect(completed.hadGlitch, isTrue);
      },
    );

    test('a clean capture still finalizes with hadGlitch clear', () async {
      final cubit = await completedCubit();
      expect((cubit.state as PerformanceRecorderCompleted).hadGlitch, isFalse);
    });
  });

  group('render polling outcomes', () {
    test('PerformanceRecordDone when every track succeeds', () async {
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        PerformanceRenderTrackStatus(channel: 1, succeeded: true),
      ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordDone>());
    });

    test('PerformanceRecordPartial when the render cannot use its manifest '
        '(no track results)', () async {
      engine
        ..renderStatuses = const []
        ..renderProgress = const PerformanceRenderProgress(
          done: true,
          progressPercent: 100,
          failed: true,
        );
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordPartial>());
    });

    test('a valid render with zero tracks is still Done', () async {
      engine.renderStatuses = const [];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordDone>());
    });

    test('PerformanceRecordPartial when at least one track fails', () async {
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        PerformanceRenderTrackStatus(channel: 1, succeeded: false),
      ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));

      await cubit.toggleArm();
      final completed = await waitForCompleted(cubit);
      expect(completed.result, isA<PerformanceRecordPartial>());
    });

    test(
      'PerformanceRecordStoppedEarly when performance.json carries '
      'stopped_early',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        // perf_drain.c writes stopped_early into the STILL-armed sidecar
        // (finalized: false) the moment its own self-stop fires — finalize
        // then preserves that native field verbatim, so the fixture mirrors
        // that ordering rather than editing the manifest after the fact.
        writeManifest(dir, stoppedEarly: 'disk_full', finalized: false);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.result, isA<PerformanceRecordStoppedEarly>());
        final result = completed.result! as PerformanceRecordStoppedEarly;
        expect(result.reason, PerformanceStopReason.diskFull);
      },
    );

    for (final (field, reason) in const [
      ('reserve_reached', PerformanceStopReason.reserveReached),
      ('slow_storage', PerformanceStopReason.slowStorage),
    ]) {
      test('PerformanceRecordStoppedEarly reports $reason for $field '
          '(#1198)', () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        writeManifest(dir, stoppedEarly: field, finalized: false);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        final result = completed.result! as PerformanceRecordStoppedEarly;
        expect(result.reason, reason);
      });
    }

    test(
      'PerformanceRecordStoppedEarly reports deviceChanged for that field '
      'value',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        writeManifest(dir, stoppedEarly: 'device_changed', finalized: false);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        final result = completed.result! as PerformanceRecordStoppedEarly;
        expect(result.reason, PerformanceStopReason.deviceChanged);
      },
    );
  });

  group('export summary (tracks)', () {
    test(
      'a fresh completion populates tracks from a real settled lane, '
      "proving _finishRender's own read-and-assign wiring",
      () async {
        engine
          ..nextSnapshot = _settledLaneSnapshot
          ..laneExports[(0, 0)] = Float32List.fromList([0.1, 0.2, 0.3])
          ..renderStatuses = const [
            PerformanceRenderTrackStatus(channel: 0, succeeded: true),
          ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);

        expect(completed.tracks, hasLength(1));
        expect(completed.tracks.single.name, 'Track 0');
      },
    );
  });

  group('.als capture-tempo threading (#281)', () {
    /// Decompresses `project.als` (gzipped XML, `als_builder.dart`) and
    /// returns it as a string — the same decode `als_builder_test.dart`
    /// itself uses — so a test here can assert on the actual emitted
    /// `<Tempo>` value rather than trusting the wiring by inspection.
    String readAls(String dir) => utf8.decode(
      GZipCodec().decode(File('$dir/project.als').readAsBytesSync()),
    );

    /// A minimal running-engine snapshot reporting [bpm] — what the
    /// repository reads at arm AND at disarm, so a test scripts the tempo
    /// each of those passes sees by swapping this between them.
    EngineSnapshot snapshotWithTempo(double bpm) => EngineSnapshot(
      isRunning: true,
      sampleRate: 48000,
      bufferFrames: 128,
      outputChannels: 2,
      framesProcessed: 0,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: LatencyState.idle,
      measuredLatencyMs: -1,
      tempoBpm: bpm,
    );

    test(
      "the capture's own persisted tempo reaches the exported .als "
      '(end-to-end: engine snapshot -> repository manifest -> '
      'writeDawProject -> DawManifestReader.read -> DawProject -> '
      'buildAls), and a later DAW project write re-reads the same manifest — '
      "an old take's tempo can never drift after the fact",
      () async {
        engine
          ..renderStatuses = const [
            PerformanceRenderTrackStatus(channel: 0, succeeded: true),
          ]
          ..nextSnapshot = snapshotWithTempo(96);
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        await waitForCompleted(cubit);
        expect(readAls(dir), contains('<Manual Value="96.0"/>'));

        // Written again long after (Library > Audio's DAW project):
        // whatever the live transport reads now is irrelevant — the
        // manifest is the only tempo source (#281).
        engine.nextSnapshot = snapshotWithTempo(150);
        await writeDawProject(dir);

        expect(readAls(dir), contains('<Manual Value="96.0"/>'));
      },
    );

    test(
      'the DISARM-time tempo wins over the arm-time read: arm over an empty '
      'grid at 96, dial in 132 before the first loop, and the export stamps '
      "132 — D6's lock only engages once grid content exists (#281)",
      () async {
        engine
          ..renderStatuses = const [
            PerformanceRenderTrackStatus(channel: 0, succeeded: true),
          ]
          ..nextSnapshot = snapshotWithTempo(96);
        final cubit = build();
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        // The tempo the take actually settled on — only the disarm-time
        // pass can see it. 132, not 120, so a pass here can never be the
        // fallback masquerading as the disarm value.
        engine.nextSnapshot = snapshotWithTempo(132);
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        await waitForCompleted(cubit);

        expect(readAls(dir), contains('<Manual Value="132.0"/>'));
      },
    );

    test(
      'a capture with no tempo set (the default snapshot, 0-as-unset) still '
      "exports — at daw_export's own fixed 120 BPM fallback, the same "
      'outcome a legacy pre-#281 bundle resolves to',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build(); // EngineSnapshot.initial(): tempoBpm 0
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        await waitForCompleted(cubit);

        expect(readAls(dir), contains('<Manual Value="120.0"/>'));
      },
    );
  });

  group('short-capture auto-discard', () {
    test(
      'an armed period under 2s with no events.log auto-discards without '
      'rendering, deleting the capture directory',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        final dir = performance.armedDirectory!;
        // Past the 1s double-press guard, but still under the 2s
        // short-capture threshold.
        clock = clock.add(const Duration(milliseconds: 1500));

        await cubit.toggleArm(); // disarm
        final completed = await waitForCompleted(cubit);

        expect(completed.discarded, isTrue);
        expect(completed.result, isNull);
        expect(Directory(dir).existsSync(), isFalse);
        expect(
          engine.lastRenderCaptureDir,
          isNull,
          reason: 'a short empty capture skips the render pipeline entirely',
        );
      },
    );

    test(
      'an armed period under 2s with only the 12-byte PLEV header (zero '
      'entries) also auto-discards',
      () async {
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        final dir = performance.armedDirectory!;
        File('$dir/events.log').writeAsBytesSync(_eventLogHeader());
        // Past the 1s double-press guard, but still under the 2s
        // short-capture threshold.
        clock = clock.add(const Duration(milliseconds: 1500));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isTrue);
        expect(Directory(dir).existsSync(), isFalse);
      },
    );

    test(
      'a long-enough capture (>= 2s) with events runs the render pipeline '
      'instead of discarding',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);
        expect(completed.discarded, isFalse);
        expect(completed.result, isNotNull);
      },
    );
  });

  group('renameCompletedCapture', () {
    test('renames via the repository and updates the result path', () async {
      final cubit = await completedCubit();
      final before = cubit.state as PerformanceRecorderCompleted;
      final oldPath = (before.result! as PerformanceRecordDone).path;

      await cubit.renameCompletedCapture('My Take');

      final after = cubit.state as PerformanceRecorderCompleted;
      final newPath = (after.result! as PerformanceRecordDone).path;
      expect(newPath, isNot(oldPath));
      expect(newPath, endsWith('My Take'));
      expect(Directory(newPath).existsSync(), isTrue);
    });

    test(
      'a PerformanceNameCollision from the repository propagates (rethrows)',
      () async {
        final cubit = await completedCubit();
        Directory(
          '${tempDir.path}/exports/Taken',
        ).createSync(recursive: true);

        await expectLater(
          cubit.renameCompletedCapture('Taken'),
          throwsA(isA<PerformanceNameCollision>()),
        );
      },
    );

    test('preserves the export summary tracks across a rename', () async {
      engine
        ..nextSnapshot = _settledLaneSnapshot
        ..laneExports[(0, 0)] = Float32List.fromList([0.1, 0.2, 0.3])
        ..renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
      final cubit = build();
      addTearDown(cubit.close);
      await armWithLog(performance);
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 5));
      await cubit.toggleArm();
      final before = await waitForCompleted(cubit);
      expect(before.tracks, hasLength(1));

      await cubit.renameCompletedCapture('Renamed Take');

      final after = cubit.state as PerformanceRecorderCompleted;
      expect(after.tracks, before.tracks);
    });
  });

  group('free space (#640, #1198)', () {
    // A capture that armed onto a healthy disk ran 13.5 hours and filled a
    // 110GB partition, because the only check ran once at arm. The engine now
    // stops a take at the destination's reserve itself, counting every byte
    // it writes; the cubit refuses to start a take that could not hold
    // PerformanceRepository.minimumTake, warns while armed, and finalizes
    // whatever the engine stopped.

    test(
      'refuses to arm below the floor, and does not create a bundle',
      () async {
        final cubit = build(
          freeSpaceBytes: (_) async => performance.minimumFreeBytesToArm - 1,
        );
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderIdle>());
        expect((cubit.state as PerformanceRecorderIdle).lowDiskBlocked, isTrue);
        // The refusal must happen BEFORE arm(), or it costs a directory and a
        // finalize to arrive at the same refusal.
        expect(performance.armedDirectory, isNull);
      },
    );

    test('a busy repository is answered before the free-space probe, so '
        'the reason is never a low-disk one (#1633)', () async {
      var probes = 0;
      final cubit = build(
        freeSpaceBytes: (_) async {
          probes++;
          return 1;
        },
      );
      addTearDown(cubit.close);
      engine.renderProgress = const PerformanceRenderProgress(
        done: false,
        progressPercent: 20,
      );

      await cubit.toggleArm();

      expect(
        cubit.state,
        const PerformanceRecorderIdle(
          busyWith: PerformanceArmBusy.rendering,
          refusal: 1,
        ),
      );
      expect(probes, 0);
      expect(engine.perfArmCalls, 0);
    });

    test('each refused press emits its own state, so each gets an answer '
        '(#1198)', () async {
      final cubit = build(
        freeSpaceBytes: (_) async => performance.minimumFreeBytesToArm - 1,
      );
      addTearDown(cubit.close);
      final states = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.toggleArm();
      await cubit.toggleArm();
      await pumpEventQueue();

      expect(states, const [
        PerformanceRecorderIdle(lowDiskBlocked: true, refusal: 1),
        PerformanceRecorderIdle(lowDiskBlocked: true, refusal: 2),
      ]);
    });

    test(
      'defaults to the repository, which asks the engine — never a subprocess '
      '(#806)',
      () async {
        // The default used to run `df`, i.e. fork() the whole app, every
        // twenty armed ticks. On the appliance that is milliseconds of
        // mmap_lock held for write and an audible dropout in the monitor.
        // Built WITHOUT a freeSpaceBytes override, so this exercises the real
        // default path end to end.
        engine.freeBytes = performance.minimumFreeBytesToArm - 1;
        final cubit = PerformanceRecorderCubit(
          performance: performance,
          armedTickInterval: const Duration(milliseconds: 10),
          renderPollInterval: const Duration(milliseconds: 10),
          now: () => clock,
        );
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();

        expect((cubit.state as PerformanceRecorderIdle).lowDiskBlocked, isTrue);

        engine.freeBytes = performance.minimumFreeBytesToArm;
        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());

        // And a volume the platform cannot measure at all must still arm —
        // through the real default seam, not an injected stand-in. A
        // regression that turned that null into a 0 would otherwise refuse
        // every arm on the device while passing every test here.
        await cubit.toggleArm();
        await pumpEventQueue();
        engine.freeBytes = null;
        await cubit.toggleArm();
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
      },
    );

    test('the arm minimum is the reserve, the allowance and ten seconds of '
        'every captured stream with a header each', () {
      final reserved = PerformanceRepository(
        storageIo: fakeStorageIo,
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        guards: GuardRegistry(),
        reserveBytes: 1000000000,
      );
      engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
        sampleRate: 96000,
      );
      expect(
        reserved.minimumFreeBytesToArm,
        1000000000 + (1 << 20) + 84 + 96000 * 10 * 8,
      );
      expect(
        performance.minimumFreeBytesToArm,
        (1 << 20) + 84 + 96000 * 10 * 8,
        reason: 'no reserve: the allowance and the ten seconds alone',
      );

      // A stereo master and four captured stereo inputs: five streams of
      // eight bytes a frame each.
      engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
        sampleRate: 96000,
        perfCaptureStreams: 5,
        perfCaptureFrameBytes: 40,
      );
      expect(
        reserved.minimumFreeBytesToArm,
        1000000000 + (1 << 20) + 5 * 84 + 96000 * 10 * 40,
      );
    });

    test('arms normally when the volume has room', () async {
      final cubit = build(
        freeSpaceBytes: (_) async =>
            performance.minimumFreeBytesToArm +
            PerformanceRecorderCubit.lowDiskThresholdBytes * 2,
      );
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(cubit.state, isA<PerformanceRecorderArmed>());
      expect(
        (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
        isFalse,
      );
    });

    test(
      'warns while armed once free space falls under the warning line',
      () async {
        final minimum = performance.minimumFreeBytesToArm;
        var free = minimum + PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
        final cubit = build(freeSpaceBytes: (_) async => free);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isFalse,
        );

        // Under the warning line: warn, keep recording. Even with no room at
        // all the cubit does not stop the take; the engine does, at the
        // reserve, and says so.
        free = minimum + PerformanceRecorderCubit.lowDiskThresholdBytes - 1;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isTrue,
        );
      },
    );

    test('a low reading never stops the take from here', () async {
      var free = performance.minimumFreeBytesToArm;
      final cubit = build(freeSpaceBytes: (_) async => free);
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();
      free = 0;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();

      expect(cubit.state, isA<PerformanceRecorderArmed>());
      expect(performance.armedDirectory, isNotNull);
    });

    for (final (engineReason, reason) in const [
      (PerfStopReason.reserveReached, PerformanceStopReason.reserveReached),
      (PerfStopReason.slowStorage, PerformanceStopReason.slowStorage),
      (PerfStopReason.writeFailed, PerformanceStopReason.diskFull),
    ]) {
      test('a take the engine stopped for $engineReason finalizes as '
          'stopped early for $reason (#1198)', () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);
        await armWithLog(performance);
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        engine
          ..perfStopReason = engineReason
          ..perfStopped = true;
        final completed = await waitForCompleted(cubit);

        expect(
          (completed.result! as PerformanceRecordStoppedEarly).reason,
          reason,
        );
        expect(performance.armedDirectory, isNull);
      });
    }

    test(
      'a full disk during the .als export still completes the capture',
      () async {
        // Regression for what the appliance run caught: writeFrom failed with
        // ENOSPC inside _writeDawExports, and because _finishRender awaits
        // it on its first line, the Completed emit on its last line never
        // ran -- the console sat in Rendering forever. The take is already
        // safe by then, so a failed export must degrade, not hang.
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build();
        addTearDown(cubit.close);

        final dir = await armWithLog(performance);
        await pumpEventQueue();

        // Fail the .als write the way a full volume does: a directory cannot be
        // overwritten by a file, so writeAsBytes throws FileSystemException on
        // exactly the path _writeDawExports targets.
        Directory('$dir/project.als').createSync(recursive: true);

        clock = clock.add(const Duration(seconds: 5));
        await cubit.toggleArm();

        expect(
          await waitForCompleted(cubit),
          isA<PerformanceRecorderCompleted>(),
          reason: 'a failed export left the cubit stuck instead of completing',
        );
      },
    );

    test(
      'a disk stop on a discarded short capture does not taint the next',
      () async {
        // _afterFinalized emits `discardedShort` and RETURNS before the reset
        // in _finishRender, so a reason left over from a stop would be
        // reported against the next capture -- a healthy take blamed on a
        // full disk.
        final cubit = build();
        addTearDown(cubit.close);

        // First capture: the engine stopped it at the reserve, but it is too
        // short/empty to keep.
        await cubit.toggleArm();
        await pumpEventQueue();
        engine
          ..perfStopReason = PerfStopReason.reserveReached
          ..perfStopped = true;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        // Second capture, disarmed normally.
        engine
          ..perfStopReason = null
          ..perfStopped = false
          ..renderStatuses = const [
            PerformanceRenderTrackStatus(channel: 0, succeeded: true),
          ];
        await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));
        await cubit.toggleArm();
        final completed = await waitForCompleted(cubit);

        expect(
          completed.result,
          isNot(isA<PerformanceRecordStoppedEarly>()),
          reason: 'a stale stop reason was blamed on a healthy capture',
        );
      },
    );

    test('an engine self-stop finalizes the capture (#652)', () async {
      // The case the free-space floor cannot see coming: the write failed for
      // a reason free space does not predict -- a quota, a read-only remount,
      // an I/O error. The engine already stopped its drain thread; before the
      // flag was published the app never found out, so the capture stayed
      // armed with its handles open and finalize never ran.
      engine.renderStatuses = const [
        PerformanceRenderTrackStatus(channel: 0, succeeded: true),
      ];
      final cubit = build();
      addTearDown(cubit.close);

      await armWithLog(performance);
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());

      engine
        ..perfStopReason = PerfStopReason.writeFailed
        ..perfStopped = true;
      final completed = await waitForCompleted(cubit);

      expect(completed.result, isA<PerformanceRecordStoppedEarly>());
      expect(
        (completed.result! as PerformanceRecordStoppedEarly).reason,
        PerformanceStopReason.diskFull,
      );
      expect(performance.armedDirectory, isNull);
    });

    test(
      'an unanswerable volume neither blocks arming nor stops a capture',
      () async {
        // Windows, or df failing. `null` means "unknown", and reading it as
        // "no space" would stop every capture on those platforms.
        final cubit = build(freeSpaceBytes: (_) async => null);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
      },
    );
  });

  group('salvage boot (D-SALVAGE, silent since #679)', () {
    test('a take the salvage could not recover is reported once it settles, '
        'its files kept (#1198)', () async {
      final dir = Directory('${tempDir.path}/exports/perf-20260913-003635')
        ..createSync(recursive: true);
      writeManifest(dir.path, finalized: false);
      // A raw take from before #1198 with no room to convert it into parts
      // (sparse: no real disk use).
      File('${dir.path}/master.pcm').openSync(mode: FileMode.write)
        ..setPositionSync(1 << 30)
        ..writeFromSync([0, 0, 0, 0])
        ..closeSync();
      engine.freeBytes = 1 << 20;

      final cubit = build();
      addTearDown(cubit.close);
      final states = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.load();
      await pumpEventQueue();
      await sub.cancel();

      expect(states, const [
        PerformanceRecorderIdle(recovering: true),
        PerformanceRecorderIdle(notRecovered: 1),
      ]);
      expect(File('${dir.path}/master.pcm').existsSync(), isTrue);
    });

    test(
      'a capture dir left unfinalized on disk (performance.json without '
      'finalized: true) is recovered end-to-end at load: finalized, '
      'stem-rendered, and moved under recovered/ — with no prompt state '
      'and no dialog trigger ever emitted',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20260706-140000')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);

        final cubit = build();
        addTearDown(cubit.close);
        final states = <PerformanceRecorderState>[];
        final sub = cubit.stream.listen(states.add);

        await cubit.load();
        await pumpEventQueue();
        await sub.cancel();

        expect(
          states,
          const [
            PerformanceRecorderIdle(recovering: true),
            PerformanceRecorderIdle(),
          ],
          reason:
              'silent recovery surfaces only the honest busy flag — never '
              'a Rendering/Completed state, which would open the completion '
              'dialog at boot',
        );
        expect(dir.existsSync(), isFalse);
        final recovered =
            '${tempDir.path}/exports/recovered/perf-20260706-140000';
        final manifest =
            jsonDecode(File('$recovered/performance.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(manifest['finalized'], isTrue);
        expect(
          engine.lastRenderCaptureDir,
          dir.path,
          reason: 'the stem render ran as part of the salvage',
        );
      },
    );

    test(
      'a crashed capture that cannot finalize (corrupt sidecar) is left in '
      'place — never deleted, no crash — and reported as not recovered '
      '(#1198)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20260706-140000')
          ..createSync(recursive: true);
        File('${dir.path}/performance.json').writeAsStringSync('{not json');

        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        expect(dir.existsSync(), isTrue);
        expect(engine.lastRenderCaptureDir, isNull);
        expect(cubit.state, const PerformanceRecorderIdle(notRecovered: 1));
      },
    );

    test(
      'a salvage the app did not survive is not run again at load but '
      'reported, and retryRecovery salvages it (#1747)',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20261110-155051')
          ..createSync(recursive: true);
        writeManifest(dir.path, finalized: false);
        // The app stopped during two salvages of it in a row.
        File(
          '${dir.path}/${PerformanceRepository.recoveryMarkerName}',
        ).writeAsStringSync('');
        File(
          '${dir.path}/${PerformanceRepository.recoveryAttemptName}',
        ).writeAsStringSync('2\n');

        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();
        await pumpEventQueue();

        expect(engine.lastRenderCaptureDir, isNull);
        expect(cubit.state, const PerformanceRecorderIdle(notRecovered: 1));
        expect(dir.existsSync(), isTrue);

        final states = <PerformanceRecorderState>[];
        final sub = cubit.stream.listen(states.add);
        await cubit.retryRecovery();
        await pumpEventQueue();
        await sub.cancel();

        expect(states, const [
          PerformanceRecorderIdle(recovering: true),
          PerformanceRecorderIdle(),
        ]);
        expect(engine.lastRenderCaptureDir, dir.path);
        expect(
          Directory(
            '${tempDir.path}/exports/recovered/perf-20261110-155051',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test('retryRecovery is a no-op with nothing left unrecovered', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      final states = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.retryRecovery();
      await pumpEventQueue();
      await sub.cancel();

      expect(states, isEmpty);
    });
  });

  group('guard table (#1198)', () {
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

    PerformanceRecorderCubit buildGuarded() => PerformanceRecorderCubit(
      performance: guarded,
      armedTickInterval: const Duration(milliseconds: 10),
      renderPollInterval: const Duration(milliseconds: 10),
      now: () => clock,
      freeSpaceBytes: (_) async => null,
    );

    test('an arm refused at its commit lands on idle naming what refused '
        'it, from the toggle and from a direct call alike', () async {
      final cubit = buildGuarded();
      addTearDown(cubit.close);
      final apply = guards.enter(
        GuardKind.sessionApply,
        const GuardScope.internal(),
        purpose: 'opening a session',
      );

      final states = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.toggleArm();
      await pumpEventQueue();
      expect(states, const [
        PerformanceRecorderIdle(
          refusedBy: GuardKind.sessionApply,
          refusal: 1,
        ),
      ]);
      expect(engine.perfArmCalls, 0);

      // The pedal reaches the repository directly, with no cubit in front.
      // Its refusal is a second, distinct state: the toast answers it too.
      await guarded.arm();
      await pumpEventQueue();
      expect(states, hasLength(2));
      expect(
        states.last,
        const PerformanceRecorderIdle(
          refusedBy: GuardKind.sessionApply,
          refusal: 2,
        ),
      );
      expect(engine.perfArmCalls, 0);

      apply.release();
      await cubit.toggleArm();
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());
      expect(engine.perfArmCalls, 1);
    });

    test('a guard refusal while this cubit still writes the DAW project '
        '(Rendering, engine render done) keeps the guard as its reason '
        '(#1633)', () async {
      final cubit = buildGuarded()
        ..emit(const PerformanceRecorderRendering(percent: 100, name: 'x'));
      addTearDown(cubit.close);
      guards.enter(
        GuardKind.sessionApply,
        const GuardScope.internal(),
        purpose: 'open session',
      );
      expect(await guarded.arm(), EngineResult.notReady);
      await pumpEventQueue();
      expect(
        cubit.state,
        isA<PerformanceRecorderRendering>()
            .having((s) => s.percent, 'percent', 100)
            .having((s) => s.refusal, 'refusal', 1)
            .having(
              (s) => (s.refusedWith! as PerformanceArmGuardRefusal)
                  .refusal
                  .blockers
                  .first
                  .kind,
              'refused by',
              GuardKind.sessionApply,
            ),
      );
    });

    test('a refusal keeps the recovering idle, and says why', () async {
      final cubit = buildGuarded()
        ..emit(const PerformanceRecorderIdle(recovering: true));
      addTearDown(cubit.close);
      guards.enter(
        GuardKind.restart,
        const GuardScope.internal(),
        purpose: 'power off',
      );
      await guarded.arm();
      await pumpEventQueue();
      expect(
        cubit.state,
        const PerformanceRecorderIdle(
          recovering: true,
          refusedBy: GuardKind.restart,
          refusal: 1,
        ),
      );
    });
  });

  group('recording to a USB drive (#1177)', () {
    late FakeUsbStorageClient client;
    late StorageRepository storage;
    late String mount;
    late StorageDestination destination;

    RemovableVolumeRecord usb(int generation) => RemovableVolumeRecord(
      generation: generation,
      kname: 'sda1',
      fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
      label: 'SEGNO USB',
      fsType: 'exfat',
      mountPoint: mount,
      sizeBytes: 32000000000,
      status: RemovableVolumeRecordStatus.mounted,
      readOnly: false,
      writeBytesPerSecond: 16777216,
    );

    setUp(() async {
      mount = '${tempDir.path}/media/1-SEGNO_USB';
      Directory(mount).createSync(recursive: true);
      destination = const StorageDestination.removable(1);
      client = FakeUsbStorageClient(initial: [usb(1)]);
      storage = StorageRepository(
        guards: GuardRegistry(),
        client: client,
        exportsRoot: () async => '${tempDir.path}/exports',
        volumeSpace: (_) => null,
      );
      await pumpEventQueue();
    });

    tearDown(() async {
      await storage.dispose();
      await client.dispose();
    });

    PerformanceRecorderCubit buildUsb() => PerformanceRecorderCubit(
      performance: performance,
      armedTickInterval: const Duration(milliseconds: 10),
      renderPollInterval: const Duration(milliseconds: 10),
      now: () => clock,
      freeSpaceBytes: (_) async => null,
      storage: storage,
      destination: () => destination,
    );

    /// [waitForCompleted] with room for a loaded machine: the finalize and
    /// render here do real file work.
    Future<PerformanceRecorderCompleted> completedWithin(
      PerformanceRecorderCubit cubit,
    ) async {
      final state = cubit.state;
      if (state is PerformanceRecorderCompleted) return state;
      return cubit.stream
          .firstWhere((s) => s is PerformanceRecorderCompleted)
          .timeout(const Duration(seconds: 30))
          .then((s) => s as PerformanceRecorderCompleted);
    }

    void seedLog(String dir) {
      File('$dir/events.log').writeAsBytesSync(
        (BytesBuilder()
              ..add(_eventLogHeader())
              ..add(_eventLogEntry()))
            .toBytes(),
      );
      writeManifest(dir, finalized: false);
    }

    /// Ends the live take and waits for the cubit to finish with it. The
    /// cubit discards or renders the take after `disarmAndFinalize` returns;
    /// a test that ends first leaves that file work running against a
    /// temporary directory its tear-down deletes (#1366).
    Future<void> finishTake(PerformanceRecorderCubit cubit) async {
      await performance.disarmAndFinalize();
      await completedWithin(cubit);
    }

    test('a take arms on the drive under a recording lease, and the armed '
        'readout names the drive', () async {
      final cubit = buildUsb();
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(
        performance.armedDirectory,
        '$mount/Segno/Performances/perf-20260706-143015',
      );
      expect(storage.leasesOn(destination), [
        WriteLease(target: destination, purpose: WritePurpose.recording),
      ]);
      expect(
        cubit.state,
        isA<PerformanceRecorderArmed>().having(
          (s) => s.volumeLabel,
          'volumeLabel',
          'SEGNO USB',
        ),
      );
      await finishTake(cubit);
    });

    test('pulling the drive ends the take as volumeLost, once, and frees '
        'the drive; the next take defaults back to Internal', () async {
      final cubit = buildUsb();
      addTearDown(cubit.close);
      final finalizing = <PerformanceRecorderState>[];
      final sub = cubit.stream.listen(finalizing.add);
      addTearDown(sub.cancel);

      await cubit.toggleArm();
      await pumpEventQueue();
      seedLog(performance.armedDirectory!);

      client.detach(1);
      final completed = await completedWithin(cubit);

      expect(
        completed.result,
        isA<PerformanceRecordStoppedEarly>().having(
          (r) => r.reason,
          'reason',
          PerformanceStopReason.volumeLost,
        ),
      );
      expect(
        finalizing.whereType<PerformanceRecorderFinalizing>(),
        hasLength(1),
        reason: 'one stop',
      );
      expect(storage.leases, isEmpty);

      destination = const StorageDestination.internal();
      await cubit.toggleArm();
      await pumpEventQueue();
      expect(performance.armedDirectory, startsWith('${tempDir.path}/exports'));
      await finishTake(cubit);
    });

    test('a finished take releases the drive', () async {
      final cubit = buildUsb();
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();
      seedLog(performance.armedDirectory!);
      clock = clock.add(const Duration(seconds: 5));
      await finishTake(cubit);

      expect(storage.leases, isEmpty);
    });

    test('a chosen drive that is gone at the press refuses the arm and says '
        'why', () async {
      final cubit = buildUsb();
      addTearDown(cubit.close);
      client.detach(1);
      await pumpEventQueue();

      await cubit.toggleArm();

      expect(performance.armedDirectory, isNull);
      expect(
        cubit.state,
        isA<PerformanceRecorderIdle>().having(
          (s) => s.driveUnavailable,
          'driveUnavailable',
          isTrue,
        ),
      );
      expect(storage.leases, isEmpty);
    });

    test('an arm that throws on the drive gives the drive back and says '
        'why, and a later arm on Internal still works', () async {
      // A file where the take's directory must go: the bundle cannot be
      // created, as on a full or read-only-on-error stick.
      File('$mount/Segno').writeAsStringSync('in the way');
      final cubit = buildUsb();
      addTearDown(cubit.close);

      await cubit.toggleArm();

      expect(performance.armedDirectory, isNull);
      expect(storage.leases, isEmpty);
      expect(
        cubit.state,
        isA<PerformanceRecorderIdle>().having(
          (s) => s.driveUnavailable,
          'driveUnavailable',
          isTrue,
        ),
      );

      destination = const StorageDestination.internal();
      await cubit.toggleArm();
      expect(performance.armedDirectory, startsWith('${tempDir.path}/exports'));
      await finishTake(cubit);
    });

    test('a take that started on the drive but failed a later arm step '
        'keeps its lease, names the drive, and ends as volumeLost when the '
        'drive goes', () async {
      engine = _SnapshotBlockingEngine();
      final blocked = PerformanceRepository(
        storageIo: fakeStorageIo,
        guards: GuardRegistry(),
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
      );
      addTearDown(blocked.dispose);
      final cubit = PerformanceRecorderCubit(
        performance: blocked,
        armedTickInterval: const Duration(milliseconds: 10),
        renderPollInterval: const Duration(milliseconds: 10),
        now: () => clock,
        freeSpaceBytes: (_) async => null,
        storage: storage,
        destination: () => destination,
      );
      addTearDown(cubit.close);

      await cubit.toggleArm();
      await pumpEventQueue();

      expect(blocked.armedDirectory, isNotNull, reason: 'the take is live');
      expect(storage.leasesOn(destination), [
        WriteLease(target: destination, purpose: WritePurpose.recording),
      ]);
      expect(
        cubit.state,
        isA<PerformanceRecorderArmed>().having(
          (s) => s.volumeLabel,
          'volumeLabel',
          'SEGNO USB',
        ),
      );

      seedLog(blocked.armedDirectory!);
      client.detach(1);
      final completed = await completedWithin(cubit);
      expect(
        completed.result,
        isA<PerformanceRecordStoppedEarly>().having(
          (r) => r.reason,
          'reason',
          PerformanceStopReason.volumeLost,
        ),
      );
    });

    test('an arm refused at its commit gives the drive back', () async {
      final guards = GuardRegistry();
      final guarded = PerformanceRepository(
        storageIo: fakeStorageIo,
        engine: engine,
        exportsRoot: () async => '${tempDir.path}/exports',
        now: () => clock,
        guards: guards,
      );
      addTearDown(guarded.dispose);
      final cubit = PerformanceRecorderCubit(
        performance: guarded,
        freeSpaceBytes: (_) async => null,
        storage: storage,
        destination: () => destination,
      );
      addTearDown(cubit.close);
      final apply = guards.enter(
        GuardKind.sessionApply,
        const GuardScope.internal(),
        purpose: 'opening a session',
      );
      addTearDown(apply.release);

      await cubit.toggleArm();

      expect(guarded.armedDirectory, isNull);
      expect(storage.leases, isEmpty);
    });
  });
}

/// Starts the take, then makes the arm snapshot unpublishable: a directory
/// stands where its pending file must be written.
class _SnapshotBlockingEngine extends FakeAudioEngine {
  @override
  EngineResult perfArm(PerfTarget target) {
    Directory('${target.captureDir}/arm-snapshot.json.pending').createSync();
    return super.perfArm(target);
  }
}

/// A manifest whose publish write fails, as a full disk would.
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

/// An engine whose render results cannot be read once the render is done:
/// a delivery failure no catch inside the delivery expects.
class _RenderStatusThrows extends FakeAudioEngine {
  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() =>
      throw StateError('render results unavailable');
}

/// An engine whose disarm throws while [throwDisarm] is set, before
/// anything has stopped.
class _DisarmThrowsOnce extends FakeAudioEngine {
  bool throwDisarm = false;

  @override
  EngineResult perfDisarm() {
    if (throwDisarm) throw StateError('native cleanup unavailable');
    return super.perfDisarm();
  }
}
