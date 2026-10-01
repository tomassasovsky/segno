import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

engine.EngineSnapshot emptyTracks() => const engine.EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: engine.LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    engine.TrackSnapshot.empty(),
    engine.TrackSnapshot.empty(),
    engine.TrackSnapshot.empty(),
  ],
);

class RejectingEngine extends FakeAudioEngine {
  bool rejectDivision = false;
  bool rejectOnce = false;

  @override
  EngineResult setQuantizeDiv(GridDivision div) =>
      rejectDivision ? EngineResult.invalid : super.setQuantizeDiv(div);

  @override
  EngineResult setTrackQuantizeDiv({
    required int channel,
    required GridDivision? div,
  }) => rejectDivision
      ? EngineResult.invalid
      : super.setTrackQuantizeDiv(channel: channel, div: div);

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) =>
      rejectOnce
      ? EngineResult.invalid
      : super.setOneShotMask(channels: channels, oneShot: oneShot);
}

void main() {
  late RejectingEngine audio;
  late LooperRepository repository;
  late StreamController<void> ticker;
  setUp(() {
    audio = RejectingEngine()..nextSnapshot = emptyTracks();
    ticker = StreamController<void>.broadcast();
    repository = LooperRepository(engine: audio, ticker: ticker.stream);
  });
  tearDown(() async {
    await repository.dispose();
    await ticker.close();
  });

  test('custom Loop and Once survive defaults and reconnect', () {
    repository
      ..startEngine(const EngineConfig())
      ..setOneShot(channel: 0, oneShot: false)
      ..setOneShot(channel: 1, oneShot: true)
      ..setDefaultOneShot(oneShot: true);
    expect(audio.trackOneShot, {0: false, 1: true, 2: true});
    expect(repository.state.tracks[0].oneShotOverride, isFalse);
    expect(repository.state.tracks[2].oneShotOverride, isNull);
    expect(repository.state.tracks[2].oneShot, isTrue);
    repository
      ..setDefaultOneShot(oneShot: false)
      ..stopEngine();
    audio.trackOneShot.clear();
    repository.startEngine(const EngineConfig());
    expect(audio.trackOneShot[0], isFalse);
    expect(audio.trackOneShot[1], isTrue);
    expect(repository.defaultOneShot, isFalse);
  });

  test('Use default removes only playback override', () {
    repository
      ..startEngine(const EngineConfig())
      ..setDefaultOneShot(oneShot: true)
      ..setOneShot(channel: 0, oneShot: false)
      ..setTrackRecordTiming(channel: 0, timing: RecordTiming.bar)
      ..setTrackOverdubDecay(channel: 0, percent: 0)
      ..setOneShot(channel: 0, oneShot: null);
    expect(audio.trackOneShot[0], isTrue);
    expect(repository.trackOneShotOverrides, isEmpty);
    expect(repository.trackRecordTimingOverrides, {0: RecordTiming.bar});
    expect(repository.trackOverdubDecayOverrides, {0: 0});
    expect(
      () => repository.trackOneShotOverrides[0] = false,
      throwsUnsupportedError,
    );
  });

  test('offline musical edits are readable without snapshot polling', () {
    repository
      ..setTempo(97.5)
      ..setTimeSignature(7, 8)
      ..setRecordTiming(RecordTiming.quarter)
      ..setDefaultMultiple(multiple: 4)
      ..setDefaultOneShot(oneShot: true)
      ..setOverdubDecay(25)
      ..setRecDub(enabled: true)
      ..setClickOutput(3)
      ..setClickVolume(0.4)
      ..setCountIn(2);
    final reads = audio.snapshotCalls;
    final settings = repository.sessionTransport;
    expect(settings.tempoBpm, 97.5);
    expect(settings.tempoSource, TempoSource.manual);
    expect((settings.tsNum, settings.tsDen), (7, 8));
    expect(settings.recordTiming, RecordTiming.quarter);
    expect(settings.defaultMultiple, 4);
    expect(settings.defaultOneShot, isTrue);
    expect(settings.overdubDecay, 25);
    expect(settings.recDub, isTrue);
    expect(settings.clickVolume, 0.4);
    expect(settings.countInBars, 2);
    expect(audio.snapshotCalls, reads);
  });

  test('empty tracks recall defaults and explicit overrides', () async {
    repository
      ..startEngine(const EngineConfig())
      ..setOneShot(channel: 2, oneShot: true)
      ..setTrackRecordTiming(channel: 2, timing: RecordTiming.bar)
      ..setTrackOverdubDecay(channel: 2, percent: 80);
    await repository.applySession(
      const SessionRig(
        defaultOneShot: true,
        recordTiming: RecordTiming.quarter,
        overdubDecay: 25,
        trackOneShotOverrides: {0: false, 1: true},
        trackRecordTimingOverrides: {0: RecordTiming.quarter},
        trackOverdubDecayOverrides: {0: 25},
        trackLengthPresetOverrides: {0: 8},
      ),
      clearPollInterval: Duration.zero,
    );
    expect(repository.defaultRecordTiming, RecordTiming.quarter);
    expect(repository.trackOneShotOverrides, {0: false, 1: true});
    expect(repository.trackRecordTimingOverrides, {0: RecordTiming.quarter});
    expect(repository.trackOverdubDecayOverrides, {0: 25});
    expect(repository.trackLengthPresetOverrides, {0: 8});
    expect(audio.trackOneShot, {0: false, 1: true, 2: true});
    expect(repository.state.tracks.every((track) => !track.hasContent), isTrue);
    repository.setDefaultOneShot(oneShot: false);
    expect(audio.trackOneShot[1], isTrue);
    expect(audio.trackOneShot[2], isFalse);
  });

  test('recall restores grid before mode and can clear old tempo', () async {
    repository
      ..startEngine(const EngineConfig())
      ..setTempo(140);
    audio.calls.clear();
    await repository.applySession(
      const SessionRig(
        tempoBpm: 97.5,
        tempoSource: TempoSource.tapped,
        tsNum: 7,
        tsDen: 8,
        recordTiming: RecordTiming.bar,
        quantizeDiv: GridDivision.bar,
        countInBars: 2,
        recDub: true,
      ),
      clearPollInterval: Duration.zero,
    );
    expect(audio.tempoRestores.last, (bpm: 97.5, source: TempoSource.tapped));
    expect(
      audio.calls.indexOf('restoreTempo'),
      lessThan(audio.calls.indexOf('setLooperMode')),
    );
    expect(repository.sessionTransport.tempoBpm, 97.5);
    expect(repository.sessionTransport.countInBars, 2);
    expect(repository.sessionTransport.recDub, isTrue);
    await repository.applySession(
      const SessionRig(),
      clearPollInterval: Duration.zero,
    );
    expect(audio.tempoRestores.last, (bpm: 0.0, source: TempoSource.none));
    expect(repository.sessionTransport.tempoBpm, 0);
    expect(repository.sessionTransport.tempoSource, TempoSource.none);
    expect(repository.sessionTransport.countInBars, 0);
    expect(repository.trackOneShotOverrides, isEmpty);
  });
  test(
    'refused timing preserves gate, default and explicit track override',
    () {
      repository
        ..startEngine(const EngineConfig())
        ..setTrackRecordTiming(channel: 0, timing: RecordTiming.immediately);
      audio.rejectDivision = true;
      expect(
        repository.setRecordTiming(RecordTiming.quarter),
        EngineResult.invalid,
      );
      expect(
        repository.setTrackRecordTiming(channel: 0, timing: RecordTiming.bar),
        EngineResult.invalid,
      );
      expect(audio.lastQuantize, isFalse);
      expect(audio.trackQuantize[0], isFalse);
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(repository.trackRecordTimingOverrides, {
        0: RecordTiming.immediately,
      });
      expect(
        repository.setTrackRecordTiming(channel: 0, timing: null),
        EngineResult.invalid,
      );
      expect(repository.trackRecordTimingOverrides, {
        0: RecordTiming.immediately,
      });
    },
  );

  test('refused Once default or group leaves every track unchanged', () {
    repository
      ..startEngine(const EngineConfig())
      ..setDefaultOneShot(oneShot: false)
      ..setOneShot(channel: 1, oneShot: true);
    audio.rejectOnce = true;
    expect(repository.setDefaultOneShot(oneShot: true), EngineResult.invalid);
    expect(repository.setAllOneShot(oneShot: false), EngineResult.invalid);
    expect(repository.defaultOneShot, isFalse);
    expect(repository.trackOneShotOverrides, {1: true});
    expect(audio.trackOneShot, {0: false, 1: true, 2: false});
  });

  for (final running in [false, true]) {
    test('Immediate preserves the selected grid when running=$running', () {
      if (running) repository.startEngine(const EngineConfig());
      expect(
        repository.setRecordTiming(RecordTiming.quarter),
        EngineResult.ok,
      );
      expect(
        repository.setRecordTiming(RecordTiming.immediately),
        EngineResult.ok,
      );
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(repository.sessionTransport.quantizeDiv, GridDivision.quarter);
      if (running) expect(audio.lastQuantizeDiv, GridDivision.quarter);
      if (running) repository.stopEngine();
      audio.lastQuantizeDiv = null;
      repository.startEngine(const EngineConfig());
      expect(repository.defaultRecordTiming, RecordTiming.immediately);
      expect(repository.sessionTransport.quantizeDiv, GridDivision.quarter);
      expect(audio.lastQuantizeDiv, GridDivision.quarter);
      repository.setQuantize(enabled: true);
      expect(repository.defaultRecordTiming, RecordTiming.quarter);
    });
  }

  test('immediate timing recalls its remembered disabled grid', () async {
    repository.startEngine(const EngineConfig());
    await repository.applySession(
      const SessionRig(quantizeDiv: GridDivision.bar),
      clearPollInterval: Duration.zero,
    );
    expect(repository.defaultRecordTiming, RecordTiming.immediately);
    expect(repository.sessionTransport.quantizeDiv, GridDivision.bar);
    expect(audio.lastQuantize, isFalse);
    repository.setQuantize(enabled: true);
    expect(repository.defaultRecordTiming, RecordTiming.bar);
  });

  test(
    'unsupported tempo refuses before clearing current recordings',
    () async {
      repository.startEngine(const EngineConfig());
      audio.calls.clear();
      final revision = repository.sessionRevision;
      await expectLater(
        repository.applySession(
          const SessionRig(tempoBpm: 120, tempoSource: TempoSource.external),
        ),
        throwsStateError,
      );
      expect(audio.calls, isNot(contains('clear')));
      expect(repository.sessionRevision, revision);
    },
  );
  test('session recall owns override maps before clearing awaits', () async {
    repository.startEngine(const EngineConfig());
    final timing = {0: RecordTiming.bar};
    final decay = {0: 25};
    final once = {0: false};
    final lengths = {0: 8};
    final apply = repository.applySession(
      SessionRig(
        trackRecordTimingOverrides: timing,
        trackOverdubDecayOverrides: decay,
        trackOneShotOverrides: once,
        trackLengthPresetOverrides: lengths,
      ),
      clearPollInterval: Duration.zero,
    );
    timing[0] = RecordTiming.immediately;
    decay[0] = 99;
    once[0] = true;
    lengths[0] = 2;
    await apply;
    expect(repository.trackRecordTimingOverrides, {0: RecordTiming.bar});
    expect(repository.trackOverdubDecayOverrides, {0: 25});
    expect(repository.trackOneShotOverrides, {0: false});
    expect(repository.trackLengthPresetOverrides, {0: 8});
  });
  test(
    'invalid restored grid refuses before clearing or replacing settings',
    () async {
      repository.startEngine(const EngineConfig());
      final revision = repository.sessionRevision;
      audio.calls.clear();
      for (final bars in [-1, 0x7fffffff]) {
        await expectLater(
          repository.applySession(SessionRig(loopBars: bars)),
          throwsStateError,
        );
      }
      expect(audio.calls, isEmpty);
      expect(repository.sessionRevision, revision);
    },
  );
  test('session settings load before a device has any native tracks', () async {
    audio.nextSnapshot = const engine.EngineSnapshot.initial();
    await repository.applySession(
      const SessionRig(
        trackRecordTimingOverrides: {
          0: RecordTiming.quarter,
          7: RecordTiming.bar,
        },
        trackOverdubDecayOverrides: {0: 0, 7: 100},
        trackOneShotOverrides: {0: false, 7: true},
        trackLengthPresetOverrides: {0: 4, 7: 8},
      ),
    );
    expect(repository.trackRecordTimingOverrides, {
      0: RecordTiming.quarter,
      7: RecordTiming.bar,
    });
    expect(repository.trackOverdubDecayOverrides, {0: 0, 7: 100});
    expect(repository.trackOneShotOverrides, {0: false, 7: true});
    expect(repository.trackLengthPresetOverrides, {0: 4, 7: 8});
    expect(audio.trackQuantizeDiv, isEmpty);
    expect(audio.trackOverdubFeedback, isEmpty);
    expect(audio.trackOneShot, isEmpty);
    expect(audio.trackLengthPreset, isEmpty);
    repository.startEngine(const EngineConfig());
    expect(audio.trackQuantizeDiv[7], GridDivision.bar);
    expect(audio.trackOverdubFeedback[7], 0);
    expect(audio.trackOneShot[0], isFalse);
    expect(audio.trackOneShot[7], isTrue);
    expect(audio.trackLengthPreset[7], 8);
  });
}
