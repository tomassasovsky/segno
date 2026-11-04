import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

void main() {
  group('InterfaceInputs', () {
    const caps = InterfaceInputs(
      status: InterfaceInputsStatus.controls,
      inputs: [
        InterfaceInput(level: InputLevel.inst, pad: false, phantomSwitch: 0),
        InterfaceInput(level: InputLevel.line, phantomSwitch: 0),
      ],
      phantomSwitches: [PhantomSwitch(firstInput: 0, lastInput: 1, on: true)],
    );

    test('an input past the ones described has nothing to set', () {
      expect(caps.inputAt(2), InterfaceInput.none);
      expect(caps.inputAt(-1), InterfaceInput.none);
      expect(InterfaceInput.none.hasSwitches, isFalse);
      expect(caps.inputAt(1).hasSwitches, isTrue);
    });

    test('names the 48 V switch that powers an input', () {
      expect(caps.phantomFor(1), caps.phantomSwitches.single);
      expect(caps.phantomFor(1)!.powers(0), isTrue);
      expect(caps.phantomFor(1)!.powers(2), isFalse);
      expect(caps.phantomFor(2), isNull);
    });
  });

  group('LooperRepository interface inputs', () {
    late FakeAudioEngine engineFake;
    late LooperRepository repository;

    setUp(() {
      engineFake = FakeAudioEngine();
      repository = LooperRepository(engine: engineFake);
      addTearDown(repository.dispose);
    });

    /// Starts the engine on capture device ':2,0' with the device present.
    void open() {
      expect(
        repository.startEngine(const EngineConfig(captureDeviceId: ':2,0')),
        EngineResult.ok,
      );
      engineFake.nextSnapshot = engineFake.nextSnapshot.copyWith(
        isRunning: true,
        devicePresent: true,
      );
    }

    test(
      'before the engine opened a device: nothing read, nothing set',
      () async {
        expect(await repository.readInterfaceInputs(), InterfaceInputs.none);
        expect(
          await repository.setInterfacePhantomPower(0, on: true),
          EngineResult.notRunning,
        );
        expect(engineFake.interfaceInputReads, isEmpty);
        expect(engineFake.interfaceInputWrites, isEmpty);
      },
    );

    test('reads the open capture device and maps every switch', () async {
      open();
      engineFake.interfaceInputs = const engine.InterfaceInputsInfo(
        state: engine.InterfaceInputsState.controls,
        inputs: [
          engine.InterfaceInputInfo(
            level: 1,
            pad: 0,
            air: 2,
            airChoices: 3,
            phantomGroup: 0,
          ),
          engine.InterfaceInputInfo(level: 0, air: 1, airChoices: 2),
          engine.InterfaceInputInfo(),
        ],
        phantom: [engine.PhantomSwitchInfo(first: 0, last: 0, on: false)],
        adapter: 'scarlett2',
      );
      expect(
        await repository.readInterfaceInputs(),
        const InterfaceInputs(
          status: InterfaceInputsStatus.controls,
          inputs: [
            InterfaceInput(
              level: InputLevel.inst,
              pad: false,
              air: InputAir.presenceDrive,
              airThreeWay: true,
              phantomSwitch: 0,
            ),
            InterfaceInput(level: InputLevel.line, air: InputAir.presence),
            InterfaceInput.none,
          ],
          phantomSwitches: [
            PhantomSwitch(firstInput: 0, lastInput: 0, on: false),
          ],
        ),
      );
      expect(engineFake.interfaceInputReads, [':2,0']);
    });

    test('a device that is not open is never reached', () async {
      open();
      engineFake.nextSnapshot = engineFake.nextSnapshot.copyWith(
        devicePresent: false,
      );
      expect(await repository.readInterfaceInputs(), InterfaceInputs.none);
      expect(
        await repository.setInterfacePhantomPower(0, on: true),
        EngineResult.notRunning,
      );
      engineFake.nextSnapshot = engineFake.nextSnapshot.copyWith(
        isRunning: false,
        devicePresent: true,
      );
      expect(await repository.readInterfaceInputs(), InterfaceInputs.none);
      expect(engineFake.interfaceInputReads, isEmpty);
      expect(engineFake.interfaceInputWrites, isEmpty);
    });

    test('maps the setup-mode states', () async {
      open();
      engineFake.interfaceInputs = const engine.InterfaceInputsInfo(
        state: engine.InterfaceInputsState.setupMode,
      );
      expect(
        (await repository.readInterfaceInputs()).status,
        InterfaceInputsStatus.setupMode,
      );
      engineFake.interfaceInputs = const engine.InterfaceInputsInfo(
        state: engine.InterfaceInputsState.setupModeRestart,
      );
      expect(
        (await repository.readInterfaceInputs()).status,
        InterfaceInputsStatus.setupModeRestart,
      );
    });

    test('each setter writes its control to the open capture device', () async {
      open();
      expect(
        await repository.setInterfaceInputLevel(0, InputLevel.inst),
        EngineResult.ok,
      );
      await repository.setInterfaceInputLevel(1, InputLevel.line);
      await repository.setInterfaceInputPad(1, on: true);
      await repository.setInterfaceInputAir(0, InputAir.presenceDrive);
      await repository.setInterfacePhantomPower(0, on: false);
      await repository.turnOffInterfaceSetupMode();
      expect(engineFake.interfaceInputWrites, [
        (':2,0', engine.InterfaceControl.level, 0, 1),
        (':2,0', engine.InterfaceControl.level, 1, 0),
        (':2,0', engine.InterfaceControl.pad, 1, 1),
        (':2,0', engine.InterfaceControl.air, 0, 2),
        (':2,0', engine.InterfaceControl.phantom, 0, 0),
        (':2,0', engine.InterfaceControl.setupModeOff, 0, 0),
      ]);
    });

    test('passes a refused write through', () async {
      open();
      engineFake.interfaceInputResult = EngineResult.device;
      expect(
        await repository.setInterfaceInputPad(0, on: true),
        EngineResult.device,
      );
    });
  });
}
