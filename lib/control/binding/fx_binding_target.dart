import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// What a pedal binding points at: one whole chain, one rack inside a chain
/// (#1711), or one effect inside a chain (A9).
///
/// ## Why this type lives app-side
///
/// The typed target and its resolution sit next to `ControlCubit` rather than
/// in `pedal_repository` / `controller_repository` (VGV-critical): those
/// packages carry bindings as opaque [canonicalString] values and gain NO
/// looper/engine dependency, so no second control-surface interpreter can grow
/// inside a repository package. `ControlCubit` stays the single dispatch point.
///
/// ## Canonical JSON
///
/// The encoding EXTENDS part 3a's [FxAddress] canonical form rather than
/// redeclaring it (R19): the address contributes its own fixed key order
/// (`stage`, `index`, `lane`), an effect-level target appends exactly one
/// key, `slot`, and a rack-level target exactly one key, `rack`. A chain-level
/// target adds nothing, so its string IS [FxAddress.canonicalString].
/// Byte-stable in every case, so plain string equality is target identity.
///
/// This composes safely because [FxAddress.fromJson] ignores keys it does not
/// know (its additive-only contract) — the same map decodes as an address
/// there and as a slot target here.
sealed class FxBindingTarget extends Equatable {
  const new();

  /// Valid target coordinates, independent of current effect availability.
  bool get isStructurallyValid => switch (this) {
    FxChainTarget(:final address) => address.isStructurallyValid,
    FxSlotTarget(:final address, :final slotId) =>
      address.isStructurallyValid && slotId.isNotEmpty,
    FxRackTarget(:final address, :final rackId) =>
      address.isStructurallyValid && rackId.isNotEmpty,
  };

  /// Parses a [canonicalString] back to a target, or `null` when [encoded] is
  /// not a decodable one.
  ///
  /// Never throws: bindings cross package boundaries and app restarts as bare
  /// strings, so a corrupt or hand-edited one must decode to `null` — which
  /// the caller renders as a stale binding — rather than taking down the
  /// control surface.
  static FxBindingTarget? tryParse(String encoded) {
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final address = FxAddress.fromJson(raw);
    if (address == null) return null;
    final hasSlot = raw.containsKey('slot');
    final hasRack = raw.containsKey('rack');
    if (!hasSlot && !hasRack) return FxChainTarget(address);
    // A present-but-unusable `slot` or `rack` is corruption, not a chain
    // target: silently widening an effect or rack binding to its whole chain
    // would bypass far more than the user asked for on the next stomp. Both
    // at once name two different things, which is corruption too.
    if (hasSlot && hasRack) return null;
    final id = raw[hasSlot ? 'slot' : 'rack'];
    if (id is! String || id.isEmpty) return null;
    return hasSlot
        ? FxSlotTarget(address: address, slotId: id)
        : FxRackTarget(address: address, rackId: id);
  }

  /// The chain this target lives on — the whole target for a
  /// [FxChainTarget], the containing chain for a [FxRackTarget] or a
  /// [FxSlotTarget].
  FxAddress get address;

  /// The byte-stable canonical serialization (see the class doc).
  String canonicalString();

  /// The switch in the rig this target flips: what the effects budget
  /// charges a control's reach by (#1723).
  FxSwitchKey get switchKey => switch (this) {
    FxChainTarget(:final address) => FxSwitchKey.chain(address),
    FxRackTarget(:final address, :final rackId) => FxSwitchKey.rack(
      address,
      rackId,
    ),
    FxSlotTarget(:final address, :final slotId) => FxSwitchKey.slot(
      address,
      slotId,
    ),
  };
}

/// A whole-chain target: the stomp flips that chain's `enabled` flag —
/// "disabled == dry through the bus" (R15).
final class FxChainTarget extends FxBindingTarget {
  /// Creates a chain-level target on [address].
  const new(this.address);

  @override
  final FxAddress address;

  @override
  String canonicalString() => address.canonicalString();

  @override
  List<Object?> get props => [address];
}

/// A single-effect target: the stomp flips one slot's `enabled` flag inside
/// the chain at [address].
///
/// Keyed by the stable [slotId] part 3a stamps on every entry, never by
/// position (A9) — inserting or reordering effects around a bound one must
/// leave the binding pointing at the SAME effect. When the slot is gone the
/// target goes inert; it never falls back to the chain or to a neighbouring
/// slot.
final class FxSlotTarget extends FxBindingTarget {
  /// Creates an effect-level target on [slotId] within [address]'s chain.
  const new({required this.address, required this.slotId});

  @override
  final FxAddress address;

  /// The stable per-slot id (part 3a) of the bound effect.
  final String slotId;

  @override
  String canonicalString() => jsonEncode({...address.toJson(), 'slot': slotId});

  @override
  List<Object?> get props => [address, slotId];
}

/// A rack-level target: the stomp switches one rack inside the chain at
/// [address] on or off as a whole (#1711), leaving each of its effects' own
/// switches as they were — so a rack switched back on sounds as it did.
///
/// Keyed by the rack's INSTANCE id ([FxRack.id]), minted when the rack is
/// added and saved with the chain, never by position or by the catalogue
/// preset it came from: a reorder, a rename or a reload leaves the binding on
/// the same rack, and a second copy of the same sound in one chain is a
/// different rack. When the rack is removed or replaced the target goes
/// inert, as a stale slot does (R25); it never falls back to the chain or to
/// another rack.
final class FxRackTarget extends FxBindingTarget {
  /// Creates a rack-level target on [rackId] within [address]'s chain.
  const new({required this.address, required this.rackId});

  @override
  final FxAddress address;

  /// The bound rack's instance id ([FxRack.id]).
  final String rackId;

  @override
  String canonicalString() => jsonEncode({...address.toJson(), 'rack': rackId});

  @override
  List<Object?> get props => [address, rackId];
}
