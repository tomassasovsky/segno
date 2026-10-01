import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

void main() {
  test(
    'session waits for MIDI receipt and saves authored Released values',
    () async {
      final engine = PumpedNativeEngine();
      final looper = LooperRepository(engine: engine);
      expect(
        looper.startEngine(
          const EngineConfig(
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
            maxLoopFrames: 8192,
          ),
        ),
        EngineResult.ok,
      );
      final pump = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      final directory = Directory.systemTemp.createTempSync(
        'segno-midi-session',
      );
      final settings = SettingsRepository(store: FakeKeyValueStore());
      final mix = testMixSettings(looper, settings: settings);
      final projection = FxChainPersistence(looper: looper);
      final sessions = SessionRepository(
        engine: engine,
        sessionsRoot: () async => directory.path,
      );
      final performance = PerformanceRepository(
        engine: engine,
        exportsRoot: () async => directory.path,
      );
      final cubit = SessionCubit(
        repository: sessions,
        looper: looper,
        performance: performance,
        mixSettings: mix,
        fxPersistence: projection,
        mixPersistence: SettingsMixPersistence(settings),
        exportDirectory: () async => directory.path,
      );
      addTearDown(() async {
        await cubit.close();
        await mix.close();
        performance.dispose();
        pump.cancel();
        await looper.dispose();
        directory.deleteSync(recursive: true);
      });
      await looper.settleMixSettings();
      expect(
        (await mix.setMidiTrackVolume(.8, channel: 0, releasedValue: .2)).isOk,
        isTrue,
      );
      expect(
        looper.setTrackEffects(
          channel: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.drive,
              slotId: 'drive',
              params: const [.8, .4, .5],
            ),
          ],
        ),
        EngineResult.ok,
      );
      final ticket = projection.beginPending();
      await looper.settleFxRecipes();
      var completed = false;
      final saving = cubit.saveAs('held MIDI').then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(completed, isFalse);
      projection
        ..replace(
          powers: const {},
          parameters: {
            const FxParamTarget(
              address: FxAddress(stage: FxStage.track),
              slotId: 'drive',
              param: 0,
            ): .2,
          },
        )
        ..finishPending(ticket);
      await saving;
      expect(cubit.state.outcome, SessionOutcome.saved);
      final bundle = await sessions.read(
        await sessions.bundlePath('held MIDI'),
      );
      expect(bundle.session.trackLevels[0], closeTo(.2, .0001));
      final saved = decodeFxChain(bundle.session.trackChains.single.encoded);
      expect(
        (saved.entries.single as BuiltInEffect).params.first,
        closeTo(.2, .0001),
      );
      expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.8, .0001));
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params.first,
        closeTo(.8, .0001),
      );
    },
    skip: Platform.environment['SEGNO_ENGINE_LIB'] == null
        ? 'Requires native pump library'
        : null,
  );
}
