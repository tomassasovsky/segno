import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/binding_scope.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/cubit/control_cubit.dart';

/// What a BOUND switch's target reads in FX mode: lit as its LED is, or
/// stale when the binding no longer resolves (R25).
typedef FxSwitchReading = ({bool lit, bool stale});

/// Why a refused FX-mode stomp changed nothing.
enum FootFxRefusal {
  /// The bound effect or chain is no longer in the rig.
  unavailable,

  /// The rig refused the write.
  failed,
}

/// What one switch does on the FX face (pen 10/03, #1229).
enum FootFxRole {
  /// Runs its FX binding for the current bank.
  binding,

  /// An unbound track switch: toggles its own Track-stage chain.
  trackChain,

  /// Switches bank (its Hold arms performance recording).
  bank,

  /// Back to the mode FX was entered from.
  exit,

  /// Does nothing in FX mode: an unbound Rec/Play, Stop, Undo or Clear.
  inert,
}

/// One switch on the FX face.
class FootFxPedal extends Equatable {
  /// Creates one switch's projection.
  const FootFxPedal({
    required this.button,
    required this.role,
    this.binding,
    this.target,
    this.channel,
    this.effects = const [],
    this.targetEntries,
    this.holdEntries,
    this.lit = false,
    this.stale = false,
    this.available = true,
  });

  /// The physical switch.
  final PedalButton button;

  /// What it does.
  final FootFxRole role;

  /// The binding a [FootFxRole.binding] switch runs.
  final PedalBinding? binding;

  /// The binding's target as it resolves now (the selected track for a
  /// selected-scope binding), or null when it does not decode.
  final FxBindingTarget? target;

  /// The channel an unbound track switch toggles.
  final int? channel;

  /// That channel's Track-stage chain, in signal order; empty otherwise.
  final List<TrackEffect> effects;

  /// The chain the binding's target reaches, in signal order, or null when
  /// that chain does not exist. The face names the pedal from it.
  final List<TrackEffect>? targetEntries;

  /// The chain the binding's Hold target reaches, or null.
  final List<TrackEffect>? holdEntries;

  /// Whether its LED is lit; the face's selection bar mirrors it.
  final bool lit;

  /// A binding that no longer resolves: it stays pressable and is refused
  /// with a notice.
  final bool stale;

  /// Whether the switch can act at all. False only when there is nothing
  /// behind it: an inert switch, or a track the engine does not expose.
  final bool available;

  @override
  List<Object?> get props => [
    button,
    role,
    binding,
    target,
    channel,
    effects,
    targetEntries,
    holdEntries,
    lit,
    stale,
    available,
  ];
}

/// Every switch of the FX face. Equatable, so the face rebuilds only when
/// what it draws changes, not on every meter tick.
class FootFxProjection extends Equatable {
  /// Creates a complete projection.
  const FootFxProjection(this.pedals);

  /// All ten switches.
  final Map<PedalButton, FootFxPedal> pedals;

  /// The read of [button].
  FootFxPedal operator [](PedalButton button) => pedals[button]!;

  @override
  List<Object?> get props => [pedals];
}

/// Reads one FX chain's entries, or null when the chain does not exist.
typedef FxChainLookup = List<TrackEffect>? Function(FxAddress address);

/// Projects every switch of the FX face from Control's state and the rig.
///
/// Bound switches read [ControlState.fxSwitches], the same values the LEDs
/// project, so the face and the plate cannot disagree. Pure.
/// [chainAt] reads the chains a binding reaches (`LooperRepository`'s
/// `chainEntriesAt`), so the face can name them.
FootFxProjection projectFootFx(
  ControlState control,
  LooperState looper, {
  required FxChainLookup chainAt,
}) => FootFxProjection(
  Map.unmodifiable({
    for (final button in PedalButton.values)
      button: _project(control, looper, button, chainAt),
  }),
);

FootFxPedal _project(
  ControlState control,
  LooperState looper,
  PedalButton button,
  FxChainLookup chainAt,
) {
  switch (button) {
    case PedalButton.mode:
      return FootFxPedal(button: button, role: FootFxRole.exit, lit: true);
    case PedalButton.bank:
      return FootFxPedal(
        button: button,
        role: FootFxRole.bank,
        lit: control.activeBank == 1,
      );
    case PedalButton.recPlay ||
        PedalButton.stop ||
        PedalButton.undo ||
        PedalButton.clear ||
        PedalButton.track1 ||
        PedalButton.track2 ||
        PedalButton.track3 ||
        PedalButton.track4:
      break;
  }
  final binding = control.bindings.lookup(button, bank: control.activeBank);
  if (binding != null) {
    final reading = control.fxSwitches[button];
    final decoded = binding.decodeTarget();
    final target = decoded == null
        ? null
        : _scoped(decoded, binding.scope, control.cursor);
    final hold = binding.decodeHoldTarget();
    return FootFxPedal(
      button: button,
      role: FootFxRole.binding,
      binding: binding,
      target: target,
      targetEntries: target == null ? null : chainAt(target.address),
      holdEntries: hold == null ? null : chainAt(hold.address),
      lit: reading?.lit ?? false,
      stale: reading?.stale ?? decoded == null,
    );
  }
  if (!PedalBindingKey.trackButtons.contains(button)) {
    return FootFxPedal(
      button: button,
      role: FootFxRole.inert,
      available: false,
    );
  }
  final channel =
      control.bankBaseChannel + button.index - PedalButton.track1.index;
  final track = channel < looper.tracks.length ? looper.tracks[channel] : null;
  return FootFxPedal(
    button: button,
    role: FootFxRole.trackChain,
    channel: channel,
    effects: track?.effects ?? const [],
    lit: track?.chainEnabled ?? false,
    available: track != null,
  );
}

FxBindingTarget _scoped(
  FxBindingTarget target,
  BindingScope scope,
  int cursor,
) {
  final address = resolveBindingAddress(target.address, scope, cursor);
  if (address == target.address) return target;
  return switch (target) {
    FxChainTarget() => FxChainTarget(address),
    FxSlotTarget(:final slotId) => FxSlotTarget(
      address: address,
      slotId: slotId,
    ),
  };
}
