import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';

void main() {
  InstrumentsWorkingCopy addAll(int count) {
    var copy = const InstrumentsWorkingCopy();
    for (var n = 0; n < count; n++) {
      copy = copy
          .add(id: 'i$n', name: 'Keys $n', soundId: 'keys', params: [1, 2, 3])
          .copy!;
    }
    return copy;
  }

  group('InstrumentsWorkingCopy', () {
    test('add fills the first free slot with its controllers off', () {
      final copy = addAll(2).remove('i0', keepLabel: false);
      final added = copy
          .add(id: 'x', name: 'Pad', soundId: 'pad', params: [4, 5, 6])
          .copy!;
      final x = added.byId('x')!;
      expect(x.slot, 0);
      expect(x.midi.enabled, isFalse);
      expect(x.keys.enabled, isFalse);
      expect(x.keys.mappings, ComputerKeys.defaultMappings);
      expect(added.instruments.map((i) => i.slot), [0, 1]);
    });

    test('a ninth instrument is refused with the reason', () {
      final full = addAll(8);
      expect(full.freeSlot, isNull);
      final result = full.add(
        id: 'z',
        name: 'Z',
        soundId: 'pad',
        params: [0, 0, 0],
      );
      expect(result.copy, isNull);
      expect(result.refusal, AddRefusal.full);
    });

    test('a tombstone holds its slot until cleared', () {
      final copy = addAll(8).remove('i3', keepLabel: true);
      expect(copy.tombstones, [const Tombstone(slot: 3, name: 'Keys 3')]);
      expect(
        copy.add(id: 'z', name: 'Z', soundId: 'pad', params: [0, 0, 0]).refusal,
        AddRefusal.tombstoned,
      );
      final cleared = copy.clearTombstone(3);
      expect(cleared.freeSlot, 3);
      expect(cleared.tombstones, isEmpty);
      expect(copy.remove('nobody', keepLabel: true), copy);
    });

    test('replace keeps the identity and slot', () {
      final copy = addAll(2);
      final renamed = copy.replace(copy.byId('i1')!.copyWith(name: 'Bass'));
      expect(renamed.byId('i1')!.name, 'Bass');
      expect(renamed.bySlot(1)!.id, 'i1');
      expect(renamed.bySlot(5), isNull);
      expect(renamed.byId('i1')!.source, 33); // sources 32-39
    });

    test('round-trips through JSON', () {
      final copy = addAll(2)
          .replace(
            const Instrument(
              id: 'i1',
              slot: 1,
              name: 'Pads',
              soundId: 'pad',
              params: [10, 20.5, 30],
              midi: MidiNoteInput(
                enabled: true,
                deviceId: 'dev',
                channel: 10,
                low: 36,
                high: 72,
                remaps: [
                  NoteRemap(
                    trigger: RemapTrigger.controller,
                    number: 64,
                    channel: 2,
                    notes: [60, 67],
                  ),
                ],
              ),
              keys: ComputerKeys(
                enabled: true,
                mappings: [
                  KeyMapping(key: 'Q', notes: [48, 52]),
                ],
              ),
            ),
          )
          .remove('i0', keepLabel: true);
      final decoded = InstrumentsWorkingCopy.fromJson(
        jsonDecode(jsonEncode(copy.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, copy);
    });

    test('refuses malformed stored data', () {
      Map<String, dynamic> stored(List<Map<String, dynamic>> instruments) => {
        'version': 1,
        'instruments': instruments,
      };
      Map<String, dynamic> one(String id, int slot) => {
        'id': id,
        'slot': slot,
        'name': 'n',
        'soundId': 'pad',
        'params': [1, 2, 3],
      };
      for (final bad in <Map<String, dynamic>>[
        {'version': 2},
        stored([one('a', 0), one('b', 0)]),
        stored([one('a', 0), one('a', 1)]),
        stored([one('a', 8)]),
        stored([
          {
            ...one('a', 0),
            'params': [1, 2],
          },
        ]),
        stored([
          {...one('a', 0)}..remove('id'),
        ]),
        stored([
          {
            ...one('a', 0),
            'midi': {
              'remaps': [
                {
                  'trigger': 'note',
                  'number': 1,
                  'notes': ['x'],
                },
              ],
            },
          },
        ]),
      ]) {
        expect(
          () => InstrumentsWorkingCopy.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('a channel can be cleared to All', () {
      const midi = MidiNoteInput(channel: 3);
      expect(midi.copyWith(clearChannel: true).channel, isNull);
      expect(midi.copyWith(low: 10).channel, 3);
    });
  });
}
