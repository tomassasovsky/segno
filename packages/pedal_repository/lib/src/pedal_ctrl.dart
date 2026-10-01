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
  /// ControlCubit maps that onto the confirmed pedal travel.
  expression,

  /// Nothing on the jack: a plug came out (or, on a switched jack, was never
  /// in). Sent once, on the tip, with value `0`, and it covers the whole
  /// jack: both contacts retire without synthetic switch-release gestures.
  /// Expression values hold; the application retires configured button holds.
  /// The jack is classified afresh on the next plug. An [expression] tip also
  /// rules out a ring switch: a pot's ring is its supply.
  none,
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
