import 'package:equatable/equatable.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// A removable volume's state as the app sees it.
enum RemovableVolumeStatus {
  /// Mounted read-write; writes may go here.
  mounted,

  /// Mounted read-only: imports work, writes are refused with a reason.
  readOnly,

  /// Not mounted: no filesystem, or one the image cannot drive.
  unsupported,

  /// Not mounted: the mount itself failed.
  mountFailed,

  /// An eject this repository filed is in flight.
  ejecting,

  /// Unmounted on request; safe to remove. Stays listed until the drive is
  /// pulled, so "Safe to remove" can be drawn.
  ejected,
}

/// One removable volume: the helper's record, plus the repository's own
/// [RemovableVolumeStatus.ejecting] while an eject it filed is in flight.
class RemovableVolume extends Equatable {
  /// Creates a [RemovableVolume].
  const RemovableVolume({
    required this.generation,
    required this.fingerprint,
    required this.label,
    required this.fsType,
    required this.sizeBytes,
    required this.status,
    this.mountPoint,
    this.writeBytesPerSecond,
    this.failureReason,
  });

  /// The volume from the helper's [record]; [ejecting] overrides the status
  /// while this repository's eject request is in flight.
  factory RemovableVolume.fromRecord(
    RemovableVolumeRecord record, {
    bool ejecting = false,
  }) {
    return RemovableVolume(
      generation: record.generation,
      fingerprint: record.fingerprint,
      label: record.label,
      fsType: record.fsType,
      mountPoint: record.mountPoint,
      sizeBytes: record.sizeBytes,
      status: ejecting
          ? RemovableVolumeStatus.ejecting
          : switch (record.status) {
              RemovableVolumeRecordStatus.mounted =>
                RemovableVolumeStatus.mounted,
              RemovableVolumeRecordStatus.readOnly =>
                RemovableVolumeStatus.readOnly,
              RemovableVolumeRecordStatus.unsupported =>
                RemovableVolumeStatus.unsupported,
              RemovableVolumeRecordStatus.mountFailed =>
                RemovableVolumeStatus.mountFailed,
              RemovableVolumeRecordStatus.ejected =>
                RemovableVolumeStatus.ejected,
            },
      writeBytesPerSecond: record.writeBytesPerSecond,
      failureReason: record.failureReason,
    );
  }

  /// Per-boot attach counter: the id every operation names. A replug is a new
  /// generation, so nothing started against the old drive can complete
  /// against the new one.
  final int generation;

  /// The stable identity of this filesystem on this drive (serial plus
  /// filesystem UUID), for "same drive" recovery.
  final String fingerprint;

  /// The label the user gave the drive (may be empty).
  final String label;

  /// `vfat`, `exfat`, `ext4`, `ntfs`, or the type of an unsupported
  /// filesystem; `none` for a blank device.
  final String fsType;

  /// Where it is mounted, or null when it is not.
  final String? mountPoint;

  /// The block device's size.
  final int sizeBytes;

  /// What can be done with it.
  final RemovableVolumeStatus status;

  /// The helper's fsync'd write probe, or null before it ran, when it was
  /// skipped (read-only) or when it failed.
  final int? writeBytesPerSecond;

  /// mount's first stderr line for a failed or read-only-fallback mount.
  final String? failureReason;

  /// Whether its files can be read right now: mounted, read-write or
  /// read-only.
  bool get readable =>
      (status == RemovableVolumeStatus.mounted ||
          status == RemovableVolumeStatus.readOnly) &&
      mountPoint != null;

  @override
  List<Object?> get props => [
    generation,
    fingerprint,
    label,
    fsType,
    mountPoint,
    sizeBytes,
    status,
    writeBytesPerSecond,
    failureReason,
  ];
}
