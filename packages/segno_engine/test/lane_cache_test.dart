import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('LaneCacheState.fromNative', () {
    test('maps every documented le_cache_state code', () {
      // The codes are the native enum's, spelled out here rather than derived,
      // so a renumbering on the C side fails this test instead of silently
      // relabelling every glyph (segno_engine_api.h, le_cache_state).
      expect(LaneCacheState.fromNative(0), LaneCacheState.live);
      expect(LaneCacheState.fromNative(1), LaneCacheState.rendering);
      expect(LaneCacheState.fromNative(2), LaneCacheState.cached);
      expect(LaneCacheState.fromNative(3), LaneCacheState.failedRetrying);
      expect(LaneCacheState.fromNative(4), LaneCacheState.gaveUp);
    });

    test('falls back to live for an unknown code', () {
      // Claiming "cached" for a state this build doesn't recognize would be
      // the one wrong answer — live is the honest default, and it matches the
      // cache's own "when in doubt, play live" contract.
      expect(LaneCacheState.fromNative(99), LaneCacheState.live);
      expect(LaneCacheState.fromNative(-1), LaneCacheState.live);
    });
  });

  group('MockAudioEngine.laneCacheStates', () {
    test('reports live for every lane nothing seeded', () {
      final engine = MockAudioEngine();
      final states = engine.laneCacheStates();
      expect(states, isNotEmpty);
      expect(states.values.toSet(), {LaneCacheState.live});
    });

    test('reports a seeded state for exactly its own lane', () {
      final engine = MockAudioEngine()
        ..seededLaneCacheStates[(1, 0)] = LaneCacheState.cached;

      final states = engine.laneCacheStates();
      expect(states[(1, 0)], LaneCacheState.cached);
      expect(states[(1, 1)], LaneCacheState.live);
      expect(states[(0, 0)], LaneCacheState.live);
    });
  });
}
