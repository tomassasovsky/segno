import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_target.dart';

void main() {
  const chain = FxChainTarget(FxAddress(stage: FxStage.track, index: 2));
  const slot = FxSlotTarget(
    address: FxAddress(stage: FxStage.input),
    slotId: 'slot-1',
  );
  const volume = TrackVolumeTarget(3);

  group('ExternalCondition', () {
    test('Held and Released read the contact; On and Off do not', () {
      expect(ExternalCondition.held.readsContact, isTrue);
      expect(ExternalCondition.released.readsContact, isTrue);
      expect(ExternalCondition.on.readsContact, isFalse);
      expect(ExternalCondition.off.readsContact, isFalse);
    });
  });

  group('ExternalActivation', () {
    test('a new one is active while the button is on', () {
      expect(
        const ExternalActivation(target: chain).condition,
        ExternalCondition.on,
      );
    });

    test('survives a round trip', () {
      const activation = ExternalActivation(
        target: slot,
        condition: ExternalCondition.released,
      );
      expect(ExternalActivation.fromJson(activation.toJson()), activation);
    });

    test('a target that does not decode drops the row', () {
      expect(ExternalActivation.fromJson({'target': 'nope'}), isNull);
      expect(ExternalActivation.fromJson({'condition': 'on'}), isNull);
    });

    test('an unknown condition reads as On', () {
      final activation = ExternalActivation.fromJson({
        'target': chain.canonicalString(),
        'condition': 'sometimes',
      })!;
      expect(activation.condition, ExternalCondition.on);
    });
  });

  group('ExternalParameter', () {
    test('survives a round trip', () {
      const parameter = ExternalParameter(
        target: volume,
        active: 0.65,
        inactive: 0.2,
        condition: ExternalValueCondition.heldReleased,
      );
      expect(ExternalParameter.fromJson(parameter.toJson()), parameter);
    });

    test('a stored value with no number in it drops the row', () {
      // Not a value to guess at: a knob set to something nobody chose.
      expect(
        ExternalParameter.fromJson({
          'target': volume.canonicalString(),
          'active': 0.5,
        }),
        isNull,
      );
    });

    test('values read from outside the range are held inside it', () {
      final parameter = ExternalParameter.fromJson({
        'target': volume.canonicalString(),
        'active': 4.0,
        'inactive': -1.0,
      })!;
      expect(parameter.active, 1);
      expect(parameter.inactive, 0);
    });
  });

  group('ExternalControls', () {
    test('editing a control keeps its row where it was', () {
      const controls = ExternalControls(
        activations: [
          ExternalActivation(target: chain),
          ExternalActivation(target: slot),
        ],
      );
      final edited = controls.withActivation(
        const ExternalActivation(
          target: chain,
          condition: ExternalCondition.held,
        ),
      );
      expect(edited.activations.map((a) => a.target), [chain, slot]);
      expect(edited.activations.first.condition, ExternalCondition.held);
    });

    test('adding and removing leave the other list alone', () {
      final controls = ExternalControls.empty
          .withActivation(const ExternalActivation(target: chain))
          .withParameter(
            const ExternalParameter(target: volume, active: 1, inactive: 0),
          );
      expect(
        controls.withoutActivation(chain).parameters.single.target,
        volume,
      );
      expect(
        controls.withoutParameter(volume).activations.single.target,
        chain,
      );
    });

    test('a stored file holding one target twice loses the repeat', () {
      final controls = ExternalControls.fromJson({
        'activations': [
          const ExternalActivation(target: chain).toJson(),
          const ExternalActivation(
            target: chain,
            condition: ExternalCondition.off,
          ).toJson(),
        ],
        'parameters': [
          const ExternalParameter(
            target: volume,
            active: 1,
            inactive: 0,
          ).toJson(),
          const ExternalParameter(
            target: volume,
            active: 0.5,
            inactive: 0.5,
          ).toJson(),
        ],
      });
      expect(controls.activations.single.condition, ExternalCondition.on);
      expect(controls.parameters.single.active, 1);
    });

    test('knows whether anything needs a momentary switch', () {
      expect(
        const ExternalControls(
          activations: [ExternalActivation(target: chain)],
        ).readsContact,
        isFalse,
      );
      expect(
        const ExternalControls(
          parameters: [
            ExternalParameter(
              target: volume,
              active: 1,
              inactive: 0,
              condition: ExternalValueCondition.heldReleased,
            ),
          ],
        ).readsContact,
        isTrue,
      );
    });

    test('a switch that controls something is not an untouched one', () {
      const setup = ExternalSwitchSetup(
        controls: ExternalControls(
          activations: [ExternalActivation(target: chain)],
        ),
      );
      expect(setup.isEmpty, isFalse);
      expect(ExternalSwitchSetup.fromJson(setup.toJson()), setup);
      expect(ExternalSwitchSetup.empty.toJson().containsKey('controls'), false);
    });
  });
}
