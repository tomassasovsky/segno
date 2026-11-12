import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/fx_address.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// One switch in the rig that a control can flip (#1711, #1723): a whole
/// chain's effects power, one rack's, or one effect's own.
final class FxSwitchKey extends Equatable {
  /// The effects power of the chain at [address].
  const new chain(this.address) : rackId = null, slotId = null;

  /// The switch of the rack [rackId] ([FxRack.id]) in the chain at
  /// [address].
  const new rack(this.address, String this.rackId) : slotId = null;

  /// The own switch of the effect [slotId] ([TrackEffect.slotId]) in the
  /// chain at [address].
  const new slot(this.address, String this.slotId) : rackId = null;

  /// The chain the switch is in.
  final FxAddress address;

  /// The rack, for a rack's switch.
  final String? rackId;

  /// The effect, for an effect's own switch.
  final String? slotId;

  @override
  List<Object?> get props => [address, rackId, slotId];
}

/// What one control can turn on (#1723): the switches it turns on in one of
/// its two states ([whenOn]) and those it turns on in the other
/// ([whenOff]), turning each side off as it turns the other on.
///
/// A console binding or a MIDI knob has one side. An external switch with
/// Rack A active while On and Rack B active while Off (#1711), or a MIDI
/// button driving two racks with opposite ranges, has two.
final class FxControlReach extends Equatable {
  /// Creates the reach of one control.
  const new({this.whenOn = const {}, this.whenOff = const {}});

  /// The switches on while the control is on.
  final Set<FxSwitchKey> whenOn;

  /// The switches on while it is off.
  final Set<FxSwitchKey> whenOff;

  @override
  List<Object?> get props => [whenOn, whenOff];
}

/// What the rig's controls can turn on, worked out from every control's
/// reach (#1723): what the effects budget reserves room for.
///
/// A switch some control turns on is [free]: charged as on, since a press
/// can turn it on at any time. A switch that one control alternates with
/// others, and no other control reaches, is in one of the [alternations]:
/// only one of its two sides is ever on from the presses, so the rig is
/// charged for the larger side, not for both ([states]).
final class FxReach extends Equatable {
  /// Works out the reach of [controls].
  ///
  /// A switch two controls reach, or one control on both sides, is [free]:
  /// another press can turn it on whatever the first control's state. A
  /// control left with one side after that alternates nothing, so its
  /// switches are free too. Past [maxAlternations], the rest are free: their
  /// sides are charged together, which over-reserves but never refuses a
  /// press.
  factory(Iterable<FxControlReach> controls) {
    final all = controls.toList();
    final seen = <FxSwitchKey, int>{};
    for (final control in all) {
      for (final key in [...control.whenOn, ...control.whenOff]) {
        seen[key] = (seen[key] ?? 0) + 1;
      }
    }
    final free = <FxSwitchKey>{};
    final alternations = <FxControlReach>[];
    for (final control in all) {
      final whenOn = {
        for (final key in control.whenOn)
          if (seen[key] == 1) key,
      };
      final whenOff = {
        for (final key in control.whenOff)
          if (seen[key] == 1) key,
      };
      if (whenOn.isNotEmpty &&
          whenOff.isNotEmpty &&
          alternations.length < maxAlternations) {
        alternations.add(FxControlReach(whenOn: whenOn, whenOff: whenOff));
        free
          ..addAll(control.whenOn.difference(whenOn))
          ..addAll(control.whenOff.difference(whenOff));
      } else {
        free
          ..addAll(control.whenOn)
          ..addAll(control.whenOff);
      }
    }
    return FxReach._(
      Set.unmodifiable(free),
      List.unmodifiable(alternations),
      Set.unmodifiable({
        for (final pair in alternations) ...pair.whenOn,
        for (final pair in alternations) ...pair.whenOff,
      }),
    );
  }

  const new _(this.free, this.alternations, this.alternated);

  /// No control reaches anything: only what is on is charged.
  static const FxReach none = FxReach._({}, [], {});

  /// The most alternations worked out as such: each can triple the states
  /// [states] weighs (its two sides and the state the screen left it in).
  static const int maxAlternations = 6;

  /// The switches some control can turn on whenever it is pressed.
  final Set<FxSwitchKey> free;

  /// The controls that alternate two sides no other control reaches, each
  /// with only those sides.
  final List<FxControlReach> alternations;

  /// Every switch of the [alternations]: the state with each of them on.
  final Set<FxSwitchKey> alternated;

  /// Whether [key] is one of the [alternations]' switches, whose state each
  /// of [states] sets.
  bool alternates(FxSwitchKey key) => alternated.contains(key);

  /// The chains the [alternations] have a switch in.
  Set<FxAddress> get alternatedChains => {
    for (final key in alternated) key.address,
  };

  /// Every state the presses can leave the [alternations] in, each as the
  /// set of their switches that are on: per alternation its On side, its
  /// Off side, and the switches on now ([isOn]) when those are neither (the
  /// screen switched one since the last press, which the next press puts
  /// back). One empty state when nothing alternates.
  List<Set<FxSwitchKey>> states(bool Function(FxSwitchKey key) isOn) {
    var states = [<FxSwitchKey>{}];
    for (final pair in alternations) {
      final now = {
        for (final key in [...pair.whenOn, ...pair.whenOff])
          if (isOn(key)) key,
      };
      final sides = [
        pair.whenOn,
        pair.whenOff,
        // Already one side, or less than one: weighing it changes nothing.
        if (!pair.whenOn.containsAll(now) && !pair.whenOff.containsAll(now))
          now,
      ];
      states = [
        for (final state in states)
          for (final side in sides) {...state, ...side},
      ];
    }
    return states;
  }

  @override
  List<Object?> get props => [free, alternations];
}

/// Whether [after] only takes reach away from [before] (#1723): each of its
/// controls, in order, turns on no more than one of [before]'s on each side,
/// each of [before]'s standing for one of them at most. What deleting a
/// binding, a MIDI mapping or a row, or emptying a store, leaves.
bool fxReachShrinks(List<FxControlReach> before, List<FxControlReach> after) {
  var at = 0;
  for (final control in after) {
    // A control that turns nothing on (a switch with no activations) takes
    // no reach.
    if (control.whenOn.isEmpty && control.whenOff.isEmpty) continue;
    while (at < before.length &&
        !(before[at].whenOn.containsAll(control.whenOn) &&
            before[at].whenOff.containsAll(control.whenOff))) {
      at++;
    }
    if (at == before.length) return false;
    at++;
  }
  return true;
}
