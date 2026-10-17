import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_mapping.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MidiSource cc(int number, {String device = 'dev', int? channel = 0}) =>
      MidiSource(
        device: device,
        kind: ControllerSourceKind.midiCc,
        number: number,
        channel: channel,
      );
  MidiMapping mapping(String id, MidiSource source, {bool enabled = true}) =>
      MidiMapping(
        id: id,
        source: source,
        behavior: MidiBehavior.continuous,
        enabled: enabled,
        controls: [
          MidiParameterControl(key: 'stable-target', low: 0.8, high: 0.2),
        ],
      );

  test('mapping and set detach lists and keep valid unavailable keys', () {
    final controls = <MidiControl>[
      MidiParameterControl(key: 'deleted-but-stable', low: 1, high: 0),
    ];
    final row = MidiMapping(
      id: 'm1',
      source: cc(1),
      behavior: MidiBehavior.continuous,
      controls: controls,
    );
    controls.clear();
    expect(row.controls.length, 1);
    expect(row.controls.clear, throwsUnsupportedError);
    final rows = <MidiMapping>[row];
    final set = MidiMappingSet(mappings: rows);
    rows.clear();
    expect(set.mappings.length, 1);
    expect(set.mappings.clear, throwsUnsupportedError);
    expect(MidiMappingSet.fromJson(set.toJson()), set);
  });

  test('disabled mapping still reserves source footprint and All overlaps', () {
    final disabled = mapping('m1', cc(21, channel: null), enabled: false);
    final set = MidiMappingSet(mappings: [disabled]);
    expect(set.conflictWith(cc(21, channel: 3)), disabled);
    expect(
      () => set.withMapping(mapping('m2', cc(21, channel: 3))),
      throwsFormatException,
    );
    expect(set.conflictWith(cc(21, device: 'other')), isNull);
  });

  test(
    'malformed explicit rows reject the entire set without dropping siblings',
    () {
      final good = mapping('m1', cc(21)).toJson();
      final malformed = [
        {...good, 'enabled': 'false'},
        {
          ...good,
          'controls': [42],
        },
        {...good, 'controls': <Object>[]},
        {
          ...good,
          'controls': [
            {'kind': 'parameter', 'key': 'x', 'low': 0.2},
          ],
        },
        {
          ...good,
          'source': {...cc(21).toJson(), 'channel': null},
        },
      ];
      for (final bad in malformed) {
        expect(
          () => MidiMappingSet.fromJson([good, bad]),
          throwsFormatException,
        );
      }
      expect(() => MidiMappingSet.fromJson(null), throwsFormatException);
      expect(
        () => MidiMappingSet.fromJson([good, good]),
        throwsFormatException,
      );
    },
  );

  test('constructors and copy reject invalid ranges, keys and behaviors', () {
    expect(
      () => MidiParameterControl(key: 'x', low: double.nan, high: 1),
      throwsFormatException,
    );
    expect(() => MidiActionControl(key: ''), throwsFormatException);
    expect(
      () => MidiMapping(
        id: 'bad',
        source: cc(2),
        behavior: MidiBehavior.continuous,
        controls: [MidiActionControl(key: 'a')],
      ),
      throwsFormatException,
    );
    final row = mapping('m1', cc(1));
    expect(
      () => row.copyWith(
        controls: [
          MidiParameterControl(key: 'x', low: 0, high: 1),
          MidiActionControl(key: 'x'),
        ],
      ),
      throwsFormatException,
    );
  });
}
