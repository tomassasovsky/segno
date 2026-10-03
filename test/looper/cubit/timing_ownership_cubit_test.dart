import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/looper.dart';
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
    await delayed.saveOverdubDecay(80);
    await delayed.saveDefaultOneShot(oneShot: true);
    await delayed.saveQuantize(value: true);
    await delayed.saveRecDub(value: true);
    await delayed.saveDefaultMultiple(4);
    await delayed.saveTempoBpm(120);
    await delayed.saveCountInBars(2);
    return delayed;
  }

  test(
    'a session recall wins while all startup preference reads are pending',
    () async {
      final delayed = await delayedSettings();
      final playback = PlaybackOptionsCubit(
        repository: repository,
        settings: delayed,
      );
      final quantize = RecordTimingCubit(
        repository: repository,
        settings: delayed,
      );
      final record = RecordOptionsCubit(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoCubit(repository: repository, settings: delayed);
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
        const RecordOptions(autoRecord: true, recordLengthReady: true),
      );
      expect(
        tempo.state,
        const TempoSettings(
          bpm: 96,
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
        const RecordOptions(autoRecord: true, recordLengthReady: true),
      );
      expect(
        tempo.state,
        const TempoSettings(
          bpm: 96,
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
      final playback = PlaybackOptionsCubit(
        repository: repository,
        settings: delayed,
      );
      final quantize = RecordTimingCubit(
        repository: repository,
        settings: delayed,
      );
      final record = RecordOptionsCubit(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoCubit(repository: repository, settings: delayed);
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
      await tempo.setClickMode(ClickMode.off);
      // Hear click has independent initialization. A matching start-method
      // edit still supersedes the pending generic Tempo restore.
      await tempo.setCountInBars(0);
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
      expect(tempo.state, const TempoSettings(clickModeReady: true));
      expect(repository.sessionTransport.overdubDecay, 80);
      expect(repository.sessionTransport.defaultOneShot, isFalse);
      expect(repository.sessionTransport.defaultMultiple, 0);
      expect(repository.sessionTransport.tempoBpm, 0);
    },
  );

  test(
    'a Hear click edit preserves independent pending Tempo preferences',
    () async {
      final delayed = await delayedSettings();
      final tempo = TempoCubit(repository: repository, settings: delayed);
      addTearDown(tempo.close);
      addTearDown(() {
        if (!delayed.ready.isCompleted) delayed.ready.complete();
      });
      final loading = tempo.load();
      await Future<void>.delayed(Duration.zero);

      expect((await tempo.setClickMode(ClickMode.off)).isOk, isTrue);
      expect(tempo.clickModeSnapshot?.mode, ClickMode.off);
      expect(tempo.state.bpm, 0);
      expect(tempo.state.countInBars, 0);
      expect(tempo.state.clickReady, isFalse);

      delayed.ready.complete();
      await loading;
      await poll();
      expect(
        tempo.state,
        const TempoSettings(
          bpm: 120,
          countInBars: 2,
          clickReady: true,
          clickModeReady: true,
        ),
      );
      expect(repository.sessionTransport.tempoBpm, 120);
      expect(repository.sessionTransport.countInBars, 2);
      expect(repository.sessionTransport.clickMode, ClickMode.off);
      expect(await delayed.loadTempoBpm(), 120);
      expect(await delayed.loadCountInBars(), 2);
      expect(await delayed.readClickModeCheckpoint(), 0);
    },
  );

  test(
    'a matching Sound start edit invalidates delayed count-in restore',
    () async {
      final delayed = await delayedSettings();
      final record = RecordOptionsCubit(
        repository: repository,
        settings: delayed,
      );
      final tempo = TempoCubit(repository: repository, settings: delayed);
      addTearDown(record.close);
      addTearDown(tempo.close);
      final loading = tempo.load();
      await Future<void>.delayed(Duration.zero);
      await record.setAutoRecord(value: false);
      delayed.ready.complete();
      await loading;
      await poll();

      expect(tempo.state.bpm, 120);
      expect(tempo.state.countInBars, 0);
      expect(record.state.autoRecord, isFalse);
      expect(repository.sessionTransport.countInBars, 0);
    },
  );

  test('only Tempo restores the coupled startup start methods', () async {
    await settings.saveAutoRecord(value: true);
    await settings.saveCountInBars(2);
    final record = RecordOptionsCubit(
      repository: repository,
      settings: settings,
    );
    final tempo = TempoCubit(repository: repository, settings: settings);
    addTearDown(record.close);
    addTearDown(tempo.close);
    await Future.wait([record.load(), tempo.load()]);
    await poll();
    expect(tempo.state.countInBars, 2);
    expect(record.state.autoRecord, isFalse);
    expect(repository.sessionTransport.countInBars, 2);
    expect(repository.sessionTransport.autoRecord, isFalse);
  });

  blocTest<PlaybackOptionsCubit, PlaybackOptions>(
    'offline playback defaults survive polling, recall and explicit reset',
    build: () => PlaybackOptionsCubit(
      repository: repository,
      settings: settings,
    ),
    act: (cubit) async {
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
      expect(await settings.loadOverdubDecay(), 40);
      expect(await settings.loadDefaultOneShot(), isTrue);

      await repository.applySession(const SessionRig());
      await poll();
    },
    verify: (cubit) => expect(
      cubit.state,
      const PlaybackOptions(decayReady: true, oneShotReady: true),
    ),
  );

  blocTest<RecordTimingCubit, RecordTimingState>(
    'offline quantize follows recalled timing and toggles from that value',
    build: () => RecordTimingCubit(
      repository: repository,
      settings: settings,
    ),
    act: (cubit) async {
      await cubit.load();
      await cubit.setEnabled(value: true);
      await poll();
      expect(cubit.state.defaultTiming, RecordTiming.loopStart);

      await repository.applySession(const SessionRig());
      await poll();
      expect(cubit.state.defaultTiming, RecordTiming.immediately);
      expect(await settings.loadQuantize(), isTrue);
      await cubit.load();
      await cubit.setEnabled(value: true);
      await poll();
    },
    verify: (cubit) {
      expect(cubit.state.defaultTiming, RecordTiming.loopStart);
      expect(repository.sessionTransport.quantize, isTrue);
    },
  );

  blocTest<RecordOptionsCubit, RecordOptions>(
    'offline count-in and Sound start clear each other in both controls',
    build: () => RecordOptionsCubit(repository: repository, settings: settings),
    act: (cubit) async {
      final tempo = TempoCubit(repository: repository, settings: settings);
      addTearDown(tempo.close);
      await Future.wait([cubit.load(), tempo.load()]);

      await cubit.setAutoRecord(value: true);
      await poll();
      expect(cubit.state.autoRecord, isTrue);
      expect(tempo.state.countInBars, 0);

      await tempo.setCountInBars(2);
      await poll();
      expect(cubit.state.autoRecord, isFalse);
      expect(tempo.state.countInBars, 2);
      expect(await settings.loadAutoRecord(), isFalse);

      await cubit.setAutoRecord(value: true);
      await poll();
      expect(tempo.state.countInBars, 0);
      expect(await settings.loadCountInBars(), 0);
    },
    verify: (cubit) {
      expect(cubit.state.autoRecord, isTrue);
      expect(repository.sessionTransport.autoRecord, isTrue);
      expect(repository.sessionTransport.countInBars, 0);
    },
  );

  blocTest<TempoCubit, TempoSettings>(
    'offline musical settings follow full recall and reset',
    build: () => TempoCubit(repository: repository, settings: settings),
    act: (cubit) async {
      await cubit.load();
      await cubit.setTempo(120);
      await cubit.setCountInBars(1);
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
        const TempoSettings(
          bpm: 96,
          tsNum: 5,
          tsDen: 8,
          clickMode: ClickMode.playRec,
          clickModeReady: true,
          clickOutputMask: 3,
          clickVolume: 0.5,
          clickReady: true,
          countInBars: 2,
        ),
      );
      expect(await settings.loadTempoBpm(), 120);
      expect(await settings.loadCountInBars(), 1);
      await cubit.load();
      expect(cubit.state.bpm, 96);

      await repository.applySession(const SessionRig());
      await poll();
    },
    verify: (cubit) => expect(
      cubit.state,
      const TempoSettings(clickReady: true, clickModeReady: true),
    ),
  );

  blocTest<RecordOptionsCubit, RecordOptions>(
    'rapid start-method edits persist the last choice in both directions',
    build: () => RecordOptionsCubit(repository: repository, settings: settings),
    act: (cubit) async {
      final tempo = TempoCubit(repository: repository, settings: settings);
      addTearDown(tempo.close);
      await Future.wait([cubit.load(), tempo.load()]);

      await Future.wait([
        cubit.setAutoRecord(value: true),
        tempo.setCountInBars(2),
      ]);
      await poll();
      expect(cubit.state.autoRecord, isFalse);
      expect(tempo.state.countInBars, 2);
      expect(await settings.loadAutoRecord(), isFalse);
      expect(await settings.loadCountInBars(), 2);

      await Future.wait([
        tempo.setCountInBars(1),
        cubit.setAutoRecord(value: true),
      ]);
      await poll();
      expect(tempo.state.countInBars, 0);
      expect(await settings.loadAutoRecord(), isTrue);
      expect(await settings.loadCountInBars(), 0);
    },
    verify: (cubit) => expect(cubit.state.autoRecord, isTrue),
  );
}
