/// Where the appliance image installs its privileged helper. Its presence is
/// how the app knows it is running on the console rather than a desktop.
const kApplianceHelperPath = '/usr/bin/segno-update-ctl';

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
  /// emitting progress in `[0, 1]`. Throws if the helper fails.
  Stream<double> stage(String version);

  /// Runs the privileged helper to reboot into the staged slot. Throws on
  /// failure.
  Future<void> reboot();

  /// Runs the privileged helper to halt the appliance
  /// (`systemctl start poweroff.target`). Throws on failure. The caller
  /// freezes on the goodbye mark rather than retrying.
  Future<void> powerOff();

  /// Clears a staged-version marker that cannot be applied: a tryboot that
  /// did not take (rolled back, whether boot-bad or simply never committed),
  /// or already running the staged version. No-op when the helper is absent.
  /// Never throws.
  Future<void> reconcileStaged();
}
