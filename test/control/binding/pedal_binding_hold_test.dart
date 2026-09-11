import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_binding.dart';

const _track5 = FxAddress(stage: FxStage.track, index: 5);

String get _chain => const FxChainTarget(_track5).canonicalString();
String get _slot =>
    const FxSlotTarget(address: _track5, slotId: 'a').canonicalString();

PedalBindingKey _key(PedalButton button, {int? bank}) =>
    PedalBindingKey(button: button, bank: bank);

void main() {
  group('which switches may carry a hold', () {
    test('the four track footswitches can', () {
      for (final button in PedalBindingKey.trackButtons) {
        expect(
          PedalBinding.canHold(_key(button, bank: 0), BindingBehavior.toggle),
          isTrue,
          reason: button.name,
        );
      }
    });

    test(
      'Record/Play and Stop cannot, because they keep immediate contact',
      () {
        // The accepted rule: delaying a rhythm-sensitive command until the
        // release to learn whether the foot is holding is not approved.
        for (final button in [PedalButton.recPlay, PedalButton.stop]) {
          expect(
            PedalBinding.canHold(_key(button), BindingBehavior.toggle),
            isFalse,
            reason: button.name,
          );
        }
      },
    );

    test('Undo and Clear cannot either', () {
      // Undo already carries the redo hold, and Clear is the one
      // irreversible stomp on the plate.
      for (final button in [PedalButton.undo, PedalButton.clear]) {
        expect(
          PedalBinding.canHold(_key(button), BindingBehavior.toggle),
          isFalse,
          reason: button.name,
        );
      }
    });

    test('a momentary press cannot, because holding IS the gesture', () {
      expect(
        PedalBinding.canHold(
          _key(PedalButton.track1, bank: 0),
          BindingBehavior.momentary,
        ),
        isFalse,
      );
    });
  });

  group('the hold on a binding', () {
    test('round-trips through JSON with its own behavior', () {
      final binding = PedalBinding(
        key: _key(PedalButton.track2, bank: 1),
        target: _chain,
        holdTarget: _slot,
        holdBehavior: BindingBehavior.momentary,
      );

      final back = PedalBinding.fromJson(binding.toJson());

      expect(back, binding);
      expect(back!.hasHold, isTrue);
      expect(back.holdBehavior, BindingBehavior.momentary);
      expect(back.decodeHoldTarget(), isA<FxSlotTarget>());
    });

    test('a binding with no hold writes no hold keys at all', () {
      final json = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
      ).toJson();

      expect(json.containsKey('holdTarget'), isFalse);
      expect(json.containsKey('holdBehavior'), isFalse);
    });

    test('a persisted hold on a switch that cannot carry one is dropped, and '
        'the press survives', () {
      // Losing a working assignment because a file claimed a hold on Stop
      // would punish the performer for the file.
      final back = PedalBinding.fromJson({
        'button': PedalButton.stop.name,
        'target': _chain,
        'behavior': 'toggle',
        'holdTarget': _slot,
      });

      expect(back, isNotNull);
      expect(back!.hasHold, isFalse);
      expect(back.target, _chain);
    });

    test('turning the press momentary drops the hold with it', () {
      final paired = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
        holdTarget: _slot,
      );

      final momentary = paired.copyWith(behavior: BindingBehavior.momentary);

      expect(momentary.hasHold, isFalse);
      expect(momentary.behavior, BindingBehavior.momentary);
    });

    test('clearHold drops it, which a null holdTarget cannot express', () {
      final paired = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
        holdTarget: _slot,
      );

      expect(paired.copyWith().hasHold, isTrue);
      expect(paired.copyWith(clearHold: true).hasHold, isFalse);
    });

    test('the scope round-trips, and a fixed one writes no key at all', () {
      // A binding written before scopes existed and one written now encode
      // identically, so adding the field moved no bytes.
      final fixed = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
      );
      expect(fixed.toJson().containsKey('scope'), isFalse);

      final following = fixed.copyWith(scope: BindingScope.selected);
      expect(following.toJson()['scope'], 'selected');
      expect(PedalBinding.fromJson(following.toJson()), following);
    });

    test("a hold's scope is its own, not the press's", () {
      final split = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
        holdTarget: _slot,
        holdScope: BindingScope.selected,
      );

      final back = PedalBinding.fromJson(split.toJson());

      expect(back!.scope, BindingScope.fixed);
      expect(back.holdScope, BindingScope.selected);
    });

    test('a hold whose target no longer parses decodes to null rather than '
        'falling back to the press', () {
      final binding = PedalBinding(
        key: _key(PedalButton.track1, bank: 0),
        target: _chain,
        holdTarget: 'not a target',
      );

      expect(binding.decodeHoldTarget(), isNull);
      expect(binding.decodeTarget(), isNotNull);
    });
  });
}
