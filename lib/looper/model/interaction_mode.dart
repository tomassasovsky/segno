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

  /// The FX face (pen 10/03, #1229): every switch but MODE and Bank runs its
  /// FX binding for the current bank, and an unbound track switch toggles
  /// its own track's Track-stage chain; the LEDs carry what each drives.
  ///
  /// Unbound Rec/Play, Stop, Undo and Clear are deliberately INERT — a stray
  /// stomp must never erase the set. MODE is the face's Exit, back to the
  /// mode FX was entered from; Bank pages, and its Hold arms performance
  /// recording.
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
  peel;

  /// The persisted token for this mode. Derived from the member name, so a
  /// member rename changes the current stored identity.
  String get token => name;
}
