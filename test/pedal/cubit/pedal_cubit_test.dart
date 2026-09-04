import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';

/// The pedal LINK tests: the board's status and firmware version, mirrored
/// for the settings UI. The pedal's BEHAVIOR (footswitch decode, LED frames)
/// is `ControlCubit`'s and is covered by test/control/control_cubit_test.dart.
void main() {
  group('PedalCubit', () {
    late FakePedalLink link;
    late PedalRepository pedal;

    setUp(() {
      link = FakePedalLink();
      pedal = PedalRepository(link);
    });

    test('starts disconnected with no firmware version', () async {
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state, const PedalState());
      await cubit.close();
    });

    test('mirrors the board hello as connected + firmware version', () async {
      final cubit = PedalCubit(pedal: pedal);
      link.hello(firmwareMinor: 2);
      await pumpEventQueue();
      expect(cubit.state.status, PedalLinkStatus.connected);
      expect(cubit.state.firmwareVersion, '1.2');
      await cubit.close();
    });

    test('seeds from a repository that is already connected', () async {
      link.hello();
      await pumpEventQueue();
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state.status, PedalLinkStatus.connected);
      expect(cubit.state.firmwareVersion, '1.0');
      await cubit.close();
    });

    test('close sends a goodbye frame and releases the link', () async {
      final cubit = PedalCubit(pedal: pedal);
      await cubit.close();
      expect(link.lastFrame?.isGoodbye, isTrue);
      expect(link.disposed, isTrue);
    });
  });

  group('PedalCubit CTRL calibration', () {
    late FakePedalLink link;
    late PedalRepository pedal;
    late SettingsRepository settings;

    setUp(() {
      link = FakePedalLink();
      pedal = PedalRepository(link);
      settings = SettingsRepository(store: FakeKeyValueStore());
    });

    CtrlMessage raw(int value) => CtrlMessage(
      jack: PedalCtrlJack.ctrl1,
      kind: PedalCtrlKind.expression,
      value: value,
    );

    test('a session collects the ends the pedal reaches, and Done keeps and '
        'persists them', () async {
      final cubit = PedalCubit(pedal: pedal, settings: settings);
      await pumpEventQueue();
      cubit.beginCtrlCalibration(PedalCtrlJack.ctrl1);
      expect(cubit.state.calibrating, PedalCtrlJack.ctrl1);
      expect(cubit.state.calibrationSeen, isNull);

      link
        ..emit(raw(120))
        ..emit(raw(24))
        ..emit(raw(255))
        ..emit(raw(100));
      await pumpEventQueue();
      expect(
        cubit.state.calibrationSeen,
        const PedalCtrlCalibration(min: 24, max: 255),
      );

      await cubit.finishCtrlCalibration();
      expect(cubit.state.calibrating, isNull);
      expect(cubit.state.calibrated, {PedalCtrlJack.ctrl1});
      expect(
        pedal.ctrlCalibration(PedalCtrlJack.ctrl1),
        const PedalCtrlCalibration(min: 24, max: 255),
      );
      expect(await settings.loadCtrlCalibration(0), (24, 255));

      // From here readings arrive calibrated.
      link.emit(raw(24));
      await pumpEventQueue();
      const tip = PedalCtrlInput(
        PedalCtrlJack.ctrl1,
        PedalCtrlContact.tip,
      );
      expect(cubit.state.ctrl[tip]?.value, 0);
      expect(cubit.state.ctrl[tip]?.raw, 24);
      await cubit.close();
    });

    test('Done on a pedal that was not swept changes nothing', () async {
      final cubit = PedalCubit(pedal: pedal, settings: settings)
        ..beginCtrlCalibration(PedalCtrlJack.ctrl1);
      link
        ..emit(raw(100))
        ..emit(raw(105));
      await pumpEventQueue();

      await cubit.finishCtrlCalibration();
      expect(cubit.state.calibrating, isNull);
      expect(cubit.state.calibrated, isEmpty);
      expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
      expect(await settings.loadCtrlCalibration(0), isNull);
      await cubit.close();
    });

    test('Cancel abandons the session', () async {
      final cubit = PedalCubit(pedal: pedal, settings: settings)
        ..beginCtrlCalibration(PedalCtrlJack.ctrl2);
      link.emit(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl2,
          kind: PedalCtrlKind.expression,
          value: 0,
        ),
      );
      await pumpEventQueue();
      cubit.cancelCtrlCalibration();
      expect(cubit.state.calibrating, isNull);
      expect(cubit.state.calibrationSeen, isNull);
      expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl2), isNull);
      await cubit.close();
    });

    test(
      'the other jack, the ring, and a switch do not feed the session',
      () async {
        final cubit = PedalCubit(pedal: pedal, settings: settings)
          ..beginCtrlCalibration(PedalCtrlJack.ctrl1);
        link
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl2,
              kind: PedalCtrlKind.expression,
              value: 0,
            ),
          )
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              contact: PedalCtrlContact.ring,
              kind: PedalCtrlKind.switchPedal,
              value: 255,
            ),
          )
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.switchPedal,
              value: 255,
            ),
          );
        await pumpEventQueue();
        expect(cubit.state.calibrationSeen, isNull);
        expect(cubit.state.ctrl, hasLength(3));
        await cubit.close();
      },
    );

    test(
      'an empty jack drops its row and abandons a calibration on it',
      () async {
        final cubit = PedalCubit(pedal: pedal, settings: settings)
          ..beginCtrlCalibration(PedalCtrlJack.ctrl1);
        link
          ..emit(raw(100))
          ..emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              contact: PedalCtrlContact.ring,
              kind: PedalCtrlKind.switchPedal,
              value: 255,
            ),
          );
        await pumpEventQueue();
        expect(cubit.state.ctrl, hasLength(2));

        link.emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.none,
            value: 0,
          ),
        );
        await pumpEventQueue();
        const tip = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip);
        const ring = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.ring);
        expect(cubit.state.ctrl.containsKey(tip), isFalse);
        expect(cubit.state.ctrl.containsKey(ring), isTrue);
        expect(cubit.state.calibrating, isNull);
        expect(cubit.state.calibrationSeen, isNull);
        await cubit.close();
      },
    );

    test('a stored calibration is applied at start', () async {
      await settings.saveCtrlCalibration(1, min: 30, max: 230);
      final cubit = PedalCubit(pedal: pedal, settings: settings);
      await pumpEventQueue();
      expect(cubit.state.calibrated, {PedalCtrlJack.ctrl2});
      expect(
        pedal.ctrlCalibration(PedalCtrlJack.ctrl2),
        const PedalCtrlCalibration(min: 30, max: 230),
      );
      await cubit.close();
    });

    test('a corrupt stored calibration is ignored', () async {
      await settings.saveCtrlCalibration(0, min: 200, max: 100);
      final cubit = PedalCubit(pedal: pedal, settings: settings);
      await pumpEventQueue();
      expect(cubit.state.calibrated, isEmpty);
      expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
      await cubit.close();
    });

    test('Reset forgets the calibration everywhere', () async {
      await settings.saveCtrlCalibration(0, min: 24, max: 255);
      final cubit = PedalCubit(pedal: pedal, settings: settings);
      await pumpEventQueue();
      await cubit.resetCtrlCalibration(PedalCtrlJack.ctrl1);
      expect(cubit.state.calibrated, isEmpty);
      expect(pedal.ctrlCalibration(PedalCtrlJack.ctrl1), isNull);
      expect(await settings.loadCtrlCalibration(0), isNull);
      await cubit.close();
    });

    test('without settings a calibration lasts the session', () async {
      final cubit = PedalCubit(pedal: pedal)
        ..beginCtrlCalibration(PedalCtrlJack.ctrl1);
      link
        ..emit(raw(0))
        ..emit(raw(255));
      await pumpEventQueue();
      await cubit.finishCtrlCalibration();
      expect(cubit.state.calibrated, {PedalCtrlJack.ctrl1});
      await cubit.close();
    });
  });
}
