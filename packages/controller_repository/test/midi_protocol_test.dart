import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

RawControllerInput cc(int number, int value, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: number,
      value: value,
      midiChannel: channel,
    );

RawControllerInput program(int number, {int channel = 0}) => RawControllerInput(
  kind: ControllerSourceKind.midiProgram,
  id: number,
  value: 0,
  midiChannel: channel,
);

RawControllerInput note(int number, int velocity, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiNote,
      id: number,
      value: velocity,
      midiChannel: channel,
    );

/// The accepted design's explicit MIDI formats. Every worked example below is
/// the design document's own Learn example, so a change here is a change to
/// what the design said.
void main() {
  late Duration now;
  late MidiDecoder decoder;
  const device = 'usb:controller-1';

  setUp(() {
    now = Duration.zero;
    decoder = MidiDecoder(clock: () => now);
  });

  List<MidiControlEvent> feed(
    List<RawControllerInput> messages,
    MidiProtocol protocol, {
    String from = device,
  }) => [
    for (final message in messages) ?decoder.feed(from, message, protocol),
  ];

  group('the design examples', () {
    test('CC 21 = 64 reads 64 of 127', () {
      final events = feed([cc(21, 64)], MidiProtocol.standard);
      expect(events.single.value, 64);
      expect(events.single.maximum, 127);
      expect(events.single.source.number, 21);
    });

    test('14-bit: CC 21 = 64, CC 53 = 1 reads 8193 of 16383', () {
      final events = feed([cc(21, 64), cc(53, 1)], MidiProtocol.cc14);
      expect(events.single.value, 8193);
      expect(events.single.maximum, 16383);
      expect(events.single.source.number, 21, reason: 'named by its MSB');
    });

    test('NRPN: 99=2, 98=3, 6=64, 38=7 reads parameter 259 at 8199', () {
      final events = feed([
        cc(99, 2),
        cc(98, 3),
        cc(6, 64),
        cc(38, 7),
      ], MidiProtocol.nrpn);
      expect(events.single.source.parameter, 259);
      expect(events.single.value, 8199);
      expect(events.single.maximum, 16383);
    });

    test('Bank + Program: 0=2, 32=4, Program 8 reads bank 260, program 8', () {
      final events = feed([
        cc(0, 2),
        cc(32, 4),
        program(8),
      ], MidiProtocol.bankProgram);
      expect(events.single.source.bank, 260);
      expect(events.single.source.number, 8);
    });

    test('Relative: CC 22 = 127 is one step down', () {
      final events = feed([cc(22, 127)], MidiProtocol.relative);
      expect(events.single.delta, -1);
    });
  });

  group('14-bit CC', () {
    test('a lone half completes nothing', () {
      expect(feed([cc(21, 64)], MidiProtocol.cc14), isEmpty);
      decoder.reset();
      expect(feed([cc(53, 1)], MidiProtocol.cc14), isEmpty);
    });

    test('the halves arrive in either order', () {
      final events = feed([cc(53, 1), cc(21, 64)], MidiProtocol.cc14);
      expect(events.single.value, 8193);
    });

    test('a stale half is not paired with a fresh one', () {
      decoder.feed(device, cc(21, 64), MidiProtocol.cc14);
      now = const Duration(milliseconds: 101);
      expect(decoder.feed(device, cc(53, 1), MidiProtocol.cc14), isNull);
    });

    test('every update needs both halves again', () {
      feed([cc(21, 64), cc(53, 1)], MidiProtocol.cc14);
      expect(
        feed([cc(53, 2)], MidiProtocol.cc14),
        isEmpty,
        reason: 'a controller sending only its changed byte is outside this',
      );
    });

    test('CCs above 63 and anything but a CC are not read', () {
      expect(feed([cc(70, 1), note(21, 64)], MidiProtocol.cc14), isEmpty);
    });

    test('two channels assemble separately', () {
      final events = feed([
        cc(21, 64, channel: 1),
        cc(53, 1, channel: 2),
      ], MidiProtocol.cc14);
      expect(events, isEmpty);
    });
  });

  group('NRPN', () {
    List<RawControllerInput> select(int msb, int lsb) => [
      cc(99, msb),
      cc(98, lsb),
    ];

    test('data with nothing selected reads nothing', () {
      expect(feed([cc(6, 64), cc(38, 7)], MidiProtocol.nrpn), isEmpty);
    });

    test('an RPN selection cancels the NRPN one', () {
      final events = feed([
        ...select(2, 3),
        cc(101, 0),
        cc(6, 64),
        cc(38, 7),
      ], MidiProtocol.nrpn);
      expect(events, isEmpty);
    });

    test('the null selection selects nothing', () {
      final events = feed([
        ...select(127, 127),
        cc(6, 64),
        cc(38, 7),
      ], MidiProtocol.nrpn);
      expect(events, isEmpty);
    });

    test('Data Increment and Decrement drop pending data', () {
      final events = feed([
        ...select(2, 3),
        cc(6, 64),
        cc(96, 1),
        cc(38, 7),
      ], MidiProtocol.nrpn);
      expect(events, isEmpty);
    });

    test('the selection holds for the next value', () {
      final events = feed([
        ...select(2, 3),
        cc(6, 64),
        cc(38, 7),
        cc(6, 1),
        cc(38, 0),
      ], MidiProtocol.nrpn);
      expect(events.map((e) => e.value), [8199, 128]);
      expect(events.every((e) => e.source.parameter == 259), isTrue);
    });
  });

  group('Bank + Program', () {
    test('a Program with no bank reads nothing', () {
      expect(feed([program(8)], MidiProtocol.bankProgram), isEmpty);
    });

    test('the bank holds for the Programs after it', () {
      final events = feed([
        cc(0, 2),
        cc(32, 4),
        program(8),
        program(9),
      ], MidiProtocol.bankProgram);
      expect(events.map((e) => e.source.number), [8, 9]);
      expect(events.every((e) => e.source.bank == 260), isTrue);
    });

    test('a partial bank invalidates the one before it', () {
      final events = feed([
        cc(0, 2),
        cc(32, 4),
        cc(0, 5),
        program(8),
      ], MidiProtocol.bankProgram);
      expect(
        events,
        isEmpty,
        reason: 'the controller omitted a bank byte, which is outside this',
      );
    });
  });

  group('the other formats', () {
    test('a Program in the standard format carries its maximum', () {
      final event = decoder.feed(device, program(8), MidiProtocol.standard)!;
      expect(event.value, 127);
      expect(event.source.kind, ControllerSourceKind.midiProgram);
    });

    test('relative steps: 1–63 up, 65–127 down, 0 still', () {
      final deltas = feed([
        cc(22, 1),
        cc(22, 63),
        cc(22, 65),
        cc(22, 0),
      ], MidiProtocol.relative).map((e) => e.delta);
      expect(deltas, [1, 63, -63, 0]);
    });

    test('reset drops a half-received pair', () {
      decoder
        ..feed(device, cc(21, 64), MidiProtocol.cc14)
        ..reset(device);
      expect(decoder.feed(device, cc(53, 1), MidiProtocol.cc14), isNull);
    });

    test('reset for one device leaves another alone', () {
      decoder
        ..feed(device, cc(21, 64), MidiProtocol.cc14)
        ..feed('din:other', cc(21, 64), MidiProtocol.cc14)
        ..reset('din:other');
      expect(decoder.feed(device, cc(53, 1), MidiProtocol.cc14), isNotNull);
    });
  });

  group('MidiSource', () {
    MidiSource source(
      MidiProtocol protocol, {
      int number = 21,
      int? channel = 0,
      ControllerSourceKind kind = ControllerSourceKind.midiCc,
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

    test('a source has to fit its format', () {
      expect(source(MidiProtocol.cc14, number: 32).isValid, isFalse);
      expect(
        source(MidiProtocol.nrpn, number: 7, parameter: 1).isValid,
        isFalse,
      );
      expect(
        source(MidiProtocol.nrpn, number: 6, parameter: 16383).isValid,
        isFalse,
      );
      expect(
        source(
          MidiProtocol.bankProgram,
          bank: 1,
        ).isValid,
        isFalse,
      );
      expect(
        source(
          MidiProtocol.relative,
          kind: ControllerSourceKind.midiNote,
        ).isValid,
        isFalse,
      );
      expect(source(MidiProtocol.standard, channel: 16).isValid, isFalse);
    });

    test('a plain CC and a 14-bit CC on its footprint overlap', () {
      final plain = source(MidiProtocol.standard, number: 53);
      final wide = source(MidiProtocol.cc14);
      expect(plain.overlaps(wide), isTrue, reason: 'CC 53 is its LSB');
      expect(wide.overlaps(plain), isTrue);
    });

    test('channels that do not meet do not overlap; All meets every one', () {
      final one = source(MidiProtocol.standard, number: 53, channel: 1);
      expect(one.overlaps(source(MidiProtocol.cc14, channel: 2)), isFalse);
      expect(one.overlaps(source(MidiProtocol.cc14, channel: null)), isTrue);
    });

    test('two devices never overlap', () {
      // Across formats, where the footprints WOULD collide on one device: the
      // same CC on two controllers is two controls.
      expect(
        source(MidiProtocol.standard, number: 53).overlaps(
          source(MidiProtocol.cc14, from: 'din:other'),
        ),
        isFalse,
      );
      expect(
        source(MidiProtocol.standard).sameAs(
          source(MidiProtocol.standard, from: 'din:other'),
        ),
        isFalse,
      );
    });

    test('distinct NRPN parameters and banked Programs stay independent', () {
      final a = source(MidiProtocol.nrpn, number: 6, parameter: 259);
      final b = source(MidiProtocol.nrpn, number: 6, parameter: 260);
      expect(a.overlaps(b), isFalse);
      expect(a.overlaps(a), isTrue);
      final p1 = source(
        MidiProtocol.bankProgram,
        kind: ControllerSourceKind.midiProgram,
        number: 8,
        bank: 1,
      );
      final p2 = source(
        MidiProtocol.bankProgram,
        kind: ControllerSourceKind.midiProgram,
        number: 8,
        bank: 2,
      );
      expect(p1.overlaps(p2), isFalse);
    });

    test('NRPN data entry overlaps a plain CC 6', () {
      expect(
        source(MidiProtocol.nrpn, number: 6, parameter: 1).overlaps(
          source(MidiProtocol.standard, number: 38),
        ),
        isTrue,
      );
    });

    test('Bank + Program overlaps a plain Program with its number', () {
      final banked = source(
        MidiProtocol.bankProgram,
        kind: ControllerSourceKind.midiProgram,
        number: 8,
        bank: 1,
      );
      expect(
        banked.overlaps(
          source(
            MidiProtocol.standard,
            kind: ControllerSourceKind.midiProgram,
            number: 8,
          ),
        ),
        isTrue,
      );
      expect(banked.overlaps(source(MidiProtocol.standard, number: 0)), isTrue);
    });

    test('survives a round trip; an invalid stored one reads as nothing', () {
      final nrpn = source(MidiProtocol.nrpn, number: 6, parameter: 259);
      expect(MidiSource.fromJson(nrpn.toJson()), nrpn);
      final all = source(MidiProtocol.relative, channel: null);
      expect(MidiSource.fromJson(all.toJson()), all);
      expect(
        MidiSource.fromJson({
          ...source(MidiProtocol.cc14).toJson(),
          'number': 40,
        }),
        isNull,
      );
      expect(MidiSource.fromJson({'device': device}), isNull);
    });
  });
}
