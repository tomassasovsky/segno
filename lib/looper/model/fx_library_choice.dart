import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';

/// The effect or saved sound selected in the library.
sealed class FxLibraryChoice {
  const FxLibraryChoice();
}

/// A factory rack preset, instantiated as a run of chain entries.
final class FxRackChoice extends FxLibraryChoice {
  /// Creates an [FxRackChoice].
  const FxRackChoice(this.preset);

  /// The selected factory preset.
  final FxPreset preset;
}

/// A standalone built-in effect.
final class FxSingleChoice extends FxLibraryChoice {
  /// Creates an [FxSingleChoice].
  const FxSingleChoice(this.type);

  /// The selected effect type.
  final TrackEffectType type;
}

/// A player's saved sound.
final class FxSavedChoice extends FxLibraryChoice {
  /// Creates an [FxSavedChoice].
  const FxSavedChoice(this.preset);

  /// The saved preset.
  final FxUserPreset preset;
}
