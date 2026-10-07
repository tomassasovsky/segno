import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Refuses writes of one key while [failKey] names it.
class _Store extends FakeKeyValueStore {
  String? failKey;

  @override
  Future<void> setInt(String key, int value) async {
    if (key == failKey) throw StateError('disk full');
    return super.setInt(key, value);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == failKey) throw StateError('disk full');
    return super.setString(key, value);
  }
}

class _Rig {
  _Rig({int inputs = 4, String? storedSetup, bool seed = false}) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(inputChannels: inputs);
    if (storedSetup != null) store.values['pedal.setup'] = storedSetup;
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(EngineConfig(inputChannels: inputs));
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    fade = FadeSettings(
      repository: looper,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: persistence,
      fadeSettings: fade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: fade,
      ),
      takeLocked: () => powerOffUp,
      seedTunerDefault: seed,
    );
    link.hello();
  }

  final engine = FakeAudioEngine();
  final store = _Store();
  final ticks = StreamController<void>.broadcast();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final FxChainPersistence persistence;
  late final PedalRepository pedal;
  late final PerformanceRepository performance;
  late final FadeSettings fade;
  late final ControlCubit control;

  bool powerOffUp = false;

  /// The refusal notices so far, in order.
  final refusals = <FootTunerRefusal>[];
  StreamSubscription<ControlState>? _notices;

  void watchNotices() {
    var count = control.state.footTunerFailure;
    _notices = control.stream.listen((state) {
      if (state.footTunerFailure == count) return;
      count = state.footTunerFailure;
      refusals.add(state.footTunerRefusal);
    });
  }

  Future<void> poll() async {
    ticks.add(null);
    await _pump();
  }

  Future<void> stomp(
    PedalButton button, {
    Duration hold = Duration.zero,
  }) async {
    link.press(button, down: true);
    await _pump(const Duration(milliseconds: 30) + hold);
    link.press(button, down: false);
    await _pump(const Duration(milliseconds: 30));
  }

  bool lit(PedalButton button) =>
      link.lastFrame!.activeButtonMask & (1 << button.index) != 0;

  Future<void> close() async {
    unawaited(_notices?.cancel());
    await control.close();
    await fade.close();
    await persistence.close();
    await mix.close();
    await pedal.dispose();
    performance.dispose();
    await looper.dispose();
    await ticks.close();
  }
}

Future<void> _pump([Duration duration = Duration.zero]) =>
    Future<void>.delayed(duration);

void main() {
  Future<_Rig> enter({int inputs = 4, InputSetup? setup, int? input}) async {
    final rig = _Rig(inputs: inputs);
    if (input != null) rig.store.values['tuner.input'] = input;
    await rig.control.load();
    await _pump();
    if (setup != null) rig.looper.setInputSetup(setup);
    await rig.poll();
    rig.control.setMode(InteractionMode.tuner);
    await _pump();
    rig.watchNotices();
    return rig;
  }

  test('entering mutes the source and arms the detector on it', () async {
    final rig = await enter();
    try {
      expect(rig.engine.tunerInput, 0);
      expect(rig.engine.tunerMuteMask, 0x1);
      expect(rig.control.state.footTuner.muted, isTrue);
      expect(rig.lit(PedalButton.track1), isTrue);
      expect(rig.lit(PedalButton.stop), isTrue);
      expect(rig.lit(PedalButton.mode), isTrue);
      expect(rig.lit(PedalButton.track2), isFalse);
    } finally {
      await rig.close();
    }
  });

  test('a paired source mutes both members', () async {
    final rig = await enter(
      setup: InputSetup(pairs: const {2: 0}),
      input: 3,
    );
    try {
      expect(rig.engine.tunerInput, 3);
      expect(rig.engine.tunerMuteMask, 0xC);
    } finally {
      await rig.close();
    }
  });

  test('Stop toggles the mute; the detector stays on the source', () async {
    final rig = await enter();
    try {
      await rig.stomp(PedalButton.stop);
      expect(rig.control.state.footTuner.muted, isFalse);
      expect(rig.engine.tunerMuteMask, 0);
      expect(rig.engine.tunerInput, 0);
      expect(rig.lit(PedalButton.stop), isFalse);
      await rig.stomp(PedalButton.stop);
      expect(rig.engine.tunerMuteMask, 0x1);
      expect(rig.refusals, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('a track pedal tunes its input and stores it', () async {
    final rig = await enter();
    try {
      await rig.stomp(PedalButton.track2);
      expect(rig.engine.tunerInput, 1);
      expect(rig.engine.tunerMuteMask, 0x2);
      expect(rig.control.state.tunerPreferences.input, 1);
      expect(rig.store.values['tuner.input'], 1);
      expect(rig.lit(PedalButton.track2), isTrue);
    } finally {
      await rig.close();
    }
  });

  test('Undo and Clear step the reference by 1 Hz; a hold resets it to '
      '440; a step past the range says so', () async {
    final rig = await enter();
    try {
      await rig.stomp(PedalButton.undo);
      expect(rig.control.state.tunerPreferences.referenceHz, 439);
      await rig.stomp(PedalButton.clear);
      await rig.stomp(PedalButton.clear);
      expect(rig.control.state.tunerPreferences.referenceHz, 441);
      await rig.stomp(
        PedalButton.clear,
        hold: const Duration(milliseconds: 900),
      );
      expect(rig.control.state.tunerPreferences.referenceHz, 440);
      expect(rig.refusals, isEmpty);
    } finally {
      await rig.close();
    }
    final limit = _Rig();
    try {
      limit.store.values['tuner.reference_hz'] = 460;
      await limit.control.load();
      for (var i = 0; i < 5; i++) {
        await _pump();
      }
      limit.control.setMode(InteractionMode.tuner);
      limit.watchNotices();
      await limit.stomp(PedalButton.clear);
      expect(limit.control.state.tunerPreferences.referenceHz, 460);
      expect(limit.refusals, [FootTunerRefusal.limit]);
    } finally {
      await limit.close();
    }
  });

  test('Bank pages through the inputs, tunes each page first input and '
      'wraps', () async {
    final rig = await enter(inputs: 6);
    try {
      await rig.stomp(PedalButton.bank);
      expect(rig.control.state.footTuner.page, 1);
      expect(rig.engine.tunerInput, 4);
      expect(rig.lit(PedalButton.bank), isTrue);
      await rig.stomp(PedalButton.bank);
      expect(rig.control.state.footTuner.page, 0);
      expect(rig.engine.tunerInput, 0);
    } finally {
      await rig.close();
    }
  });

  test(
    'positions past the last input and a single-page Bank are silent',
    () async {
      final rig = await enter(inputs: 2);
      try {
        await rig.stomp(PedalButton.track3);
        await rig.stomp(PedalButton.bank);
        await rig.stomp(PedalButton.recPlay);
        expect(rig.engine.tunerInput, 0);
        expect(rig.control.state.footTuner.page, 0);
        expect(rig.refusals, isEmpty);
      } finally {
        await rig.close();
      }
    },
  );

  test('MODE exits and disarms, clearing the mask', () async {
    final rig = await enter();
    try {
      await rig.stomp(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.tunerInput, -1);
      expect(rig.engine.tunerMuteMask, 0);
    } finally {
      await rig.close();
    }
  });

  test(
    'a clear-all from another surface leaves the Tuner and disarms',
    () async {
      final rig = await enter();
      try {
        // A MIDI or External clear-all reaches clearAll without setMode.
        await rig.control.clearAll();
        await _pump();
        expect(rig.control.state.mode, InteractionMode.record);
        expect(rig.engine.tunerInput, -1);
        expect(rig.engine.tunerMuteMask, 0);
      } finally {
        await rig.close();
      }
    },
  );

  test('any mode change disarms, and so does close', () async {
    final rig = await enter();
    rig.control.setMode(InteractionMode.mute);
    expect(rig.engine.tunerInput, -1);
    rig.control.setMode(InteractionMode.tuner);
    expect(rig.engine.tunerInput, 0);
    await rig.close();
    expect(rig.engine.tunerInput, -1);
    expect(rig.engine.tunerMuteMask, 0);
  });

  test(
    'a device change re-arms the new source; no tunable input disarms',
    () async {
      final rig = await enter(input: 1);
      try {
        expect(rig.engine.tunerInput, 1);
        // Input 2 becomes a loopback capture.
        rig.engine.nextSnapshot = rig.engine.nextSnapshot.copyWith(
          excludedInputMask: 0x2,
        );
        await rig.poll();
        expect(rig.engine.tunerInput, 0);
        expect(rig.engine.tunerMuteMask, 0x1);
        // The stored choice is kept for a later device.
        expect(rig.control.state.tunerPreferences.input, 1);
        rig.engine.nextSnapshot = rig.engine.nextSnapshot.copyWith(
          excludedInputMask: 0xF,
        );
        await rig.poll();
        expect(rig.engine.tunerInput, -1);
      } finally {
        await rig.close();
      }
    },
  );

  test('a refused mute says so and reads the input as audible', () async {
    final rig = _Rig();
    try {
      await rig.control.load();
      rig
        ..watchNotices()
        ..engine.refuseTunerMute = EngineResult.invalid;
      rig.control.setMode(InteractionMode.tuner);
      await _pump();
      expect(rig.refusals, [FootTunerRefusal.armFailed]);
      expect(rig.control.state.footTuner.muted, isFalse);
      // It does not retry on every poll.
      final calls = rig.engine.tunerInputCalls;
      // Fresh snapshots arrive (the rig keeps moving), and none re-arms.
      for (final xruns in [1, 2]) {
        rig.engine.nextSnapshot = rig.engine.nextSnapshot.copyWith(
          xrunCount: xruns,
        );
        await rig.poll();
      }
      expect(rig.refusals, [FootTunerRefusal.armFailed]);
      expect(rig.engine.tunerInputCalls, calls);
    } finally {
      await rig.close();
    }
  });

  test(
    'a failed preference save says so and keeps the previous value',
    () async {
      final rig = await enter();
      try {
        rig.store.failKey = 'tuner.reference_hz';
        await rig.stomp(PedalButton.clear);
        expect(rig.refusals, [FootTunerRefusal.saveFailed]);
        expect(rig.control.state.tunerPreferences.referenceHz, 440);
        rig.store.failKey = 'tuner.input';
        await rig.stomp(PedalButton.track2);
        expect(rig.refusals, [
          FootTunerRefusal.saveFailed,
          FootTunerRefusal.saveFailed,
        ]);
        // The detector went back with the stored input.
        expect(rig.engine.tunerInput, 0);
      } finally {
        await rig.close();
      }
    },
  );

  test('presses are refused while the power-off dialog is up; Exit still '
      'leaves', () async {
    final rig = await enter();
    try {
      rig.powerOffUp = true;
      await rig.stomp(PedalButton.stop);
      await rig.stomp(PedalButton.clear);
      expect(rig.control.state.footTuner.muted, isTrue);
      expect(rig.control.state.tunerPreferences.referenceHz, 440);
      rig.control.activateFootTunerPedal(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.tunerInput, -1);
    } finally {
      await rig.close();
    }
  });

  test('presses are refused while a Session load holds control', () async {
    final rig = await enter();
    try {
      rig.persistence.reserveSessionLoad();
      await rig.stomp(PedalButton.clear);
      await rig.stomp(PedalButton.stop);
      await rig.stomp(PedalButton.track2);
      expect(rig.control.state.tunerPreferences.referenceHz, 440);
      expect(rig.control.state.footTuner.muted, isTrue);
      expect(rig.engine.tunerInput, 0);
      rig.persistence.cancelSessionLoad();
      await rig.stomp(PedalButton.clear);
      expect(rig.control.state.tunerPreferences.referenceHz, 441);
    } finally {
      await rig.close();
    }
  });

  test(
    'on-screen contacts and semantic activation reach the same roles',
    () async {
      final rig = await enter();
      try {
        final contact = Object();
        rig.control.footTunerPressed(PedalButton.stop, contact);
        rig.control.footTunerReleased(PedalButton.stop, contact);
        expect(rig.control.state.footTuner.muted, isFalse);
        rig.control.activateFootTunerPedal(PedalButton.clear);
        await _pump();
        expect(rig.control.state.tunerPreferences.referenceHz, 441);
        rig.control.activateFootTunerPedal(PedalButton.clear, hold: true);
        await _pump();
        expect(rig.control.state.tunerPreferences.referenceHz, 440);
        // A cancelled hold runs nothing: its reset would put 441 back to 440.
        rig.control.activateFootTunerPedal(PedalButton.clear);
        await _pump();
        expect(rig.control.state.tunerPreferences.referenceHz, 441);
        final held = Object();
        rig.control.footTunerPressed(PedalButton.undo, held);
        await _pump(const Duration(milliseconds: 30));
        rig.control.footTunerCancelled(PedalButton.undo, held);
        await _pump(const Duration(milliseconds: 900));
        expect(rig.control.state.tunerPreferences.referenceHz, 441);
      } finally {
        await rig.close();
      }
    },
  );

  test('a cubit built without the seeding leaves the setup alone', () async {
    final rig = _Rig();
    try {
      await rig.control.load();
      for (var i = 0; i < 5; i++) {
        await _pump();
      }
      expect(rig.store.values.containsKey('pedal.setup'), isFalse);
      expect(
        rig.store.values.containsKey('pedal.tuner_default_seeded'),
        isFalse,
      );
    } finally {
      await rig.close();
    }
  });

  group('the one-shot Hold · Tuner default (#1229, D11)', () {
    const tuner = ModeAction(InteractionMode.tuner);

    Future<void> settle(_Rig rig) async {
      await rig.control.load();
      for (var i = 0; i < 5; i++) {
        await _pump();
      }
    }

    test(
      'a default install gets it on Custom pedal 2 and is told once',
      () async {
        final rig = _Rig(seed: true);
        try {
          await settle(rig);
          expect(
            rig.control.state.pedalSetup
                .customFor(PedalButton.track2, bank: 0)
                .hold,
            tuner,
          );
          expect(rig.control.state.tunerDefaultSeeded, isTrue);
          expect(rig.store.values['pedal.tuner_default_seeded'], isTrue);
          expect(
            PedalSetup.decode(
              rig.store.values['pedal.setup']! as String,
            ).customFor(PedalButton.track2, bank: 0).hold,
            tuner,
          );
        } finally {
          await rig.close();
        }
      },
    );

    test('a stored setup with an empty pedal 2 Hold gets it; an assigned '
        'one keeps it', () async {
      final empty = _Rig(
        seed: true,
        storedSetup: const PedalSetup()
            .withCustom(
              PedalButton.track2,
              bank: 0,
              pair: const ControlGesturePair(
                press: ModeAction(InteractionMode.fx),
              ),
            )
            .encode(),
      );
      try {
        await settle(empty);
        final pair = empty.control.state.pedalSetup.customFor(
          PedalButton.track2,
          bank: 0,
        );
        expect(pair.press, const ModeAction(InteractionMode.fx));
        expect(pair.hold, tuner);
      } finally {
        await empty.close();
      }
      const kept = ControlGesturePair(hold: ModeAction(InteractionMode.mixer));
      final assigned = _Rig(
        seed: true,
        storedSetup: const PedalSetup()
            .withCustom(PedalButton.track2, bank: 0, pair: kept)
            .encode(),
      );
      try {
        await settle(assigned);
        expect(
          assigned.control.state.pedalSetup.customFor(
            PedalButton.track2,
            bank: 0,
          ),
          kept,
        );
        expect(assigned.control.state.tunerDefaultSeeded, isFalse);
        expect(assigned.store.values['pedal.tuner_default_seeded'], isTrue);
      } finally {
        await assigned.close();
      }
    });

    test('removing it and rebooting does not bring it back', () async {
      final rig = _Rig(storedSetup: const PedalSetup().encode(), seed: true);
      rig.store.values['pedal.tuner_default_seeded'] = true;
      try {
        await settle(rig);
        expect(
          rig.control.state.pedalSetup
              .customFor(PedalButton.track2, bank: 0)
              .hold,
          isNull,
        );
        expect(rig.control.state.tunerDefaultSeeded, isFalse);
      } finally {
        await rig.close();
      }
    });

    test(
      'a malformed stored setup is not written, and the flag stays unset',
      () async {
        final rig = _Rig(storedSetup: '{not json', seed: true);
        try {
          await settle(rig);
          expect(rig.control.state.pedalSetupUnavailable, isTrue);
          expect(rig.store.values['pedal.setup'], '{not json');
          expect(
            rig.store.values.containsKey('pedal.tuner_default_seeded'),
            isFalse,
          );
        } finally {
          await rig.close();
        }
      },
    );
  });
}
