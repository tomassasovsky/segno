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
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_mode_control.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_record_length_control.dart';
import '../helpers/fake_record_timing_control.dart';

const _decay = TrackDecayTarget(0);

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  int decayWrites = 0;
  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) {
    decayWrites++;
    return refuse
        ? EngineResult.notReady
        : super.setTrackOverdubFeedback(channel: channel, feedback: feedback);
  }
}

class _Store extends FakeKeyValueStore {
  int decayWrites = 0;
  @override
  Future<void> setInt(String key, int value) async {
    if (key.contains('overdub_decay')) decayWrites++;
    await super.setInt(key, value);
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('decay-test', 1);
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
                        target: _decay,
                        active: .2,
                        inactive: .6,
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
    settings = SettingsRepository(store: store);
    owner = PlaybackOptionsCubit(repository: looper, settings: settings);
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
      decayControl: owner,
      oneShotControl: owner,
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
  final _Engine engine;
  final LooperRepository looper;
  final store = _Store();
  final link = FakePedalLink();
  bool powerUp = false;
  late final SettingsRepository settings;
  late final PlaybackOptionsCubit owner;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  int get live =>
      owner.decaySnapshot!.effectivePercent(const DecayAddress.track(0));
  int? get durable => owner.durableDecaySnapshot.trackOverrides[0];
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
    cubit.beginMidiEdit(device: 'decay-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'decay-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _decay.canonicalString(),
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

  void ordinary(int? value) {
    unawaited(owner.setTrackOverdubDecay(channel: 0, percent: value));
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
  group('Decay shared dispatch', () {
    void check(String name, void Function(_Rig) body) => test(name, () {
      fakeAsync((clock) {
        final engine = _Engine()
          ..nextSnapshot = const EngineSnapshot.initial().copyWith(
            tracks: List.generate(8, (_) => const TrackSnapshot.empty()),
          );
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
        '${external ? 'External' : 'MIDI'} release keeps explicit '
        'authored zero',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          expect(r.live, external ? 20 : 75);
          expect(r.durable, external ? 60 : 0);
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          expect(r.looper.trackOverdubDecayOverrides[0], external ? 60 : 0);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} Use default retires stale '
        'cleanup without numeric override',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.ordinary(null);
          unawaited(r.owner.setOverdubDecay(40));
          r.pump();
          final writes = r.engine.decayWrites;
          expect(r.live, 40);
          expect(r.looper.trackOverdubDecayOverrides, isEmpty);
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          r.retire();
          expect(r.engine.decayWrites, writes);
          expect(r.live, 40);
          expect(r.looper.trackOverdubDecayOverrides, isEmpty);
          expect(r.store.values.containsKey('track_overdub_decay.0'), isFalse);
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} earlier ordinary value '
        'does not defeat authored release',
        (r) {
          r
            ..ordinary(40)
            ..bind();
          if (external) {
            r
              ..external(high: true)
              ..external(high: false);
          } else {
            r
              ..note(127)
              ..note(0);
          }
          expect(r.live, external ? 60 : 0);
        },
      );
    }
    check(
      'surviving MIDI and External hold keeps the survivor Released value',
      (r) {
        r
          ..bind()
          ..note(127)
          ..external(high: true);
        expect((r.live, r.durable), (20, 60));
        r.external(high: false);
        expect((r.live, r.durable), (75, 0));
        r.note(0);
        expect((r.live, r.durable), (0, 0));
      },
    );
    check(
      'accepted non-held value remains durable after older holders retire',
      (r) {
        r
          ..external(high: true)
          ..bind(behavior: MidiBehavior.toggle)
          ..note(127);
        expect((r.live, r.durable), (75, 75));
        r
          ..retire()
          ..external(high: false);
        expect((r.live, r.durable), (75, 75));
      },
    );
    check(
      'same-value reset preserves latch and a later physical press is fresh',
      (r) {
        r
          ..bind(behavior: MidiBehavior.toggle)
          ..note(127)
          ..note(0)
          ..ordinary(null)
          ..note(127);
        expect((r.live, r.durable), (0, 0));
        expect(r.looper.trackOverdubDecayOverrides, {0: 0});
      },
    );
    check('reset target does not discard a valid sibling in the same mapping', (
      r,
    ) {
      r
        ..bind(
          controls: [
            MidiParameterControl(
              key: _decay.canonicalString(),
              low: 0,
              high: .75,
            ),
            MidiParameterControl(
              key: const TrackDecayTarget(1).canonicalString(),
              low: .1,
              high: .6,
            ),
          ],
        )
        ..note(127)
        ..ordinary(null)
        ..note(0);
      expect(r.looper.trackOverdubDecayOverrides, {1: 10});
    });
    check('refused Use default retains the older held cleanup obligation', (r) {
      r
        ..bind()
        ..note(127)
        ..engine.refuse = true
        ..ordinary(null);
      expect(r.live, 75);
      r
        ..engine.refuse = false
        ..note(0);
      expect((r.live, r.durable), (0, 0));
    });
  });
}
