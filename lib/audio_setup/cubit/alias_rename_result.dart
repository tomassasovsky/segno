/// Result of changing a physical port's name.
enum AliasRenameResult {
  /// The name is durable and may be shown.
  applied,

  /// The sheet belongs to an earlier device lifetime or an invalid port.
  refused,

  /// The write failed and the exact prior key was restored.
  storageFailed,

  /// The write and its rollback failed; this key needs a successful reload.
  recoveryRequired,
}
