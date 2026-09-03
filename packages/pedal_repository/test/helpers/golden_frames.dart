import 'package:pedal_repository/pedal_repository.dart';

/// The golden messages: one per fixture in `test/fixtures/`, named by key.
///
/// `tool/generate_golden_fixtures.dart` writes each as `<key>.bin` (the full
/// encoded frame); `pedal_link_golden_test.dart` pins the Dart codec to those
/// bytes, and `firmware/test/test_pedal_link.c` pins the firmware's C codec to
/// the same files. Change a message here → regenerate → both sides move.
/// One fixture per enum value, named `enum_<table>_<dartName>`, so the C
/// contract test can pin every Dart enum name to its C constant and compare
/// the count per table with the C `PEDAL_*_COUNT` — a value added, removed or
/// reordered on either side fails there instead of mis-rendering on stage.
Map<String, PedalLinkMessage> _enumPins() {
  final blank = PedalStateFrame.blank();
  final pins = <String, PedalLinkMessage>{
    for (final b in PedalButton.values)
      'enum_button_${b.name}': ButtonMessage(b, pressed: true),
    for (final m in PedalMode.values)
      'enum_mode_${m.name}': StateMessage(blank.copyWith(mode: m)),
    for (final l in PedalLooperMode.values)
      'enum_looper_${l.name}': StateMessage(blank.copyWith(looperMode: l)),
    for (final g in GlobalColor.values)
      'enum_global_${g.name}': StateMessage(blank.copyWith(globalColor: g)),
    for (final led in PedalTrackLed.values)
      'enum_led_${led.name}': StateMessage(
        blank.copyWith(
          trackLeds: [led, ...blank.trackLeds.skip(1)],
        ),
      ),
  };
  return pins;
}

final goldenMessages = <String, PedalLinkMessage>{
  ..._enumPins(),
  'blank_goodbye': StateMessage(PedalStateFrame.blank(goodbye: true)),
  'idle_rec': StateMessage(
    PedalStateFrame.blank().copyWith(globalColor: GlobalColor.green),
  ),
  'recording_track1': StateMessage(
    PedalStateFrame(
      globalColor: GlobalColor.red,
      trackLeds: const [
        PedalTrackLed.red,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
      ],
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
    ),
  ),
  'playing_bankb': StateMessage(
    PedalStateFrame(
      globalColor: GlobalColor.amber,
      trackLeds: const [
        PedalTrackLed.green,
        PedalTrackLed.green,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.green,
        PedalTrackLed.off,
        PedalTrackLed.red,
        PedalTrackLed.off,
      ],
      activeBank: 1,
      selectedTrack: 6,
      mode: PedalMode.play,
      loopLengthMicros: 4000000,
      clearFadeActive: false,
      masterGain: 128 / 255, // exactly one wire byte, so it round-trips
      looperMode: PedalLooperMode.sync,
    ),
  ),
  'clear_fade': StateMessage(
    PedalStateFrame.blank().copyWith(
      globalColor: GlobalColor.blue,
      clearFadeActive: true,
    ),
  ),
  'performance_armed': StateMessage(
    PedalStateFrame.blank().copyWith(
      globalColor: GlobalColor.green,
      performanceArmed: true,
    ),
  ),
  'mode_counting_in': StateMessage(
    PedalStateFrame.blank().copyWith(
      globalColor: GlobalColor.red,
      looperMode: PedalLooperMode.band,
      countingIn: true,
    ),
  ),
  'fx_mode': StateMessage(
    PedalStateFrame(
      globalColor: GlobalColor.green,
      trackLeds: const [
        PedalTrackLed.blue,
        PedalTrackLed.off,
        PedalTrackLed.blue,
        PedalTrackLed.blue,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
        PedalTrackLed.off,
      ],
      activeBank: 0,
      selectedTrack: 2,
      mode: PedalMode.fx,
      loopLengthMicros: 0xFFFFFFFF,
      clearFadeActive: false,
      looperMode: PedalLooperMode.free,
    ),
  ),
  'loop_top': const LoopTopMessage(),
  'button_track3_down': const ButtonMessage(PedalButton.track3, pressed: true),
  'button_bank_up': const ButtonMessage(PedalButton.bank, pressed: false),
  'encoder_plus1': const EncoderMessage(1),
  'encoder_minus3': const EncoderMessage(-3),
  'hello': const HelloMessage(
    protocolVersion: PedalLinkCodec.protocolVersion,
    firmwareMajor: 1,
    firmwareMinor: 0,
  ),
};
