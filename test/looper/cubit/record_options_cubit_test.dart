import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late StreamController<LooperState> looperStates;
  late int confirmedLength;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    confirmedLength = 0;
    registerFallbackValue(LooperMode.multi);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.recordLengthCaptureLocked).thenReturn(false);
    when(() => repository.lengthSettingsSettled).thenReturn(true);
    when(() => repository.lengthRecoveryRequired).thenReturn(false);
    when(
      () => repository.lengthSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.trackLengthPresetOverrides).thenReturn({});
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lengthRestartIntent).thenAnswer(
      (_) => (
        defaultBars: confirmedLength,
        trackOverrides: <int, int>{},
        mode: LooperMode.multi,
      ),
    );
    when(
      () => repository.setLengthSettings(
        defaultBars: any(named: 'defaultBars'),
        overrides: any(named: 'overrides'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((call) {
      confirmedLength = call.namedArguments[#defaultBars] as int;
      return EngineResult.ok;
    });
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(defaultLengthPresetBars: confirmedLength),
    );
    when(
      () => repository.settleLengthSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
      confirmedLength = call.positionalArguments.single as int;
      return EngineResult.ok;
    });
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
  });

  tearDown(() => looperStates.close());

  RecordOptionsCubit build() =>
      RecordOptionsCubit(repository: repository, settings: settings);

  group('RecordOptionsCubit', () {
    test('defaults to RecDub off', () {
      expect(build().state, const RecordOptions());
    });

    blocTest<RecordOptionsCubit, RecordOptions>(
      'load restores persisted options and applies them',
      setUp: () async {
        await settings.saveRecDub(value: true);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const RecordOptions(recDub: true),
        const RecordOptions(recDub: true, recordLengthReady: true),
      ],
      verify: (_) {
        verify(() => repository.setRecDub(enabled: true)).called(1);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setRecDub emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setRecDub(value: true),
      expect: () => [const RecordOptions(recDub: true)],
      verify: (_) async {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        expect(await settings.loadRecDub(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setDefaultMultiple emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setDefaultMultiple(2),
      expect: () => [const RecordOptions(defaultMultiple: 2)],
      verify: (_) async {
        verify(() => repository.setDefaultMultiple(multiple: 2)).called(1);
        expect(await settings.loadDefaultMultiple(), 2);
      },
    );
    blocTest<RecordOptionsCubit, RecordOptions>(
      'setDefaultLengthBars emits, persists and applies the clamped default',
      build: build,
      act: (cubit) => cubit.setDefaultLengthBars(80),
      expect: () => [
        const RecordOptions(recordLengthReady: true),
        const RecordOptions(defaultLengthBars: 64, recordLengthReady: true),
      ],
      verify: (_) async {
        expect(await settings.loadDefaultLengthPreset(), 64);
        verify(() => repository.setDefaultLengthPreset(64)).called(1);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'late length refusal keeps the displayed and saved default',
      setUp: () => when(
        () => repository.settleLengthSettings(),
      ).thenAnswer((_) async => EngineResult.invalid),
      build: build,
      act: (cubit) => cubit.setDefaultLengthBars(8),
      expect: () => <RecordOptions>[],
      verify: (_) async => expect(await settings.loadDefaultLengthPreset(), 0),
    );

    test(
      'an accepted length still persists after a rejected tap and RecDub edit',
      () async {
        final pending = Completer<EngineResult>();
        when(() => repository.setDefaultLengthPreset(any())).thenAnswer((
          call,
        ) {
          final bars = call.positionalArguments.single as int;
          return bars == 8 ? EngineResult.ok : EngineResult.notReady;
        });
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) => pending.future);
        final cubit = build();
        addTearDown(cubit.close);

        // Initialize before withholding the transaction receipt.
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) async => EngineResult.ok);
        await cubit.load();
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) => pending.future);
        final accepted = cubit.setDefaultLengthBars(8);
        final rejected = cubit.setDefaultLengthBars(12);
        await Future<void>.delayed(Duration.zero);
        await cubit.setRecDub(value: true);
        confirmedLength = 8;
        pending.complete(EngineResult.ok);
        await accepted;
        await rejected;

        expect(cubit.state.defaultLengthBars, 8);
        expect(cubit.state.recDub, isTrue);
        expect(await settings.loadDefaultLengthPreset(), 8);
        expect(await settings.loadRecDub(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'follows the repository before load without overwriting saved defaults',
      setUp: () => settings.saveRecDub(value: true),
      build: build,
      act: (cubit) async {
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [const RecordOptions()],
      verify: (_) async => expect(await settings.loadRecDub(), isTrue),
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'explicit matching values still reach the repository',
      build: build,
      act: (cubit) async {
        await cubit.setRecDub(value: false);
        await cubit.setDefaultMultiple(0);
      },
      expect: () => [const RecordOptions()],
      verify: (_) {
        verify(() => repository.setRecDub(enabled: false)).called(1);
        verify(() => repository.setDefaultMultiple(multiple: 0)).called(1);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'refused edits preserve displayed and saved recording options',
      setUp: () {
        when(
          () => repository.setRecDub(enabled: true),
        ).thenReturn(EngineResult.invalid);
        when(
          () => repository.setDefaultMultiple(multiple: 2),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) async {
        await cubit.setRecDub(value: true);
        await cubit.setDefaultMultiple(2);
      },
      expect: () => <RecordOptions>[],
      verify: (_) async {
        expect(await settings.loadRecDub(), isFalse);
        expect(await settings.loadDefaultMultiple(), 0);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'follows recalled and reset recording defaults',
      build: build,
      act: (_) async {
        looperStates.add(
          const LooperState(
            transport: TransportState(
              recDub: true,
              defaultMultiple: 3,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        const RecordOptions(recDub: true, defaultMultiple: 3),
        const RecordOptions(),
      ],
      verify: (_) async {
        expect(await settings.loadRecDub(), isFalse);
        expect(await settings.loadDefaultMultiple(), 0);
      },
    );
  });
}
