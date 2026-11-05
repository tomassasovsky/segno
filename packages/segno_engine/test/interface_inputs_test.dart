import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

void main() {
  group('InterfaceInputsState.fromCode', () {
    test('maps each native state, and an unknown one to noControls', () {
      expect(InterfaceInputsState.fromCode(0), InterfaceInputsState.noControls);
      expect(InterfaceInputsState.fromCode(1), InterfaceInputsState.controls);
      expect(InterfaceInputsState.fromCode(2), InterfaceInputsState.setupMode);
      expect(
        InterfaceInputsState.fromCode(3),
        InterfaceInputsState.setupModeRestart,
      );
      expect(InterfaceInputsState.fromCode(7), InterfaceInputsState.noControls);
    });
  });

  test('InterfaceControl codes match le_interface_control', () {
    expect(
      InterfaceControl.level.code,
      le_interface_control.LE_INTERFACE_LEVEL.value,
    );
    expect(
      InterfaceControl.pad.code,
      le_interface_control.LE_INTERFACE_PAD.value,
    );
    expect(
      InterfaceControl.air.code,
      le_interface_control.LE_INTERFACE_AIR.value,
    );
    expect(
      InterfaceControl.phantom.code,
      le_interface_control.LE_INTERFACE_PHANTOM.value,
    );
    expect(
      InterfaceControl.setupModeOff.code,
      le_interface_control.LE_INTERFACE_SETUP_MODE_OFF.value,
    );
  });

  group('InterfaceInputsInfo.fromNative', () {
    test('projects the inputs, the 48 V switches and the adapter', () {
      final ptr = calloc<le_interface_inputs>();
      try {
        final ref = ptr.ref
          ..state = 1
          ..input_count = 2
          ..phantom_count = 1;
        ref.inputs[0]
          ..level = 1
          ..pad = 0
          ..air = 2
          ..air_choices = 3
          ..phantom_group = 0;
        ref.inputs[1]
          ..level = -1
          ..pad = -1
          ..air = -1
          ..air_choices = 0
          ..phantom_group = 0;
        ref.phantom[0]
          ..first = 1
          ..last = 2
          ..on$ = 1;
        const name = 'scarlett2';
        for (var i = 0; i < name.length; i++) {
          ref.adapter[i] = name.codeUnitAt(i);
        }

        final info = InterfaceInputsInfo.fromNative(ptr);
        expect(info.state, InterfaceInputsState.controls);
        expect(info.adapter, 'scarlett2');
        expect(info.inputs, hasLength(2));
        expect(info.inputs[0].level, 1);
        expect(info.inputs[0].pad, 0);
        expect(info.inputs[0].air, 2);
        expect(info.inputs[0].airChoices, 3);
        expect(info.inputs[0].phantomGroup, 0);
        expect(info.inputs[1].level, isNull);
        expect(info.inputs[1].pad, isNull);
        expect(info.inputs[1].air, isNull);
        expect(info.inputs[1].airChoices, 0);
        expect(info.phantom, hasLength(1));
        expect(info.phantom[0].first, 0);
        expect(info.phantom[0].last, 1);
        expect(info.phantom[0].on, isTrue);
      } finally {
        calloc.free(ptr);
      }
    });

    test('a card with nothing to set projects no inputs', () {
      final ptr = calloc<le_interface_inputs>();
      try {
        final info = InterfaceInputsInfo.fromNative(ptr);
        expect(info.state, InterfaceInputsState.noControls);
        expect(info.inputs, isEmpty);
        expect(info.phantom, isEmpty);
        expect(info.adapter, isEmpty);
      } finally {
        calloc.free(ptr);
      }
    });
  });

  group('MockAudioEngine interface inputs', () {
    test('simulates a 4i4 3rd Gen', () async {
      final engine = MockAudioEngine();
      final info = await engine.readInterfaceInputs('mock');
      expect(info.state, InterfaceInputsState.controls);
      expect(info.inputs, hasLength(2));
      expect(info.inputs[0].level, 0);
      expect(info.inputs[0].airChoices, 2);
      expect(info.phantom.single.first, 0);
      expect(info.phantom.single.last, 1);
      expect(info.phantom.single.on, isFalse);
    });

    test('keeps what is set and refuses what it does not have', () async {
      final engine = MockAudioEngine();
      expect(
        await engine.setInterfaceInput(
          'mock',
          control: InterfaceControl.level,
          index: 1,
          value: 1,
        ),
        EngineResult.ok,
      );
      expect(
        await engine.setInterfaceInput(
          'mock',
          control: InterfaceControl.phantom,
          index: 0,
          value: 1,
        ),
        EngineResult.ok,
      );
      final info = await engine.readInterfaceInputs('mock');
      expect(info.inputs[1].level, 1);
      expect(info.inputs[0].level, 0);
      expect(info.phantom.single.on, isTrue);
      expect(
        await engine.setInterfaceInput(
          'mock',
          control: InterfaceControl.pad,
          index: 2,
          value: 1,
        ),
        EngineResult.invalid,
      );
      expect(
        await engine.setInterfaceInput(
          'mock',
          control: InterfaceControl.air,
          index: 0,
          value: 2,
        ),
        EngineResult.invalid,
      );
      expect(
        await engine.setInterfaceInput(
          'mock',
          control: InterfaceControl.setupModeOff,
          index: 0,
          value: 0,
        ),
        EngineResult.invalid,
      );
    });
  });
}
