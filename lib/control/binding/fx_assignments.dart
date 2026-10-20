import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_binding_set.dart';
import 'package:segno/control/cubit/control_cubit.dart';

/// Whether [target] names one of the effects [slotIds] in the chain at
/// [address], or one of their parameters.
///
/// A whole-chain target names the chain, not an effect, so it never matches.
bool fxTargetNamesEffect(
  Object? target,
  FxAddress address,
  Set<String> slotIds,
) => switch (target) {
  FxSlotTarget(address: final a, :final slotId) =>
    a == address && slotIds.contains(slotId),
  FxParamTarget(address: final a, :final slotId) =>
    a == address && slotIds.contains(slotId),
  _ => false,
};

/// The target a MIDI control [key] stands for, or `null`.
Object? _midiTarget(String key) =>
    ControlValueTarget.tryParse(key) ?? FxBindingTarget.tryParse(key);

/// Whether the MIDI control [key] names one of the effects [slotIds] in the
/// chain at [address] (see [fxTargetNamesEffect]).
bool fxMidiKeyNamesEffect(String key, FxAddress address, Set<String> slotIds) =>
    fxTargetNamesEffect(_midiTarget(key), address, slotIds);

/// How many MIDI and pedal assignments removing the assignments to the
/// effects [slotIds] in the chain at [address] takes out of [control]: the
/// ones [fxWithoutAssignmentsTo] removes.
///
/// Counts every stored assignment that names one of those effects or one of
/// their parameters: each MIDI control, each console pedal binding's press
/// and hold in both the global and the session set, and each external pedal
/// activation, parameter and expression mapping, under every type a jack
/// stores. A console binding cannot keep a hold without a press, so when its
/// press goes, its hold goes too and is counted whatever it targets.
int fxAssignmentsTo(
  ControlState control,
  FxAddress address,
  Set<String> slotIds,
) {
  var count = 0;
  void add(Object? target) {
    if (fxTargetNamesEffect(target, address, slotIds)) count++;
  }

  for (final mapping in control.midiMappings.mappings) {
    for (final midi in mapping.controls) {
      add(_midiTarget(midi.key));
    }
  }
  for (final set in [control.globalBindings, control.sessionBindings]) {
    for (final binding in set.bindings) {
      final pressGoes = fxTargetNamesEffect(
        binding.decodeTarget(),
        address,
        slotIds,
      );
      if (pressGoes) {
        count += binding.hasHold ? 2 : 1;
      } else {
        add(binding.decodeHoldTarget());
      }
    }
  }
  for (final jack in control.pedalSetup.external.jacks.values) {
    for (final setup in [jack.single, jack.dualFirst, jack.dualSecond]) {
      for (final row in setup.controls.activations) {
        add(row.target);
      }
      for (final row in setup.controls.parameters) {
        add(row.target);
      }
    }
    for (final mapping in jack.expression.mappings) {
      add(mapping.target);
    }
  }
  return count;
}

/// The MIDI mappings, console pedal bindings and external pedal setup of
/// [control] with every assignment [fxAssignmentsTo] counts removed.
///
/// A console pedal binding whose press is removed goes whole, hold included,
/// since a binding cannot keep a hold without a press (its press target is
/// required); [fxAssignmentsTo] counts that hold.
({
  MidiMappingSet midi,
  PedalBindingSet global,
  PedalBindingSet session,
  ExternalPedalSetup external,
})
fxWithoutAssignmentsTo(
  ControlState control,
  FxAddress address,
  Set<String> slotIds,
) {
  bool names(Object? target) => fxTargetNamesEffect(target, address, slotIds);
  return (
    midi: control.midiMappings.withoutControls(
      (key) => fxMidiKeyNamesEffect(key, address, slotIds),
    ),
    global: control.globalBindings.withoutTargets(names),
    session: control.sessionBindings.withoutTargets(names),
    external: control.pedalSetup.external.withoutTargets(names),
  );
}
