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
      for (final level in [double.nan, double.infinity, -0.1, 4.1]) {
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
      // A rack level up to +12 dB (gain about 3.98) is admitted.
      for (final level in [2.1, 3.388, kFxLevelMax]) {
        expect(
          engine.setFxRecipe(
            owner: FxOwner.track,
            recipe: FxRecipe(
              slots: [
                FxRecipeSlot(
                  type: TrackEffectType.drive,
                  channels: FxChannels(level: level),
                ),
              ],
            ),
            revision: 5,
          ),
          EngineResult.ok,
          reason: '$level',
        );
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

  test('fxInstanceId is a stable non-zero 64-bit id, 0 for no id', () {
    expect(fxInstanceId(null), 0);
    expect(fxInstanceId('slot-1'), fxInstanceId('slot-1'));
    expect(fxInstanceId('slot-1'), isNot(fxInstanceId('slot-2')));
    for (final id in ['', 'a', 'slot-1', 'rack/very-long-id-0123456789']) {
      expect(fxInstanceId(id), isNot(0));
    }
    // 64-bit FNV-1a of "a".
    // ignore: avoid_js_rounded_ints
    expect(fxInstanceId('a'), 0xaf63dc4c8601ec8c);
  });
}
