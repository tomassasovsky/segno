import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

const _reverb = FxRack(id: 'rack-a', name: 'Reverb + Delay');
const _chords = FxRack(id: 'rack-b', name: 'Soft Chords');

BuiltInEffect _module(String slotId, FxRack rack, {bool enabled = true}) =>
    BuiltInEffect(
      type: TrackEffectType.drive,
      slotId: slotId,
      rack: rack,
      enabled: enabled,
    );

/// Input 1's chain from #1711: two racks, the first with one pedal off.
List<TrackEffect> _twoRacks() => [
  _module('a1', _reverb),
  _module('a2', _reverb, enabled: false),
  _module('b1', _chords),
];

const _track = FxAddress(stage: FxStage.track);

/// Refuses the per-entry switch of entry [refuseIndex] on a track chain.
class _RefusingEngine extends FakeAudioEngine {
  int? refuseIndex;

  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) => index == refuseIndex
      ? EngineResult.invalid
      : super.setTrackFxEnabled(
          channel: channel,
          index: index,
          enabled: enabled,
        );
}

const _input = FxAddress(stage: FxStage.input);

void main() {
  late FakeAudioEngine audio;
  late LooperRepository repo;
  setUp(() {
    audio = FakeAudioEngine();
    repo = LooperRepository(engine: audio)..startEngine(const EngineConfig());
  });
  tearDown(() => repo.dispose());

  group('setRackEnabled', () {
    test('off bypasses the rack and keeps each pedal own switch', () {
      repo.setTrackEffects(channel: 0, effects: _twoRacks());
      audio.trackFxEnabled.clear();

      expect(
        repo.setRackEnabled(address: _track, rackId: 'rack-a', enabled: false),
        EngineResult.ok,
      );

      final chain = repo.trackEffects(0);
      expect(chain.map((fx) => fx.enabled), [true, false, true]);
      expect(chain.map((fx) => fx.rack?.bypassed), [true, true, false]);
      expect(chain.map((fx) => fx.effectiveEnabled), [false, false, true]);
      // Only the entry whose sound changed is written, and the engine is
      // told the effective state.
      expect(audio.trackFxEnabled, {(0, 0): false});
      expect(repo.state.tracks[0].effects, chain);
    });

    test('on restores every pedal as it was', () {
      repo
        ..setTrackEffects(channel: 0, effects: _twoRacks())
        ..setRackEnabled(address: _track, rackId: 'rack-a', enabled: false);
      audio.trackFxEnabled.clear();

      repo.setRackEnabled(address: _track, rackId: 'rack-a', enabled: true);

      final chain = repo.trackEffects(0);
      expect(chain.map((fx) => fx.enabled), [true, false, true]);
      expect(chain.map((fx) => fx.rack?.bypassed), [false, false, false]);
      expect(audio.trackFxEnabled, {(0, 0): true});
    });

    test('a pedal switched on inside a bypassed rack stays silent', () {
      repo
        ..setTrackEffects(channel: 0, effects: _twoRacks())
        ..setRackEnabled(address: _track, rackId: 'rack-a', enabled: false)
        ..setTrackEffectEnabled(channel: 0, index: 1, enabled: true);

      expect(repo.trackEffects(0)[1].enabled, isTrue);
      expect(audio.trackFxEnabled[(0, 1)], isFalse);
      // ...and sounds once the rack is back on.
      repo.setRackEnabled(address: _track, rackId: 'rack-a', enabled: true);
      expect(audio.trackFxEnabled[(0, 1)], isTrue);
    });

    test('a chain write carries the effective state in its recipe', () {
      final chain = [
        _module('a1', _reverb.copyWith(bypassed: true)),
        _module('b1', _chords),
      ];
      repo.setMonitorEffects(input: 0, effects: chain);

      final recipe = audio.recipes[(engine.FxOwner.monitor, 0, 0)]!;
      expect(recipe.slots.map((slot) => slot.enabled), [false, true]);
      expect(repo.monitorEffects(0).first.enabled, isTrue);
    });

    test('works on a live input and announces the change', () async {
      repo.setMonitorEffects(input: 0, effects: _twoRacks());
      final announced = <int>[];
      final sub = repo.monitorChanges.listen(announced.add);
      addTearDown(sub.cancel);

      repo.setRackEnabled(address: _input, rackId: 'rack-b', enabled: false);
      await Future<void>.delayed(Duration.zero);

      expect(audio.monitorFxEnabled[(0, 2)], isFalse);
      expect(repo.monitorEffects(0)[2].rack?.bypassed, isTrue);
      expect(announced, [0]);
    });

    test('refuses a rack the chain does not hold', () {
      repo.setTrackEffects(channel: 0, effects: _twoRacks());
      final before = repo.trackEffects(0);

      expect(
        repo.setRackEnabled(address: _track, rackId: 'gone', enabled: false),
        EngineResult.invalid,
      );
      expect(
        repo.setRackEnabled(
          address: const FxAddress(stage: FxStage.loop),
          rackId: 'rack-a',
          enabled: false,
        ),
        EngineResult.invalid,
      );
      expect(repo.trackEffects(0), before);
    });

    test('a refused engine write leaves the rack as it was', () {
      final refusing = _RefusingEngine();
      final rig = LooperRepository(engine: refusing)
        ..startEngine(const EngineConfig());
      addTearDown(rig.dispose);
      rig.setTrackEffects(
        channel: 0,
        effects: [_module('a1', _reverb), _module('a2', _reverb)],
      );
      final before = rig.trackEffects(0);
      refusing.refuseIndex = 1;

      expect(
        rig.setRackEnabled(address: _track, rackId: 'rack-a', enabled: false),
        EngineResult.invalid,
      );
      expect(rig.trackEffects(0), before);
      // The first module, already switched, was put back.
      expect(refusing.trackFxEnabled[(0, 0)], isTrue);
    });
  });

  test('the rack switch is saved with the chain and survives a reload', () {
    final chain = [
      _module('a1', _reverb.copyWith(bypassed: true), enabled: false),
      _module('b1', _chords),
    ];

    final decoded = decodeTrackEffects(encodeTrackEffects(chain));

    expect(decoded, chain);
    expect(decoded.first.rack?.bypassed, isTrue);
    expect(decoded.first.enabled, isFalse);
  });

  test('the arm snapshot carries what was heard: a bypassed rack is off', () {
    final chain = [
      _module('a1', _reverb.copyWith(bypassed: true)),
      _module('b1', _chords),
    ];

    final snapshot = trackEffectsToEngine(chain);

    expect(snapshot.map((fx) => (fx as engine.BuiltInEffect).enabled), [
      false,
      true,
    ]);
  });

  test('the fingerprint folds what the engine holds, not the own bit', () {
    final on = [_module('a1', _reverb)];
    final bypassed = [_module('a1', _reverb.copyWith(bypassed: true))];
    final off = [_module('a1', _reverb, enabled: false)];

    expect(fxChainFingerprint(bypassed), fxChainFingerprint(off));
    expect(fxChainFingerprint(bypassed), isNot(fxChainFingerprint(on)));
  });
}
