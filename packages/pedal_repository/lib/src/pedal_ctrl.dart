import 'package:equatable/equatable.dart';

/// The console's two CTRL jacks, in wire order.
///
/// One jack takes an expression pedal OR a footswitch, and the board works out
/// which from what the tip does. Each jack has two readable contacts, see
/// [PedalCtrlContact].
enum PedalCtrlJack {
  /// The left jack (J20).
  ctrl1,

  /// The right jack (J21).
  ctrl2,
}

/// The two contacts of a CTRL jack the board can read, in wire order.
enum PedalCtrlContact {
  /// The pot's wiper, or a footswitch. The contact a mono plug carries.
  tip,

  /// The pot's supply on an expression pedal, so never a travel — but on a
  /// two-switch pedal on one TRS plug (a BOSS FS-6's A&B jack) the SECOND
  /// switch, which shorts the ring to sleeve. Always [PedalCtrlKind
  /// .switchPedal]. Console board v2 reads it on a spare GPIO wired to the
  /// jack's ring pin; without that wire it simply never reports.
  ring,
}

/// What the board decided is plugged into a [PedalCtrlJack].
enum PedalCtrlKind {
  /// A footswitch: the value is `0` released or `255` pressed.
  switchPedal,

  /// An expression pedal: the board sends its RAW position `0`..`255`, and
  /// `PedalRepository` maps that onto the pedal's travel (see
  /// [PedalCtrlCalibration]).
  expression,
}

/// One readable contact of one jack: the identity of a CTRL control.
///
/// A footswitch on the tip and the second switch of an FS-6 on the ring are
/// two controls, bound separately.
class PedalCtrlInput extends Equatable {
  /// Creates a [PedalCtrlInput].
  const PedalCtrlInput(this.jack, this.contact);

  /// The jack.
  final PedalCtrlJack jack;

  /// The contact on it.
  final PedalCtrlContact contact;

  /// Every input in panel order: CTRL 1 tip, CTRL 1 ring, CTRL 2 tip, CTRL 2
  /// ring.
  static const values = [
    PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip),
    PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.ring),
    PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.tip),
    PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.ring),
  ];

  @override
  List<Object?> get props => [jack, contact];

  @override
  String toString() => '${jack.name}.${contact.name}';
}

/// Where an expression pedal's ends are, in the board's raw `0`..`255`.
///
/// A pedal never uses the whole scale: the tip's pull-up and the ring's
/// series resistor compress both ends, and every pedal's travel and range
/// knob differ again. Measured on the bench, an M-Audio EX-P covers 24..255.
/// Mapping raw straight to travel would leave a bound level never reaching
/// its bottom.
///
/// So the ends are learned and the travel between them stretched onto
/// `0`..`255`. [margin] trims a little off each end before stretching: the
/// learned end is the noisiest sample ever seen there, and without the
/// margin a pedal held at heel would sit a count or two short of it and
/// never report a hard zero.
class PedalCtrlCalibration extends Equatable {
  /// Creates a [PedalCtrlCalibration] from the lowest and highest raw
  /// readings seen across the pedal's travel.
  const PedalCtrlCalibration({required this.min, required this.max})
    : assert(min >= 0 && min <= 255, 'min must fit a byte'),
      assert(max >= 0 && max <= 255, 'max must fit a byte');

  /// The raw reading at one end of the travel.
  final int min;

  /// The raw reading at the other end.
  final int max;

  /// The smallest `max - min` a calibration is trusted at: about a tenth of
  /// the scale. Below it the pedal has not been swept (or is not a pedal),
  /// and stretching that onto the whole range would turn noise into travel.
  static const minSpan = 25;

  /// How much of each learned end is treated as "the end", in raw counts.
  static const margin = 2;

  /// Whether the ends are far enough apart to trust.
  bool get isUsable => max - min >= minSpan;

  /// The travel `0`..`255` for a raw reading, clamped to the ends.
  int apply(int raw) {
    final lo = min + margin;
    final hi = max - margin;
    if (hi <= lo) return raw;
    return ((raw - lo) * 255 / (hi - lo)).round().clamp(0, 255);
  }

  /// This calibration widened to include [raw], for learning ends from what
  /// a pedal does.
  PedalCtrlCalibration including(int raw) => PedalCtrlCalibration(
    min: raw < min ? raw : min,
    max: raw > max ? raw : max,
  );

  @override
  List<Object?> get props => [min, max];
}
