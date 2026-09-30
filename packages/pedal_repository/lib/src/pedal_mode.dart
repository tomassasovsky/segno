/// Which behavior set the pedal's footswitches drive.
///
/// This is a different axis from the engine's `LooperMode`
/// (Multi/Sync/Song/Band/Free — what the looper's transport *is*), which the
/// state frame carries separately as `PedalLooperMode`. The two must not be
/// confused with each other; see `PedalLooperMode`'s doc comment (and D10,
/// which performed the equivalent split on the app side: `InteractionMode`
/// vs. `LooperMode`).
///
/// Encoded as the enum [index] in the state frame — **do not reorder**; the
/// declaration order is the wire value and must stay in lockstep with the
/// firmware's `PEDAL_MODE_*` constants (`pedal_link.h`).
enum PedalMode {
  /// Recording / transport control.
  ///
  /// The track buttons select the cursor track; Rec/Play cycles the selected
  /// track through record / overdub / play; Stop mutes it.
  rec,

  /// Mixing / playback control.
  ///
  /// While playing, the track buttons mute/unmute; while stopped (parked) they
  /// arm/disarm the play set. Rec/Play plays the armed set or stops everything.
  play,

  /// Effects control.
  ///
  /// The track buttons toggle each track's FX chain; the LEDs carry
  /// chain-enabled state (`PedalTrackLed.blue`).
  fx,
}
