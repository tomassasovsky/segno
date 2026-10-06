import 'dart:async';
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
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// The Pending Hold cue's state (#1229 Part 1): which pedals have a hold
/// armed and not yet settled, published by the one gesture interpreter.
class _Rig {
  _Rig({int longPressMs = 300}) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      tracks: [
        for (var channel = 0; channel < 8; channel++)
          if (channel < 2)
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
    unawaited(store.setInt('pedal.long_press_ms', longPressMs));
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

  final engine = FakeAudioEngine();
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
    if (control.state.mode == InteractionMode.mixer) {
      control.footMixerPressed(button, contact);
    } else {
      control.footFadePressed(button, contact);
    }
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact == null) return;
    if (control.state.mode == InteractionMode.mixer) {
      control.footMixerReleased(button, contact);
    } else {
      control.footFadeReleased(button, contact);
    }
  }

  Set<PedalButton> get pending => control.state.pendingHolds;

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
  Future<_Rig> enter(InteractionMode mode) async {
    final rig = _Rig();
    await rig.fade.load();
    await rig.control.load();
    rig.control.setMode(mode);
    await _pump();
    expect(rig.control.state.mode, mode);
    return rig;
  }

  test('the loaded threshold is published', () async {
    final rig = await enter(InteractionMode.fade);
    addTearDown(rig.close);
    expect(rig.control.state.holdThreshold, const Duration(milliseconds: 300));
  });

  test('a release before the threshold ends the pending hold', () async {
    final rig = await enter(InteractionMode.fade);
    addTearDown(rig.close);
    expect(rig.pending, isEmpty);

    rig.press(PedalButton.track1);
    expect(rig.pending, {PedalButton.track1});

    await _pump(const Duration(milliseconds: 50));
    rig.release(PedalButton.track1);
    expect(rig.pending, isEmpty);
  });

  test('the hold firing ends the pending hold before the release', () async {
    final rig = await enter(InteractionMode.fade);
    addTearDown(rig.close);
    rig.press(PedalButton.track2);
    expect(rig.pending, {PedalButton.track2});

    await _pump(const Duration(milliseconds: 360));
    expect(rig.pending, isEmpty);
    // A Fade track hold selects that track's time.
    expect(rig.control.state.footFade.timeChannel, 1);
    rig.release(PedalButton.track2);
    expect(rig.pending, isEmpty);
  });

  test('two pedals can be pending at once and settle apart', () async {
    final rig = await enter(InteractionMode.fade);
    addTearDown(rig.close);
    rig
      ..press(PedalButton.track1)
      ..press(PedalButton.undo);
    expect(rig.pending, {PedalButton.track1, PedalButton.undo});
    rig.release(PedalButton.track1);
    expect(rig.pending, {PedalButton.undo});
    rig.release(PedalButton.undo);
    expect(rig.pending, isEmpty);
  });

  test('a mode change cancels the pending hold', () async {
    final rig = await enter(InteractionMode.fade);
    addTearDown(rig.close);
    rig.press(PedalButton.track1);
    expect(rig.pending, {PedalButton.track1});

    rig.control.setMode(InteractionMode.record);
    expect(rig.pending, isEmpty);
    // Nothing fires later from the cancelled gesture.
    await _pump(const Duration(milliseconds: 360));
    expect(rig.pending, isEmpty);
    expect(rig.control.state.footFade.timeChannel, isNull);
  });

  test('a Mixer Undo hold is pending until it resets', () async {
    final rig = await enter(InteractionMode.mixer);
    addTearDown(rig.close);
    rig.press(PedalButton.undo);
    expect(rig.pending, {PedalButton.undo});
    await _pump(const Duration(milliseconds: 360));
    expect(rig.pending, isEmpty);
    rig.release(PedalButton.undo);
  });

  test('a Mixer domain switch cancels its pending holds', () async {
    final rig = await enter(InteractionMode.mixer);
    addTearDown(rig.close);
    rig.press(PedalButton.clear);
    expect(rig.pending, {PedalButton.clear});

    rig.control.selectFootMixerDomain(FootMixerDomain.inputs);
    expect(rig.pending, isEmpty);
  });

  test('an immediate role never shows the cue', () async {
    final rig = await enter(InteractionMode.mixer);
    addTearDown(rig.close);
    // MODE exits on contact: no hold to wait for.
    rig.press(PedalButton.mode);
    expect(rig.pending, isEmpty);
    expect(rig.control.state.mode, InteractionMode.record);
  });

  for (final mode in [InteractionMode.record, InteractionMode.mute]) {
    test('a ${mode.name}-mode stomp publishes no cue: those modes draw no '
        'pedals, so the Tracks screen does not rebuild for it', () async {
      final rig = await enter(mode);
      addTearDown(rig.close);
      final emitted = <ControlState>[];
      final sub = rig.control.stream.listen(emitted.add);
      addTearDown(sub.cancel);
      // Undo and Bank arm holds in every mode (Undo's Redo, Bank's
      // performance recording).
      for (final button in [PedalButton.undo, PedalButton.bank]) {
        rig.link.press(button, down: true);
        await _pump();
        expect(rig.pending, isEmpty);
        rig.link.press(button, down: false);
        await _pump();
      }
      expect(emitted.where((s) => s.pendingHolds.isNotEmpty), isEmpty);
    });
  }

  test('closing retires a pending hold and emits nothing after', () async {
    final rig = await enter(InteractionMode.fade);
    final emitted = <ControlState>[];
    final sub = rig.control.stream.listen(emitted.add);
    rig.press(PedalButton.track1);
    expect(rig.pending, {PedalButton.track1});

    // Retiring input (the first step of close) cancels the gesture while the
    // cubit is still open, so the cue clears; nothing later may emit.
    await rig.close();
    await _pump();
    await sub.cancel();
    expect(rig.pending, isEmpty);
    expect(emitted.last.pendingHolds, isEmpty);
    expect(rig.control.isClosed, isTrue);
  });
}
