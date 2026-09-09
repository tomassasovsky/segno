/// Which tab the Tracks domain is showing.
///
/// Flutter-free, like `LoopTab` and `ControlTab` and for the same reason: the
/// value lives in `SettingsTrayState`, and the tray cubit must not import a
/// widget library to name something it only stores.
enum TracksTab {
  /// What each track is called.
  names,

  /// What each track records, where it is heard, and whether it quantizes.
  routing,
}
