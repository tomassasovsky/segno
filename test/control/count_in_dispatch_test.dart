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

const _countIn = CountInValueTarget();

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  @override
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
  }) => refuse
      ? EngineResult.notReady
      : super.setRecordStartSettings(
          countInBars: countInBars,
          soundStart: soundStart,
          editKind: editKind,
        );
}

class _Store extends FakeKeyValueStore {
  bool fail = false;
  @override
  Future<void> setBool(String key, {required bool value}) async {
    await super.setBool(key, value: value);
    if (fail && key == 'looper.auto_record') {
      throw StateError('pair write failed');
    }
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('count-in-test', 1);
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
                        target: _countIn,
                        active: 2 / 3,
                        inactive: 0,
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
      device: () => 'count-in rig',
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
      recordStartControl: owner,
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
  final store = _Store();
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
  (int, bool) get live => (owner.state.countInBars, owner.state.soundStart);
  (int, bool) get durable => (
    owner.durableRecordStartSettings.countInBars,
    owner.durableRecordStartSettings.soundStart,
  );
  (Object?, Object?) get stored => (
    store.values['tempo.count_in_bars'],
    store.values['looper.auto_record'],
  );
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
    double low = 0,
    double high = 2 / 3,
  }) {
    final owner = Object();
    cubit.beginMidiEdit(device: 'count-in-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'count-in-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _countIn.canonicalString(),
                      low: low,
                      high: high,
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

  void ordinary(int bars) {
    unawaited(owner.setCountInBars(bars));
    pump();
  }

  void sound({required bool enabled}) {
    unawaited(owner.setSoundStart(enabled: enabled));
    pump();
  }

  void externalEndpoints({required double high, required double low}) {
    unawaited(
      cubit.setPedalSetup(
        cubit.state.pedalSetup.copyWith(
          external: ExternalPedalSetup(
            jacks: {
              PedalCtrlJack.ctrl1: ExternalJackSetup(
                single: ExternalSwitchSetup(
                  controls: ExternalControls(
                    parameters: [
                      ExternalParameter(
                        target: _countIn,
                        active: high,
                        inactive: low,
                        condition: ExternalValueCondition.heldReleased,
                      ),
                    ],
                  ),
                ),
              ),
            },
          ),
        ),
      ),
    );
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
  void check(String name, void Function(_Rig) body) => test(name, () {
    fakeAsync((clock) {
      final engine = _Engine();
      final looper = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
      expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
      final r = _Rig(clock, engine, looper);
      try {
        expect(r.live, (1, false));
        body(r);
      } finally {
        r.close();
        unawaited(looper.dispose());
        clock.flushMicrotasks();
      }
    });
  });

  for (final external in [false, true]) {
    final name = external ? 'External' : 'MIDI';
    void press(_Rig r, {required bool high}) {
      if (external) {
        r.external(high: high);
      } else {
        r.note(high ? 127 : 0);
      }
    }

    check('$name Held 2 and Released Off never resurrect prior Sound', (r) {
      r
        ..sound(enabled: true)
        ..bind();
      press(r, high: true);
      expect(r.live, (2, false));
      expect(r.durable, (0, false));
      expect(r.stored, (0, false));
      press(r, high: false);
      expect(r.live, (0, false));
    });

    check('$name Held Off preserves live Sound but Released 2 disables it', (
      r,
    ) {
      r
        ..sound(enabled: true)
        ..externalEndpoints(high: 0, low: 2 / 3)
        ..bind(high: 0, low: 2 / 3);
      press(r, high: true);
      expect(r.live, (0, true));
      expect(r.durable, (2, false));
      expect(r.stored, (2, false));
      press(r, high: false);
      expect(r.live, (2, false));
    });

    check('$name ordinary Sound at unchanged Off invalidates old release', (r) {
      r
        ..externalEndpoints(high: 0, low: 1)
        ..bind(high: 0, low: 1);
      press(r, high: true);
      expect(r.live, (0, false));
      expect(r.durable, (4, false));
      r.sound(enabled: true);
      press(r, high: false);
      r.retire();
      expect(r.live, (0, true));
      expect(r.durable, (0, true));
      expect(r.stored, (0, true));
    });

    check('$name same pair ordinary intent also supersedes Released', (r) {
      r
        ..externalEndpoints(high: 0, low: 1)
        ..bind(high: 0, low: 1);
      press(r, high: true);
      r.sound(enabled: false);
      press(r, high: false);
      expect(r.live, (0, false));
      expect(r.durable, (0, false));
    });

    check('$name ordinary before press does not override authored Released', (
      r,
    ) {
      r
        ..ordinary(4)
        ..bind();
      press(r, high: true);
      press(r, high: false);
      expect(r.live, (0, false));
      expect(r.durable, (0, false));
    });

    check('$name refused ordinary write gains no release priority', (r) {
      r.bind();
      press(r, high: true);
      r.fakeEngine.refuse = true;
      r.ordinary(4);
      expect(r.live, (2, false));
      r.fakeEngine.refuse = false;
      press(r, high: false);
      expect(r.live, (0, false));
      expect(r.stored, (0, false));
    });

    check(
      '$name capture refuses Held; eligible physical release '
      'keeps its semantics',
      (r) {
        r
          ..bind()
          ..capture(TrackState.recording);
        press(r, high: true);
        expect(r.live, (1, false));
        r.capture(TrackState.empty);
        // No retry of the refused Held occurs on eligibility change.
        expect(r.live, (1, false));
        press(r, high: false);
        // An External physical Released edge is independently authored. MIDI
        // momentary release only cleans an accepted MIDI hold.
        expect(r.live, (external ? 0 : 1, false));
      },
    );

    check('$name release during capture remains owed until eligible', (r) {
      r.bind();
      press(r, high: true);
      r.capture(TrackState.overdubbing);
      press(r, high: false);
      expect(r.live, (2, false));
      expect(r.fakeEngine.stopCalls, 0);
      Object? failure;
      unawaited(
        r.cubit.flushMidiConfiguration(retireControls: true).catchError(
          (Object error) {
            failure = error;
          },
        ),
      );
      r.pump();
      expect(failure, isA<ControlCleanupPending>());
      r.capture(TrackState.empty);
      var done = false;
      unawaited(
        r.cubit
            .flushMidiConfiguration(retireControls: true)
            .then((_) => done = true),
      );
      r.pump();
      expect(done, isTrue);
      expect(r.live, (0, false));
    });

    check('$name recovery retains cleanup until explicit recovery and flush', (
      r,
    ) {
      r.bind();
      press(r, high: true);
      r.store.fail = true;
      press(r, high: false);
      expect(r.owner.recordStartSnapshot, isNull);
      expect(r.live, (2, false));
      Object? failure;
      unawaited(
        r.cubit.flushMidiConfiguration(retireControls: true).catchError(
          (Object error) {
            failure = error;
          },
        ),
      );
      r.pump();
      expect(failure, isA<ControlCleanupPending>());
      r.store.fail = false;
      unawaited(r.owner.recoverRecordStart());
      r.pump();
      var done = false;
      unawaited(
        r.cubit
            .flushMidiConfiguration(retireControls: true)
            .then((_) => done = true),
      );
      r.pump();
      expect(done, isTrue);
      expect(r.live, (0, false));
      expect(r.stored, (0, false));
    });
  }

  check('latest accepted MIDI wins then exposes the surviving External hold', (
    r,
  ) {
    r
      ..bind(high: 1, low: 1 / 3)
      ..external(high: true)
      ..note(127);
    expect(r.live, (4, false));
    expect(r.durable, (1, false));
    r.note(0);
    expect(r.live, (2, false));
    expect(r.durable, (0, false));
    r.external(high: false);
    expect(r.live, (0, false));
  });

  check('latest accepted External wins then exposes the surviving MIDI hold', (
    r,
  ) {
    r
      ..bind(high: 1, low: 1 / 3)
      ..note(127)
      ..external(high: true);
    expect(r.live, (2, false));
    r.external(high: false);
    expect(r.live, (4, false));
    expect(r.durable, (1, false));
    r.note(0);
    expect(r.live, (1, false));
  });

  check('refused newer External hold does not gain priority over MIDI', (r) {
    r
      ..bind(high: 1, low: 1 / 3)
      ..note(127);
    r.fakeEngine.refuse = true;
    r.external(high: true);
    r.fakeEngine.refuse = false;
    r.note(0);
    expect(r.live, (1, false));
    r.external(high: false);
    // This new physical Released edge is distinct from rejected-held priority.
    expect(r.live, (0, false));
  });

  check('disconnect applies authored Released after a refused External Held', (
    r,
  ) {
    r.fakeEngine.refuse = true;
    r.external(high: true);
    expect(r.live, (1, false));
    r.fakeEngine.refuse = false;
    r.link.emit(
      const CtrlMessage(
        jack: PedalCtrlJack.ctrl1,
        kind: PedalCtrlKind.none,
        value: 0,
      ),
    );
    r.pump();
    expect(r.live, (0, false));
    expect(r.durable, (0, false));
  });

  check(
    'accepted non-held MIDI intent remains durable past older hold release',
    (r) {
      r
        ..bind(behavior: MidiBehavior.toggle, high: 1)
        ..external(high: true)
        ..note(127);
      expect(r.live, (4, false));
      expect(r.durable, (4, false));
      r
        ..retire()
        ..external(high: false);
      expect(r.live, (4, false));
      expect(r.durable, (4, false));
    },
  );

  check('relative detents advance through choices rather than numeric bars', (
    r,
  ) {
    r
      ..ordinary(2)
      ..bind(
        behavior: MidiBehavior.continuous,
        protocol: MidiProtocol.relative,
        high: 1,
      )
      ..note(1);
    expect(r.live, (4, false));
    r.note(127);
    expect(r.live, (2, false));
    r.note(127);
    expect(r.live, (1, false));
  });

  check('saving an assignment sends no pair command', (r) {
    final before = r.fakeEngine.recordStartRequests.length;
    r.bind(high: .8, low: .2);
    expect(r.fakeEngine.recordStartRequests, hasLength(before));
    r.note(127);
    expect(r.live, (2, false));
    r.note(0);
    expect(r.live, (1, false));
  });

  void nativeCheck(
    String name,
    void Function(
      _Rig,
      PumpedNativeEngine,
      void Function({required bool enabled}),
    )
    body,
  ) {
    test(
      name,
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
          var pumping = true;
          final callback = Timer.periodic(const Duration(milliseconds: 5), (_) {
            if (pumping) engine.pump(frames: 0);
          });
          final r = _Rig(clock, engine, looper);
          try {
            body(r, engine, ({required enabled}) => pumping = enabled);
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
  }

  nativeCheck(
    'native receipt precedes Count-in live and durable confirmation',
    (r, engine, pump) {
      r
        ..sound(enabled: true)
        ..bind();
      final revision = engine.snapshot().recordStartRevision;
      pump(enabled: false);
      r.note(127);
      expect(engine.commandsSettled, isFalse);
      expect(engine.snapshot().recordStartRevision, revision);
      expect(r.live, (0, true));
      expect(r.durable, (0, true));
      pump(enabled: true);
      r.pump();
      expect(engine.snapshot().recordStartRevision, greaterThan(revision));
      expect(r.live, (2, false));
      expect(r.durable, (0, false));
      r.note(0);
      expect(r.live, (0, false));
    },
  );

  nativeCheck(
    'native restart uses Released and rejects obsolete physical release',
    (r, engine, _) {
      r
        ..bind()
        ..note(127);
      expect(r.live, (2, false));
      r.looper.stopEngine();
      expect(
        r.looper.startEngine(
          const EngineConfig(
            sampleRate: 8000,
            inputChannels: 1,
            outputChannels: 1,
            maxLoopFrames: 32000,
          ),
        ),
        EngineResult.ok,
      );
      r.pump();
      expect(engine.snapshot().countInBars, 0);
      final revision = engine.snapshot().recordStartRevision;
      r.note(0);
      expect(engine.snapshot().recordStartRevision, revision);
      expect(r.live, (0, false));
      expect(r.durable, (0, false));
      r.note(127);
      expect(r.live, (2, false));
    },
  );

  nativeCheck(
    'native expression Save and seed are silent; movement selects choices',
    (r, engine, _) {
      final revision = engine.snapshot().recordStartRevision;
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: ExternalPedalSetup(
              jacks: {
                PedalCtrlJack.ctrl1: ExternalJackSetup(
                  type: ExternalJackType.expression,
                  expression: ExternalExpressionSetup(
                    calibration: ExpressionCalibration(heel: 0, toe: 255),
                    mappings: [ExpressionMapping(target: _countIn)],
                  ),
                ),
              },
            ),
          ),
        ),
      );
      r.pump();
      expect(engine.snapshot().recordStartRevision, revision);
      void position(int raw) {
        r.link.emit(
          CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.expression,
            value: raw,
          ),
        );
        r.pump();
      }

      position(128);
      expect(engine.snapshot().recordStartRevision, revision);
      for (final sample in [(0, 0), (85, 1), (170, 2), (255, 4)]) {
        position(sample.$1);
        expect(engine.snapshot().countInBars, sample.$2);
        expect(r.live, (sample.$2, false));
        expect(r.stored, (sample.$2, false));
      }
    },
  );
}
