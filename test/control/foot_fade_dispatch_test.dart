import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno_engine/segno_engine.dart'
    show FadeAdmission, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Accepts every toggle and records exactly what Control asked for.
class _Engine extends FakeAudioEngine {
  final toggles = <(int, double)>[];
  final _results = <int, EngineResult>{};
  var _request = 0;
  bool refuse = false;

  @override
  FadeAdmission toggleFade({required int channel, required double seconds}) {
    if (refuse) return (result: EngineResult.invalid, request: 0);
    toggles.add((channel, seconds));
    final request = ++_request;
    _results[request] = EngineResult.ok;
    return (result: EngineResult.ok, request: request);
  }

  @override
  EngineResult? readFadeResult(int request) =>
      _results.remove(request) ?? super.readFadeResult(request);
}

const _holdThreshold = Duration(milliseconds: 820);

TrackSnapshot _recorded({FadeImage fade = const FadeImage()}) => TrackSnapshot(
  state: TrackState.playing,
  volume: 1,
  muted: false,
  lengthFrames: 48000,
  undoDepth: 0,
  rms: 0,
  peak: 0,
  fade: fade,
);

/// Publishes recorded tracks [recorded], with [faded] ones at zero.
void _publish(
  _Engine engine, {
  required Set<int> recorded,
  Set<int> faded = const {},
}) => engine.nextSnapshot = engine.nextSnapshot.copyWith(
  tracks: [
    for (var channel = 0; channel < 8; channel++)
      if (recorded.contains(channel))
        _recorded(
          fade: faded.contains(channel)
              ? const FadeImage(amount: 0, target: 0)
              : const FadeImage(),
        )
      else
        const TrackSnapshot.empty(),
  ],
);

class _Rig {
  _Rig({Set<int> recorded = const {0, 1, 4}}) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
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
    );
    link.hello();
  }

  final engine = _Engine();
  final store = FakeKeyValueStore();
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

  final _contacts = <PedalButton, Object>{};
  void press(PedalButton button) {
    final contact = Object();
    _contacts[button] = contact;
    control.footFadePressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footFadeReleased(button, contact);
  }

  /// The stored record, decoded independently of FadeSettings.
  Future<FadeDurations?> stored() async {
    final record = await settings.readFadeDurationsCheckpoint();
    return record == null ? null : FadeDurations.fromJson(jsonDecode(record));
  }

  Future<void> close() async {
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
  Future<_Rig> enter({Set<int> recorded = const {0, 1, 4}}) async {
    final rig = _Rig(recorded: recorded);
    await rig.fade.load();
    rig.control.setMode(InteractionMode.fade);
    await _pump();
    return rig;
  }

  Future<void> tap(_Rig rig, PedalButton button) async {
    rig.press(button);
    await _pump(const Duration(milliseconds: 50));
    rig.release(button);
    await _pump();
  }

  Future<void> hold(_Rig rig, PedalButton button) async {
    rig.press(button);
    await _pump(_holdThreshold);
    rig.release(button);
    await _pump();
  }

  test('entry selects the shared Default', () async {
    final rig = await enter();
    try {
      expect(rig.control.state.mode, InteractionMode.fade);
      expect(rig.control.state.footFade, const FootFadeSelection());
    } finally {
      await rig.close();
    }
  });

  test('a track tap fades on release at the effective duration', () async {
    final rig = await enter();
    try {
      rig.press(PedalButton.track1);
      await _pump(const Duration(milliseconds: 50));
      expect(rig.engine.toggles, isEmpty, reason: 'nothing at contact');
      rig.release(PedalButton.track1);
      await _pump();
      expect(rig.engine.toggles, [(0, 4.0)]);
    } finally {
      await rig.close();
    }
  });

  test('a track hold selects its time and never fades', () async {
    final rig = await enter();
    try {
      await hold(rig, PedalButton.track2);
      expect(rig.engine.toggles, isEmpty);
      expect(
        rig.control.state.footFade,
        const FootFadeSelection(timeChannel: 1),
      );
    } finally {
      await rig.close();
    }
  });

  test('a pending track hold follows a bank change until it fires', () async {
    final rig = await enter();
    try {
      rig.press(PedalButton.track1);
      await _pump(const Duration(milliseconds: 100));
      await tap(rig, PedalButton.bank);
      expect(rig.control.state.activeBank, 1);
      await _pump(_holdThreshold);
      rig.release(PedalButton.track1);
      await _pump();
      // Slot 0 of bank B is track 5 (channel 4), resolved at activation.
      expect(
        rig.control.state.footFade,
        const FootFadeSelection(timeChannel: 4),
      );
      expect(rig.engine.toggles, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('editing an inherited track time creates its override only', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.undo); // Default 4.0 -> 3.5
      await _pump();
      expect(await rig.stored(), FadeDurations(defaultMs: 3500));
      await hold(rig, PedalButton.track1); // select track 1's time
      await tap(rig, PedalButton.clear); // inherited 3.5 -> override 4.0
      await _pump();
      expect(
        await rig.stored(),
        FadeDurations(defaultMs: 3500, overrides: const {0: 4000}),
      );
      await tap(rig, PedalButton.track1);
      expect(rig.engine.toggles.last, (0, 4.0));
      await tap(rig, PedalButton.track2);
      expect(rig.engine.toggles.last, (1, 3.5));
    } finally {
      await rig.close();
    }
  });

  // Each test stays well under the fake link's status timeout, which
  // legitimately cancels open gestures.
  test('holding Undo makes a track inherit Default again', () async {
    final rig = await enter();
    try {
      await hold(rig, PedalButton.track1);
      await tap(rig, PedalButton.clear);
      await _pump();
      expect(
        await rig.stored(),
        FadeDurations(overrides: const {0: 4500}),
      );
      await hold(rig, PedalButton.undo);
      await _pump();
      expect(await rig.stored(), FadeDurations());
      expect(
        rig.control.state.footFade,
        const FootFadeSelection(timeChannel: 0),
      );
    } finally {
      await rig.close();
    }
  });

  test('holding Bank selects Default and holding Clear resets it', () async {
    final rig = await enter();
    try {
      await hold(rig, PedalButton.track1);
      await hold(rig, PedalButton.bank);
      expect(rig.control.state.footFade, const FootFadeSelection());
      await rig.fade.setDefault(6000);
      await hold(rig, PedalButton.clear);
      await _pump();
      expect(await rig.stored(), FadeDurations());
    } finally {
      await rig.close();
    }
  });

  test('rapid steps queued behind a pending write each count', () async {
    final rig = await enter();
    try {
      await Future.wait([
        rig.control.stepFootFadeTime(1),
        rig.control.stepFootFadeTime(1),
      ]);
      expect(await rig.stored(), FadeDurations(defaultMs: 5000));
    } finally {
      await rig.close();
    }
  });

  test('Fade mode lights faded track switches only', () async {
    final rig = await enter();
    try {
      _publish(rig.engine, recorded: {0, 1, 4}, faded: {1});
      rig.ticks.add(null);
      await _pump();
      final mask = rig.link.lastFrame!.activeButtonMask;
      expect(mask & (1 << PedalButton.track2.index), isNonZero);
      expect(mask & (1 << PedalButton.track1.index), 0);
    } finally {
      await rig.close();
    }
  });

  test('an edge step changes nothing', () async {
    final rig = await enter();
    try {
      await rig.fade.setDefault(FootFadeProjection.minimumMs);
      await tap(rig, PedalButton.undo);
      await _pump();
      expect(await rig.stored(), FadeDurations(defaultMs: 500));
    } finally {
      await rig.close();
    }
  });

  test('an empty track is unavailable, not a failure', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track3); // channel 2 is empty
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footFadeFailure, 0);
    } finally {
      await rig.close();
    }
  });

  test('an engine refusal is reported once', () async {
    final rig = await enter();
    try {
      rig.engine.refuse = true;
      await tap(rig, PedalButton.track1);
      await _pump();
      expect(rig.control.state.footFadeFailure, 1);
    } finally {
      await rig.close();
    }
  });

  test('physical Mode exits with fades left running', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track1);
      rig.link.press(PedalButton.mode, down: true);
      await _pump();
      rig.link.press(PedalButton.mode, down: false);
      await _pump();
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.toggles, [(0, 4.0)], reason: 'Exit adds no toggle');
    } finally {
      await rig.close();
    }
  });

  test('an assigned all-tracks Fade toggles every recorded track', () async {
    final rig = _Rig();
    try {
      await rig.fade.load();
      await rig.control.setPedalSetup(
        const PedalSetup().withCustom(
          PedalButton.clear,
          bank: 0,
          pair: const ControlGesturePair(
            press: TrackOperationAction(
              operation: TrackOperation.fade,
              scope: AllTracksScope(),
            ),
          ),
        ),
      );
      rig.control.setMode(InteractionMode.custom);
      rig.link.press(PedalButton.clear, down: true);
      await _pump(const Duration(milliseconds: 50));
      rig.link.press(PedalButton.clear, down: false);
      await _pump();
      expect(
        rig.engine.toggles.map((toggle) => toggle.$1).toSet(),
        {0, 1, 4},
      );
      // The assignment reports active once every RECORDED track is faded;
      // empty tracks 2, 3, 5, 6 and 7 cannot fade and must not block it.
      _publish(rig.engine, recorded: {0, 1, 4}, faded: {0, 1, 4});
      rig.ticks.add(null);
      await _pump();
      expect(
        rig.link.lastFrame!.activeButtonMask & (1 << PedalButton.clear.index),
        isNonZero,
      );
    } finally {
      await rig.close();
    }
  });
}
