@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';
import '../../helpers/test_backing.dart';
import '../../helpers/test_mix_settings.dart';

class _Store extends FakeKeyValueStore {
  bool refuse = false;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await super.setBool(key, value: value);
    if (refuse && key == 'looper.auto_record') {
      throw StateError('Sound storage failed after mutation');
    }
  }

  @override
  Future<void> setInt(String key, int value) async {
    if (refuse && key == 'tempo.count_in_bars') {
      throw StateError('Count-in storage unavailable');
    }
    await super.setInt(key, value);
  }
}

Future<void> _until(bool Function() settled, {String? description}) async {
  for (var i = 0; i < 1000 && !settled(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(
    settled(),
    isTrue,
    reason: description ?? 'Expected the real transaction to settle',
  );
}

void main() {
  group(
    'mapped Count-in through runtime, session files and shutdown',
    skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'),
    () {
      late AppRuntime runtime;
      late PumpedNativeEngine engine;
      late LooperRepository looper;
      late SessionRepository sessions;

      /// The id the catalog gave the session saved as [name].
      Future<SessionId> idOf(String name) async =>
          (await sessions.listSessions()).singleWhere((s) => s.name == name).id;
      late _Store store;
      late FakePedalLink link;
      var halts = 0;

      Future<void> start({double active = 2 / 3, double released = 0}) async {
        halts = 0;
        final directory = Directory.systemTemp.createTempSync(
          'segno-count-in-',
        );
        engine = PumpedNativeEngine();
        looper = LooperRepository(engine: engine);
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
        store = _Store();
        store.values['pedal.setup'] = const PedalSetup()
            .copyWith(
              external: ExternalPedalSetup(
                jacks: {
                  PedalCtrlJack.ctrl1: ExternalJackSetup(
                    single: ExternalSwitchSetup(
                      controls: ExternalControls(
                        parameters: [
                          ExternalParameter(
                            target: const CountInValueTarget(),
                            active: active,
                            inactive: released,
                            condition: ExternalValueCondition.heldReleased,
                          ),
                        ],
                      ),
                    ),
                  ),
                },
              ),
            )
            .encode();
        final settings = SettingsRepository(store: store);
        link = FakePedalLink();
        final pedal = PedalRepository(link);
        final controllers = ControllerRepository(
          sources: [ConsoleCtrlSource(pedal)],
        );
        final midi = MidiDeviceRepository(source: null, settings: settings);
        sessions = SessionRepository(
          guards: GuardRegistry(),
          engine: engine,
          sessionsRoot: () async => directory.path,
        );
        final performance = PerformanceRepository(
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => directory.path,
        );
        runtime = AppRuntime(
          guards: GuardRegistry(),
          repository: looper,
          settings: settings,
          mix: testMixSettings(looper, settings: settings),
          controllers: controllers,
          midiDevices: midi,
          pedal: pedal,
          performance: performance,
          sessions: sessions,
          backing: testBackingRepository(),
          powerOff: () async => halts++,
          reboot: () async => halts++,
          storageSettled: () async {},
        );
        addTearDown(() async {
          store.refuse = false;
          await runtime.close();
          await pedal.dispose();
          await controllers.dispose();
          await midi.dispose();
          performance.dispose();
          pump.cancel();
          await looper.dispose();
          directory.deleteSync(recursive: true);
        });
        link.hello();
        await runtime.start();
        expect(
          (await runtime.tempo.recordStartControl.setCountInBars(0)).isOk,
          isTrue,
        );
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 256, input: .5);
        expect(looper.record(), EngineResult.ok);
        engine.pump();
        expect(engine.snapshot().tracks.first.state, TrackState.playing);
        expect(
          (await runtime.tempo.recordStartControl.setSoundStart(
            enabled: true,
          )).isOk,
          isTrue,
        );
      }

      void press() => link.emit(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 255,
        ),
      );

      for (final held in [false, true]) {
        test(
          'Save/Save As and recall use Released intent, Held=$held',
          () async {
            await start(active: held ? 2 / 3 : 0, released: held ? 0 : 2 / 3);
            press();
            await _until(
              () =>
                  runtime.tempo.recordStartOwner.durable.countInBars ==
                      (held ? 0 : 2) &&
                  !runtime.tempo.recordStartOwner.durable.soundStart,
            );
            expect(engine.snapshot().countInBars, held ? 2 : 0);
            expect(engine.snapshot().autoRecord, !held);
            printOnFailure('Hold accepted; saving');
            await runtime.session.saveAs('Held choice');
            expect(runtime.session.state.status, SessionStatus.success);
            final savedAs = await sessions.read(
              await sessions.bundlePathOf(await idOf('Held choice')),
            );
            expect(savedAs.session.countInBars, held ? 0 : 2);
            expect(savedAs.session.autoRecord, isFalse);
            expect(savedAs.session.trackLevels[0] ?? 1, 1);
            expect((await runtime.mix.setTrackVolume(.37)).isOk, isTrue);
            printOnFailure('Save As checked; saving changed track level');
            await runtime.session.save();
            expect(runtime.session.state.status, SessionStatus.success);
            final saved = await sessions.read(
              await sessions.bundlePathOf(await idOf('Held choice')),
            );
            expect(saved.session.countInBars, held ? 0 : 2);
            expect(saved.session.autoRecord, isFalse);
            expect(saved.session.trackLevels[0], .37);
            expect(saved.session.tracks, hasLength(1));
            expect(engine.snapshot().countInBars, held ? 2 : 0);
            printOnFailure('Both files checked; recalling');
            // Opening the current session does nothing (plan Part 4), so
            // recall goes through another current session.
            await runtime.session.saveAs('Elsewhere');
            await runtime.session.open(await idOf('Held choice'));
            printOnFailure('Recall completed');
            expect(runtime.session.state.status, SessionStatus.success);
            expect(engine.snapshot().countInBars, held ? 0 : 2);
            expect(engine.snapshot().autoRecord, isFalse);
            expect(looper.mixSettingsSnapshot.trackLevels[0], .37);
            expect(engine.snapshot().countingIn, isFalse);
          },
        );
      }

      test(
        'shutdown refuses failed release and Retry settles it before halt',
        () async {
          await start();
          press();
          await _until(
            () => engine.snapshot().countInBars == 2,
            description: 'Held 2 accepted',
          );
          await runtime.control.flushMidiConfiguration();
          expect(
            runtime.tempo.recordStartControl.confirmedRecordStart?.countInBars,
            2,
          );
          store.refuse = true;
          const snapshot = PowerSnapshot(currentSessionName: 'set');
          runtime.power
            ..press(snapshot)
            ..shutDown(snapshot, save: () async {});
          await _until(
            () => runtime.power.state.phase == PowerPhase.saveFailed,
            description: 'Shutdown must refuse failed release',
          );
          expect(halts, 0);
          expect(engine.snapshot().countInBars, 2);
          store.refuse = false;
          runtime.power.retry(snapshot);
          await _until(
            () => halts == 1,
            description: 'Retry must halt after repair',
          );
          expect(engine.snapshot().countInBars, 0);
          expect(engine.snapshot().autoRecord, isFalse);
          expect(store.values['tempo.count_in_bars'], 0);
          expect(store.values['looper.auto_record'], isFalse);
          expect(engine.snapshot().countingIn, isFalse);
        },
      );
    },
  );
}
