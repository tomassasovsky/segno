import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno_engine/segno_engine.dart'
    show
        EngineSnapshot,
        LaneSnapshot,
        LatencyState,
        PerformanceRenderProgress,
        PerformanceRenderTrackStatus,
        TrackSnapshot,
        TrackState;

import '../../helpers/helpers.dart';

/// `events.log`'s 12-byte header: `PLEV` magic + 4 reserved bytes + a
/// little-endian int32 sample rate (docs/design/performance-event-log-format
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
    double Function()? currentTempoBpm,
    PerformanceChains Function()? currentChains,
    Duration armedTickInterval = const Duration(milliseconds: 10),
  }) => PerformanceRecorderCubit(
    performance: performance,
    armedTickInterval: armedTickInterval,
    renderPollInterval: const Duration(milliseconds: 10),
    now: now ?? (() => clock),
    freeSpaceBytes: freeSpaceBytes ?? (_) async => null,
    currentTempoBpm: currentTempoBpm ?? () => 0,
    currentChains: currentChains ?? PerformanceChains.new,
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
  /// capture" starting point for [renameCompletedCapture] and [reExport]
  /// tests alike, both of which act on a state past the render pipeline.
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

    test('is refused (a no-op) while finalizing/rendering', () async {
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
      unawaited(performance.disarmAndFinalize());
      await cubit.stream.firstWhere(
        (s) => s is! PerformanceRecorderIdle && s is! PerformanceRecorderArmed,
      );
      expect(cubit.state, isNot(isA<PerformanceRecorderIdle>()));

      await cubit.toggleArm(); // refused: not idle
      expect(engine.perfArmCalls, 1, reason: 'no second arm went through');
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
        await performance.arm();
        await pumpEventQueue();

        expect(performance.armedDirectory, isNull);
        expect(engine.perfArmCalls, 1, reason: 'only the initial arm');
        expect(cubit.state, isA<PerformanceRecorderRendering>());

        // Once the render completes the gate lifts and the pedal can arm a
        // fresh capture again.
        engine.renderProgress = PerformanceRenderProgress.empty;
        await waitForCompleted(cubit);
        await performance.arm();
        expect(performance.armedDirectory, isNotNull);
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
      'is a no-op while the boot salvage is still running — refused before '
      'the free-space probe, so no lowDiskBlocked emit can blind the '
      'recovering flag (#679 r2)',
      build: build,
      seed: () => const PerformanceRecorderIdle(recovering: true),
      act: (cubit) => cubit.toggleArm(),
      expect: () => <PerformanceRecorderState>[],
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
      'a fresh completion (not re-export) populates tracks from a real '
      "settled lane, proving _finishRender's own read-and-assign wiring — "
      'not just reExport()',
      () async {
        engine
          ..nextSnapshot = const EngineSnapshot(
            isRunning: true,
            sampleRate: 48000,
            bufferFrames: 128,
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
          )
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

  group('.als real tempo threading', () {
    /// Decompresses `project.als` (gzipped XML, `als_builder.dart`) and
    /// returns it as a string — the same decode `als_builder_test.dart`
    /// itself uses — so a test here can assert on the actual emitted
    /// `<Tempo>` value rather than trusting the wiring by inspection.
    String readAls(String dir) => utf8.decode(
      GZipCodec().decode(File('$dir/project.als').readAsBytesSync()),
    );

    test(
      'a real, non-default currentTempoBpm reaches the exported .als '
      "(end-to-end: this cubit's constructor dependency -> "
      '_writeDawExports -> DawManifestReader.read -> DawProject -> '
      'buildAls), not just the daw_export library level',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build(currentTempoBpm: () => 96.0);
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        await waitForCompleted(cubit);

        expect(readAls(dir), contains('<Manual Value="96.0"/>'));
      },
    );

    test(
      'an unset (0, the default) currentTempoBpm still exports — falling '
      "back to daw_export's own 120 BPM default, exactly like before this "
      'wiring existed',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        final cubit = build(); // default currentTempoBpm: () => 0
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));

        await cubit.toggleArm();
        await waitForCompleted(cubit);

        expect(readAls(dir), contains('<Manual Value="120.0"/>'));
      },
    );

    test(
      'reExport() also threads the real tempo (same _writeDawExports path '
      'as a fresh completion)',
      () async {
        engine.renderStatuses = const [
          PerformanceRenderTrackStatus(channel: 0, succeeded: true),
        ];
        var tempo = 0.0;
        final cubit = build(currentTempoBpm: () => tempo);
        addTearDown(cubit.close);
        final dir = await armWithLog(performance);
        await pumpEventQueue();
        clock = clock.add(const Duration(seconds: 5));
        await cubit.toggleArm();
        await waitForCompleted(cubit);
        expect(readAls(dir), contains('<Manual Value="120.0"/>'));

        // Tempo becomes known only after the fact (e.g. the user dialed it
        // in after this capture finished) — reExport() must pick up the
        // CURRENT value, proving it reads the callback fresh rather than a
        // value captured once at cubit construction.
        tempo = 140.0;
        await cubit.reExport();
        await pumpEventQueue();

        expect(readAls(dir), contains('<Manual Value="140.0"/>'));
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
      final cubit = await completedCubit();
      final path =
          ((cubit.state as PerformanceRecorderCompleted).result!
                  as PerformanceRecordDone)
              .path;
      Directory('$path/stems/wet').createSync(recursive: true);
      File('$path/stems/wet/track0.wav').writeAsBytesSync([0]);
      File('$path/performance.json').writeAsStringSync(
        jsonEncode({
          'slug': 'perf-x',
          'sample_rate': 48000,
          'capture_frames': 4800,
          'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
          'overrun_count': 0,
          'overrun_gaps': <Map<String, dynamic>>[],
          'layers': <Map<String, dynamic>>[],
          'finalized': true,
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
      await cubit.reExport();
      final before = cubit.state as PerformanceRecorderCompleted;
      expect(before.tracks, hasLength(1));

      await cubit.renameCompletedCapture('Renamed Take');

      final after = cubit.state as PerformanceRecorderCompleted;
      expect(after.tracks, before.tracks);
    });
  });

  group('reExport', () {
    test('is a no-op when not currently Completed', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.reExport();
      expect(cubit.state, isA<PerformanceRecorderIdle>());
    });

    test(
      'regenerates project.als/fx-chains.txt without touching audio files',
      () async {
        final cubit = await completedCubit();
        final path =
            ((cubit.state as PerformanceRecorderCompleted).result!
                    as PerformanceRecordDone)
                .path;
        final wavFile = File('$path/stems/wet/track0.wav')
          ..createSync(recursive: true)
          ..writeAsBytesSync([1, 2, 3, 4]);
        final beforeBytes = wavFile.readAsBytesSync();
        final beforeModified = wavFile.lastModifiedSync();
        // Written by the original finish-render pass — reExport should
        // still find it (proving it's re-invoking the same generation step,
        // not something new).
        expect(File('$path/project.als').existsSync(), isTrue);

        await cubit.reExport();

        expect(wavFile.readAsBytesSync(), beforeBytes);
        expect(wavFile.lastModifiedSync(), beforeModified);
        expect(File('$path/project.als').existsSync(), isTrue);
      },
    );

    test('emits isReExporting: true, then false, around the call', () async {
      final cubit = await completedCubit();
      // expectLater + emitsInOrder (not a manual listen/cancel) so this
      // waits for both emissions regardless of exactly when the second
      // one's microtask lands relative to `reExport()`'s own Future
      // resolving — a manual `listen`-then-`cancel` right after `await
      // cubit.reExport()` is a real race here, since _writeDawExports does
      // genuine (non-microtask) file I/O.
      final expectation = expectLater(
        cubit.stream,
        emitsInOrder([
          isA<PerformanceRecorderCompleted>().having(
            (s) => s.isReExporting,
            'isReExporting',
            isTrue,
          ),
          isA<PerformanceRecorderCompleted>().having(
            (s) => s.isReExporting,
            'isReExporting',
            isFalse,
          ),
        ]),
      );

      await cubit.reExport();
      await expectation;
    });

    test(
      're-reads the manifest fresh — a manifest that gained real track data '
      'since the original export is reflected in tracks',
      () async {
        final cubit = await completedCubit();
        final path =
            ((cubit.state as PerformanceRecorderCompleted).result!
                    as PerformanceRecordDone)
                .path;
        expect((cubit.state as PerformanceRecorderCompleted).tracks, isEmpty);

        Directory('$path/stems/wet').createSync(recursive: true);
        File('$path/stems/wet/track0.wav').writeAsBytesSync([0]);
        File('$path/performance.json').writeAsStringSync(
          jsonEncode({
            'slug': 'perf-x',
            'sample_rate': 48000,
            'capture_frames': 4800,
            'channel_layout': {
              'master_channels': 2,
              'captured_inputs': <int>[],
            },
            'overrun_count': 0,
            'overrun_gaps': <Map<String, dynamic>>[],
            'layers': <Map<String, dynamic>>[],
            'finalized': true,
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

        await cubit.reExport();

        final after = cubit.state as PerformanceRecorderCompleted;
        expect(after.tracks, hasLength(1));
      },
    );

    test(
      'a write failure sets reExportFailed and leaves tracks unchanged',
      () async {
        final cubit = await completedCubit();
        final before = cubit.state as PerformanceRecorderCompleted;
        final path = (before.result! as PerformanceRecordDone).path;
        // Replace the file reExport would overwrite with a directory of the
        // same name, so the write throws a real FileSystemException instead
        // of silently succeeding — the simplest reliable way to force an
        // I/O failure without mocking dart:io.
        File('$path/project.als').deleteSync();
        Directory('$path/project.als').createSync();

        await cubit.reExport();

        final after = cubit.state as PerformanceRecorderCompleted;
        expect(after.reExportFailed, isTrue);
        expect(after.isReExporting, isFalse);
        expect(after.tracks, before.tracks);
      },
    );
  });

  group('free-space floor (#640)', () {
    // A capture that armed onto a healthy disk ran 13.5 hours and filled a
    // 110GB partition, because the only check ran once at arm. These pin both
    // gates: refuse to start on a full volume, and stop a running capture
    // before it can get there.

    test(
      'refuses to arm below the floor, and does not create a bundle',
      () async {
        final cubit = build(
          freeSpaceBytes: (_) async =>
              PerformanceRecorderCubit.lowDiskThresholdBytes - 1,
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

    test(
      'defaults to the repository, which asks the engine — never a subprocess '
      '(#806)',
      () async {
        // The default used to run `df`, i.e. fork() the whole app, every
        // twenty armed ticks. On the appliance that is milliseconds of
        // mmap_lock held for write and an audible dropout in the monitor.
        // Built WITHOUT a freeSpaceBytes override, so this exercises the real
        // default path end to end.
        engine.freeBytes = PerformanceRecorderCubit.lowDiskThresholdBytes - 1;
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

        engine.freeBytes = PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
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

    test('arms normally when the volume has room', () async {
      final cubit = build(
        freeSpaceBytes: (_) async =>
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
        var free = PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
        final cubit = build(freeSpaceBytes: (_) async => free);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isFalse,
        );

        // Between the warning line and the stop floor: warn, keep recording.
        free = PerformanceRecorderCubit.lowDiskThresholdBytes - 1;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        expect(cubit.state, isA<PerformanceRecorderArmed>());
        expect(
          (cubit.state as PerformanceRecorderArmed).lowDiskWarning,
          isTrue,
        );
      },
    );

    test(
      'stops a running capture when free space crosses the stop floor',
      () async {
        var free = PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
        final cubit = build(freeSpaceBytes: (_) async => free);
        addTearDown(cubit.close);

        await cubit.toggleArm();
        await pumpEventQueue();
        expect(cubit.state, isA<PerformanceRecorderArmed>());

        free = PerformanceRecorderCubit.finalizeHeadroomBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        // It must leave armed under its own steam -- nothing else disarmed it.
        expect(cubit.state, isNot(isA<PerformanceRecorderArmed>()));
        expect(performance.armedDirectory, isNull);
      },
    );

    test('the stopped capture is reported as stopped-early for disk', () async {
      // The reason cannot come from the manifest here: perf_drain.c only
      // writes `stopped_early` when IT self-stops on a failed write, and this
      // stop happens BEFORE any write fails. Without the cubit carrying its
      // own reason the take would be reported as an ordinary success.
      var free = PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
      final cubit = build(freeSpaceBytes: (_) async => free);
      addTearDown(cubit.close);

      // A capture with real content, so finalize delivers a bundle instead of
      // discarding it as short-and-empty.
      await armWithLog(performance);
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());

      free = PerformanceRecorderCubit.finalizeHeadroomBytes ~/ 2;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();

      final state = cubit.state;
      expect(state, isA<PerformanceRecorderCompleted>());
      final result = (state as PerformanceRecorderCompleted).result;
      expect(result, isA<PerformanceRecordStoppedEarly>());
      expect(
        (result! as PerformanceRecordStoppedEarly).reason,
        PerformanceStopReason.diskFull,
      );
    });

    test('the floor scales with what has been captured, not a constant', () {
      // The floor has to cover a FULL SECOND COPY of the capture: finalize
      // writes every stream out as WAV and keeps the .pcm alongside. Measured
      // on the appliance at 96kHz that is 384 KB/s per stream across three
      // continuous streams, so a long take needs GBs, not a constant.
      const captured = 4 * 1024 * 1024;
      expect(
        PerformanceRecorderCubit.stopFloorFor(captured),
        greaterThan(captured),
        reason: 'the floor must leave room to duplicate what was captured',
      );
      expect(
        PerformanceRecorderCubit.stopFloorFor(captured * 100),
        greaterThan(PerformanceRecorderCubit.stopFloorFor(captured)),
        reason: 'a bigger capture must demand a bigger floor',
      );
      expect(
        PerformanceRecorderCubit.stopFloorFor(0),
        PerformanceRecorderCubit.finalizeHeadroomBytes,
      );
    });

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
        var free = PerformanceRecorderCubit.lowDiskThresholdBytes * 2;
        final cubit = build(freeSpaceBytes: (_) async => free);
        addTearDown(cubit.close);

        // First capture: stopped for disk, but too short/empty to keep.
        await cubit.toggleArm();
        await pumpEventQueue();
        free = PerformanceRecorderCubit.finalizeHeadroomBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue();

        // Second capture on a healthy volume, disarmed normally.
        free = PerformanceRecorderCubit.lowDiskThresholdBytes * 4;
        engine.renderStatuses = const [
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
      // Plenty of room -- this must NOT be the floor doing the work.
      final cubit = build(
        freeSpaceBytes: (_) async =>
            PerformanceRecorderCubit.lowDiskThresholdBytes * 100,
      );
      addTearDown(cubit.close);

      await armWithLog(performance);
      await pumpEventQueue();
      expect(cubit.state, isA<PerformanceRecorderArmed>());

      engine.perfStopped = true;
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
      'place — never deleted, no crash, still no state emitted',
      () async {
        final dir = Directory('${tempDir.path}/exports/perf-20260706-140000')
          ..createSync(recursive: true);
        File('${dir.path}/performance.json').writeAsStringSync('{not json');

        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        expect(dir.existsSync(), isTrue);
        expect(engine.lastRenderCaptureDir, isNull);
        expect(cubit.state, const PerformanceRecorderIdle());
      },
    );
  });
}
