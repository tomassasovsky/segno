import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show FxOwner, MockAudioEngine;

/// Guitar Rack / Rhythm Atmos, read from the catalogue's own file: its
/// Master Vol is +10.6 dB, past the old x2 entry-level ceiling.
FxPreset _rhythmAtmos() => FxPreset.tryParse(
  'Guitar Rack',
  File(
    '../fx_catalogue/assets/presets/Guitar Rack/Rhythm Atmos.fxpreset',
  ).readAsStringSync(),
)!;

void main() {
  late MockAudioEngine engine;
  late LooperRepository repo;

  setUp(() {
    engine = MockAudioEngine();
    repo = LooperRepository(engine: engine)..startEngine(const EngineConfig());
    addTearDown(repo.dispose);
  });

  List<TrackEffect> asRack(List<TrackEffect> entries) => [
    for (final fx in entries)
      switch (fx) {
        BuiltInEffect() => fx.copyWith(
          rack: const FxRack(id: 'rack', name: 'Rhythm Atmos'),
        ),
        PluginEffect() => fx,
      },
  ];

  test('a rack level of 3.388 (+10.6 dB) reaches the engine', () {
    final entries = asRack([
      BuiltInEffect(type: TrackEffectType.delay),
      BuiltInEffect(
        type: TrackEffectType.reverb,
        channels: const FxChannels(level: 3.388),
      ),
    ]);

    expect(repo.setTrackEffects(channel: 0, effects: entries), EngineResult.ok);

    expect(
      fxChainGroups(repo.trackEffects(0)).single.channels.level,
      closeTo(3.388, 1e-9),
    );
    expect(
      engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots.last.channels.level,
      closeTo(3.388, 1e-6),
    );
  });

  test('adding Rhythm Atmos plays it at +10.6 dB', () {
    final preset = _rhythmAtmos();
    final entries = asRack(fxRackEntries(preset));

    expect(repo.setTrackEffects(channel: 0, effects: entries), EngineResult.ok);

    final level = fxChainGroups(repo.trackEffects(0)).single.channels.level;
    expect(fxRackLevelDb(level), 10.6);
    expect(
      engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots.last.channels.level,
      closeTo(level, 1e-6),
    );
    expect(engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots, hasLength(7));
  });
}
