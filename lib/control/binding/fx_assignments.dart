import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';

/// How many MIDI and pedal assignments in [control] point at one of the
/// effects [slotIds] in the chain at [address].
///
/// Counts every stored assignment that names one of those effects or one of
/// their parameters: each MIDI control, each console pedal binding (its press
/// and its hold, in both the global and the session set) and each external
/// pedal activation, parameter and expression mapping on a jack of the type
/// it is set up as. A whole-chain assignment names the chain, not an effect,
/// so it is not counted.
int fxAssignmentsTo(
  ControlState control,
  FxAddress address,
  Set<String> slotIds,
) {
  bool names(Object? target) => switch (target) {
    FxSlotTarget(address: final a, :final slotId) =>
      a == address && slotIds.contains(slotId),
    FxParamTarget(address: final a, :final slotId) =>
      a == address && slotIds.contains(slotId),
    _ => false,
  };

  var count = 0;
  void add(Object? target) {
    if (names(target)) count++;
  }

  for (final mapping in control.midiMappings.mappings) {
    for (final midi in mapping.controls) {
      add(
        ControlValueTarget.tryParse(midi.key) ??
            FxBindingTarget.tryParse(midi.key),
      );
    }
  }
  for (final set in [control.globalBindings, control.sessionBindings]) {
    for (final binding in set.bindings) {
      add(binding.decodeTarget());
      add(binding.decodeHoldTarget());
    }
  }
  for (final jack in control.pedalSetup.external.jacks.values) {
    final switches = switch (jack.type) {
      ExternalJackType.expression => const <ExternalSwitchSetup>[],
      ExternalJackType.singleSwitch => [jack.single],
      ExternalJackType.dualSwitch => [jack.dualFirst, jack.dualSecond],
    };
    for (final setup in switches) {
      for (final row in setup.controls.activations) {
        add(row.target);
      }
      for (final row in setup.controls.parameters) {
        add(row.target);
      }
    }
    if (jack.type == ExternalJackType.expression) {
      for (final mapping in jack.expression.mappings) {
        add(mapping.target);
      }
    }
  }
  return count;
}
