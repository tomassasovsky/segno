import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_client/testing.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/playback_settings.dart';
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
import '../helpers/fake_record_start_control.dart';
import '../helpers/fake_record_timing_control.dart';
import '../helpers/test_fade_settings.dart';

const _pedal = MidiDevice(id: 'pedal', name: 'Foot controller');
const _keys = MidiDevice(id: 'keys', name: 'Keyboard');

/// Every connected MIDI device feeds the mappings learned from it, and only
/// those (#1040): a real `MidiDeviceRepository` over fake captures drives a
/// real `ControlCubit`, with Decay as the mapped value.
class _Rig {
  _Rig(this.clock, this.engine, this.looper) {
    settings = SettingsRepository(store: store);
    owner = PlaybackSettings(repository: looper, settings: settings);
    unawaited(owner.load());
    pump();
    midi = MidiDeviceRepository(
      captures: () {
        final capture = FakeMidiCapture(devices: () => plugged);
        captures.add(capture);
        return capture;
      },
      settings: settings,
      pollInterval: Duration.zero,
    );
    mix = MixSettingsCoordinator(
      repository: looper,
      persistence: SettingsMixPersistence(settings),
      device: () => 'devices rig',
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
      controller: controller,
      midiDevices: midi,
      midiClock: () => clock.elapsed,
      fadeSettings: ownedFade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: owner.decayControl,
        oneShot: owner.oneShotControl,
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: ownedFade,
      ),
    );
    link.hello();
    unawaited(cubit.load());
    pump();
  }

  final FakeAsync clock;
  final FakeAudioEngine engine;
  final LooperRepository looper;
  final store = FakeKeyValueStore();
  final link = FakePedalLink();
  final captures = <FakeMidiCapture>[];
  List<MidiDevice> plugged = const [_pedal, _keys];
  late final SettingsRepository settings;
  late final PlaybackSettings owner;
  late final MidiDeviceRepository midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;

  int decay(int channel) => owner.decayControl.decaySnapshot!.effectivePercent(
    DecayAddress.track(channel),
  );

  void pump() {
    for (var i = 0; i < 20; i++) {
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 5));
    }
    clock.flushMicrotasks();
  }

  /// Saves a momentary mapping of [device]'s CC [number] to track
  /// [channel]'s Decay, 0 released and 75 held.
  void bind(String device, {required int number, required int channel}) {
    final owner = Object();
    cubit.beginMidiEdit(device: device, owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: device,
                kind: ControllerSourceKind.midiCc,
                number: number,
              ),
              behavior: MidiBehavior.momentary,
              controls: [
                MidiParameterControl(
                  key: TrackDecayTarget(channel).canonicalString(),
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

  /// [device] sends CC [number] at [value].
  void send(String device, int number, int value) {
    captures
        .lastWhere((capture) => capture.session?.device == device)
        .send(
          RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: number,
            value: value,
          ),
        );
    pump();
  }

  void replug(List<MidiDevice> devices) {
    plugged = devices;
    midi.refresh();
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
      final engine = FakeAudioEngine()
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

  check('a mapping fires only from the device it was learned from', (r) {
    // The keyboard's sustain pedal sends the same CC.
    r
      ..bind('pedal', number: 64, channel: 0)
      ..send('keys', 64, 127);
    expect(r.decay(0), 0);

    r.send('pedal', 64, 127);
    expect(r.decay(0), 75);
    r.send('pedal', 64, 0);
    expect(r.decay(0), 0);
  });

  check('every connected device feeds its own mappings at once', (r) {
    r
      ..bind('pedal', number: 21, channel: 0)
      ..bind('keys', number: 21, channel: 1);
    // The page shows the pedal; the keyboard still feeds its mapping.
    unawaited(r.midi.select('pedal'));
    r
      ..pump()
      ..send('keys', 21, 127);
    expect((r.decay(0), r.decay(1)), (0, 75));
    r.send('pedal', 21, 127);
    expect((r.decay(0), r.decay(1)), (75, 75));
  });

  check('unplugging one device releases only what it holds', (r) {
    r
      ..bind('pedal', number: 21, channel: 0)
      ..bind('keys', number: 21, channel: 1)
      ..send('pedal', 21, 127)
      ..send('keys', 21, 127);
    expect((r.decay(0), r.decay(1)), (75, 75));

    r.replug(const [_pedal]);

    expect((r.decay(0), r.decay(1)), (75, 0));
    r.send('pedal', 21, 0);
    expect(r.decay(0), 0);
  });

  check('a replugged device feeds its mappings again', (r) {
    r
      ..bind('keys', number: 21, channel: 1)
      ..replug(const [_pedal])
      ..replug(const [_pedal, _keys]);
    expect(r.midi.sessions['keys'], const MidiInputSession('keys', 2));

    r.send('keys', 21, 127);
    expect(r.decay(1), 75);
  });

  check('Learn hears only the device being edited', (r) {
    final owner = Object();
    r.cubit
      ..beginMidiEdit(device: 'pedal', owner: owner)
      ..startMidiLearn(MidiProtocol.standard, owner: owner);

    r.send('keys', 30, 127);
    expect(r.cubit.state.midiEdit!.learn!.reading, isNull);

    r.send('pedal', 31, 127);
    final source = r.cubit.state.midiEdit!.learn!.reading!.source;
    expect((source.device, source.number), ('pedal', 31));
    r.cubit.endMidiEdit(owner);
  });

  check('editing one device keeps the other device level readings', (r) {
    r
      ..bind('pedal', number: 21, channel: 0)
      ..bind('keys', number: 22, channel: 1)
      ..send('pedal', 21, 100)
      ..send('keys', 22, 90);
    expect(
      r.cubit.state.midiLevels.keys.map((source) => source.device).toSet(),
      {'pedal', 'keys'},
    );

    final owner = Object();
    r.cubit.beginMidiEdit(device: 'keys', owner: owner);
    r.pump();

    expect(
      r.cubit.state.midiLevels.keys.map((source) => source.device).toSet(),
      {'pedal'},
    );
    r.cubit.endMidiEdit(owner);
  });
}
