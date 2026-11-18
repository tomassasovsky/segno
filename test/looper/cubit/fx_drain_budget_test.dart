import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/cubit/fx_cubit.dart';
import 'package:segno_engine/segno_engine.dart'
    show FxDraining, FxOwner, MockAudioEngine;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// #1733: a reverb switched off keeps running until its tail drains, so the
/// room it frees comes back only once the engine says the tail is quiet.
void main() {
  const track = FxAddress(stage: FxStage.track);
  const other = FxAddress(stage: FxStage.track, index: 1);

  late MockAudioEngine engine;
  late StreamController<void> ticks;
  late LooperRepository looper;
  late FxChainPersistence persistence;
  late FxCubit fx;
  late StreamSubscription<LooperState> polling;

  setUp(() async {
    engine = MockAudioEngine();
    ticks = StreamController<void>.broadcast(sync: true);
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig(sampleRate: 96000));
    // The repository polls the engine while someone listens.
    polling = looper.looperState.listen((_) {});
    await pumpEventQueue();
    persistence = FxChainPersistence(looper: looper);
    fx = FxCubit(
      repository: looper,
      settings: SettingsRepository(store: FakeKeyValueStore()),
      persistence: persistence,
    );
  });

  tearDown(() async {
    unawaited(polling.cancel());
    await fx.close();
    await persistence.close();
    await looper.dispose();
    await ticks.close();
  });

  test('a reverb switched off at the limit keeps its room until its tail '
      'drains: another effect switched on is refused until then', () {
    final reverb = fxEntryCostNs(BuiltInEffect(type: TrackEffectType.roomVerb));
    final drive = fxEntryCostNs(BuiltInEffect(type: TrackEffectType.overdrive));
    // Track 1: the reverb, on, and Overdrives on until less than one more
    // Overdrive fits. Track 2: one more Overdrive, off.
    looper.setTrackEffects(
      channel: 0,
      effects: [
        BuiltInEffect(type: TrackEffectType.roomVerb, slotId: 'reverb'),
      ],
    );
    final count = looper.fxRoomNs ~/ drive;
    looper
      ..setTrackEffects(
        channel: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.roomVerb, slotId: 'reverb'),
          for (var i = 0; i < count; i++)
            BuiltInEffect(type: TrackEffectType.overdrive, slotId: 'd$i'),
        ],
      )
      ..setTrackEffects(
        channel: 1,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.overdrive,
            slotId: 'spare',
            enabled: false,
          ),
        ],
      );
    ticks.add(null);
    expect(looper.fxRoomNs, lessThan(drive));
    // The reverb's room makes the Overdrive fit once it is gone.
    expect(looper.fxRoomNs + reverb, greaterThanOrEqualTo(drive));

    expect(
      fx.setEffectEnabled(track, 'reverb', enabled: false).status,
      FxEditStatus.applied,
    );
    // Before the engine has said anything, the reverb still counts.
    expect(
      fx.setEffectEnabled(other, 'spare', enabled: true).status,
      FxEditStatus.overBudget,
    );
    // The engine reports its tail draining: still refused.
    engine.fxDraining = FxDraining(const {(FxOwner.track, 0, 0): 1});
    ticks
      ..add(null)
      ..add(null);
    expect(
      fx.setEffectEnabled(other, 'spare', enabled: true).status,
      FxEditStatus.overBudget,
    );
    expect(looper.trackEffects(1).single.enabled, isFalse);

    // Drained: the room comes back.
    engine.fxDraining = FxDraining.none;
    ticks
      ..add(null)
      ..add(null);
    expect(
      fx.setEffectEnabled(other, 'spare', enabled: true).status,
      FxEditStatus.applied,
    );
    expect(looper.fxRoomNs, greaterThanOrEqualTo(0));
  });

  test('an effect that does not drain frees its room at once', () {
    final drive = fxEntryCostNs(BuiltInEffect(type: TrackEffectType.overdrive));
    looper.setTrackEffects(
      channel: 0,
      effects: [
        for (var i = 0; i < looper.fxRoomNs ~/ drive; i++)
          BuiltInEffect(type: TrackEffectType.overdrive, slotId: 'd$i'),
      ],
    );
    looper.setTrackEffects(
      channel: 1,
      effects: [
        BuiltInEffect(
          type: TrackEffectType.overdrive,
          slotId: 'spare',
          enabled: false,
        ),
      ],
    );
    ticks.add(null);
    expect(
      fx.setEffectEnabled(other, 'spare', enabled: true).status,
      FxEditStatus.overBudget,
    );
    expect(
      fx.setEffectEnabled(track, 'd0', enabled: false).status,
      FxEditStatus.applied,
    );
    expect(
      fx.setEffectEnabled(other, 'spare', enabled: true).status,
      FxEditStatus.applied,
    );
  });
}
