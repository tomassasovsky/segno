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
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_record_length_control.dart';
import '../helpers/fake_record_timing_control.dart';

const _once = TrackOneShotTarget(0);

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  int onceWrites = 0;
  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    onceWrites++;
    return refuse
        ? EngineResult.notReady
        : super.setOneShotMask(channels: channels, oneShot: oneShot);
  }
}

class _Store extends FakeKeyValueStore {}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('once-test', 1);
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
                        target: _once,
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
  bool get live =>
      owner.oneShotSnapshot!.effectiveOneShot(const OneShotAddress.track(0));
  bool? get durable => owner.durableOneShotSnapshot.trackOverrides[0];
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
    cubit.beginMidiEdit(device: 'once-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'once-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _once.canonicalString(),
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

  void ordinary({required bool? value}) {
    unawaited(owner.setTrackOneShot(channel: 0, oneShot: value));
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
  group('Once shared source dispatch', () {
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
        '${external ? 'External' : 'MIDI'} stores explicit '
        'authored Released choice',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          expect(r.live, !external);
          expect(r.durable, external);
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          expect(r.live, external);
          expect(r.owner.oneShotSnapshot!.trackOverrides, {0: external});
        },
      );
      check(
        '${external ? 'External' : 'MIDI'} Use default '
        'retires older cleanup only',
        (r) {
          r.bind();
          if (external) {
            r.external(high: true);
          } else {
            r.note(127);
          }
          r.ordinary(value: null);
          unawaited(r.owner.setDefaultOneShot(value: true));
          r.pump();
          if (external) {
            r.external(high: false);
          } else {
            r.note(0);
          }
          r.retire();
          expect(r.live, isTrue);
          expect(r.owner.oneShotSnapshot!.trackOverrides, isEmpty);
          expect(r.store.values.containsKey('track_one_shot.0'), isFalse);
        },
      );
    }
    check('latest accepted source wins including false and survivor Released', (
      r,
    ) {
      r
        ..bind()
        ..note(127)
        ..external(high: true);
      expect((r.live, r.durable), (false, true));
      r.external(high: false);
      expect((r.live, r.durable), (true, false));
      r.note(0);
      expect((r.live, r.durable), (false, false));
    });
    check('ordinary during hold retains durable priority after old release', (
      r,
    ) {
      r
        ..bind()
        ..note(127)
        ..ordinary(value: true)
        ..note(0);
      expect((r.live, r.durable), (true, true));
    });
    check('refused reset preserves older cleanup', (r) {
      r
        ..bind()
        ..note(127)
        ..engine.refuse = true
        ..ordinary(value: null);
      expect(r.live, isTrue);
      r
        ..engine.refuse = false
        ..note(0);
      expect((r.live, r.durable), (false, false));
    });
  });
}
