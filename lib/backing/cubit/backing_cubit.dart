import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/backing/application/backing_player.dart';
import 'package:segno/backing/model/backing_state.dart';

part 'backing_cubit_state.dart';

/// Presents the [BackingPlayer] to the backing surfaces (#1200 Part 5): the
/// prepared list, the selection, the transport and the latest refusal. It
/// holds no state of its own beyond the confirmation `Use as backing` waits
/// for; the player is the one owner.
class BackingCubit extends Cubit<BackingCubitState> {
  /// Follows [player].
  BackingCubit({required BackingPlayer player})
    : _player = player,
      super(BackingCubitState(backing: player.state)) {
    _subscription = player.states.listen(
      (backing) => emit(state.copyWith(backing: backing)),
    );
  }

  final BackingPlayer _player;
  late final StreamSubscription<BackingState> _subscription;

  /// Selects [digest].
  void select(String digest) => _player.select(digest);

  /// Play / Pause on the selection (plan D4).
  void play() => unawaited(_player.play());

  /// Pause.
  void pause() => _player.pause();

  /// Stop and rewind.
  void stop() => _player.stop();

  /// Seek the loaded file.
  void seek(Duration position) => _player.seek(position);

  /// Clear backing (the surface asked first).
  void clear() => _player.clear();

  /// Add to prepared.
  void addToPrepared(BackingAsset asset) =>
      unawaited(_player.addToPrepared(asset));

  /// Remove from prepared.
  void remove(String digest) => unawaited(_player.remove(digest));

  /// Move up.
  void moveUp(String digest) => unawaited(_player.moveUp(digest));

  /// Move down.
  void moveDown(String digest) => unawaited(_player.moveDown(digest));

  /// Use as backing; while another file plays, waits in
  /// [BackingCubitState.confirmUse] for [confirmUse] or [cancelUse].
  void useAsBacking(BackingAsset asset) => unawaited(_use(asset));

  Future<void> _use(BackingAsset asset) async {
    final outcome = await _player.useAsBacking(asset);
    if (isClosed) return;
    if (outcome == UseAsBackingOutcome.needsConfirm) {
      emit(state.copyWith(confirmUse: asset));
    }
  }

  /// Confirms the waiting `Use as backing`.
  void confirmUse() {
    final asset = state.confirmUse;
    if (asset == null) return;
    emit(state.copyWith(clearConfirmUse: true));
    unawaited(_player.useAsBacking(asset, confirmed: true));
  }

  /// Drops the waiting `Use as backing`.
  void cancelUse() => emit(state.copyWith(clearConfirmUse: true));

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
