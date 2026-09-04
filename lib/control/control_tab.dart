/// Which tab the Control domain is showing.
///
/// Flutter-free, like `NetworkTab` and for the same reason: the value lives in
/// `SettingsTrayState`, and the tray cubit must not import a widget library to
/// name something it only stores.
enum ControlTab {
  /// The footswitch plate's assignable switches and what they act on.
  pedal,

  /// Everything plugged into the console — a MIDI foot controller, and the
  /// pedals in the CTRL jacks — and every global mapping off them.
  ///
  /// Named for what the tab holds rather than for one of the ways a control
  /// reaches it: bindings are source-agnostic (`ControllerSourceKind` covers
  /// MIDI and the CTRL jacks alike), so calling this "MIDI" hid the jacks.
  controllers,
}
