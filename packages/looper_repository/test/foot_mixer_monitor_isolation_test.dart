@Tags(['fuzz'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// Observes the real callback before the device-free pump frees its buffers.
class _OutputBindings extends SegnoEngineBindings {
  _OutputBindings(super.dynamicLibrary);

  Float32List output = Float32List(0);

  @override
  // Native binding names are fixed by the generated FFI interface.
  // ignore: non_constant_identifier_names
  void le_engine_process(
    Pointer<le_engine> engine,
    Pointer<Float> output,
    Pointer<Float> input,
    int frames,
  ) {
    super.le_engine_process(engine, output, input, frames);
    if (frames > 0) {
      // Every test configures two outputs. Copy, rather than retain the view.
      this.output = Float32List.fromList(output.asTypedList(frames * 2));
    }
  }
}

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];

  group(
    '$LooperRepository Foot Mixer native isolation',
    () {
      late _OutputBindings bindings;
      late PumpedNativeEngine engine;
      late LooperRepository repository;

      Future<void> settleMix() async {
        engine.pump(frames: 0);
        expect(await repository.settleMixSettings(), EngineResult.ok);
      }

      void expectStereo({required double left, required double right}) {
        expect(bindings.output, hasLength(1024));
        expect(
          [
            for (var frame = 0; frame < 512; frame++)
              bindings.output[frame * 2],
          ],
          everyElement(closeTo(left, 1e-6)),
        );
        expect(
          [
            for (var frame = 0; frame < 512; frame++)
              bindings.output[frame * 2 + 1],
          ],
          everyElement(closeTo(right, 1e-6)),
        );
      }

      Future<void> seedPlayingLoop() async {
        // Seed content only. Every gain, mute and route under test goes through
        // the real repository; no fake fabricates its audio or transport.
        expect(
          engine.importTrack(1, Float32List(4096)..fillRange(0, 4096, .125)),
          EngineResult.ok,
        );
        expect(engine.commitSession(4096, loopBeats: 0), EngineResult.ok);
        expect(engine.play(channel: 1), EngineResult.ok);
        engine.pump(frames: 0);
        expect(
          repository.setLaneOutput(channel: 1, lane: 0, mask: 2),
          EngineResult.ok,
        );
        await settleMix();
        expect(repository.state.tracks[1].state, TrackState.playing);
      }

      setUp(() async {
        bindings = _OutputBindings(DynamicLibrary.open(library!));
        engine = PumpedNativeEngine(bindings: bindings);
        repository = LooperRepository(
          engine: engine,
          ticker: const Stream<void>.empty(),
        );
        expect(
          repository.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              inputChannels: 1,
              outputChannels: 2,
              maxLoopFrames: 32768,
            ),
          ),
          EngineResult.ok,
        );
        await settleMix();
        expect(
          repository.setInputConditioningEnabled(input: 0, enabled: false),
          EngineResult.ok,
        );
        expect(repository.setClickOutput(0), EngineResult.ok);
        expect(repository.setMasterGain(1), EngineResult.ok);
        expect(engine.setLimiter(enabled: false), EngineResult.ok);
        expect(
          repository.setMonitorInputMode(input: 0, mode: MonitorMode.on),
          EngineResult.ok,
        );
        expect(
          repository.setMonitorOutput(input: 0, mask: 1),
          EngineResult.ok,
        );
        engine.pump(frames: 0);
      });

      tearDown(() => repository.dispose());

      for (final colored in [false, true]) {
        test(
          'monitor gain and mute preserve every captured sample '
          '${colored ? 'with capture trim and input FX' : 'at unity trim'}',
          () async {
            if (colored) {
              expect(
                repository.setInputTrimDb(input: 0, db: -6),
                EngineResult.ok,
              );
              await settleMix();
              expect(
                repository.setMonitorEffects(
                  input: 0,
                  effects: [
                    BuiltInEffect(
                      type: TrackEffectType.drive,
                      params: const [.3, .7, .4, 0],
                      placement: FxPlacement.pre,
                    ),
                  ],
                ),
                EngineResult.ok,
              );
              engine.pump(frames: 0);
              expect(await repository.settleFxRecipes(), EngineResult.ok);
            }
            final inputSetup = repository.inputSetup;
            final effects = repository.monitorEffects(0);
            final fingerprint = engine.monitorFxFingerprint(input: 0);
            expect(repository.record(), EngineResult.ok);
            engine.pump(frames: 0);
            expect(repository.state.tracks[0].state, TrackState.recording);

            // Literal monitor outputs for input .25. All five capture segments
            // remain in the exported assertion, including gain zero and mute.
            const segments = [
              (gain: 1.0, muted: false, output: .25),
              (gain: .5, muted: false, output: .125),
              (gain: 0.0, muted: false, output: 0.0),
              (gain: .5, muted: true, output: 0.0),
              (gain: .5, muted: false, output: .125),
            ];
            for (final segment in segments) {
              expect(
                repository.setMonitorVolume(input: 0, volume: segment.gain),
                EngineResult.ok,
              );
              await settleMix();
              expect(
                repository.setMonitorMute(input: 0, muted: segment.muted),
                EngineResult.ok,
              );
              engine.pump(input: .25);
              expect(repository.state.tracks[0].state, TrackState.recording);
              expect(repository.inputSetup, inputSetup);
              expect(repository.monitorEffects(0), effects);
              expect(engine.monitorFxFingerprint(input: 0), fingerprint);
              expect(repository.monitorOutput(0), 1);
              expect(repository.monitorMode(0), MonitorMode.on);
              if (!colored) expectStereo(left: segment.output, right: 0);
            }

            expect(repository.stopTrack(), EngineResult.ok);
            // The existing defining-take seam consumes a 480-frame overlap
            // without extending the 2560-frame take. Keep the same input in
            // that overlap; assert the entire exported take, not a crop.
            engine.pump(input: .25);
            expect(repository.state.tracks[0].state, TrackState.stopped);
            final captured = engine.exportTrackLane(0, 0);
            expect(captured, hasLength(2560));
            expect(
              captured,
              everyElement(closeTo(colored ? .1252968084 : .25, 1e-6)),
            );
            expect(repository.inputSetup.trimDbOf(0), colored ? -6 : 0);
            expect(repository.monitorEffects(0), effects);
          },
        );
      }

      test(
        'monitor edits leave recorded playback independent and '
        'track gain and mute never rewrite its PCM or park it',
        () async {
          await seedPlayingLoop();
          final recorded = engine.exportTrackLane(1, 0);
          expect(recorded, everyElement(closeTo(.125, 1e-6)));
          const segments = [
            (gain: 1.0, muted: false, output: .25),
            (gain: .5, muted: false, output: .125),
            (gain: 0.0, muted: false, output: 0.0),
            (gain: .5, muted: true, output: 0.0),
            (gain: .5, muted: false, output: .125),
          ];
          for (final segment in segments) {
            expect(
              repository.setMonitorVolume(input: 0, volume: segment.gain),
              EngineResult.ok,
            );
            await settleMix();
            expect(
              repository.setMonitorMute(input: 0, muted: segment.muted),
              EngineResult.ok,
            );
            engine.pump(input: .25);
            expectStereo(left: segment.output, right: .125);
            expect(repository.state.tracks[1].state, TrackState.playing);
            expect(engine.exportTrackLane(1, 0), recorded);
            expect(repository.inputSetup.trimDbOf(0), 0);
          }
          for (final level in [
            (gain: .5, output: .0625),
            (gain: 1.5, output: .1875),
          ]) {
            expect(
              repository.setVolume(level.gain, channel: 1),
              EngineResult.ok,
            );
            await settleMix();
            engine.pump(input: .25);
            expectStereo(left: .125, right: level.output);
            expect(engine.exportTrackLane(1, 0), recorded);
          }
          final position = engine.snapshot().masterPositionFrames;
          expect(repository.setMute(channel: 1, muted: true), EngineResult.ok);
          engine.pump(input: .25);
          expectStereo(left: .125, right: 0);
          expect(repository.state.tracks[1].state, TrackState.playing);
          expect(
            engine.snapshot().masterPositionFrames,
            (position + 512) % 4096,
          );
          expect(repository.setMute(channel: 1, muted: false), EngineResult.ok);
          engine.pump(input: .25);
          expectStereo(left: .125, right: .1875);
          expect(engine.exportTrackLane(1, 0), recorded);
        },
      );

      for (final mode in [MonitorMode.auto, MonitorMode.off]) {
        test(
          '$mode stays closed through mute, unity reset and unmute '
          'while the recorded loop keeps playing',
          () async {
            await seedPlayingLoop();
            expect(
              repository.setMonitorInputMode(input: 0, mode: mode),
              EngineResult.ok,
            );
            expect(
              repository.setMonitorVolume(input: 0, volume: .4),
              EngineResult.ok,
            );
            await settleMix();
            expect(repository.monitorResolved(0), isFalse);
            for (final muted in [true, false]) {
              expect(
                repository.setMonitorMute(input: 0, muted: muted),
                EngineResult.ok,
              );
              expect(
                repository.setMonitorVolume(input: 0, volume: 1),
                EngineResult.ok,
              );
              await settleMix();
              engine.pump(input: .25);
              expectStereo(left: 0, right: .125);
              expect(repository.monitorMode(0), mode);
              expect(repository.monitorResolved(0), isFalse);
              expect(repository.monitorMuted(0), muted);
              expect(repository.monitorVolume(0), 1);
              expect(repository.monitorOutput(0), 1);
              expect(repository.inputSetup.trimDbOf(0), 0);
              expect(repository.state.tracks[1].state, TrackState.playing);
              expect(
                engine.exportTrackLane(1, 0),
                everyElement(closeTo(.125, 1e-6)),
              );
            }
          },
        );
      }
    },
    skip: library == null || library.isEmpty
        ? 'SEGNO_ENGINE_LIB is required for native audio isolation'
        : null,
  );
}
