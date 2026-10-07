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

  test('one button retains independent activation and parameter rows', () {
    final controls = ExternalControls(
      activations: const [
        ExternalActivation(target: chain),
        ExternalActivation(target: slot, condition: ExternalCondition.held),
      ],
      parameters: [
        ExternalParameter(
          target: volume,
          active: 0.8,
          inactive: 0.2,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    );
    expect(controls.readsContact, isTrue);
    expect(ExternalControls.fromJson(controls.toJson()), controls);
    final edited = controls.withActivation(
      const ExternalActivation(target: chain, condition: ExternalCondition.off),
    );
    expect(edited.activations.map((row) => row.target), [chain, slot]);
    expect(edited.parameters.single.target, volume);
    expect(edited.withoutActivation(slot).activations.single.target, chain);
    expect(edited.withoutParameter(volume).parameters, isEmpty);
  });

  test('rows detach caller lists and cannot be mutated after construction', () {
    final rows = <ExternalActivation>[const ExternalActivation(target: chain)];
    final controls = ExternalControls(activations: rows);
    rows.add(const ExternalActivation(target: slot));
    expect(controls.activations.length, 1);
    expect(controls.activations.clear, throwsUnsupportedError);
  });

  test('repair keeps row position, rule, and parameter endpoints', () {
    const replacement = FxChainTarget(
      FxAddress(stage: FxStage.output, index: 1),
    );
    const newVolume = TrackVolumeTarget(4);
    final controls = ExternalControls(
      activations: const [
        ExternalActivation(target: chain, condition: ExternalCondition.off),
        ExternalActivation(target: slot, condition: ExternalCondition.held),
      ],
      parameters: [
        ExternalParameter(
          target: volume,
          active: 0.71,
          inactive: 0.14,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    );
    final repaired = controls
        .repointActivation(chain, replacement)
        .repointParameter(volume, newVolume);
    expect(repaired.activations.map((row) => row.target), [replacement, slot]);
    expect(repaired.activations.first.condition, ExternalCondition.off);
    expect(repaired.parameters.single.target, newVolume);
    expect(repaired.parameters.single.active, 0.71);
    expect(repaired.parameters.single.inactive, 0.14);
    expect(
      repaired.parameters.single.condition,
      ExternalValueCondition.heldReleased,
    );
    expect(controls.activations.first.target, chain);
    expect(controls.parameters.single.target, volume);
  });

  test('duplicate identities reject in constructor and explicit JSON', () {
    expect(
      () => ExternalControls(
        activations: const [
          ExternalActivation(target: chain),
          ExternalActivation(target: chain, condition: ExternalCondition.off),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalControls.fromJson({
        'parameters': [
          ExternalParameter(target: volume, active: 1, inactive: 0).toJson(),
          ExternalParameter(
            target: volume,
            active: 0.5,
            inactive: 0.2,
          ).toJson(),
        ],
      }),
      throwsFormatException,
    );
  });

  test('explicit malformed condition, target, and endpoint reject', () {
    expect(
      () => ExternalActivation.fromJson({
        'target': chain.canonicalString(),
        'condition': 'sometimes',
      }),
      throwsFormatException,
    );
    expect(
      () => ExternalActivation.fromJson(const {'target': 'not a target'}),
      throwsFormatException,
    );
    expect(
      () => ExternalActivation.fromJson(const {
        'target': '{"stage":"track","index":"bad"}',
      }),
      throwsFormatException,
    );
    expect(
      () => ExternalParameter.fromJson(const {
        'target': '{"ctl":"trackVolume","index":0.5}',
        'active': 0.5,
        'inactive': 0.5,
      }),
      throwsFormatException,
    );
    for (final value in [double.nan, double.infinity, -0.01, 1.01]) {
      expect(
        () => ExternalParameter.fromJson({
          'target': volume.canonicalString(),
          'active': value,
          'inactive': 0.4,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => ExternalControls.fromJson(const {
        'activations': [4],
      }),
      throwsFormatException,
    );
  });

  test('retained Held rows are valid while hardware is latching', () {
    final controls = ExternalControls(
      activations: const [
        ExternalActivation(target: chain, condition: ExternalCondition.held),
      ],
    );
    final setup = ExternalSwitchSetup(
      hardware: ExternalSwitchHardware.latching,
      controls: controls,
    );
    expect(setup.controls.readsContact, isTrue);
    expect(ExternalSwitchSetup.fromJson(setup.toJson()), setup);
  });

  test('programmatic invalid targets cannot enter button configuration', () {
    expect(
      () => ExternalParameter(
        target: const TrackVolumeTarget(-1),
        active: 0.8,
        inactive: 0.2,
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalParameter(
        target: const FxParamTarget(
          address: FxAddress(stage: FxStage.loop),
          slotId: 's',
          param: 0,
        ),
        active: 0.8,
        inactive: 0.2,
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalControls(
        activations: const [
          ExternalActivation(
            target: FxChainTarget(
              FxAddress(stage: FxStage.allTracks, index: 1),
            ),
          ),
        ],
      ),
      throwsFormatException,
    );
    expect(
      ExternalControls(
        activations: const [
          ExternalActivation(
            target: FxSlotTarget(
              address: FxAddress(stage: FxStage.track, index: 999),
              slotId: 'gone',
            ),
          ),
        ],
      ).activations.length,
      1,
    );
  });
}
