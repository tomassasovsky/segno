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

/// A settings store whose writes fail while [failing] is set.
class _FailingStore extends FakeKeyValueStore {
  bool failing = false;

  @override
  Future<void> setString(String key, String value) {
    if (failing) throw const FileSystemException('disk full');
    return super.setString(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) {
    if (failing) throw const FileSystemException('disk full');
    return super.setBool(key, value: value);
  }
}

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
  late _FailingStore store;
  late SettingsRepository settings;
  late PedalRepository pedal;
  late PerformanceRepository performance;
  late ControlCubit cubit;
  late Directory tempDir;
  late bool takeLocked;
  late List<(int, double)> volumeWrites;

  const volume0 = TrackVolumeTarget(0);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  ControlCubit build({Duration learnTimeout = const Duration(seconds: 15)}) =>
      ControlCubit(
        looper: looper,
        pedal: pedal,
        settings: settings,
        performance: performance,
        midiDevices: midiDevices,
        keepAliveInterval: Duration.zero,
        midiLearnTimeout: learnTimeout,
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
    store = _FailingStore();
    settings = SettingsRepository(store: store);
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

  Future<void> connect({bool connected = true}) async {
    connections.add(
      MidiConnection(
        selectedId: _device,
        status: connected
            ? MidiConnectionStatus.connected
            : MidiConnectionStatus.deviceGone,
      ),
    );
    await settle();
  }

  void learn(MidiProtocol protocol) {
    cubit
      ..beginMidiEdit(device: _device)
      ..startMidiLearn(protocol);
  }

  MidiLearn? learning() => cubit.state.midiEdit?.learn;

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

    test('Tap tempo reaches the engine', () async {
      when(() => looper.tapTempo()).thenReturn(EngineResult.ok);
      await cubit.saveMidiMapping(
        MidiMapping(
          id: 'tap',
          source: _source(kind: ControllerSourceKind.midiNote, number: 61),
          behavior: MidiBehavior.momentary,
          controls: [
            MidiActionControl(
              key: const CommandAction(ControlCommand.tapTempo).key,
            ),
          ],
        ),
      );
      await send([_note(61, 100), _note(61, 0), _note(61, 100)]);
      verify(() => looper.tapTempo()).called(2);
    });

    test('master gain keeps the encoder accumulator in step', () async {
      when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
      await cubit.saveMidiMapping(knobOn(const MasterGainTarget()));
      // Master gain reads 1, so the knob takes over at the top and is then
      // turned right down.
      await send([_cc(21, 127), _cc(21, 0)]);
      cubit.encoderTurned(1); // the next detent must step up FROM 0

      final gains = verify(
        () => looper.setMasterGain(captureAny()),
      ).captured.cast<double>();
      expect(gains, [1, 0, closeTo(1 / 64, 1e-9)]);
    });

    test('a parameter gone from the rig writes nothing and throws '
        'nothing', () async {
      when(() => looper.trackEffects(any())).thenReturn(const []);
      when(() => looper.allTrackChains()).thenReturn(const {});
      await cubit.saveMidiMapping(
        knobOn(
          const FxParamTarget(
            address: FxAddress(stage: FxStage.track),
            slotId: 'gone',
            param: 0,
          ),
        ),
      );
      await send([_cc(21, 64), _cc(21, 127)]);
      verifyNever(
        () => looper.setTrackEffectParam(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          param: any(named: 'param'),
          value: any(named: 'value'),
        ),
      );
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

    test('a knob value holds when the controller disconnects', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      await send([_cc(21, 64), _cc(21, 127)]);
      expect(volumeWrites.last.$2, 1);
      final writes = volumeWrites.length;
      connections.add(
        const MidiConnection(
          selectedId: _device,
          status: MidiConnectionStatus.deviceGone,
        ),
      );
      await settle();
      expect(volumeWrites, hasLength(writes), reason: 'no snap-back');
    });

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
      learn(MidiProtocol.cc14);
      await send([_cc(21, 64), _cc(21, 100)]);
      expect(volumeWrites, isEmpty, reason: 'the device dispatches nothing');
      expect(learning()?.isListening, isTrue);

      await send([_cc(53, 1)]);
      final heard = learning()!;
      expect(
        heard.reading?.value,
        100 * 128 + 1,
        reason: 'the MSB that was fresh when the LSB arrived',
      );
      expect(heard.reading?.source.protocol, MidiProtocol.cc14);

      cubit.endMidiEdit();
      expect(cubit.state.midiEdit, isNull);
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
      learn(MidiProtocol.standard);
      expect(
        volumeWrites.last.$2,
        0.2,
        reason: 'entering the editor releases its momentary values',
      );
    });

    test("never learns the pedal's own traffic", () async {
      learn(MidiProtocol.standard);
      await send([
        RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: PedalButton.recPlay.note,
          value: 127,
        ),
      ]);
      expect(learning()?.isListening, isTrue);
      await send([_note(60, 90)]);
      expect(learning()?.reading?.source.number, 60);
    });

    test('Learning again drops a half the last Learn received', () async {
      learn(MidiProtocol.cc14);
      await send([_cc(21, 64)]);
      cubit.startMidiLearn(MidiProtocol.cc14);
      await send([_cc(53, 1)]);
      expect(learning()?.isListening, isTrue);
    });

    test('with no device connected there is nothing to learn from', () async {
      connections.add(const MidiConnection());
      await settle();
      learn(MidiProtocol.standard);
      expect(cubit.state.midiEdit?.device, _device, reason: 'editor open');
      expect(learning(), isNull);
    });

    test('Cancel Learn keeps the editor open and the device paused', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      learn(MidiProtocol.standard);
      cubit.cancelMidiLearn();
      expect(cubit.state.midiEdit?.device, _device);
      expect(learning(), isNull);
      await send([_cc(21, 64), _cc(21, 100)]);
      expect(volumeWrites, isEmpty);
    });

    test('Learn that hears nothing times out and says so', () async {
      await cubit.close();
      cubit = build(learnTimeout: const Duration(milliseconds: 1));
      await cubit.load();
      await connect();
      learn(MidiProtocol.standard);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(learning(), isNull);
      expect(cubit.state.midiEdit?.learnTimedOut, isTrue);

      cubit.startMidiLearn(MidiProtocol.standard);
      expect(cubit.state.midiEdit?.learnTimedOut, isFalse);
      await send([_cc(21, 64)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        learning()?.reading?.source.number,
        21,
        reason: 'a Learn that heard something does not time out',
      );
    });

    test(
      'Cancel Learn and reopening the editor both stop the timeout',
      () async {
        await cubit.close();
        cubit = build(learnTimeout: const Duration(milliseconds: 1));
        await cubit.load();
        await connect();

        learn(MidiProtocol.standard);
        cubit.cancelMidiLearn();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(cubit.state.midiEdit?.learnTimedOut, isFalse);

        learn(MidiProtocol.standard);
        cubit.beginMidiEdit(device: _device);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(cubit.state.midiEdit?.learnTimedOut, isFalse);
      },
    );

    test('Edit existing mapping moves the editor to it', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      learn(MidiProtocol.standard);
      await send([_cc(21, 64)]);
      cubit.beginMidiEdit(device: _device);
      expect(cubit.state.midiEdit?.device, _device);
      expect(learning(), isNull);
    });
  });

  group('editing', () {
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

    test('opening a mapping without Learn pauses its device', () async {
      await cubit.saveMidiMapping(held());
      await send([_note(60, 100)]);
      expect(volumeWrites.last.$2, 0.9);

      cubit.beginMidiEdit(device: _device);
      expect(volumeWrites.last.$2, 0.2, reason: 'its hold ends on entry');
      volumeWrites.clear();
      await send([_note(60, 0), _note(60, 100)]);
      expect(volumeWrites, isEmpty);

      cubit.endMidiEdit();
      await send([_note(60, 0), _note(60, 100)]);
      expect(volumeWrites.last.$2, 0.9);
    });

    test('a device that goes away and comes back while the editor is open '
        'dispatches again once it closes', () async {
      await cubit.saveMidiMapping(held());
      learn(MidiProtocol.standard);
      await connect(connected: false);
      expect(cubit.state.midiEdit?.device, _device, reason: 'still open');
      expect(learning()?.isListening, isTrue);

      await connect();
      await send([_note(61, 100)]);
      expect(
        learning()?.reading?.source.number,
        61,
        reason: 'Learn hears the device again',
      );
      volumeWrites.clear();
      await send([_note(60, 100)]);
      expect(volumeWrites, isEmpty, reason: 'still paused while editing');

      cubit.endMidiEdit();
      await send([_note(60, 0), _note(60, 100)]);
      expect(volumeWrites.last.$2, 0.9, reason: 'not left paused');
    });

    test(
      'an editor closed while its device was away does not strand it',
      () async {
        await cubit.saveMidiMapping(held());
        cubit.beginMidiEdit(device: _device);
        await connect(connected: false);
        cubit.endMidiEdit();
        await connect();
        await send([_note(60, 100)]);
        expect(volumeWrites.last.$2, 0.9);
      },
    );

    test('opening an editor on another device lets the first one go', () async {
      await cubit.saveMidiMapping(held());
      cubit
        ..beginMidiEdit(device: 'din:other')
        ..beginMidiEdit(device: _device)
        ..beginMidiEdit(device: 'din:other');
      await send([_note(60, 100)]);
      expect(volumeWrites.last.$2, 0.9);
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

    test('a failed write changes nothing', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      store.failing = true;
      final moved = knobOn(volume0).copyWith(source: _source(number: 30));
      await cubit.saveMidiMapping(moved);
      expect(cubit.state.midiMappings.byId('knob')?.source.number, 21);
      await send([_cc(21, 64), _cc(21, 100)]);
      expect(volumeWrites, isNotEmpty, reason: 'the saved one still runs');

      await cubit.deleteMidiMapping('knob');
      await cubit.setMidiMappingEnabled('knob', enabled: false);
      await cubit.setMidiControlEnabled(enabled: false);
      expect(cubit.state.midiMappings.byId('knob')?.enabled, isTrue);
      expect(cubit.state.midiControlEnabled, isTrue);
      volumeWrites.clear();
      await send([_cc(21, 110)]);
      expect(
        volumeWrites,
        isNotEmpty,
        reason: 'a Control Off that was not written does not stop dispatch',
      );

      store.failing = false;
      await cubit.deleteMidiMapping('knob');
      expect(cubit.state.midiMappings.mappings, isEmpty);
    });

    test('Save keeps whether a mapping is enabled', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      await cubit.setMidiMappingEnabled('knob', enabled: false);
      // An editor opened before the toggle landed still holds enabled: true.
      await cubit.saveMidiMapping(
        knobOn(volume0).copyWith(source: _source(number: 30)),
      );
      final saved = cubit.state.midiMappings.byId('knob');
      expect(saved?.source.number, 30);
      expect(saved?.enabled, isFalse);
    });

    test('quick edits run in order and none is lost', () async {
      final first = knobOn(volume0);
      final second = MidiMapping(
        id: 'm2',
        source: _source(number: 22),
        behavior: MidiBehavior.continuous,
        controls: [
          MidiParameterControl(
            key: volume0.canonicalString(),
            low: 0,
            high: 1,
          ),
        ],
      );
      await Future.wait([
        cubit.saveMidiMapping(first),
        cubit.saveMidiMapping(second),
        cubit.setMidiMappingEnabled('knob', enabled: false),
      ]);
      expect(cubit.state.midiMappings.mappings.map((m) => m.id), [
        'knob',
        'm2',
      ]);
      expect(cubit.state.midiMappings.byId('knob')?.enabled, isFalse);
      final restarted = build();
      addTearDown(restarted.close);
      await restarted.load();
      expect(restarted.state.midiMappings, cubit.state.midiMappings);
    });

    test('deleting a mapping persists', () async {
      await cubit.saveMidiMapping(knobOn(volume0));
      await cubit.deleteMidiMapping('knob');
      expect(cubit.state.midiMappings.mappings, isEmpty);
      expect(await settings.loadMidiMappings(), '[]');
    });
  });
}
