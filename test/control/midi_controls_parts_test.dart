import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/control/view/midi_controls/midi_control_cards.dart';
import 'package:segno/control/view/midi_controls/midi_device_cards.dart';
import 'package:segno/l10n/l10n.dart';

/// The pieces of the MIDI controls page that decide what it says.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('a parameter range is named by the behavior', () {
    test('a knob runs From / To', () {
      final captions = midiRangeCaptions(
        l10n,
        MidiBehavior.continuous,
        program: false,
      );
      expect((captions.low, captions.high), ('From', 'To'));
    });

    test('a toggle is Off / On, a momentary Released / Held', () {
      final toggle = midiRangeCaptions(
        l10n,
        MidiBehavior.toggle,
        program: false,
      );
      final momentary = midiRangeCaptions(
        l10n,
        MidiBehavior.momentary,
        program: false,
      );
      expect((toggle.low, toggle.high), ('Off', 'On'));
      expect((momentary.low, momentary.high), ('Released', 'Held'));
    });

    test('a Program writes one Value', () {
      final captions = midiRangeCaptions(
        l10n,
        MidiBehavior.trigger,
        program: true,
      );
      expect((captions.low, captions.high), (null, 'Value'));
    });
  });

  group('the device cards', () {
    const usb = MidiDevice(id: 'usb', name: 'USB controller');
    const din = MidiDevice(id: 'din', name: 'MIDI In');

    test('the input in use says how it stands; the rest are available', () {
      for (final (status, expected) in [
        (MidiConnectionStatus.connected, MidiDeviceStatus.connected),
        (MidiConnectionStatus.connecting, MidiDeviceStatus.connecting),
        (MidiConnectionStatus.error, MidiDeviceStatus.openFailed),
        (MidiConnectionStatus.deviceGone, MidiDeviceStatus.disconnected),
      ]) {
        final cards = midiDeviceCards(
          MidiConnection(
            devices: const [usb, din],
            selectedId: 'usb',
            status: status,
          ),
        );
        expect(cards.map((c) => c.status), [
          expected,
          MidiDeviceStatus.available,
        ]);
        expect(cards.map((c) => c.selected), [true, false]);
      }
    });

    test('an unplugged input in use keeps a card, by its saved name', () {
      final cards = midiDeviceCards(
        const MidiConnection(
          devices: [din],
          selectedId: 'usb',
          selectedName: 'USB controller',
          status: MidiConnectionStatus.deviceGone,
        ),
      );
      expect(cards.map((c) => (c.id, c.name, c.online)), [
        ('din', 'MIDI In', true),
        ('usb', 'USB controller', false),
      ]);
    });

    test('with nothing in use every input is available', () {
      final cards = midiDeviceCards(
        const MidiConnection(devices: [usb, din]),
      );
      expect(cards.every((c) => !c.selected), isTrue);
    });
  });
}
