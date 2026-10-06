import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

const _config = EngineConfig(sampleRate: 48000, outputChannels: 2);

void main() {
  group('enum codes', () {
    test('map the native codes, unknowns to the safe default', () {
      expect(BackingTransport.fromCode(1), BackingTransport.playing);
      expect(BackingTransport.fromCode(2), BackingTransport.paused);
      expect(BackingTransport.fromCode(7), BackingTransport.stopped);
      expect(BackingEnd.fromCode(2), BackingEnd.next);
      expect(BackingEnd.fromCode(-1), BackingEnd.stop);
      expect(BackingEndEvent.fromCode(3), BackingEndEvent.advanced);
      expect(BackingEndEvent.fromCode(4), BackingEndEvent.nextMissing);
      expect(BackingEndEvent.fromCode(9), BackingEndEvent.none);
    });

    test('ops and modes keep the native order', () {
      expect(BackingTransportOp.values.map((v) => v.index), [0, 1, 2]);
      expect(BackingTransportOp.stop.index, 2);
      expect(BackingEnd.repeat.index, 1);
    });
  });

  group('BackingState', () {
    test('is a value', () {
      expect(const BackingState(item: 3), const BackingState(item: 3));
      expect(
        const BackingState(item: 3).hashCode,
        const BackingState(item: 3).hashCode,
      );
      expect(const BackingState(item: 3), isNot(const BackingState()));
      expect(const BackingState().loaded, isFalse);
      expect(const BackingState(item: 0).loaded, isTrue);
    });
  });

  group('MockAudioDecoder', () {
    late MockAudioDecoder decoder;
    setUp(
      () => decoder = MockAudioDecoder(
        files: {
          'a.wav': const MockAudioFile(sourceRate: 44100, sourceFrames: 44100),
          'long.mp3': const MockAudioFile(
            sourceRate: 8000,
            sourceFrames: 901 * 8000,
          ),
          'bad.wav': const MockAudioFile.refused(EngineResult.invalid),
        },
      ),
    );

    test('converts by the native length rule and reports the file', () async {
      final audio = await decoder.decode('a.wav', sampleRate: 48000);
      expect(audio.frames, 48000);
      expect(audio.bytes, 48000 * 8);
      expect(
        audio.info,
        const AudioFileInfo(
          sourceRate: 44100,
          sourceChannels: 2,
          sourceFrames: 44100,
        ),
      );
      expect(audio.info.seconds, 1);
      expect(audio.copySamples().sublist(0, 4), [
        1 / 65536,
        -1 / 65536,
        2 / 65536,
        -2 / 65536,
      ]);
      expect(audio.peaks(2), hasLength(2));
      audio.dispose();
      expect(decoder.live, 0);
    });

    test('a bounded read truncates and says so', () async {
      final audio = await decoder.decode(
        'a.wav',
        sampleRate: 48000,
        maxFrames: 100,
      );
      expect(audio.frames, 100);
      expect(audio.info.truncated, isTrue);
      audio.dispose();
    });

    test('refusals carry their reason', () async {
      await expectLater(
        decoder.decode('missing.wav', sampleRate: 48000),
        throwsA(
          isA<EngineException>().having(
            (e) => e.result,
            'result',
            EngineResult.invalid,
          ),
        ),
      );
      await expectLater(
        decoder.decode('long.mp3', sampleRate: 48000),
        throwsA(
          isA<EngineException>().having(
            (e) => e.result,
            'result',
            EngineResult.tooLong,
          ),
        ),
      );
      await expectLater(
        decoder.probe('bad.wav'),
        throwsA(isA<EngineException>()),
      );
      expect(decoder.decoded, 0);
      expect(decoder.requests, ['missing.wav', 'long.mp3', 'bad.wav']);
    });

    test('a bounded read of a long file is allowed', () async {
      final audio = await decoder.decode(
        'long.mp3',
        sampleRate: 48000,
        maxFrames: 48,
      );
      expect(audio.frames, 48);
      audio.dispose();
    });

    test('probe keeps nothing', () async {
      final probe = await decoder.probe('a.wav', buckets: 4);
      expect(probe.info.sourceFrames, 44100);
      expect(probe.peaks, hasLength(4));
      expect(decoder.live, 0);
    });
  });

  group('DecodedAudio ownership', () {
    test('dispose frees once; a disposed decode cannot be read', () async {
      final decoder = MockAudioDecoder(
        files: {'a': const MockAudioFile(sourceRate: 48000, sourceFrames: 10)},
      );
      final audio = await decoder.decode('a', sampleRate: 48000);
      expect(audio.ownership, DecodedAudioOwnership.owned);
      audio
        ..dispose()
        ..dispose();
      expect(audio.ownership, DecodedAudioOwnership.disposed);
      expect(decoder.freed, 1);
      expect(audio.copySamples, throwsStateError);
    });
  });

  group('MockAudioEngine backing', () {
    late MockAudioEngine engine;
    late MockAudioDecoder decoder;

    setUp(() {
      engine = MockAudioEngine()..start(_config);
      decoder = MockAudioDecoder(
        files: {
          'a': const MockAudioFile(sourceRate: 48000, sourceFrames: 300),
          'b': const MockAudioFile(sourceRate: 48000, sourceFrames: 200),
          'c44': const MockAudioFile(sourceRate: 44100, sourceFrames: 100),
        },
      );
    });

    Future<DecodedAudio> decode(String path, {int rate = 48000}) =>
        decoder.decode(path, sampleRate: rate);

    test('refuses when not running, keeping the audio', () async {
      final idle = MockAudioEngine();
      final audio = await decode('a');
      expect(
        idle.backingLoad(audio, item: 1, play: true),
        EngineResult.notRunning,
      );
      expect(audio.isOwned, isTrue);
      audio.dispose();
    });

    test('a configured but stopped engine still takes backing calls, as '
        'the native one does (review of P3, L1)', () async {
      final audio = await decode('a');
      engine.stop();
      expect(engine.backingLoad(audio, item: 3, play: false), EngineResult.ok);
      expect(engine.backingTransport(BackingTransportOp.play), EngineResult.ok);
      expect(engine.backingSeek(10), EngineResult.ok);
      expect(engine.backingStageNext(null, item: -1), EngineResult.ok);
      expect(engine.backingState().item, 3);
      expect(engine.backingClear(), EngineResult.ok);
    });

    test('a retained reopen keeps the loaded and staged files, stopped at '
        '0, and bumps the epoch; a rate change frees them', () async {
      final a = await decode('a');
      final b = await decode('b');
      engine
        ..backingLoad(a, item: 1, play: true)
        ..backingStageNext(b, item: 2)
        ..advanceBacking(50)
        ..stop();
      final epoch = engine.backingState().epoch;
      final kept = engine.reopen(_config);
      expect(kept.outcome, ReopenOutcome.retained);
      var s = engine.backingState();
      expect(s.epoch, epoch + 1);
      expect((s.item, s.nextItem, s.owned), (1, 2, 2));
      expect((s.transport, s.position), (BackingTransport.stopped, 0));
      expect(decoder.freed, 0);
      engine.stop();
      final cleared = engine.reopen(
        const EngineConfig(sampleRate: 44100, outputChannels: 2),
      );
      expect(cleared.outcome, ReopenOutcome.clearedRate);
      s = engine.backingState();
      expect(s.epoch, epoch + 2);
      expect((s.item, s.owned), (-1, 0));
      expect(decoder.freed, 2);
    });

    test('load transfers, plays and stops at the end', () async {
      final audio = await decode('a');
      expect(engine.backingLoad(audio, item: 7, play: true), EngineResult.ok);
      expect(audio.ownership, DecodedAudioOwnership.transferred);
      expect(audio.copySamples, throwsStateError);
      engine.advanceBacking(100);
      var s = engine.backingState();
      expect(s.item, 7);
      expect(s.transport, BackingTransport.playing);
      expect(s.position, 100);
      expect(s.frames, 300);
      engine.advanceBacking(250);
      s = engine.backingState();
      expect(s.transport, BackingTransport.stopped);
      expect(s.position, 0);
      expect(s.endCount, 1);
      expect(s.lastEnd, BackingEndEvent.stopped);
    });

    test(
      'the same audio twice, a spent one, or another rate is refused',
      () async {
        final audio = await decode('a');
        expect(
          engine.backingLoad(audio, item: 1, play: false),
          EngineResult.ok,
        );
        expect(
          engine.backingLoad(audio, item: 2, play: false),
          EngineResult.invalid,
        );
        final other = await decode('c44', rate: 44100);
        expect(
          engine.backingLoad(other, item: 3, play: false),
          EngineResult.invalid,
        );
        expect(other.isOwned, isTrue);
        other.dispose();
        expect(decoder.live, 1);
      },
    );

    test('repeat wraps; next advances and frees the finished file', () async {
      engine
        ..setBackingEnd(BackingEnd.repeat)
        ..backingLoad(await decode('a'), item: 1, play: true)
        ..advanceBacking(650);
      var s = engine.backingState();
      expect(s.position, 50);
      expect(s.endCount, 2);
      expect(s.lastEnd, BackingEndEvent.repeated);

      engine
        ..setBackingEnd(BackingEnd.next)
        ..backingStageNext(await decode('b'), item: 2);
      expect(engine.backingState().nextItem, 2);
      engine.advanceBacking(250);
      s = engine.backingState();
      expect(s.item, 2);
      expect(s.nextItem, -1);
      expect(s.position, 0);
      expect(s.lastEnd, BackingEndEvent.advanced);
      expect(decoder.live, 1);
      engine.advanceBacking(200);
      s = engine.backingState();
      expect(s.transport, BackingTransport.stopped);
      expect(s.lastEnd, BackingEndEvent.nextMissing);
    });

    test('pause holds, play resumes, stop rewinds, seek clamps', () async {
      engine
        ..backingLoad(await decode('a'), item: 1, play: true)
        ..advanceBacking(40)
        ..backingTransport(BackingTransportOp.pause)
        ..advanceBacking(40);
      expect(engine.backingState().position, 40);
      expect(engine.backingState().transport, BackingTransport.paused);
      engine
        ..backingSeek(1000)
        ..backingTransport(BackingTransportOp.play);
      expect(engine.backingState().position, 299);
      engine.backingTransport(BackingTransportOp.stop);
      expect(engine.backingState().position, 0);
      expect(engine.backingState().transport, BackingTransport.stopped);
    });

    test('replace, restage and clear free what they drop', () async {
      engine
        ..backingLoad(await decode('a'), item: 1, play: true)
        ..backingLoad(await decode('b'), item: 2, play: true)
        ..backingStageNext(await decode('a'), item: 3)
        ..backingStageNext(await decode('b'), item: 4);
      expect(decoder.decoded, 4);
      expect(decoder.live, 2);
      expect(engine.backingState().owned, 2);
      engine.backingStageNext(null, item: 0);
      expect(decoder.live, 1);
      engine.backingClear();
      expect(decoder.live, 0);
      expect(engine.backingState(), isA<BackingState>());
      expect(engine.backingState().loaded, isFalse);
    });

    test('a fresh start frees the buffers, keeps the settings, bumps the '
        'epoch', () async {
      engine
        ..setBackingOutput(3)
        ..setBackingLevel(0.5)
        ..setBackingPan(-2)
        ..setClickPan(0.25)
        ..backingLoad(await decode('a'), item: 1, play: true);
      final epoch = engine.backingState().epoch;
      engine
        ..stop()
        ..start(_config);
      final s = engine.backingState();
      expect(decoder.live, 0);
      expect(s.epoch, epoch + 1);
      expect(s.loaded, isFalse);
      expect(s.outputMask, 3);
      expect(s.level, 0.5);
      expect(s.pan, -1);
      expect(s.clickPan, 0.25);
    });

    test('dispose frees the buffers', () async {
      engine
        ..backingLoad(await decode('a'), item: 1, play: false)
        ..dispose();
      expect(decoder.live, 0);
    });

    test('a stage past the 1.5 GiB backing budget is refused', () async {
      // 110 M frames of stereo float are 880 MB: two pass, the stage of a
      // second over 1.5 GiB in all does not (no samples are made).
      decoder.files['big'] = const MockAudioFile(
        sourceRate: 192000,
        sourceFrames: 110000000,
      );
      final big = await decoder.decode('big', sampleRate: 192000);
      final engine192 = MockAudioEngine()
        ..start(const EngineConfig(sampleRate: 192000, outputChannels: 2));
      addTearDown(engine192.dispose);
      expect(engine192.backingLoad(big, item: 1, play: false), EngineResult.ok);
      final second = await decoder.decode('big', sampleRate: 192000);
      expect(
        engine192.backingStageNext(second, item: 2),
        EngineResult.capacity,
      );
      expect(second.isOwned, isTrue);
      second.dispose();
    });

    test('NaN gains and pans are refused', () {
      expect(engine.setBackingLevel(double.nan), EngineResult.invalid);
      expect(engine.setBackingPan(double.nan), EngineResult.invalid);
      expect(engine.setClickPan(double.nan), EngineResult.invalid);
      expect(engine.setBackingLevel(9), EngineResult.ok);
      expect(engine.backingState().level, 2);
    });
  });
}
