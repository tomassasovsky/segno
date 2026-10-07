@Tags(['fuzz'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart'
    show le_midi;

/// The instrument seam against the REAL native engine, driven through the
/// device-free pump. Self-skips when `SEGNO_ENGINE_LIB` is unset; build it
/// first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  PumpedNativeEngine configured() {
    final engine = PumpedNativeEngine();
    addTearDown(engine.dispose);
    expect(
      engine.start(
        const EngineConfig(
          inputChannels: 1,
          outputChannels: 2,
          maxLoopFrames: 48000,
        ),
      ),
      EngineResult.ok,
    );
    return engine;
  }

  test(
    'reads the 19 patches and the parameters of every family',
    () {
      final engine = PumpedNativeEngine();
      addTearDown(engine.dispose);
      final catalogue = engine.synthCatalogue();
      expect(catalogue.patches, hasLength(kSynthPatches));
      expect(catalogue.patches.map((p) => p.id).toSet(), hasLength(19));
      for (var i = 0; i < kSynthPatches; i++) {
        expect(catalogue.patches[i].index, i);
        expect(catalogue.patches[i].defaults, hasLength(kSynthFamilyParams));
      }
      expect(catalogue.byId('pad')!.family, SynthFamily.synths);
      for (final family in SynthFamily.values) {
        expect(
          catalogue.paramsOf(family),
          hasLength(kSynthFamilyParams),
          reason: family.name,
        );
      }
      final cutoff = catalogue.paramsOf(SynthFamily.synths).first;
      expect(cutoff.key, 'cutoff');
      expect(cutoff.exponential, isTrue);
      expect(cutoff.valueAt(100), closeTo(12600, 1));
      expect(identical(engine.synthCatalogue(), catalogue), isTrue);
    },
    skip: skip,
  );

  test(
    'a chord from one origin sounds whole and ends together',
    () {
      final engine = configured();
      final pad = engine.synthCatalogue().byId('pad')!.index;
      engine.setInstrument(slot: 0, patch: pad, params: const [42, 60, 0]);
      expect(
        engine.instrumentChordOn(
          slot: 0,
          origin: 3,
          notes: const [60, 64, 67],
          velocity: 100,
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 256);
      expect(engine.snapshot().instruments.voices[0], 3);
      expect(
        engine.instrumentChordOn(
          slot: 0,
          origin: 4,
          notes: const [],
          velocity: 100,
        ),
        EngineResult.invalid,
      );
      engine.instrumentRelease(3);
      for (var i = 0; i < 48; i++) {
        engine.pump();
      }
      expect(engine.snapshot().instruments.voices[0], 0);
    },
    skip: skip,
  );

  test(
    'a note sounds one voice and its release ends it',
    () {
      final engine = configured();
      final pad = engine.synthCatalogue().byId('pad')!.index;
      expect(
        engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 100),
        EngineResult.noInstrument,
      );
      expect(
        engine.setInstrument(slot: 0, patch: 19),
        EngineResult.unknownPatch,
      );
      expect(engine.setInstrument(slot: 0, patch: pad), EngineResult.ok);
      expect(
        engine.setInstrumentParam(slot: 0, param: 2, value: 0),
        EngineResult.ok,
      );
      expect(engine.setVoiceLimit(16), EngineResult.ok);
      expect(
        engine.instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 100),
        EngineResult.ok,
      );
      engine.pump(frames: 256);
      var instruments = engine.snapshot().instruments;
      expect(instruments.patches[0], pad);
      expect(instruments.voices[0], 1);
      expect(instruments.voiceLimit, 16);
      expect(instruments.peaks[0], greaterThan(0));
      expect(engine.instrumentRelease(1), EngineResult.ok);
      // Release 0 is the shortest release (0.08 s): well within 0.5 s.
      for (var i = 0; i < 48; i++) {
        engine.pump();
      }
      instruments = engine.snapshot().instruments;
      expect(instruments.voices[0], 0);
      expect(instruments.synthEpoch, greaterThan(0));
    },
    skip: skip,
  );

  test(
    'sustain holds a released note on until the contributor lets go',
    () {
      final engine = configured();
      final pad = engine.synthCatalogue().byId('pad')!.index;
      engine
        ..setInstrument(slot: 0, patch: pad, params: const [42, 60, 0])
        ..instrumentSustain(slot: 0, origin: 9, on: true)
        ..instrumentNoteOn(slot: 0, origin: 1, note: 60, velocity: 100)
        ..pump(frames: 256)
        ..instrumentRelease(1);
      for (var i = 0; i < 48; i++) {
        engine.pump();
      }
      expect(engine.snapshot().instruments.voices[0], 1);
      engine.instrumentSustain(slot: 0, origin: 9, on: false);
      for (var i = 0; i < 48; i++) {
        engine.pump();
      }
      expect(engine.snapshot().instruments.voices[0], 0);
    },
    skip: skip,
  );

  test(
    'publishes routes and attaches and detaches a capture handle',
    () {
      final engine = configured();
      expect(
        engine.setInstrumentRoutes(const [
          InstrumentRoute(
            midiEnabled: true,
            port: 2,
            channel: 10,
            remaps: [
              InstrumentRemap(
                port: 2,
                kind: MidiRemapKind.note,
                number: 36,
                notes: [48, 52, 55],
              ),
            ],
          ),
        ]),
        EngineResult.ok,
      );
      expect(
        engine.setInstrumentRoutes(const [
          InstrumentRoute(midiEnabled: true, low: 80, high: 20),
        ]),
        EngineResult.invalid,
      );
      // A capture stand-in: the engine reaches a capture only through the
      // sink at its start, which a zeroed block is (le_midi_port.h).
      final capture = calloc<Uint8>(64).cast<le_midi>();
      addTearDown(() => calloc.free(capture));
      final handle = MidiCaptureHandle(capture);
      expect(engine.attachMidiInput(handle, port: 3), EngineResult.ok);
      engine.pump(frames: 0);
      expect(engine.snapshot().midiInput.isAttached(3), isTrue);
      expect(engine.attachMidiInput(handle, port: 8), EngineResult.invalid);
      expect(engine.detachMidiInput(3), EngineResult.ok);
      engine.pump(frames: 0);
      expect(engine.snapshot().midiInput.attachedMask, 0);
      expect(engine.snapshot().midiInput.rebinds, greaterThan(0));
    },
    skip: skip,
  );
}
