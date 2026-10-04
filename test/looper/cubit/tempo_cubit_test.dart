import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
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
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
    when(() => repository.sessionTransport).thenAnswer((_) => accepted);
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
    when(() => repository.setClickMode(any())).thenAnswer((call) {
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
    when(() => repository.setClickVolume(any())).thenAnswer((call) {
      accepted = _updated(
        accepted,
        clickVolume: call.positionalArguments[0] as double,
      );
      return EngineResult.ok;
    });
  });

  group('TempoCubit', () {
    test('defaults to the tempo-free grid-off state', () {
      final cubit = TempoCubit(repository: repository, settings: settings);
      expect(cubit.state, const TempoSettings());
    });

    blocTest<TempoCubit, TempoSettings>(
      'load restores the persisted settings and applies every one of them '
      'to the repository',
      setUp: () async {
        await settings.saveTempoBpm(140);
        await settings.saveTimeSignature(7, 8);
        await settings.restoreClickModeCheckpoint(ClickMode.playRec.code);
        await settings.saveClickOutputMask(0x3);
        await settings.saveClickVolume(0.5);
        await settings.saveRecordStartSettings(
          countInBars: 2,
          soundStart: false,
        );
      },
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(
          cubit.state,
          const TempoSettings(
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
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'load with an unset (0) tempo does not push it to the engine',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      verify: (_) => verifyNever(() => repository.setTempo(any())),
    );

    blocTest<TempoCubit, TempoSettings>(
      'load is single-flight — a second call restores nothing new',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) async {
        await cubit.load();
        await cubit.load();
      },
      verify: (_) => verify(
        () => repository.setTimeSignature(any(), any()),
      ).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'refused edits preserve displayed settings and the saved start pair',
      setUp: () async {
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
          ),
        ).thenReturn(EngineResult.invalid);
      },
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) async {
        await cubit.setTempo(96);
        await cubit.setTimeSignature(5, 8);
        await cubit.setClickMode(ClickMode.rec);
        await cubit.setClickOutput(1);
        await cubit.setClickVolume(0.5);
        await cubit.setCountInBars(2);
      },
      expect: () => [
        const TempoSettings(
          clickMode: ClickMode.recFirst,
          clickModeReady: true,
        ),
        const TempoSettings(
          clickMode: ClickMode.recFirst,
          clickModeReady: true,
          soundStart: true,
          recordStartReady: true,
        ),
      ],
      verify: (_) async {
        expect(await settings.loadTempoBpm(), 0);
        expect(await settings.loadTimeSignature(), (4, 4));
        expect(await settings.readClickModeCheckpoint(), isNull);
        expect(await settings.loadClickOutputMask(), 0);
        expect(await settings.loadClickVolume(), 1);
        expect(
          await settings.readRecordStartCheckpoint(),
          (countInBars: 0, soundStart: true),
        );
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTempo emits, persists, and applies the new value',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTempo(96),
      expect: () => [const TempoSettings(bpm: 96)],
      verify: (_) async {
        expect(await settings.loadTempoBpm(), 96);
        verify(() => repository.setTempo(96)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTempo to the same value as the cache still calls the repository '
      '(no stale-cache-based early return)',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTempo(0),
      verify: (_) => verify(() => repository.setTempo(0)).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'a setter still calls the repository when its target value matches '
      "the cubit's cache but a bypass writer moved the LIVE state away from "
      'it in between (regression: pedal-toggle no-op bug)',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) async {
        // The cache now holds ClickMode.rec.
        await cubit.setClickMode(ClickMode.rec);
        clearInteractions(repository);
        // A bypass writer (e.g. LooperBloc._toggleMetronome, a pedal press)
        // moves the LIVE engine's click mode directly through the
        // repository — the real pedal path never touches this cubit, so
        // its cache still (wrongly) reads `rec`.
        repository.setClickMode(ClickMode.off);
        // The user opens Settings — which reads the LIVE TransportState,
        // not this stale cache (see TempoSettingsSection's class doc) —
        // sees "Off" and taps "Recording" to restore it. That target value
        // (`rec`) matches the cubit's stale cache exactly, so the old
        // guard (`newValue != state.field`) would have silently skipped
        // the repository call here.
        await cubit.setClickMode(ClickMode.rec);
      },
      verify: (_) =>
          verify(() => repository.setClickMode(ClickMode.rec)).called(1),
    );

    blocTest<TempoCubit, TempoSettings>(
      'setTimeSignature emits, persists, and applies the new signature',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setTimeSignature(5, 8),
      expect: () => [const TempoSettings(tsNum: 5, tsDen: 8)],
      verify: (_) async {
        expect(await settings.loadTimeSignature(), (5, 8));
        verify(() => repository.setTimeSignature(5, 8)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickMode emits, persists, and applies the new mode',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickMode(ClickMode.rec),
      expect: () => [
        const TempoSettings(
          clickMode: ClickMode.recFirst,
          clickModeReady: true,
        ),
        const TempoSettings(clickMode: ClickMode.rec, clickModeReady: true),
      ],
      verify: (_) async {
        expect(await settings.readClickModeCheckpoint(), ClickMode.rec.code);
        verify(() => repository.setClickMode(ClickMode.rec)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickOutput emits, persists, and applies the new mask',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickOutput(0x1),
      expect: () => [const TempoSettings(clickOutputMask: 0x1)],
      verify: (_) async {
        expect(await settings.loadClickOutputMask(), 0x1);
        verify(() => repository.setClickOutput(0x1)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setClickVolume emits, persists, and applies the new volume',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setClickVolume(0.75),
      expect: () => [const TempoSettings(clickVolume: 0.75, clickReady: true)],
      verify: (_) async {
        expect(await settings.loadClickVolume(), 0.75);
        verify(() => repository.setClickVolume(0.75)).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setCountInBars confirms and persists the full recording-start pair',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setCountInBars(2),
      verify: (_) async {
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
          ),
        ).called(1);
      },
    );

    blocTest<TempoCubit, TempoSettings>(
      'setCountInBars rejects an unsupported value without a write',
      build: () => TempoCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setCountInBars(-3),
      verify: (_) async {
        expect(
          await settings.readRecordStartCheckpoint(),
          (countInBars: null, soundStart: null),
        );
        verifyNever(
          () => repository.setRecordStartSettings(
            countInBars: -3,
            soundStart: false,
            editKind: RecordStartEditKind.countIn,
          ),
        );
      },
    );

    test('tapTempo forwards to the repository and is never persisted', () {
      final cubit = TempoCubit(repository: repository, settings: settings);

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

  blocTest<TempoCubit, TempoSettings>(
    'setting a count-in clears Sound in the confirmed and saved pair',
    setUp: () => settings.saveRecordStartSettings(
      countInBars: 0,
      soundStart: true,
    ),
    build: () => TempoCubit(repository: repository, settings: settings),
    act: (cubit) => cubit.setCountInBars(2),
    verify: (cubit) async {
      expect(cubit.confirmedRecordStart?.countInBars, 2);
      expect(cubit.confirmedRecordStart?.soundStart, isFalse);
      expect(
        await settings.readRecordStartCheckpoint(),
        (countInBars: 2, soundStart: false),
      );
    },
  );

  blocTest<TempoCubit, TempoSettings>(
    'follows a recalled count-in without changing startup settings',
    setUp: () => settings.saveRecordStartSettings(
      countInBars: 2,
      soundStart: false,
    ),
    build: () => TempoCubit(repository: repository, settings: settings),
    act: (cubit) async {
      await cubit.load();
      expect(cubit.state.countInBars, 2);
      accepted = _updated(accepted, countInBars: 0);
      looperStates.add(const LooperState());
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.countInBars, 0);
      expect(cubit.state.clickModeReady, isTrue);
    },
    verify: (_) async => expect(
      await settings.readRecordStartCheckpoint(),
      (countInBars: 2, soundStart: false),
    ),
  );

  blocTest<TempoCubit, TempoSettings>(
    'follows all recalled musical settings and a subsequent reset',
    build: () => TempoCubit(repository: repository, settings: settings),
    act: (cubit) async {
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
        const TempoSettings(
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
        const TempoSettings(
          clickReady: true,
          clickModeReady: true,
          countInBars: 1,
          recordStartReady: true,
        ),
      );
    },
    verify: (_) async {
      expect(await settings.loadTempoBpm(), 0);
      expect(await settings.loadQuantizeDiv(), GridDivision.off.code);
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
    },
  );
}
