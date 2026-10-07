import 'package:pub_semver/pub_semver.dart';
import 'package:update_repository/src/update_manifest.dart';
import 'package:update_repository/src/update_recovery.dart';

/// The per-platform half of the update system, behind a single interface so the
/// app-facing `UpdateRepository` and `UpdateCubit` stay platform-agnostic.
///
/// Implementations:
///   * appliance (Raspberry Pi) — reads `/etc/segno/build-version`, fetches the
///     channel manifest over HTTPS, stages the signed bundle to the inactive
///     RAUC slot via a privileged helper, and reboots to apply;
///   * desktop (macOS/Windows) — drives Sparkle / WinSparkle;
///   * `UnsupportedPlatformBackend` — the inert fallback where in-app updates
///     are not offered (e.g. a generic dev Linux build).
///
/// The backend deals only in raw data and side effects; the newer-than-current
/// decision lives in `UpdateRepository`.
abstract interface class PlatformUpdateBackend {
  /// Whether this platform offers in-app updates at all. When `false`, the UI
  /// hides the update surfaces and the other members are not exercised.
  bool get isSupported;

  /// The channel this device follows (`experimental` / `production`), for
  /// display. Empty when [isSupported] is `false`.
  String get channel;

  /// Pins the device to [channel] (`experimental` / `production`). On the
  /// appliance this writes a durable override the OTA helper also reads; on
  /// unsupported platforms this is a no-op.
  Future<void> setChannel(String channel);

  /// The running semantic version. [Version.none] (`0.0.0`) when unknown.
  Future<Version> currentVersion();

  /// The semantic version already staged to the inactive slot and awaiting a
  /// restart to apply, or [Version.none] if nothing is staged.
  Future<Version> stagedVersion();

  /// Reads what the previous run left behind: a staged build that did not
  /// start, and an install that was cut off. Called once at startup, before
  /// any check; on the appliance it also clears a staged marker that can no
  /// longer be applied, so the check can offer that build again.
  Future<UpdateRecovery> recover();

  /// Forgets an install that was cut off, once it is retried or dropped.
  Future<void> clearInterrupted();

  /// Fetches and parses the channel manifest. Read-only — no download, no
  /// install — so it is safe to call automatically. Returns `null` when the
  /// server is unreachable or publishes nothing parseable.
  Future<UpdateManifest?> fetchManifest();

  /// Downloads [manifest]'s bundle, verifies it, and stages it to the inactive
  /// slot (appliance) or downloads it in the background (desktop). Emits
  /// progress in `[0, 1]`; completes when the update is fully staged. Throws on
  /// verification or transport failure. Cancelling the subscription stops the
  /// work and stages nothing; the cancel completes once it has stopped.
  Stream<double> downloadAndStage(UpdateManifest manifest);
}
