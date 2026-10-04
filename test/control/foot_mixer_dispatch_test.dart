import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/audio_bootstrap.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _Clock {
  Future<void> pump([Duration duration = Duration.zero]) =>
      Future<void>.delayed(duration);
}

class _Engine extends FakeAudioEngine {
  bool refuseMute = false;
  final recordedChannels = <int>[];
  @override
  EngineResult record({int channel = 0}) {
    recordedChannels.add(channel);
    return super.record(channel: channel);
  }

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) =>
      refuseMute
      ? EngineResult.notReady
      : super.setMonitorInputMute(input: input, muted: muted);
}

class _Store extends FakeKeyValueStore {
  bool refuseMute = false;
  Completer<void>? gate;
  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key.startsWith('monitor_mute.')) {
      await gate?.future;
      if (refuseMute) throw StateError('monitor storage refused');
    }
    await super.setBool(key, value: value);
  }
}

class _Rig {
  _Rig({Set<int> recorded = const {0, 1, 4}, int excluded = 0}) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      inputChannels: 18,
      excludedInputMask: excluded,
      tracks: [
        for (var channel = 0; channel < 8; channel++)
          if (recorded.contains(channel))
            const TrackSnapshot(
              state: TrackState.playing,
              volume: 1,
              muted: false,
              lengthFrames: 48000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
            )
          else
            const TrackSnapshot.empty(),
      ],
    );
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: persistence,
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      recordStartControl: FakeRecordStartControl(),
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: FakeRecordTimingControl(),
    );
    link.hello();
  }
  final engine = _Engine();
  final store = _Store();
  final ticks = StreamController<void>.broadcast();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final FxChainPersistence persistence;
  late final PedalRepository pedal;
  late final PerformanceRepository performance;
  late final ControlCubit control;

  final _screenContacts = <PedalButton, Object>{};
  void press(PedalButton button) {
    final contact = Object();
    _screenContacts[button] = contact;
    control.footMixerPressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _screenContacts.remove(button);
    if (contact != null) control.footMixerReleased(button, contact);
  }

  void cancel(PedalButton button) {
    final contact = _screenContacts.remove(button);
    if (contact != null) control.footMixerCancelled(button, contact);
  }

  Future<void> close() async {
    await control.close();
    await persistence.close();
    await mix.close();
    await pedal.dispose();
    performance.dispose();
    await looper.dispose();
    await ticks.close();
  }
}

void main() {
  void check(String name, Future<void> Function(_Clock) body) =>
      test(name, () => body(_Clock()));

  late _Rig rig;
  blocTest<ControlCubit, ControlState>(
    'entry chooses current recorded track and keeps normal bank and cursor',
    build: () {
      rig = _Rig();
      return rig.control;
    },
    act: (control) {
      control
        ..selectTrack(4)
        ..setMode(InteractionMode.mixer);
    },
    verify: (control) {
      expect(
        control.state.footMixer,
        const FootMixerSelection(page: 1, channel: 4),
      );
      expect(control.state.cursor, 4);
      expect(control.state.activeBank, 1);
    },
    tearDown: () => rig.close(),
  );

  Future<_Rig> setup(
    _Clock tester, {
    Set<int> recorded = const {0, 1, 4},
    int excluded = 0,
  }) async {
    final rig = _Rig(recorded: recorded, excluded: excluded);
    rig.control.setMode(InteractionMode.mixer);
    await tester.pump();
    return rig;
  }

  Future<void> tap(_Clock tester, _Rig rig, PedalButton button) async {
    rig.press(button);
    await tester.pump(const Duration(milliseconds: 50));
    rig.release(button);
    await tester.pump();
  }

  check('Custom saved hold enters Mixer and consumes its old release', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      final setup = const PedalSetup().withCustom(
        PedalButton.clear,
        bank: 0,
        pair: const ControlGesturePair(hold: ModeAction(InteractionMode.mixer)),
      );
      await r.control.setPedalSetup(setup);
      expect(PedalSetup.decode((await r.settings.loadPedalSetup())!), setup);
      r.control.setMode(InteractionMode.custom);
      r.link.press(PedalButton.clear, down: true);
      await tester.pump(const Duration(milliseconds: 820));
      expect(r.control.state.mode, InteractionMode.mixer);
      r.link.press(PedalButton.clear, down: false);
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0] ?? 1, 1);
    } finally {
      await r.close();
    }
  });

  check('Record Play remains on transport cursor while input 18 is selected', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.control.selectTrack(4);
      r.control.selectFootMixerDomain(FootMixerDomain.inputs);
      for (var page = 0; page < 4; page++) {
        r.control.nextFootMixerPage();
      }
      r.control.selectFootMixerSlot(1);
      r.press(PedalButton.recPlay);
      expect(r.engine.recordedChannels, [4]);
      expect(r.control.state.footMixer.channel, 17);
      r
        ..release(PedalButton.recPlay)
        ..press(PedalButton.stop);
      expect(r.engine.stopTrackCalls, 3);
      r.release(PedalButton.stop);
    } finally {
      await r.close();
    }
  });

  for (final session in [false, true]) {
    check(
      '${session ? "Session" : "device"} replacement invalidates pending hold',
      (tester) async {
        final r = await setup(tester);
        try {
          r.press(PedalButton.track1);
          if (session) {
            await r.looper.applySession(const SessionRig(trackLevels: {0: .4}));
            r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
              tracks: [
                const TrackSnapshot(
                  state: TrackState.playing,
                  volume: .4,
                  muted: false,
                  lengthFrames: 96000,
                  undoDepth: 0,
                  rms: 0,
                  peak: 0,
                ),
                for (var channel = 1; channel < 8; channel++)
                  const TrackSnapshot.empty(),
              ],
            );
          } else {
            r.looper.stopEngine();
            r.looper.startEngine(const EngineConfig());
          }
          r.ticks.add(null);
          await tester.pump();
          expect(r.looper.state.tracks.first.hasContent, isTrue);
          await tester.pump(const Duration(milliseconds: 820));
          r.release(PedalButton.track1);
          expect(r.looper.trackMuted(0), isFalse);
        } finally {
          await r.close();
        }
      },
    );
  }

  check('monitor gain/mute use the existing durable keys, reset keeps mute', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.control.selectFootMixerDomain(FootMixerDomain.inputs);
      await r.control.stepFootMixerGain(-1);
      await r.control.toggleFootMixerMute();
      expect(
        (await r.settings.loadMixSettings(
          r.looper.state.status.deviceName,
        )).monitorLevels[0],
        closeTo(.95, 1e-9),
      );
      expect(await r.settings.loadMonitorMute(0), isTrue);
      await r.settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      final freshEngine = FakeAudioEngine();
      final fresh = LooperRepository(
        engine: freshEngine,
        ticker: const Stream.empty(),
      );
      final freshMix = testMixSettings(fresh, settings: r.settings);
      final freshFx = FxChainPersistence(looper: fresh);
      final monitor = MonitorCubit(
        repository: fresh,
        settings: r.settings,
        mixSettings: freshMix,
        fxPersistence: freshFx,
      );
      try {
        final boot = await tryAutoStartEngine(
          repository: fresh,
          settings: r.settings,
          mixSettings: freshMix,
        );
        expect(boot.started, isTrue);
        await monitor.load();
        expect(fresh.monitorVolume(0), closeTo(.95, 1e-9));
        expect(fresh.monitorMuted(0), isTrue);
      } finally {
        await monitor.close();
        await freshFx.close();
        await freshMix.close();
        await fresh.dispose();
      }

      await r.control.resetFootMixerGain();
      expect(r.looper.monitorMuted(0), isTrue);
      expect(
        (await r.settings.loadMixSettings(
          r.looper.state.status.deviceName,
        )).monitorLevels[0],
        1,
      );
    } finally {
      await r.close();
    }
  });

  check('physical-first overlap cannot release or cancel the physical hold', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      await r.mix.setTrackVolume(.4);
      r.link.press(PedalButton.clear, down: true);
      await tester.pump();
      r
        ..press(PedalButton.clear)
        ..release(PedalButton.clear)
        ..cancel(PedalButton.clear);
      r.control.footMixerCancelled(PedalButton.clear, Object());
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], .4);
      await tester.pump(const Duration(milliseconds: 820));
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], 1);
      r.link.press(PedalButton.clear, down: false);
    } finally {
      await r.close();
    }
  });

  check('screen-first overlap ignores physical release until screen hold', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      await r.mix.setTrackVolume(.4);
      r.press(PedalButton.clear);
      r.link.press(PedalButton.clear, down: true);
      await tester.pump();
      r.link.press(PedalButton.clear, down: false);
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], .4);
      await tester.pump(const Duration(milliseconds: 820));
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], 1);
      r.release(PedalButton.clear);
    } finally {
      await r.close();
    }
  });

  check('stale screen token cannot release or cancel a newer flow contact', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      await r.mix.setTrackVolume(.4);
      final old = Object();
      r.control.footMixerPressed(PedalButton.clear, old);
      r.control
        ..selectFootMixerDomain(FootMixerDomain.inputs)
        ..setMode(InteractionMode.record)
        ..setMode(InteractionMode.mixer)
        ..footMixerCancelled(PedalButton.clear, old);
      final current = Object();
      r.control.footMixerPressed(PedalButton.clear, current);
      r.control
        ..footMixerReleased(PedalButton.clear, old)
        ..footMixerCancelled(PedalButton.clear, old);
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], .4);
      await tester.pump(const Duration(milliseconds: 820));
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], 1);
      r.control.footMixerReleased(PedalButton.clear, current);
    } finally {
      await r.close();
    }
  });

  check('18 inputs page locally and custom mask selects input 18', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.control.selectFootMixerDomain(FootMixerDomain.inputs);
      for (var page = 0; page < 4; page++) {
        await tap(tester, r, PedalButton.bank);
      }
      await tap(tester, r, PedalButton.track2);
      expect(
        r.control.state.footMixer,
        const FootMixerSelection(
          domain: FootMixerDomain.inputs,
          page: 4,
          channel: 17,
        ),
      );
      final frame = r.link.lastFrame!;
      expect(frame.mode, PedalMode.custom);
      expect(frame.activeBank, 0);
      expect(frame.selectedTrack, 0);
      expect(
        frame.activeButtonMask & (1 << PedalButton.track2.index),
        isNonZero,
      );
      expect(frame.activeButtonMask & (1 << PedalButton.track1.index), 0);
      await tap(tester, r, PedalButton.track3);
      expect(r.control.state.footMixer.channel, 17);
      await tap(tester, r, PedalButton.bank);
      expect(r.control.state.footMixer.page, 0);
    } finally {
      await r.close();
    }
  });

  check(
    'domain entry searches later pages without changing normal selection',
    (tester) async {
      final r = await setup(tester, recorded: {4}, excluded: 15);
      try {
        expect(r.control.state.footMixer.channel, 4);
        r.control.selectFootMixerDomain(FootMixerDomain.inputs);
        expect(r.control.state.footMixer.channel, 4);
        r.control.selectFootMixerDomain(FootMixerDomain.tracks);
        expect(r.control.state.footMixer.channel, 4);
        expect(r.control.state.cursor, 0);
      } finally {
        await r.close();
      }
    },
  );

  check('empty Tracks still reaches Inputs', (tester) async {
    final r = await setup(tester, recorded: {});
    try {
      expect(r.control.state.footMixer.channel, isNull);
      r.press(PedalButton.bank);
      await tester.pump(const Duration(milliseconds: 801));
      expect(r.control.state.footMixer.domain, FootMixerDomain.inputs);
      r.release(PedalButton.bank);
      await tester.pump();
      expect(r.control.state.footMixer.page, 0);
    } finally {
      await r.close();
    }
  });

  check('tap gain waits release; hold resets without trailing step', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      await r.mix.setTrackVolume(.4);
      r.press(PedalButton.clear);
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], .4);
      r.release(PedalButton.clear);
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], closeTo(.45, 1e-9));
      r.press(PedalButton.undo);
      await tester.pump(const Duration(milliseconds: 801));
      r.release(PedalButton.undo);
      await tester.pump();
      expect(r.looper.mixSettingsSnapshot.trackLevels[0], 1);
    } finally {
      await r.close();
    }
  });

  check('held channel resolves the slot after Bank short page change', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.press(PedalButton.track1);
      await tester.pump(const Duration(milliseconds: 100));
      await tap(tester, r, PedalButton.bank);
      await tester.pump(const Duration(milliseconds: 700));
      expect(r.looper.trackMuted(0), isFalse);
      expect(r.looper.trackMuted(4), isTrue);
      r.release(PedalButton.track1);
      await tester.pump();
      expect(await r.settings.loadLaneMute(4, 0), isTrue);
    } finally {
      await r.close();
    }
  });

  check(
    'domain change cancels old hold and release without muting input',
    (tester) async {
      final r = await setup(tester);
      try {
        r.press(PedalButton.track1);
        await tester.pump(const Duration(milliseconds: 100));
        r.control.selectFootMixerDomain(FootMixerDomain.inputs);
        await tester.pump(const Duration(milliseconds: 900));
        r.release(PedalButton.track1);
        await tester.pump();
        expect(r.looper.monitorMuted(0), isFalse);
        expect(r.looper.trackMuted(0), isFalse);
      } finally {
        await r.close();
      }
    },
  );

  check('cancelled touch and Exit never commit delayed gain tap', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r
        ..press(PedalButton.clear)
        ..cancel(PedalButton.clear);
      await tester.pump(const Duration(milliseconds: 900));
      r
        ..release(PedalButton.clear)
        ..press(PedalButton.undo)
        ..press(PedalButton.mode)
        ..release(PedalButton.undo);
      await tester.pump();
      expect(r.control.state.mode, InteractionMode.record);
      expect(r.looper.mixSettingsSnapshot.trackLevels[0] ?? 1, 1);
    } finally {
      await r.close();
    }
  });

  check('encoder steps selected input and retains master gain', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.control.selectFootMixerDomain(FootMixerDomain.inputs);
      r.control.encoderTurned(-3);
      await tester.pump();
      expect(r.looper.monitorVolume(0), closeTo(.85, 1e-9));
      expect(r.link.lastFrame!.masterGain, 1);
    } finally {
      await r.close();
    }
  });

  check(
    'monitor native refusal reports failure; successful retry persists',
    (tester) async {
      final r = await setup(tester);
      try {
        r.control.selectFootMixerDomain(FootMixerDomain.inputs);
        r.engine.refuseMute = true;
        await r.control.toggleFootMixerMute();
        expect(r.control.state.footMixerFailure, 1);
        expect(r.looper.monitorMuted(0), isFalse);
        r.engine.refuseMute = false;
        await r.control.toggleFootMixerMute();
        expect(r.looper.monitorMuted(0), isTrue);
        expect(await r.settings.loadMonitorMute(0), isTrue);
      } finally {
        await r.close();
      }
    },
  );

  check('retired flow ignores late storage failure after reentry', (
    tester,
  ) async {
    final r = await setup(tester);
    try {
      r.control.selectFootMixerDomain(FootMixerDomain.inputs);
      r.store
        ..refuseMute = true
        ..gate = Completer<void>();
      final save = r.control.toggleFootMixerMute();
      await tester.pump();
      r.control
        ..setMode(InteractionMode.record)
        ..setMode(InteractionMode.mixer);
      r.store.gate!.complete();
      await save;
      expect(r.control.state.footMixerFailure, 0);
    } finally {
      await r.close();
    }
  });
}
