import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_color.dart';
import 'package:pedal_repository/src/pedal_mode.dart';

/// The colours a frame carries when nothing has set them: white on every
/// footswitch, which is the palette default on both sides of the wire.
const List<PedalColor> defaultPedalColors = [
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
  PedalColor.defaultColor,
];

/// Logical per-track activity, retained for snapshot consumers.
///
/// Physical indicators use the independent ten-button activity mask.
/// Encoded as the enum [index] in the state frame — do not reorder.
enum PedalTrackLed {
  /// Track is empty or muted — LED dark.
  off,

  /// Track has a loop that is playing — LED green.
  green,

  /// Track is recording / overdubbing or armed — LED red.
  red,

  /// Track's FX chain is enabled (FX mode) — LED blue.
  ///
  /// In [PedalMode.fx] the app writes chain-enabled state into the same
  /// `trackLeds` bytes for snapshot consumers.
  blue,
}

/// The transport activity color: what the console's ring sweeps in.
///
/// Semantic colors chosen by segno and rendered verbatim by the firmware.
/// Encoded as the enum [index] in the state frame — do not reorder.
enum GlobalColor {
  /// No global indication — LED dark.
  off,

  /// Idle / ready in Rec mode — green.
  green,

  /// Recording or armed — red.
  red,

  /// Play mode — amber.
  amber,

  /// Transient / busy (e.g. clear fade) — blue.
  blue,
}

/// The looper-mode code carried in every state frame.
///
/// This is a **value-only mirror** of `packages/segno_engine`'s `LooperMode`
/// enum (`multi/sync/song/band/free`, `code` 0-4) — `pedal_repository` is a
/// protocol/repo-layer package and cannot depend on `segno_engine` (an
/// app-facing DATA package two layers up), so the two enums are kept in
/// lockstep by hand rather than by import. Translating between them is an
/// app-layer concern for a later PR (the repository consumer already
/// projects [PedalMode] from the app's `InteractionMode` the same way — see
/// `lib/control/control_projection.dart`).
///
/// This is a **different axis from [PedalMode]**: [PedalMode] is the pedal's
/// own interaction mode (what a track press *does* — record vs. mute/arm,
/// wire bit 0, unaffected by this enum); [PedalLooperMode] is the engine's
/// looper mode (what the looper's transport *is* — Multi/Sync/Song/Band/Free).
/// The two enums never coexist as "the pedal's mode" and must not be
/// confused with each other (D10, D11).
///
/// Encoded as the enum [index] in the state frame — do not reorder.
enum PedalLooperMode {
  /// Independent per-track loops — today's behavior, and the engine default.
  multi,

  /// Primary-track ("crown") sync with multiples and divisions.
  sync,

  /// Section sequencing.
  song,

  /// Primary track plus independently start/stoppable, quantized sections.
  band,

  /// Independent per-track clocks.
  free,
}

/// An immutable snapshot of everything the pedal needs to render its LEDs.
///
/// segno projects looper state into a [PedalStateFrame], `PedalLinkCodec`
/// serializes it, and the firmware renders the last good frame. It carries
/// logical state for all eight tracks and physical state for all ten pills.
class PedalStateFrame extends Equatable {
  /// Creates a [PedalStateFrame].
  PedalStateFrame({
    required this.globalColor,
    required List<PedalTrackLed> trackLeds,
    required this.activeBank,
    required this.selectedTrack,
    required this.mode,
    required this.loopLengthMicros,
    required this.clearFadeActive,
    this.isGoodbye = false,
    this.performanceArmed = false,
    this.masterGain = 1,
    this.looperMode = PedalLooperMode.multi,
    this.countingIn = false,
    List<PedalColor> pedalColors = defaultPedalColors,
    this.activeButtonMask = 0,
  }) : trackLeds = List.unmodifiable(trackLeds),
       pedalColors = List.unmodifiable(pedalColors),
       assert(
         activeButtonMask >= 0 && activeButtonMask <= 0x3FF,
         'only ten physical activity bits are defined',
       ),
       assert(
         pedalColors.length == PedalButton.values.length,
         'a frame must carry one colour per footswitch',
       ),
       assert(
         trackLeds.length == trackCount,
         'a frame must carry exactly $trackCount track LEDs',
       ),
       assert(
         masterGain >= 0.0 && masterGain <= 1.0,
         'masterGain must be in 0.0..1.0',
       ),
       assert(
         activeBank == 0 || activeBank == 1,
         'activeBank must be 0 (A) or 1 (B)',
       ),
       assert(
         selectedTrack >= 0 && selectedTrack < trackCount,
         'selectedTrack must be in 0..${trackCount - 1}',
       ),
       assert(
         loopLengthMicros >= 0 && loopLengthMicros <= maxLoopLengthMicros,
         'loopLengthMicros out of range',
       ) {
    if (trackLeds.length != trackCount ||
        pedalColors.length != PedalButton.values.length ||
        activeButtonMask < 0 ||
        activeButtonMask > 0x3FF ||
        pedalColors.any(
          (c) =>
              c.r < 0 ||
              c.r > 255 ||
              c.g < 0 ||
              c.g > 255 ||
              c.b < 0 ||
              c.b > 255,
        )) {
      throw ArgumentError('Invalid pedal indicator frame');
    }
  }

  /// A blank, all-off frame.
  ///
  /// With [goodbye] set this is the shutdown frame segno sends on close; the
  /// firmware darkens its LEDs on receipt.
  factory PedalStateFrame.blank({bool goodbye = false}) => PedalStateFrame(
    globalColor: GlobalColor.off,
    trackLeds: List<PedalTrackLed>.filled(trackCount, PedalTrackLed.off),
    activeBank: 0,
    selectedTrack: 0,
    mode: PedalMode.rec,
    loopLengthMicros: 0,
    clearFadeActive: false,
    isGoodbye: goodbye,
  );

  /// The number of tracks carried in every frame (2 banks of 4).
  static const trackCount = 8;

  /// The maximum encodable loop length (unsigned 32-bit microseconds).
  static const maxLoopLengthMicros = 0xFFFFFFFF;

  /// Semantic transport activity for the independent ring renderer.
  final GlobalColor globalColor;

  /// Per-track LED state for all [trackCount] tracks, track 0 first.
  final List<PedalTrackLed> trackLeds;

  /// The active bank: `0` = A, `1` = B.
  final int activeBank;

  /// The selected-track (cursor) index shown by the pedal, `0`..[trackCount]-1.
  ///
  /// In Rec mode this is the selected track; in Play mode the armed *set* is
  /// carried by [trackLeds] (green), and this stays the last cursor.
  final int selectedTrack;

  /// Which behavior set the footswitches drive (Rec vs Play).
  final PedalMode mode;

  /// The active loop length in microseconds (`0` when there is no loop).
  final int loopLengthMicros;

  /// Whether a clear fade is currently in progress.
  final bool clearFadeActive;

  /// Whether this is the shutdown frame — all LEDs off, sent so the console
  /// darkens when segno quits while the board stays powered.
  final bool isGoodbye;

  /// Whether performance-recording is armed (D-PEDAL). On the wire; the
  /// console board does not render it (armed already shows on the screens).
  final bool performanceArmed;

  /// The engine's master output gain, `0.0`..`1.0` (the value the encoder
  /// adjusts), quantized to one 0..255 byte on the wire. The board shows it
  /// as a filled arc on the ring for a moment after it changes: the encoder
  /// has no indicator of its own, so the ring is its readout.
  final double masterGain;

  /// The engine's looper mode (Multi/Sync/Song/Band/Free) — a **different
  /// axis from [mode]**; see [PedalLooperMode]'s doc comment.
  final PedalLooperMode looperMode;

  /// Whether the engine is currently counting in before a defining recording
  /// (A2/D9). On the wire; the console board does not render it.
  final bool countingIn;

  /// Saved hues in [PedalButton] order, detached from the caller.
  final List<PedalColor> pedalColors;

  /// Authoritative physical activity; bit [PedalButton.index] is active.
  /// Reserved bits 10–15 must be zero. Logical track LEDs do not override it.
  final int activeButtonMask;

  /// The configured hue, independent of activity.
  PedalColor colorFor(PedalButton button) => pedalColors[button.index];

  /// Whether this physical button is active in the published frame.
  bool isLit(PedalButton button) =>
      !isGoodbye && (activeButtonMask & (1 << button.index)) != 0;

  /// Returns a copy with the given fields replaced.
  PedalStateFrame copyWith({
    GlobalColor? globalColor,
    List<PedalTrackLed>? trackLeds,
    int? activeBank,
    int? selectedTrack,
    PedalMode? mode,
    int? loopLengthMicros,
    bool? clearFadeActive,
    bool? isGoodbye,
    bool? performanceArmed,
    double? masterGain,
    PedalLooperMode? looperMode,
    bool? countingIn,
    List<PedalColor>? pedalColors,
    int? activeButtonMask,
  }) {
    return PedalStateFrame(
      globalColor: globalColor ?? this.globalColor,
      trackLeds: trackLeds ?? this.trackLeds,
      activeBank: activeBank ?? this.activeBank,
      selectedTrack: selectedTrack ?? this.selectedTrack,
      mode: mode ?? this.mode,
      loopLengthMicros: loopLengthMicros ?? this.loopLengthMicros,
      clearFadeActive: clearFadeActive ?? this.clearFadeActive,
      isGoodbye: isGoodbye ?? this.isGoodbye,
      performanceArmed: performanceArmed ?? this.performanceArmed,
      masterGain: masterGain ?? this.masterGain,
      looperMode: looperMode ?? this.looperMode,
      countingIn: countingIn ?? this.countingIn,
      pedalColors: pedalColors ?? this.pedalColors,
      activeButtonMask: activeButtonMask ?? this.activeButtonMask,
    );
  }

  @override
  List<Object?> get props => [
    globalColor,
    trackLeds,
    activeBank,
    selectedTrack,
    mode,
    loopLengthMicros,
    clearFadeActive,
    isGoodbye,
    performanceArmed,
    masterGain,
    looperMode,
    countingIn,
    pedalColors,
    activeButtonMask,
  ];

  @override
  String toString() =>
      'PedalStateFrame(global: ${globalColor.name}, '
      'tracks: ${trackLeds.map((l) => l.name).join(",")}, '
      'bank: $activeBank, selected: $selectedTrack, '
      'mode: ${mode.name}, loopUs: $loopLengthMicros, '
      'clearFade: $clearFadeActive, goodbye: $isGoodbye, '
      'performanceArmed: $performanceArmed, masterGain: $masterGain, '
      'looperMode: ${looperMode.name}, countingIn: $countingIn)';
}
