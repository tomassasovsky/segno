/// How far a failed pedal firmware flash got, as recorded by the flasher.
///
/// The distinction is what the failed dialog's honesty rides on: "your pedal
/// still works on its previous firmware" is only true when the write never
/// began.
enum PedalFlashFailureClass {
  /// The flash failed before a single byte was written — no manifest, bad
  /// checksum, pedal unplugged, or the bootloader never appeared (Caterina
  /// jumps back to the sketch untouched). The pedal still runs whatever it ran
  /// before, and retrying is always worthwhile.
  notStarted,

  /// avrdude was handed the bootloader port and did not finish — or finished
  /// but the sketch never re-enumerated. The pedal may be parked in its
  /// bootloader with a half-written app section: switches dead, ring dark,
  /// previous firmware gone.
  interrupted;

  /// The more pessimistic of `this` and [other].
  ///
  /// Used when two independent signals classify the same failure and only one
  /// can be trusted to describe it — the on-disk marker (which may be an
  /// earlier attempt's, if this one died before writing) against how far this
  /// attempt actually got. Comfort that cannot be proven must not be offered,
  /// so the worse claim wins.
  PedalFlashFailureClass worseOf(PedalFlashFailureClass other) =>
      this == interrupted || other == interrupted ? interrupted : notStarted;

  /// Parses the class token the flasher writes (`not-started` /
  /// `interrupted`), or `null` for anything else.
  static PedalFlashFailureClass? tryParse(String? token) => switch (token) {
    'not-started' => PedalFlashFailureClass.notStarted,
    'interrupted' => PedalFlashFailureClass.interrupted,
    _ => null,
  };
}
