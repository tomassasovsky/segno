import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The CTRL jacks reach segno the way the footswitches do: as Notes on the
/// link from the console board. These pin the numbers, because they are a wire
/// contract shared with firmware that does not exist yet.
void main() {
  group('PedalExternalSwitch', () {
    test('numbers follow the plate, so the two cannot be confused', () {
      expect(
        PedalExternalSwitchNote.firstNote,
        PedalButton.values.length,
        reason: 'the external notes start where the plate ends',
      );
      for (final switchId in PedalExternalSwitch.values) {
        expect(
          PedalButtonNote.fromNote(switchId.note),
          isNull,
          reason: '${switchId.name} must not decode as a footswitch',
        );
        expect(PedalExternalSwitchNote.fromNote(switchId.note), switchId);
      }
    });

    test("names which of its jack's switches it is", () {
      expect(PedalExternalSwitch.ctrl1First.position, 0);
      expect(PedalExternalSwitch.ctrl1Second.position, 1);
      expect(PedalExternalSwitch.ctrl2First.position, 0);
      expect(PedalExternalSwitch.ctrl2Second.position, 1);
    });

    test('a note past the last switch is not one', () {
      expect(PedalExternalSwitchNote.fromNote(9), isNull);
      expect(
        PedalExternalSwitchNote.fromNote(
          PedalExternalSwitchNote.firstNote + PedalExternalSwitch.values.length,
        ),
        isNull,
      );
    });
  });

  group('decoding a jack', () {
    test('a NoteOn closes the contact and a NoteOff opens it', () {
      expect(
        PedalCodec.decodeMessage(
          0x90,
          PedalExternalSwitch.ctrl2First.note,
          127,
        ),
        const ExternalContactChanged(
          PedalExternalSwitch.ctrl2First,
          closed: true,
        ),
      );
      expect(
        PedalCodec.decodeMessage(0x80, PedalExternalSwitch.ctrl2First.note, 0),
        const ExternalContactChanged(
          PedalExternalSwitch.ctrl2First,
          closed: false,
        ),
      );
    });

    test('a NoteOn at velocity 0 opens it, as it does for a footswitch', () {
      expect(
        PedalCodec.decodeMessage(0x90, PedalExternalSwitch.ctrl1Second.note, 0),
        const ExternalContactChanged(
          PedalExternalSwitch.ctrl1Second,
          closed: false,
        ),
      );
    });

    test('the timestamp comes through for a hold to be timed against', () {
      const when = Duration(milliseconds: 812);
      expect(
        PedalCodec.decodeMessage(
          0x90,
          PedalExternalSwitch.ctrl1First.note,
          64,
          timestamp: when,
        ),
        const ExternalContactChanged(
          PedalExternalSwitch.ctrl1First,
          closed: true,
          timestamp: when,
        ),
      );
    });

    test('the plate still decodes as the plate', () {
      expect(
        PedalCodec.decodeMessage(0x90, PedalButton.mode.note, 127),
        const ButtonPressed(PedalButton.mode),
      );
      expect(
        PedalCodec.decodeMessage(0x90, 99, 127),
        isNull,
        reason: 'a note belonging to neither is not input',
      );
    });
  });
}
