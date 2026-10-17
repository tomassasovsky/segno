/// The console's two panels, by what they show.
///
/// A role, not a connector: which output a role is on is set in the
/// embedder's homescreen.toml, read at run time, so a rewired bench unit keeps
/// each setting with the panel that shows that screen.
enum DisplayRole {
  /// The 7" Track display: the selected-track readout and its waveform.
  track,

  /// The 15.6" Main display: the stage and every page.
  main,
}
