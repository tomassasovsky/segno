import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:storage_repository/src/models/storage_destination.dart';
import 'package:storage_repository/src/models/storage_failure.dart';

/// What a write is for. The Storage page names it, in the user's language,
/// beside a disabled Eject; it is a closed set so every writer's word has a
/// translation and two writers of one kind read as one.
enum WritePurpose {
  /// A take being recorded to the destination.
  recording,

  /// A file copy (`StorageRepository.copyFile`): an import or an export of
  /// files.
  copy,

  /// An export rendered straight to the destination.
  export,

  /// A backup.
  backup,
}

/// A write in progress on a destination: where it goes and what it is for.
///
/// A value, so it can be listed, compared and built `const` (the Library's
/// `RemovableVolumes` port declares it this way). The live side of a lease,
/// its loss and its release, is the [HeldLease] that
/// `StorageRepository.acquire` returns.
class WriteLease extends Equatable {
  /// Creates a [WriteLease].
  const WriteLease({required this.target, required this.purpose});

  /// Where the write goes.
  final StorageDestination target;

  /// What for; the Storage page names it next to a disabled Eject.
  final WritePurpose purpose;

  @override
  List<Object?> get props => [target, purpose];
}

/// A writer's hold on a destination, from `StorageRepository.acquire`.
///
/// While any lease on a removable volume is held, eject is refused and
/// shutdown waits (accepted behaviour §7.7, §7.8). When the volume can no
/// longer take writes (unplugged, or ejected), every lease on it completes
/// [lost] with [StorageFailure.volumeLost], so the holder (recorder, export,
/// backup) can stop at a complete frame and keep what it has. A lease on
/// Internal never completes [lost].
class HeldLease {
  /// Creates a [HeldLease]; `StorageRepository.acquire` is the only caller.
  HeldLease(this.lease, {required void Function(HeldLease held) onRelease})
    : _onRelease = onRelease;

  /// What is held.
  final WriteLease lease;

  /// Where the holder is writing.
  StorageDestination get target => lease.target;

  /// What for.
  WritePurpose get purpose => lease.purpose;

  final void Function(HeldLease held) _onRelease;
  final _lost = Completer<StorageFailure>();
  bool _held = true;

  /// Completes when the destination stops taking writes while this lease is
  /// held, with the failure to report. Never completes for Internal, or for a
  /// lease that was released first.
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
