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

  setUpAll(() => registerFallbackValue(RecordTiming.immediately));

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(
      () => repository.setRecordTiming(any()),
    ).thenReturn(EngineResult.ok);
  });

  RecordTimingCubit build() =>
      RecordTimingCubit(repository: repository, settings: settings);

  group('RecordTimingCubit', () {
    test('defaults to Immediately', () {
      expect(build().state, RecordTiming.immediately);
    });

    blocTest<RecordTimingCubit, RecordTiming>(
      'load restores the gate and division as one timing and applies it',
      setUp: () async {
        await settings.saveQuantize(value: true);
        await settings.saveQuantizeDiv(GridDivision.quarter.code);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [RecordTiming.quarter],
      verify: (_) => verify(
        () => repository.setRecordTiming(RecordTiming.quarter),
      ).called(1),
    );

    blocTest<RecordTimingCubit, RecordTiming>(
      'setTiming emits, applies once, and persists both keys',
      build: build,
      act: (cubit) => cubit.setTiming(RecordTiming.eighth),
      expect: () => [RecordTiming.eighth],
      verify: (_) async {
        verify(() => repository.setRecordTiming(RecordTiming.eighth)).called(1);
        expect(await settings.loadQuantize(), isTrue);
        expect(await settings.loadQuantizeDiv(), GridDivision.eighth.code);
      },
    );

    blocTest<RecordTimingCubit, RecordTiming>(
      'setEnabled keeps the division: on is the loop top with none set, off '
      'is Immediately',
      build: build,
      act: (cubit) async {
        await cubit.setEnabled(value: true);
        await cubit.setEnabled(value: false);
      },
      expect: () => [RecordTiming.loopStart, RecordTiming.immediately],
    );
  });
}
