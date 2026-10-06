import 'dart:async';

import 'package:storage_repository/src/models/storage_destination.dart';
import 'package:storage_repository/src/models/storage_failure.dart';

/// A writer's hold on a destination, with the purpose the user can read.
///
/// While any lease on a removable volume is held, eject is refused and
/// shutdown waits (accepted behaviour §7.7, §7.8). When the volume
/// disappears, every lease on it completes [lost] with
/// [StorageFailure.volumeLost], so the holder (recorder, export, backup) can
/// stop at a complete frame and keep what it has. A lease on Internal never
/// completes [lost]. Leases come from `StorageRepository.acquire`.
class WriteLease {
  /// Creates a [WriteLease]; `StorageRepository.acquire` is the only caller.
  WriteLease({
    required this.target,
    required this.purpose,
    required void Function(WriteLease lease) onRelease,
  }) : _onRelease = onRelease;

  /// Where the holder is writing.
  final StorageDestination target;

  /// What for, in words the Storage page shows next to a disabled Eject
  /// (`recording`, `export`, `backup`).
  final String purpose;

  final void Function(WriteLease lease) _onRelease;
  final _lost = Completer<StorageFailure>();
  bool _held = true;

  /// Completes when the destination is lost while this lease is held, with
  /// the failure to report. Never completes for Internal, or for a lease that
  /// was released first.
  Future<StorageFailure> get lost => _lost.future;

  /// Whether the destination was lost while this lease held it.
  bool get isLost => _lost.isCompleted;

  /// Whether this lease still holds its destination.
  bool get isHeld => _held;

  /// Gives the destination back. Idempotent.
  void release() {
    if (!_held) return;
    _held = false;
    _onRelease(this);
  }

  /// The repository's side of a loss: completes [lost] and lets go.
  void markLost(StorageFailure failure) {
    if (!_held) return;
    _lost.complete(failure);
    release();
  }
}
