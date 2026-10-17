import 'dart:async';
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
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/model/record_length.dart';
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
import '../helpers/fake_record_start_control.dart';
import '../helpers/fake_record_timing_control.dart';
import '../helpers/test_fade_settings.dart';

const _length = TrackRecordLengthTarget(0);

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  @override
  EngineResult setTrackLengthPresets(List<int> bars) =>
      refuse ? EngineResult.notReady : super.setTrackLengthPresets(bars);
}

class _Store extends FakeKeyValueStore {}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('length-test', 1);
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
                        target: _length,
                        active: .25,
                        inactive: .125,
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
    owner = RecordSettings(repository: looper, settings: settings);
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
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    final ownedFade = testFadeSettings();
    cubit = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      takeLocked: () => powerUp,
      controller: controller,
      midiDevices: midi,
      midiClock: () => clock.elapsed,
      fadeSettings: ownedFade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: owner,
        recordTiming: FakeRecordTimingControl(),
        fade: ownedFade,
      ),
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
  late final RecordSettings owner;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  int get live => owner.recordLengthSnapshot!.effectiveBars(
    const RecordLengthAddress.track(0),
  );
  int? get durable => owner.durableRecordLengthSnapshot.trackOverrides[0];
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
    cubit.beginMidiEdit(device: 'length-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'length-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _length.canonicalString(),
                      low: 0,
                      high: .75,
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
    unawaited(owner.setTrackRecordLength(channel: 0, bars: value));
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
  group('Record length shared dispatch', () {
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
          expect(r.live, external ? 16 : 48);
          expect(r.durable, external ? 8 : 0);
          expect(r.store.values['tempo.length_preset.0'], external ? 8 : 0);
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          expect(r.live, external ? 8 : 0);
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
          unawaited(r.owner.setDefaultLengthBars(12));
          r.pump();
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          r.retire();
          expect(r.live, 12);
          expect(r.owner.recordLengthSnapshot!.trackOverrides, isEmpty);
          expect(r.store.values.containsKey('tempo.length_preset.0'), isFalse);
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
          expect(r.live, external ? 16 : 48);
          expect(r.durable, external ? 8 : 0);
          expect(r.engine.stopCalls, 0);
          r.capture(TrackState.empty);
          expect(r.live, external ? 8 : 0);
          expect(r.engine.stopCalls, 0);
        },
      );
    }
    check(
      'accepted Multi retires track holder and leaving Multi reveals Released',
      (r) {
        r
          ..bind()
          ..note(127);
        unawaited(r.owner.setLooperMode(LooperMode.multi));
        r.pump();
        expect(r.owner.recordLengthSnapshot!.trackOverrides, {0: 0});
        r.note(0);
        unawaited(r.owner.setLooperMode(LooperMode.free));
        r.pump();
        expect(r.live, 0);
      },
    );
    for (final source in ['MIDI latch', 'MIDI hold', 'External hold']) {
      check('a $source on a track length released after entering Multi '
          'completes power-off', (r) {
        r.bind(
          behavior: source == 'MIDI latch'
              ? MidiBehavior.toggle
              : MidiBehavior.momentary,
        );
        if (source == 'External hold') {
          r.external(high: true);
        } else {
          r.note(127);
        }
        unawaited(r.owner.setLooperMode(LooperMode.multi));
        r.pump();
        // Multi supersedes every track's claim: the hold owes no release.
        switch (source) {
          case 'MIDI latch':
            r.note(127);
          case 'MIDI hold':
            r.note(0);
          default:
            r.external(high: false);
        }
        Object? failure;
        var flushed = false;
        unawaited(
          r.cubit
              .flushMidiConfiguration(retireControls: true)
              .then((_) => flushed = true, onError: (Object e) => failure = e),
        );
        r.pump();
        expect(failure, isNull);
        expect(flushed, isTrue);
        expect(r.engine.stopCalls, 0);
      });
    }
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
    check('relative input advances one bar with no fractional endpoint', (r) {
      r
        ..ordinary(value: 8)
        ..bind(
          behavior: MidiBehavior.continuous,
          protocol: MidiProtocol.relative,
        )
        ..note(1);
      expect(r.live, 9);
    });
  });
}
