import 'package:flutter/painting.dart';

/// The enclosure colour of each catalogue pedal, by module name.
///
/// Each is the colour of the module's former Looper X illustration (the
/// first of its numbered variants, which is the one the app drew), sampled
/// as the most common opaque colour after the rubber-pad grey every
/// illustration shared. The Transient takes its green top plate rather than
/// its near-black body, which would draw it as an overdrive. Where two
/// illustrations shared a colour (the compressor and the vinyl, the
/// low-pass filter and the parametric EQ), their pedals do too: this keeps
/// each effect's colour identity, and the name on the treadle tells them
/// apart.
const Map<String, Color> kFxStompColours = {
  'Amp': Color(0xFFE7AD42),
  'Compressor': Color(0xFF001021),
  'Overdrive': Color(0xFF090909),
  'Distortion': Color(0xFF627EC5),
  'Four-band EQ': Color(0xFF020202),
  // EQ5's colour: the Looper X's single-effect artwork list runs in
  // effect-name order and puts EQ5 where Parametric EQ falls.
  'Parametric EQ': Color(0xFFB0AFB0),
  'Low-pass filter': Color(0xFFB0AFB0),
  'Wah': Color(0xFF0E0E0E),
  'Chorus': Color(0xFF52C986),
  'Modulation': Color(0xFF744AC9),
  'Octaver': Color(0xFFFAB055),
  'Pitch shift': Color(0xFF4FBCD9),
  'Whammy': Color(0xFF9B2025),
  'Delay': Color(0xFF2BC8CF),
  // Delay6's colour, for the same reason as the parametric EQ's.
  'Dub delay': Color(0xFFD18B94),
  'Reverb': Color(0xFF377085),
  'Spring reverb': Color(0xFF142438),
  'Ambience': Color(0xFF060D3E),
  'Dub reverb': Color(0xFF9A0E0C),
  'Doubler': Color(0xFFCBCBCC),
  'High-pass gate': Color(0xFFFEFCFE),
  'Transient': Color(0xFF7BB96C),
  'Pumper': Color(0xFF012468),
  'Slicer': Color(0xFFEAE3CF),
  'Vinyl': Color(0xFF001021),
  'Degrade': Color(0xFF873E0B),
  'Harmonizer': Color(0xFFC5E7E2),
  'Smart tune': Color(0xFFE4E6E6),
};

/// The colour a pedal of a module missing from [kFxStompColours] is drawn
/// in: a plain grey, so it still draws. A test keeps the table complete.
const Color kFxStompFallbackColour = Color(0xFF6C727A);
