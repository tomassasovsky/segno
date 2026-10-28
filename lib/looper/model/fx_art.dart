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

/// A catalogue pedal, drawn in code from its [effect]: its module's colour,
/// its controls and their current values.
final class FxPedalPicture extends FxArt {
  /// Creates an [FxPedalPicture].
  const FxPedalPicture(this.effect);

  /// The chain entry the pedal stands for.
  final BuiltInEffect effect;

  @override
  List<Object?> get props => [effect];
}

/// The pedal [effect] is drawn as, or `null` when it is not one of the
/// catalogue's pedals.
FxPedalPicture? fxEntryArt(TrackEffect effect) {
  if (effect is! BuiltInEffect) return null;
  final module = effect.module;
  if (module == null || fxModuleNamed(module) == null) return null;
  return FxPedalPicture(effect);
}
