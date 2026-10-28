import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

/// What one pedal shows: how it looks ([spec]), its knobs and its LED.
class FxStompFace extends Equatable {
  /// Creates an [FxStompFace].
  FxStompFace({
    required this.spec,
    required this.knobs,
    this.led = FxStompLed.on,
    this.live = true,
  }) : assert(
         knobs.length <= spec.face.maxKnobs,
         'a face draws at most its maxKnobs knobs',
       );

  /// How the pedal looks.
  final FxStompSpec spec;

  /// The knobs, in reading order: at most the face's
  /// [FxStompFaceKind.maxKnobs].
  final List<FxStompKnob> knobs;

  /// What the LED shows.
  final FxStompLed led;

  /// Whether the knobs follow the effect, so they turn on a layer of their
  /// own. A still pedal's never turn.
  final bool live;

  @override
  List<Object?> get props => [spec, knobs, led, live];
}

/// What a pedal's LED shows.
enum FxStompLed {
  /// Lit, with its glow: the effect is engaged.
  on,

  /// Dark: the effect is bypassed.
  off,

  /// Its lens, unlit and not dark: a still pedal, which shows no state
  /// because its surface does not follow the rig.
  still,
}

/// One knob on a pedal.
class FxStompKnob extends Equatable {
  /// Creates an [FxStompKnob].
  const FxStompKnob({required this.label, required this.setting});

  /// The label under the knob.
  final String label;

  /// Where the knob points, from 0 (fully left) to 1 (fully right).
  final double setting;

  @override
  List<Object?> get props => [label, setting];
}

/// The controls a pedal of [module] shows as knobs on a face with room for
/// [room], as positions into [controls] (an entry's [fxEntryControls]).
///
/// Every control while they fit. A variant with more shows the first [room]
/// in the order the rack editor lists them, except where [kFxStompKnobKeys]
/// names the ones a module's pedal shows instead.
List<int> fxStompKnobs(
  String module,
  ({List<int> params, List<String> keys}) controls, {
  required int room,
}) {
  final count = controls.keys.length;
  if (count <= room) return [for (var i = 0; i < count; i++) i];
  final preferred = kFxStompKnobKeys[module] ?? const <String>{};
  final picked = [
    for (var i = 0; i < count; i++)
      if (preferred.contains(controls.keys[i])) i,
  ];
  // The table's controls first, then the rest in order until the face is
  // full: a face never holds more than [room], nor fewer while there are
  // controls left.
  return [
    ...picked.take(room),
    ...[
      for (var i = 0; i < count; i++)
        if (!picked.contains(i)) i,
    ].take(room - math.min(room, picked.length)),
  ]..sort();
}

/// The controls a module's pedal shows when its variant has more than its
/// face holds, by control key, where the first ones would be the wrong ones.
///
/// Ed's Rack's four-band EQ lists every band's cut, gain, frequency and Q,
/// so its first six are the low band and a mid. Its module face shows the
/// four band gains, which is what every other four-band EQ variant shows,
/// and the two cuts.
const Map<String, Set<String>> kFxStompKnobKeys = {
  'Four-band EQ': {
    'low_cut',
    'low_gain',
    'lo_mid_gain',
    'hi_mid_gain',
    'high_gain',
    'high_cut',
  },
};

/// Where a knob points when the pedal does not show its settings
/// ([FxPedalPicture.live] is false), in reading order: the design's own
/// sample angles.
const List<double> _kRestingSettings = [
  .5 - 60 / 270,
  .5 + 30 / 270,
  .5 - 20 / 270,
  .5 + 70 / 270,
  .5 + 10 / 270,
  .5 - 100 / 270,
];

/// The face [pedal] is drawn with, or `null` for a module with no look in
/// [kFxStompSpecs].
///
/// The knobs are the entry's own controls ([fxStompKnobs]), so a pedal never
/// shows a control that does not exist; they point at the entry's settings
/// when the pedal is live. A live pedal's LED is on while the effect is
/// engaged; a still pedal shows no state ([FxStompLed.still]).
FxStompFace? fxStompFace(AppLocalizations l10n, FxPedalPicture pedal) {
  final FxPedalPicture(:effect, :module, :controls, :live) = pedal;
  final spec = kFxStompSpecs[module.name];
  // A module with no look draws no pedal; a test keeps the table complete.
  if (spec == null) return null;
  final knobs = fxStompKnobs(
    module.name,
    controls,
    room: spec.face.maxKnobs,
  );
  return FxStompFace(
    spec: spec,
    live: live,
    led: !live
        ? FxStompLed.still
        : effect.enabled && pedal.chainOn
        ? FxStompLed.on
        : FxStompLed.off,
    knobs: [
      for (final (n, i) in knobs.indexed)
        FxStompKnob(
          label: l10n.fxParamKeyName(controls.keys[i]).toUpperCase(),
          setting: live && effect is BuiltInEffect
              ? fxEntryShownSetting(effect, controls.params[i])
              : _kRestingSettings[n % _kRestingSettings.length],
        ),
    ],
  );
}
