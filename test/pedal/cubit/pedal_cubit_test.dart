import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/pedal/pedal.dart';

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
      expect(cubit.state.protocolVersion, PedalLinkCodec.protocolVersion);
      await cubit.close();
    });

    test('seeds from a repository that is already connected', () async {
      link.hello();
      await pumpEventQueue();
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state.status, PedalLinkStatus.connected);
      expect(cubit.state.firmwareVersion, '1.0');
      expect(cubit.state.protocolVersion, PedalLinkCodec.protocolVersion);
      await cubit.close();
    });

    test('mirrors the canonical frame before and after subscription', () async {
      final before = PedalStateFrame.blank().copyWith(activeButtonMask: 1);
      pedal.pushState(before);
      final cubit = PedalCubit(pedal: pedal);
      expect(cubit.state.frame, before);
      final next = before.copyWith(activeButtonMask: 512);
      pedal.pushState(next);
      await pumpEventQueue();
      expect(cubit.state.frame, next);
      expect(cubit.state.status, PedalLinkStatus.disconnected);
      pedal.goodbye();
      await pumpEventQueue();
      expect(cubit.state.frame!.isGoodbye, isTrue);
      expect(cubit.state.frame!.activeButtonMask, 0);
      await cubit.close();
    });

    test('close sends a goodbye frame and releases the link', () async {
      final cubit = PedalCubit(pedal: pedal);
      link.hello();
      await pumpEventQueue();
      await cubit.close();
      expect(link.lastFrame?.isGoodbye, isTrue);
      expect(link.disposed, isTrue);
    });
  });

  test(
    'mirrors full raw precision and clears only disconnected input',
    () async {
      final link = FakePedalLink();
      final pedal = PedalRepository(link);
      final cubit = PedalCubit(pedal: pedal);
      link
        ..hello()
        ..emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.expression,
            value: 201,
          ),
        )
        ..emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl2,
            kind: PedalCtrlKind.switchPedal,
            value: 255,
          ),
        );
      await pumpEventQueue();
      const first = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip);
      const second = PedalCtrlInput(PedalCtrlJack.ctrl2, PedalCtrlContact.tip);
      expect(cubit.state.ctrl[first]!.raw, 201);
      link.emit(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.none,
          value: 0,
        ),
      );
      await pumpEventQueue();
      expect(cubit.state.ctrl.containsKey(first), isFalse);
      expect(cubit.state.ctrl[second]!.raw, 255);
      await cubit.close();
    },
  );
}
