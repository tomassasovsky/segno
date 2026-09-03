import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('SimulatorPedalLink', () {
    test('press and turn inject board messages', () async {
      final sim = SimulatorPedalLink();
      final inbound = <PedalLinkMessage>[];
      sim.inbound.listen(inbound.add);
      sim
        ..press(PedalButton.recPlay, down: true)
        ..press(PedalButton.recPlay, down: false)
        ..turn(3)
        ..turn(-200);
      await pumpEventQueue();
      expect(inbound, const [
        ButtonMessage(PedalButton.recPlay, pressed: true),
        ButtonMessage(PedalButton.recPlay, pressed: false),
        EncoderMessage(3),
        EncoderMessage(-128),
      ]);
      await sim.dispose();
    });

    test('releaseAll releases only what is held', () async {
      final sim = SimulatorPedalLink();
      final inbound = <PedalLinkMessage>[];
      sim.inbound.listen(inbound.add);
      sim
        ..press(PedalButton.undo, down: true)
        ..press(PedalButton.mode, down: true)
        ..press(PedalButton.mode, down: false)
        ..releaseAll()
        ..releaseAll();
      await pumpEventQueue();
      expect(inbound.sublist(3), const [
        ButtonMessage(PedalButton.undo, pressed: false),
      ]);
      await sim.dispose();
    });

    test('sent state frames update the plate frame', () async {
      final sim = SimulatorPedalLink();
      expect(sim.frame.value, PedalStateFrame.blank());
      final frame = PedalStateFrame.blank().copyWith(
        globalColor: GlobalColor.green,
      );
      sim
        ..send(StateMessage(frame))
        ..send(const LoopTopMessage());
      expect(sim.frame.value, frame);
      await sim.dispose();
    });

    test('after dispose, presses and sends are dropped', () async {
      final sim = SimulatorPedalLink();
      final frame = sim.frame.value;
      await sim.dispose();
      sim
        ..press(PedalButton.bank, down: true)
        ..turn(1)
        ..releaseAll()
        ..send(StateMessage(frame.copyWith(globalColor: GlobalColor.red)));
      await sim.dispose(); // idempotent
    });
  });
}
