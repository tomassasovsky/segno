import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/cubit/control_cubit.dart';

/// What one switch does on the Custom face.
enum FootCustomRole {
  /// MODE: back to Tracks. It cannot be assigned.
  exit,

  /// Bank: show the other four tracks' assignments. It cannot be assigned.
  nextBank,

  /// Every other switch runs the actions the performer assigned to it.
  assignment,
}

/// One switch's read of the Custom setup for the bank in view.
class FootCustomPedal extends Equatable {
  /// Creates one switch's read.
  const FootCustomPedal({
    required this.button,
    required this.role,
    this.press,
    this.hold,
    this.lit = false,
  });

  /// The physical switch.
  final PedalButton button;

  /// Whether the switch is MODE, Bank or an assignable switch.
  final FootCustomRole role;

  /// The action a press runs; null when none is assigned.
  final ControlAction? press;

  /// The action a hold runs; null when none is assigned.
  final ControlAction? hold;

  /// Whether the switch LED is lit: the value the plate shows.
  final bool lit;

  /// A switch with an assignment takes contacts even when the action cannot
  /// run, so its refusal can say so. Only an unassigned switch is inert.
  bool get enabled => role != FootCustomRole.assignment || assigned;

  /// Whether the switch carries a Press or a Hold.
  bool get assigned => press != null || hold != null;

  /// Whether the Press is a saved assignment this build cannot run.
  bool get unavailable => press is UnavailableAction;

  @override
  List<Object?> get props => [button, role, press, hold, lit];
}

/// The Custom face for the bank in view.
class FootCustomProjection extends Equatable {
  /// Creates a complete projection.
  const FootCustomProjection({required this.bank, required this.pedals});

  /// Shared rig bank (0 = A, 1 = B).
  final int bank;

  /// All ten switches.
  final Map<PedalButton, FootCustomPedal> pedals;

  /// The read of [button].
  FootCustomPedal operator [](PedalButton button) => pedals[button]!;

  @override
  List<Object?> get props => [bank, pedals];
}

/// Reads the Custom setup for the bank in view. The lit switches come from
/// [ControlState.customLit], the value the cubit sends to the LEDs. A setup
/// that could not be loaded assigns nothing, so every assignable switch reads
/// as unassigned and is inert.
FootCustomProjection projectFootCustom(ControlState control) {
  final bank = control.activeBank.clamp(0, 1);
  FootCustomPedal read(PedalButton button) {
    switch (button) {
      case PedalButton.mode:
        return const FootCustomPedal(
          button: PedalButton.mode,
          role: FootCustomRole.exit,
          lit: true,
        );
      case PedalButton.bank:
        return FootCustomPedal(
          button: PedalButton.bank,
          role: FootCustomRole.nextBank,
          lit: bank == 1,
        );
      case PedalButton.recPlay ||
          PedalButton.stop ||
          PedalButton.undo ||
          PedalButton.clear ||
          PedalButton.track1 ||
          PedalButton.track2 ||
          PedalButton.track3 ||
          PedalButton.track4:
        if (control.pedalSetupUnavailable) {
          return FootCustomPedal(
            button: button,
            role: FootCustomRole.assignment,
          );
        }
        final pair = control.pedalSetup.customFor(button, bank: bank);
        return FootCustomPedal(
          button: button,
          role: FootCustomRole.assignment,
          press: pair.press,
          hold: pair.hold,
          lit: control.customLit[button] ?? false,
        );
    }
  }

  return FootCustomProjection(
    bank: bank,
    pedals: Map.unmodifiable({
      for (final button in PedalButton.values) button: read(button),
    }),
  );
}
