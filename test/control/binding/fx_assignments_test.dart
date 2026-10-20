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

void main() {
  group('fxAssignmentsTo', () {
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
      final cleaned = fxWithoutAssignmentsTo(state, _track, {'a', 'b'});
      final after = state.copyWith(
        midiMappings: cleaned.midi,
        globalBindings: cleaned.global,
        sessionBindings: cleaned.session,
        pedalSetup: state.pedalSetup.copyWith(external: cleaned.external),
      );
      expect(fxAssignmentsTo(after, _track, {'a', 'b'}), 0);
      expect(cleaned.midi.mappings.map((m) => m.id), ['two']);
      expect(fxAssignmentsTo(after, _other, {'b'}), 1);
      expect(cleaned.global.bindings.map((b) => b.key.button), [
        PedalButton.track2,
      ]);
      expect(cleaned.session.isEmpty, isTrue);
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
      final binding = fxWithoutAssignmentsTo(
        state,
        _track,
        {'a'},
      ).global.bindings.single;
      expect(binding.decodeTarget(), chain);
      expect(binding.hasHold, isFalse);
    });
  });
}
