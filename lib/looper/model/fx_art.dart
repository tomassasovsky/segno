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

/// A catalogue pedal, drawn in code from its [effect]: its module's look,
/// its controls and, when [live], their current settings.
///
/// Made by [fxEntryArt], which resolves the [module] and the [controls].
final class FxPedalPicture extends FxArt {
  const FxPedalPicture._(
    this.effect,
    this.module,
    this.controls, {
    required this.live,
  });

  /// The chain entry the pedal stands for.
  final TrackEffect effect;

  /// The catalogue module it is.
  final FxModule module;

  /// The controls it shows knobs for: a built-in entry's
  /// ([fxEntryControls]), and none for an entry this build runs as a plugin.
  final ({List<int> params, List<String> keys}) controls;

  /// Whether its knobs and LED show [effect]'s state. A surface that does
  /// not rebuild when a setting changes passes `false`, and its pedal draws
  /// them at rest instead, so they never show a stale value.
  final bool live;

  /// A live picture is its effect's state; a still one is only which pedal
  /// it is, so a setting change does not make it a different picture.
  @override
  List<Object?> get props => live
      ? [effect, module.name, live]
      : [
          effect.slotId,
          effect.rack?.art,
          module.name,
          effect.typeCode,
          ...controls.keys,
          live,
        ];
}

/// The pedal [effect] is drawn as, or `null` when it does not name one of
/// the catalogue's pedals.
///
/// [live] says whether the surface asking rebuilds when the effect's
/// settings change ([FxPedalPicture.live]).
FxPedalPicture? fxEntryArt(TrackEffect effect, {required bool live}) {
  final name = effect.module;
  final module = name == null ? null : fxModuleNamed(name);
  if (module == null) return null;
  return FxPedalPicture._(
    effect,
    module,
    effect is BuiltInEffect
        ? fxEntryControls(effect)
        : (params: const <int>[], keys: const <String>[]),
    live: live,
  );
}
