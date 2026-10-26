import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show FxOwner, FxRackEdge, FxRackPath, MockAudioEngine, fxInstanceId;

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

  test("the recipe marks each rack's first and last entry, so the engine "
      'applies the rack level whatever its last pedal is', () {
    final rack = asRack(fxRackEntries(_rhythmAtmos()));
    final effects = [
      BuiltInEffect(type: TrackEffectType.delay, slotId: 'solo'),
      ...rack,
      BuiltInEffect(
        type: TrackEffectType.reverb,
        slotId: 'one',
        rack: const FxRack(id: 'one', name: 'One'),
      ),
    ];

    expect(repo.setTrackEffects(channel: 0, effects: effects), EngineResult.ok);

    final slots = engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots;
    expect(slots.map((s) => s.rack), [
      FxRackEdge.none, // a standalone entry belongs to no rack
      FxRackEdge.first,
      for (var i = 1; i < rack.length - 1; i++) FxRackEdge.none,
      FxRackEdge.last,
      FxRackEdge.only,
    ]);
    // The rack level rides the last entry, which the engine now applies after
    // that entry even though its module is one the engine cannot build.
    expect(slots[rack.length].channels.level, closeTo(3.388, 1e-3));
  });

  test('each recipe slot carries its entry identity, so a publish that '
      'keeps an entry in place keeps its state', () {
    final effects = [
      BuiltInEffect(type: TrackEffectType.delay, slotId: 'a'),
      BuiltInEffect(type: TrackEffectType.reverb, slotId: 'b'),
    ];
    expect(repo.setTrackEffects(channel: 0, effects: effects), EngineResult.ok);
    final first = engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots;
    expect(first.map((s) => s.instance), [
      fxInstanceId('a'),
      fxInstanceId('b'),
    ]);

    // A setting moves: the same identities go out again.
    final edited = [
      (repo.trackEffects(0)[0] as BuiltInEffect).copyWith(
        params: const [0.9, 0.35, 0.35],
      ),
      repo.trackEffects(0)[1],
    ];
    expect(repo.setTrackEffects(channel: 0, effects: edited), EngineResult.ok);
    expect(
      engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots.map((s) => s.instance),
      first.map((s) => s.instance),
    );
  });

  test("a Dub Rack's recipe puts its pedals on the rack's two paths", () {
    final preset = FxPreset.tryParse(
      'Dub Rack',
      File(
        '../fx_catalogue/assets/presets/Dub Rack/Dub FX 1.fxpreset',
      ).readAsStringSync(),
    )!;
    final entries = asRack(fxRackEntries(preset));
    expect(repo.setTrackEffects(channel: 0, effects: entries), EngineResult.ok);
    final slots = engine.fxRecipes[(FxOwner.track, 0, 0)]!.slots;
    expect(
      {
        for (final (i, fx) in repo.trackEffects(0).indexed)
          fx.module: slots[i].path,
      },
      {
        'Doubler': FxRackPath.dub,
        'Dub delay': FxRackPath.dub,
        'Dub reverb': FxRackPath.dub,
        'Ambience': FxRackPath.amb,
        'Compressor': FxRackPath.none,
        'Parametric EQ': FxRackPath.none,
      },
    );
  });
}
