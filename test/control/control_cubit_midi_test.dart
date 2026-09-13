import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

const _device = 'usb:controller-1';

RawControllerInput _cc(int number, int value) => RawControllerInput(
  kind: ControllerSourceKind.midiCc,
  id: number,
  value: value,
);

RawControllerInput _note(int number, int velocity) => RawControllerInput(
  kind: ControllerSourceKind.midiNote,
  id: number,
  value: velocity,
);

MidiSource _source({
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  int number = 21,
  MidiProtocol protocol = MidiProtocol.standard,
  String device = _device,
}) => MidiSource(
  device: device,
  kind: kind,
  number: number,
  channel: 0,
  protocol: protocol,
);

/// The part 4g MIDI mappings, wired through the one control interpreter.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late _MockMidiDeviceRepository midiDevices;
  late StreamController<MidiConnection> connections;
  late StreamController<RawControllerInput> messages;
  late SettingsRepository settings;
  late PedalRepository pedal;
  late PerformanceRepository performance;
  late ControlCubit cubit;
  late Directory tempDir;
  late bool takeLocked;
  late List<(int, double)> volumeWrites;

  const volume0 = TrackVolumeTarget(0);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  ControlCubit build() => ControlCubit(
    looper: looper,
    pedal: pedal,
    settings: settings,
    performance: performance,
    midiDevices: midiDevices,
    keepAliveInterval: Duration.zero,
    takeLocked: () => takeLocked,
  );

  setUp(() async {
    takeLocked = false;
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast(sync: true);
    midiDevices = _MockMidiDeviceRepository();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<RawControllerInput>.broadcast();
    when(() => midiDevices.connections).thenAnswer((_) => connections.stream);
    when(() => midiDevices.messages).thenAnswer((_) => messages.stream);
    settings = SettingsRepository(store: FakeKeyValueStore());
    pedal = PedalRepository(FakePedalTransport());
    volumeWrites = [];

    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [
          const Track(volume: 0.5),
          for (var i = 1; i < 8; i++) Track(channel: i),
        ],
        outputBusCount: 1,
      ),
    );
    when(() => looper.masterGain).thenReturn(1);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenAnswer((call) {
      volumeWrites.add((
        call.namedArguments[#channel] as int,
        call.positionalArguments.first as double,
      ));
      return EngineResult.ok;
    });
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);

    tempDir = Directory.systemTemp.createTempSync('segno_control_midi4g');
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => tempDir.path,
    );
    cubit = build();
    await cubit.load();
    connections.add(
      const MidiConnection(
        selectedId: _device,
        status: MidiConnectionStatus.connected,
      ),
    );
    await settle();
  });

  tearDown(() async {
    await cubit.close();
    await connections.close();
    await messages.close();
    await pedal.dispose();
    await looperStates.close();
    performance.dispose();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> send(List<RawControllerInput> inputs) async {
    inputs.forEach(messages.add);
    await settle();
  }

  const knob = MidiMapping(
    id: 'knob',
    source: MidiSource(
      device: _device,
      kind: ControllerSourceKind.midiCc,
      number: 21,
      channel: 0,
    ),
    behavior: MidiBehavior.continuous,
    controls: [MidiParameterControl(key: '', low: 0, high: 1)],
  );

  MidiMapping knobOn(ControlValueTarget target) => knob.copyWith(
    controls: [
      MidiParameterControl(key: target.canonicalString(), low: 0, high: 1),
    ],
  );

  group('dispatch', () {
    test('a knob takes over, then drives the parameter', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      await send([_cc(21, 0)]);
      expect(volumeWrites, isEmpty, reason: 'far from 0.5: no jump');
      await send([_cc(21, 64), _cc(21, 100)]);
      expect(volumeWrites.last.$2, closeTo(100 / 127, 1e-9));
    });

    test('another device does not drive it', () async {
      await cubit.saveMidiMapping(
        knobOn(volume0).copyWith(source: _source(device: 'din:other')),
      );
      await send([_cc(21, 64)]);
      expect(volumeWrites, isEmpty);
    });

    test('an action runs on its edge', () async {
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'btn',
          source: _source(kind: ControllerSourceKind.midiNote, number: 60),
          behavior: MidiBehavior.momentary,
          controls: [
            MidiActionControl(key: const ModeAction(InteractionMode.mute).key),
          ],
        ),
      );
      await send([_note(60, 100)]);
      expect(cubit.state.mode, InteractionMode.mute);
    });

    test('a take lock refuses a MIDI action', () async {
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'btn',
          source: _source(kind: ControllerSourceKind.midiNote, number: 60),
          behavior: MidiBehavior.momentary,
          controls: [
            MidiActionControl(key: const ModeAction(InteractionMode.mute).key),
          ],
        ),
      );
      takeLocked = true;
      await send([_note(60, 100)]);
      expect(cubit.state.mode, InteractionMode.record);
    });
  });

  group('Control and connection', () {
    MidiMapping held() => MidiMapping(
      id: 'held',
      source: _source(kind: ControllerSourceKind.midiNote, number: 60),
      behavior: MidiBehavior.momentary,
      controls: [
        MidiParameterControl(
          key: volume0.canonicalString(),
          low: 0.2,
          high: 0.9,
        ),
      ],
    );

    test(
      'Control off releases a hold and stops dispatch, and is kept',
      () async {
        await cubit.saveMidiMapping(held());
        await send([_note(60, 100)]);
        expect(volumeWrites.last.$2, 0.9);

        await cubit.setMidiControlEnabled(enabled: false);
        expect(volumeWrites.last.$2, 0.2, reason: 'Released on the way out');
        volumeWrites.clear();
        await send([_note(60, 100)]);
        expect(volumeWrites, isEmpty);
        expect(await settings.loadMidiControlEnabled(), isFalse);
        expect(cubit.state.midiMappings.mappings, hasLength(1));
      },
    );

    test('a disconnect releases a hold', () async {
      await cubit.saveMidiMapping(held());
      await send([_note(60, 100)]);
      connections.add(
        const MidiConnection(
          selectedId: _device,
          status: MidiConnectionStatus.deviceGone,
        ),
      );
      await settle();
      expect(volumeWrites.last.$2, 0.2);
    });

    test('disabling a mapping releases it; it survives a restart', () async {
      await cubit.saveMidiMapping(held());
      await send([_note(60, 100)]);
      await cubit.setMidiMappingEnabled('held', enabled: false);
      expect(volumeWrites.last.$2, 0.2);

      final restarted = build();
      addTearDown(restarted.close);
      await restarted.load();
      expect(restarted.state.midiMappings.byId('held')?.enabled, isFalse);
    });
  });

  group('Learn', () {
    test('reads in the chosen format and pauses dispatch meanwhile', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      cubit.startMidiLearn(MidiProtocol.cc14);
      await send([_cc(21, 64), _cc(21, 100)]);
      expect(volumeWrites, isEmpty, reason: 'the device dispatches nothing');
      expect(cubit.state.midiLearn?.isListening, isTrue);

      await send([_cc(53, 1)]);
      final learn = cubit.state.midiLearn!;
      expect(
        learn.reading?.value,
        100 * 128 + 1,
        reason: 'the MSB that was fresh when the LSB arrived',
      );
      expect(learn.reading?.source.protocol, MidiProtocol.cc14);
      expect(
        learn.conflictId,
        'knob',
        reason: 'CC 53 is the LSB of CC 21, which plain CC 21 already reads',
      );

      cubit.endMidiEdit();
      expect(cubit.state.midiLearn, isNull);
      await send([_cc(21, 64)]);
      expect(volumeWrites, isNotEmpty, reason: 'dispatch resumed');
    });

    test('starting Learn releases a hold on that device', () async {
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'held',
          source: _source(kind: ControllerSourceKind.midiNote, number: 60),
          behavior: MidiBehavior.momentary,
          controls: [
            MidiParameterControl(
              key: volume0.canonicalString(),
              low: 0.2,
              high: 0.9,
            ),
          ],
        ),
      );
      await send([_note(60, 100)]);
      expect(volumeWrites.last.$2, 0.9);
      cubit.startMidiLearn(MidiProtocol.standard);
      expect(
        volumeWrites.last.$2,
        0.2,
        reason: 'entering the editor releases its momentary values',
      );
    });

    test("never learns the pedal's own traffic", () async {
      cubit.startMidiLearn(MidiProtocol.standard);
      await send([
        RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: PedalButton.recPlay.note,
          value: 127,
        ),
      ]);
      expect(cubit.state.midiLearn?.isListening, isTrue);
      await send([_note(60, 90)]);
      expect(cubit.state.midiLearn?.reading?.source.number, 60);
    });

    test('a device going away ends Learn', () async {
      cubit.startMidiLearn(MidiProtocol.standard);
      connections.add(const MidiConnection());
      await settle();
      expect(cubit.state.midiLearn, isNull);
    });

    test('with no device connected there is nothing to learn from', () async {
      connections.add(const MidiConnection());
      await settle();
      cubit.startMidiLearn(MidiProtocol.standard);
      expect(cubit.state.midiLearn, isNull);
    });
  });

  group('saving', () {
    test('refuses an overlapping source, disabled mapping or not', () async {
      await cubit.saveMidiMapping(knobOn(volume0).copyWith(enabled: false));
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'wide',
          source: _source(protocol: MidiProtocol.cc14),
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: volume0.canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        ),
      );
      expect(cubit.state.midiMappings.mappings.map((m) => m.id), ['knob']);
    });

    test('refuses a mapping that cannot drive what it carries', () async {
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'bad',
          source: _source(protocol: MidiProtocol.relative),
          behavior: MidiBehavior.continuous,
          controls: [
            MidiActionControl(key: const ModeAction(InteractionMode.mute).key),
          ],
        ),
      );
      expect(cubit.state.midiMappings.mappings, isEmpty);
    });

    test('deleting a mapping persists', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      await cubit.deleteMidiMapping('knob');
      expect(cubit.state.midiMappings.mappings, isEmpty);
      expect(await settings.loadMidiMappings(), '[]');
    });
  });
}
