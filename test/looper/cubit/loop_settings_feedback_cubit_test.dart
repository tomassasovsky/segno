import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/loop_settings_feedback_cubit.dart';

class _MockRepository extends Mock implements LooperRepository {}

void main() {
  late _MockRepository repository;
  late StreamController<EngineResult> failures;
  late StreamController<void> rigReplaced;
  late int sessionRevision;

  setUp(() {
    repository = _MockRepository();
    failures = StreamController<EngineResult>.broadcast();
    rigReplaced = StreamController<void>.broadcast();
    sessionRevision = 0;
    when(() => repository.sessionRevision).thenAnswer((_) => sessionRevision);
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => failures.stream,
    );
    when(() => repository.rigReplaced).thenAnswer((_) => rigReplaced.stream);
  });

  tearDown(() async {
    await failures.close();
    await rigReplaced.close();
  });

  blocTest<LoopSettingsFeedbackCubit, LoopSettingsFeedback>(
    'each refusal is visible, including consecutive identical failures',
    build: () => LoopSettingsFeedbackCubit(repository: repository),
    act: (_) => failures
      ..add(EngineResult.invalid)
      ..add(EngineResult.invalid)
      ..add(EngineResult.notReady),
    expect: () => [
      (refused: 1, sessionRevision: 0),
      (refused: 2, sessionRevision: 0),
      (refused: 3, sessionRevision: 0),
    ],
  );

  test(
    'rig replacement updates identity without reporting a refusal',
    () async {
      final cubit = LoopSettingsFeedbackCubit(repository: repository);
      addTearDown(cubit.close);
      sessionRevision = 1;
      rigReplaced.add(null);
      await pumpEventQueue();
      expect(cubit.state, (refused: 0, sessionRevision: 1));
    },
  );

  test('closing the page releases its failure subscription', () async {
    final cubit = LoopSettingsFeedbackCubit(repository: repository);
    expect(failures.hasListener, isTrue);
    expect(rigReplaced.hasListener, isTrue);
    await cubit.close();
    expect(failures.hasListener, isFalse);
    expect(rigReplaced.hasListener, isFalse);
    failures.add(EngineResult.invalid);
    await pumpEventQueue();
    expect(cubit.state, (refused: 0, sessionRevision: 0));
  });
}
