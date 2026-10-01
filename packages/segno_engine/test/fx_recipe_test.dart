import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  test('an armed recipe owns its parameter and slot collections', () {
    final params = [0.0, 0.5];
    final slots = [
      FxRecipeSlot(type: TrackEffectType.drive, params: params),
    ];
    final recipe = FxRecipe(slots: slots, preCount: 1);
    final recipes = {0: recipe};
    final image = RecordImage(revision: 7, lanes: const {}, laneFx: recipes);
    params[1] = 1;
    slots.clear();
    recipes.clear();
    expect(image.laneFx[0]!.slots.single.params, [0, 0.5]);
    expect(image.laneFx[0]!.preCount, 1);
    expect(image.isValid, isTrue);
    expect(image.laneFx.clear, throwsUnsupportedError);
  });

  test(
    'invalid channel gain refuses a replacement and retains its revision',
    () {
      final engine = MockAudioEngine()..start(const EngineConfig());
      addTearDown(engine.dispose);
      final old = FxRecipe(
        slots: [
          FxRecipeSlot(type: TrackEffectType.drive, params: [0, 0.5]),
        ],
      );
      expect(
        engine.setFxRecipe(owner: FxOwner.track, recipe: old, revision: 3),
        EngineResult.ok,
      );
      for (final level in [double.nan, double.infinity, -0.1, 2.1]) {
        final bad = FxRecipe(
          slots: [
            FxRecipeSlot(
              type: TrackEffectType.drive,
              channels: FxChannels(level: level),
            ),
          ],
        );
        expect(
          engine.setFxRecipe(owner: FxOwner.track, recipe: bad, revision: 4),
          EngineResult.invalid,
        );
        expect(engine.fxRecipeRevision(owner: FxOwner.track), 3);
        expect(engine.fxRecipes[(FxOwner.track, 0, 0)], same(old));
      }
    },
  );

  test('track fader changes preserve independently stored part gain', () {
    final engine = MockAudioEngine();
    addTearDown(engine.dispose);
    engine.start(engine.defaultConfig);
    expect(
      engine.setMix(
        EngineMixSettings(
          revision: 1,
          lanes: const {(0, 0): (gain: 0.25, pan: 0.3)},
          trackLevels: const {0: 0.75},
        ),
      ),
      EngineResult.ok,
    );
    expect(engine.snapshot().tracks[0].volume, 0.75);
    expect(engine.snapshot().tracks[0].lanes[0].volume, 0.25);
    expect(
      engine.setMix(
        EngineMixSettings(revision: 2, trackLevels: const {0: 0.5}),
      ),
      EngineResult.ok,
    );
    expect(engine.snapshot().tracks[0].volume, 0.5);
    expect(engine.snapshot().tracks[0].lanes[0].volume, 0.25);
  });
}
