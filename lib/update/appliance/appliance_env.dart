import 'dart:io';

/// Where the appliance image installs its privileged helper. Its presence is
/// how the app knows it is running on the console rather than a desktop.
const kApplianceHelperPath = '/usr/bin/segno-update-ctl';

/// The helper's `install` exit status when the boot partition is mounted
/// read-only (`EXIT_BOOT_READ_ONLY` in `segno-update-ctl`, #1397).
const kBootReadOnlyExitCode = 3;

/// The helper's `install-file` exit status for a package it refused before
/// writing anything; its JSON line on stdout says why. Keep in step with
/// EXIT_REFUSED in segno-update-ctl.
const kInstallFileRefusedExitCode = 4;

/// The helper's `reboot` and `poweroff` exit status when RAUC reports an
/// install in progress (#1498); nothing was reset. Keep in step with
/// EXIT_INSTALLING in segno-update-ctl.
const kUpdateInstallingExitCode = 5;

/// Where a package from a USB drive is copied for `install-file`; the helper
/// refuses any other path.
const kUpdateStagingDirectory = '/data/segno/update-staging';

/// Whether this process runs on the console: Linux, with the appliance
/// image's helper installed. The one predicate every appliance-only source
/// (the pedal link, the power key) is gated on.
bool isAppliance() =>
    Platform.isLinux && File(kApplianceHelperPath).existsSync();

/// The operating-system boundary the appliance update backend depends on,
/// injected so the backend is fully testable without real files, network, or a
/// device. The production implementation is `SystemApplianceEnv`.
abstract interface class ApplianceEnv {
  /// Reads [path] synchronously, or `null` if absent/unreadable. Used for the
  /// tiny local marker files (`build-version`, `update-channel`, the staged
  /// marker) — sync keeps `PlatformUpdateBackend.channel` (a sync getter) and
  /// the support check simple.
  String? readTextSync(String path);

  /// Creates parent directories as needed and writes [contents] to [path].
  /// Used for the user-selected channel override on `/data`.
  void writeTextSync(String path, String contents);

  /// Whether [path] exists.
  bool existsSync(String path);

  /// GETs [url] and returns the response body, or `null` on any failure
  /// (non-200, transport error). Never throws.
  Future<String?> httpGetText(Uri url);

  /// Runs the privileged helper to download + verify + stage semver [version]
  /// (e.g. `"0.2.0"` or `"0.2.0-experimental.7"`) to the inactive slot,
  /// emitting progress in `[0, 1]`. Throws if the helper fails, a
  /// `BootPartitionReadOnlyException` when it found the boot partition
  /// read-only. Cancelling the subscription sends the helper SIGTERM; the
  /// cancel completes once it has exited.
  Stream<double> stage(String version);

  /// Runs the helper's `install-file` on the package at [path], with the same
  /// progress and errors as [stage]; a refusal fails the stream with an
  /// `UpdatePackageRefused`.
  Stream<double> stageFile(String path);

  /// Deletes everything inside [path], which stays; nothing when it is not
  /// there.
  void clearDirectorySync(String path);

  /// The version of an install the helper recorded and never finished (cut
  /// off by a power loss, a stopped service or a cancel), or `null`. Never
  /// throws.
  Future<String?> updateAttempt();

  /// Forgets the install [updateAttempt] reports. Never throws.
  Future<void> clearUpdateAttempt();

  /// Whether RAUC itself reports an install in progress (its D-Bus
  /// `Operation` is `installing`), through the helper's `install-state`.
  /// RAUC keeps writing the slot after the app that started it is gone.
  /// False when the helper cannot tell. Never throws.
  Future<bool> raucInstalling();

  /// Runs the privileged helper to reboot, into the staged slot when one is
  /// staged. Throws on failure, an `UpdateInstallingException` when the
  /// helper refused because RAUC is installing. Only `PowerCubit` calls it,
  /// after the save.
  Future<void> reboot();

  /// Runs the privileged helper to halt the appliance
  /// (`systemctl start poweroff.target`). Throws on failure, an
  /// `UpdateInstallingException` when the helper refused because RAUC is
  /// installing. The caller freezes on the goodbye mark on any other
  /// failure rather than retrying.
  Future<void> powerOff();

  /// Clears a staged-version marker that cannot be applied: a tryboot that
  /// did not take (rolled back, whether boot-bad or simply never committed),
  /// or already running the staged version. Returns the helper's reason for
  /// clearing it (`tryboot-not-taken`, `already-running`, `empty`), or `null`
  /// when it kept the marker or could not run. Never throws.
  Future<String?> reconcileStaged();
}
