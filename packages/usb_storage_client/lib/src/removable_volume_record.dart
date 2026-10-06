import 'package:equatable/equatable.dart';

/// What `segno-usb-ctl` recorded as a volume's state.
enum RemovableVolumeRecordStatus {
  /// Mounted read-write at [RemovableVolumeRecord.mountPoint].
  mounted,

  /// Mounted read-only: the read-write mount failed (a write-protect switch,
  /// a dirty NTFS volume) and the helper fell back once.
  readOnly,

  /// Not mounted: no filesystem, or one the image has no driver for.
  unsupported,

  /// Not mounted: both the read-write and the read-only mount failed;
  /// [RemovableVolumeRecord.failureReason] carries mount's first stderr line.
  mountFailed,

  /// Unmounted on request and safe to remove; the record stays until the
  /// drive is physically unplugged.
  ejected;

  static RemovableVolumeRecordStatus _parse(Object? raw) {
    for (final status in values) {
      if (status.name == raw) return status;
    }
    throw FormatException('unknown volume status: $raw');
  }
}

/// The outcome the helper wrote for an eject request.
class EjectOutcomeRecord extends Equatable {
  /// Creates an [EjectOutcomeRecord].
  const EjectOutcomeRecord({
    required this.request,
    required this.ok,
    this.reason,
  });

  /// Parses the helper's `eject` object.
  factory EjectOutcomeRecord.fromJson(Map<String, Object?> json) {
    return EjectOutcomeRecord(
      request: _string(json, 'request'),
      ok: _bool(json, 'ok'),
      reason: _optionalString(json, 'reason'),
    );
  }

  /// The request id this outcome answers (`UsbStorageClient.requestEject`).
  final String request;

  /// Whether the unmount succeeded.
  final bool ok;

  /// Why it did not: `busy` when the kernel refused, `error` otherwise; null
  /// on success.
  final String? reason;

  @override
  List<Object?> get props => [request, ok, reason];
}

/// One volume as `segno-usb-ctl` describes it: one JSON file under
/// `/run/segno/usb/volumes/<generation>.json`.
///
/// A record is a reading of the helper's file, nothing more: capacity is not
/// here (it changes; the storage repository reads it through the engine), and
/// neither is any policy.
class RemovableVolumeRecord extends Equatable {
  /// Creates a [RemovableVolumeRecord].
  const RemovableVolumeRecord({
    required this.generation,
    required this.kname,
    required this.fingerprint,
    required this.label,
    required this.fsType,
    required this.sizeBytes,
    required this.status,
    required this.readOnly,
    this.mountPoint,
    this.writeBytesPerSecond,
    this.failureReason,
    this.eject,
  });

  /// Parses one volume file. Throws [FormatException] when the shape is not
  /// the helper's; readers skip such a file rather than failing the stream.
  factory RemovableVolumeRecord.fromJson(Map<String, Object?> json) {
    final eject = json['eject'];
    return RemovableVolumeRecord(
      generation: _int(json, 'generation'),
      kname: _string(json, 'kname'),
      fingerprint: _string(json, 'fingerprint'),
      label: _string(json, 'label'),
      fsType: _string(json, 'fsType'),
      mountPoint: _optionalString(json, 'mountPoint'),
      sizeBytes: _int(json, 'sizeBytes'),
      status: RemovableVolumeRecordStatus._parse(json['status']),
      readOnly: _bool(json, 'readOnly'),
      writeBytesPerSecond: _optionalInt(json, 'writeBytesPerSecond'),
      failureReason: _optionalString(json, 'failureReason'),
      eject: switch (eject) {
        null => null,
        final Map<String, Object?> map => EjectOutcomeRecord.fromJson(map),
        _ => throw FormatException('eject is not an object: $eject'),
      },
    );
  }

  /// Per-boot attach counter; a replug is a new generation, so nothing started
  /// against the old drive can complete against the new one.
  final int generation;

  /// The kernel name (`sda1`).
  final String kname;

  /// `ID_SERIAL-ID_FS_UUID`: the stable identity of this filesystem on this
  /// drive, for "same drive" recovery.
  final String fingerprint;

  /// The filesystem label as the user wrote it (decoded, may be empty).
  final String label;

  /// `vfat`, `exfat`, `ext4`, `ntfs`, or whatever udev reported; `none` for a
  /// blank device.
  final String fsType;

  /// Where it is mounted, or null when it is not.
  final String? mountPoint;

  /// The block device's size.
  final int sizeBytes;

  /// The helper's verdict.
  final RemovableVolumeRecordStatus status;

  /// Whether writes are refused at the mount.
  final bool readOnly;

  /// The helper's fsync'd write probe, or null before it ran, when it was
  /// skipped (read-only) or when it failed.
  final int? writeBytesPerSecond;

  /// mount's first stderr line for [RemovableVolumeRecordStatus.mountFailed]
  /// (and the read-write failure behind a read-only fallback).
  final String? failureReason;

  /// The last eject request's outcome, or null.
  final EjectOutcomeRecord? eject;

  @override
  List<Object?> get props => [
    generation,
    kname,
    fingerprint,
    label,
    fsType,
    mountPoint,
    sizeBytes,
    status,
    readOnly,
    writeBytesPerSecond,
    failureReason,
    eject,
  ];
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key is not an integer: $value');
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _int(json, key);
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key is not a string: $value');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _string(json, key);
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key is not a boolean: $value');
}
