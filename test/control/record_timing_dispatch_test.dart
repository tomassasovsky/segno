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
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_mode_control.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_decay_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_one_shot_control.dart';
import '../helpers/fake_record_length_control.dart';

const _timing = TrackRecordTimingTarget(0);

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) => refuse
      ? EngineResult.notReady
      : super.setRecordTimingSettings(
          defaultTiming: defaultTiming,
          rememberedDivision: rememberedDivision,
          trackOverrides: trackOverrides,
          editMask: editMask,
        );
}

class _Store extends FakeKeyValueStore {
  bool fail = false;
  @override
  Future<void> setInt(String key, int value) async {
    await super.setInt(key, value);
    if (fail && key == 'track_record_timing.7') {
      throw StateError('mutated scalar write failed');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (fail && key == 'track_record_timing.7') {
      throw StateError('rollback removal failed');
    }
    await super.remove(key);
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('timing-test', 1);
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
                        target: _timing,
                        active: 1,
                        inactive: 1 / 6,
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
    owner = RecordTimingSettings(repository: looper, settings: settings);
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
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: owner,
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
  final _Engine engine;
  final LooperRepository looper;
  final store = _Store();
  final link = FakePedalLink();
  bool powerUp = false;
  late final SettingsRepository settings;
  late final RecordTimingSettings owner;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  int get live => owner.recordTimingSnapshot!
      .effectiveTiming(
        const RecordTimingAddress.track(0),
      )
      .code;
  int? get durable => owner.durableRecordTimingSnapshot.trackOverrides[0]?.code;
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
    cubit.beginMidiEdit(device: 'timing-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'timing-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _timing.canonicalString(),
                      low: 0,
                      high: 2 / 3,
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

  void ordinary({required int? value}) {
    unawaited(
      owner.setTrackTiming(channel: 0, timing: RecordTiming.fromCode(value)),
    );
    pump();
  }

  void capture(TrackState state) {
    engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
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
  group('Record timing shared dispatch', () {
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
          body(r);
        } finally {
          r.close();
          unawaited(looper.dispose());
          clock.flushMicrotasks();
        }
      });
    });
    for (final external in [false, true]) {
      check(
        '${external ? 'External' : 'MIDI'} holds live and saves '
        'authored Released',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          expect(r.live, external ? 6 : 4);
          expect(r.durable, external ? 1 : 0);
          expect(r.store.values['track_record_timing.0'], external ? 1 : 0);
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          expect(r.live, external ? 1 : 0);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} retiring flush rejects owed '
        'cleanup until explicit retry succeeds',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.engine.refuse = true;
          Object? failure;
          var finished = false;
          unawaited(
            r.cubit
                .flushMidiConfiguration(retireControls: true)
                .then(
                  (_) => finished = true,
                  onError: (Object error) => failure = error,
                ),
          );
          r.pump();
          expect(finished, isFalse);
          expect(failure, isNotNull);
          expect(r.live, external ? 6 : 4);
          expect(r.durable, external ? 1 : 0);
          expect(r.engine.stopCalls, 0);
          r.engine.refuse = false;
          unawaited(
            r.cubit
                .flushMidiConfiguration(retireControls: true)
                .then(
                  (_) => finished = true,
                ),
          );
          r.pump();
          expect(finished, isTrue);
          expect(r.live, external ? 1 : 0);
          expect(r.engine.stopCalls, 0);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} retains owed release while '
        'owner is unavailable for scalar recovery',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.store.fail = true;
          unawaited(
            r.owner.setTrackTiming(channel: 7, timing: RecordTiming.bar),
          );
          r.pump();
          expect(r.owner.recordTimingSnapshot, isNull);
          if (external) {
            r.external(high: false);
          } else {
            r.retire();
          }
          expect(
            r.looper.trackRecordTimingOverrides[0]!.code,
            external ? 6 : 4,
          );
          expect(r.durable, external ? 1 : 0);
          r.store.fail = false;
          unawaited(r.owner.recoverRecordTiming());
          r.pump();
          unawaited(r.cubit.flushMidiConfiguration(retireControls: true));
          r.pump();
          expect(r.live, external ? 1 : 0);
          expect(r.store.values['track_record_timing.0'], external ? 1 : 0);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} Use default defeats old '
        'release and preserves inheritance',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.ordinary(value: null);
          unawaited(r.owner.setTiming(RecordTiming.bar));
          r.pump();
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          r.retire();
          expect(r.live, 2);
          expect(r.owner.recordTimingSnapshot!.trackOverrides, isEmpty);
          expect(r.store.values.containsKey('track_record_timing.0'), isFalse);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} capture retirement stays '
        'owed and retries at idle',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.capture(TrackState.recording);
          if (external) {
            r.external(high: false);
          } else {
            r.retire();
          }
          expect(r.live, external ? 6 : 4);
          expect(r.durable, external ? 1 : 0);
          expect(r.engine.stopCalls, 0);
          r.capture(TrackState.empty);
          expect(r.live, external ? 1 : 0);
          expect(r.engine.stopCalls, 0);
        },
      );
    }
    check('accepted MIDI toggle has no owed release at retiring flush', (r) {
      r
        ..bind(behavior: MidiBehavior.toggle)
        ..note(127);
      expect(r.live, 4);
      expect(r.durable, 4);
      r.engine.refuse = true;
      var finished = false;
      unawaited(
        r.cubit
            .flushMidiConfiguration(retireControls: true)
            .then(
              (_) => finished = true,
            ),
      );
      r.pump();
      expect(finished, isTrue);
      expect(r.live, 4);
      expect(r.durable, 4);
    });
    check('Multi preserves independent track timing controls', (r) {
      unawaited(r.looper.settleLengthSettings());
      r.pump();
      expect(r.looper.setLooperMode(LooperMode.multi), EngineResult.ok);
      r
        ..pump()
        ..bind()
        ..note(127);
      expect(r.live, 4);
      r.note(0);
      expect(r.live, 0);
    });
    check('refused press cannot erase older cleanup priority', (r) {
      r
        ..bind()
        ..note(127);
      r.engine.refuse = true;
      r.external(high: true);
      r.engine.refuse = false;
      r.note(0);
      expect(r.live, 0);
      expect(r.durable, 0);
    });
    check('relative input advances one accepted timing choice', (r) {
      r
        ..ordinary(value: 3)
        ..bind(
          behavior: MidiBehavior.continuous,
          protocol: MidiProtocol.relative,
        )
        ..note(1);
      expect(r.live, 4);
    });
  });
}
