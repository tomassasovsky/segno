import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/playback_options.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _DelayedSettingsRepository extends SettingsRepository {
  _DelayedSettingsRepository({required super.store});

  final ready = Completer<void>();

  Future<T> _delay<T>(Future<T> read) async {
    final saved = await read;
    await ready.future;
    return saved;
  }

  @override
  Future<int?> readDecayCheckpoint({required int? channel}) =>
      _delay(super.readDecayCheckpoint(channel: channel));

  @override
  Future<RecordTimingCheckpoint> readRecordTimingCheckpoint() =>
      _delay(super.readRecordTimingCheckpoint());

  @override
  Future<bool> loadRecDub() => _delay(super.loadRecDub());

  @override
  Future<double> loadTempoBpm() => _delay(super.loadTempoBpm());
}

void main() {
  late LooperRepository repository;
  late SettingsRepository settings;
  late StreamController<void> ticks;

  setUp(() {
    ticks = StreamController<void>.broadcast();
    repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: ticks.stream,
    );
    settings = SettingsRepository(store: FakeKeyValueStore());
  });

  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  Future<void> poll() async {
    ticks.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  Future<_DelayedSettingsRepository> delayedSettings() async {
    final delayed = _DelayedSettingsRepository(store: FakeKeyValueStore());
    await delayed.restoreDecayCheckpoint(channel: null, percent: 80);
    await delayed.restoreOneShotCheckpoint(channel: null, oneShot: true);
    await delayed.restoreRecordTimingCheckpoint((
      quantize: true,
      division: null,
      trackOverrides: {},
    ));
    await delayed.saveRecDub(value: true);
    await delayed.saveDefaultMultiple(4);
    await delayed.saveTempoBpm(120);
    await delayed.saveRecordStartSettings(countInBars: 2, soundStart: false);
    return delayed;
  }

  test(
    'a session recall wins while all startup preference reads are pending',
    () async {
      final delayed = await delayedSettings();
      final playback = PlaybackSettings(
        repository: repository,
        settings: delayed,
      );
      final quantize = RecordTimingSettings(
        repository: repository,
        settings: delayed,
      );
      final record = RecordSettings(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoSettings(repository: repository, settings: delayed);
      addTearDown(playback.close);
      addTearDown(quantize.close);
      addTearDown(record.close);
      addTearDown(tempo.close);
      addTearDown(() {
        if (!delayed.ready.isCompleted) delayed.ready.complete();
      });
      final loads = Future.wait([
        playback.load(),
        quantize.load(),
        record.load(),
        tempo.load(),
      ]);
      await Future<void>.delayed(Duration.zero);

      await repository.applySession(
        const SessionRig(
          overdubDecay: 35,
          tempoBpm: 96,
          tempoSource: TempoSource.manual,
          autoRecord: true,
        ),
      );
      await poll();
      expect(
        playback.state,
        const PlaybackOptions(
          overdubDecay: 35,
          decayReady: true,
          oneShotReady: true,
        ),
      );
      expect(quantize.state.defaultTiming, RecordTiming.immediately);
      expect(
        record.state,
        const RecordOptions(recordLengthReady: true),
      );
      expect(
        tempo.state,
        const TempoState(
          bpm: 96,
          soundStart: true,
          recordStartReady: true,
          clickReady: true,
          clickModeReady: true,
        ),
      );

      delayed.ready.complete();
      await loads;
      await poll();
      expect(
        playback.state,
        const PlaybackOptions(
          overdubDecay: 35,
          decayReady: true,
          oneShotReady: true,
        ),
      );
      expect(quantize.state.defaultTiming, RecordTiming.immediately);
      expect(
        record.state,
        const RecordOptions(recordLengthReady: true),
      );
      expect(
        tempo.state,
        const TempoState(
          bpm: 96,
          soundStart: true,
          recordStartReady: true,
          clickReady: true,
          clickModeReady: true,
        ),
      );
      expect(repository.sessionTransport.overdubDecay, 35);
      expect(repository.sessionTransport.defaultOneShot, isFalse);
      expect(repository.sessionTransport.defaultMultiple, 0);
      expect(repository.sessionTransport.autoRecord, isTrue);
      expect(repository.sessionTransport.tempoBpm, 96);
    },
  );

  test(
    'explicit matching edits win over pending startup preferences',
    () async {
      final delayed = await delayedSettings();
      final playback = PlaybackSettings(
        repository: repository,
        settings: delayed,
      );
      final quantize = RecordTimingSettings(
        repository: repository,
        settings: delayed,
      );
      final record = RecordSettings(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoSettings(repository: repository, settings: delayed);
      addTearDown(playback.close);
      addTearDown(quantize.close);
      addTearDown(record.close);
      addTearDown(tempo.close);
      addTearDown(() {
        if (!delayed.ready.isCompleted) delayed.ready.complete();
      });
      final loads = Future.wait([
        playback.load(),
        quantize.load(),
        record.load(),
        tempo.load(),
      ]);
      await Future<void>.delayed(Duration.zero);
      await playback.setDefaultOneShot(value: false);
      final timingEdit = quantize.setEnabled(value: false);
      await record.setRecDub(value: false);
      await tempo.clickModeOwner.set(ClickMode.off);
      // Recording start has its own owner. Editing it must preserve the
      // independent Tempo preference read that is still pending.
      await tempo.recordStartControl.setCountInBars(0);
      delayed.ready.complete();
      await loads;
      await timingEdit;
      await poll();

      // An ordinary Once edit does not discard the independent saved Decay.
      expect(
        playback.state,
        const PlaybackOptions(
          overdubDecay: 80,
          decayReady: true,
          oneShotReady: true,
        ),
      );
      expect(quantize.state.defaultTiming, RecordTiming.immediately);
      expect(record.state, const RecordOptions(recordLengthReady: true));
      expect(
        tempo.state,
        const TempoState(
          bpm: 120,
          clickReady: true,
          clickModeReady: true,
          recordStartReady: true,
        ),
      );
      expect(repository.sessionTransport.overdubDecay, 80);
      expect(repository.sessionTransport.defaultOneShot, isFalse);
      expect(repository.sessionTransport.defaultMultiple, 0);
      expect(repository.sessionTransport.tempoBpm, 120);
    },
  );

  test(
    'a Hear click edit preserves independent pending Tempo preferences',
    () async {
      final delayed = await delayedSettings();
      final tempo = TempoSettings(repository: repository, settings: delayed);
      addTearDown(tempo.close);
      addTearDown(() {
        if (!delayed.ready.isCompleted) delayed.ready.complete();
      });
      final loading = tempo.load();
      await Future<void>.delayed(Duration.zero);

      expect((await tempo.clickModeOwner.set(ClickMode.off)).isOk, isTrue);
      expect(tempo.clickModeControl.clickModeSnapshot?.mode, ClickMode.off);
      expect(tempo.state.bpm, 0);
      expect(tempo.state.countInBars, 2);
      // Click volume loads independently of the delayed tempo grid.
      expect(tempo.state.clickReady, isTrue);

      delayed.ready.complete();
      await loading;
      await poll();
      expect(
        tempo.state,
        const TempoState(
          bpm: 120,
          countInBars: 2,
          recordStartReady: true,
          clickReady: true,
          clickModeReady: true,
        ),
      );
      expect(repository.sessionTransport.tempoBpm, 120);
      expect(repository.sessionTransport.countInBars, 2);
      expect(repository.sessionTransport.clickMode, ClickMode.off);
      expect(await delayed.loadTempoBpm(), 120);
      expect((await delayed.readRecordStartCheckpoint()).countInBars, 2);
      expect(await delayed.readClickModeCheckpoint(), 0);
    },
  );

  test(
    'a Sound start edit preserves independent delayed Tempo preferences',
    () async {
      final delayed = await delayedSettings();
      final record = RecordSettings(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoSettings(repository: repository, settings: delayed);
      addTearDown(record.close);
      addTearDown(tempo.close);
      final loading = tempo.load();
      await Future<void>.delayed(Duration.zero);
      expect(
        (await tempo.recordStartControl.setSoundStart(enabled: false)).isOk,
        isTrue,
      );
      delayed.ready.complete();
      await loading;
      await poll();

      expect(tempo.state.bpm, 120);
      expect(tempo.state.countInBars, 2);
      expect(tempo.state.soundStart, isFalse);
      expect(repository.sessionTransport.countInBars, 2);
    },
  );

  test('only Tempo restores the coupled startup start methods', () async {
    await settings.saveRecordStartSettings(countInBars: 2, soundStart: false);
    final record = RecordSettings(
      repository: repository,
      settings: settings,
    );
    final tempo = TempoSettings(repository: repository, settings: settings);
    addTearDown(record.close);
    addTearDown(tempo.close);
    await Future.wait([record.load(), tempo.load()]);
    await poll();
    expect(tempo.state.countInBars, 2);
    expect(tempo.state.soundStart, isFalse);
    expect(tempo.state.recordStartReady, isTrue);
    expect(repository.sessionTransport.countInBars, 2);
    expect(repository.sessionTransport.autoRecord, isFalse);
  });

  test(
    'contradictory saved start methods require recovery without coercion',
    () async {
      final store = FakeKeyValueStore()
        ..values['tempo.count_in_bars'] = 2
        ..values['looper.auto_record'] = true;
      final invalid = SettingsRepository(store: store);
      final record = RecordSettings(
        repository: repository,
        settings: invalid,
      );
      final tempo = TempoSettings(repository: repository, settings: invalid);
      addTearDown(record.close);
      addTearDown(tempo.close);
      await Future.wait([record.load(), tempo.load()]);
      await poll();
      expect(tempo.recordStartControl.recordStartSnapshot, isNull);
      expect(tempo.state.recordStartReady, isFalse);
      expect(store.values['tempo.count_in_bars'], 2);
      expect(store.values['looper.auto_record'], isTrue);
    },
  );

  test(
    'offline playback defaults survive polling, recall and explicit reset',
    () async {
      final owner = (() => PlaybackSettings(
        repository: repository,
        settings: settings,
      ))();
      addTearDown(owner.close);
      await ((PlaybackSettings cubit) async {
        await cubit.load();
        await cubit.setOverdubDecay(40);
        await cubit.setDefaultOneShot(value: true);
        await poll();
        expect(
          cubit.state,
          const PlaybackOptions(
            overdubDecay: 40,
            defaultOneShot: true,
            decayReady: true,
            oneShotReady: true,
          ),
        );

        await repository.applySession(const SessionRig(overdubDecay: 75));
        await poll();
        expect(
          cubit.state,
          const PlaybackOptions(
            overdubDecay: 75,
            decayReady: true,
            oneShotReady: true,
          ),
        );
        await cubit.load();
        expect(
          cubit.state,
          const PlaybackOptions(
            overdubDecay: 75,
            decayReady: true,
            oneShotReady: true,
          ),
        );
        expect(await settings.readDecayCheckpoint(channel: null), 40);
        expect(await settings.readOneShotCheckpoint(channel: null), isTrue);

        await repository.applySession(const SessionRig());
        await poll();
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((PlaybackSettings cubit) => expect(
        cubit.state,
        const PlaybackOptions(decayReady: true, oneShotReady: true),
      ))(owner);
    },
  );

  late RecordTimingSettings timingOwner;
  blocTest<RecordTimingCubit, RecordTimingState>(
    'offline quantize follows recalled timing and toggles from that value',
    build: () {
      timingOwner = RecordTimingSettings(
        repository: repository,
        settings: settings,
      );
      addTearDown(timingOwner.close);
      return RecordTimingCubit(settings: timingOwner);
    },
    act: (cubit) async {
      await timingOwner.load();
      await cubit.setEnabled(value: true);
      await poll();
      expect(cubit.state.defaultTiming, RecordTiming.loopStart);

      await repository.applySession(const SessionRig());
      await poll();
      expect(cubit.state.defaultTiming, RecordTiming.immediately);
      expect((await settings.readRecordTimingCheckpoint()).quantize, isTrue);
      await timingOwner.load();
      await cubit.setEnabled(value: true);
      await poll();
    },
    verify: (cubit) {
      expect(cubit.state.defaultTiming, RecordTiming.loopStart);
      expect(repository.sessionTransport.quantize, isTrue);
    },
  );

  test(
    'offline count-in and Sound edits use the same confirmed owner',
    () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) async {
        await cubit.load();
        expect(
          (await cubit.recordStartControl.setSoundStart(enabled: true)).isOk,
          isTrue,
        );
        await poll();
        expect(cubit.state.soundStart, isTrue);
        expect(cubit.state.countInBars, 0);
        expect((await cubit.recordStartControl.setCountInBars(2)).isOk, isTrue);
        await poll();
        expect(cubit.state.soundStart, isFalse);
        expect(cubit.state.countInBars, 2);
        expect(await settings.readRecordStartCheckpoint(), (
          countInBars: 2,
          soundStart: false,
        ));
        expect(
          (await cubit.recordStartControl.setSoundStart(enabled: true)).isOk,
          isTrue,
        );
        await poll();
        expect(cubit.state.countInBars, 0);
        expect(await settings.readRecordStartCheckpoint(), (
          countInBars: 0,
          soundStart: true,
        ));
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((TempoSettings cubit) {
        expect(cubit.state.soundStart, isTrue);
        expect(repository.sessionTransport.autoRecord, isTrue);
        expect(repository.sessionTransport.countInBars, 0);
      })(owner);
    },
  );

  test('offline musical settings follow full recall and reset', () async {
    final owner = (() =>
        TempoSettings(repository: repository, settings: settings))();
    addTearDown(owner.close);
    await ((TempoSettings cubit) async {
      await cubit.load();
      await cubit.setTempo(120);
      await cubit.recordStartControl.setCountInBars(1);
      await poll();
      expect(cubit.state.bpm, 120);
      expect(cubit.state.countInBars, 1);

      await repository.applySession(
        const SessionRig(
          tempoBpm: 96,
          tempoSource: TempoSource.manual,
          tsNum: 5,
          tsDen: 8,
          syncTempo: false,
          recordTiming: RecordTiming.eighth,
          quantizeDiv: GridDivision.eighth,
          clickMode: ClickMode.playRec,
          clickMask: 3,
          clickVolume: 0.5,
          countInBars: 2,
        ),
      );
      await poll();
      expect(
        cubit.state,
        const TempoState(
          bpm: 96,
          tsNum: 5,
          tsDen: 8,
          clickMode: ClickMode.playRec,
          clickModeReady: true,
          clickOutputMask: 3,
          clickVolume: 0.5,
          clickReady: true,
          countInBars: 2,
          recordStartReady: true,
        ),
      );
      expect(await settings.loadTempoBpm(), 120);
      expect((await settings.readRecordStartCheckpoint()).countInBars, 1);
      await cubit.load();
      expect(cubit.state.bpm, 96);

      await repository.applySession(const SessionRig());
      await poll();
    })(owner);
    await Future<void>.delayed(Duration.zero);
    await owner.close();
    ((TempoSettings cubit) => expect(
      cubit.state,
      const TempoState(
        clickReady: true,
        clickModeReady: true,
        recordStartReady: true,
      ),
    ))(owner);
  });

  test(
    'rapid start-method edits persist the last choice in both directions',
    () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) async {
        await cubit.load();
        final first = await Future.wait([
          cubit.recordStartControl.setSoundStart(enabled: true),
          cubit.recordStartControl.setCountInBars(2),
        ]);
        expect(first.every((outcome) => outcome.isOk), isTrue);
        await poll();
        expect(cubit.state.soundStart, isFalse);
        expect(cubit.state.countInBars, 2);
        expect(await settings.readRecordStartCheckpoint(), (
          countInBars: 2,
          soundStart: false,
        ));
        final second = await Future.wait([
          cubit.recordStartControl.setCountInBars(1),
          cubit.recordStartControl.setSoundStart(enabled: true),
        ]);
        expect(second.every((outcome) => outcome.isOk), isTrue);
        await poll();
        expect(cubit.state.countInBars, 0);
        expect(await settings.readRecordStartCheckpoint(), (
          countInBars: 0,
          soundStart: true,
        ));
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((TempoSettings cubit) => expect(cubit.state.soundStart, isTrue))(owner);
    },
  );
}
