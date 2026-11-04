import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/interface_inputs_cubit.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

const _scarlett = LooperState(
  status: EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 4i4 USB',
    sampleRate: 48000,
    inputChannels: 4,
  ),
);

const _closed = LooperState();

InterfaceInputs _fourI4({
  InputLevel level = InputLevel.line,
  bool on = false,
}) => InterfaceInputs(
  status: InterfaceInputsStatus.controls,
  inputs: [
    InterfaceInput(
      level: level,
      pad: false,
      air: InputAir.off,
      phantomSwitch: 0,
    ),
    const InterfaceInput(
      level: InputLevel.line,
      pad: false,
      air: InputAir.off,
      phantomSwitch: 0,
    ),
  ],
  phantomSwitches: [PhantomSwitch(firstInput: 0, lastInput: 1, on: on)],
);

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> engine;
  late InterfaceInputs onInterface;
  late int reads;
  late int generation;

  setUp(() {
    repository = _MockLooperRepository();
    engine = StreamController<LooperState>.broadcast();
    addTearDown(engine.close);
    onInterface = _fourI4();
    reads = 0;
    generation = 1;
    when(() => repository.looperState).thenAnswer((_) => engine.stream);
    when(() => repository.state).thenReturn(_scarlett);
    when(() => repository.mixGeneration).thenAnswer((_) => generation);
    when(() => repository.readInterfaceInputs()).thenAnswer((_) async {
      reads++;
      return onInterface;
    });
    when(
      () => repository.setInterfaceInputLevel(any(), any()),
    ).thenAnswer((invocation) async {
      final level = invocation.positionalArguments[1] as InputLevel;
      onInterface = _fourI4(level: level);
      return EngineResult.ok;
    });
    when(
      () => repository.setInterfacePhantomPower(any(), on: any(named: 'on')),
    ).thenAnswer((_) async => EngineResult.device);
    when(
      () => repository.setInterfaceInputPad(any(), on: any(named: 'on')),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setInterfaceInputAir(any(), any()),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.turnOffInterfaceSetupMode(),
    ).thenAnswer((_) async => EngineResult.ok);
  });

  setUpAll(() {
    registerFallbackValue(InputLevel.line);
    registerFallbackValue(InputAir.off);
  });

  InterfaceInputsCubit build() => InterfaceInputsCubit(repository: repository);

  group('InterfaceInputsCubit', () {
    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'reads the interface when a device is open',
      build: build,
      expect: () => [InterfaceInputsState(inputs: _fourI4(), loaded: true)],
      verify: (_) => expect(reads, 1),
    );

    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'reads nothing with no device open',
      setUp: () => when(() => repository.state).thenReturn(_closed),
      build: build,
      expect: () => <InterfaceInputsState>[],
      verify: (_) => expect(reads, 0),
    );

    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'a change shows what the interface holds after it',
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.setLevel(0, InputLevel.inst);
        await pumpEventQueue();
      },
      skip: 1,
      expect: () => [
        InterfaceInputsState(
          inputs: _fourI4(level: InputLevel.inst),
          loaded: true,
        ),
      ],
      verify: (_) {
        verify(() => repository.setInterfaceInputLevel(0, InputLevel.inst));
        expect(reads, 2);
      },
    );

    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'a refused change keeps the reported value and counts a failure',
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit.setPhantomPower(0, on: true);
        await pumpEventQueue();
      },
      skip: 1,
      expect: () => [
        InterfaceInputsState(
          inputs: _fourI4(),
          loaded: true,
          failures: 1,
          lastFailure: InterfaceSwitch.phantom,
        ),
      ],
      verify: (_) =>
          verify(() => repository.setInterfacePhantomPower(0, on: true)),
    );

    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'each setter reaches the repository',
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        cubit
          ..setPad(1, on: true)
          ..setAir(0, InputAir.presence)
          ..turnOffSetupMode();
        await pumpEventQueue();
      },
      verify: (_) {
        verify(() => repository.setInterfaceInputPad(1, on: true));
        verify(() => repository.setInterfaceInputAir(0, InputAir.presence));
        verify(() => repository.turnOffInterfaceSetupMode());
      },
    );

    blocTest<InterfaceInputsCubit, InterfaceInputsState>(
      'a device change drops the old state and reads the new device',
      build: build,
      act: (cubit) async {
        await pumpEventQueue();
        onInterface = InterfaceInputs.none;
        when(() => repository.state).thenReturn(_closed);
        engine.add(_closed);
        await pumpEventQueue();
        generation = 2;
        engine.add(_scarlett);
        await pumpEventQueue();
      },
      skip: 1,
      // Closing drops the old reading; the reopen's empty state equals it.
      expect: () => [
        const InterfaceInputsState(),
        const InterfaceInputsState(loaded: true),
      ],
      verify: (_) => expect(reads, 2),
    );

    test('a read for a device that has gone is dropped', () async {
      final slow = Completer<InterfaceInputs>();
      when(
        () => repository.readInterfaceInputs(),
      ).thenAnswer((_) => slow.future);
      final cubit = build();
      addTearDown(cubit.close);
      engine.add(_closed);
      await pumpEventQueue();
      slow.complete(_fourI4());
      await pumpEventQueue();
      expect(cubit.state, const InterfaceInputsState());
    });

    test('a watch read overtaken by a change read-back is dropped', () async {
      final first = Completer<InterfaceInputs>();
      var call = 0;
      when(() => repository.readInterfaceInputs()).thenAnswer((_) {
        call++;
        return call == 1 ? first.future : Future.value(onInterface);
      });
      final cubit = build();
      addTearDown(cubit.close);
      cubit.setLevel(0, InputLevel.inst);
      await pumpEventQueue();
      expect(cubit.state.inputs, _fourI4(level: InputLevel.inst));
      first.complete(_fourI4());
      await pumpEventQueue();
      expect(cubit.state.inputs, _fourI4(level: InputLevel.inst));
    });

    test('watches only between startWatching and stopWatching', () {
      fakeAsync((async) {
        final cubit = build();
        async.flushMicrotasks();
        expect(reads, 1);
        async.elapse(const Duration(seconds: 2));
        expect(reads, 1);

        cubit.startWatching();
        async.flushMicrotasks();
        expect(reads, 2);
        onInterface = _fourI4(level: InputLevel.inst);
        async.elapse(const Duration(milliseconds: 500));
        expect(reads, 3);
        expect(cubit.state.inputs, _fourI4(level: InputLevel.inst));
        async.elapse(const Duration(seconds: 1));
        expect(reads, 5);

        cubit.stopWatching();
        async.elapse(const Duration(seconds: 2));
        expect(reads, 5);
        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('closing stops the watch', () {
      fakeAsync((async) {
        final cubit = build()..startWatching();
        async.flushMicrotasks();
        final before = reads;
        unawaited(cubit.close());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2));
        expect(reads, before);
      });
    });
  });
}
