import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/binding_scope.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';

/// Whether [target] names one of the effects [slotIds] in the chain at
/// [address], one of their parameters, or one of the racks [rackIds] there
/// (#1711).
///
/// A whole-chain target names the chain, not an effect, so it never matches.
bool fxTargetNamesEffect(
  Object? target,
  FxAddress address,
  Set<String> slotIds, {
  Set<String> rackIds = const {},
}) => switch (target) {
  FxSlotTarget(address: final a, :final slotId) =>
    a == address && slotIds.contains(slotId),
  FxParamTarget(address: final a, :final slotId) =>
    a == address && slotIds.contains(slotId),
  FxRackTarget(address: final a, :final rackId) =>
    a == address && rackIds.contains(rackId),
  _ => false,
};

/// The target a MIDI control [key] stands for, or `null`.
Object? _midiTarget(String key) =>
    ControlValueTarget.tryParse(key) ?? FxBindingTarget.tryParse(key);

/// Whether the MIDI control [key] names one of the effects [slotIds] or the
/// racks [rackIds] in the chain at [address] (see [fxTargetNamesEffect]).
bool fxMidiKeyNamesEffect(
  String key,
  FxAddress address,
  Set<String> slotIds, {
  Set<String> rackIds = const {},
}) => fxTargetNamesEffect(
  _midiTarget(key),
  address,
  slotIds,
  rackIds: rackIds,
);

/// How many MIDI and pedal assignments removing the assignments to the
/// effects [slotIds] and the racks [rackIds] in the chain at [address] takes
/// out of [control]: the ones `ControlCubit.removeFxAssignments` removes.
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
  Set<String> slotIds, {
  Set<String> rackIds = const {},
}) {
  bool names(Object? target) =>
      fxTargetNamesEffect(target, address, slotIds, rackIds: rackIds);
  var count = 0;
  void add(Object? target) {
    if (names(target)) count++;
  }

  for (final mapping in control.midiMappings.mappings) {
    for (final midi in mapping.controls) {
      add(_midiTarget(midi.key));
    }
  }
  for (final set in [control.globalBindings, control.sessionBindings]) {
    for (final binding in set.bindings) {
      final pressGoes = names(binding.decodeTarget());
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

/// What every control in [control] can turn on (#1723): the reach the
/// effects budget reserves room for (`LooperRepository.setFxReach`).
///
/// - Each console binding in force, its press and its hold, on every track
///   when it acts on the selected one.
/// - Every Track-stage chain: an unbound track switch in FX mode, the
///   keyboard's digit keys and the Track effects on command all switch one
///   on.
/// - Each enabled MIDI mapping's effect switches. A button (toggle or
///   momentary) alternates the switches it turns on at its top with those it
///   turns on at its bottom; a knob or a Program Change may leave any of
///   them on.
/// - Each external switch's activations under the type its jack is set to:
///   those active while On alternate with those active while Off, and those
///   active while Held with those active while Released.
List<FxControlReach> fxReachOf(ControlState control) {
  const channels = ControlState.tracksPerBank * ControlState.bankCount;
  Set<FxSwitchKey> keys(FxBindingTarget? target, BindingScope scope) => {
    if (target != null)
      for (var cursor = 0; cursor < channels; cursor++)
        resolveBindingTarget(target, scope, cursor).switchKey,
  };

  return [
    for (final binding in control.bindings.bindings) ...[
      FxControlReach(whenOn: keys(binding.decodeTarget(), binding.scope)),
      if (binding.hasHold)
        FxControlReach(
          whenOn: keys(binding.decodeHoldTarget(), binding.holdScope),
        ),
    ],
    FxControlReach(
      whenOn: {
        for (var channel = 0; channel < channels; channel++)
          FxSwitchKey.chain(FxAddress(stage: FxStage.track, index: channel)),
      },
    ),
    for (final mapping in control.midiMappings.mappings)
      if (mapping.enabled) _midiReach(mapping),
    for (final jack in control.pedalSetup.external.jacks.values)
      for (var index = 0; index < 2; index++)
        if (jack.switchAt(index) case final setup?) ...[
          _externalReach(
            setup.controls,
            ExternalCondition.on,
            ExternalCondition.off,
          ),
          _externalReach(
            setup.controls,
            ExternalCondition.held,
            ExternalCondition.released,
          ),
        ],
  ];
}

/// The effect switches a MIDI [mapping] can turn on: an effect switch is on
/// at a value of a half or more.
FxControlReach _midiReach(MidiMapping mapping) {
  final high = <FxSwitchKey>{};
  final low = <FxSwitchKey>{};
  for (final midi in mapping.controls) {
    if (midi is! MidiParameterControl) continue;
    final key = FxBindingTarget.tryParse(midi.key)?.switchKey;
    if (key == null) continue;
    if (midi.high >= 0.5) high.add(key);
    if (midi.low >= 0.5) low.add(key);
  }
  return switch (mapping.behavior) {
    MidiBehavior.toggle ||
    MidiBehavior.momentary => FxControlReach(whenOn: high, whenOff: low),
    MidiBehavior.continuous ||
    MidiBehavior.trigger => FxControlReach(whenOn: {...high, ...low}),
  };
}

/// One of an external switch's two facts ([on] and its opposite [off]):
/// the switches active on each side.
FxControlReach _externalReach(
  ExternalControls controls,
  ExternalCondition on,
  ExternalCondition off,
) => FxControlReach(
  whenOn: {
    for (final row in controls.activations)
      if (row.condition == on) row.target.switchKey,
  },
  whenOff: {
    for (final row in controls.activations)
      if (row.condition == off) row.target.switchKey,
  },
);
