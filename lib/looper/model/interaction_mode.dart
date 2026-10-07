/// The looper's system-wide interaction mode: what a track press does,
/// wherever the press comes from (pedal footswitch, keyboard, or touch).
///
/// One mode for the whole system — the pedal's MODE footswitch, the keyboard's
/// `M`, and the on-screen mode chip all toggle this same state (owned by
/// `ControlCubit`), so a track press can never mean "record" on one surface and
/// "mute" on another. The pedal wire frame carries it as `PedalMode`.
enum InteractionMode {
  /// Track presses select and record/overdub; Stop mutes the selection.
  record,

  /// Track presses arm and mute/unmute; the transport plays the armed set.
  ///
  /// Named after the Sheeran Looper X manual's "Mute Mode" — the track-press
  /// action in this mode is mute toggling.
  mute,

  /// Track presses toggle each track's Track-stage FX chain; the track LEDs
  /// carry chain-enabled state (FX v3 part 5b).
  ///
  /// Every one of the pedal's ten controls is explicitly defined here: the
  /// bank's four track switches stomp Track chains, Stop is FX panic (all
  /// chains off; long-press restores them), Bank / Mode / the encoder keep
  /// their usual jobs, and Rec/Play, Undo and Clear are deliberately INERT —
  /// a stray stomp must never erase the set.
  fx,

  /// Every switch but MODE and BANK runs whatever the Pedals setup assigned
  /// to it; an unassigned one does nothing at all (#763).
  ///
  /// The opposite of [fx] in one respect that matters: FX mode gives every
  /// unbound control a contextual default, so a stray stomp there still
  /// means something. Custom mode has no defaults to fall back to, which is
  /// what "fully user-defined" costs — and is why an unassigned switch is
  /// inert rather than guessing.
  ///
  /// MODE and BANK keep their jobs here as everywhere: MODE is the way out
  /// and BANK is the way to the other four track switches, and the binding
  /// model refuses to hold an assignment on either.
  custom,

  /// Foot-controlled track playback and live-input gain/mute.
  mixer,

  /// Foot-controlled independent track fades and their durations.
  fade,

  /// Foot-controlled per-track playback direction: each track pedal turns
  /// its track around at the current position.
  reverse,

  /// Foot-controlled Peel: each track pedal removes its track's newest
  /// overdub layer, recoverable through Undo.
  peel,

  /// The foot Tuner: the track pedals pick the input to tune, Stop mutes it,
  /// Undo and Clear move the A4 reference (#1229). Never a boot mode.
  tuner,

  /// Foot-controlled Multiply (#1168, pen 16 screens 01-02): the track
  /// pedals select a recorded track, Clear doubles it and Undo stays Undo;
  /// Rec/Play keeps recording.
  multiply,

  /// Foot-controlled Divide (#1168, pen 16 screens 03-08): the track pedals
  /// select a recorded track, Undo keeps its first half (hold for Undo) and
  /// Clear its last half; Rec/Play keeps recording.
  divide;

  /// The persisted token for this mode. Derived from the member name, so a
  /// member rename changes the current stored identity.
  String get token => name;

  /// Whether this is one of the two length surfaces, Multiply or Divide.
  bool get isLength => this == multiply || this == divide;
}
