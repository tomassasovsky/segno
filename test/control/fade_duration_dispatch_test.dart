import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
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
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, RequestAdmission, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Records the duration Control asks the engine to fade with.
class _Engine extends FakeAudioEngine {
  final toggles = <(int, double)>[];
  final _results = <int, EngineResult>{};

  @override
  RequestAdmission toggleFade({required int channel, required double seconds}) {
    toggles.add((channel, seconds));
    _results[toggles.length] = EngineResult.ok;
    return (result: EngineResult.ok, request: toggles.length);
  }

  @override
  EngineResult? readRequestResult(int request) =>
      _results.remove(request) ?? super.readRequestResult(request);
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('fade-test', 1);
  @override
  Stream<MidiInputMessage> get messages => inputs.stream;
  void push(int value) => inputs.add(
    MidiInputMessage(
      session,
      RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 21,
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

/// A 0.5–30 s endpoint expressed as its whole number of half-second steps.
double _travel(int milliseconds) => (milliseconds - 500) / 29500;

class _Rig {
  _Rig(this.clock, {required ExternalJackSetup jack}) {
    engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
      tracks: [
        const TrackSnapshot(
          state: TrackState.playing,
          volume: 1,
          muted: false,
          lengthFrames: 48000,
          undoDepth: 0,
          rms: 0,
          peak: 0,
        ),
        for (var channel = 1; channel < 8; channel++)
          const TrackSnapshot.empty(),
      ],
    );
    looper = LooperRepository(engine: engine, ticker: const Stream.empty());
    expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
    store.values['pedal.setup'] = const PedalSetup()
        .copyWith(
          external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: jack}),
        )
        .encode();
    settings = SettingsRepository(store: store);
    fade = FadeSettings(
      repository: looper,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    unawaited(fade.load());
    midi = _Midi(settings);
    mix = testMixSettings(looper, settings: settings);
    pedal = PedalRepository(link, clock: () => clock.elapsed);
    controller = ControllerRepository(sources: [ConsoleCtrlSource(pedal)]);
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    persistence = FxChainPersistence(looper: looper);
    cubit = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: persistence,
      controller: controller,
      midiDevices: midi,
      midiClock: () => clock.elapsed,
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
    unawaited(cubit.load());
    pump();
  }

  final FakeAsync clock;
  final engine = _Engine();
  final store = FakeKeyValueStore();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final FadeSettings fade;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final FxChainPersistence persistence;
  late final ControlCubit cubit;

  FadeDurations get live => fade.live;

  /// The stored record, decoded independently of FadeSettings.
  FadeDurations get stored {
    final record = store.values['looper.fade_durations'];
    return record == null
        ? FadeDurations.defaults
        : FadeDurations.fromJson(jsonDecode(record as String));
  }

  void pump() {
    for (var i = 0; i < 20; i++) {
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 5));
    }
    clock.flushMicrotasks();
  }

  void bind(
    FadeValueTarget target, {
    MidiBehavior behavior = MidiBehavior.momentary,
    MidiProtocol protocol = MidiProtocol.standard,
  }) {
    final owner = Object();
    cubit.beginMidiEdit(device: 'fade-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'fade-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls: [
                MidiParameterControl(
                  key: target.canonicalString(),
                  low: _travel(2000),
                  high: _travel(10000),
                ),
              ],
            ),
            owner: owner,
            create: true,
          )
          .then((result) {
            expect(result.saved, isTrue);
            cubit.endMidiEdit(owner);
          }),
    );
    pump();
  }

  void cc(int value) {
    midi.push(value);
    pump();
  }

  void ctrl(int value, {PedalCtrlKind kind = PedalCtrlKind.switchPedal}) {
    link.emit(CtrlMessage(jack: PedalCtrlJack.ctrl1, kind: kind, value: value));
    pump();
  }

  void close() {
    unawaited(cubit.close());
    pump();
    unawaited(fade.close());
    unawaited(persistence.close());
    unawaited(controller.dispose());
    unawaited(midi.dispose());
    unawaited(mix.close());
    unawaited(pedal.dispose());
    performance.dispose();
    unawaited(looper.dispose());
    clock.flushMicrotasks();
  }
}

/// A Held-on / Released-off button: 10 s while held, 2 s once released.
ExternalJackSetup _heldButton(FadeValueTarget target) => ExternalJackSetup(
  single: ExternalSwitchSetup(
    controls: ExternalControls(
      parameters: [
        ExternalParameter(
          target: target,
          active: _travel(10000),
          inactive: _travel(2000),
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
  ),
);

/// A full-sweep expression pedal over one Fade duration.
ExternalJackSetup _expression(FadeValueTarget target) => ExternalJackSetup(
  type: ExternalJackType.expression,
  expression: ExternalExpressionSetup(
    calibration: ExpressionCalibration(heel: 0, toe: 255),
    mappings: [ExpressionMapping(target: target)],
  ),
);

void main() {
  void check(
    String name,
    void Function(_Rig) body, {
    ExternalJackSetup? jack,
  }) => test(name, () {
    fakeAsync((clock) {
      final rig = _Rig(clock, jack: jack ?? ExternalJackSetup.empty);
      try {
        body(rig);
      } finally {
        rig.close();
      }
    });
  });

  group('Fade duration controller dispatch', () {
    check('a held MIDI CC applies to the next gesture but saves Released', (
      r,
    ) {
      r
        ..bind(const DefaultFadeTarget())
        ..cc(127);
      expect(r.live.defaultMs, 10000);
      expect(r.stored.defaultMs, 2000);
      // The held time is what the next fade uses: tap track 1 on the
      // Fade surface.
      r.cubit.setMode(InteractionMode.fade);
      r.pump();
      final contact = Object();
      r.cubit.footFadePressed(PedalButton.track1, contact);
      r.clock.elapse(const Duration(milliseconds: 50));
      r.cubit.footFadeReleased(PedalButton.track1, contact);
      r.pump();
      expect(r.engine.toggles, [(0, 10.0)]);
      r.cc(0);
      expect((r.live.defaultMs, r.stored.defaultMs), (2000, 2000));
    });

    check('a MIDI CC on an inherited track creates its override', (r) {
      r
        ..bind(const TrackFadeTarget(2))
        ..cc(127);
      expect(r.live.overrides, {2: 10000});
      expect(r.live.defaultMs, 4000);
      expect(r.stored.overrides, {2: 2000});
      r.cc(0);
      expect(r.live.overrides, {2: 2000});
      expect(r.stored, r.live);
    });

    check('a relative detent moves one half-second step', (r) {
      r
        ..bind(
          const TrackFadeTarget(5),
          behavior: MidiBehavior.continuous,
          protocol: MidiProtocol.relative,
        )
        ..cc(1);
      expect(r.live.effectiveMs(5), 4500);
      r.cc(127);
      expect(r.live.effectiveMs(5), 4000);
      expect(r.stored.overrides, {5: 4000});
    });

    check('an ordinary edit outranks a held MIDI value and its release', (r) {
      r
        ..bind(const DefaultFadeTarget())
        ..cc(127);
      unawaited(r.fade.setDefault(8000));
      r.pump();
      expect(r.live.defaultMs, 8000);
      r.cc(0);
      expect((r.live.defaultMs, r.stored.defaultMs), (8000, 8000));
    });

    for (final target in const [DefaultFadeTarget(), TrackFadeTarget(3)]) {
      int at(FadeDurations durations) => target.channel == null
          ? durations.defaultMs
          : durations.effectiveMs(target.channel!);

      check(
        'an External held button holds $target and restores Released',
        jack: _heldButton(target),
        (r) {
          r.ctrl(255);
          expect((at(r.live), at(r.stored)), (10000, 2000));
          r.ctrl(0);
          expect((at(r.live), at(r.stored)), (2000, 2000));
        },
      );

      check(
        'an External expression pedal sweeps $target end to end',
        jack: _expression(target),
        (r) {
          // The first reading seeds the position and writes nothing.
          r.ctrl(128, kind: PedalCtrlKind.expression);
          expect(at(r.live), 4000);
          expect(r.store.values.containsKey('looper.fade_durations'), isFalse);
          for (final (raw, milliseconds) in [
            (255, 30000),
            (0, 500),
            (51, 6500),
          ]) {
            r.ctrl(raw, kind: PedalCtrlKind.expression);
            expect(at(r.live), milliseconds);
            expect(at(r.stored), milliseconds);
          }
          if (target.channel case final channel?) {
            expect(r.live.defaultMs, 4000);
            expect(r.live.overrides.keys, [channel]);
          }
        },
      );
    }
  });
}
