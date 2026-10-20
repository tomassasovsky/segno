import 'package:flutter_test/flutter_test.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:segno_engine/segno_engine.dart';

/// A mock engine whose release lane refuses the next few releases.
class _FullLaneEngine extends MockAudioEngine {
  int refuseReleases = 0;

  @override
  EngineResult instrumentRelease(int origin) {
    if (refuseReleases > 0) {
      refuseReleases--;
      return EngineResult.capacity;
    }
    return super.instrumentRelease(origin);
  }

  @override
  EngineResult instrumentSustain({
    required int slot,
    required int origin,
    required bool on,
  }) {
    if (!on && refuseReleases > 0) {
      refuseReleases--;
      return EngineResult.capacity;
    }
    return super.instrumentSustain(slot: slot, origin: origin, on: on);
  }
}

void main() {
  const pad = 6;
  const keys = 1;

  late _FullLaneEngine engine;
  late List<Instrument> instruments;
  late NoteDispatcher notes;

  Instrument instrument(String id, int slot, {ComputerKeys? computer}) =>
      Instrument(
        id: id,
        slot: slot,
        name: id,
        soundId: 'pad',
        params: const [0, 0, 0],
        keys: computer ?? const ComputerKeys(),
      );

  setUp(() {
    engine = _FullLaneEngine()
      ..start(MockAudioEngine().defaultConfig)
      ..setInstrument(slot: 0, patch: pad)
      ..setInstrument(slot: 1, patch: keys);
    instruments = [
      instrument('a', 0, computer: const ComputerKeys(enabled: true)),
      instrument(
        'b',
        1,
        computer: const ComputerKeys(
          enabled: true,
          mappings: [
            KeyMapping(key: 'a', notes: [48, 52, 55]),
          ],
        ),
      ),
    ];
    notes = NoteDispatcher(engine: engine, instruments: () => instruments);
  });

  List<int> voices() => engine.snapshot().instruments.voices;

  test('a press is one token; a chord sounds whole and ends together', () {
    final single = notes.press('a', const [60])!;
    final chord = notes.press('b', const [60, 64, 67, 71])!;
    expect(single, isNot(chord));
    expect(voices().take(2), [1, 4]);
    notes.release(chord);
    expect(voices().take(2), [1, 0]);
    expect(notes.press('nobody', const [60]), isNull);
  });

  test(
    'a computer key plays every instrument that maps it, repeats ignored',
    () {
      notes
        ..keyDown('A')
        ..keyDown('a'); // the repeat of a held key
      expect(voices().take(2), [1, 3]);
      expect(notes.keysDown, ['A']);
      notes.keyUp('a');
      expect(voices().take(2), [0, 0]);
      expect(notes.keyOwner('A')!.id, 'a');
      expect(notes.keyOwner('Q'), isNull);
    },
  );

  test('a key-up ends its notes even after the keys were turned off', () {
    notes.keyDown('A');
    instruments = [
      for (final i in instruments) i.copyWith(keys: const ComputerKeys()),
    ];
    notes
      ..keyDown('S') // nothing claims it now
      ..keyUp('A');
    expect(voices().take(2), [0, 0]);
  });

  test('losing focus lets go of every held key', () {
    notes
      ..keyDown('A')
      ..keyDown('S');
    expect(voices()[0], 2);
    notes.releaseAllKeys();
    expect(voices().take(2), [0, 0]);
    expect(notes.keysDown, isEmpty);
  });

  test('a latch toggles under its key', () {
    expect(notes.toggleLatch('pad1', 'a', const [60]), isTrue);
    expect(notes.isLatched('pad1'), isTrue);
    expect(voices()[0], 1);
    expect(notes.toggleLatch('pad1', 'a', const [60]), isFalse);
    expect(voices()[0], 0);
    expect(notes.toggleLatch('pad2', 'nobody', const [60]), isFalse);
  });

  test('sustain holds a released note until its key lets go', () {
    notes.sustain('pedal', 'a', on: true);
    final t = notes.press('a', const [60])!;
    notes.release(t);
    expect(voices()[0], 1);
    notes
      ..sustain('pedal', 'a', on: true) // already held: nothing new
      ..sustain('pedal', 'a', on: false);
    expect(voices()[0], 0);
    notes
      ..sustain('ghost', 'nobody', on: true)
      ..sustain('ghost', 'nobody', on: false);
  });

  test('a release the lane cannot take is retried until accepted', () {
    final t = notes.press('a', const [60])!;
    notes.sustain('pedal', 'b', on: true);
    engine.refuseReleases = 3;
    notes
      ..release(t)
      ..sustain('pedal', 'b', on: false);
    expect(notes.owedReleases, 2);
    expect(voices()[0], 1);
    notes.retry(); // one more refusal, then both land
    expect(notes.owedReleases, 1);
    notes.retry();
    expect(notes.owedReleases, 0);
    expect(voices()[0], 0);
    expect(engine.simulatedSustain(1), isEmpty);
  });

  test('a reset drops held keys, latches, sustain and owed releases', () {
    notes
      ..keyDown('A')
      ..toggleLatch('pad', 'a', const [62])
      ..sustain('pedal', 'a', on: true);
    engine.refuseReleases = 1;
    notes
      ..release(99)
      ..reset();
    expect(notes.keysDown, isEmpty);
    expect(notes.isLatched('pad'), isFalse);
    expect(notes.owedReleases, 0);
    notes.keyUp('A'); // nothing left to release
  });

  test('tokens wrap within 31 bits', () {
    final first = notes.press('a', const [60])!;
    expect(first, greaterThan(0));
    expect(first, lessThanOrEqualTo(0x7fffffff));
  });
}
