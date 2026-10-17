import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The reading owner (#1229): it follows the stored input and reference and
/// never arms the engine; the foot Tuner does.
void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;
  late TunerSettings settings;

  setUp(() {
    settings = TunerSettings(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(const LooperState());
  });

  tearDown(() async {
    await states.close();
    await settings.close();
  });

  TunerCubit build() => TunerCubit(repository: repository, settings: settings);

  LooperState reading(double hz, {double confidence = 1, int input = 0}) =>
      LooperState(
        tuner: TunerReading(hz: hz, confidence: confidence, input: input),
      );

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('never arms or moves the engine tuner', () async {
    final cubit = build();
    states
      ..add(reading(110))
      ..add(const LooperState(status: EngineStatus(inputChannels: 2)));
    await flush();
    await settings.setInput(1);
    await cubit.close();
    verifyNever(() => repository.setTunerInput(input: any(named: 'input')));
  });

  test('a disarmed tuner (input -1) reads as nothing', () async {
    final cubit = build();
    addTearDown(cubit.close);
    states.add(reading(110, input: -1));
    await flush();
    expect(cubit.state.hasReading, isFalse);
  });

  test(
    'resolves a confident reading on the followed input to a note',
    () async {
      final cubit = build();
      addTearDown(cubit.close);
      states.add(reading(110));
      await flush();
      expect(cubit.state.pitch!.note, 'A');
      expect(cubit.state.pitch!.octave, 2);
      expect(cubit.state.pitch!.isInTune, isTrue);
      expect(cubit.state.hz, 110);
    },
  );

  test('rejects a reading the engine is not confident about', () async {
    final cubit = build();
    addTearDown(cubit.close);
    states.add(reading(110, confidence: 0.2));
    await flush();
    expect(cubit.state.hasReading, isFalse);
  });

  test('holds the last note between picks, then lets it go on the clock '
      'alone (the repository emits only on change)', () {
    fakeAsync((async) {
      final local = StreamController<LooperState>.broadcast();
      when(() => repository.looperState).thenAnswer((_) => local.stream);
      final cubit = build();

      local.add(reading(110));
      async.flushMicrotasks();
      expect(cubit.state.pitch!.note, 'A');

      local.add(reading(0));
      async.flushMicrotasks();
      expect(cubit.state.pitch!.note, 'A');
      expect(cubit.state.isStale, isTrue);

      async.elapse(TunerCubit.holdFor + const Duration(milliseconds: 1));
      expect(cubit.state.hasReading, isFalse);
      expect(cubit.state.isStale, isFalse);

      unawaited(cubit.close());
      unawaited(local.close());
      async.flushMicrotasks();
    });
  });

  test('a reading from another input clears the held one at once', () async {
    final cubit = build();
    addTearDown(cubit.close);
    states.add(reading(110));
    await flush();
    expect(cubit.state.hasReading, isTrue);

    final emitted = <TunerState>[];
    final subscription = cubit.stream.listen(emitted.add);
    addTearDown(subscription.cancel);
    states.add(reading(220, input: 1));
    await flush();
    expect(emitted, hasLength(1));
    expect(emitted.single.hasReading, isFalse);
    expect(emitted.single.isStale, isFalse);
  });

  test('a reading is named against the stored A4 reference, and a '
      'reference change renames it at once', () async {
    await settings.setReference(432);
    final cubit = build();
    addTearDown(cubit.close);
    states.add(reading(432));
    await flush();
    expect(cubit.state.referenceHz, 432);
    expect(cubit.state.pitch!.isInTune, isTrue);

    await settings.setReference(440);
    expect(cubit.state.pitch!.isInTune, isFalse);
    expect(cubit.state.pitch!.cents, lessThan(-30));
  });

  test('follows the stored input, dropping the previous note', () async {
    final cubit = build();
    addTearDown(cubit.close);
    states.add(reading(110));
    await flush();
    await settings.setInput(1);
    expect(cubit.state.input, 1);
    expect(cubit.state.hasReading, isFalse);
    states.add(reading(220, input: 1));
    await flush();
    expect(cubit.state.pitch!.note, 'A');
  });

  test('never follows a loopback capture: it folds onto the first real '
      'input without touching the stored choice', () async {
    await settings.setInput(1);
    final cubit = build();
    addTearDown(cubit.close);
    states.add(
      const LooperState(
        status: EngineStatus(inputChannels: 4, excludedInputMask: 0x3),
      ),
    );
    await flush();
    expect(cubit.state.input, 2);
    expect(settings.live.input, 1);
  });

  test('every capture a loopback: nothing to follow', () async {
    final cubit = build();
    addTearDown(cubit.close);
    states.add(
      const LooperState(
        status: EngineStatus(inputChannels: 2, excludedInputMask: 0x3),
        tuner: TunerReading(hz: 110, confidence: 1, input: 0),
      ),
    );
    await flush();
    expect(cubit.state.input, -1);
    expect(cubit.state.hasReading, isFalse);
  });
}
