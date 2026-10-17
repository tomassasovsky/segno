part of 'backing_mix_cubit.dart';

/// The backing mix and the click pan as the surfaces draw them: the live
/// values (a held controller value included) and whether each owner can
/// take an edit.
class BackingMixState extends Equatable {
  /// Creates a [BackingMixState].
  const BackingMixState({
    this.mix = BackingMix.defaults,
    this.mixReady = false,
    this.clickPan = 0,
    this.clickPanReady = false,
  });

  /// The live backing level, pan, outputs and End.
  final BackingMix mix;

  /// Whether the mix owner can take an edit.
  final bool mixReady;

  /// The live click pan.
  final double clickPan;

  /// Whether the click pan owner can take an edit.
  final bool clickPanReady;

  @override
  List<Object?> get props => [mix, mixReady, clickPan, clickPanReady];
}
