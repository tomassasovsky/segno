import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/pedal/console_ctrl_source.dart';

void main() {
  group('ConsoleCtrlSource', () {
    late FakePedalLink link;
    late PedalRepository pedal;
    late ConsoleCtrlSource source;

    setUp(() {
      link = FakePedalLink();
      pedal = PedalRepository(link);
      source = ConsoleCtrlSource(pedal);
    });

    tearDown(() async {
      await source.dispose();
      await pedal.dispose();
    });

    Future<List<RawControllerInput>> collect(
      List<PedalLinkMessage> messages,
    ) async {
      final seen = <RawControllerInput>[];
      final sub = source.inputs.listen(seen.add);
      for (final message in messages) {
        link.emit(message);
      }
      await pumpEventQueue();
      await sub.cancel();
      return seen;
    }

    test(
      'a footswitch and an expression pedal are different controls',
      () async {
        final seen = await collect(const [
          CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.switchPedal,
            value: 255,
          ),
          CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.expression,
            value: 255,
          ),
        ]);

        // Same jack, same value: swapping pedals must not drive whatever the
        // other one was bound to.
        expect(seen.map((i) => i.kind), [
          ControllerSourceKind.consoleSwitch,
          ControllerSourceKind.consoleExpression,
        ]);
        expect(seen.map((i) => i.trigger).toSet(), hasLength(2));
      },
    );

    test('the jack is the control number, and values land in 0..127', () async {
      final seen = await collect(const [
        CtrlMessage(
          jack: PedalCtrlJack.ctrl2,
          kind: PedalCtrlKind.expression,
          value: 0,
        ),
        CtrlMessage(
          jack: PedalCtrlJack.ctrl2,
          kind: PedalCtrlKind.expression,
          value: 255,
        ),
      ]);

      expect(seen.map((i) => i.id), everyElement(1));
      expect(seen.map((i) => i.value), [0, 127]);
    });

    test('a press reads as a press and a release does not', () async {
      final seen = await collect(const [
        CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 255,
        ),
        CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 0,
        ),
      ]);

      expect(seen.map((i) => i.isPress), [true, false]);
    });

    test('other pedal events are not controls', () async {
      final seen = await collect(const [
        ButtonMessage(PedalButton.recPlay, pressed: true),
        EncoderMessage(1),
      ]);

      expect(seen, isEmpty);
    });

    test('an expression pedal is learnable at any value, a switch is not', () {
      // A pedal resting heel-down reports 0 forever; refusing that value would
      // make it uncapturable.
      expect(ControllerSourceKind.consoleExpression.isContinuous, isTrue);
      expect(ControllerSourceKind.consoleSwitch.isContinuous, isFalse);
    });
  });
}
