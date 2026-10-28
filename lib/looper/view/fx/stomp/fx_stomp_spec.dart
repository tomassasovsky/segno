import 'package:flutter/painting.dart';

/// The five kinds of enclosure a pedal is drawn as, each with its own
/// proportions and room for knobs (the approved pedal design, #1501).
enum FxStompFaceKind {
  /// A stomp box with a hinged treadle carrying the name.
  treadle(Size(450, 662), 4),

  /// A rounded box with the knobs on top and a hex-nut stomp switch.
  box(Size(450, 662), 6),

  /// A coloured inset panel that holds the knobs.
  window(Size(450, 760), 4),

  /// A tall panel with a display under the title and two columns of knobs.
  module(Size(450, 1000), 6),

  /// A rubber rocker treadle, the name along its side, and no knobs.
  rocker(Size(450, 780), 0);

  const FxStompFaceKind(this.size, this.maxKnobs);

  /// The face's drawing space.
  final Size size;

  /// The most knobs the face has room for.
  final int maxKnobs;
}

/// How a knob is made.
enum FxStompKnobStyle {
  /// Knurled black, with a cap and a light pointer.
  black,

  /// A polished metal dome.
  dome,

  /// A cream cap on a black skirt.
  cream,

  /// A cream chicken-head pointer.
  chicken,

  /// A coloured cap ([FxStompSpec.knobCap]) on a black skirt.
  cap,
}

/// The body's finish.
enum FxStompFinish {
  /// A plain vertical gradient of the base colour.
  plain,

  /// Hammertone.
  hammer,

  /// Metal flake.
  flake,

  /// Brushed metal.
  brush,

  /// Marble.
  marble,

  /// Split diagonally between the base and [FxStompSpec.base2].
  split,

  /// Faded from [FxStompSpec.base2] at the top to the base at the bottom.
  fade,
}

/// The picture on a pedal's face that shows what the effect does.
enum FxStompGraphic {
  /// No picture.
  none,

  /// Flames along the top of the face (Overdrive).
  flames,

  /// A clipped square wave (Distortion).
  clip,

  /// Three crossing sine waves (Chorus).
  sines,

  /// A spiral (Modulation).
  swirl,

  /// Spreading ripples (Reverb).
  ripples,

  /// A starfield with a nebula (Ambience).
  stars,

  /// Concentric octave bands (Octaver).
  octaves,

  /// Tweed cloth (Amp).
  tweed,

  /// Diagonal slices (Slicer).
  slices,

  /// The name fading into echoes on the treadle (Delay).
  echo,

  /// Two tape reels (Dub delay).
  reels,

  /// A spring coil across the treadle (Spring reverb).
  spring,

  /// Gate pulses (High-pass gate).
  gate,

  /// A staff with chords on it (Harmonizer).
  staff,

  /// A tuner arc (Smart tune).
  tuner,

  /// Pitch arrows (Pitch shift).
  arrows,

  /// A pumping curve (Pumper).
  pump,

  /// A transient spike (Transient).
  spike,

  /// Two overlapping circles (Doubler).
  doubled,

  /// Chevrons along the side band (Whammy).
  chevrons,
}

/// The screen on a module face.
enum FxStompDisplay {
  /// No screen.
  none,

  /// A VU meter (Compressor).
  vu,

  /// A four-band EQ curve (Four-band EQ).
  eq4,

  /// A bell curve (Parametric EQ).
  bell,

  /// A low-pass curve with a resonant peak (Low-pass filter).
  lpf,

  /// A record (Vinyl).
  record,

  /// Pixel bars (Degrade).
  pixels,
}

/// How one catalogue pedal looks: its face, its printed name and type, its
/// colours, knobs, LED, finish and face picture.
///
/// A reading of the approved design's per-pedal table (`pedal(...)` in
/// segno-design `docs/design/own-art/pedal_faces_v3.py`).
class FxStompSpec {
  /// Creates an [FxStompSpec].
  const FxStompSpec({
    required this.face,
    required this.name,
    required this.base,
    required this.font,
    required this.size,
    this.knob = FxStompKnobStyle.black,
    this.knobCap,
    this.led = const Color(0xFFFF3B2B),
    this.finish = FxStompFinish.plain,
    this.graphic = FxStompGraphic.none,
    this.display = FxStompDisplay.none,
    this.base2,
    this.panel,
    this.ink,
    this.accent = const Color(0xFFF4F6F8),
    this.titleY,
    this.tilt = 0,
    this.bold = false,
    this.outline,
  });

  /// The enclosure kind.
  final FxStompFaceKind face;

  /// The name printed on the pedal.
  final String name;

  /// The enclosure colour.
  final Color base;

  /// The second colour of a [FxStompFinish.split] or [FxStompFinish.fade]
  /// body.
  final Color? base2;

  /// The inset panel colour of a [FxStompFaceKind.window] face.
  final Color? panel;

  /// The name's typeface.
  final String font;

  /// The name's size.
  final double size;

  /// Whether the name is set bold.
  final bool bold;

  /// The colour of an outline under the name, or `null` for none.
  final Color? outline;

  /// The knob style.
  final FxStompKnobStyle knob;

  /// The cap colour of a [FxStompKnobStyle.cap] knob.
  final Color? knobCap;

  /// The pointer colour of a [FxStompKnobStyle.black] knob.
  final Color accent;

  /// The LED colour.
  final Color led;

  /// The body finish.
  final FxStompFinish finish;

  /// The face picture.
  final FxStompGraphic graphic;

  /// The screen of a [FxStompFaceKind.module] face.
  final FxStompDisplay display;

  /// The print colour, where the design sets one instead of [fxStompInk].
  final Color? ink;

  /// The name's baseline, where the design moves it from the face's own.
  final double? titleY;

  /// How far the name is turned, in degrees.
  final double tilt;

  /// The colour names and labels print in on the body.
  Color get bodyInk => ink ?? fxStompInk(base);

  /// The colour the knob labels print in on a window face's panel.
  Color get panelInk => fxStompInk(panel ?? base);
}

/// Dark print on a light colour, light print on a dark one: the design's
/// luma rule.
Color fxStompInk(Color colour) {
  final luma = .299 * colour.r + .587 * colour.g + .114 * colour.b;
  return luma > .62 ? kFxStompDarkInk : kFxStompLightInk;
}

/// The dark print colour.
const Color kFxStompDarkInk = Color(0xFF16181C);

/// The light print colour.
const Color kFxStompLightInk = Color(0xFFF6F8FA);

/// How every catalogue pedal looks, by module name.
const Map<String, FxStompSpec> kFxStompSpecs = {
  // treadle
  'Overdrive': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'Overdrive',
    base: Color(0xFF1B1C1F),
    font: 'Shrikhand',
    size: 64,
    led: Color(0xFFFF6A1F),
    finish: FxStompFinish.hammer,
    graphic: FxStompGraphic.flames,
    tilt: -4,
    accent: Color(0xFFFF8A3A),
  ),
  'Distortion': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'DIST',
    base: Color(0xFF3C5FC4),
    font: 'Bungee',
    size: 84,
    led: Color(0xFFFFD400),
    finish: FxStompFinish.flake,
    graphic: FxStompGraphic.clip,
    titleY: 400,
  ),
  'Chorus': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'Chorus',
    base: Color(0xFF3FBF7C),
    font: 'Pacifico',
    size: 70,
    led: Color(0xFF5CF2A8),
    graphic: FxStompGraphic.sines,
    titleY: 388,
  ),
  'Modulation': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'MOD',
    base: Color(0xFF6A3FD0),
    font: 'Audiowide',
    size: 84,
    knob: FxStompKnobStyle.cap,
    knobCap: Color(0xFFB58CFF),
    led: Color(0xFFB58CFF),
    finish: FxStompFinish.flake,
    graphic: FxStompGraphic.swirl,
    titleY: 398,
  ),
  'Delay': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'DELAY',
    base: Color(0xFF1FB8C2),
    font: 'Righteous',
    size: 72,
    led: Color(0xFF3AD6FF),
    graphic: FxStompGraphic.echo,
    titleY: 392,
  ),
  'Dub delay': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'DUB',
    base: Color(0xFFD5838F),
    base2: Color(0xFF2C7A3E),
    font: 'Rubik Mono One',
    size: 84,
    knob: FxStompKnobStyle.cream,
    led: Color(0xFFFFE14A),
    finish: FxStompFinish.split,
    graphic: FxStompGraphic.reels,
    titleY: 400,
  ),
  'Spring reverb': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'Spring',
    base: Color(0xFF132A44),
    font: 'Rye',
    size: 66,
    knob: FxStompKnobStyle.cream,
    led: Color(0xFFFFB02E),
    graphic: FxStompGraphic.spring,
    titleY: 380,
    ink: Color(0xFFF1D39A),
  ),
  'High-pass gate': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'GATE',
    base: Color(0xFFF5F3F0),
    font: 'Bebas Neue',
    size: 96,
    led: Color(0xFF2EE66B),
    graphic: FxStompGraphic.gate,
    titleY: 400,
  ),
  'Harmonizer': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'Harmony',
    base: Color(0xFFBFE6DF),
    font: 'Lobster',
    size: 72,
    knob: FxStompKnobStyle.cap,
    knobCap: Color(0xFF2F8F86),
    led: Color(0xFF2FD9C5),
    graphic: FxStompGraphic.staff,
    titleY: 392,
  ),
  'Smart tune': FxStompSpec(
    face: FxStompFaceKind.treadle,
    name: 'TUNE',
    base: Color(0xFFDFE2E3),
    font: 'Space Mono',
    size: 76,
    led: Color(0xFF2EE66B),
    finish: FxStompFinish.brush,
    graphic: FxStompGraphic.tuner,
    titleY: 398,
    bold: true,
  ),
  // box
  'Reverb': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'REVERB',
    base: Color(0xFF2F6F86),
    font: 'Monoton',
    size: 64,
    knob: FxStompKnobStyle.dome,
    led: Color(0xFF7FE0FF),
    graphic: FxStompGraphic.ripples,
  ),
  'Ambience': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'Ambience',
    base: Color(0xFF0A0F3A),
    font: 'Audiowide',
    size: 50,
    knob: FxStompKnobStyle.dome,
    led: Color(0xFFB56CFF),
    graphic: FxStompGraphic.stars,
  ),
  'Dub reverb': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'DUB VERB',
    base: Color(0xFFB0120F),
    font: 'Shrikhand',
    size: 56,
    knob: FxStompKnobStyle.cream,
    led: Color(0xFFFFE14A),
    finish: FxStompFinish.marble,
    outline: Color(0xFF4A0000),
  ),
  'Amp': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'Amp',
    base: Color(0xFFE3A73C),
    font: 'Fascinate',
    size: 104,
    knob: FxStompKnobStyle.chicken,
    graphic: FxStompGraphic.tweed,
    ink: Color(0xFF2A1A08),
    titleY: 410,
  ),
  'Octaver': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'OCTAVES',
    base: Color(0xFF2B1A4A),
    font: 'Righteous',
    size: 66,
    led: Color(0xFFFFB31A),
    graphic: FxStompGraphic.octaves,
    titleY: 405,
  ),
  'Slicer': FxStompSpec(
    face: FxStompFaceKind.box,
    name: 'SLICER',
    base: Color(0xFFEFE8D6),
    font: 'Bebas Neue',
    size: 96,
    graphic: FxStompGraphic.slices,
    titleY: 430,
  ),
  // window
  'Pitch shift': FxStompSpec(
    face: FxStompFaceKind.window,
    name: 'PITCH',
    base: Color(0xFF3FB6D6),
    panel: Color(0xFFF6B2CF),
    font: 'Righteous',
    size: 76,
    led: Color(0xFFFF7AB8),
    graphic: FxStompGraphic.arrows,
  ),
  'Pumper': FxStompSpec(
    face: FxStompFaceKind.window,
    name: 'PUMPER',
    base: Color(0xFF0A2A78),
    panel: Color(0xFFF5A52E),
    font: 'Bungee',
    size: 60,
    led: Color(0xFFFFA52E),
    finish: FxStompFinish.flake,
    graphic: FxStompGraphic.pump,
  ),
  'Transient': FxStompSpec(
    face: FxStompFaceKind.window,
    name: 'TRANSIENT',
    base: Color(0xFF1F2226),
    panel: Color(0xFF7BC46C),
    font: 'Audiowide',
    size: 50,
    led: Color(0xFF7BF26C),
    finish: FxStompFinish.hammer,
    graphic: FxStompGraphic.spike,
  ),
  'Doubler': FxStompSpec(
    face: FxStompFaceKind.window,
    name: 'Doubler',
    base: Color(0xFFD2D3D6),
    panel: Color(0xFFEAA6D0),
    font: 'Lobster',
    size: 74,
    led: Color(0xFFFF5FB4),
    finish: FxStompFinish.brush,
    graphic: FxStompGraphic.doubled,
  ),
  // module
  'Compressor': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'COMP',
    base: Color(0xFF0D1D33),
    font: 'Bebas Neue',
    size: 76,
    knob: FxStompKnobStyle.dome,
    led: Color(0xFFFFB02E),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.vu,
  ),
  'Four-band EQ': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'EQ',
    base: Color(0xFF1B1C1F),
    font: 'Bebas Neue',
    size: 76,
    knob: FxStompKnobStyle.cap,
    knobCap: Color(0xFF2AB0FF),
    led: Color(0xFF2AB0FF),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.eq4,
  ),
  'Parametric EQ': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'PARA EQ',
    base: Color(0xFFB5B4B5),
    font: 'Bebas Neue',
    size: 76,
    led: Color(0xFFFF9A2E),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.bell,
  ),
  'Low-pass filter': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'LPF',
    base: Color(0xFFC9C8C9),
    font: 'Bebas Neue',
    size: 76,
    knob: FxStompKnobStyle.cap,
    knobCap: Color(0xFFE8433A),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.lpf,
  ),
  'Vinyl': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'VINYL',
    base: Color(0xFF122238),
    font: 'Lobster',
    size: 70,
    knob: FxStompKnobStyle.cream,
    led: Color(0xFFFFB02E),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.record,
  ),
  'Degrade': FxStompSpec(
    face: FxStompFaceKind.module,
    name: 'DEGRADE',
    base: Color(0xFF8A3F0C),
    font: 'Press Start 2P',
    size: 34,
    led: Color(0xFF7BF26C),
    finish: FxStompFinish.brush,
    display: FxStompDisplay.pixels,
  ),
  // rocker
  'Wah': FxStompSpec(
    face: FxStompFaceKind.rocker,
    name: 'Wah',
    base: Color(0xFF141517),
    font: 'Shrikhand',
    size: 88,
    finish: FxStompFinish.hammer,
  ),
  'Whammy': FxStompSpec(
    face: FxStompFaceKind.rocker,
    name: 'WHAM',
    base: Color(0xFFA3171C),
    font: 'Bungee',
    size: 72,
    led: Color(0xFFFFE14A),
    finish: FxStompFinish.flake,
    graphic: FxStompGraphic.chevrons,
  ),
};

/// How a pedal of a module missing from [kFxStompSpecs] looks: a plain grey
/// treadle under the module's name, so it still draws. A test keeps the
/// table complete.
FxStompSpec fxStompFallbackSpec(String module) => FxStompSpec(
  face: FxStompFaceKind.treadle,
  name: module.toUpperCase(),
  base: const Color(0xFF6C727A),
  font: 'Inter',
  size: 56,
);
