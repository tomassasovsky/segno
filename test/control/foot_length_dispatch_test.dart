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
import 'package:segno/control/model/foot_length.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show LengthEdit, RequestAdmission, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Doubles and halves tracks and publishes the length like the callback.
class _Engine extends FakeAudioEngine {
  _Engine(this.recorded);

  final Set<int> recorded;
  final lengths = <int, int>{};

  /// Recorded tracks writing an overdub pass.
  final overdubbing = <int>{};
  final edits = <(int, LengthEdit)>[];
  final _results = <int, EngineResult>{};
  var _request = 0;

  /// The verdict the next edits get, in order; empty accepts.
  final verdicts = <EngineResult>[];

  void publish() => nextSnapshot = nextSnapshot.copyWith(
    tracks: [
      for (var channel = 0; channel < 8; channel++)
        if (recorded.contains(channel))
          TrackSnapshot(
            state: overdubbing.contains(channel)
                ? TrackState.overdubbing
                : TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: lengths[channel] ?? 48000,
            multiple: (lengths[channel] ?? 48000) ~/ 48000 < 1
                ? 1
                : (lengths[channel] ?? 48000) ~/ 48000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          )
        else
          const TrackSnapshot.empty(),
    ],
  );

  @override
  RequestAdmission editLength({
    required int channel,
    required LengthEdit edit,
  }) {
    edits.add((channel, edit));
    final verdict = verdicts.isEmpty ? EngineResult.ok : verdicts.removeAt(0);
    if (verdict != EngineResult.ok) return (result: verdict, request: 0);
    final length = lengths[channel] ?? 48000;
    lengths[channel] = edit == LengthEdit.doubled ? length * 2 : length ~/ 2;
    publish();
    final request = ++_request;
    _results[request] = EngineResult.ok;
    return (result: EngineResult.ok, request: request);
  }

  @override
  EngineResult? readRequestResult(int request) =>
      _results.remove(request) ?? super.readRequestResult(request);
}

/// A repository whose Session revision a test can move mid-edit, the way a
/// Session load does.
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
    control.footLengthPressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footLengthReleased(button, contact);
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
  Future<_Rig> enter({
    Set<int> recorded = const {0, 1, 4},
    int cursor = 0,
    InteractionMode mode = InteractionMode.multiply,
  }) async {
    final rig = _Rig(recorded: recorded);
    await rig.poll();
    rig.control
      ..selectTrack(cursor)
      ..setMode(mode);
    await _pump();
    return rig;
  }

  Future<void> tap(_Rig rig, PedalButton button) async {
    rig.press(button);
    await _pump(const Duration(milliseconds: 50));
    rig.release(button);
    await _pump();
  }

  test('a track pedal selects its recorded track on contact', () async {
    final rig = await enter();
    try {
      rig.press(PedalButton.track2);
      await _pump();
      expect(rig.control.state.cursor, 1, reason: 'selected at contact');
      rig.release(PedalButton.track2);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.edits, isEmpty, reason: 'selecting edits nothing');
    } finally {
      await rig.close();
    }
  });

  test('Multiply (pen 16 01-02): Clear doubles the selected track; Undo '
      'stays Undo and Rec/Play stays Record / Play', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track2);
      await tap(rig, PedalButton.clear);
      await rig.poll();
      expect(rig.looper.state.tracks[1].lengthFrames, 96000);
      expect(rig.engine.edits, [(1, LengthEdit.doubled)]);
      // Clear never reaches the eraser here.
      expect(rig.engine.clearCalls, 0);
      expect(rig.engine.undoCalls, 0);
      await tap(rig, PedalButton.undo);
      expect(rig.engine.undoCalls, 1, reason: 'Undo is the Tracks Undo');
      await tap(rig, PedalButton.recPlay);
      expect(rig.engine.recordCalls, 1, reason: 'Rec/Play records');
      expect(rig.engine.edits, [(1, LengthEdit.doubled)]);
      expect(rig.control.state.footLengthFailure, 0);
    } finally {
      await rig.close();
    }
  });

  test('Divide (pen 16 03-08): a tap on Undo keeps the first half, Clear '
      'the last half; a hold on Undo undoes instead', () async {
    final rig = await enter(mode: InteractionMode.divide);
    try {
      await tap(rig, PedalButton.track2);
      rig.press(PedalButton.undo);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.edits, isEmpty, reason: 'First half waits for release');
      rig.release(PedalButton.undo);
      await _pump();
      await tap(rig, PedalButton.clear);
      expect(rig.engine.edits, [
        (1, LengthEdit.firstHalf),
        (1, LengthEdit.lastHalf),
      ]);
      expect(rig.engine.undoCalls, 0);
      expect(rig.engine.clearCalls, 0);
      // Held past the threshold: Undo, and no First half on the release.
      rig.press(PedalButton.undo);
      await _pump(const Duration(milliseconds: 900));
      rig.release(PedalButton.undo);
      await _pump();
      expect(rig.engine.undoCalls, 1);
      expect(rig.engine.edits, hasLength(2));
      await tap(rig, PedalButton.recPlay);
      expect(rig.engine.recordCalls, 1, reason: 'Rec/Play records');
      expect(rig.control.state.footLengthFailure, 0);
    } finally {
      await rig.close();
    }
  });

  test('the keyboard Rec/Play and the footswitch do the same thing on both '
      'surfaces', () async {
    for (final mode in [InteractionMode.multiply, InteractionMode.divide]) {
      final rig = await enter(mode: mode);
      try {
        await tap(rig, PedalButton.recPlay);
        expect(rig.engine.recordCalls, 1, reason: '$mode footswitch');
        rig.control.recPlay();
        await _pump();
        expect(rig.engine.recordCalls, 2, reason: '$mode keyboard');
        expect(rig.engine.edits, isEmpty);
      } finally {
        await rig.close();
      }
    }
  });

  test('an accepted edit becomes the outcome; entering a surface starts '
      'with none', () async {
    final rig = await enter();
    try {
      expect(rig.control.state.footLengthOutcome, FootLengthOutcome.none);
      await tap(rig, PedalButton.clear);
      await _pump();
      expect(
        rig.control.state.footLengthOutcome,
        const FootLengthOutcome(
          channel: 0,
          edit: LengthEdit.doubled,
          fromFrames: 48000,
        ),
      );
      // A refused edit leaves it.
      rig.engine.verdicts.add(EngineResult.modeMismatch);
      await tap(rig, PedalButton.clear);
      await _pump();
      expect(rig.control.state.footLengthOutcome.edit, LengthEdit.doubled);
      rig.control.setMode(InteractionMode.divide);
      expect(rig.control.state.footLengthOutcome, FootLengthOutcome.none);
    } finally {
      await rig.close();
    }
  });

  test('Bank pages; the track pedals then select the other four', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.bank);
      expect(rig.control.state.activeBank, 1);
      expect(rig.control.state.cursor, 0, reason: 'paging keeps the cursor');
      await tap(rig, PedalButton.track1);
      // Slot 0 of bank B is track 5 (channel 4).
      expect(rig.control.state.cursor, 4);
      await tap(rig, PedalButton.clear);
      expect(rig.engine.edits, [(4, LengthEdit.doubled)]);
    } finally {
      await rig.close();
    }
  });

  test('an empty track is dimmed and silent', () async {
    final rig = await enter(cursor: 2);
    try {
      // The edit pedals rest while the selected track is empty: a held
      // stomp is not accepted, so its pedal stays dark.
      rig.press(PedalButton.clear);
      await _pump();
      await rig.poll();
      expect(
        rig.link.lastFrame!.activeButtonMask & (1 << PedalButton.clear.index),
        0,
      );
      rig.release(PedalButton.clear);
      await _pump();
      await tap(rig, PedalButton.clear);
      await rig.control.editFootLengthTrack(LengthEdit.doubled);
      rig.control.setMode(InteractionMode.divide);
      await tap(rig, PedalButton.undo);
      await tap(rig, PedalButton.clear);
      // Its own pedal cannot select it.
      await tap(rig, PedalButton.track1);
      await tap(rig, PedalButton.track4); // channel 3 is empty
      expect(rig.control.state.cursor, 0);
      expect(rig.engine.edits, isEmpty);
      expect(rig.control.state.footLengthFailure, 0);
    } finally {
      await rig.close();
    }
  });

  test('a busy recorded track is refused with the busy notice, without '
      'reaching the engine', () async {
    final rig = _Rig()..engine.overdubbing.add(0);
    rig.engine.publish();
    await rig.poll();
    rig.control.setMode(InteractionMode.multiply);
    await _pump();
    try {
      await tap(rig, PedalButton.clear);
      expect(rig.engine.edits, isEmpty);
      expect(rig.control.state.footLengthFailure, 1);
      expect(rig.control.state.footLengthRefusal, FootLengthRefusal.busy);
      rig.engine.overdubbing.clear();
      rig.engine.publish();
      await rig.poll();
      await tap(rig, PedalButton.clear);
      expect(rig.engine.edits, [(0, LengthEdit.doubled)]);
      expect(rig.control.state.footLengthFailure, 1);
    } finally {
      await rig.close();
    }
  });

  test('every engine refusal shows its own notice, once', () async {
    final rig = await enter();
    try {
      final expected = {
        EngineResult.modeMismatch: FootLengthRefusal.incompatible,
        EngineResult.capacity: FootLengthRefusal.capacity,
        EngineResult.notReady: FootLengthRefusal.busy,
        EngineResult.invalid: FootLengthRefusal.failed,
      };
      var failures = 0;
      for (final MapEntry(key: verdict, value: refusal) in expected.entries) {
        rig.engine.verdicts.add(verdict);
        await tap(rig, PedalButton.clear);
        await _pump();
        expect(rig.control.state.footLengthFailure, ++failures);
        expect(rig.control.state.footLengthRefusal, refusal);
      }
      expect(rig.looper.state.tracks[0].lengthFrames, 48000);
      expect(rig.control.state.footLengthOutcome, FootLengthOutcome.none);
    } finally {
      await rig.close();
    }
  });

  test('a refusal is not reported after its visit or Session ended', () async {
    final rig = await enter();
    try {
      rig.engine.verdicts.add(EngineResult.modeMismatch);
      final pending = rig.control.editFootLengthTrack(LengthEdit.firstHalf);
      rig.control.setMode(InteractionMode.record);
      await pending;
      expect(rig.control.state.footLengthFailure, 0);
      // Even when the player is back by the time it lands.
      rig.control.setMode(InteractionMode.multiply);
      await _pump();
      rig.engine.verdicts.add(EngineResult.modeMismatch);
      final revisit = rig.control.editFootLengthTrack(LengthEdit.firstHalf);
      rig.control
        ..setMode(InteractionMode.record)
        ..setMode(InteractionMode.multiply);
      await revisit;
      expect(rig.control.state.footLengthFailure, 0);
      // A Session load that began meanwhile retires the report too.
      rig.engine.verdicts.add(EngineResult.modeMismatch);
      final reloaded = rig.control.editFootLengthTrack(LengthEdit.firstHalf);
      rig.looper.revision = rig.looper.sessionRevision + 1;
      await reloaded;
      expect(rig.control.state.footLengthFailure, 0);
      rig.engine.verdicts.add(EngineResult.modeMismatch);
      await rig.control.editFootLengthTrack(LengthEdit.firstHalf);
      expect(rig.control.state.footLengthFailure, 1);
    } finally {
      await rig.close();
    }
  });

  test('edits are refused during a Session transition and behind the '
      'power-off dialog; Exit still leaves', () async {
    final rig = await enter();
    try {
      rig.persistence.reserveSessionLoad();
      await tap(rig, PedalButton.clear);
      await tap(rig, PedalButton.track2);
      await rig.control.editFootLengthTrack(LengthEdit.doubled);
      rig.control.activateFootLengthPedal(PedalButton.clear);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.edits, isEmpty);
      expect(rig.control.state.cursor, 0);
      expect(rig.control.state.footLengthFailure, 0);
      await tap(rig, PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      rig.persistence.cancelSessionLoad();
      rig.control.setMode(InteractionMode.multiply);
      await _pump();
      rig.powerOffUp = true;
      await rig.control.editFootLengthTrack(LengthEdit.doubled);
      rig.control.activateFootLengthPedal(PedalButton.clear);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.engine.edits, isEmpty);
      rig.control.activateFootLengthPedal(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
      rig.powerOffUp = false;
    } finally {
      await rig.close();
    }
  });

  test('Exit returns to Tracks keeping the lengths; the Mode cycle and a '
      'track button behave as on the other surfaces', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.clear);
      rig.control.trackPressed(1);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.control.state.mode, InteractionMode.multiply);
      expect(rig.engine.edits, [(0, LengthEdit.doubled)]);
      rig.link.press(PedalButton.mode, down: true);
      await _pump();
      rig.link.press(PedalButton.mode, down: false);
      await rig.poll();
      expect(rig.control.state.mode, InteractionMode.record);
      expect(rig.looper.state.tracks[0].lengthFrames, 96000);
      rig.control.setMode(InteractionMode.multiply);
      rig.control.toggleMode();
      expect(rig.control.state.mode, InteractionMode.record);
    } finally {
      await rig.close();
    }
  });

  test('the selected recorded track lights; an accepted edit lights its '
      'pedal', () async {
    final rig = await enter();
    try {
      await tap(rig, PedalButton.track2);
      await rig.poll();
      bool lit(PedalButton button) =>
          rig.link.lastFrame!.activeButtonMask & (1 << button.index) != 0;
      expect(lit(PedalButton.track2), isTrue);
      expect(lit(PedalButton.track1), isFalse);
      expect(lit(PedalButton.clear), isFalse);
      rig.press(PedalButton.clear);
      await _pump();
      await rig.poll();
      expect(lit(PedalButton.clear), isTrue, reason: 'held, accepted');
      rig.release(PedalButton.clear);
      await rig.poll();
      expect(lit(PedalButton.clear), isFalse);
    } finally {
      await rig.close();
    }
  });

  group('assigned Multiply and Divide reach the same adapter', () {
    const multiply = TrackOperationAction(
      operation: TrackOperation.multiply,
      scope: SelectedTrackScope(),
    );
    const firstHalf = TrackOperationAction(
      operation: TrackOperation.divideFirstHalf,
      scope: FixedTrackScope(4),
    );
    const lastHalf = TrackOperationAction(
      operation: TrackOperation.divideLastHalf,
      scope: FixedTrackScope(2),
    );

    test('every scope but all tracks is offered', () {
      final keys = {
        for (final action in controlActionCatalogue()) action.key,
      };
      for (final operation in [
        TrackOperation.multiply,
        TrackOperation.divideFirstHalf,
        TrackOperation.divideLastHalf,
      ]) {
        expect(
          keys,
          contains(
            TrackOperationAction(
              operation: operation,
              scope: const SelectedTrackScope(),
            ).key,
          ),
        );
        expect(
          keys,
          isNot(
            contains(
              TrackOperationAction(
                operation: operation,
                scope: const AllTracksScope(),
              ).key,
            ),
          ),
        );
      }
      expect(
        keys,
        containsAll([
          const ModeAction(InteractionMode.multiply).key,
          const ModeAction(InteractionMode.divide).key,
        ]),
      );
    });

    test('a Custom pedal: selected and fixed; an empty target and an '
        'engine refusal say why, in any mode', () async {
      final rig = _Rig();
      try {
        await rig.poll();
        await rig.control.setPedalSetup(
          const PedalSetup()
              .withCustom(
                PedalButton.clear,
                bank: 0,
                pair: const ControlGesturePair(press: multiply),
              )
              .withCustom(
                PedalButton.undo,
                bank: 0,
                pair: const ControlGesturePair(press: firstHalf),
              )
              .withCustom(
                PedalButton.stop,
                bank: 0,
                pair: const ControlGesturePair(press: lastHalf),
              ),
        );
        rig.control
          ..selectTrack(1)
          ..setMode(InteractionMode.custom);
        Future<void> stomp(PedalButton button) async {
          rig.link.press(button, down: true);
          await _pump(const Duration(milliseconds: 50));
          rig.link.press(button, down: false);
          await _pump(const Duration(milliseconds: 30));
        }

        await stomp(PedalButton.clear);
        await stomp(PedalButton.undo);
        expect(rig.engine.edits, [
          (1, LengthEdit.doubled),
          (4, LengthEdit.firstHalf),
        ]);
        expect(rig.control.state.footLengthFailure, 0);
        // Track 3 is empty: the assigned stomp says so.
        await stomp(PedalButton.stop);
        expect(rig.engine.edits, hasLength(2));
        expect(rig.control.state.footLengthFailure, 1);
        expect(rig.control.state.footLengthRefusal, FootLengthRefusal.empty);
        rig.engine.verdicts.add(EngineResult.capacity);
        await stomp(PedalButton.clear);
        expect(rig.control.state.footLengthFailure, 2);
        expect(
          rig.control.state.footLengthRefusal,
          FootLengthRefusal.capacity,
        );
        expect(rig.control.state.mode, InteractionMode.custom);
      } finally {
        await rig.close();
      }
    });

    test('a CTRL switch', () async {
      final rig = _Rig(
        jack: const ExternalJackSetup(
          single: ExternalSwitchSetup(
            gestures: ControlGesturePair(press: firstHalf),
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
        expect(rig.engine.edits, [(4, LengthEdit.firstHalf)]);
      } finally {
        await rig.close();
      }
    });

    test('a MIDI action', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await rig.poll();
        rig.control.selectTrack(1);
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
            controls: [MidiActionControl(key: multiply.key)],
          ),
          owner: owner,
          create: true,
        );
        expect(saved.saved, isTrue);
        rig.control.endMidiEdit(owner);
        rig.midi.push(21, 127);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.edits, [(1, LengthEdit.doubled)]);
      } finally {
        await rig.close();
      }
    });
  });
}
