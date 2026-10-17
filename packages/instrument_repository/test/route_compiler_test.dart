import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:segno_engine/segno_engine.dart';

void main() {
  Instrument instrument(String id, int slot, MidiNoteInput midi) => Instrument(
    id: id,
    slot: slot,
    name: id,
    soundId: 'pad',
    params: const [0, 0, 0],
    midi: midi,
  );

  InstrumentsWorkingCopy copyOf(List<Instrument> instruments) =>
      InstrumentsWorkingCopy(instruments: instruments);

  test('plays nothing unless enabled and its device is attached', () {
    final result = compileRoutes(
      copyOf([
        instrument('off', 0, const MidiNoteInput(deviceId: 'kb')),
        instrument(
          'detached',
          1,
          const MidiNoteInput(enabled: true, deviceId: 'gone'),
        ),
        instrument('none', 2, const MidiNoteInput(enabled: true)),
      ]),
      const {'kb': 0},
    );
    expect(result.routes, hasLength(kMaxInstruments));
    expect(result.routes, everyElement(InstrumentRoute.disabled));
    expect(result.problems, isEmpty);
  });

  test('builds splits, layers and ranges by port and channel', () {
    final result = compileRoutes(
      copyOf([
        instrument(
          'keys',
          0,
          const MidiNoteInput(enabled: true, deviceId: 'kb', channel: 1),
        ),
        instrument(
          'drums',
          3,
          const MidiNoteInput(enabled: true, deviceId: 'kb', channel: 10),
        ),
        instrument(
          'bass',
          5,
          const MidiNoteInput(
            enabled: true,
            deviceId: 'pads',
            low: 24,
            high: 47,
          ),
        ),
      ]),
      const {'kb': 2, 'pads': 6},
    );
    expect(
      result.routes[0],
      const InstrumentRoute(midiEnabled: true, port: 2, channel: 1),
    );
    expect(
      result.routes[3],
      const InstrumentRoute(midiEnabled: true, port: 2, channel: 10),
    );
    expect(
      result.routes[5],
      const InstrumentRoute(midiEnabled: true, port: 6, low: 24, high: 47),
    );
    expect(result.routes[1], InstrumentRoute.disabled);
  });

  test('carries remaps on the device port', () {
    final result = compileRoutes(
      copyOf([
        instrument(
          'pads',
          0,
          const MidiNoteInput(
            enabled: true,
            deviceId: 'kb',
            remaps: [
              NoteRemap(
                trigger: RemapTrigger.note,
                number: 36,
                channel: 10,
                notes: [48, 52, 55],
              ),
              NoteRemap(
                trigger: RemapTrigger.controller,
                number: 64,
                notes: [60],
              ),
            ],
          ),
        ),
      ]),
      const {'kb': 4},
    );
    expect(result.routes[0].remaps, const [
      InstrumentRemap(
        port: 4,
        channel: 10,
        kind: MidiRemapKind.note,
        number: 36,
        notes: [48, 52, 55],
      ),
      InstrumentRemap(
        port: 4,
        kind: MidiRemapKind.controller,
        number: 64,
        notes: [60],
      ),
    ]);
  });

  test('reports truncation to the native caps rather than hiding it', () {
    final result = compileRoutes(
      copyOf([
        instrument(
          'big',
          0,
          MidiNoteInput(
            enabled: true,
            deviceId: 'kb',
            remaps: [
              const NoteRemap(
                trigger: RemapTrigger.note,
                number: 0,
                notes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
              ),
              for (var n = 1; n <= kMaxInstrumentRemaps; n++)
                NoteRemap(trigger: RemapTrigger.note, number: n, notes: [n]),
            ],
          ),
        ),
      ]),
      const {'kb': 0},
    );
    expect(result.routes[0].remaps, hasLength(kMaxInstrumentRemaps));
    expect(result.routes[0].remaps.first.notes, hasLength(kMaxRemapNotes));
    expect(result.problems, const [
      RouteProblem('big', RouteProblemKind.tooManyRemaps),
      RouteProblem('big', RouteProblemKind.tooManyRemapNotes),
    ]);
  });

  test('an out-of-range definition keeps its MIDI off and says so', () {
    final result = compileRoutes(
      copyOf([
        instrument(
          'bad',
          2,
          const MidiNoteInput(enabled: true, deviceId: 'kb', low: 80, high: 20),
        ),
      ]),
      const {'kb': 0},
    );
    expect(result.routes[2], InstrumentRoute.disabled);
    expect(result.problems, const [
      RouteProblem('bad', RouteProblemKind.invalid),
    ]);
  });
}
