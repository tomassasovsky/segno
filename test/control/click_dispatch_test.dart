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
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

const _click = ClickVolumeTarget();

class _Engine extends PumpedNativeEngine {
  bool refuseClick = false;
  int clickWrites = 0;
  @override
  EngineResult setClickVolume(double volume) {
    clickWrites++;
    return refuseClick ? EngineResult.notReady : super.setClickVolume(volume);
  }
}

class _Store extends FakeKeyValueStore {
  int failingClickWrites = 0;
  @override
  Future<void> setDouble(String key, double value) async {
    if (key == 'tempo.click_volume' && failingClickWrites > 0) {
      failingClickWrites--;
      throw StateError('Click storage refused');
    }
    await super.setDouble(key, value);
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('click-test', 1);
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
    store.values['tempo.click_volume'] = .5;
    store.values['pedal.setup'] = const PedalSetup()
        .copyWith(
          external: ExternalPedalSetup(
            jacks: {
              PedalCtrlJack.ctrl1: ExternalJackSetup(
                single: ExternalSwitchSetup(
                  controls: ExternalControls(
                    parameters: [
                      ExternalParameter(
                        target: _click,
                        active: .375,
                        inactive: .2,
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
    tempo = TempoCubit(repository: looper, settings: settings);
    unawaited(tempo.load());
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
      decayControl: FakeDecayControl(),
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      clickVolumeControl: tempo,
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
  late final TempoCubit tempo;
  late final _Midi midi;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  double get live => looper.state.transport.clickVolume;
  double get durable => tempo.durableClickVolume;
  void pump() {
    for (var i = 0; i < 20; i++) {
      clock.flushMicrotasks();
      engine.pump(frames: 0);
      clock.elapse(const Duration(milliseconds: 5));
    }
    clock.flushMicrotasks();
  }

  void bind({
    MidiBehavior behavior = MidiBehavior.momentary,
    MidiProtocol protocol = MidiProtocol.standard,
    List<MidiControl>? controls,
  }) {
    final owner = Object();
    cubit.beginMidiEdit(device: 'click-test', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'click-test',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: 21,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: _click.canonicalString(),
                      low: .125,
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

  void ordinary(double value) {
    unawaited(tempo.setClickVolume(value));
    pump();
  }

  void retire() {
    unawaited(cubit.setMidiControlEnabled(enabled: false));
    pump();
  }

  void close() {
    unawaited(cubit.close());
    pump();
    unawaited(tempo.close());
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
  late _Engine engine;
  late LooperRepository looper;
  setUp(() async {
    engine = _Engine();
    looper = LooperRepository(engine: engine);
    expect(
      looper.startEngine(
        const EngineConfig(
          inputChannels: 2,
          outputChannels: 2,
          maxLoopFrames: 8192,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    await looper.settleMixSettings();
    await looper.settleClickVolume();
  });
  tearDown(() async => looper.dispose());
  void check(String name, void Function(_Rig) body) => test(
    name,
    () => fakeAsync((clock) {
      final r = _Rig(clock, engine, looper);
      try {
        body(r);
      } finally {
        r.close();
      }
    }),
    skip: Platform.environment['SEGNO_ENGINE_LIB'] == null
        ? 'Requires native pump library'
        : null,
  );

  check('Click MIDI admission stays pending before real callback', (r) {
    r
      ..bind()
      ..note(127, settle: false);
    expect(r.live, .5);
    expect(r.tempo.clickVolume, .5);
    expect(r.store.values['tempo.click_volume'], .25);
    r.pump();
    expect(r.live, 1.5);
    expect(r.durable, .25);
    r.note(0);
    expect(r.live, .25);
  });
  check('Click release received before native high receipt is not lost', (r) {
    r
      ..bind()
      ..note(127, settle: false)
      ..note(0, settle: false)
      ..pump();
    expect(r.live, .25);
    expect(r.durable, .25);
  });
  check('Click surviving MIDI and External holds retain their own low', (r) {
    r
      ..bind()
      ..note(127)
      ..external(high: true);
    expect(r.live, .75);
    expect(r.durable, .4);
    r.external(high: false);
    expect(r.live, 1.5);
    expect(r.durable, .25);
    r.note(0);
    expect(r.live, .25);
    expect(r.durable, .25);
  });
  check('Click older ordinary baseline cannot defeat later authored low', (r) {
    r
      ..ordinary(1)
      ..bind()
      ..note(127)
      ..note(0);
    expect(r.live, .25);
    expect(r.durable, .25);
    r
      ..ordinary(1)
      ..external(high: true)
      ..external(high: false);
    expect(r.live, closeTo(.4, 1e-6));
    expect(r.durable, .4);
  });
  check('Click newer ordinary and same-value intent supersede old release', (
    r,
  ) {
    r
      ..bind()
      ..note(127)
      ..ordinary(1.5)
      ..note(0);
    expect(r.live, 1.5);
    expect(r.durable, 1.5);
    r
      ..external(high: true)
      ..ordinary(1.25)
      ..external(high: false);
    expect(r.live, 1.25);
    expect(r.durable, 1.25);
  });
  check(
    'Click non-held toggle survives retirement and older External release',
    (r) {
      r
        ..bind(behavior: MidiBehavior.toggle)
        ..external(high: true)
        ..note(127);
      expect(r.live, 1.5);
      expect(r.durable, 1.5);
      r
        ..retire()
        ..external(high: false);
      expect(r.live, 1.5);
      expect(r.durable, 1.5);
      r.external(high: true);
      expect(r.durable, .4);
      r.external(high: false);
      expect(r.live, closeTo(.4, 1e-6));
    },
  );
  check('Click refused native press gains no low projection', (r) {
    r.bind();
    engine.refuseClick = true;
    r.note(127);
    expect(r.live, .5);
    expect(r.durable, .5);
    expect(r.store.values['tempo.click_volume'], .5);
    engine.refuseClick = false;
    r.note(0);
    expect(r.live, .5);
  });
  check('Click failed scalar press does not acquire priority over External', (
    r,
  ) {
    r
      ..bind()
      ..external(high: true)
      ..store.failingClickWrites = 1
      ..note(127);
    expect(r.live, .75);
    expect(r.durable, .4);
    r
      ..note(0)
      ..external(high: false);
    expect(r.live, closeTo(.4, 1e-6));
  });
  check('Click refused release retains obligation and same-source repress', (
    r,
  ) {
    r
      ..bind()
      ..note(127);
    engine.refuseClick = true;
    r.note(0);
    expect(r.live, 1.5);
    expect(r.durable, .25);
    engine.refuseClick = false;
    r
      ..note(127)
      ..pump();
    expect(r.live, 1.5);
    r.note(0);
    expect(r.live, .25);
  });
  check('Click relative step uses normalized gain law', (r) {
    r
      ..ordinary(1)
      ..bind(
        behavior: MidiBehavior.continuous,
        protocol: MidiProtocol.relative,
        controls: [
          MidiParameterControl(key: _click.canonicalString(), low: 0, high: 1),
        ],
      )
      ..note(1);
    expect(r.live, closeTo(1.02, 1e-6));
    r.note(127);
    expect(r.live, closeTo(1, 1e-6));
    r.note(64);
    expect(r.live, 0);
    r.note(63);
    expect(r.live, closeTo(1.26, 1e-6));
  });
  check(
    'Click absolute full range and missing sibling remain independently valid',
    (r) {
      r
        ..bind(
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: _click.canonicalString(),
              low: 0,
              high: 1,
            ),
            MidiParameterControl(
              key: const TrackVolumeTarget(999).canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        )
        // Absolute control first crosses the accepted .25 normalized pickup.
        ..note(32)
        ..note(127);
      expect(r.live, 2);
      r.note(64);
      expect(r.live, closeTo(128 / 127, 1e-6));
      r.note(0);
      expect(r.live, 0);
    },
  );
  check('power confirmation blocks new values but admits held release', (r) {
    r
      ..bind()
      ..note(127)
      ..powerUp = true
      ..note(0);
    expect(r.live, .25);
    r.note(127);
    expect(r.live, .25);
    r
      ..powerUp = false
      ..note(0)
      ..note(127);
    expect(r.live, 1.5);
  });
  check('halt cutoff retires holders and blocks post-flush fresh writes', (r) {
    r
      ..bind()
      ..note(127)
      ..powerUp = true;
    var flushed = false;
    unawaited(
      r.cubit
          .flushMidiConfiguration(retireControls: true)
          .then((_) => flushed = true),
    );
    r.pump();
    expect(flushed, isTrue);
    expect(r.live, .25);
    r
      ..note(0)
      ..note(127)
      ..external(high: true)
      ..external(high: false);
    expect(r.live, .25);
    expect(r.store.values['tempo.click_volume'], .25);
    r
      ..powerUp = false
      ..note(0)
      ..note(127);
    expect(r.live, 1.5);
  });
  for (final midi in [true, false]) {
    check('halt Retry retains refused ${midi ? "MIDI" : "External"} cleanup', (
      r,
    ) {
      r.bind();
      if (midi) {
        r.note(127);
      } else {
        r.external(high: true);
      }
      r.powerUp = true;
      engine.refuseClick = true;
      unawaited(r.cubit.flushMidiConfiguration(retireControls: true));
      r.pump();
      ClickVolumeOutcome? outcome;
      unawaited(r.tempo.flushClickVolume().then((v) => outcome = v));
      r.pump();
      expect(outcome!.isOk, isFalse);
      engine.refuseClick = false;
      unawaited(r.tempo.recoverClickVolume());
      r.pump();
      unawaited(r.cubit.flushMidiConfiguration(retireControls: true));
      r.pump();
      expect(r.live, closeTo(midi ? .25 : .4, 1e-6));
      unawaited(r.tempo.flushClickVolume().then((v) => outcome = v));
      r.pump();
      expect(outcome!.isOk, isTrue);
    });
  }
  check('Click fresh input required after Remote retirement', (r) {
    r
      ..bind()
      ..note(127)
      ..retire();
    expect(r.live, .25);
    unawaited(r.cubit.setMidiControlEnabled(enabled: true));
    r.pump();
    expect(r.live, .25);
    r
      ..note(0)
      ..note(127);
    expect(r.live, 1.5);
  });
}
