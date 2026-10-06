import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show RenderJobStatus, RenderMethod, RenderPlan, RenderRequest;

import 'helpers/fake_audio_engine.dart';

void main() {
  group('Shared render recipe', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;

    setUp(() {
      engine = FakeAudioEngine();
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        sampleRate: 48000,
        tsNum: 3,
      );
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
        renderPollInterval: const Duration(milliseconds: 1),
      );
    });
    tearDown(() => repository.dispose());

    const render = SelectedRender(sources: {0, 2});

    test('measures through a memory request and reads the plan in bars', () {
      engine.measureRenderAnswer = (
        result: EngineResult.ok,
        plan: const RenderPlan(
          frames: 144000,
          method: RenderMethod.chosenLength,
          beatsMilli: 6000,
          tempoSet: true,
          pluginTracks: {2},
          fadedTracks: {0},
        ),
      );
      final measured = repository.measureRender(
        render.copyWith(lengthBars: 2, tails: RenderTails.cut, mixFx: true),
        maxFrames: 200000,
      );
      expect(measured.result, EngineResult.ok);
      expect(
        measured.plan,
        const SelectedRenderPlan(
          frames: 144000,
          seconds: 3,
          commonCycle: false,
          beats: 6,
          bars: 2,
          pluginTracks: {2},
          fadedTracks: {0},
        ),
      );
      expect(
        engine.renderRequests.single,
        const RenderRequest(
          sources: {0, 2},
          lengthBars: 2,
          tails: RenderTails.cut,
          mixFx: true,
          maxFrames: 200000,
        ),
      );
    });

    test('reads a plan without a tempo in seconds only', () {
      final measured = repository.measureRender(render);
      expect(measured.plan!.tempoSet, isFalse);
      expect(measured.plan!.bars, isNull);
      expect(measured.plan!.seconds, 48 / 48000);
      expect(measured.plan!.commonCycle, isTrue);
    });

    test('passes refusals through without a plan', () {
      engine.measureRenderAnswer = (
        result: EngineResult.noCommonCycle,
        plan: null,
      );
      final measured = repository.measureRender(render);
      expect(measured.result, EngineResult.noCommonCycle);
      expect(measured.plan, isNull);
    });

    test('is not ready while a Session owns the engine audio', () {
      repository.blockStartForSessionBoot();
      expect(repository.measureRender(render).result, EngineResult.notReady);
      final begun = repository.renderToFile(render, '/tmp/x.wav');
      expect(begun.result, EngineResult.notReady);
      expect(begun.job, isNull);
      expect(engine.renderRequests, isEmpty);
    });

    test('a file render reports progress, publishes, then releases', () async {
      engine.renderStatuses = const [
        RenderJobStatus(state: RenderJobState.freezing, permille: 0),
        RenderJobStatus(state: RenderJobState.rendering, permille: 400),
        RenderJobStatus(state: RenderJobState.done, permille: 1000),
      ];
      final begun = repository.renderToFile(render, '/tmp/mix.wav');
      expect(begun.result, EngineResult.ok);
      final job = begun.job!;
      final seen = <RenderProgress>[];
      job.progress.listen(seen.add);
      expect(
        await job.outcome,
        const RenderOutcome(result: EngineResult.ok, path: '/tmp/mix.wav'),
      );
      expect(seen.map((p) => p.permille), [0, 400, 1000]);
      expect(engine.renderRequests.single.target, RenderTarget.file);
      expect(engine.renderRequests.single.path, '/tmp/mix.wav');
      expect(engine.cancelledRenders, [1]); // released once published
    });

    test('a memory render keeps its result until released', () async {
      engine
        ..renderSamples = Float32List.fromList([1, 2, 3, 4])
        ..beginRenderAnswer = (result: EngineResult.ok, job: 7);
      final job = repository.renderToMemory(render, maxFrames: 1440000).job!;
      expect(await job.outcome, const RenderOutcome(result: EngineResult.ok));
      expect(engine.renderRequests.single.maxFrames, 1440000);
      expect(engine.cancelledRenders, isEmpty);
      expect(job.copySamples(maxFrames: 2), [1, 2, 3, 4]);
      job.release();
      expect(engine.cancelledRenders, [7]);
    });

    test('a failed render carries its reason', () async {
      engine.renderStatuses = const [
        RenderJobStatus(
          state: RenderJobState.failed,
          permille: 120,
          failure: EngineResult.tracksChanged,
        ),
      ];
      final job = repository.renderToFile(render, '/tmp/a.wav').job!;
      expect(
        await job.outcome,
        const RenderOutcome(result: EngineResult.tracksChanged),
      );
    });

    test('a job the engine no longer holds ends as invalid', () async {
      engine.renderStatuses = const [];
      final job = repository.renderToMemory(render, maxFrames: 10).job!;
      expect(
        await job.outcome,
        const RenderOutcome(result: EngineResult.invalid),
      );
    });

    test('cancel releases the job and ends it as cancelled', () async {
      engine.renderStatuses = const [
        RenderJobStatus(state: RenderJobState.rendering, permille: 10),
      ];
      final job = repository.renderToFile(render, '/tmp/b.wav').job!..cancel();
      expect(
        await job.outcome,
        const RenderOutcome(result: EngineResult.ok, cancelled: true),
      );
      expect(engine.cancelledRenders, [1]);
      job.cancel(); // once only
      expect(engine.cancelledRenders, [1]);
    });

    test('begin refusals return no job', () {
      engine.beginRenderAnswer = (result: EngineResult.alreadyRunning, job: 0);
      final begun = repository.renderToMemory(render, maxFrames: 10);
      expect(begun.result, EngineResult.alreadyRunning);
      expect(begun.job, isNull);
    });

    test('dispose cancels a running render', () async {
      engine.renderStatuses = const [
        RenderJobStatus(state: RenderJobState.rendering, permille: 10),
      ];
      final job = repository.renderToFile(render, '/tmp/c.wav').job!;
      await repository.dispose();
      expect(engine.cancelledRenders, [1]);
      expect((await job.outcome).cancelled, isTrue);
    });
  });

  test('SelectedRender defaults and copyWith', () {
    const render = SelectedRender(sources: {1});
    expect(render.tails, RenderTails.wrap);
    expect(render.mixFx, isFalse);
    expect(render.lengthBars, isNull);
    final chosen = render.copyWith(lengthBars: 4);
    expect(chosen.lengthBars, 4);
    expect(chosen.copyWith(clearLength: true).lengthBars, isNull);
    expect(
      const SelectedRender(sources: {1, 2}),
      const SelectedRender(sources: {2, 1}),
    );
  });
}
