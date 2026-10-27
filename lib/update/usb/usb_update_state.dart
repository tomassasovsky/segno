part of 'usb_update_cubit.dart';

/// Where Load from USB stands.
enum UsbUpdatePhase {
  /// The list is not open.
  closed,

  /// No drive is plugged in that can be read.
  noDrive,

  /// The drives are being read.
  reading,

  /// The drives hold no update package.
  empty,

  /// The packages are listed, to choose one.
  list,

  /// A package is being copied off its drive.
  copying,

  /// The helper is verifying and staging it.
  installing,

  /// The last choice failed; see [UsbUpdateState.error].
  failed,
}

/// Why a package was not installed. Nothing was changed by any of them.
enum UsbUpdateError {
  /// The signature or the compatible string did not check out.
  unverified,

  /// Not newer than what runs.
  notNewer,

  /// The drive was removed before the copy finished.
  removed,

  /// Internal has no room for it.
  noSpace,

  /// Something that must not overlap a copy is in flight (a take, an
  /// online update).
  busy,

  /// The boot partition is read-only; a restart repairs it.
  bootReadOnly,

  /// Anything else.
  failed,
}

/// State of Load from USB.
class UsbUpdateState extends Equatable {
  /// Creates a [UsbUpdateState].
  const UsbUpdateState({
    this.phase = UsbUpdatePhase.closed,
    this.driveLabel = '',
    this.packages = const [],
    this.progress = 0,
    this.error,
    this.busyKind,
    this.neededBytes,
    this.refusedVersion,
    this.installedVersion,
  });

  /// Where it stands.
  final UsbUpdatePhase phase;

  /// The drive read, for "No update packages on {drive}".
  final String driveLabel;

  /// The packages found.
  final List<UsbUpdatePackage> packages;

  /// The install's progress in `[0, 1]`.
  final double progress;

  /// Why the last choice failed, in [UsbUpdatePhase.failed].
  final UsbUpdateError? error;

  /// The guard table's name of what refused it, for [UsbUpdateError.busy].
  final String? busyKind;

  /// The free space it needs, for [UsbUpdateError.noSpace].
  final int? neededBytes;

  /// The package's version, for [UsbUpdateError.notNewer].
  final Version? refusedVersion;

  /// The running version, for [UsbUpdateError.notNewer].
  final Version? installedVersion;

  /// Returns a copy with the given fields replaced; [clearError] drops the
  /// failure's details.
  UsbUpdateState copyWith({
    UsbUpdatePhase? phase,
    double? progress,
    UsbUpdateError? error,
    String? busyKind,
    int? neededBytes,
    Version? refusedVersion,
    Version? installedVersion,
    bool clearError = false,
  }) => UsbUpdateState(
    phase: phase ?? this.phase,
    driveLabel: driveLabel,
    packages: packages,
    progress: progress ?? this.progress,
    error: clearError ? null : (error ?? this.error),
    busyKind: clearError ? null : (busyKind ?? this.busyKind),
    neededBytes: clearError ? null : (neededBytes ?? this.neededBytes),
    refusedVersion: clearError ? null : (refusedVersion ?? this.refusedVersion),
    installedVersion: clearError
        ? null
        : (installedVersion ?? this.installedVersion),
  );

  @override
  List<Object?> get props => [
    phase,
    driveLabel,
    packages,
    progress,
    error,
    busyKind,
    neededBytes,
    refusedVersion,
    installedVersion,
  ];
}
