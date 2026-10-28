import 'package:equatable/equatable.dart';
import 'package:flutter/painting.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

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
/// where [_kFxStompKnobKeys] names the four a module's pedal shows instead.
List<int> fxStompKnobs(
  String module,
  ({List<int> params, List<String> keys}) controls,
) {
  final count = controls.keys.length;
  if (count <= kFxStompMaxKnobs) return [for (var i = 0; i < count; i++) i];
  final preferred = _kFxStompKnobKeys[module];
  if (preferred != null) {
    final picked = [
      for (var i = 0; i < count; i++)
        if (preferred.contains(controls.keys[i])) i,
    ];
    if (picked.length == kFxStompMaxKnobs) return picked;
  }
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
const Map<String, Set<String>> _kFxStompKnobKeys = {
  'Four-band EQ': {'low_gain', 'lo_mid_gain', 'hi_mid_gain', 'high_gain'},
  'Compressor': {'threshold', 'ratio', 'attack', 'makeup'},
};

/// The face of the pedal [effect] is drawn as, or `null` when it is not one
/// of the catalogue's pedals.
///
/// The knobs are the entry's own controls ([fxStompKnobs]) at their current
/// settings, so a pedal never shows a control that does not exist. The
/// subtitle is the factory rack the entry came from, when it came from one.
FxStompFace? fxStompFace(AppLocalizations l10n, BuiltInEffect effect) {
  final name = effect.module;
  final module = name == null ? null : fxModuleNamed(name);
  if (module == null) return null;
  final controls = fxEntryControls(effect);
  return FxStompFace(
    name: module.name.toUpperCase(),
    subtitle: _family(effect)?.toUpperCase(),
    colour: module.colour,
    knobs: [
      for (final i in fxStompKnobs(module.name, controls))
        FxStompKnob(
          label: l10n.fxParamKeyName(controls.keys[i]).toUpperCase(),
          setting: fxEntryShownSetting(effect, controls.params[i]),
        ),
    ],
  );
}

/// The factory family of [effect]'s rack, by its artwork slug, or `null`.
String? _family(BuiltInEffect effect) {
  final slug = effect.rack?.art;
  if (slug == null) return null;
  for (final MapEntry(:key, :value) in kFxFamilySlugs.entries) {
    if (value == slug) return key;
  }
  return null;
}
