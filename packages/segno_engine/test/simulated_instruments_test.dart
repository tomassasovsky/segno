import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/simulated_instruments.dart'
    show referenceSynthCatalogue;

/// The mock engine's instrument model ([SimulatedInstruments]), which the
/// test fakes share.
void main() {
  late MockAudioEngine engine;

  const pad = 6;
  const drums = 14;

  setUp(() {
    engine = MockAudioEngine()..start(MockAudioEngine().defaultConfig);
  });

  List<int> voices() => engine.snapshot().instruments.voices;

  test('refuses instrument calls until the engine is configured', () {
    final fresh = MockAudioEngine();
    expect(
      fresh.setInstrument(slot: 0, patch: pad),
      EngineResult.notRunning,
    );
    expect(fresh.setVoiceLimit(8), EngineResult.notRunning);
    expect(fresh.setInstrumentRoutes(const []), EngineResult.notRunning);
    // Attaching does not need a configured engine.
    expect(
      fresh.attachMidiInput(
        MidiCaptureHandle(Pointer.fromAddress(0x10)),
        port: 0,
      ),
      EngineResult.ok,
    );
  });

  test('returns the catalogue and refuses unknown patches and bad slots', () {
    expect(engine.synthCatalogue(), referenceSynthCatalogue);
    expect(
      engine.setInstrument(slot: 0, patch: 19),
      EngineResult.unknownPatch,
    );
    expect(engine.setInstrument(slot: 8, patch: pad), EngineResult.invalid);
    expect(
      engine.setInstrument(slot: 0, patch: pad, params: const [1, 2]),
      EngineResult.invalid,
    );
    expect(
      engine.setInstrumentParam(slot: 0, param: 0, value: 50),
      EngineResult.noInstrument,
    );
  });

  test('a slot takes the patch defaults or the given params', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..setInstrument(slot: 1, patch: pad, params: const [10, 200, -5]);
    expect(engine.simulatedParams(0), [42, 60, 72]);
    expect(engine.simulatedParams(1), [10, 100, 0]);
    expect(
      engine.setInstrumentParam(slot: 1, param: 2, value: 33),
      EngineResult.ok,
    );
    expect(engine.simulatedParams(1), [10, 100, 33]);
    expect(engine.snapshot().instruments.patches.take(2), [pad, pad]);
  });

  test('notes sound until released by origin, on every slot', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..setInstrument(slot: 1, patch: pad);
    expect(
      engine.instrumentNoteOn(slot: 3, origin: 1, note: 60, velocity: 90),
      EngineResult.noInstrument,
    );
    engine
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentNoteOn(slot: 1, origin: 1, note: 64, velocity: 90)
      ..instrumentNoteOn(slot: 1, origin: 2, note: 67, velocity: 90);
    expect(voices().take(2), [1, 2]);
    engine.instrumentRelease(1);
    expect(voices().take(2), [0, 1]);
    // One origin, one sounding note: a new strike replaces it, whatever its
    // note, on that slot only.
    engine
      ..instrumentNoteOn(slot: 1, origin: 2, note: 67, velocity: 90)
      ..instrumentNoteOn(slot: 1, origin: 2, note: 72, velocity: 90);
    expect(voices()[1], 1);
    expect(engine.simulatedVoices.last.note, 72);
    expect(
      engine.instrumentNoteOn(slot: 0, origin: 1, note: 128, velocity: 9),
      EngineResult.invalid,
    );
    expect(
      engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 0),
      EngineResult.invalid,
    );
  });

  test('a chord sounds whole for one origin and replaces its held voice', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..instrumentNoteOn(slot: 0, origin: 5, note: 48, velocity: 90);
    expect(
      engine.instrumentChordOn(
        slot: 0,
        origin: 5,
        notes: const [60, 64, 67],
        velocity: 90,
      ),
      EngineResult.ok,
    );
    expect(engine.simulatedVoices.map((v) => v.note), [60, 64, 67]);
    engine.instrumentRelease(5);
    expect(voices()[0], 0);
    expect(
      engine.instrumentChordOn(
        slot: 0,
        origin: 5,
        notes: const [],
        velocity: 9,
      ),
      EngineResult.invalid,
    );
    expect(
      engine.instrumentChordOn(
        slot: 0,
        origin: 5,
        notes: List.filled(kMaxChordNotes + 1, 60),
        velocity: 9,
      ),
      EngineResult.invalid,
    );
    expect(
      engine.instrumentChordOn(
        slot: 4,
        origin: 5,
        notes: const [60],
        velocity: 9,
      ),
      EngineResult.noInstrument,
    );
  });

  test('a re-strike under sustain stays a distinct voice', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..instrumentSustain(slot: 0, origin: 100, on: true)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentRelease(1)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90);
    expect(voices()[0], 2);
  });

  test('a kit plays only its GM notes', () {
    engine
      ..setInstrument(slot: 0, patch: drums)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 37, velocity: 90)
      ..instrumentNoteOn(slot: 0, origin: 2, note: 38, velocity: 90);
    expect(voices()[0], 1);
  });

  test('sustain holds released notes until every contributor lets go', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..instrumentSustain(slot: 0, origin: 100, on: true)
      ..instrumentSustain(slot: 0, origin: 101, on: true)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentRelease(1);
    expect(voices()[0], 1);
    expect(engine.simulatedVoices.single.sustained, isTrue);
    engine.instrumentSustain(slot: 0, origin: 100, on: false);
    expect(voices()[0], 1);
    engine.instrumentSustain(slot: 0, origin: 101, on: false);
    expect(voices()[0], 0);
  });

  test('a seventeenth contributor is refused and counted', () {
    engine.setInstrument(slot: 0, patch: pad);
    for (var o = 0; o < 17; o++) {
      engine.instrumentSustain(slot: 0, origin: o, on: true);
    }
    expect(engine.simulatedSustain(0), hasLength(16));
    expect(engine.snapshot().instruments.sustainRefused, 1);
  });

  test('drums ignore sustain', () {
    engine
      ..setInstrument(slot: 0, patch: drums)
      ..instrumentSustain(slot: 0, origin: 100, on: true)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 36, velocity: 90)
      ..instrumentRelease(1);
    expect(engine.simulatedSustain(0), isEmpty);
    expect(voices()[0], 0);
    expect(
      engine.instrumentSustain(slot: 1, origin: 1, on: true),
      EngineResult.noInstrument,
    );
  });

  test('the voice limit steals the oldest voice, sustained ones first', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..setVoiceLimit(2)
      ..instrumentSustain(slot: 0, origin: 100, on: true)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentNoteOn(slot: 0, origin: 2, note: 62, velocity: 90)
      ..instrumentRelease(2)
      ..instrumentNoteOn(slot: 0, origin: 3, note: 64, velocity: 90);
    expect(engine.simulatedVoices.map((v) => v.note), [60, 64]);
    expect(engine.snapshot().instruments.voicesStolen, 1);
    expect(engine.snapshot().instruments.voiceLimit, 2);
    engine.setVoiceLimit(1);
    expect(engine.simulatedVoices.map((v) => v.note), [64]);
    expect(engine.setVoiceLimit(0), EngineResult.invalid);
    expect(engine.setVoiceLimit(kMaxVoiceLimit + 1), EngineResult.invalid);
  });

  test('a patch change and a reset end the slot, a reconfigure everything', () {
    engine
      ..setInstrument(slot: 0, patch: pad)
      ..setInstrument(slot: 1, patch: pad)
      ..instrumentSustain(slot: 0, origin: 100, on: true)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentNoteOn(slot: 1, origin: 2, note: 60, velocity: 90)
      // The same patch again: nothing ends.
      ..setInstrument(slot: 0, patch: pad);
    expect(voices().take(2), [1, 1]);
    engine.setInstrument(slot: 0, patch: 5);
    expect(voices().take(2), [0, 1]);
    expect(engine.simulatedSustain(0), isEmpty);
    engine.resetInstrument(1);
    expect(voices()[1], 0);
    final epoch = engine.snapshot().instruments.synthEpoch;
    engine
      ..instrumentNoteOn(slot: 1, origin: 2, note: 60, velocity: 90)
      ..setInstrumentRoutes(const [InstrumentRoute(midiEnabled: true)])
      ..stop()
      ..start(engine.defaultConfig);
    final after = engine.snapshot().instruments;
    expect(after.synthEpoch, epoch + 1);
    expect(after.patches, everyElement(-1));
    expect(after.totalVoices, 0);
    expect(engine.simulatedRoutes, isEmpty);
  });

  test('routes are validated and kept', () {
    expect(
      engine.setInstrumentRoutes(const [
        InstrumentRoute(midiEnabled: true, low: 70, high: 60),
      ]),
      EngineResult.invalid,
    );
    expect(
      engine.setInstrumentRoutes(
        List.filled(kMaxInstruments + 1, InstrumentRoute.disabled),
      ),
      EngineResult.invalid,
    );
    const routes = [InstrumentRoute(midiEnabled: true, port: 1, channel: 10)];
    expect(engine.setInstrumentRoutes(routes), EngineResult.ok);
    expect(engine.simulatedRoutes, routes);
  });

  test('attaching moves a capture between ports; detaching clears', () {
    final a = MidiCaptureHandle(Pointer.fromAddress(0x10));
    final b = MidiCaptureHandle(Pointer.fromAddress(0x20));
    engine
      ..attachMidiInput(a, port: 0)
      ..attachMidiInput(b, port: 3);
    expect(engine.snapshot().midiInput.attachedMask, 0x9);
    engine.attachMidiInput(a, port: 5);
    expect(engine.snapshot().midiInput.attachedMask, 0x28);
    expect(engine.simulatedAttached[5], a);
    engine.detachMidiInput(3);
    expect(engine.snapshot().midiInput.attachedMask, 0x20);
    expect(engine.detachMidiInput(3), EngineResult.ok);
    expect(engine.attachMidiInput(a, port: 8), EngineResult.invalid);
    expect(engine.detachMidiInput(-1), EngineResult.invalid);
  });

  test('records every call by name', () {
    engine
      ..synthCatalogue()
      ..setInstrument(slot: 0, patch: pad)
      ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 90)
      ..instrumentRelease(1);
    expect(engine.instrumentCalls, [
      'synthCatalogue',
      'setInstrument',
      'instrumentNoteOn',
      'instrumentRelease',
    ]);
  });
}
