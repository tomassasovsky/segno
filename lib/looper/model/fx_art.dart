import 'package:equatable/equatable.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';

/// The picture a surface draws for a rack or one of its pedals.
sealed class FxArt extends Equatable {
  const FxArt();
}

/// A rack's footswitch picture, from the catalogue package.
final class FxRackPicture extends FxArt {
  /// Creates an [FxRackPicture] for the catalogue artwork [slug].
  const FxRackPicture(this.slug);

  /// The catalogue artwork slug ([FxRack.art]).
  final String slug;

  /// The image's path in the catalogue package.
  String get asset => fxFootswitchAsset(slug);

  @override
  List<Object?> get props => [slug];
}

/// A pedal drawn in code from its [effect]: its [look], its controls and,
/// when [live], their current settings.
///
/// Made by [fxEntryArt], which resolves the [look] and the [controls].
final class FxPedalPicture extends FxArt {
  const FxPedalPicture._(
    this.effect,
    this.look,
    this.controls, {
    required this.live,
    this.chainOn = true,
  });

  /// The chain entry the pedal stands for.
  final TrackEffect effect;

  /// Whether the chain the entry is in is switched on. A live pedal in a
  /// chain switched off is not engaged, whatever its own power.
  final bool chainOn;

  /// The name of the look it is drawn with: a catalogue pedal's module
  /// name, or for a standalone built-in its [kFxBuiltInLooks] entry.
  final String look;

  /// The controls it shows knobs for: a built-in entry's
  /// ([fxEntryControls]), and none for an entry this build runs as a plugin.
  final ({List<int> params, List<String> keys}) controls;

  /// Whether its knobs and LED show [effect]'s state. A surface that does
  /// not rebuild when the effect changes passes `false`, and its pedal draws
  /// them at rest instead, so they never show a stale value.
  final bool live;

  /// A live picture is its effect's state; a still one is only which pedal
  /// it is, so a change of setting or power does not make it a different
  /// picture.
  @override
  List<Object?> get props => live
      ? [effect, look, live, chainOn]
      : [
          effect.slotId,
          effect.rack?.art,
          look,
          effect.typeCode,
          ...controls.keys,
          live,
        ];
}

/// The look each standalone built-in is drawn with, by type: the catalogue
/// pedal's where the built-in is that kind of pedal, and one of its own
/// (Tremolo, Echo) where no catalogue pedal is.
///
/// A standalone built-in names no catalogue module ([TrackEffect.module] is
/// `null`: the singles library adds it by type), so without this table it
/// would draw no pedal at all (#1730).
const Map<TrackEffectType, String> kFxBuiltInLooks = {
  TrackEffectType.drive: 'Overdrive',
  TrackEffectType.filter: 'Low-pass filter',
  TrackEffectType.delay: 'Delay',
  TrackEffectType.tremolo: 'Tremolo',
  TrackEffectType.octaver: 'Octaver',
  TrackEffectType.echo: 'Echo',
  TrackEffectType.reverb: 'Reverb',
};

/// The pedal [effect] is drawn as, or `null` when it is neither one of the
/// catalogue's pedals nor a standalone built-in.
///
/// An entry that names a catalogue module is drawn with that module's look,
/// whatever engine type it runs on, and one naming a module the catalogue
/// does not have draws nothing. A built-in that names no module is drawn
/// with its type's [kFxBuiltInLooks] entry.
///
/// [live] says whether the surface asking rebuilds when the effect's
/// settings change ([FxPedalPicture.live]).
FxPedalPicture? fxEntryArt(
  TrackEffect effect, {
  required bool live,
  bool chainOn = true,
}) {
  final name = effect.module;
  final look = name != null
      ? fxModuleNamed(name)?.name
      : effect is BuiltInEffect
      ? kFxBuiltInLooks[effect.type]
      : null;
  if (look == null) return null;
  return FxPedalPicture._(
    effect,
    look,
    effect is BuiltInEffect
        ? fxEntryControls(effect)
        : (params: const <int>[], keys: const <String>[]),
    live: live,
    chainOn: chainOn,
  );
}
