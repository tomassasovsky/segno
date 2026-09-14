import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const device = 'usb:controller-1';

RawControllerInput cc(int number, int value, {int channel = 0}) =>
    RawControllerInput(
      kind: ControllerSourceKind.midiCc,
      id: number,
      value: value,
      midiChannel: channel,
    );

void main() {
  late Duration now;
  late MidiSignalLevels levels;

  const knob = MidiSource(
    device: device,
    kind: ControllerSourceKind.midiCc,
    number: 21,
    channel: 0,
  );
  const wide = MidiSource(
    device: device,
    kind: ControllerSourceKind.midiCc,
    number: 22,
    channel: 0,
    protocol: MidiProtocol.cc14,
  );

  setUp(() {
    now = Duration.zero;
    levels = MidiSignalLevels(clock: () => now);
  });

  test('is the last value a source received', () {
    expect(levels.levelOf(knob), 0);
    expect(levels.feed(device, cc(21, 127), [knob, wide]), isTrue);
    expect(levels.levelOf(knob), 1);
    expect(levels.levelOf(wide), 0);
    expect(levels.feed(device, cc(21, 127), [knob]), isFalse);
    levels.feed(device, cc(21, 0), [knob]);
    expect(levels.levelOf(knob), 0);
  });

  test('reads each source in its own format', () {
    levels
      ..feed(device, cc(22, 127), [knob, wide])
      ..feed(device, cc(54, 127), [knob, wide]);
    expect(levels.levelOf(wide), 1);
    expect(levels.levelOf(knob), 0);
  });

  test('another device or channel moves nothing', () {
    expect(levels.feed('din:other', cc(21, 127), [knob]), isFalse);
    expect(levels.feed(device, cc(21, 127, channel: 4), [knob]), isFalse);
    expect(levels.levelOf(knob), 0);
  });

  test('a reset drops a half, and keeps the levels', () {
    levels
      ..feed(device, cc(21, 64), [knob])
      ..feed(device, cc(22, 127), [wide])
      ..reset(device)
      ..feed(device, cc(54, 127), [wide]);
    expect(levels.levelOf(wide), 0);
    expect(levels.levelOf(knob), 64 / 127);
  });
}
