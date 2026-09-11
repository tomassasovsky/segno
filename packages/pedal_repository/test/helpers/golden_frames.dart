import 'package:pedal_repository/pedal_repository.dart';

/// The canonical set of [PedalStateFrame]s captured as golden SysEx fixtures.
///
/// These are the **shared contract** between segno's codec and the pedal
/// firmware: the committed `test/fixtures/<name>.syx` bytes are regenerated
/// from this catalog (see `tool/generate_golden_fixtures.dart`) and asserted by
/// `test/pedal_codec_golden_test.dart`. The firmware's host-compiled test links
/// the same `.syx` files. Keep names stable; append rather than renumber.
Map<String, PedalStateFrame> goldenFrames() {
  List<PedalTrackLed> leds(List<PedalTrackLed> values) => [
    ...values,
    ...List<PedalTrackLed>.filled(
      PedalStateFrame.trackCount - values.length,
      PedalTrackLed.off,
    ),
  ];

  return {
    // The all-off shutdown frame (isGoodbye set).
    'blank_goodbye': PedalStateFrame.blank(goodbye: true),

    // An all-off but live frame (e.g. fresh bind, nothing recorded yet).
    'idle_rec': PedalStateFrame(
      globalColor: GlobalColor.green,
      trackLeds: leds(const []),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
    ),

    // Recording track 1, Rec mode, bank A, no loop yet.
    'recording_track1': PedalStateFrame(
      globalColor: GlobalColor.red,
      trackLeds: leds(const [PedalTrackLed.red]),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
    ),

    // Play mode, bank B, tracks 1-4 playing, a 1.5 s loop, armed track 5.
    // masterGain 153/255 (~0.6) exercises the gain byte at a non-unity value;
    // n/255 keeps the double round-trip exact for the golden decode assertion.
    'playing_bankb': PedalStateFrame(
      globalColor: GlobalColor.amber,
      trackLeds: leds(const [
        PedalTrackLed.green,
        PedalTrackLed.green,
        PedalTrackLed.green,
        PedalTrackLed.green,
      ]),
      activeBank: 1,
      selectedTrack: 4,
      mode: PedalMode.play,
      loopLengthMicros: 1500000,
      clearFadeActive: false,
      masterGain: 153 / 255,
    ),

    // Clear fade in progress — exercises the clearFadeActive flag and a long
    // (near-max) loop length to stress the 32-bit little-endian field.
    'clear_fade': PedalStateFrame(
      globalColor: GlobalColor.blue,
      trackLeds: leds(const [
        PedalTrackLed.green,
        PedalTrackLed.red,
        PedalTrackLed.off,
        PedalTrackLed.green,
      ]),
      activeBank: 0,
      selectedTrack: 3,
      mode: PedalMode.rec,
      loopLengthMicros: 0xFEDCBA98,
      clearFadeActive: true,
    ),

    // Performance recording armed (D-PEDAL) — exercises the new flags bit3
    // alongside an otherwise-ordinary Rec-mode, bank A frame.
    'performance_armed': PedalStateFrame(
      globalColor: GlobalColor.green,
      trackLeds: leds(const [PedalTrackLed.red]),
      activeBank: 0,
      selectedTrack: 0,
      mode: PedalMode.rec,
      loopLengthMicros: 0,
      clearFadeActive: false,
      performanceArmed: true,
    ),

    // Protocol v2 (D11) — exercises the new flags bits 4-6 (looperMode) and
    // bit 7 (countingIn) at once, alongside otherwise-ordinary Play-mode,
    // bank A fields. Encoded at the codec's default (v2) like every other
    // entry here, so this fixture proves the (app v2, firmware v2) full-
    // fidelity pairing on its own; see `explicitVersionGoldenFrames` below
    // for the same content forced onto the legacy (v1) wire.
    'mode_counting_in': PedalStateFrame(
      globalColor: GlobalColor.amber,
      trackLeds: leds(const [PedalTrackLed.green]),
      activeBank: 0,
      selectedTrack: 2,
      mode: PedalMode.play,
      loopLengthMicros: 750000,
      clearFadeActive: false,
      looperMode: PedalLooperMode.sync,
      countingIn: true,
    ),
  };
}

/// A small second catalog: fixtures that pin an explicit wire protocol
/// version rather than the [PedalCodec.protocolVersion] default every entry
/// in [goldenFrames] above encodes at.
///
/// These exist purely for the bidirectional-degrade contracts (D11, B10):
/// proving what the app actually puts on the wire when it knows the bound
/// firmware's version, with a concrete committed byte sequence firmware can
/// test against (see `firmware/test/test_pedal_protocol.c`'s
/// `test_version_pairings`) — not just "the codec's current default", which
/// [goldenFrames] already covers.
///
/// `decoded` is what [PedalCodec.decodeFrame] recovers from the fixture
/// bytes — identical to `frame` unless the pinned version genuinely cannot
/// carry a field (a downgrade loses information by design; the golden test
/// asserts exactly what survives).
Map<String, ({PedalStateFrame frame, int version, PedalStateFrame decoded})>
explicitVersionGoldenFrames() {
  // The FX-mode frame (protocol v3, part 5a): mode fx with chain-state
  // trackLeds (PedalTrackLed.blue = chain enabled), on bank B so the mode
  // field's high bit coexists with the bank bit in payload byte 2
  // (byte 2 = 0b11), plus non-default v2 fields (looperMode band) to prove
  // v3 carries everything v2 did. The v2/v1 twins below pin the B10
  // downgrade projection byte-for-byte: the mode field degrades to play and
  // the blue chain LEDs degrade to green (pre-v3 firmware rejects a frame
  // carrying an unknown LED index wholesale); every other byte matches the
  // v3 encoding.
  final fxMode = PedalStateFrame(
    globalColor: GlobalColor.green,
    trackLeds: const [
      PedalTrackLed.blue,
      PedalTrackLed.off,
      PedalTrackLed.blue,
      PedalTrackLed.blue,
      PedalTrackLed.off,
      PedalTrackLed.off,
      PedalTrackLed.blue,
      PedalTrackLed.off,
    ],
    activeBank: 1,
    selectedTrack: 5,
    mode: PedalMode.fx,
    loopLengthMicros: 2000000,
    clearFadeActive: false,
    masterGain: 204 / 255,
    looperMode: PedalLooperMode.band,
  );

  // The custom-mode frame (protocol v4, #763): the fourth mode value, again
  // on bank B so it shares payload byte 2 with the bank bit (byte 2 = 0b11 —
  // the SAME byte the fx twin writes, since custom differs from fx only in
  // the flags-byte low bit). The v3 twin below pins the degrade: custom
  // writes as play, because a v3 decoder rejects the fourth value outright
  // and a blank pedal is worse than a mis-coloured LED.
  final customMode = fxMode.copyWith(mode: PedalMode.custom);

  // Ten DISTINCT colours, one per footswitch, so the colour bytes are pinned
  // as a per-pedal array rather than as one repeated value — a fixture where
  // every pedal is white would pass an encoder that wrote the first colour
  // ten times, or that indexed the array backwards.
  final coloredPedals = customMode.copyWith(
    pedalColors: const [
      PedalColor(0xE6, 0xEE, 0xF9), // white
      PedalColor(0xEF, 0xBC, 0x72), // amber
      PedalColor(0xEE, 0x6B, 0x70), // red
      PedalColor(0xEF, 0x96, 0x66), // orange
      PedalColor(0x7A, 0xCB, 0x9E), // green
      PedalColor(0x73, 0xCF, 0xDF), // cyan
      PedalColor(0x82, 0xAA, 0xFF), // blue
      PedalColor(0xB1, 0x9A, 0xFA), // violet
      PedalColor(0x00, 0x00, 0x00), // off, which is a colour a user may pick
      PedalColor.defaultColor, // the default, explicitly
    ],
  );

  // What a downgraded wire's trackLeds decode back to: blue -> green.
  final degradedLeds = [
    for (final led in fxMode.trackLeds)
      if (led == PedalTrackLed.blue) PedalTrackLed.green else led,
  ];

  return {
    // Same logical content as `idle_rec` above, forced onto the legacy (v1)
    // wire — the D11 "today's baseline, must stay bit-identical" pairing.
    // Pinned in pedal_codec_test.dart against the exact pre-B5a fixture
    // bytes.
    'idle_rec_v1': (
      frame: goldenFrames()['idle_rec']!,
      version: PedalCodec.protocolVersionV1,
      decoded: goldenFrames()['idle_rec']!,
    ),

    // FX mode at v3: full fidelity.
    'fx_mode_v3': (
      frame: fxMode,
      version: PedalCodec.protocolVersionV3,
      decoded: fxMode,
    ),

    // Custom mode at v4: full fidelity, and the only version that has it.
    'custom_mode_v4': (
      frame: customMode,
      version: PedalCodec.protocolVersionV4,
      decoded: customMode,
    ),

    // Custom mode on the v3 wire: the mode degrades to play (mute). The
    // chain LEDs do NOT degrade — v3 carries blue — so this fixture isolates
    // the mode degrade from the LED one the fx twins pin.
    'custom_mode_v3': (
      frame: customMode,
      version: PedalCodec.protocolVersionV3,
      decoded: customMode.copyWith(mode: PedalMode.play),
    ),

    // The colours at v4: ten distinct hues, full fidelity.
    'pedal_colors_v4': (
      frame: coloredPedals,
      version: PedalCodec.protocolVersionV4,
      decoded: coloredPedals,
    ),

    // The same frame on the v3 wire: the colours have no bytes there, so they
    // fall off entirely and decode as the default palette — and the mode
    // degrades with them, since v3 has no fourth value either.
    'pedal_colors_v3': (
      frame: coloredPedals,
      version: PedalCodec.protocolVersionV3,
      decoded: coloredPedals.copyWith(
        mode: PedalMode.play,
        pedalColors: defaultPedalColors,
      ),
    ),

    // FX mode downgraded onto the v2 wire (B10): the mode field degrades to
    // play (mute) and the blue chain LEDs degrade to green; every other
    // byte is identical to the v3 twin.
    'fx_mode_v2': (
      frame: fxMode,
      version: PedalCodec.protocolVersionV2,
      decoded: fxMode.copyWith(mode: PedalMode.play, trackLeds: degradedLeds),
    ),

    // FX mode downgraded onto the v1 wire (B10 + D11): the mode and chain
    // LEDs degrade as at v2, AND the v2-only looperMode/countingIn fields
    // fall off the wire.
    'fx_mode_v1': (
      frame: fxMode,
      version: PedalCodec.protocolVersionV1,
      decoded: fxMode.copyWith(
        mode: PedalMode.play,
        trackLeds: degradedLeds,
        looperMode: PedalLooperMode.multi,
      ),
    ),
  };
}
