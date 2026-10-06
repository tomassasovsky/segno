import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  group('RenderRequest', () {
    test('sourceMask sets one bit per selected track', () {
      expect(const RenderRequest(sources: {0, 2, 7}).sourceMask, 0x85);
      expect(const RenderRequest(sources: {}).sourceMask, 0);
    });

    test('defaults to the common cycle, Wrap, no Mix FX, memory', () {
      const request = RenderRequest(sources: {1});
      expect(request.lengthBars, isNull);
      expect(request.tails, RenderTails.wrap);
      expect(request.mixFx, isFalse);
      expect(request.target, RenderTarget.memory);
      expect(request.path, isNull);
      expect(request.maxFrames, isNull);
    });

    test('equality ignores source order and covers every field', () {
      expect(
        const RenderRequest(sources: {2, 1}),
        const RenderRequest(sources: {1, 2}),
      );
      expect(
        const RenderRequest(sources: {1}, tails: RenderTails.cut),
        isNot(const RenderRequest(sources: {1})),
      );
      expect(
        const RenderRequest(sources: {1}, lengthBars: 4).hashCode,
        const RenderRequest(sources: {1}, lengthBars: 4).hashCode,
      );
    });

    test('tails and targets carry the native codes', () {
      expect(RenderTails.wrap.index, 0);
      expect(RenderTails.cut.index, 1);
      expect(RenderTarget.memory.index, 0);
      expect(RenderTarget.file.index, 1);
    });
  });

  test('RenderJobState.fromCode maps le_render_state', () {
    expect(RenderJobState.fromCode(0), RenderJobState.none);
    expect(RenderJobState.fromCode(1), RenderJobState.freezing);
    expect(RenderJobState.fromCode(2), RenderJobState.staging);
    expect(RenderJobState.fromCode(3), RenderJobState.rendering);
    expect(RenderJobState.fromCode(4), RenderJobState.done);
    expect(RenderJobState.fromCode(5), RenderJobState.failed);
    expect(RenderJobState.fromCode(9), RenderJobState.none);
    expect(RenderJobState.done.isTerminal, isTrue);
    expect(RenderJobState.failed.isTerminal, isTrue);
    expect(RenderJobState.rendering.isTerminal, isFalse);
  });

  test('RenderMethod.fromCode maps le_render_method', () {
    expect(RenderMethod.fromCode(0), RenderMethod.commonCycle);
    expect(RenderMethod.fromCode(1), RenderMethod.chosenLength);
  });

  test('renderTracksOfMask names each set bit', () {
    expect(renderTracksOfMask(0), isEmpty);
    expect(renderTracksOfMask(0x85), {0, 2, 7});
  });

  test('RenderPlan and RenderJobStatus compare by value', () {
    const a = RenderPlan(
      frames: 48,
      method: RenderMethod.commonCycle,
      beatsMilli: 0,
      tempoSet: false,
      pluginTracks: {1},
    );
    const b = RenderPlan(
      frames: 48,
      method: RenderMethod.commonCycle,
      beatsMilli: 0,
      tempoSet: false,
      pluginTracks: {1},
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(
        const RenderPlan(
          frames: 48,
          method: RenderMethod.commonCycle,
          beatsMilli: 0,
          tempoSet: false,
          pluginTracks: {1},
          onceCutTracks: {1},
        ),
      ),
    );
    expect(
      const RenderJobStatus(state: RenderJobState.failed, permille: 10),
      isNot(
        const RenderJobStatus(
          state: RenderJobState.failed,
          permille: 10,
          failure: EngineResult.tracksChanged,
        ),
      ),
    );
  });

  test('the mock engine has no audio to render and says so', () {
    final engine = MockAudioEngine();
    const request = RenderRequest(sources: {0});
    expect(engine.measureRender(request).result, EngineResult.unsupported);
    expect(engine.measureRender(request).plan, isNull);
    expect(engine.beginRender(request).result, EngineResult.unsupported);
    expect(engine.pollRender(1), isNull);
    expect(engine.copyRender(1, maxFrames: 8), isNull);
    expect(engine.cancelRender(1), EngineResult.invalid);
  });
}
