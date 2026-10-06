import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show AudioEngine, PumpedNativeEngine, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_decay_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_one_shot_control.dart';
import '../helpers/fake_record_length_control.dart';
import '../helpers/fake_record_timing_control.dart';
import '../helpers/test_fade_settings.dart';

const _mode = ClickModeValueTarget();

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  @override
  EngineResult setClickMode(ClickMode mode) =>
      refuse ? EngineResult.notReady : super.setClickMode(mode);
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('mode-test', 1);
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

class _Rig {
  _Rig(this.clock, this.engine, this.looper) {
    store.values['pedal.setup'] = const PedalSetup()
        .copyWith(
          external: ExternalPedalSetup(
            jacks: {
              PedalCtrlJack.ctrl1: ExternalJackSetup(
                single: ExternalSwitchSetup(
                  controls: ExternalControls(
                    parameters: [
                      ExternalParameter(
                        target: _mode,
                        active: 1,
                        inactive: 1 / 3,
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
    store.values['looper.mode'] = LooperMode.free.code;
    settings = SettingsRepository(store: store);
    owner = TempoSettings(repository: looper, settings: settings);
    unawaited(owner.load());
    pump();
    midi = _Midi(settings);
    mix = MixSettingsCoordinator(
      repository: looper,
      persistence: SettingsMixPersistence(settings),
      device: () => 'click rig',
    );
    pedal = PedalRepository(link, clock: () => clock.elapsed);
    controller = ControllerRepository(sources: [ConsoleCtrlSource(pedal)]);
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    cubit = ControlCubit(
      fadeSettings: testFadeSettings(),
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: owner.clickModeControl,
      recordStartControl: owner.recordStartControl,
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: FakeRecordTimingControl(),
      takeLocked: () => powerUp,
      controller: controller,
      midiDevices: midi,
      midiClock: () => clock.elapsed,
    );
    link.hello();
    unawaited(cubit.load());
    clock.flushMicrotasks();
  }
  final FakeAsync clock;
  final AudioEngine engine;
  _Engine get fakeEngine => engine as _Engine;
  final LooperRepository looper;
  final store = FakeKeyValueStore();
  final link = FakePedalLink();
  bool powerUp = false;
  late final SettingsRepository settings;
  late final TempoSettings owner;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  int get live => owner.state.clickMode.code;
  int get durable => owner.clickModeOwner.durable.code;
  void pump() {
    for (var i = 0; i < 20; i++) {
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 5));
    }
    clock.flushMicrotasks();
  }

  void bind({
    MidiBehavior behavior = MidiBehavior.momentary,
    MidiProtocol protocol = MidiProtocol.standard,
    List<MidiControl>? controls,
  }) {
    final owner = Object();
    cubit.beginMidiEdit(device: 'mode-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'mode-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _mode.canonicalString(),
                      low: 0,
                      high: 1,
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

  void note(int value, {bool settle = true}) {
    midi.push(value);
    clock.flushMicrotasks();
    if (settle) pump();
  }

  void external({required bool high, bool settle = true}) {
    link.emit(
      CtrlMessage(
        jack: PedalCtrlJack.ctrl1,
        kind: PedalCtrlKind.switchPedal,
        value: high ? 255 : 0,
      ),
    );
    clock.flushMicrotasks();
    if (settle) pump();
  }

  void ordinary(ClickMode mode) {
    unawaited(owner.clickModeOwner.set(mode));
    pump();
  }

  void capture(TrackState state) {
    fakeEngine.nextSnapshot = fakeEngine.nextSnapshot.copyWith(
      looperMode: LooperMode.free,
      tracks: [
        TrackSnapshot(
          state: state,
          volume: 1,
          muted: false,
          lengthFrames: 0,
          undoDepth: 0,
          rms: 0,
          peak: 0,
        ),
        for (var c = 1; c < 8; c++) const TrackSnapshot.empty(),
      ],
    );
    // Exercise the real repository publication/Control eligibility listener.
    looper.setRecDub(enabled: false);
    pump();
  }

  void retire() {
    unawaited(cubit.setMidiControlEnabled(enabled: false));
    pump();
  }

  void close() {
    unawaited(cubit.close());
    pump();
    unawaited(owner.close());
    pump();
    unawaited(controller.dispose());
    unawaited(midi.dispose());
    unawaited(mix.close());
    unawaited(pedal.dispose());
    performance.dispose();
    clock.flushMicrotasks();
  }
}

void main() {
  void check(String name, void Function(_Rig) body) => test(
    name,
    () => fakeAsync((clock) {
      final engine = _Engine();
      final looper = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
      expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
      final r = _Rig(clock, engine, looper);
      try {
        body(r);
      } finally {
        r.close();
        unawaited(looper.dispose());
        clock.flushMicrotasks();
      }
    }),
  );
  test(
    'native External expression movement confirms modes without Save dispatch',
    () {
      fakeAsync((clock) {
        final engine = PumpedNativeEngine();
        final looper = LooperRepository(
          engine: engine,
          ticker: const Stream.empty(),
        );
        expect(
          looper.startEngine(
            const EngineConfig(
              sampleRate: 8000,
              inputChannels: 1,
              outputChannels: 1,
              maxLoopFrames: 32000,
            ),
          ),
          EngineResult.ok,
        );
        final callback = Timer.periodic(
          const Duration(milliseconds: 5),
          (_) => engine.pump(frames: 0),
        );
        final r = _Rig(clock, engine, looper);
        try {
          expect(
            r.owner.clickModeControl.clickModeSnapshot?.mode,
            ClickMode.recFirst,
          );
          final before = engine.snapshot().clickModeRevision;
          // The first physical report establishes contact position; it is not
          // movement and must not replay a saved mapping on attachment.
          r.link.emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.expression,
              value: 128,
            ),
          );
          r.pump();
          expect(engine.snapshot().clickModeRevision, before);
          var saved = false;
          unawaited(
            r.cubit
                .setPedalSetup(
                  r.cubit.state.pedalSetup.copyWith(
                    external: ExternalPedalSetup(
                      jacks: {
                        PedalCtrlJack.ctrl1: ExternalJackSetup(
                          type: ExternalJackType.expression,
                          expression: ExternalExpressionSetup(
                            calibration: ExpressionCalibration(
                              heel: 0,
                              toe: 255,
                            ),
                            mappings: [
                              ExpressionMapping(
                                target: const ClickModeValueTarget(),
                              ),
                            ],
                          ),
                        ),
                      },
                    ),
                  ),
                )
                .then((_) => saved = true),
          );
          r.pump();
          expect(saved, isTrue);
          expect(engine.snapshot().clickModeRevision, before);
          // Saving a changed configuration retires its old contact. Establish
          // the next physical position without replay, then send movement.
          r.link.emit(
            const CtrlMessage(
              jack: PedalCtrlJack.ctrl1,
              kind: PedalCtrlKind.expression,
              value: 128,
            ),
          );
          r.pump();
          expect(engine.snapshot().clickModeRevision, before);
          var revision = before;
          for (final sample in [
            (0, ClickMode.off),
            (255, ClickMode.playRec),
            (128, ClickMode.rec),
          ]) {
            r.link.emit(
              CtrlMessage(
                jack: PedalCtrlJack.ctrl1,
                kind: PedalCtrlKind.expression,
                value: sample.$1,
              ),
            );
            r.pump();
            expect(engine.commandsSettled, isTrue);
            expect(engine.snapshot().clickMode, sample.$2);
            expect(engine.snapshot().clickModeRevision, greaterThan(revision));
            revision = engine.snapshot().clickModeRevision;
            expect(r.owner.clickModeControl.clickModeSnapshot?.mode, sample.$2);
            expect(r.store.values['tempo.click_mode'], sample.$2.code);
          }
        } finally {
          r.close();
          callback.cancel();
          unawaited(looper.dispose());
          clock.flushMicrotasks();
        }
      });
    },
    tags: ['fuzz'],
    skip: Platform.environment['SEGNO_ENGINE_LIB'] == null,
  );
  for (final external in [false, true]) {
    void press(_Rig r, {required bool high}) {
      if (external) {
        r.external(high: high);
      } else {
        r.note(high ? 127 : 0);
      }
    }

    check(
      '${external ? "External" : "MIDI"} authored Held and Released '
      'share the confirmed mode owner',
      (r) {
        r.bind();
        press(r, high: true);
        expect(r.live, 3);
        expect(r.durable, external ? 2 : 0);
        expect(r.store.values['tempo.click_mode'], external ? 2 : 0);
        press(r, high: false);
        expect(r.live, external ? 2 : 0);
      },
    );
    check(
      '${external ? "External" : "MIDI"} refused cleanup blocks halt '
      'then retries once accepted',
      (r) {
        r.bind();
        press(r, high: true);
        r.fakeEngine.refuse = true;
        Object? error;
        var done = false;
        unawaited(
          r.cubit
              .flushMidiConfiguration(retireControls: true)
              .then((_) => done = true, onError: (Object e) => error = e),
        );
        r.pump();
        expect(error, isA<ControlCleanupPending>());
        expect(done, isFalse);
        expect(r.live, 3);
        expect(r.fakeEngine.stopCalls, 0);
        r.fakeEngine.refuse = false;
        unawaited(
          r.cubit
              .flushMidiConfiguration(retireControls: true)
              .then((_) => done = true),
        );
        r.pump();
        expect(done, isTrue);
        expect(r.live, external ? 2 : 0);
      },
    );
    check(
      '${external ? "External" : "MIDI"} accepted ordinary mode '
      'defeats old release',
      (r) {
        r.bind();
        press(r, high: true);
        r.ordinary(ClickMode.rec);
        press(r, high: false);
        r.retire();
        expect(r.live, 1);
        expect(r.durable, 1);
        expect(r.store.values['tempo.click_mode'], 1);
      },
    );
    check(
      '${external ? "External" : "MIDI"} capture refuses acquisition '
      'without adding a holder',
      (r) {
        r
          ..bind()
          ..capture(TrackState.recording);
        press(r, high: true);
        expect(r.live, 2);
        expect(r.durable, 2);
        r.capture(TrackState.empty);
        press(r, high: false);
        expect(r.live, 2);
      },
    );
  }
}
