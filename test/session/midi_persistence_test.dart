import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _NamedEngine extends PumpedNativeEngine {
  @override
  String get deviceName => 'session test rig';
}

void main() {
  for (final external in [false, true]) {
    test(
      'session saves and reloads all Released mix values from '
      '${external ? 'External' : 'MIDI owner'}',
      () async {
        final engine = _NamedEngine();
        final looper = LooperRepository(engine: engine);
        expect(
          looper.startEngine(
            const EngineConfig(
              sampleRate: 48000,
              inputChannels: 4,
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
        final mix = MixSettingsCoordinator(
          repository: looper,
          persistence: SettingsMixPersistence(settings),
          device: () => 'session test rig',
        );
        final projection = FxChainPersistence(looper: looper);
        final sessions = SessionRepository(
          engine: engine,
          sessionsRoot: () async => directory.path,
        );
        final performance = PerformanceRepository(
          engine: engine,
          exportsRoot: () async => directory.path,
        );
        final tempo = TempoSettings(repository: looper, settings: settings);
        await tempo.load();
        expect((await tempo.recordStartControl.setCountInBars(0)).isOk, isTrue);
        final playback = PlaybackSettings(
          repository: looper,
          settings: settings,
        );
        await playback.load();
        final record = RecordSettings(repository: looper, settings: settings);
        await record.load();
        final timing = RecordTimingSettings(
          repository: looper,
          settings: settings,
        );
        await timing.load();
        final fade = FadeSettings(
          settings: settings,
          blocked: () => false,
          sessionBlocked: () => false,
        );
        await fade.load();
        addTearDown(fade.close);
        final cubit = SessionCubit(
          settings: settings,
          captureSettings: SessionSettingsCoordinator(
            fade: fade,
            looper: looper,
            mix: mix,
            fx: projection,
            owners: SettingsOwners([...tempo.owners, ...playback.owners]),
            tempo: tempo,
            playback: playback,
            record: record,
            timing: timing,
          ),
          repository: sessions,
          looper: looper,
          performance: performance,
          mixSettings: mix,
          fxPersistence: projection,
          mixPersistence: SettingsMixPersistence(settings),
          exportDirectory: () async => directory.path,
        );
        ControlCubit? control;
        PedalRepository? pedal;
        ControllerRepository? controller;
        FakePedalLink? link;
        Future<void> sendExternal(int value, double expected) async {
          link!.emit(
            CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.switchPedal,
              value: value,
            ),
          );
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            if (((looper.mixSettingsSnapshot.trackLevels[0] ?? 1) - expected)
                    .abs() <
                .0001) {
              break;
            }
          }
          expect(
            looper.mixSettingsSnapshot.trackLevels[0],
            closeTo(expected, .0001),
          );
        }

        addTearDown(() async {
          await control?.close();
          await controller?.dispose();
          await pedal?.dispose();
          await cubit.close();
          await timing.close();
          await record.close();
          await playback.close();
          await tempo.close();
          await mix.close();
          await projection.close();
          performance.dispose();
          pump.cancel();
          await looper.dispose();
          directory.deleteSync(recursive: true);
        });
        await looper.settleMixSettings();
        expect((await mix.setInputPair(input: 0, paired: true)).isOk, isTrue);
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 256, input: .5);
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 0);
        looper.setMonitorInputMode(input: 0, mode: MonitorMode.on);
        await looper.settleMixSettings();
        const gains = <MixValueTarget>[
          TrackVolumeTarget(0),
          LaneVolumeTarget(0, 0),
          MonitorVolumeTarget(0),
        ];
        const bipolar = <MixValueTarget>[
          TrackPanTarget(0),
          InputPanTarget(2),
          PairBalanceTarget(0),
          OutputBalanceTarget(0),
        ];
        final released = <MixValueTarget, double>{
          for (final target in gains) target: target.fromDomain(.2),
          for (final target in bipolar) target: target.fromDomain(-.25),
          const OutputLevelTarget(0): .2,
        };
        final held = <MixValueTarget, double>{
          for (final target in gains) target: target.fromDomain(.8),
          for (final target in bipolar) target: target.fromDomain(.75),
          const OutputLevelTarget(0): .8,
        };
        if (external) {
          link = FakePedalLink();
          pedal = PedalRepository(link);
          controller = ControllerRepository(
            sources: [ConsoleCtrlSource(pedal)],
          );
          control = ControlCubit(
            fadeSettings: testFadeSettings(),
            decayControl: playback.decayControl,
            oneShotControl: playback.oneShotControl,
            recordLengthControl: record,
            recordTimingControl: timing,
            clickVolumeControl: tempo.clickVolumeControl,
            clickModeControl: tempo.clickModeControl,
            recordStartControl: tempo.recordStartControl,
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: performance,
            mixSettings: mix,
            fxPersistence: projection,
            controller: controller,
          );
          link.hello();
          await control.load();
          await control.setPedalSetup(
            PedalSetup(
              external: ExternalPedalSetup(
                jacks: {
                  PedalCtrlJack.ctrl1: ExternalJackSetup(
                    single: ExternalSwitchSetup(
                      controls: ExternalControls(
                        parameters: [
                          for (final entry in held.entries)
                            ExternalParameter(
                              target: entry.key,
                              active: entry.value,
                              inactive: released[entry.key]!,
                              condition: ExternalValueCondition.heldReleased,
                            ),
                        ],
                      ),
                    ),
                  ),
                },
              ),
            ),
          );
          await sendExternal(255, .8);
        } else {
          expect(
            (await mix.setControllerValues(
              held,
              releasedValues: released,
            )).isOk,
            isTrue,
          );
        }
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
        expect(
          bundle.session.tracks.first.lanes.first.volume,
          closeTo(.2, .0001),
        );
        expect(bundle.session.monitors.single.volume, closeTo(.2, .0001));
        expect(bundle.session.trackPans[0], -.25);
        expect(bundle.session.inputSetup.pan[2], -.25);
        expect(bundle.session.inputSetup.pairs[0], -.25);
        expect(bundle.session.outputSetup.level[0], .2);
        expect(bundle.session.outputSetup.balance[0], -.25);
        final capture = performanceChainsFromLooper(looper);
        expect(capture.monitors.single.volume, closeTo(.8, .0001));
        final boot = await settings.loadMixSettings('session test rig');
        expect(boot.laneLevels[(0, 0)], closeTo(.2, .0001));
        expect(boot.monitorLevels[0], closeTo(.2, .0001));
        expect(boot.inputSetup.pairs[0], -.25);
        expect(boot.outputSetup.level[0], .2);
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
        if (external) {
          await sendExternal(0, .2);
        } else {
          expect((await mix.setControllerValues(released)).isOk, isTrue);
        }
        expect(
          looper.mixSettingsSnapshot.laneLevels[(0, 0)],
          closeTo(.2, .0001),
        );
        expect(looper.mixSettingsSnapshot.monitorLevels[0], closeTo(.2, .0001));
        await cubit.saveAs('released MIDI');
        expect(cubit.state.outcome, SessionOutcome.saved);
        final afterRelease = await sessions.read(
          await sessions.bundlePath('released MIDI'),
        );
        expect(afterRelease.session.monitors.single.volume, closeTo(.2, .0001));
        expect(afterRelease.session.inputSetup.pairs[0], -.25);
        await control?.close();
        control = null;
        await cubit.loadNamed('held MIDI');
        expect(cubit.state.outcome, SessionOutcome.loaded);
        expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.2, .0001));
        expect(
          looper.mixSettingsSnapshot.laneLevels[(0, 0)],
          closeTo(.2, .0001),
        );
        expect(looper.mixSettingsSnapshot.monitorLevels[0], closeTo(.2, .0001));
        expect(looper.inputSetup.pairs[0], -.25);
        expect(looper.mixSettingsSnapshot.outputSetup.of(0).balance, -.25);
      },
      skip: Platform.environment['SEGNO_ENGINE_LIB'] == null
          ? 'Requires native pump library'
          : null,
    );
  }
}
