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
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Tracks 1 and 2 are recorded; the rest are empty.
class _Engine extends FakeAudioEngine {
  /// A result [record] returns instead of recording.
  EngineResult? recordResult;

  @override
  EngineResult record({int channel = 0}) =>
      recordResult ?? super.record(channel: channel);

  void publish() => nextSnapshot = nextSnapshot.copyWith(
    tracks: [
      for (var channel = 0; channel < 8; channel++)
        if (channel < 2)
          const TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          )
        else
          const TrackSnapshot.empty(),
    ],
  );
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
  _Rig({ExternalJackSetup? jack}) {
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
      freeSpaceBytes: (_) async => freeBytes,
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
  late final _Midi midi;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final FadeSettings fade;
  late final ControlCubit control;

  /// The power-off route is up: takes and performance actions are locked.
  bool powerOffUp = false;

  /// The free room on the exports volume; null is unknown.
  int? freeBytes;

  final _contacts = <PedalButton, Object>{};
  void press(PedalButton button) {
    final contact = Object();
    _contacts[button] = contact;
    control.footCustomPressed(button, contact);
  }

  void release(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footCustomReleased(button, contact);
  }

  void cancel(PedalButton button) {
    final contact = _contacts.remove(button);
    if (contact != null) control.footCustomCancelled(button, contact);
  }

  /// Stomps the physical switch.
  Future<void> stomp(PedalButton button) async {
    link.press(button, down: true);
    await _pump(const Duration(milliseconds: 50));
    link.press(button, down: false);
    await _pump(const Duration(milliseconds: 30));
    await poll();
  }

  /// Lets the repository poll the published snapshot.
  Future<void> poll() async {
    ticks.add(null);
    await _pump();
  }

  /// The generic assigned-action notices so far, in order.
  final refused = <ControlAction>[];
  StreamSubscription<ControlState>? _notices;

  void watchNotices() {
    var count = control.state.assignedActionFailure;
    _notices = control.stream.listen((state) {
      if (state.assignedActionFailure == count) return;
      count = state.assignedActionFailure;
      refused.add(state.assignedActionRefusal!);
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

const _future = UnavailableAction('future:thing');
const _undoFirst = TrackOperationAction(
  operation: TrackOperation.undo,
  scope: FixedTrackScope(0),
);

void main() {
  Future<_Rig> enter(PedalSetup setup) async {
    final rig = _Rig();
    await rig.poll();
    await rig.control.setPedalSetup(setup);
    rig.control.setMode(InteractionMode.custom);
    await _pump();
    rig.watchNotices();
    return rig;
  }

  group('the on-screen contact', () {
    final setup = const PedalSetup()
        .withCustom(
          PedalButton.track1,
          bank: 0,
          pair: const ControlGesturePair(
            press: SelectTrackAction(2),
            hold: SelectTrackAction(3),
          ),
        )
        .withCustom(
          PedalButton.track1,
          bank: 1,
          pair: const ControlGesturePair(press: SelectTrackAction(6)),
        );

    test('a tap runs the Press for the bank in view', () async {
      final rig = await enter(setup);
      try {
        rig.press(PedalButton.track1);
        await _pump(const Duration(milliseconds: 50));
        rig.release(PedalButton.track1);
        await _pump();
        expect(rig.control.state.cursor, 2);
        rig.control.toggleBankWithCursor();
        await _pump();
        rig.press(PedalButton.track1);
        await _pump(const Duration(milliseconds: 50));
        rig.release(PedalButton.track1);
        await _pump();
        expect(rig.control.state.cursor, 6);
      } finally {
        await rig.close();
      }
    });

    test('a hold runs the Hold', () async {
      final rig = await enter(setup);
      try {
        rig.press(PedalButton.track1);
        await _pump(const Duration(milliseconds: 900));
        rig.release(PedalButton.track1);
        await _pump();
        expect(rig.control.state.cursor, 3);
      } finally {
        await rig.close();
      }
    });

    test('a cancelled contact runs nothing', () async {
      final rig = await enter(setup);
      try {
        rig.press(PedalButton.track1);
        await _pump(const Duration(milliseconds: 50));
        rig.cancel(PedalButton.track1);
        await _pump(const Duration(milliseconds: 900));
        expect(rig.control.state.cursor, 0);
        // The switch takes the next contact.
        rig.press(PedalButton.track1);
        await _pump(const Duration(milliseconds: 50));
        rig.release(PedalButton.track1);
        await _pump();
        expect(rig.control.state.cursor, 2);
      } finally {
        await rig.close();
      }
    });

    test('a contact outside Custom mode is not admitted', () async {
      final rig = await enter(setup);
      try {
        rig.control.setMode(InteractionMode.record);
        await _pump();
        // A stale face's MODE contact would otherwise cycle the Record
        // surface's mode.
        rig.press(PedalButton.mode);
        await _pump(const Duration(milliseconds: 50));
        rig.release(PedalButton.mode);
        await _pump();
        expect(rig.control.state.mode, InteractionMode.record);
      } finally {
        await rig.close();
      }
    });

    test(
      'semantic activation runs the Press, the Hold, MODE and Bank',
      () async {
        final rig = await enter(setup);
        try {
          rig.control.activateFootCustomPedal(PedalButton.track1);
          await _pump();
          expect(rig.control.state.cursor, 2);
          rig.control.activateFootCustomPedal(PedalButton.track1, hold: true);
          await _pump();
          expect(rig.control.state.cursor, 3);
          // An unassigned switch does nothing and says nothing.
          rig.control.activateFootCustomPedal(PedalButton.stop);
          await _pump();
          expect(rig.refused, isEmpty);
          rig.control.activateFootCustomPedal(PedalButton.bank);
          await _pump();
          expect(rig.control.state.activeBank, 1);
          rig.control.activateFootCustomPedal(PedalButton.mode);
          await _pump();
          expect(rig.control.state.mode, InteractionMode.record);
        } finally {
          await rig.close();
        }
      },
    );

    test(
      'semantic activation is refused while the power-off dialog is up',
      () async {
        final rig = await enter(setup);
        try {
          rig.powerOffUp = true;
          rig.control.activateFootCustomPedal(PedalButton.track1);
          rig.control.activateFootCustomPedal(PedalButton.mode);
          await _pump();
          expect(rig.control.state.cursor, 0);
          expect(rig.control.state.mode, InteractionMode.custom);
        } finally {
          await rig.close();
        }
      },
    );
  });

  test('the face and the switch LEDs read one published value', () async {
    final rig = await enter(
      const PedalSetup().withCustom(
        PedalButton.clear,
        bank: 0,
        pair: const ControlGesturePair(press: SelectTrackAction(1)),
      ),
    );
    try {
      void expectParity() {
        for (final button in PedalButton.values) {
          if (button == PedalButton.mode || button == PedalButton.bank) {
            continue;
          }
          expect(
            rig.control.state.customLit[button] ?? false,
            rig.lit(button),
            reason: button.name,
          );
        }
      }

      expect(rig.control.state.customLit[PedalButton.clear], isFalse);
      expectParity();
      await rig.stomp(PedalButton.clear);
      expect(rig.control.state.cursor, 1);
      expect(rig.control.state.customLit[PedalButton.clear], isTrue);
      expectParity();
      rig.control.selectTrack(0);
      await _pump();
      expect(rig.control.state.customLit[PedalButton.clear], isFalse);
      expectParity();
      // Outside Custom the face is gone and nothing is published.
      rig.control.setMode(InteractionMode.record);
      await _pump();
      expect(rig.control.state.customLit, isEmpty);
    } finally {
      await rig.close();
    }
  });

  group('a refused assignment says so once', () {
    test('an action this build cannot run, from a Custom switch', () async {
      final rig = await enter(
        const PedalSetup().withCustom(
          PedalButton.stop,
          bank: 0,
          pair: const ControlGesturePair(press: _future),
        ),
      );
      try {
        await rig.stomp(PedalButton.stop);
        expect(rig.refused, [_future]);
      } finally {
        await rig.close();
      }
    });

    test('an action the rig refuses, from a Custom switch', () async {
      final rig = await enter(
        const PedalSetup().withCustom(
          PedalButton.undo,
          bank: 0,
          pair: const ControlGesturePair(press: _undoFirst),
        ),
      );
      try {
        await rig.stomp(PedalButton.undo);
        expect(rig.engine.undoCalls, 1);
        expect(rig.refused, isEmpty, reason: 'an accepted action is quiet');
        rig.engine.nextUndoResult = EngineResult.invalid;
        await rig.stomp(PedalButton.undo);
        expect(rig.engine.undoCalls, 2);
        expect(rig.refused, [_undoFirst]);
      } finally {
        await rig.close();
      }
    });

    test('an action that is refused later, from a Custom switch', () async {
      const solo = TrackOperationAction(
        operation: TrackOperation.solo,
        scope: FixedTrackScope(0),
      );
      final rig = await enter(
        const PedalSetup().withCustom(
          PedalButton.undo,
          bank: 0,
          pair: const ControlGesturePair(press: solo),
        ),
      );
      try {
        // A session change holds the mix: the Solo is turned away once the
        // mix answers.
        final held = Completer<void>();
        final exclusive = rig.mix.runExclusive(() => held.future);
        await rig.stomp(PedalButton.undo);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.refused, [solo]);
        held.complete();
        await exclusive;
        await rig.stomp(PedalButton.undo);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.refused, [solo], reason: 'an accepted Solo is quiet');
      } finally {
        await rig.close();
      }
    });

    test('nothing is said while the power-off dialog is up', () async {
      final rig = await enter(
        const PedalSetup().withCustom(
          PedalButton.stop,
          bank: 0,
          pair: const ControlGesturePair(press: _future),
        ),
      );
      try {
        rig.powerOffUp = true;
        await rig.stomp(PedalButton.stop);
        expect(rig.refused, isEmpty);
      } finally {
        await rig.close();
      }
    });

    test('Fade, Reverse and Peel keep their own notice', () async {
      ControlGesturePair on(TrackOperation operation) => ControlGesturePair(
        press: TrackOperationAction(
          operation: operation,
          scope: const FixedTrackScope(2),
        ),
      );
      final rig = await enter(
        const PedalSetup()
            .withCustom(
              PedalButton.recPlay,
              bank: 0,
              pair: on(TrackOperation.fade),
            )
            .withCustom(
              PedalButton.stop,
              bank: 0,
              pair: on(TrackOperation.reverse),
            )
            .withCustom(
              PedalButton.undo,
              bank: 0,
              pair: on(TrackOperation.peel),
            ),
      );
      try {
        final before = rig.control.state;
        await rig.stomp(PedalButton.recPlay);
        await rig.stomp(PedalButton.stop);
        await rig.stomp(PedalButton.undo);
        final after = rig.control.state;
        expect(after.footFadeFailure, before.footFadeFailure + 1);
        expect(after.footReverseFailure, before.footReverseFailure + 1);
        expect(after.footPeelFailure, before.footPeelFailure + 1);
        expect(rig.refused, isEmpty);
      } finally {
        await rig.close();
      }
    });

    const perform = CommandAction(ControlCommand.recordPerformance);
    final performOnStop = const PedalSetup().withCustom(
      PedalButton.stop,
      bank: 0,
      pair: const ControlGesturePair(press: perform),
    );

    test('a performance arm the engine refuses says so once', () async {
      final rig = await enter(performOnStop);
      try {
        rig.engine.perfArmResult = EngineResult.invalid;
        await rig.stomp(PedalButton.stop);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.perfArmCalls, 1);
        expect(rig.refused, [perform]);
        expect(rig.control.state.assignedActionLowDisk, isFalse);
      } finally {
        await rig.close();
      }
    });

    test('a performance arm with too little room is refused before the '
        'engine, and says so in the recorder words', () async {
      final rig = await enter(performOnStop);
      try {
        rig.freeBytes = 1;
        await rig.stomp(PedalButton.stop);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.perfArmCalls, 0);
        expect(rig.refused, [perform]);
        expect(rig.control.state.assignedActionLowDisk, isTrue);
        // Room again: it arms, and says nothing.
        rig.freeBytes = null;
        await rig.stomp(PedalButton.stop);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.engine.perfArmCalls, 1);
        expect(rig.refused, [perform]);
      } finally {
        await rig.close();
      }
    });

    test('a Record / Play the looper refuses with its own notice gets no '
        'second one', () async {
      const recordPlay = CommandAction(ControlCommand.recordPlay);
      final rig = await enter(
        const PedalSetup().withCustom(
          PedalButton.undo,
          bank: 0,
          pair: const ControlGesturePair(press: recordPlay),
        ),
      );
      final announced = <int>[];
      final subscription = rig.looper.overdubRefusals.listen(announced.add);
      try {
        // Track 1 plays reversed: an overdub is refused, and the looper says
        // so itself.
        rig.engine.recordResult = EngineResult.reversed;
        await rig.stomp(PedalButton.undo);
        await _pump(const Duration(milliseconds: 30));
        expect(announced, [0]);
        expect(rig.refused, isEmpty);
        // A refusal the looper does not announce still gets the generic one.
        rig.engine.recordResult = EngineResult.invalid;
        await rig.stomp(PedalButton.undo);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.refused, [recordPlay]);
      } finally {
        await subscription.cancel();
        await rig.close();
      }
    });

    test('a CTRL switch, in Tracks mode', () async {
      for (final (action, expected) in [
        (_future, [_future]),
        (_undoFirst, [_undoFirst]),
      ]) {
        final rig = _Rig(
          jack: ExternalJackSetup(
            single: ExternalSwitchSetup(
              gestures: ControlGesturePair(press: action),
            ),
          ),
        );
        try {
          await rig.control.load();
          await rig.poll();
          rig
            ..engine.nextUndoResult = EngineResult.invalid
            ..watchNotices();
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
          expect(rig.refused, expected, reason: action.key);
        } finally {
          await rig.close();
        }
      }
    });

    test('a MIDI control, in Tracks mode', () async {
      for (final (key, expected) in [
        (_future.key, [_future]),
        (_undoFirst.key, [_undoFirst]),
      ]) {
        final rig = _Rig();
        try {
          await rig.control.load();
          await rig.poll();
          rig.engine.nextUndoResult = EngineResult.invalid;
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
              controls: [MidiActionControl(key: key)],
            ),
            owner: owner,
            create: true,
          );
          expect(saved.saved, isTrue, reason: key);
          rig.control.endMidiEdit(owner);
          rig.watchNotices();
          rig.midi.push(21, 127);
          await _pump(const Duration(milliseconds: 30));
          expect(rig.refused, expected, reason: key);
        } finally {
          await rig.close();
        }
      }
    });
  });
}
