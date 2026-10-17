import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/looper/model/interaction_mode.dart';

void main() {
  const mute = ModeAction(InteractionMode.mute);
  const exit = ModeAction(InteractionMode.record);
  const track5 = TrackPedalAction(4);
  const select5 = SelectTrackAction(4);

  test('single/dual switch dispatch follows physical tip/ring identity', () {
    const jack = ExternalJackSetup(
      single: ExternalSwitchSetup(
        gestures: ControlGesturePair(press: track5),
      ),
      dualFirst: ExternalSwitchSetup(
        gestures: ControlGesturePair(press: mute),
      ),
      dualSecond: ExternalSwitchSetup(
        gestures: ControlGesturePair(press: select5),
      ),
    );
    final setup = ExternalPedalSetup().withJack(PedalCtrlJack.ctrl2, jack);
    const tip = PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.tip);
    const ring = PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.ring);
    expect(setup.switchFor(tip)?.closureAction, track5);
    expect(setup.switchFor(ring), isNull);
    final dual = setup.withJack(
      PedalCtrlJack.ctrl2,
      jack.copyWith(type: ExternalJackType.dualSwitch),
    );
    expect(dual.switchFor(tip)?.closureAction, mute);
    expect(dual.switchFor(ring)?.closureAction, select5);
    expect(dual.forJack(PedalCtrlJack.ctrl2).single.gestures.press, track5);
    expect(ExternalPedalSetup.fromJson(dual.toJson()), dual);
  });

  test('expression type hides switches but retains their configurations', () {
    final expression = ExternalExpressionSetup(
      calibration: ExpressionCalibration(heel: 230, toe: 20),
      mappings: [ExpressionMapping(target: const MasterGainTarget())],
    );
    final jack = ExternalJackSetup(
      type: ExternalJackType.expression,
      dualSecond: const ExternalSwitchSetup(change: track5),
      expression: expression,
    );
    final setup = ExternalPedalSetup().withJack(PedalCtrlJack.ctrl1, jack);
    expect(
      setup.switchFor(
        const PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.ring),
      ),
      isNull,
    );
    expect(
      jack.copyWith(type: ExternalJackType.dualSwitch).dualSecond.change,
      track5,
    );
    expect(ExternalPedalSetup.fromJson(setup.toJson()), setup);
  });

  test('latching retains latent Hold, controls and change assignment', () {
    const momentary = ExternalSwitchSetup(
      gestures: ControlGesturePair(press: mute, hold: exit),
      change: track5,
    );
    final latching = momentary.copyWith(
      hardware: ExternalSwitchHardware.latching,
    );
    expect(latching.closureAction, track5);
    expect(latching.gestures.hold, exit);
    expect(ExternalSwitchSetup.fromJson(latching.toJson()), latching);
    expect(
      latching
          .copyWith(hardware: ExternalSwitchHardware.momentary)
          .closureAction,
      mute,
    );
  });

  test('jack map is immutable, detached, ordered, and default elided', () {
    final source = <PedalCtrlJack, ExternalJackSetup>{
      PedalCtrlJack.ctrl2: const ExternalJackSetup(
        type: ExternalJackType.dualSwitch,
      ),
    };
    final setup = ExternalPedalSetup(jacks: source);
    source.clear();
    expect(
      setup.forJack(PedalCtrlJack.ctrl2).type,
      ExternalJackType.dualSwitch,
    );
    expect(setup.jacks.clear, throwsUnsupportedError);
    final other = ExternalPedalSetup()
        .withJack(
          PedalCtrlJack.ctrl1,
          const ExternalJackSetup(type: ExternalJackType.expression),
        )
        .withJack(
          PedalCtrlJack.ctrl2,
          const ExternalJackSetup(type: ExternalJackType.dualSwitch),
        );
    final reverse = ExternalPedalSetup()
        .withJack(
          PedalCtrlJack.ctrl2,
          const ExternalJackSetup(type: ExternalJackType.dualSwitch),
        )
        .withJack(
          PedalCtrlJack.ctrl1,
          const ExternalJackSetup(type: ExternalJackType.expression),
        );
    expect(other, reverse);
    expect(other.toJson().toString(), reverse.toJson().toString());
    expect(
      setup.withJack(PedalCtrlJack.ctrl2, ExternalJackSetup.empty).isEmpty,
      isTrue,
    );
  });

  test('logical intent round-trips separately from jack configuration', () {
    const input = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip);
    final on = ExternalPedalSetup.empty.withLogicalOn(input, on: true);
    expect(on.logicalOn[input], isTrue);
    expect(on.sameConfigurationAs(ExternalPedalSetup.empty), isTrue);
    expect(on, isNot(ExternalPedalSetup.empty));
    expect(ExternalPedalSetup.fromJson(on.toJson()), on);
    final off = on.withLogicalOn(input, on: false);
    expect(ExternalPedalSetup.fromJson(off.toJson()).logicalOn[input], isFalse);
    final draft = ExternalPedalSetup(
      jacks: const {
        PedalCtrlJack.ctrl2: ExternalJackSetup(
          type: ExternalJackType.dualSwitch,
        ),
      },
    );
    final merged = on.withConfigurationFrom(draft);
    expect(merged.logicalOn[input], isTrue);
    expect(merged.sameConfigurationAs(draft), isTrue);
    expect(on.logicalOn.clear, throwsUnsupportedError);
    expect(
      () => ExternalPedalSetup.fromJson(const {
        'on': {'ctrl1.tip': 'true'},
      }),
      throwsFormatException,
    );
    expect(
      () => ExternalPedalSetup.fromJson(const {
        'on': {'ctrl3.tip': true},
      }),
      throwsFormatException,
    );
  });

  test('malformed explicit type/hardware/jack/action rejects whole setup', () {
    for (final external in [
      {
        'ctrl1': {'type': 'quadSwitch'},
      },
      {
        'ctrl1': {
          'single': {'hardware': 'toggle'},
        },
      },
      {
        'ctrl1': {
          'single': {'press': 4},
        },
      },
      {
        'ctrl1': {'single': 'bad'},
      },
      {'ctrl3': <String, dynamic>{}},
    ]) {
      expect(
        () => PedalSetup.decode('{"external":${_json(external)}}'),
        throwsFormatException,
      );
    }
  });

  test('one malformed target rejects the complete configured payload', () {
    final encoded = jsonEncode({
      'external': {
        'ctrl1': {
          'single': {
            'controls': {
              'parameters': [
                {
                  'target': const TrackVolumeTarget(2).canonicalString(),
                  'active': 0.7,
                  'inactive': 0.3,
                },
              ],
            },
          },
        },
        'ctrl2': {
          'expression': {
            'mappings': [
              {
                'target':
                    '{"stage":"allTracks","index":1,"slot":"s","param":0}',
              },
            ],
          },
        },
      },
    });
    expect(() => PedalSetup.decode(encoded), throwsFormatException);
  });

  test(
    'external round-trips with built-in setup and survives Custom clear',
    () {
      final setup = const PedalSetup()
          .withCustom(
            PedalButton.track1,
            bank: 0,
            pair: const ControlGesturePair(press: mute),
          )
          .copyWith(
            external: ExternalPedalSetup().withJack(
              PedalCtrlJack.ctrl1,
              const ExternalJackSetup(
                type: ExternalJackType.dualSwitch,
                dualSecond: ExternalSwitchSetup(change: track5),
              ),
            ),
          );
      expect(PedalSetup.decode(setup.encode()), setup);
      expect(setup.clearedCustom().external, setup.external);
      expect(const PedalSetup().encode().contains('external'), isFalse);
    },
  );
}

String _json(Object value) => const JsonEncoder().convert(value);
