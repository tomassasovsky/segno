/// The stages of the save before a restart or shutdown, in the order
/// `PowerCubit` runs them. The Saving face lists them and ticks each off as
/// it finishes; the Track display shows the current one.
enum PowerStep {
  /// The transport stops.
  stopPlayback,

  /// The settings flush.
  saveSettings,

  /// The session file is written. Skipped when nothing is saved (an empty
  /// unnamed session).
  writeSession,

  /// Storage writes and ejects settle, and the installer is asked once more.
  finishOnDisk,
}
