import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/looper/model/interaction_mode.dart';

const _mute = ModeAction(InteractionMode.mute);
const _exit = ModeAction(InteractionMode.record);
const _track5 = TrackPedalAction(4);

void main() {
  group('a switch', () {
    test("keeps both hardwares' assignments side by side", () {
      // Retyping to latching and back must find the press and hold where they
      // were left: the hardware decides which half DISPATCHES, not which half
      // is remembered.
      const momentary = ExternalSwitchSetup(
        gestures: ControlGesturePair(press: _mute, hold: _exit),
      );
      final latching = momentary.copyWith(
        hardware: ExternalSwitchHardware.latching,
        change: _track5,
      );
      expect(latching.gestures.press, _mute);
      expect(latching.gestures.hold, _exit);
      expect(
        latching.copyWith(hardware: ExternalSwitchHardware.momentary),
        momentary.copyWith(change: _track5),
      );
    });

    test('names the action its ACTIVE hardware runs on a closure', () {
      const setup = ExternalSwitchSetup(
        gestures: ControlGesturePair(press: _mute),
        change: _track5,
      );
      expect(setup.closureAction, _mute);
      expect(
        setup.copyWith(hardware: ExternalSwitchHardware.latching).closureAction,
        _track5,
      );
    });

    test('is empty only when nothing is on either hardware', () {
      expect(ExternalSwitchSetup.empty.isEmpty, isTrue);
      expect(
        const ExternalSwitchSetup(
          gestures: ControlGesturePair(hold: _exit),
        ).isEmpty,
        isFalse,
      );
      expect(const ExternalSwitchSetup(change: _mute).isEmpty, isFalse);
      // The hardware is a setting in its own right: saying a latching switch
      // is plugged in has to survive on its own, before any action is on it.
      expect(
        const ExternalSwitchSetup(
          hardware: ExternalSwitchHardware.latching,
        ).isEmpty,
        isFalse,
      );
    });
  });

  group('a jack', () {
    test('offers the switches its active type has, and no others', () {
      const jack = ExternalJackSetup.empty;
      expect(jack.type, ExternalJackType.singleSwitch);
      expect(jack.switchAt(0), ExternalSwitchSetup.empty);
      expect(jack.switchAt(1), isNull);

      final dual = jack.copyWith(type: ExternalJackType.dualSwitch);
      expect(dual.switchAt(1), ExternalSwitchSetup.empty);
      expect(dual.switchAt(2), isNull);

      final expression = jack.copyWith(type: ExternalJackType.expression);
      expect(expression.switchAt(0), isNull);
    });

    test("keeps every type's assignments when the type changes", () {
      // The accepted design: choosing another type retains the others.
      const single = ExternalSwitchSetup(
        gestures: ControlGesturePair(press: _mute),
      );
      const first = ExternalSwitchSetup(change: _track5);
      final jack = ExternalJackSetup.empty
          .withSwitch(0, single)
          .copyWith(type: ExternalJackType.dualSwitch)
          .withSwitch(0, first);

      expect(jack.switchAt(0), first);
      expect(jack.single, single, reason: 'the single switch is still there');
      expect(
        jack.copyWith(type: ExternalJackType.singleSwitch).switchAt(0),
        single,
      );
    });

    test('refuses a switch the active type does not have', () {
      const jack = ExternalJackSetup.empty;
      const setup = ExternalSwitchSetup(change: _mute);
      expect(jack.withSwitch(1, setup), jack);
      expect(
        jack.copyWith(type: ExternalJackType.expression).withSwitch(0, setup),
        jack.copyWith(type: ExternalJackType.expression),
      );
    });

    test('round-trips through JSON', () {
      final jack = const ExternalJackSetup(type: ExternalJackType.dualSwitch)
          .withSwitch(
            0,
            const ExternalSwitchSetup(
              gestures: ControlGesturePair(press: _mute, hold: _exit),
            ),
          )
          .withSwitch(
            1,
            const ExternalSwitchSetup(
              hardware: ExternalSwitchHardware.latching,
              change: _track5,
            ),
          );
      expect(ExternalJackSetup.fromJson(jack.toJson()), jack);
    });
  });

  group('both jacks', () {
    test('start empty and encode to nothing', () {
      const setup = ExternalPedalSetup();
      expect(setup.isEmpty, isTrue);
      expect(setup.toJson(), isEmpty);
      expect(setup.forJack(ExternalJack.ctrl2), ExternalJackSetup.empty);
    });

    test('a jack set back to how it shipped drops its entry', () {
      final setup = const ExternalPedalSetup().withJack(
        ExternalJack.ctrl1,
        const ExternalJackSetup(type: ExternalJackType.dualSwitch),
      );
      expect(setup.isEmpty, isFalse);
      expect(
        setup.withJack(ExternalJack.ctrl1, ExternalJackSetup.empty),
        const ExternalPedalSetup(),
      );
    });

    test('round-trip and order-independent equality', () {
      const ctrl1 = ExternalJackSetup(
        single: ExternalSwitchSetup(gestures: ControlGesturePair(press: _mute)),
      );
      const ctrl2 = ExternalJackSetup(type: ExternalJackType.expression);
      final one = const ExternalPedalSetup()
          .withJack(ExternalJack.ctrl1, ctrl1)
          .withJack(ExternalJack.ctrl2, ctrl2);
      final other = const ExternalPedalSetup()
          .withJack(ExternalJack.ctrl2, ctrl2)
          .withJack(ExternalJack.ctrl1, ctrl1);
      expect(other, one);
      expect(ExternalPedalSetup.fromJson(one.toJson()), one);
      expect(other.toJson().toString(), one.toJson().toString());
    });

    test('a blob this build cannot read degrades instead of throwing', () {
      expect(ExternalPedalSetup.fromJson(const {}), const ExternalPedalSetup());
      expect(
        ExternalPedalSetup.fromJson(const <String, dynamic>{
          'ctrl1': 'nope',
          'ctrl3': <String, dynamic>{},
        }),
        const ExternalPedalSetup(),
      );
      final salvaged = ExternalPedalSetup.fromJson(const {
        'ctrl2': {
          'type': 'quadSwitch',
          'single': {'hardware': 'toggle', 'press': 'mode:mute'},
        },
      });
      // An unreadable type and hardware fall back rather than dropping the
      // assignment that came with them.
      final jack = salvaged.forJack(ExternalJack.ctrl2);
      expect(jack.type, ExternalJackType.singleSwitch);
      expect(jack.single.hardware, ExternalSwitchHardware.momentary);
      expect(jack.single.gestures.press, _mute);
    });
  });

  group('in the pedal setup', () {
    test('round-trips with the rest and survives a custom clear', () {
      final setup = const PedalSetup()
          .withCustom(
            PedalButton.stop,
            bank: 0,
            pair: const ControlGesturePair(press: _mute),
          )
          .copyWith(
            external: const ExternalPedalSetup().withJack(
              ExternalJack.ctrl1,
              const ExternalJackSetup(
                type: ExternalJackType.dualSwitch,
                dualSecond: ExternalSwitchSetup(change: _track5),
              ),
            ),
          );
      final decoded = PedalSetup.decode(setup.encode());
      expect(decoded, setup);
      expect(
        decoded.external.forJack(ExternalJack.ctrl1).switchAt(1)?.change,
        _track5,
      );
      // Clear custom assignments is about the built-in plate.
      expect(setup.clearedCustom().external, setup.external);
    });

    test('an untouched jack adds nothing to the encoding', () {
      expect(const PedalSetup().encode().contains('external'), isFalse);
    });
  });
}
