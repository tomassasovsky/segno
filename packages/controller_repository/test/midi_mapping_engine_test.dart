import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const device = 'usb:controller-1';
const mix = 'param:delay-mix';
const volume = 'param:track-1-volume';

RawControllerInput cc(int number, int value, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: number,
      value: value,
      midiChannel: channel,
    );

RawControllerInput note(int number, int velocity, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiNote,
      id: number,
      value: velocity,
      midiChannel: channel,
    );

RawControllerInput program(int number) => RawControllerInput(
  kind: ControllerSourceKind.midiProgram,
  id: number,
  value: 0,
);

MidiSource source({
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  int number = 21,
  int? channel = 0,
  MidiProtocol protocol = MidiProtocol.standard,
  int? parameter,
  int? bank,
  String from = device,
}) => MidiSource(
  device: from,
  kind: kind,
  number: number,
  channel: channel,
  protocol: protocol,
  parameter: parameter,
  bank: bank,
);

/// The accepted MIDI controls runtime, rule by rule.
void main() {
  late Map<String, double> values;
  late MidiMappingEngine engine;

  setUp(() {
    values = {mix: 0.5, volume: 0.5};
    engine = MidiMappingEngine(
      clock: () => Duration.zero,
      read: (key) => values[key],
      step: (_) => 0.01,
    );
  });

  /// Feeds [messages] and applies every parameter write, the way the owner
  /// would, so the next reading sees the value it left.
  List<MidiOutput> play(
    List<RawControllerInput> messages, {
    String from = device,
  }) {
    final outputs = <MidiOutput>[];
    for (final message in messages) {
      for (final output in engine.receive(from, message)) {
        if (output is MidiParameterWrite) values[output.key] = output.value;
        outputs.add(output);
      }
    }
    return outputs;
  }

  void save(List<MidiMapping> mappings) {
    var set = const MidiMappingSet();
    for (final mapping in mappings) {
      set = set.withMapping(mapping);
    }
    engine.setMappings(set);
  }

  group('a knob', () {
    const knob = MidiMapping(
      id: 'knob',
      source: MidiSource(
        device: device,
        kind: ControllerSourceKind.midiCc,
        number: 21,
        channel: 0,
      ),
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: mix, low: 0, high: 1)],
    );

    test('writes nothing until it reaches the value', () {
      save([knob]);
      expect(play([cc(21, 0)]), isEmpty, reason: 'far below 0.5: no jump');
      expect(play([cc(21, 20)]), isEmpty);
    });

    test('takes over when it crosses the value, and follows from there', () {
      save([knob]);
      play([cc(21, 40)]);
      final crossed = play([cc(21, 90)]);
      expect(crossed.single, isA<MidiParameterWrite>());
      expect(values[mix], closeTo(90 / 127, 0.001));
      play([cc(21, 10)]);
      expect(values[mix], closeTo(10 / 127, 0.001));
    });

    test('takes over when it lands within a step of the value', () {
      save([knob]);
      expect(play([cc(21, 64)]), isNotEmpty, reason: '64/127 is 0.504');
    });

    test('a range running backwards inverts it', () {
      values[mix] = 1;
      save([
        knob.copyWith(
          controls: const [MidiParameterControl(key: mix, low: 1, high: 0)],
        ),
      ]);
      play([cc(21, 0)]);
      play([cc(21, 127)]);
      expect(values[mix], closeTo(0, 0.001));
    });

    test('14-bit resolution reaches the parameter', () {
      values[volume] = 0;
      save([
        const MidiMapping(
          id: 'wide',
          source: MidiSource(
            device: device,
            kind: ControllerSourceKind.midiCc,
            number: 21,
            channel: 0,
            protocol: MidiProtocol.cc14,
          ),
          behavior: MidiBehavior.continuous,
          controls: [MidiParameterControl(key: volume, low: 0, high: 1)],
        ),
      ]);
      play([cc(21, 0), cc(53, 0)]);
      play([cc(21, 64), cc(53, 1)]);
      expect(values[volume], closeTo(8193 / 16383, 0.0001));
    });
  });

  group('a relative control', () {
    MidiMapping relative({double low = 0, double high = 1}) => MidiMapping(
      id: 'enc',
      source: source(number: 22, protocol: MidiProtocol.relative),
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: volume, low: low, high: high)],
    );

    test('moves from the current value by the step', () {
      save([relative()]);
      play([cc(22, 127)]);
      expect(values[volume], closeTo(0.49, 1e-9));
      play([cc(22, 3)]);
      expect(values[volume], closeTo(0.52, 1e-9));
    });

    test('stays inside its range', () {
      save([relative(low: 0.2, high: 0.55)]);
      play([cc(22, 63)]);
      expect(values[volume], 0.55);
    });

    test('a backwards range turns the other way', () {
      save([relative(low: 1, high: 0)]);
      play([cc(22, 1)]);
      expect(values[volume], closeTo(0.49, 1e-9));
    });
  });

  group('a button', () {
    MidiMapping button(
      MidiBehavior behavior, {
      List<MidiControl> controls = const [
        MidiParameterControl(key: mix, low: 0.2, high: 0.65),
      ],
    }) => MidiMapping(
      id: 'btn',
      source: source(kind: ControllerSourceKind.midiNote, number: 60),
      behavior: behavior,
      controls: controls,
    );

    test('momentary holds its Held value while down', () {
      save([button(MidiBehavior.momentary)]);
      play([note(60, 100)]);
      expect(values[mix], 0.65);
      play([note(60, 0)]);
      expect(values[mix], 0.2);
    });

    test('toggle flips on each press and ignores releases', () {
      save([button(MidiBehavior.toggle)]);
      play([note(60, 100), note(60, 0)]);
      expect(values[mix], 0.65);
      play([note(60, 100)]);
      expect(values[mix], 0.2);
      expect(play([note(60, 0)]), isEmpty);
    });

    test('an action runs on its edge, and a press action ends on release', () {
      save([
        button(
          MidiBehavior.momentary,
          controls: const [
            MidiActionControl(key: 'track:5:pedal'),
            MidiActionControl(key: 'mode:mute', trigger: MidiEdge.release),
          ],
        ),
      ]);
      expect(play([note(60, 100)]), [
        const MidiActionRun(mappingId: 'btn', key: 'track:5:pedal'),
      ]);
      expect(play([note(60, 0)]), [
        const MidiActionEnd(mappingId: 'btn', key: 'track:5:pedal'),
        const MidiActionRun(mappingId: 'btn', key: 'mode:mute'),
        const MidiActionEnd(mappingId: 'btn', key: 'mode:mute'),
      ]);
    });

    test('on All channels it is down while any channel is', () {
      save([
        MidiMapping(
          id: 'all',
          source: source(
            kind: ControllerSourceKind.midiNote,
            number: 60,
            channel: null,
          ),
          behavior: MidiBehavior.momentary,
          controls: const [
            MidiParameterControl(key: mix, low: 0.2, high: 0.65),
          ],
        ),
      ]);
      play([note(60, 100, channel: 1), note(60, 100, channel: 2)]);
      play([note(60, 0, channel: 1)]);
      expect(values[mix], 0.65, reason: 'channel 2 is still down');
      play([note(60, 0, channel: 2)]);
      expect(values[mix], 0.2);
    });
  });

  group('a Program', () {
    test('every message is a press, with nothing to release', () {
      values[mix] = 0;
      save([
        MidiMapping(
          id: 'prog',
          source: source(
            kind: ControllerSourceKind.midiProgram,
            number: 8,
            protocol: MidiProtocol.bankProgram,
            bank: 260,
          ),
          behavior: MidiBehavior.trigger,
          controls: const [
            MidiActionControl(key: 'command:cut-sound'),
            MidiParameterControl(key: mix, low: 0, high: 0.8),
          ],
        ),
      ]);
      final outputs = play([cc(0, 2), cc(32, 4), program(8), program(8)]);
      expect(
        outputs.whereType<MidiActionRun>().length,
        2,
        reason: 'two Programs, two runs',
      );
      expect(outputs.whereType<MidiActionEnd>().length, 2);
      expect(values[mix], 0.8, reason: 'the high value, every time');
    });
  });

  group('ending holds', () {
    const held = MidiMapping(
      id: 'held',
      source: MidiSource(
        device: device,
        kind: ControllerSourceKind.midiNote,
        number: 60,
        channel: 0,
      ),
      behavior: MidiBehavior.momentary,
      controls: [
        MidiParameterControl(key: mix, low: 0.2, high: 0.65),
        MidiActionControl(key: 'instrument:held'),
      ],
    );

    List<MidiOutput> holdDown() {
      save([held]);
      return play([note(60, 100)]);
    }

    const released = [
      MidiActionEnd(mappingId: 'held', key: 'instrument:held'),
      MidiParameterWrite(mix, 0.2),
    ];

    test('turning Control off releases, and nothing dispatches', () {
      holdDown();
      expect(engine.setControlEnabled(enabled: false), released);
      expect(play([note(60, 100)]), isEmpty);
    });

    test('disabling the mapping releases it', () {
      holdDown();
      expect(
        engine.setMappings(
          const MidiMappingSet().withMapping(held.copyWith(enabled: false)),
        ),
        released,
      );
    });

    test('deleting the mapping releases it', () {
      holdDown();
      expect(engine.setMappings(const MidiMappingSet()), released);
    });

    test('pausing the device for Learn releases it and stops dispatch', () {
      holdDown();
      expect(engine.pause(device), released);
      expect(play([note(60, 0), note(60, 100)]), isEmpty);
      engine.resume(device);
      expect(play([note(60, 100)]), isNotEmpty);
    });

    test('a disconnect releases and runs no action', () {
      final outputs = holdDown();
      expect(outputs.whereType<MidiActionRun>(), hasLength(1));
      final ended = engine.connectionChanged(device);
      expect(ended, released);
      expect(ended.whereType<MidiActionRun>(), isEmpty);
    });

    test('a reconnect restarts a toggle Off and a knob untaken', () {
      save([
        MidiMapping(
          id: 'tog',
          source: source(kind: ControllerSourceKind.midiNote, number: 61),
          behavior: MidiBehavior.toggle,
          controls: const [MidiParameterControl(key: volume, low: 0, high: 1)],
        ),
      ]);
      play([note(61, 100), note(61, 0)]);
      expect(values[volume], 1);
      engine.connectionChanged(device);
      play([note(61, 100)]);
      expect(values[volume], 1, reason: 'the latch restarted Off, so On again');
    });

    test('an unchanged saved mapping keeps its hold', () {
      holdDown();
      expect(engine.setMappings(engine.mappings), isEmpty);
    });
  });

  group('dispatch identity', () {
    const knob = MidiMapping(
      id: 'knob',
      source: MidiSource(
        device: device,
        kind: ControllerSourceKind.midiCc,
        number: 21,
        channel: 0,
      ),
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: mix, low: 0, high: 1)],
    );

    test('another device does not drive it', () {
      save([knob]);
      expect(play([cc(21, 64)], from: 'din:other'), isEmpty);
    });

    test('another channel does not drive it', () {
      save([knob]);
      expect(play([cc(21, 64, channel: 3)]), isEmpty);
    });

    test('a disabled mapping does not drive it', () {
      save([knob.copyWith(enabled: false)]);
      expect(play([cc(21, 64)]), isEmpty);
    });

    test('a parameter gone from the rig is skipped', () {
      values.remove(mix);
      save([knob]);
      expect(play([cc(21, 64)]), isEmpty);
    });
  });

  group('Learn', () {
    test('ignores a Note release and a relative reading of nothing', () {
      expect(
        engine.learn(device, note(60, 0), MidiProtocol.standard),
        isNull,
      );
      expect(engine.learn(device, cc(22, 0), MidiProtocol.relative), isNull);
      expect(
        engine
            .learn(device, note(60, 90), MidiProtocol.standard)
            ?.source
            .number,
        60,
      );
    });

    test('reads in the format it was given', () {
      expect(engine.learn(device, cc(21, 64), MidiProtocol.cc14), isNull);
      final event = engine.learn(device, cc(53, 1), MidiProtocol.cc14)!;
      expect(event.value, 8193);
    });

    test('a reset drops a half received before Learn', () {
      engine
        ..learn(device, cc(21, 64), MidiProtocol.cc14)
        ..resetDecoder(device);
      expect(engine.learn(device, cc(53, 1), MidiProtocol.cc14), isNull);
    });
  });

  group('MidiMappingSet', () {
    test('refuses an overlap, disabled or not', () {
      final set = const MidiMappingSet().withMapping(
        MidiMapping(
          id: 'a',
          source: source(number: 53),
          behavior: MidiBehavior.continuous,
          enabled: false,
          controls: const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ),
      );
      final wide = source(protocol: MidiProtocol.cc14);
      expect(set.conflictWith(wide)?.id, 'a');
      expect(
        () => set.withMapping(
          MidiMapping(
            id: 'b',
            source: wide,
            behavior: MidiBehavior.continuous,
            controls: const [MidiParameterControl(key: mix, low: 0, high: 1)],
          ),
        ),
        throwsArgumentError,
      );
      expect(set.conflictWith(wide, exceptId: 'a'), isNull);
    });

    test('a stored file keeps the first of two overlapping mappings', () {
      final json = [
        MidiMapping(
          id: 'a',
          source: source(number: 53),
          behavior: MidiBehavior.continuous,
          controls: const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ).toJson(),
        MidiMapping(
          id: 'b',
          source: source(protocol: MidiProtocol.cc14),
          behavior: MidiBehavior.continuous,
          controls: const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ).toJson(),
      ];
      expect(
        MidiMappingSet.fromJson(json).mappings.map((m) => m.id),
        ['a'],
      );
    });

    test('a stored mapping that could not be saved is dropped', () {
      // Otherwise the next edit of anything in the set would throw.
      final json = [
        MidiMapping(
          id: 'empty',
          source: source(),
          behavior: MidiBehavior.continuous,
        ).toJson(),
        MidiMapping(
          id: 'ok',
          source: source(number: 22),
          behavior: MidiBehavior.continuous,
          controls: const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ).toJson(),
      ];
      final set = MidiMappingSet.fromJson(json);
      expect(set.mappings.map((m) => m.id), ['ok']);
      expect(
        () => set.withMapping(set.mappings.single.copyWith(enabled: false)),
        returnsNormally,
      );
    });

    test('survives a round trip, disabled mappings included', () {
      final set = const MidiMappingSet()
          .withMapping(
            MidiMapping(
              id: 'a',
              source: source(kind: ControllerSourceKind.midiNote, number: 60),
              behavior: MidiBehavior.toggle,
              enabled: false,
              controls: const [
                MidiParameterControl(key: mix, low: 0.1, high: 0.9),
                MidiActionControl(key: 'k', trigger: MidiEdge.release),
              ],
            ),
          )
          .withMapping(
            MidiMapping(
              id: 'b',
              source: source(
                number: 6,
                protocol: MidiProtocol.nrpn,
                parameter: 259,
              ),
              behavior: MidiBehavior.continuous,
              controls: const [
                MidiParameterControl(key: volume, low: 0, high: 1),
              ],
            ),
          );
      expect(MidiMappingSet.fromJson(set.toJson()), set);
    });
  });

  group('what a mapping can be', () {
    MidiMapping build(
      MidiSource source,
      MidiBehavior behavior,
      List<MidiControl> controls,
    ) => MidiMapping(
      id: 'x',
      source: source,
      behavior: behavior,
      controls: controls,
    );

    test('high-resolution and relative formats drive parameters only', () {
      expect(
        build(
          source(protocol: MidiProtocol.cc14),
          MidiBehavior.continuous,
          const [MidiActionControl(key: 'k')],
        ).problem,
        MidiMappingProblem.actionNeedsButton,
      );
      expect(
        build(
          source(protocol: MidiProtocol.relative),
          MidiBehavior.momentary,
          const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ).problem,
        MidiMappingProblem.behaviorDoesNotFit,
      );
    });

    test('a Program is a trigger with no release', () {
      final prog = source(kind: ControllerSourceKind.midiProgram, number: 8);
      expect(
        build(prog, MidiBehavior.momentary, const [
          MidiActionControl(key: 'k'),
        ]).problem,
        MidiMappingProblem.behaviorDoesNotFit,
      );
      expect(
        build(prog, MidiBehavior.trigger, const [
          MidiActionControl(key: 'k', trigger: MidiEdge.release),
        ]).problem,
        MidiMappingProblem.programHasNoRelease,
      );
      expect(
        build(prog, MidiBehavior.trigger, const [
          MidiActionControl(key: 'k'),
        ]).problem,
        isNull,
      );
    });

    test('a learned source starts with the behavior it fits', () {
      expect(
        MidiMapping.defaultBehavior(
          source(kind: ControllerSourceKind.midiProgram, number: 1),
        ),
        MidiBehavior.trigger,
      );
      expect(
        MidiMapping.defaultBehavior(
          source(protocol: MidiProtocol.nrpn, number: 6, parameter: 1),
        ),
        MidiBehavior.continuous,
      );
      expect(MidiMapping.defaultBehavior(source()), MidiBehavior.continuous);
      expect(
        MidiMapping.defaultBehavior(source(), drivesActions: true),
        MidiBehavior.momentary,
      );
      expect(
        MidiMapping.defaultBehavior(
          source(kind: ControllerSourceKind.midiNote, number: 60),
        ),
        MidiBehavior.momentary,
      );
    });

    test('nothing learned, or nothing driven, cannot be saved', () {
      expect(
        build(source(), MidiBehavior.continuous, const []).problem,
        MidiMappingProblem.noControls,
      );
      expect(
        build(
          source(number: 200),
          MidiBehavior.continuous,
          const [MidiParameterControl(key: mix, low: 0, high: 1)],
        ).problem,
        MidiMappingProblem.noSource,
      );
    });
  });
}
