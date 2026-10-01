import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

engine.EngineSnapshot emptyTracks([int count = 3]) => engine.EngineSnapshot(
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
    for (var channel = 0; channel < count; channel++)
      const engine.TrackSnapshot.empty(),
  ],
);

class RejectingEngine extends FakeAudioEngine {
  bool rejectDivision = false;
  bool rejectOnce = false;
  bool rejectLengths = false;
  bool dropMode = false;

  @override
  EngineResult setTrackLengthPresets(List<int> bars) =>
      rejectLengths ? EngineResult.invalid : super.setTrackLengthPresets(bars);

  @override
  EngineResult setTrackLengthPreset({
    required int channel,
    required int bars,
  }) => rejectLengths
      ? EngineResult.invalid
      : super.setTrackLengthPreset(channel: channel, bars: bars);

  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) =>
      rejectLengths
      ? EngineResult.invalid
      : dropMode
      ? EngineResult.ok
      : super.setLooperModeWithPresets(mode, bars);

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

  test('length inheritance retains explicit Auto and equal custom values', () {
    repository
      ..setLooperMode(LooperMode.free)
      ..setDefaultLengthPreset(4)
      ..setTrackLengthPreset(channel: 0, bars: 0)
      ..setTrackLengthPreset(channel: 1, bars: 4)
      ..startEngine(const EngineConfig());
    expect(audio.trackLengthPreset, {0: 0, 1: 4, 2: 4});
    repository.setDefaultLengthPreset(8);
    expect(audio.trackLengthPreset, {0: 0, 1: 4, 2: 8});
    expect(repository.state.tracks[0].lengthPresetOverride, 0);
    expect(repository.state.tracks[2].lengthPresetOverride, isNull);
    repository.setTrackLengthPreset(channel: 1, bars: null);
    expect(audio.trackLengthPreset[1], 8);
    expect(repository.trackLengthPresetOverrides, {0: 0});
    repository.stopEngine();
    audio.trackLengthPreset.clear();
    repository.startEngine(const EngineConfig());
    expect(audio.trackLengthPreset, {0: 0, 1: 8, 2: 8});
  });

  test('Multi shares default and restores dormant independent overrides', () {
    repository
      ..setDefaultLengthPreset(4)
      ..setTrackLengthPreset(channel: 0, bars: 8)
      ..setTrackLengthPreset(channel: 1, bars: 0)
      ..startEngine(const EngineConfig());
    expect(audio.trackLengthPreset, {0: 4, 1: 4, 2: 4});
    repository.setDefaultLengthPreset(16);
    expect(audio.trackLengthPreset, {0: 16, 1: 16, 2: 16});
    repository.setLooperMode(LooperMode.free);
    expect(audio.trackLengthPreset, {0: 8, 1: 0, 2: 16});
    repository.setLooperMode(LooperMode.multi);
    expect(audio.trackLengthPreset, {0: 16, 1: 16, 2: 16});
    expect(repository.trackLengthPresetOverrides, {0: 8, 1: 0});
  });

  test('length and mode refusal preserve every desired and native value', () {
    repository
      ..setDefaultLengthPreset(4)
      ..setTrackLengthPreset(channel: 0, bars: 8)
      ..startEngine(const EngineConfig());
    audio.rejectLengths = true;
    expect(repository.setDefaultLengthPreset(16), EngineResult.invalid);
    expect(
      repository.setTrackLengthPreset(channel: 0, bars: null),
      EngineResult.invalid,
    );
    expect(repository.setLooperMode(LooperMode.free), EngineResult.invalid);
    expect(repository.sessionTransport.defaultLengthPresetBars, 4);
    expect(repository.sessionTransport.looperMode, LooperMode.multi);
    expect(repository.trackLengthPresetOverrides, {0: 8});
    expect(audio.trackLengthPreset, {0: 4, 1: 4, 2: 4});
  });

  for (final action in [
    'default',
    'track',
    'mode',
    'invalid track',
    'invalid overrides',
  ]) {
    test(
      'immediate $action refusal emits once without changing settings',
      () async {
        repository
          ..setDefaultLengthPreset(4)
          ..setTrackLengthPreset(channel: 0, bars: 8)
          ..startEngine(const EngineConfig());
        final failures = <EngineResult>[];
        final subscription = repository.lengthSettingsFailures.listen(
          failures.add,
        );
        addTearDown(subscription.cancel);
        audio.rejectLengths = true;
        final result = switch (action) {
          'default' => repository.setDefaultLengthPreset(16),
          'track' => repository.setTrackLengthPreset(channel: 0, bars: null),
          'mode' => repository.setLooperMode(LooperMode.free),
          'invalid track' => repository.setTrackLengthPreset(
            channel: 8,
            bars: 4,
          ),
          _ => repository.setLengthSettings(defaultBars: 16, overrides: {8: 4}),
        };
        expect(result, EngineResult.invalid);
        await Future<void>.delayed(Duration.zero);
        expect(failures, [EngineResult.invalid]);
        expect(repository.sessionTransport.defaultLengthPresetBars, 4);
        expect(repository.sessionTransport.looperMode, LooperMode.multi);
        expect(repository.trackLengthPresetOverrides, {0: 8});
        expect(audio.publishedLengths, {0: 4, 1: 4, 2: 4});
        expect(repository.lengthSettingsSettled, isTrue);
      },
    );
  }

  test(
    'busy refusal does not poison the first pending length request',
    () async {
      repository
        ..setDefaultLengthPreset(4)
        ..startEngine(const EngineConfig());
      final failures = <EngineResult>[];
      final subscription = repository.lengthSettingsFailures.listen(
        failures.add,
      );
      addTearDown(subscription.cancel);
      audio.commandsAreSettled = false;
      expect(repository.setDefaultLengthPreset(8), EngineResult.ok);
      final first = repository.settleLengthSettings();
      expect(repository.setLooperMode(LooperMode.free), EngineResult.notReady);
      await Future<void>.delayed(Duration.zero);
      expect(failures, [EngineResult.notReady]);
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      expect(repository.lengthSettingsSettled, isFalse);
      audio.commandsAreSettled = true;
      expect(await first, EngineResult.ok);
      expect(await repository.settleLengthSettings(), EngineResult.ok);
      expect(repository.sessionTransport.defaultLengthPresetBars, 8);
      expect(repository.sessionTransport.looperMode, LooperMode.multi);
      expect(repository.trackLengthPresetOverrides, isEmpty);
      expect(failures, [EngineResult.notReady]);
    },
  );

  test('cancelled length request does not emit failure feedback', () async {
    repository.startEngine(const EngineConfig());
    final failures = <EngineResult>[];
    final subscription = repository.lengthSettingsFailures.listen(failures.add);
    addTearDown(subscription.cancel);
    audio.commandsAreSettled = false;
    repository.setDefaultLengthPreset(8);
    final pending = repository.settleLengthSettings();
    repository.stopEngine();
    expect(await pending, EngineResult.notReady);
    expect(failures, isEmpty);
  });

  test(
    'callback mode rejection reconciles without compensating preset writes',
    () async {
      repository
        ..setDefaultLengthPreset(4)
        ..setTrackLengthPreset(channel: 0, bars: 8)
        ..startEngine(const EngineConfig());
      audio
        ..dropMode = true
        ..commandsAreSettled = false;
      repository.setLooperMode(LooperMode.free);
      expect(repository.settledLooperMode, isNull);
      audio.calls.clear();
      audio.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      for (var poll = 0; poll < 12; poll++) {
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
      }
      expect(repository.settledLooperMode, LooperMode.multi);
      expect(audio.trackLengthPreset, {0: 4, 1: 4, 2: 4});
      expect(audio.calls, isNot(contains('setTrackLengthPresets')));
      expect(audio.calls, isNot(contains('setTrackLengthPreset')));
    },
  );

  test(
    'empty session recalls length default and explicit Auto independently',
    () async {
      repository.startEngine(const EngineConfig());
      await repository.applySession(
        const SessionRig(
          looperMode: LooperMode.free,
          defaultLengthPresetBars: 4,
          trackLengthPresetOverrides: {0: 0, 1: 4},
        ),
        clearPollInterval: Duration.zero,
      );
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      expect(repository.trackLengthPresetOverrides, {0: 0, 1: 4});
      expect(audio.trackLengthPreset, {0: 0, 1: 4, 2: 4});
      repository.setDefaultLengthPreset(8);
      expect(audio.trackLengthPreset, {0: 0, 1: 4, 2: 8});
    },
  );

  test(
    'settlement refuses unpublished same-mode default and override changes',
    () async {
      repository
        ..setLooperMode(LooperMode.free)
        ..setDefaultLengthPreset(4)
        ..startEngine(const EngineConfig());
      audio
        ..commandsAreSettled = false
        ..publishLengthCommands = false;
      expect(repository.setDefaultLengthPreset(8), EngineResult.ok);
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      expect(
        repository.setTrackLengthPreset(channel: 0, bars: 0),
        EngineResult.notReady,
      );
      audio.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      audio.commandsAreSettled = false;
      expect(
        repository.setTrackLengthPreset(channel: 0, bars: 0),
        EngineResult.ok,
      );
      expect(repository.trackLengthPresetOverrides, isEmpty);
      audio.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      expect(repository.trackLengthPresetOverrides, isEmpty);
    },
  );

  test(
    'confirmed vector publishes without a ticker and owns input map',
    () async {
      repository.startEngine(const EngineConfig());
      audio.commandsAreSettled = false;
      final overrides = {0: 0, 1: 4};
      expect(
        repository.setLengthSettings(defaultBars: 8, overrides: overrides),
        EngineResult.ok,
      );
      overrides[0] = 16;
      expect(repository.trackLengthPresetOverrides, isEmpty);
      audio.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.ok);
      expect(repository.sessionTransport.defaultLengthPresetBars, 8);
      expect(repository.trackLengthPresetOverrides, {0: 0, 1: 4});
    },
  );

  test('session replacement cancels an older length waiter', () async {
    repository.startEngine(const EngineConfig());
    audio.commandsAreSettled = false;
    repository.setDefaultLengthPreset(8);
    final previous = repository.settleLengthSettings();
    audio.commandsAreSettled = true;
    await repository.applySession(
      const SessionRig(defaultLengthPresetBars: 4),
      clearPollInterval: Duration.zero,
    );
    expect(await previous, EngineResult.notReady);
    expect(repository.sessionTransport.defaultLengthPresetBars, 4);
  });

  test(
    'startup replay refusal keeps saved choice and stops the engine',
    () async {
      repository
        ..setDefaultLengthPreset(8)
        ..setTrackLengthPreset(channel: 0, bars: 0);
      audio.rejectLengths = true;
      expect(
        repository.startEngine(const EngineConfig()),
        EngineResult.invalid,
      );
      expect(repository.sessionTransport.isRunning, isFalse);
      expect(repository.sessionTransport.defaultLengthPresetBars, 8);
      expect(repository.trackLengthPresetOverrides, {0: 0});
      audio
        ..rejectLengths = false
        ..commandsAreSettled = false
        ..publishLengthCommands = false;
      final failures = repository.lengthSettingsFailures.first;
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      audio.commandsAreSettled = true;
      expect(await repository.settleLengthSettings(), EngineResult.invalid);
      expect(await failures, EngineResult.invalid);
      expect(repository.sessionTransport.isRunning, isFalse);
      expect(repository.sessionTransport.defaultLengthPresetBars, 8);
    },
  );

  test(
    'settlement timeout stops pending work and restart replays '
    'confirmed choice',
    () async {
      repository
        ..setDefaultLengthPreset(4)
        ..startEngine(const EngineConfig());
      audio
        ..commandsAreSettled = false
        ..publishLengthCommands = false;
      repository.setDefaultLengthPreset(8);
      final failures = repository.lengthSettingsFailures.first;
      expect(
        await repository.settleLengthSettings(
          pollInterval: Duration.zero,
          attempts: 1,
        ),
        EngineResult.notReady,
      );
      expect(await failures, EngineResult.notReady);
      expect(repository.sessionTransport.isRunning, isFalse);
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      audio
        ..commandsAreSettled = true
        ..publishLengthCommands = true;
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(audio.publishedLengths, {0: 4, 1: 4, 2: 4});
      expect(await repository.settleLengthSettings(), EngineResult.ok);
    },
  );

  test(
    'dispose cancels a waiting length request before native access',
    () async {
      repository.startEngine(const EngineConfig());
      audio.commandsAreSettled = false;
      repository.setDefaultLengthPreset(8);
      final wait = repository.settleLengthSettings();
      await repository.dispose();
      expect(await wait, EngineResult.notReady);
    },
  );

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

  test('refused Once default leaves every track unchanged', () {
    repository
      ..startEngine(const EngineConfig())
      ..setDefaultOneShot(oneShot: false)
      ..setOneShot(channel: 1, oneShot: true);
    audio.rejectOnce = true;
    expect(repository.setDefaultOneShot(oneShot: true), EngineResult.invalid);
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
        looperMode: LooperMode.free,
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
    audio.nextSnapshot = emptyTracks(8);
    repository.startEngine(const EngineConfig());
    expect(audio.trackQuantizeDiv[7], GridDivision.bar);
    expect(audio.trackOverdubFeedback[7], 0);
    expect(audio.trackOneShot[0], isFalse);
    expect(audio.trackOneShot[7], isTrue);
    expect(audio.trackLengthPreset[7], 8);
  });
}
