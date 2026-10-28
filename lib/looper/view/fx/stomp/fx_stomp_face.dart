import 'package:equatable/equatable.dart';
import 'package:flutter/painting.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_colours.dart';

/// The most knobs a pedal has room for.
const int kFxStompMaxKnobs = 4;

/// What one pedal shows: its name, the rack it came from, its colour and
/// its knobs.
class FxStompFace extends Equatable {
  /// Creates an [FxStompFace].
  const FxStompFace({
    required this.name,
    required this.colour,
    required this.knobs,
    this.subtitle,
  }) : assert(knobs.length <= kFxStompMaxKnobs, 'a pedal has four knobs');

  /// The pedal's name, as the treadle prints it.
  final String name;

  /// The line under the name, or `null` for none.
  final String? subtitle;

  /// The enclosure colour.
  final Color colour;

  /// The knobs, left to right.
  final List<FxStompKnob> knobs;

  @override
  List<Object?> get props => [name, subtitle, colour, knobs];
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

/// The controls a pedal of [module] shows as knobs, as positions into
/// [controls] (an entry's [fxEntryControls]).
///
/// Every control while there are at most [kFxStompMaxKnobs]. A variant with
/// more shows the first four in the order the rack editor lists them, except
/// where [kFxStompKnobKeys] names the four a module's pedal shows instead.
List<int> fxStompKnobs(
  String module,
  ({List<int> params, List<String> keys}) controls,
) {
  final count = controls.keys.length;
  if (count <= kFxStompMaxKnobs) return [for (var i = 0; i < count; i++) i];
  final preferred = kFxStompKnobKeys[module];
  final picked = [
    for (var i = 0; i < count; i++)
      if (preferred?.contains(controls.keys[i]) ?? false) i,
  ];
  // A table entry that no longer names four of the variant's controls is
  // caught by the factory-pedal test; the pedal still draws meanwhile.
  if (picked.length == kFxStompMaxKnobs) return picked;
  return [for (var i = 0; i < kFxStompMaxKnobs; i++) i];
}

/// The four controls a module's pedal shows when its variant has more, by
/// control key, where the first four would be the wrong ones.
///
/// - Ed's Rack's four-band EQ lists every band's cut, gain, frequency and Q,
///   so its first four are all the low band. The pedal shows the four gains,
///   which is what every other four-band EQ variant shows.
/// - Ed's Rack's compressor lists makeup fifth. Every other compressor
///   variant keeps makeup (the Drum Rack's keeps threshold, attack and
///   makeup), so the pedal shows makeup and leaves out release.
const Map<String, Set<String>> kFxStompKnobKeys = {
  'Four-band EQ': {'low_gain', 'lo_mid_gain', 'hi_mid_gain', 'high_gain'},
  'Compressor': {'threshold', 'ratio', 'attack', 'makeup'},
};

/// Where a knob points when the pedal does not show its settings
/// ([FxPedalPicture.live] is false), left to right.
const List<double> _kRestingSettings = [.35, .6, .45, .7];

/// The face [pedal] is drawn with.
///
/// The knobs are the entry's own controls ([fxStompKnobs]), so a pedal never
/// shows a control that does not exist; they point at the entry's settings
/// when the pedal is live. The subtitle is the factory rack whose variant
/// the entry is ([_variantFamily]), when it is one.
FxStompFace fxStompFace(AppLocalizations l10n, FxPedalPicture pedal) {
  final FxPedalPicture(:effect, :module, :live) = pedal;
  final controls = fxEntryControls(effect);
  final knobs = fxStompKnobs(module.name, controls);
  return FxStompFace(
    name: module.name.toUpperCase(),
    subtitle: _variantFamily(effect, module)?.toUpperCase(),
    colour: kFxStompColours[module.name] ?? kFxStompFallbackColour,
    knobs: [
      for (final (n, i) in knobs.indexed)
        FxStompKnob(
          label: l10n.fxParamKeyName(controls.keys[i]).toUpperCase(),
          setting: live
              ? fxEntryShownSetting(effect, controls.params[i])
              : _kRestingSettings[n],
        ),
    ],
  );
}

/// The factory rack family whose variant of [module] [effect] is
/// ([fxEntryBuild]), or `null` when it is none.
///
/// Read from the controls the entry carries, not from the rack it sits in: a
/// pedal added to another family's rack keeps its own family. Where several
/// families share one variant, the family of the rack the entry sits in, if
/// it is one of them, and otherwise the first. A module this build has no
/// variant of at all (the Harmonizer) takes its rack's family when the
/// module belongs there.
String? _variantFamily(BuiltInEffect effect, FxModule module) {
  final slug = effect.rack?.art;
  final variants = kFxModuleVariants[module.name];
  if (variants == null) {
    for (final MapEntry(key: family, value: familySlug)
        in kFxFamilySlugs.entries) {
      if (familySlug == slug && module.appearsIn(family)) return family;
    }
    return null;
  }
  final build = fxEntryBuild(effect);
  if (build == null) return null;
  final families = [
    for (final MapEntry(:key, :value) in variants.entries)
      if (identical(value, build)) key,
  ];
  for (final family in families) {
    if (kFxFamilySlugs[family] == slug) return family;
  }
  return families.firstOrNull;
}
