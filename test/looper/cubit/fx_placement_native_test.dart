@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/cubit/fx_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno_engine/segno_engine.dart'
    show LaneSource, PumpedNativeEngine;
import 'package:settings_repository/settings_repository.dart';

class _Settings extends Mock implements SettingsRepository {}

class _Persistence extends Mock implements FxChainPersistence {}

/// The Effects page's Pre/Post switch on the real engine (#1741).
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run '
            'packages/segno_engine/tool/build_test_lib.sh'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;
  late _Settings settings;
  late _Persistence persistence;
  Timer? driver;

  setUpAll(() {
    registerFallbackValue(const FxAddress(stage: FxStage.track));
  });

  setUp(() {
    if (skip != null) return;
    engine = PumpedNativeEngine();
    ticks = StreamController<void>.broadcast(sync: true);
    repository = LooperRepository(engine: engine, ticker: ticks.stream);
    expect(
      repository.startEngine(
        const EngineConfig(
          inputChannels: 1,
          outputChannels: 2,
          maxLoopFrames: 192000,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    settings = _Settings();
    persistence = _Persistence();
    when(() => persistence.inputRestoreFailed).thenReturn(false);
    when(() => persistence.beginPending()).thenAnswer((_) => Object());
    when(() => persistence.finishPending(any())).thenReturn(null);
    when(() => persistence.retainConfirmed(any(), settings)).thenReturn(null);
    when(
      () => persistence.saveConfirmed(any(), settings),
    ).thenAnswer((_) async {});
  });
  tearDown(() async {
    if (skip != null) return;
    driver?.cancel();
    await repository.dispose();
    await ticks.close();
  });

  /// Pumps the callback in real time, so receipts land while a test awaits.
  void drive() => driver = Timer.periodic(
    const Duration(milliseconds: 1),
    (_) => engine.pump(frames: 0),
  );

  Future<void> settle() async {
    drive();
    expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
    expect(await repository.settleRecordStartSettings(), EngineResult.ok);
    expect(await repository.settleMixSettings(), EngineResult.ok);
    expect(await repository.settleFxRecipes(), EngineResult.ok);
    driver?.cancel();
    ticks.add(null);
  }

  /// The console's own block: 32 frames.
  void run(int frames, {double input = 0}) {
    for (var done = 0; done < frames; done += 32) {
      engine.pump(frames: 32, input: input);
    }
  }

  double peakOver(int frames) {
    final out = Float32List(2 * 32);
    var peak = 0.0;
    for (var done = 0; done < frames; done += 32) {
      engine.pump(frames: 32, output: out);
      for (final v in out) {
        if (v.abs() > peak) peak = v.abs();
      }
    }
    return peak;
  }

  double tailAfterStop([int playing = 24000]) {
    run(playing);
    expect(repository.stopTrack(), EngineResult.ok);
    run(4800);
    return peakOver(9600);
  }

  FxCubit cubitAt(FxDestination destination) {
    final cubit = FxCubit(
      repository: repository,
      settings: settings,
      persistence: persistence,
      initial: destination,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<FxEditResult> movePost(FxAddress address) async {
    final cubit = cubitAt(
      address.stage == FxStage.input
          ? FxDestination.liveInput(address.index)
          : FxDestination.recordedTrack(
              address.index,
              part: address.stage == FxStage.loop
                  ? FxTrackPart.part(address.lane!)
                  : null,
            ),
    );
    final chain = switch (address.stage) {
      FxStage.input => repository.monitorEffects(address.index),
      FxStage.track => repository.trackEffects(address.index),
      _ => repository.laneEffects(address.index, address.lane!),
    };
    final group = fxChainGroups(chain).single;
    drive();
    final result = await cubit.setGroupPlacement(
      address,
      fxGroupId(group),
      FxPlacement.post,
    );
    driver?.cancel();
    ticks.add(null);
    return result;
  }

  /// Plays in real time for [ms], so the cache worker can print.
  Future<void> playFor(int ms) async {
    for (var i = 0; i < ms ~/ 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      run(480);
      ticks.add(null);
    }
  }

  Future<void> recordThroughPreReverb({bool track = false}) async {
    final sub = repository.looperState.listen((_) {});
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    repository
      ..setMonitorEffects(
        input: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.reverb, placement: FxPlacement.pre),
        ],
      )
      ..setMonitorMute(input: 0, muted: true);
    if (track) {
      repository.setTrackEffects(
        channel: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.delay, placement: FxPlacement.pre),
        ],
      );
    }
    await settle();
    expect(repository.record(), EngineResult.ok);
    // A take that sounds all the way through: a 50 Hz square wave.
    for (var k = 0; k < 200; k++) {
      run(480, input: k.isEven ? .5 : -.5);
    }
    expect(repository.record(), EngineResult.ok);
    run(24000);
    ticks.add(null);
    await playFor(3000);
  }

  const input = FxAddress(stage: FxStage.input, index: 0);
  const part = FxAddress(stage: FxStage.loop, index: 0, lane: 0);
  const whole = FxAddress(stage: FxStage.track, index: 0);

  for (final order in [
    [input, whole],
    [whole, input],
    [input, whole, part],
  ]) {
    test('with a whole-track effect at Pre, the switch moves '
        '${order.map((a) => a.stage.name).join(' then ')} to Post, and the '
        'take rings out past Stop', () async {
      await recordThroughPreReverb(track: true);
      for (final address in order) {
        final result = await movePost(address);
        // ignore: avoid_print
        print('${address.stage.name}: ${result.status}');
      }
      await playFor(500);
      final lane = engine.snapshot().tracks[0].lanes[0];
      // ignore: avoid_print
      print('lane fx ${repository.laneEffects(0, 0).map((e) => e.placement)} '
          'track fx ${repository.trackEffects(0).map((e) => e.placement)} '
          'source ${lane.source}');
      final tail = tailAfterStop(4800);
      // ignore: avoid_print
      print('tail $tail');
      expect(tail, greaterThan(1e-3));
    }, skip: skip);
  }

  for (final order in [
    [input, part],
    [part, input],
  ]) {
    test('the switch moves ${order.map((a) => a.stage.name).join(' then ')} '
        'to Post, and the take rings out past Stop', () async {
      await recordThroughPreReverb();
      for (final address in order) {
        final result = await movePost(address);
        // ignore: avoid_print
        print('${address.stage.name}: ${result.status}');
      }
      final lane = engine.snapshot().tracks[0].lanes[0];
      // ignore: avoid_print
      print('lane fx ${repository.laneEffects(0, 0).map((e) => e.placement)} '
          'source ${lane.source} heard ${lane.heard}');
      expect(lane.source, LaneSource.clean);
      final tail = tailAfterStop(4800);
      // ignore: avoid_print
      print('tail $tail');
      expect(tail, greaterThan(1e-3));
    }, skip: skip);
  }
}
