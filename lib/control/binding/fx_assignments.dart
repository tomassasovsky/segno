import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/binding_scope.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/midi_labels.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/l10n/l10n.dart';

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
}) =>
    slotIds.contains(_slotNamed(target, address)) ||
    rackIds.contains(_rackNamed(target, address));

/// The slot id of the effect [target] names in the chain at [address], by
/// itself or by one of its parameters, or `null`.
String? _slotNamed(Object? target, FxAddress address) => switch (target) {
  FxSlotTarget(address: final a, :final slotId) when a == address => slotId,
  FxParamTarget(address: final a, :final slotId) when a == address => slotId,
  _ => null,
};

/// The id of the rack [target] names in the chain at [address], or `null`.
String? _rackNamed(Object? target, FxAddress address) => switch (target) {
  FxRackTarget(address: final a, :final rackId) when a == address => rackId,
  _ => null,
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
}) => fxTargetNamesEffect(_midiTarget(key), address, slotIds, rackIds: rackIds);

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

/// What the controls acting on each card of the chain at [address] are
/// called, by the card's `fxGroupId` (a single effect's slot id, or a rack's
/// id), named as the assignment screens name them (#1757, #1760): the console
/// switches first (`Track 3`, or `Track 3 · Hold` when only its hold acts),
/// then the CTRL jacks (`CTRL 1`, `CTRL 2 · Button 2`), then the MIDI controls
/// (`CC 20 · Ch 1`). Each control once per card, however many of its
/// switches, parameters and gestures act there; a dual pedal's two buttons
/// are two controls. A rack's card gathers what is bound to the rack itself
/// and to the effects in it, which [chain] (the chain's entries) places in
/// their racks; an effect absent from it counts as a card of its own. A card
/// that nothing acts on is absent.
///
/// Only what acts: the console bindings in force (a loaded session's remap
/// replaces the globals), each resolved against the selected track when its
/// scope follows it; each jack's switches or expression under the type
/// plugged in; and the MIDI mappings that are switched on, while MIDI control
/// is. [fxAssignmentsTo] counts more, every stored assignment, because it
/// counts what removing the effects takes away.
Map<String, List<String>> fxAssignmentNames(
  AppLocalizations l10n,
  ControlState control,
  FxAddress address, {
  List<TrackEffect> chain = const [],
}) {
  final rackOf = {
    for (final effect in chain)
      if ((effect.slotId, effect.rack) case (final slot?, final rack?))
        slot: rack.id,
  };
  // Per card, each control by its identity: two MIDI mappings can
  // share a name (one CC on two devices) and are still two controls, and a
  // console switch's press and hold are one.
  final named = <String, Map<Object, String>>{};
  void add(Object? target, Object control, String name) {
    final slot = _slotNamed(target, address);
    final id = _rackNamed(target, address) ?? rackOf[slot] ?? slot;
    if (id != null) {
      (named[id] ??= {}).putIfAbsent(control, () => name);
    }
  }

  for (final binding in control.bindings.bindings) {
    final key = binding.key;
    final name = pedalSwitchLabel(l10n, key.button, key.bank ?? 0);
    if (binding.decodeTarget() case final press?) {
      add(
        resolveBindingTarget(press, binding.scope, control.cursor),
        key,
        name,
      );
    }
    if (binding.decodeHoldTarget() case final hold?) {
      // Named for its hold only when the press does not act on the same
      // card: the press, added first, keeps the switch's plain name.
      add(
        resolveBindingTarget(hold, binding.holdScope, control.cursor),
        key,
        l10n.fxAssignedControlPart(name, l10n.pedalSetupHold),
      );
    }
  }
  for (final jack in PedalCtrlJack.values) {
    final setup = control.pedalSetup.external.forJack(jack);
    final name = externalJackName(l10n, jack);
    if (setup.type == ExternalJackType.expression) {
      for (final mapping in setup.expression.mappings) {
        add(mapping.target, jack, name);
      }
    }
    final switches = setup.type.switchCount;
    for (var index = 0; index < switches; index++) {
      final button = setup.switchAt(index)!;
      final label = switches == 1
          ? name
          : l10n.fxAssignedControlPart(name, l10n.externalButton(index + 1));
      // A latching switch reports no contact, so its Held and Released rows
      // never act (as in [fxReachOf]).
      final latching = button.hardware == ExternalSwitchHardware.latching;
      for (final target in [
        for (final row in button.controls.activations)
          if (!latching ||
              row.condition == ExternalCondition.on ||
              row.condition == ExternalCondition.off)
            row.target,
        for (final row in button.controls.parameters)
          if (!latching || row.condition == ExternalValueCondition.onOff)
            row.target,
      ]) {
        add(target, (jack, index), label);
      }
    }
  }
  if (control.midiControlEnabled) {
    for (final mapping in control.midiMappings.mappings) {
      if (!mapping.enabled) continue;
      final name = midiSourceName(l10n, mapping.source);
      for (final midi in mapping.controls) {
        add(_midiTarget(midi.key), mapping.id, name);
      }
    }
  }
  return {
    for (final MapEntry(:key, :value) in named.entries)
      key: value.values.toList(),
  };
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
///   those active while On alternate with those active while Off, and, on a
///   momentary switch, those active while Held with those active while
///   Released. MIDI mappings count while MIDI control is off, since switching
///   it back on is never weighed.
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
          // A latching switch reports no contact, so its Held and Released
          // rows never switch anything.
          if (setup.hardware == ExternalSwitchHardware.momentary)
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
