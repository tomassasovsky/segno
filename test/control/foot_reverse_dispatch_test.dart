import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show RequestAdmission, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Turns tracks around and publishes the direction like the callback does.
class _Engine extends FakeAudioEngine {
  _Engine(this.recorded);

  final Set<int> recorded;
  final reversedTracks = <int>{};

  /// Recorded tracks writing an overdub pass, or with an arm pending.
  final overdubbing = <int>{};
  final pendingTracks = <int>{};
  final toggles = <int>[];
  final records = <int>[];
  final _results = <int, EngineResult>{};
  var _request = 0;
  bool refuse = false;

  void publish() => nextSnapshot = nextSnapshot.copyWith(
    tracks: [
      for (var channel = 0; channel < 8; channel++)
        if (recorded.contains(channel))
          TrackSnapshot(
            state: overdubbing.contains(channel)
                ? TrackState.overdubbing
                : TrackState.playing,
            pending: pendingTracks.contains(channel),
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            reversed: reversedTracks.contains(channel),
          )
        else
          const TrackSnapshot.empty(),
    ],
  );

  @override
  RequestAdmission toggleReverse({required int channel}) {
    if (refuse) return (result: EngineResult.invalid, request: 0);
    toggles.add(channel);
    if (!reversedTracks.remove(channel)) reversedTracks.add(channel);
    publish();
    final request = ++_request;
    _results[request] = EngineResult.ok;
    return (result: EngineResult.ok, request: request);
  }

  @override
  EngineResult? readRequestResult(int request) =>
      _results.remove(request) ?? super.readRequestResult(request);

  /// A punch-in on a reversed track is refused, as the engine refuses it.
  @override
  EngineResult record({int channel = 0}) {
    records.add(channel);
    if (reversedTracks.contains(channel)) return EngineResult.reversed;
    return super.record(channel: channel);
  }
}

/// A repository whose Session revision a test can move mid-toggle, the way
/// a Session load does.
class _Looper extends LooperRepository {
  _Looper({required super.engine, required super.ticker});

  int? revision;

  @override
  int get sessionRevision => revision ?? super.sessionRevision;
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

class _Rig {
  _Rig({Set<int> recorded = const {0, 1, 4}, ExternalJackSetup? jack})
    : engine = _Engine(recorded) {
    engine.publish();
    if (jack != null) {
      store.values['pedal.setup'] = const PedalSetup()
          .copyWith(
            external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: jack}),
          )
          .encode();
    }
    looper = _Looper(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    midi = _Midi(settings);
    controller = ControllerRepository(sources: [ConsoleCtrlSource(pedal)]);
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
  late final _Looper looper;
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
    control.footReversePressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footReverseReleased(button, contact);
  }

  /// Lets the repository poll the published snapshot.
  Future<void> poll() async {
    ticks.add(null);
    await _pump();
  }

  Future<void> close() async {
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
  Future<_Rig> enter({Set<int> recorded = const {0, 1, 4}}) async {
    final rig = _Rig(recorded: recorded);
    await rig.poll();
    rig.control.setMode(InteractionMode.reverse);
    await _pump();
    return rig;
  }

  Future<void> tap(_Rig rig, PedalButton button) async {
    rig.press(button);
    await _pump(const Duration(milliseconds: 50));
    rig.release(button);
    await _pump();
  }

  test('a track pedal turns its track around on contact', () async {
    final rig = await enter();
    try {
      rig.press(PedalButton.track2);
      await _pump();
      expect(rig.engine.toggles, [1], reason: 'the toggle fires at contact');
      rig.release(PedalButton.track2);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.toggles, [1], reason: 'the release adds nothing');
      await rig.poll();
      expect(rig.looper.state.tracks[1].reversed, isTrue);
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
      expect(rig.engine.toggles, [4]);
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
      rig.control.setMode(InteractionMode.reverse);
      await _pump();
      rig.release(PedalButton.track1);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.toggles, [0]);
    } finally {
      await rig.close();
    }
  });

  test(
    'a Reverse toggle is refused while the power-off dialog is up',
    () async {
      final rig = await enter();
      try {
        rig.powerOffUp = true;
        await tap(rig, PedalButton.track1);
        rig.control.trackPressed(1);
        await rig.control.toggleFootReverseTrack(0);
        rig.control.activateFootReversePedal(PedalButton.track2);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.toggles, isEmpty);
        expect(rig.control.state.footReverseFailure, 0);
        rig.powerOffUp = false;
        await tap(rig, PedalButton.track1);
        expect(rig.engine.toggles, [0]);
      } finally {
        await rig.close();
      }
    },
  );

  test('Undo and Clear are inert', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.undo);
      await tap(rig, PedalButton.clear);
      expect(rig.engine.undoCalls, 0);
      expect(rig.engine.clearCalls, 0);
      expect(rig.engine.toggles, isEmpty);
      // Neither pedal reaches the transport: every track keeps playing.
      expect(rig.engine.stopTrackCalls, 0);
      expect(rig.engine.cancelCountInCalls, 0);
      expect(rig.control.state.parkedResume, isEmpty);
      expect(rig.control.state.mode, InteractionMode.reverse);
    } finally {
      await rig.close();
    }
  });

  test('a busy recorded track is refused with one notice, then turns once '
      'it settles', () async {
    final rig = _Rig()..engine.overdubbing.add(0);
    rig.engine
      ..pendingTracks.add(1)
      ..publish();
    await rig.poll();
    rig.control.setMode(InteractionMode.reverse);
    await _pump();
    try {
      await tap(rig, PedalButton.track1); // overdubbing
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footReverseFailure, 1);
      await tap(rig, PedalButton.track2); // arm pending
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footReverseFailure, 2);
      rig.engine.overdubbing.clear();
      rig.engine
        ..pendingTracks.clear()
        ..publish();
      await rig.poll();
      await tap(rig, PedalButton.track1);
      await tap(rig, PedalButton.track2);
      expect(rig.engine.toggles, [0, 1]);
      expect(rig.control.state.footReverseFailure, 2);
    } finally {
      await rig.close();
    }
  });

  test('a toggle is refused during a Session transition', () async {
    final rig = await enter();
    try {
      rig.persistence.reserveSessionLoad();
      await tap(rig, PedalButton.track1);
      await rig.control.toggleFootReverseTrack(1);
      rig.control.activateFootReversePedal(PedalButton.track2);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footReverseFailure, 0);
      rig.persistence.cancelSessionLoad();
      await tap(rig, PedalButton.track1);
      expect(rig.engine.toggles, [0]);
    } finally {
      await rig.close();
    }
  });

  test('Exit leaves Reverse even while toggles are not editable', () async {
    final rig = await enter();
    try {
      // A Session transition makes the surface read-only; Exit still works.
      rig.persistence.reserveSessionLoad();
      await tap(rig, PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      rig.persistence.cancelSessionLoad();
      // Behind the power-off dialog the pedals are locked upstream, but the
      // screen's Exit activation still leaves.
      rig.control.setMode(InteractionMode.reverse);
      await _pump();
      rig.powerOffUp = true;
      rig.control.activateFootReversePedal(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.toggles, isEmpty);
    } finally {
      await rig.close();
    }
  });

  test('the Mode cycle leaves Reverse for Tracks', () async {
    final rig = await enter();
    try {
      rig.control.toggleMode();
      expect(rig.control.state.mode, InteractionMode.record);
    } finally {
      await rig.close();
    }
  });

  test('a track button in Reverse mode is inert, like Fade', () async {
    final rig = await enter();
    try {
      rig.control.trackPressed(0);
      rig.control.trackPressed(1);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footReverseFailure, 0);
      expect(rig.control.state.mode, InteractionMode.reverse);
    } finally {
      await rig.close();
    }
  });

  test('an empty track is unavailable, not a failure', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track3); // channel 2 is empty
      expect(rig.engine.toggles, isEmpty);
      expect(rig.control.state.footReverseFailure, 0);
    } finally {
      await rig.close();
    }
  });

  test('a refused toggle is reported once, and not after the visit '
      'ended', () async {
    final rig = await enter();
    try {
      rig.engine.refuse = true;
      await tap(rig, PedalButton.track1);
      await _pump();
      expect(rig.control.state.footReverseFailure, 1);
      // A refusal that lands after Exit belongs to a finished visit.
      final pending = rig.control.toggleFootReverseTrack(1);
      rig.control.setMode(InteractionMode.record);
      await pending;
      expect(rig.control.state.footReverseFailure, 1);
      // Even when the player is back in Reverse by the time it lands.
      rig.control.setMode(InteractionMode.reverse);
      await _pump();
      final revisit = rig.control.toggleFootReverseTrack(1);
      rig.control
        ..setMode(InteractionMode.record)
        ..setMode(InteractionMode.reverse);
      await revisit;
      expect(rig.control.state.footReverseFailure, 1);
      // A Session load that began meanwhile retires the report too.
      final reloaded = rig.control.toggleFootReverseTrack(1);
      rig.looper.revision = rig.looper.sessionRevision + 1;
      await reloaded;
      expect(rig.control.state.footReverseFailure, 1);
      // The same refusal with nothing in between is reported.
      await rig.control.toggleFootReverseTrack(1);
      expect(rig.control.state.footReverseFailure, 2);
    } finally {
      await rig.close();
    }
  });

  test('Exit returns to Tracks and keeps every direction', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track1);
      await tap(rig, PedalButton.track2);
      rig.link.press(PedalButton.mode, down: true);
      await _pump();
      rig.link.press(PedalButton.mode, down: false);
      await rig.poll();
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.engine.toggles, [0, 1], reason: 'Exit adds no toggle');
      expect(
        [for (final track in rig.looper.state.tracks) track.reversed],
        [true, true, false, false, false, false, false, false],
      );
    } finally {
      await rig.close();
    }
  });

  test('Record / Play on a reversed cursor track reports the overdub '
      'refusal', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track1);
      await rig.poll();
      expect(rig.control.state.cursor, 0);
      final refusals = <int>[];
      final sub = rig.looper.overdubRefusals.listen(refusals.add);
      await tap(rig, PedalButton.recPlay);
      expect(rig.engine.records, [0]);
      // The same report every mode gets: one record-refusal notice.
      expect(refusals, [0]);
      expect(rig.control.state.footReverseFailure, 0);
      // Back in Tracks, the same press reports the same way.
      rig.control.setMode(InteractionMode.record);
      await _pump();
      rig.control.recPlay();
      await _pump();
      expect(refusals, [0, 0]);
      unawaited(sub.cancel());
    } finally {
      await rig.close();
    }
  });

  test('Reverse mode lights reversed recorded track switches only', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track2);
      await rig.poll();
      final mask = rig.link.lastFrame!.activeButtonMask;
      expect(mask & (1 << PedalButton.track2.index), isNonZero);
      expect(mask & (1 << PedalButton.track1.index), 0);
      expect(mask & (1 << PedalButton.undo.index), 0);
    } finally {
      await rig.close();
    }
  });

  group('assigned Reverse actions reach the same adapter', () {
    const selected = TrackOperationAction(
      operation: TrackOperation.reverse,
      scope: SelectedTrackScope(),
    );
    const fixed = TrackOperationAction(
      operation: TrackOperation.reverse,
      scope: FixedTrackScope(4),
    );
    const all = TrackOperationAction(
      operation: TrackOperation.reverse,
      scope: AllTracksScope(),
    );

    test('a Custom pedal: selected, fixed and all tracks', () async {
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
              )
              .withCustom(
                PedalButton.stop,
                bank: 0,
                pair: const ControlGesturePair(press: all),
              ),
        );
        rig.control
          ..selectTrack(1)
          ..setMode(InteractionMode.custom);
        for (final button in [
          PedalButton.clear,
          PedalButton.undo,
          PedalButton.stop,
        ]) {
          rig.link.press(button, down: true);
          await _pump(const Duration(milliseconds: 50));
          rig.link.press(button, down: false);
          await _pump(const Duration(milliseconds: 30));
        }
        expect(rig.engine.toggles.take(2), [1, 4]);
        expect(rig.engine.toggles.skip(2).toSet(), {0, 1, 4});
        await rig.poll();
        expect(
          rig.engine.reversedTracks,
          {0},
          reason: '1 and 4 were turned twice',
        );
        bool lit(PedalButton button) =>
            rig.link.lastFrame!.activeButtonMask & (1 << button.index) != 0;
        // The all-tracks assignment reads active only once every recorded
        // track plays reversed.
        expect(lit(PedalButton.stop), isFalse);
        for (final button in [PedalButton.clear, PedalButton.undo]) {
          rig.link.press(button, down: true);
          await _pump(const Duration(milliseconds: 50));
          rig.link.press(button, down: false);
          await _pump(const Duration(milliseconds: 30));
        }
        await rig.poll();
        expect(rig.engine.reversedTracks, {0, 1, 4});
        expect(lit(PedalButton.stop), isTrue);
        expect(lit(PedalButton.undo), isTrue, reason: 'track 5 reversed');
      } finally {
        await rig.close();
      }
    });

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
        expect(rig.engine.toggles, [4]);
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
            controls: [MidiActionControl(key: all.key)],
          ),
          owner: owner,
          create: true,
        );
        expect(saved.saved, isTrue);
        rig.control.endMidiEdit(owner);
        rig.midi.push(21, 127);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.toggles.toSet(), {0, 1, 4});
      } finally {
        await rig.close();
      }
    });
  });
}
