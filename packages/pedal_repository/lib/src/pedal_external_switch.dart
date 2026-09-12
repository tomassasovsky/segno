/// A switch on one of the console's two external control jacks.
///
/// The CTRL jacks are read by the console board alongside the ten footswitches
/// and the encoder, so an external switch reaches segno the way a footswitch
/// does: as a Note on the same link, at the numbers below.
///
/// A dual pedal puts two switches on one jack; a single pedal uses only the
/// first of its jack's pair. The numbering is part of the wire contract —
/// append, never renumber.
enum PedalExternalSwitch {
  /// The first switch on CTRL 1, and the only one a single pedal has.
  ctrl1First,

  /// The second switch on CTRL 1, present on a dual pedal.
  ctrl1Second,

  /// The first switch on CTRL 2.
  ctrl2First,

  /// The second switch on CTRL 2.
  ctrl2Second;

  /// Which of its jack's switches this is: `0` or `1`.
  ///
  /// Which JACK is deliberately not offered here: the app names its own jacks
  /// and maps them by name, so a switch appended to this enum has to be given
  /// one rather than falling into whichever the arithmetic reached.
  int get position => index % 2;
}

/// The Note number each external switch transmits.
///
/// They follow the ten footswitches, so a build that predates them decodes
/// nothing rather than mistaking one for a plate switch: `PedalButtonNote`
/// rejects any note at or above the plate's count, which is where these start.
extension PedalExternalSwitchNote on PedalExternalSwitch {
  /// The first external Note number, immediately after the plate's ten.
  static const int firstNote = 10;

  /// The Note number this switch transmits.
  int get note => firstNote + index;

  /// The [PedalExternalSwitch] for a MIDI [note], or `null` if it is not one.
  static PedalExternalSwitch? fromNote(int note) {
    final index = note - firstNote;
    if (index < 0 || index >= PedalExternalSwitch.values.length) return null;
    return PedalExternalSwitch.values[index];
  }
}
