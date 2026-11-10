import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_assignments.dart';
import 'package:segno/control/control.dart';

const _track = FxAddress(stage: FxStage.track);
const _other = FxAddress(stage: FxStage.track, index: 1);

MidiMapping _knob(String id, int number, ControlValueTarget target) =>
    MidiMapping(
      id: id,
      source: MidiSource(
        device: 'knobs',
        kind: ControllerSourceKind.midiCc,
        number: number,
      ),
      behavior: MidiBehavior.continuous,
      controls: [
        MidiParameterControl(key: target.canonicalString(), low: 0, high: 1),
      ],
    );

/// [state] with each store cleaned by its own removal API, the way
/// `ControlCubit.removeFxAssignments` cleans them.
ControlState _cleaned(ControlState state, FxAddress address, Set<String> ids) {
  bool names(Object? target) => fxTargetNamesEffect(target, address, ids);
  return state.copyWith(
    midiMappings: state.midiMappings.withoutControls(
      (key) => fxMidiKeyNamesEffect(key, address, ids),
    ),
    globalBindings: state.globalBindings.withoutTargets(names),
    sessionBindings: state.sessionBindings.withoutTargets(names),
    pedalSetup: state.pedalSetup.copyWith(
      external: state.pedalSetup.external.withoutTargets(names),
    ),
  );
}

void main() {
  group('fxAssignmentsTo', () {
    test('counts the replaced rack itself with its effects, in one count, '
        'and a cleaning removes both (#1711)', () {
      const rack = FxRackTarget(address: _track, rackId: 'r1');
      const otherRack = FxRackTarget(address: _track, rackId: 'r2');
      final state = ControlState(
        globalBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: rack.canonicalString(),
          ),
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track2, bank: 0),
            target: const FxSlotTarget(
              address: _track,
              slotId: 'a',
            ).canonicalString(),
          ),
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track3, bank: 0),
            target: otherRack.canonicalString(),
          ),
        ]),
        pedalSetup: PedalSetup(
          external: ExternalPedalSetup(
            jacks: {
              PedalCtrlJack.ctrl1: ExternalJackSetup(
                single: ExternalSwitchSetup(
                  controls: ExternalControls(
                    activations: const [ExternalActivation(target: rack)],
                  ),
                ),
              ),
            },
          ),
        ),
      );

      expect(fxAssignmentsTo(state, _track, {'a'}), 1);
      expect(fxAssignmentsTo(state, _track, {'a'}, rackIds: {'r1'}), 3);

      bool names(Object? target) =>
          fxTargetNamesEffect(target, _track, {'a'}, rackIds: {'r1'});
      final cleaned = state.copyWith(
        globalBindings: state.globalBindings.withoutTargets(names),
        pedalSetup: state.pedalSetup.copyWith(
          external: state.pedalSetup.external.withoutTargets(names),
        ),
      );
      expect(fxAssignmentsTo(cleaned, _track, {'a'}, rackIds: {'r1'}), 0);
      // The other rack keeps its binding.
      expect(
        cleaned.globalBindings.bindings.map((b) => b.target),
        [otherRack.canonicalString()],
      );
    });

    test('is zero when nothing points at the effects', () {
      expect(fxAssignmentsTo(const ControlState(), _track, {'a', 'b'}), 0);
    });

    test('counts every MIDI, console pedal and external pedal assignment to '
        'the effects, and nothing else', () {
      const slotA = FxSlotTarget(address: _track, slotId: 'a');
      const paramB = FxParamTarget(address: _track, slotId: 'b', param: 1);
      final state = ControlState(
        midiMappings: MidiMappingSet(
          mappings: [
            _knob('one', 1, paramB),
            // Another chain's effect with the same slot id.
            _knob(
              'two',
              2,
              const FxParamTarget(address: _other, slotId: 'b', param: 1),
            ),
          ],
        ),
        globalBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: slotA.canonicalString(),
          ),
          // A whole-chain binding names the chain, not an effect.
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track2, bank: 0),
            target: const FxChainTarget(_track).canonicalString(),
          ),
        ]),
        sessionBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: slotA.canonicalString(),
          ),
        ]),
        pedalSetup: PedalSetup(
          external: ExternalPedalSetup(
            jacks: {
              PedalCtrlJack.ctrl1: ExternalJackSetup(
                type: ExternalJackType.dualSwitch,
                // Stored on a dual jack but not in use: still an assignment.
                single: ExternalSwitchSetup(
                  controls: ExternalControls(
                    activations: const [ExternalActivation(target: slotA)],
                  ),
                ),
                dualSecond: ExternalSwitchSetup(
                  controls: ExternalControls(
                    activations: const [ExternalActivation(target: slotA)],
                    parameters: [
                      ExternalParameter(
                        target: paramB,
                        active: 1,
                        inactive: 0,
                      ),
                    ],
                  ),
                ),
              ),
              PedalCtrlJack.ctrl2: ExternalJackSetup(
                type: ExternalJackType.expression,
                expression: ExternalExpressionSetup(
                  mappings: [ExpressionMapping(target: paramB)],
                ),
              ),
            },
          ),
        ),
      );

      // MIDI 1, global pedal 1, session pedal 1, external switches 3,
      // expression 1.
      expect(fxAssignmentsTo(state, _track, {'a', 'b'}), 7);
      expect(fxAssignmentsTo(state, _track, {'a'}), 4);
      expect(fxAssignmentsTo(state, _other, {'b'}), 1);

      // Removing them leaves none, and leaves everything else alone.
      final after = _cleaned(state, _track, {'a', 'b'});
      expect(fxAssignmentsTo(after, _track, {'a', 'b'}), 0);
      expect(after.midiMappings.mappings.map((m) => m.id), ['two']);
      expect(fxAssignmentsTo(after, _other, {'b'}), 1);
      expect(after.globalBindings.bindings.map((b) => b.key.button), [
        PedalButton.track2,
      ]);
      expect(after.sessionBindings.isEmpty, isTrue);
    });

    test('a binding whose press names the effects goes whole, and its '
        'unrelated hold is counted', () {
      const slotA = FxSlotTarget(address: _track, slotId: 'a');
      const elsewhere = FxChainTarget(_other);
      final state = ControlState(
        globalBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: slotA.canonicalString(),
            holdTarget: elsewhere.canonicalString(),
          ),
        ]),
      );

      // A binding needs a press, so the hold cannot stay behind: both go,
      // and the dialog's count says two.
      expect(fxAssignmentsTo(state, _track, {'a'}), 2);
      expect(_cleaned(state, _track, {'a'}).globalBindings.isEmpty, isTrue);
    });

    test('a binding whose hold alone names the effects keeps its press', () {
      const slotA = FxSlotTarget(address: _track, slotId: 'a');
      const chain = FxChainTarget(_track);
      final state = ControlState(
        globalBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: chain.canonicalString(),
            holdTarget: slotA.canonicalString(),
          ),
        ]),
      );

      expect(fxAssignmentsTo(state, _track, {'a'}), 1);
      final binding = _cleaned(
        state,
        _track,
        {'a'},
      ).globalBindings.bindings.single;
      expect(binding.decodeTarget(), chain);
      expect(binding.hasHold, isFalse);
    });
  });

  group('fxReachOf (#1723)', () {
    const input = FxAddress(stage: FxStage.input);
    const rackA = FxRackTarget(address: input, rackId: 'a');
    const rackB = FxRackTarget(address: input, rackId: 'b');

    MidiMapping button(
      MidiBehavior behavior,
      List<MidiControl> controls, {
      bool enabled = true,
    }) => MidiMapping(
      id: 'm',
      source: MidiSource(
        device: 'buttons',
        kind: ControllerSourceKind.midiCc,
        number: 20,
      ),
      behavior: behavior,
      controls: controls,
      enabled: enabled,
    );

    MidiParameterControl power(
      FxBindingTarget target,
      double low,
      double high,
    ) => MidiParameterControl(
      key: target.canonicalString(),
      low: low,
      high: high,
    );

    /// The reach of [state] beside the Track-stage chains every state
    /// reaches.
    List<FxControlReach> reach(ControlState state) => [
      for (final control in fxReachOf(state))
        if (!control.whenOn.any((key) => key.address.stage == FxStage.track))
          control,
    ];

    test('every Track-stage chain is reached, whatever is bound', () {
      final keys = fxReachOf(const ControlState()).expand((c) => c.whenOn);
      expect(keys, {
        for (var channel = 0; channel < 8; channel++)
          FxSwitchKey.chain(FxAddress(stage: FxStage.track, index: channel)),
      });
    });

    test('a console binding reaches its press and its hold, a selected one '
        'on every track', () {
      const lane = FxSlotTarget(
        address: FxAddress(stage: FxStage.loop, lane: 0),
        slotId: 's',
      );
      final state = ControlState(
        globalBindings: PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: rackA.canonicalString(),
            holdTarget: rackB.canonicalString(),
          ),
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track2, bank: 0),
            target: lane.canonicalString(),
            scope: BindingScope.selected,
          ),
        ]),
      );
      expect(reach(state), [
        FxControlReach(whenOn: {rackA.switchKey}),
        FxControlReach(whenOn: {rackB.switchKey}),
        FxControlReach(
          whenOn: {
            for (var track = 0; track < 8; track++)
              FxSwitchKey.slot(
                FxAddress(stage: FxStage.loop, index: track, lane: 0),
                's',
              ),
          },
        ),
      ]);
    });

    test('a MIDI button with opposite ranges alternates; a knob, or a '
        'disabled mapping, does not', () {
      ControlState with_(MidiMapping mapping) =>
          ControlState(midiMappings: MidiMappingSet(mappings: [mapping]));
      final controls = [power(rackA, 0, 1), power(rackB, 1, 0)];
      expect(reach(with_(button(MidiBehavior.toggle, controls))), [
        FxControlReach(whenOn: {rackA.switchKey}, whenOff: {rackB.switchKey}),
      ]);
      expect(reach(with_(button(MidiBehavior.continuous, controls))), [
        FxControlReach(whenOn: {rackA.switchKey, rackB.switchKey}),
      ]);
      expect(
        reach(with_(button(MidiBehavior.toggle, controls, enabled: false))),
        isEmpty,
      );
      // A control held off at both ends turns nothing on.
      expect(
        reach(with_(button(MidiBehavior.toggle, [power(rackA, 0, 0)]))),
        [const FxControlReach()],
      );
    });

    test('an external switch alternates On with Off and Held with Released, '
        "under its jack's type only", () {
      final controls = ExternalControls(
        activations: const [
          ExternalActivation(target: rackA),
          ExternalActivation(target: rackB, condition: ExternalCondition.off),
        ],
      );
      ControlState jack(ExternalJackSetup setup) => ControlState(
        pedalSetup: PedalSetup(
          external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: setup}),
        ),
      );
      expect(
        reach(
          jack(
            ExternalJackSetup(single: ExternalSwitchSetup(controls: controls)),
          ),
        ),
        [
          FxControlReach(whenOn: {rackA.switchKey}, whenOff: {rackB.switchKey}),
          const FxControlReach(),
        ],
      );
      // A latching switch reports no contact: its Held rows reach nothing.
      final held = ExternalControls(
        activations: const [
          ExternalActivation(target: rackA, condition: ExternalCondition.held),
        ],
      );
      expect(
        reach(
          jack(
            ExternalJackSetup(
              single: ExternalSwitchSetup(
                hardware: ExternalSwitchHardware.latching,
                controls: held,
              ),
            ),
          ),
        ),
        [const FxControlReach()],
      );
      expect(
        reach(
          jack(ExternalJackSetup(single: ExternalSwitchSetup(controls: held))),
        ),
        [
          const FxControlReach(),
          FxControlReach(whenOn: {rackA.switchKey}),
        ],
      );
      // Kept for the dual type, but a single switch is plugged in.
      expect(
        reach(
          jack(
            ExternalJackSetup(
              dualFirst: ExternalSwitchSetup(controls: controls),
            ),
          ),
        ),
        [const FxControlReach(), const FxControlReach()],
      );
      // The A/B pair it makes charges its larger side.
      final pair = FxReach(
        fxReachOf(
          jack(
            ExternalJackSetup(single: ExternalSwitchSetup(controls: controls)),
          ),
        ),
      );
      expect(pair.alternations, [
        FxControlReach(whenOn: {rackA.switchKey}, whenOff: {rackB.switchKey}),
      ]);
    });
  });
}
