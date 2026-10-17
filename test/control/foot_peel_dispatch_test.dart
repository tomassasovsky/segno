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
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show PendingLaunchAction, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Peels layers and publishes the depths like the engine does.
class _Engine extends FakeAudioEngine {
  _Engine(this.layers);

  /// Peelable overdub layers per recorded channel; absent = empty track.
  final Map<int, int> layers;
  final peels = <int>[];
  final records = <int>[];

  /// Tracks published as overdubbing.
  final overdubbing = <int>{};

  /// Tracks published with a layer still draining.
  final draining = <int>{};

  /// Tracks published waiting for a Count-in launch.
  final launching = <int>{};

  /// A refusal the engine returns instead of peeling.
  EngineResult? refuse;

  void publish() => nextSnapshot = nextSnapshot.copyWith(
    tracks: [
      for (var channel = 0; channel < 8; channel++)
        if (layers.containsKey(channel))
          TrackSnapshot(
            state: overdubbing.contains(channel)
                ? TrackState.overdubbing
                : TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: layers[channel]!,
            peelDepth: layers[channel]!,
            layerInFlight: draining.contains(channel),
            pendingLaunch: launching.contains(channel)
                ? PendingLaunchAction.play
                : null,
            rms: 0,
            peak: 0,
          )
        else
          const TrackSnapshot.empty(),
    ],
  );

  @override
  EngineResult peel({int channel = 0}) {
    final refused = refuse;
    if (refused != null) return refused;
    peels.add(channel);
    layers[channel] = layers[channel]! - 1;
    publish();
    return EngineResult.ok;
  }

  @override
  EngineResult record({int channel = 0}) {
    records.add(channel);
    return super.record(channel: channel);
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('test-midi', 1);
  @override
  Stream<MidiInputMessage> get messages => inputs.stream;
  void push(int id, int value) => inputs.add(
    MidiInputMessage(
      session,
      RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: id,
        value: value,
      ),
    ),
  );
  @override
  Future<void> dispose() async {
    await inputs.close();
    await super.dispose();
  }
}

/// Channel 0 has two layers to peel, 1 has one, 2 is empty, 3 holds only
/// its original, 4 has one.
Map<int, int> _defaultLayers() => {0: 2, 1: 1, 3: 0, 4: 1};

class _Rig {
  _Rig({Map<int, int>? layers, ExternalJackSetup? jack})
    : engine = _Engine(layers ?? _defaultLayers()) {
    engine.publish();
    if (jack != null) {
      store.values['pedal.setup'] = const PedalSetup()
          .copyWith(
            external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: jack}),
          )
          .encode();
    }
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    midi = _Midi(settings);
    controller = ControllerRepository(sources: [ConsoleCtrlSource(pedal)]);
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
      controller: controller,
      midiDevices: midi,
      takeLocked: () => powerOffUp,
    );
    link.hello();
  }

  final _Engine engine;
  final store = FakeKeyValueStore();
  final ticks = StreamController<void>.broadcast();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final FxChainPersistence persistence;
  late final PedalRepository pedal;
  late final _Midi midi;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final FadeSettings fade;
  late final ControlCubit control;

  /// The power-off route is up: takes and performance actions are locked.
  bool powerOffUp = false;

  final _contacts = <PedalButton, Object>{};
  void press(PedalButton button) {
    final contact = Object();
    _contacts[button] = contact;
    control.footPeelPressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footPeelReleased(button, contact);
  }

  /// Lets the repository poll the published snapshot.
  Future<void> poll() async {
    ticks.add(null);
    await _pump();
  }

  /// The refusal notices emitted so far, in order.
  final refusals = <FootPeelRefusal>[];
  StreamSubscription<ControlState>? _notices;

  void watchNotices() {
    var count = control.state.footPeelFailure;
    _notices = control.stream.listen((state) {
      if (state.footPeelFailure == count) return;
      count = state.footPeelFailure;
      refusals.add(state.footPeelRefusal);
    });
  }

  bool lit(PedalButton button) =>
      link.lastFrame!.activeButtonMask & (1 << button.index) != 0;

  Future<void> close() async {
    unawaited(_notices?.cancel());
    await control.close();
    await fade.close();
    await persistence.close();
    await mix.close();
    await controller.dispose();
    await midi.dispose();
    await pedal.dispose();
    performance.dispose();
    await looper.dispose();
    await ticks.close();
  }
}

Future<void> _pump([Duration duration = Duration.zero]) =>
    Future<void>.delayed(duration);

void main() {
  Future<_Rig> enter({Map<int, int>? layers}) async {
    final rig = _Rig(layers: layers);
    await rig.poll();
    rig.control.setMode(InteractionMode.peel);
    await _pump();
    rig.watchNotices();
    return rig;
  }

  Future<void> tap(_Rig rig, PedalButton button) async {
    rig.press(button);
    await _pump(const Duration(milliseconds: 50));
    rig.release(button);
    await _pump();
  }

  test('a track pedal peels its track on contact', () async {
    final rig = await enter();
    try {
      expect(rig.looper.state.tracks[0].layers, 3);
      rig.press(PedalButton.track1);
      await _pump();
      expect(rig.engine.peels, [0], reason: 'the peel fires at contact');
      rig.release(PedalButton.track1);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.peels, [0], reason: 'the release adds nothing');
      await rig.poll();
      expect(rig.looper.state.tracks[0].layers, 2);
      expect(rig.refusals, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('track pedals follow the bank', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.bank);
      expect(rig.control.state.activeBank, 1);
      await tap(rig, PedalButton.track1);
      // Slot 0 of bank B is track 5 (channel 4).
      expect(rig.engine.peels, [4]);
    } finally {
      await rig.close();
    }
  });

  test('a release from a contact admitted before Exit does nothing', () async {
    final rig = await enter();
    try {
      rig.press(PedalButton.track1);
      await _pump();
      rig.control.setMode(InteractionMode.record);
      await _pump();
      rig.control.setMode(InteractionMode.peel);
      await _pump();
      rig.release(PedalButton.track1);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.peels, [0]);
    } finally {
      await rig.close();
    }
  });

  test('a Peel is refused while the power-off dialog is up', () async {
    final rig = await enter();
    try {
      rig.powerOffUp = true;
      await tap(rig, PedalButton.track1);
      rig.control
        ..peelFootPeelTrack(0)
        ..activateFootPeelPedal(PedalButton.track2);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.peels, isEmpty);
      expect(rig.refusals, isEmpty, reason: 'the dialog owns the screen');
      rig.powerOffUp = false;
      await tap(rig, PedalButton.track1);
      expect(rig.engine.peels, [0]);
    } finally {
      await rig.close();
    }
  });

  test('semantic Rec/Play, Stop and Bank do nothing under the power-off '
      'dialog', () async {
    final rig = await enter();
    try {
      final stops = rig.engine.stopTrackCalls;
      final plays = rig.engine.playCalls;
      rig.powerOffUp = true;
      [
        PedalButton.recPlay,
        PedalButton.stop,
        PedalButton.bank,
      ].forEach(rig.control.activateFootPeelPedal);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.records, isEmpty, reason: 'no take starts');
      expect(rig.engine.stopTrackCalls, stops);
      expect(rig.engine.playCalls, plays);
      expect(rig.control.state.activeBank, 0);
      expect(rig.control.state.mode, InteractionMode.peel);
    } finally {
      await rig.close();
    }
  });

  test('a retired input ignores the surface', () async {
    final rig = await enter();
    try {
      rig.control.retireInput();
      rig.control
        ..activateFootPeelPedal(PedalButton.recPlay)
        ..activateFootPeelPedal(PedalButton.track1)
        ..peelFootPeelTrack(0);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.records, isEmpty);
      expect(rig.engine.peelCalls, 0);
      expect(rig.refusals, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('a Peel is refused while a Session load holds control', () async {
    final rig = await enter();
    try {
      rig.persistence.reserveSessionLoad();
      await tap(rig, PedalButton.track1);
      rig.control.activateFootPeelPedal(PedalButton.track1);
      expect(rig.engine.peels, isEmpty);
      rig.persistence.cancelSessionLoad();
      await tap(rig, PedalButton.track1);
      expect(rig.engine.peels, [0]);
    } finally {
      await rig.close();
    }
  });

  test('a track tile tap is inert in Peel mode', () async {
    final rig = await enter();
    try {
      rig.control.trackPressed(0);
      await _pump();
      expect(rig.engine.peels, isEmpty);
      expect(rig.engine.records, isEmpty);
      expect(rig.refusals, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('Undo and Clear are inert and leave the transport alone', () async {
    final rig = await enter();
    try {
      final stops = rig.engine.stopTrackCalls;
      await tap(rig, PedalButton.undo);
      await tap(rig, PedalButton.clear);
      expect(rig.engine.undoCalls, 0);
      expect(rig.engine.clearCalls, 0);
      expect(rig.engine.peels, isEmpty);
      expect(rig.engine.records, isEmpty);
      expect(rig.engine.stopTrackCalls, stops);
      expect(rig.refusals, isEmpty);
      expect(rig.control.state.mode, InteractionMode.peel);
      expect(rig.lit(PedalButton.undo), isFalse);
    } finally {
      await rig.close();
    }
  });

  group('a refused press on a recorded track says why', () {
    test('an empty track is silent, as on Fade and Reverse', () async {
      final rig = await enter();
      try {
        await tap(rig, PedalButton.track3); // channel 2 is empty
        rig.control.activateFootPeelPedal(PedalButton.track3);
        expect(rig.engine.peelCalls, 0);
        expect(rig.refusals, isEmpty);
      } finally {
        await rig.close();
      }
    });

    test('a track that holds only its original', () async {
      final rig = await enter();
      try {
        await tap(rig, PedalButton.track4); // channel 3
        expect(rig.engine.peelCalls, 0);
        expect(rig.refusals, [FootPeelRefusal.originalOnly]);
        // Peeling the last layer leaves the original; the next press says so.
        await tap(rig, PedalButton.track2); // channel 1, one layer
        await rig.poll();
        await tap(rig, PedalButton.track2);
        expect(rig.engine.peels, [1]);
        expect(rig.refusals, [
          FootPeelRefusal.originalOnly,
          FootPeelRefusal.originalOnly,
        ]);
      } finally {
        await rig.close();
      }
    });

    test('a track that overdubs, drains a layer or waits to launch', () async {
      final rig = await enter();
      try {
        rig.engine
          ..overdubbing.add(0)
          ..draining.add(1)
          ..launching.add(4)
          ..publish();
        await rig.poll();
        await tap(rig, PedalButton.track1);
        await tap(rig, PedalButton.track2);
        await tap(rig, PedalButton.bank);
        await tap(rig, PedalButton.track1);
        expect(rig.engine.peelCalls, 0);
        expect(rig.refusals, [
          FootPeelRefusal.busy,
          FootPeelRefusal.busy,
          FootPeelRefusal.busy,
        ]);
      } finally {
        await rig.close();
      }
    });

    test('an engine refusal', () async {
      final rig = await enter();
      try {
        for (final result in [
          EngineResult.notReady,
          EngineResult.invalid,
          EngineResult.notRunning,
        ]) {
          rig.engine.refuse = result;
          await tap(rig, PedalButton.track1);
        }
        expect(rig.engine.peels, isEmpty);
        expect(rig.refusals, [
          FootPeelRefusal.busy,
          FootPeelRefusal.originalOnly,
          FootPeelRefusal.failed,
        ]);
      } finally {
        await rig.close();
      }
    });
  });

  test('Exit returns to Tracks, keeps the peeled layers, and works while '
      'the surface is locked', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track1);
      // A Session load locks the surface; Exit still leaves it.
      rig.persistence.reserveSessionLoad();
      rig.link.press(PedalButton.mode, down: true);
      await _pump();
      rig.link.press(PedalButton.mode, down: false);
      await rig.poll();
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.peels, [0], reason: 'Exit adds no peel');
      expect(rig.looper.state.tracks[0].layers, 2);
      rig.persistence.cancelSessionLoad();
    } finally {
      await rig.close();
    }
  });

  test('the on-screen Exit leaves while the surface is locked', () async {
    final rig = await enter();
    try {
      rig.persistence.reserveSessionLoad();
      rig.control.activateFootPeelPedal(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      rig.persistence.cancelSessionLoad();
    } finally {
      await rig.close();
    }
  });

  test('the mode toggle returns to Record', () async {
    final rig = await enter();
    try {
      rig.control.toggleMode();
      expect(rig.control.state.mode, InteractionMode.record);
    } finally {
      await rig.close();
    }
  });

  test('Record / Play advances recording on the cursor track', () async {
    final rig = await enter();
    try {
      rig.control.selectTrack(1);
      await tap(rig, PedalButton.recPlay);
      expect(rig.engine.records, [1]);
      expect(rig.engine.peels, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('a track switch lights only while a press would peel', () async {
    final rig = await enter();
    try {
      await rig.poll();
      expect(rig.lit(PedalButton.track1), isTrue, reason: 'two layers');
      expect(rig.lit(PedalButton.track2), isTrue, reason: 'one layer');
      expect(rig.lit(PedalButton.track3), isFalse, reason: 'empty');
      expect(rig.lit(PedalButton.track4), isFalse, reason: 'original only');
      rig.engine
        ..overdubbing.add(0)
        ..publish();
      await rig.poll();
      expect(rig.lit(PedalButton.track1), isFalse, reason: 'overdubbing');
      await tap(rig, PedalButton.track2);
      await rig.poll();
      expect(rig.lit(PedalButton.track2), isFalse, reason: 'none remain');
    } finally {
      await rig.close();
    }
  });

  group('assigned Peel actions reach the same adapter', () {
    const selected = TrackOperationAction(
      operation: TrackOperation.peel,
      scope: SelectedTrackScope(),
    );
    const fixed = TrackOperationAction(
      operation: TrackOperation.peel,
      scope: FixedTrackScope(4),
    );

    test('All tracks is not offered', () {
      expect(TrackOperation.peel.allowsAllTracks, isFalse);
      expect(
        ControlAction.tryParse(
          const TrackOperationAction(
            operation: TrackOperation.peel,
            scope: AllTracksScope(),
          ).key,
        ),
        isNull,
      );
    });

    test(
      'a Custom pedal: selected and fixed, and a refusal says why',
      () async {
        final rig = _Rig();
        try {
          await rig.poll();
          await rig.control.setPedalSetup(
            const PedalSetup()
                .withCustom(
                  PedalButton.clear,
                  bank: 0,
                  pair: const ControlGesturePair(press: selected),
                )
                .withCustom(
                  PedalButton.undo,
                  bank: 0,
                  pair: const ControlGesturePair(press: fixed),
                ),
          );
          rig.control
            ..selectTrack(1)
            ..setMode(InteractionMode.custom);
          rig.watchNotices();
          Future<void> stomp(PedalButton button) async {
            rig.link.press(button, down: true);
            await _pump(const Duration(milliseconds: 50));
            rig.link.press(button, down: false);
            await _pump(const Duration(milliseconds: 30));
            await rig.poll();
          }

          await stomp(PedalButton.clear);
          await stomp(PedalButton.undo);
          expect(rig.engine.peels, [1, 4]);
          expect(rig.refusals, isEmpty);
          // Both now hold only their original: the next stomp says so.
          await stomp(PedalButton.clear);
          expect(rig.engine.peels, [1, 4]);
          expect(rig.refusals, [FootPeelRefusal.originalOnly]);
          // An assigned Peel on an empty track says so too: the stomp came
          // from elsewhere, so a silent refusal would read as a dead pedal.
          rig.control.selectTrack(2);
          await stomp(PedalButton.clear);
          expect(rig.refusals, [
            FootPeelRefusal.originalOnly,
            FootPeelRefusal.empty,
          ]);
        } finally {
          await rig.close();
        }
      },
    );

    test('a CTRL switch', () async {
      final rig = _Rig(
        jack: const ExternalJackSetup(
          single: ExternalSwitchSetup(
            gestures: ControlGesturePair(press: fixed),
          ),
        ),
      );
      try {
        await rig.control.load();
        await rig.poll();
        for (final value in [0, 255]) {
          rig.link.emit(
            CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.switchPedal,
              value: value,
            ),
          );
          await _pump(const Duration(milliseconds: 30));
        }
        expect(rig.engine.peels, [4]);
      } finally {
        await rig.close();
      }
    });

    test('a CTRL switch is refused while the power-off dialog is up', () async {
      final rig = _Rig(
        jack: const ExternalJackSetup(
          single: ExternalSwitchSetup(
            gestures: ControlGesturePair(press: fixed),
          ),
        ),
      );
      try {
        await rig.control.load();
        await rig.poll();
        rig.powerOffUp = true;
        for (final value in [0, 255]) {
          rig.link.emit(
            CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.switchPedal,
              value: value,
            ),
          );
          await _pump(const Duration(milliseconds: 30));
        }
        expect(rig.engine.peels, isEmpty);
      } finally {
        await rig.close();
      }
    });

    test('a MIDI action', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await rig.poll();
        final owner = Object();
        rig.control.beginMidiEdit(device: 'test-midi', owner: owner);
        final saved = await rig.control.saveMidiMapping(
          MidiMapping(
            id: 'draft',
            source: MidiSource(
              device: 'test-midi',
              kind: ControllerSourceKind.midiCc,
              number: 21,
            ),
            behavior: MidiBehavior.momentary,
            controls: [MidiActionControl(key: fixed.key)],
          ),
          owner: owner,
          create: true,
        );
        expect(saved.saved, isTrue);
        rig.control.endMidiEdit(owner);
        rig.midi.push(21, 127);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.peels, [4]);
      } finally {
        await rig.close();
      }
    });
  });
}
