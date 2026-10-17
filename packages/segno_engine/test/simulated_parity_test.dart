@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/simulated_instruments.dart'
    show referenceSynthCatalogue;

/// The simulated instrument model against the REAL engine: one script, voice
/// counts per slot compared after every step, and the model's reference
/// catalogue pinned to the engine's table. Self-skips when `SEGNO_ENGINE_LIB`
/// is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  test(
    'the reference catalogue matches the engine field by field',
    () {
      final engine = PumpedNativeEngine();
      addTearDown(engine.dispose);
      final native = engine.synthCatalogue();
      const reference = referenceSynthCatalogue;
      expect(native.patches, hasLength(reference.patches.length));
      for (var i = 0; i < native.patches.length; i++) {
        final n = native.patches[i];
        final r = reference.patches[i];
        expect((n.index, n.id, n.family), (r.index, r.id, r.family));
        for (var p = 0; p < kSynthFamilyParams; p++) {
          expect(n.defaults[p], closeTo(r.defaults[p], 1e-4));
        }
      }
      for (final family in SynthFamily.values) {
        final n = native.paramsOf(family);
        final r = reference.paramsOf(family);
        expect(n, hasLength(r.length), reason: family.name);
        for (var p = 0; p < n.length; p++) {
          expect(
            (n[p].key, n[p].unit, n[p].exponential),
            (r[p].key, r[p].unit, r[p].exponential),
          );
          expect(n[p].atMin, closeTo(r[p].atMin, 1e-4));
          expect(n[p].atMax, closeTo(r[p].atMax, 1e-2));
        }
      }
    },
    skip: skip,
  );

  test(
    'the simulated model counts voices as the engine does',
    () {
      final native = PumpedNativeEngine();
      addTearDown(native.dispose);
      final mock = MockAudioEngine();
      const config = EngineConfig(
        inputChannels: 1,
        outputChannels: 2,
        maxLoopFrames: 48000,
      );
      expect(native.start(config), EngineResult.ok);
      expect(mock.start(mock.defaultConfig), EngineResult.ok);
      final catalogue = native.synthCatalogue();
      final pad = catalogue.byId('pad')!.index;
      final keys = catalogue.byId('keys')!.index;
      final drums = catalogue.byId('drums')!.index;

      // Every step runs on both; the engine then plays 0.25 s, long enough
      // for the shortest release (0.08 s) and any fade to finish.
      var step = 0;
      void both(void Function(InstrumentHost engine) action) {
        action(native);
        action(mock);
        for (var i = 0; i < 24; i++) {
          native.pump();
        }
        step++;
        expect(
          native.snapshot().instruments.voices,
          mock.snapshot().instruments.voices,
          reason: 'after step $step',
        );
      }

      both(
        (e) => e
          ..setInstrument(slot: 0, patch: pad, params: const [42, 0, 0])
          ..setInstrument(slot: 1, patch: keys, params: const [50, 0, 50])
          ..setInstrument(slot: 2, patch: drums),
      );
      // a chord, then a single strike for the same origin replaces it
      both(
        (e) => e.instrumentChordOn(
          slot: 0,
          origin: 1,
          notes: const [60, 64, 67],
          velocity: 100,
        ),
      );
      both(
        (e) => e.instrumentNoteOn(slot: 0, origin: 1, note: 72, velocity: 90),
      );
      // two origins on another slot; one released
      both(
        (e) => e
          ..instrumentNoteOn(slot: 1, origin: 2, note: 60, velocity: 90)
          ..instrumentNoteOn(slot: 1, origin: 3, note: 62, velocity: 90),
      );
      both((e) => e.instrumentRelease(2));
      // a re-strike under sustain stays distinct, and the sustain ends both
      both(
        (e) => e
          ..instrumentSustain(slot: 1, origin: 50, on: true)
          ..instrumentNoteOn(slot: 1, origin: 4, note: 65, velocity: 90),
      );
      both((e) => e.instrumentRelease(4));
      both(
        (e) => e.instrumentNoteOn(slot: 1, origin: 4, note: 65, velocity: 90),
      );
      both((e) => e.instrumentRelease(4));
      both((e) => e.instrumentSustain(slot: 1, origin: 50, on: false));
      // a kit: only GM notes sound; a hit outlives the 0.25 s step, so
      // compare before its end on the engine as well
      both(
        (e) => e.instrumentNoteOn(slot: 2, origin: 6, note: 37, velocity: 90),
      );
      // the voice limit steals, then lowering it trims
      both(
        (e) => e
          ..setVoiceLimit(3)
          ..instrumentChordOn(
            slot: 1,
            origin: 7,
            notes: const [48, 52, 55, 59],
            velocity: 90,
          ),
      );
      both((e) => e.setVoiceLimit(2));
      // a patch change ends the slot
      both((e) => e.setInstrument(slot: 0, patch: keys));
      both((e) => e.instrumentRelease(7));
    },
    skip: skip,
  );
}
