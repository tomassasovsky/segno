import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';

void main() {
  group(
    'confirmed Fade duration with actual native playback',
    skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'),
    () {
      test(
        'Session captures native amount while live Fade continues',
        () async {
          final engine = PumpedNativeEngine();
          final looper = LooperRepository(
            engine: engine,
            ticker: const Stream.empty(),
          );
          addTearDown(looper.dispose);
          final directory = Directory.systemTemp.createTempSync(
            'fade-session-',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          expect(
            looper.startEngine(
              const EngineConfig(
                sampleRate: 8000,
                inputChannels: 1,
                outputChannels: 1,
                maxLoopFrames: 1000,
              ),
            ),
            EngineResult.ok,
          );
          engine.pump(frames: 0);
          expect(
            engine.importTrack(0, Float32List.fromList(List.filled(128, .5))),
            EngineResult.ok,
          );
          expect(engine.commitSession(128, loopBars: 0), EngineResult.ok);
          expect(engine.play(), EngineResult.ok);
          engine.pump(frames: 0);
          // Retain an earlier public projection while native audio advances.
          final earlierProjection = looper.state;
          expect(
            engine.toggleFade(channel: 0, seconds: 4).result,
            EngineResult.ok,
          );
          engine.pump(frames: 8000);
          expect(earlierProjection.tracks[0].fade.amount, 1);
          final sessions = SessionRepository(
            guards: GuardRegistry(),
            engine: engine,
          );
          final saved = await sessions.save(
            directory.path,
            settings: const SessionSettings(),
          );
          expect(saved.tracks.single.fadeAmount, closeTo(.75, 1e-6));
          final read = await sessions.read(directory.path);
          expect(read.session.tracks.single.fadeAmount, closeTo(.75, 1e-6));
          expect(read.laneStems[(0, 0)]!.single, everyElement(.5));
          engine.pump(frames: 8000);
          final fade = engine.snapshot().tracks[0].fade;
          expect(fade.amount, closeTo(.5, 1e-6));
          expect(fade.target, 0);
          expect(fade.fullTravelSeconds, 4);
          expect(engine.exportTrack(0), everyElement(.5));
        },
      );

      test('an edit changes only the next gesture full-travel rate', () async {
        final engine = PumpedNativeEngine();
        final repository = LooperRepository(
          engine: engine,
          ticker: const Stream.empty(),
        );
        final owner = FadeSettings(
          repository: repository,
          settings: SettingsRepository(store: FakeKeyValueStore()),
          blocked: () => false,
          sessionBlocked: () => false,
        );
        addTearDown(repository.dispose);
        addTearDown(owner.close);
        await owner.load();
        expect(
          repository.startEngine(
            const EngineConfig(
              sampleRate: 8000,
              inputChannels: 1,
              outputChannels: 1,
              maxLoopFrames: 1000,
            ),
          ),
          EngineResult.ok,
        );
        // Drain repository startup commands before native import admission.
        engine.pump(frames: 0);
        expect(
          engine.importTrack(0, Float32List.fromList(List.filled(128, .5))),
          EngineResult.ok,
        );
        expect(engine.commitSession(128, loopBars: 0), EngineResult.ok);
        expect(engine.play(), EngineResult.ok);
        engine.pump(frames: 0);
        final before = engine.snapshot().tracks[0];
        final first = repository.toggleFade(
          channel: 0,
          seconds: owner.confirmed.effectiveMs(0) / 1000,
        );
        engine.pump(frames: 8000);
        expect(await first, EngineResult.ok);
        final original = engine.snapshot().tracks[0].fade;
        expect(original.amount, closeTo(.75, 1 / 32000));
        await owner.setDefault(8000);
        expect(engine.snapshot().tracks[0].fade, original);
        engine.pump(frames: 8000);
        expect(engine.snapshot().tracks[0].fade.amount, closeTo(.5, 1 / 32000));
        expect(engine.snapshot().tracks[0].fade.fullTravelSeconds, 4);
        final second = repository.toggleFade(
          channel: 0,
          seconds: owner.confirmed.effectiveMs(0) / 1000,
        );
        engine.pump(frames: 8000);
        expect(await second, EngineResult.ok);
        final after = engine.snapshot().tracks[0];
        expect(after.fade.amount, closeTo(.625, 1 / 32000));
        expect(after.fade.target, 1);
        expect(after.fade.fullTravelSeconds, 8);
        // A single output sample is exactly known PCM times the current amount.
        engine.pump(frames: 1);
        expect(
          engine.snapshot().outputPeaks[0],
          closeTo(.5 * after.fade.amount, 1e-6),
        );
        expect(after.volume, before.volume);
        expect(after.undoDepth, before.undoDepth);
        expect(engine.exportTrack(0), everyElement(.5));
      });
    },
  );
}
