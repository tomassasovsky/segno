import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The learn-hygiene predicate (B8), stated against the real wire tables so it
/// cannot drift from the protocol the firmware speaks.
void main() {
  RawControllerInput note(int id, {int channel = 0}) => RawControllerInput(
    kind: ControllerSourceKind.midiNote,
    id: id,
    value: 127,
    midiChannel: channel,
  );
  RawControllerInput cc(int id, {int channel = 0}) => RawControllerInput(
    kind: ControllerSourceKind.midiCc,
    id: id,
    value: 64,
    midiChannel: channel,
  );

  group('isPedalProtocolInput', () {
    test('claims every footswitch note the pedal transmits', () {
      for (final button in PedalButton.values) {
        expect(
          isPedalProtocolInput(note(button.note)),
          isTrue,
          reason: '${button.name} (note ${button.note}) is pedal traffic',
        );
      }
    });

    test('claims the relative encoder CC', () {
      expect(isPedalProtocolInput(cc(PedalCodec.encoderCc)), isTrue);
    });

    test('claims the external jacks, switches and expression alike', () {
      // The console board reports its CTRL jacks on the same link as the
      // plate. A MIDI binding learned from one would run beside the pedal
      // setup's own assignment — the same stomp, or the same sweep, twice.
      for (final switchId in PedalExternalSwitch.values) {
        expect(
          isPedalProtocolInput(note(switchId.note)),
          isTrue,
          reason: '${switchId.name} (note ${switchId.note}) is pedal traffic',
        );
      }
      for (final jack in PedalExpressionJack.values) {
        expect(
          isPedalProtocolInput(cc(jack.cc)),
          isTrue,
          reason: '${jack.name} (CC ${jack.cc}) is pedal traffic',
        );
      }
    });

    test('leaves a third-party controller alone', () {
      expect(
        isPedalProtocolInput(
          note(
            PedalExternalSwitchNote.firstNote +
                PedalExternalSwitch.values.length,
          ),
        ),
        isFalse,
      );
      expect(isPedalProtocolInput(note(60)), isFalse);
      expect(
        isPedalProtocolInput(
          cc(PedalExpressionJackCc.firstCc + PedalExpressionJack.values.length),
        ),
        isFalse,
      );
      expect(isPedalProtocolInput(cc(11)), isFalse);
      expect(
        isPedalProtocolInput(
          const RawControllerInput(
            kind: ControllerSourceKind.midiProgram,
            id: 3,
            value: 0,
          ),
        ),
        isFalse,
        reason: 'the pedal sends no Program Change',
      );
    });

    test('is channel-agnostic — wrong on one channel is wrong on all', () {
      expect(
        isPedalProtocolInput(cc(PedalCodec.encoderCc, channel: 9)),
        isTrue,
      );
      expect(
        isPedalProtocolInput(note(PedalButton.stop.note, channel: 15)),
        isTrue,
      );
    });
  });
}
