import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

TransportState _updated(
  TransportState prior, {
  double? tempoBpm,
  int? tsNum,
  int? tsDen,
  ClickMode? clickMode,
  int? clickMask,
  double? clickVolume,
  int? countInBars,
  bool? soundStart,
}) => TransportState(
  tempoBpm: tempoBpm ?? prior.tempoBpm,
  tsNum: tsNum ?? prior.tsNum,
  tsDen: tsDen ?? prior.tsDen,
  clickMode: clickMode ?? prior.clickMode,
  clickMask: clickMask ?? prior.clickMask,
  clickVolume: clickVolume ?? prior.clickVolume,
  countInBars: countInBars ?? prior.countInBars,
  autoRecord: soundStart ?? prior.autoRecord,
);

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late StreamController<LooperState> looperStates;
  late TransportState accepted;

  test(
    'failed startup remains visible but close disposes every owned stream',
    () async {
      final store = FakeKeyValueStore()..values['tempo.bpm'] = 'broken';
      final modeFailures = StreamController<EngineResult>.broadcast();
      final startFailures = StreamController<EngineResult>.broadcast();
      when(
        () => repository.clickModeFailures,
      ).thenAnswer((_) => modeFailures.stream);
      when(
        () => repository.recordStartSettingsFailures,
      ).thenAnswer((_) => startFailures.stream);
      final owner = TempoSettings(
        repository: repository,
        settings: SettingsRepository(store: store),
      );
      final done = <Future<void>>[
        owner.stream.drain<void>(),
        owner.clickModeOwner.failures.drain<void>(),
        owner.recordStartOwner.failures.drain<void>(),
        owner.clickVolumeOwner.failures.drain<void>(),
        owner.clickModeOwner.ordinaryChanges.drain<void>(),
        owner.clickVolumeOwner.ordinaryChanges.drain<void>(),
        owner.recordStartOwner.ordinaryChanges.drain<void>(),
      ];
      final loading = owner.load();
      await expectLater(loading, throwsA(isA<TypeError>()));
      expect(looperStates.hasListener, isTrue);
      expect(modeFailures.hasListener, isTrue);
      expect(startFailures.hasListener, isTrue);
      await owner.close();
      await Future.wait(done);
      expect(looperStates.hasListener, isFalse);
      expect(modeFailures.hasListener, isFalse);
      expect(startFailures.hasListener, isFalse);
      await owner.close();
      await expectLater(loading, throwsA(isA<TypeError>()));
      await modeFailures.close();
      await startFailures.close();
    },
  );

  setUpAll(() {
    registerFallbackValue(Duration.zero);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(RecordStartEditKind.restore);
  });

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    accepted = const TransportState();
    when(
      () => repository.clickModeFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.clickModeSettled).thenReturn(true);
    when(() => repository.clickModeRecoveryRequired).thenReturn(false);
    when(() => repository.clickModeCaptureLocked).thenReturn(false);
    when(
      () => repository.clickModeRestartIntent,
    ).thenAnswer((_) => accepted.clickMode);
    when(
      () => repository.settleClickMode(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.clickVolumeSettled).thenReturn(true);
    when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
    when(
      () => repository.clickVolumeFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => repository.clickVolumeRestartIntent,
    ).thenAnswer((_) => accepted.clickVolume);
    when(
      () => repository.settleClickVolume(
        pollInterval: any(named: 'pollInterval'),
        attempts: any(named: 'attempts'),
      ),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordStartSettingsSettled).thenReturn(true);
    when(() => repository.recordStartRecoveryRequired).thenReturn(false);
    when(() => repository.recordStartCaptureLocked).thenReturn(false);
    when(() => repository.recordStartSettings).thenAnswer(
      (_) =>
          (countInBars: accepted.countInBars, soundStart: accepted.autoRecord),
    );
    when(() => repository.recordStartRestartIntent).thenAnswer(
      (_) =>
          (countInBars: accepted.countInBars, soundStart: accepted.autoRecord),
    );
    when(repository.settleRecordStartSettings).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => repository.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
        releasedSettings: any(named: 'releasedSettings'),
      ),
    ).thenAnswer((call) {
      accepted = _updated(
        accepted,
        countInBars: call.namedArguments[#countInBars] as int,
        soundStart: call.namedArguments[#soundStart] as bool,
      );
      return EngineResult.ok;
    });
    looperStates = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => looperStates.stream);
    when(
      () => repository.sessionTransport,
    ).thenAnswer((_) => accepted);
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
    when(
      () => repository.setClickMode(any()),
    ).thenAnswer((call) {
      accepted = _updated(
        accepted,
        clickMode: call.positionalArguments[0] as ClickMode,
      );
      return EngineResult.ok;
    });
    when(() => repository.setTempo(any())).thenAnswer((call) {
      accepted = _updated(
        accepted,
        tempoBpm: call.positionalArguments[0] as double,
      );
      return EngineResult.ok;
    });
    when(() => repository.setTimeSignature(any(), any())).thenAnswer((call) {
      accepted = _updated(
        accepted,
        tsNum: call.positionalArguments[0] as int,
        tsDen: call.positionalArguments[1] as int,
      );
      return EngineResult.ok;
    });
    when(() => repository.setClickOutput(any())).thenAnswer((call) {
      accepted = _updated(
        accepted,
        clickMask: call.positionalArguments[0] as int,
      );
      return EngineResult.ok;
    });
    when(
      () => repository.setClickVolume(any()),
    ).thenAnswer((call) {
      accepted = _updated(
        accepted,
        clickVolume: call.positionalArguments[0] as double,
      );
      return EngineResult.ok;
    });
  });

  group('TempoSettings', () {
    test('defaults to the tempo-free grid-off state', () {
      final cubit = TempoSettings(repository: repository, settings: settings);
      expect(cubit.state, const TempoState());
    });

    test('load restores the persisted settings and applies every one of them '
        'to the repository', () async {
      await (() async {
        await settings.saveTempoBpm(140);
        await settings.saveTimeSignature(7, 8);
        await settings.restoreClickModeCheckpoint(ClickMode.playRec.code);
        await settings.saveClickOutputMask(0x3);
        await settings.restoreClickVolumeCheckpoint(0.5);
        await settings.saveRecordStartSettings(
          countInBars: 2,
          soundStart: false,
        );
      })();
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) => cubit.load())(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((TempoSettings cubit) {
        expect(
          cubit.state,
          const TempoState(
            bpm: 140,
            tsNum: 7,
            tsDen: 8,
            clickMode: ClickMode.playRec,
            clickOutputMask: 0x3,
            clickVolume: 0.5,
            clickReady: true,
            clickModeReady: true,
            countInBars: 2,
            recordStartReady: true,
          ),
        );
        verify(() => repository.setTempo(140)).called(1);
        verify(() => repository.setTimeSignature(7, 8)).called(1);
        verify(() => repository.setClickMode(ClickMode.playRec)).called(1);
        verify(() => repository.setClickOutput(0x3)).called(1);
        verify(() => repository.setClickVolume(0.5)).called(1);
        verify(
          () => repository.setRecordStartSettings(
            countInBars: 2,
            soundStart: false,
            editKind: RecordStartEditKind.restore,
          ),
        ).called(1);
      })(owner);
    });

    test(
      'load with an unset (0) tempo does not push it to the engine',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        await ((TempoSettings cubit) => cubit.load())(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        ((TempoSettings _) =>
            verifyNever(() => repository.setTempo(any())))(owner);
      },
    );

    test(
      'load is single-flight — a second call restores nothing new',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        await ((TempoSettings cubit) async {
          await cubit.load();
          await cubit.load();
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        ((TempoSettings _) => verify(
          () => repository.setTimeSignature(any(), any()),
        ).called(1))(owner);
      },
    );

    test(
      'refused edits preserve displayed settings and the saved start pair',
      () async {
        await (() async {
          await settings.saveRecordStartSettings(
            countInBars: 0,
            soundStart: true,
          );
          when(
            () => repository.setTempo(96),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setTimeSignature(5, 8),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setClickMode(ClickMode.rec),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setClickOutput(1),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setClickVolume(0.5),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setRecordStartSettings(
              countInBars: 2,
              soundStart: false,
              editKind: RecordStartEditKind.countIn,
              releasedSettings: (countInBars: 2, soundStart: false),
            ),
          ).thenReturn(EngineResult.invalid);
        })();
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        final states = <TempoState>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((TempoSettings cubit) async {
          await cubit.setTempo(96);
          await cubit.setTimeSignature(5, 8);
          await cubit.clickModeOwner.set(ClickMode.rec);
          await cubit.setClickOutput(1);
          await cubit.clickVolumeOwner.set(0.5);
          await cubit.recordStartControl.setCountInBars(2);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(
          states,
          (() => [
            const TempoState(
              clickMode: ClickMode.recFirst,
              clickModeReady: true,
            ),
            // The first Click write loads the owner, which confirms unity.
            const TempoState(
              clickMode: ClickMode.recFirst,
              clickModeReady: true,
              clickReady: true,
            ),
            const TempoState(
              clickMode: ClickMode.recFirst,
              clickModeReady: true,
              clickReady: true,
              soundStart: true,
              recordStartReady: true,
            ),
          ])(),
        );
        await ((TempoSettings _) async {
          expect(await settings.loadTempoBpm(), 0);
          expect(await settings.loadTimeSignature(), (4, 4));
          expect(await settings.readClickModeCheckpoint(), isNull);
          expect(await settings.loadClickOutputMask(), 0);
          expect(await settings.readClickVolumeCheckpoint(), isNull);
          expect(
            await settings.readRecordStartCheckpoint(),
            (countInBars: 0, soundStart: true),
          );
        })(owner);
      },
    );

    test('setTempo emits, persists, and applies the new value', () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      final states = <TempoState>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((TempoSettings cubit) => cubit.setTempo(96))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(states, (() => [const TempoState(bpm: 96)])());
      await ((TempoSettings _) async {
        expect(await settings.loadTempoBpm(), 96);
        verify(() => repository.setTempo(96)).called(1);
      })(owner);
    });

    test('setTempo to the same value as the cache still calls the repository '
        '(no stale-cache-based early return)', () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) => cubit.setTempo(0))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((TempoSettings _) =>
          verify(() => repository.setTempo(0)).called(1))(owner);
    });

    test('a setter still calls the repository when its target value matches '
        "the cubit's cache but a bypass writer moved the LIVE state away from "
        'it in between (regression: pedal-toggle no-op bug)', () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) async {
        // The cache now holds ClickMode.rec.
        await cubit.clickModeOwner.set(ClickMode.rec);
        clearInteractions(repository);
        // A bypass writer (e.g. LooperBloc._toggleMetronome, a pedal press)
        // moves the LIVE engine's click mode directly through the
        // repository — the real pedal path never touches this cubit, so
        // its cache still (wrongly) reads `rec`.
        repository.setClickMode(ClickMode.off);
        // The user opens Settings — which reads the LIVE TransportState,
        // not this stale cache (see TempoStateSection's class doc) —
        // sees "Off" and taps "Recording" to restore it. That target value
        // (`rec`) matches the cubit's stale cache exactly, so the old
        // guard (`newValue != state.field`) would have silently skipped
        // the repository call here.
        await cubit.clickModeOwner.set(ClickMode.rec);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      ((TempoSettings _) => verify(
        () => repository.setClickMode(ClickMode.rec),
      ).called(1))(owner);
    });

    test(
      'setTimeSignature emits, persists, and applies the new signature',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        final states = <TempoState>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((TempoSettings cubit) => cubit.setTimeSignature(5, 8))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const TempoState(tsNum: 5, tsDen: 8)])());
        await ((TempoSettings _) async {
          expect(await settings.loadTimeSignature(), (5, 8));
          verify(() => repository.setTimeSignature(5, 8)).called(1);
        })(owner);
      },
    );

    test('setClickMode emits, persists, and applies the new mode', () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      final states = <TempoState>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((TempoSettings cubit) =>
          cubit.clickModeOwner.set(ClickMode.rec))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(
        states,
        (() => [
          const TempoState(
            clickMode: ClickMode.recFirst,
            clickModeReady: true,
          ),
          const TempoState(clickMode: ClickMode.rec, clickModeReady: true),
        ])(),
      );
      await ((TempoSettings _) async {
        expect(await settings.readClickModeCheckpoint(), ClickMode.rec.code);
        verify(() => repository.setClickMode(ClickMode.rec)).called(1);
      })(owner);
    });

    test('setClickOutput emits, persists, and applies the new mask', () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      final states = <TempoState>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((TempoSettings cubit) => cubit.setClickOutput(0x1))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(states, (() => [const TempoState(clickOutputMask: 0x1)])());
      await ((TempoSettings _) async {
        expect(await settings.loadClickOutputMask(), 0x1);
        verify(() => repository.setClickOutput(0x1)).called(1);
      })(owner);
    });

    test(
      'setClickVolume emits, persists, and applies the new volume',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        final states = <TempoState>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((TempoSettings cubit) => cubit.clickVolumeOwner.set(0.75))(
          owner,
        );
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(
          states,
          (() => [
            // The write loads the owner first, which confirms unity.
            const TempoState(clickReady: true),
            const TempoState(clickVolume: 0.75, clickReady: true),
          ])(),
        );
        await ((TempoSettings _) async {
          expect(await settings.readClickVolumeCheckpoint(), 0.75);
          verify(() => repository.setClickVolume(0.75)).called(1);
        })(owner);
      },
    );

    test(
      'setCountInBars confirms and persists the full recording-start pair',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        await ((TempoSettings cubit) =>
            cubit.recordStartControl.setCountInBars(2))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        await ((TempoSettings _) async {
          expect(accepted.countInBars, 2);
          expect(accepted.autoRecord, isFalse);
          expect(
            await settings.readRecordStartCheckpoint(),
            (countInBars: 2, soundStart: false),
          );
          verify(
            () => repository.setRecordStartSettings(
              countInBars: 2,
              soundStart: false,
              editKind: RecordStartEditKind.countIn,
              releasedSettings: (countInBars: 2, soundStart: false),
            ),
          ).called(1);
        })(owner);
      },
    );

    test(
      'setCountInBars rejects an unsupported value without a write',
      () async {
        final owner = (() =>
            TempoSettings(repository: repository, settings: settings))();
        addTearDown(owner.close);
        await ((TempoSettings cubit) =>
            cubit.recordStartControl.setCountInBars(-3))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        await ((TempoSettings _) async {
          expect(
            await settings.readRecordStartCheckpoint(),
            (countInBars: null, soundStart: null),
          );
          verifyNever(
            () => repository.setRecordStartSettings(
              countInBars: -3,
              soundStart: false,
              editKind: RecordStartEditKind.countIn,
              releasedSettings: any(named: 'releasedSettings'),
            ),
          );
        })(owner);
      },
    );

    test('tapTempo forwards to the repository and is never persisted', () {
      final cubit = TempoSettings(repository: repository, settings: settings);

      final result = cubit.tapTempo();

      expect(result, EngineResult.ok);
      verify(repository.tapTempo).called(1);
    });
  });

  test(
    'kValidTimeSignatures has exactly the 17 Sheeran-verified signatures',
    () {
      expect(kValidTimeSignatures, hasLength(17));
      expect(
        kValidTimeSignatures.where((ts) => ts.$2 == 4).map((ts) => ts.$1),
        [2, 3, 4, 5, 6, 7],
      );
      expect(
        kValidTimeSignatures.where((ts) => ts.$2 == 8).map((ts) => ts.$1),
        [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      );
    },
  );

  tearDown(() => looperStates.close());

  test(
    'setting a count-in clears Sound in the confirmed and saved pair',
    () async {
      await (() => settings.saveRecordStartSettings(
        countInBars: 0,
        soundStart: true,
      ))();
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) =>
          cubit.recordStartControl.setCountInBars(2))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      await ((TempoSettings cubit) async {
        expect(cubit.recordStartControl.confirmedRecordStart?.countInBars, 2);
        expect(
          cubit.recordStartControl.confirmedRecordStart?.soundStart,
          isFalse,
        );
        expect(
          await settings.readRecordStartCheckpoint(),
          (countInBars: 2, soundStart: false),
        );
      })(owner);
    },
  );

  test(
    'follows a recalled count-in without changing startup settings',
    () async {
      await (() => settings.saveRecordStartSettings(
        countInBars: 2,
        soundStart: false,
      ))();
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) async {
        await cubit.load();
        expect(cubit.state.countInBars, 2);
        accepted = _updated(accepted, countInBars: 0);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.countInBars, 0);
        expect(cubit.state.clickModeReady, isTrue);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      await ((TempoSettings _) async => expect(
        await settings.readRecordStartCheckpoint(),
        (countInBars: 2, soundStart: false),
      ))(owner);
    },
  );

  test(
    'follows all recalled musical settings and a subsequent reset',
    () async {
      final owner = (() =>
          TempoSettings(repository: repository, settings: settings))();
      addTearDown(owner.close);
      await ((TempoSettings cubit) async {
        await cubit.load();
        accepted = _updated(
          accepted,
          tempoBpm: 96,
          tsNum: 5,
          tsDen: 8,
          clickMode: ClickMode.playRec,
          clickMask: 3,
          clickVolume: 0.5,
          countInBars: 2,
        );
        when(() => repository.sessionTransport).thenReturn(
          const TransportState(
            tempoBpm: 96,
            tsNum: 5,
            tsDen: 8,
            syncTempo: false,
            quantizeDiv: GridDivision.eighth,
            clickMode: ClickMode.playRec,
            clickMask: 3,
            clickVolume: 0.5,
            countInBars: 2,
          ),
        );
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state,
          const TempoState(
            bpm: 96,
            tsNum: 5,
            tsDen: 8,
            clickMode: ClickMode.playRec,
            clickOutputMask: 3,
            clickVolume: .5,
            clickReady: true,
            clickModeReady: true,
            countInBars: 2,
            recordStartReady: true,
          ),
        );
        accepted = _updated(
          const TransportState(),
          countInBars: 1,
        );
        when(() => repository.sessionTransport).thenReturn(accepted);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        await cubit.load();
        expect(
          cubit.state,
          const TempoState(
            clickReady: true,
            clickModeReady: true,
            countInBars: 1,
            recordStartReady: true,
          ),
        );
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      await ((TempoSettings _) async {
        expect(await settings.loadTempoBpm(), 0);
        expect(
          (await settings.readRecordTimingCheckpoint()).division,
          isNull,
        );
        expect(
          await settings.readRecordStartCheckpoint(),
          (countInBars: null, soundStart: null),
        );
        verify(
          () => repository.setRecordStartSettings(
            countInBars: 1,
            soundStart: false,
            editKind: RecordStartEditKind.restore,
          ),
        ).called(1);
      })(owner);
    },
  );
}
