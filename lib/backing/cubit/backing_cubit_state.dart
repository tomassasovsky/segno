part of 'backing_cubit.dart';

/// [BackingCubit]'s state: the player's, plus a `Use as backing` waiting
/// for its confirmation.
class BackingCubitState extends Equatable {
  /// Creates a [BackingCubitState].
  const BackingCubitState({required this.backing, this.confirmUse});

  /// The player.
  final BackingState backing;

  /// The asset `Use as backing` waits to load, or null.
  final BackingAsset? confirmUse;

  /// A copy with the given fields replaced.
  BackingCubitState copyWith({
    BackingState? backing,
    BackingAsset? confirmUse,
    bool clearConfirmUse = false,
  }) => BackingCubitState(
    backing: backing ?? this.backing,
    confirmUse: clearConfirmUse ? null : confirmUse ?? this.confirmUse,
  );

  @override
  List<Object?> get props => [backing, confirmUse];
}
