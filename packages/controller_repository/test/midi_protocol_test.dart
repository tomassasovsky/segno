import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

RawControllerInput _cc(int number, int value, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: number,
      value: value,
      midiChannel: channel,
    );

RawControllerInput _program(int number, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiProgram,
      id: number,
      value: 0,
      midiChannel: channel,
    );

void main() {
  late Duration now;
  late MidiDecoder decoder;
  setUp(() {
    now = Duration.zero;
    decoder = MidiDecoder(clock: () => now);
  });

  test('standard reads only musical Note, CC and Program', () {
    expect(decoder.feed('dev', _cc(21, 64), MidiProtocol.standard)?.value, 64);
    expect(
      decoder
          .feed(
            'dev',
            const RawControllerInput(
              kind: ControllerSourceKind.midiNote,
              id: 2,
              value: 0,
            ),
            MidiProtocol.standard,
          )
          ?.value,
      0,
    );
    expect(
      decoder.feed('dev', _program(8), MidiProtocol.standard)?.value,
      127,
    );
    expect(
      decoder.feed(
        'dev',
        const RawControllerInput(
          kind: ControllerSourceKind.consoleSwitch,
          id: 0,
          value: 1,
        ),
        MidiProtocol.standard,
      ),
      isNull,
    );
  });

  test('CC14 needs two fresh halves each time, in either order', () {
    expect(decoder.feed('dev', _cc(53, 1), MidiProtocol.cc14), isNull);
    expect(decoder.feed('dev', _cc(21, 64), MidiProtocol.cc14)?.value, 8193);
    expect(decoder.feed('dev', _cc(53, 2), MidiProtocol.cc14), isNull);
    now = const Duration(milliseconds: 101);
    expect(decoder.feed('dev', _cc(21, 65), MidiProtocol.cc14), isNull);
    expect(decoder.feed('dev', _cc(53, 3), MidiProtocol.cc14)?.value, 8323);
  });

  test('interleaved CC14 pairs and channels stay distinct', () {
    expect(decoder.feed('dev', _cc(21, 64), MidiProtocol.cc14), isNull);
    expect(decoder.feed('dev', _cc(22, 10), MidiProtocol.cc14), isNull);
    expect(
      decoder.feed('dev', _cc(53, 1, channel: 1), MidiProtocol.cc14),
      isNull,
    );
    expect(decoder.feed('dev', _cc(54, 2), MidiProtocol.cc14)?.value, 1282);
    expect(decoder.feed('dev', _cc(53, 1), MidiProtocol.cc14)?.value, 8193);
  });

  test('NRPN selection, RPN cancellation and repeated data pairs', () {
    for (final message in [_cc(99, 2), _cc(98, 3), _cc(6, 64)]) {
      expect(decoder.feed('dev', message, MidiProtocol.nrpn), isNull);
    }
    final first = decoder.feed('dev', _cc(38, 7), MidiProtocol.nrpn)!;
    expect(first.source.parameter, 259);
    expect(first.value, 8199);
    expect(decoder.feed('dev', _cc(38, 8), MidiProtocol.nrpn), isNull);
    expect(decoder.feed('dev', _cc(6, 1), MidiProtocol.nrpn)?.value, 136);
    for (final message in [_cc(101, 0), _cc(6, 2), _cc(38, 3)]) {
      expect(decoder.feed('dev', message, MidiProtocol.nrpn), isNull);
    }
  });

  test('Bank+Program retains completed bank but not a partial replacement', () {
    expect(decoder.feed('dev', _program(8), MidiProtocol.bankProgram), isNull);
    expect(decoder.feed('dev', _cc(0, 2), MidiProtocol.bankProgram), isNull);
    expect(decoder.feed('dev', _cc(32, 4), MidiProtocol.bankProgram), isNull);
    expect(
      decoder.feed('dev', _program(8), MidiProtocol.bankProgram)?.source.bank,
      260,
    );
    expect(
      decoder.feed('dev', _program(9), MidiProtocol.bankProgram)?.source.bank,
      260,
    );
    expect(decoder.feed('dev', _cc(0, 3), MidiProtocol.bankProgram), isNull);
    expect(decoder.feed('dev', _program(9), MidiProtocol.bankProgram), isNull);
  });

  test('relative two complement includes 64 as -64 and 0 as neutral', () {
    final delta = [0, 1, 63, 64, 65, 127].map(
      (value) =>
          decoder.feed('dev', _cc(22, value), MidiProtocol.relative)!.delta,
    );
    expect(delta, [0, 1, 63, -64, -63, -1]);
  });

  test('reset drops only matching device partials', () {
    decoder
      ..feed('one', _cc(21, 64), MidiProtocol.cc14)
      ..feed('two', _cc(21, 12), MidiProtocol.cc14)
      ..reset('one');
    expect(decoder.feed('one', _cc(53, 1), MidiProtocol.cc14), isNull);
    expect(decoder.feed('two', _cc(53, 1), MidiProtocol.cc14)?.value, 1537);
  });

  test('source validation excludes console and malformed coordinates', () {
    expect(
      () => MidiSource(
        device: 'dev',
        kind: ControllerSourceKind.consoleSwitch,
        number: 0,
      ),
      throwsFormatException,
    );
    expect(
      MidiSource.fromJson(const {
        'device': 'dev',
        'kind': 'midiCc',
        'number': 21,
        'channel': 0.5,
        'protocol': 'standard',
      }),
      isNull,
    );
    expect(
      MidiSource.fromJson(const {
        'device': 'dev',
        'kind': 'midiCc',
        'number': 21,
        'channel': null,
        'protocol': 'standard',
      }),
      isNull,
    );
  });

  test('footprints conflict across formats and All channels, not devices', () {
    MidiSource source(
      MidiProtocol protocol,
      int number, {
      int? channel = 0,
      String device = 'dev',
    }) => MidiSource(
      device: device,
      kind: ControllerSourceKind.midiCc,
      number: number,
      channel: channel,
      protocol: protocol,
    );
    final plain = source(MidiProtocol.standard, 53);
    final wide = source(MidiProtocol.cc14, 21, channel: null);
    expect(plain.overlaps(wide), isTrue);
    expect(wide.overlaps(plain), isTrue);
    expect(plain.overlaps(source(MidiProtocol.cc14, 21, channel: 1)), isFalse);
    expect(
      plain.overlaps(source(MidiProtocol.cc14, 21, device: 'other')),
      isFalse,
    );
    expect(source(MidiProtocol.relative, 53).overlaps(plain), isTrue);
  });
}
