import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  const colors = [
    PedalColor(0, 128, 255),
    PedalColor(165, 1, 2),
    PedalColor(3, 4, 5),
    PedalColor(6, 7, 8),
    PedalColor(9, 10, 11),
    PedalColor(12, 13, 14),
    PedalColor(15, 16, 17),
    PedalColor(18, 19, 20),
    PedalColor(21, 22, 23),
    PedalColor(254, 253, 252),
  ];
  const payload = [
    0,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    255,
    0,
    128,
    255,
    165,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    254,
    253,
    252,
    1,
    2,
  ];
  test('v8 literal layout has ten raw RGB triples then little-endian mask', () {
    final frame = PedalStateFrame.blank().copyWith(
      mode: PedalMode.custom,
      pedalColors: colors,
      activeButtonMask: 0x201,
    );
    expect(PedalLinkCodec.protocolVersion, 8);
    expect(PedalLinkCodec.encodeStatePayload(frame), payload);
    expect(PedalLinkCodec.decodeStatePayload(payload), frame);
    expect(frame.isLit(PedalButton.recPlay), isTrue);
    expect(frame.isLit(PedalButton.bank), isTrue);
    expect(frame.isLit(PedalButton.stop), isFalse);
    expect(frame.colorFor(PedalButton.bank), const PedalColor(254, 253, 252));
  });
  test('hue, activity and diagnostic track state remain independent', () {
    for (final button in PedalButton.values) {
      final frame = PedalStateFrame.blank().copyWith(
        pedalColors: colors,
        activeButtonMask: 1 << button.index,
      );
      for (final other in PedalButton.values) {
        expect(frame.isLit(other), other == button);
      }
      expect(frame.copyWith(isGoodbye: true).isLit(button), isFalse);
      expect(
        frame.copyWith(activeButtonMask: 0).colorFor(button),
        frame.colorFor(button),
      );
    }
    final frame = PedalStateFrame.blank().copyWith(
      clearFadeActive: true,
      trackLeds: List.filled(8, PedalTrackLed.red),
      globalColor: GlobalColor.red,
      activeBank: 1,
    );
    expect(PedalButton.values.map(frame.isLit), everyElement(isFalse));
  });
  test('caller mutation cannot change snapshots, equality or copied lists', () {
    final hues = List<PedalColor>.of(colors);
    final tracks = List.filled(8, PedalTrackLed.green);
    final frame = PedalStateFrame.blank().copyWith(
      pedalColors: hues,
      trackLeds: tracks,
    );
    final same = frame.copyWith();
    final hash = frame.hashCode;
    hues[0] = const PedalColor(0, 0, 0);
    tracks[0] = PedalTrackLed.red;
    expect(frame, same);
    expect(frame.hashCode, hash);
    expect(frame.colorFor(PedalButton.recPlay), colors[0]);
    expect(frame.trackLeds[0], PedalTrackLed.green);
    expect(() => frame.pedalColors[0] = colors[1], throwsUnsupportedError);
    expect(() => same.trackLeds[0] = PedalTrackLed.off, throwsUnsupportedError);
    expect(frame.copyWith(activeButtonMask: 1), isNot(frame));
    expect(frame.copyWith(pedalColors: hues), isNot(frame));
  });
  test('rejects historical sizes, reserved mask bits and non-byte inputs', () {
    for (final size in [0, 19, 21, 49, 50, 52, 255]) {
      expect(PedalLinkCodec.decodeStatePayload(List.filled(size, 0)), isNull);
    }
    for (final mask in [4, 8, 16, 32, 64, 128, 255]) {
      expect(
        PedalLinkCodec.decodeStatePayload(List.of(payload)..[50] = mask),
        isNull,
      );
    }
    for (final value in [-1, 256]) {
      expect(
        PedalLinkCodec.decodeStatePayload(List.of(payload)..[19] = value),
        isNull,
      );
      expect(
        PedalLinkCodec.decode(PedalLinkCodec.typeButton, [value, 1]),
        isNull,
      );
    }
    expect(
      () => PedalStateFrame.blank().copyWith(activeButtonMask: 1024),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => PedalStateFrame.blank().copyWith(pedalColors: colors.sublist(1)),
      throwsA(isA<AssertionError>()),
    );
  });
  test(
    'bad state followed by literal state recovers without publishing it',
    () {
      final bad = [...payload]..[50] = 4;
      List<int> wire(List<int> p) => [
        165,
        16,
        p.length,
        ...p,
        p.fold(16 ^ p.length, (a, b) => a ^ b),
      ];
      final parser = PedalLinkParser();
      final messages = parser.push([...wire(bad), ...wire(payload)]);
      expect(messages, hasLength(1));
      expect((messages.single as StateMessage).frame.activeButtonMask, 0x201);
      expect(parser.droppedFrames, 1);
    },
  );
  test('color value preserves all channel bits and equality', () {
    final color = PedalColor.fromRgb(0x80A5FF);
    expect(color, const PedalColor(128, 165, 255));
    expect(color.rgb, 0x80A5FF);
    expect(color.toString(), '#80A5FF');
  });
}
