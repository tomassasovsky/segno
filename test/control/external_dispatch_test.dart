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
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart'
    show FxOwner, FxRecipe, PumpedNativeEngine;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

const _chain = FxChainTarget(FxAddress(stage: FxStage.track));
const _slot = FxSlotTarget(
  address: FxAddress(stage: FxStage.track),
  slotId: 'drive',
);
const _param = FxParamTarget(
  address: FxAddress(stage: FxStage.track),
  slotId: 'drive',
  param: 0,
);

class _RefusingEngine extends PumpedNativeEngine {
  int taps = 0;
  @override
  EngineResult tapTempo() {
    taps++;
    return super.tapTempo();
  }

  bool refuseRecipes = false;
  int refused = 0;

  @override
  EngineResult setFxRecipe({
    required FxOwner owner,
    required FxRecipe recipe,
    required int revision,
    int channel = 0,
    int lane = 0,
  }) {
    if (refuseRecipes) {
      refused++;
      return EngineResult.notReady;
    }
    return super.setFxRecipe(
      owner: owner,
      recipe: recipe,
      revision: revision,
      channel: channel,
      lane: lane,
    );
  }
}

class _Store extends FakeKeyValueStore {
  bool failSetup = false;
  bool failMidi = false;
  bool failMix = false;
  int failMixWrites = 0;
  Completer<void>? fxGate;
  Completer<void>? monitorModeGate;
  Completer<void>? monitorFxGate;
  @override
  Future<void> setString(String key, String value) async {
    if (key == 'mix_settings' && (failMix || failMixWrites > 0)) {
      if (failMixWrites > 0) failMixWrites--;
      throw StateError('mix storage refused');
    }
    if (key.startsWith('track_fx_chain.')) await fxGate?.future;
    if (key == 'monitor_input_mode.0') await monitorModeGate?.future;
    if (key == 'monitor_fx.0') await monitorFxGate?.future;
    if (key == 'midi.configuration' && failMidi) {
      throw StateError('MIDI storage refused');
    }
    if (key == 'pedal.setup' && failSetup) {
      throw StateError('setup storage refused');
    }
    await super.setString(key, value);
  }
}

class _Midi extends MidiDeviceRepository {
  _Midi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);
  final inputs = StreamController<MidiInputMessage>.broadcast();
  @override
  MidiInputSession get session => const MidiInputSession('test-midi', 1);
  @override
  Stream<MidiInputMessage> get messages => inputs.stream;
  void push(RawControllerInput input, {int? timestampMicros}) => inputs.add(
    MidiInputMessage(session, input, timestampMicros: timestampMicros),
  );
  @override
  Future<void> dispose() async {
    await inputs.close();
    await super.dispose();
  }
}

class _Rig {
  _Rig(
    this.clock,
    this.engine,
    this.looper,
    ExternalJackSetup setup, {
    bool initialOn = false,
    String? initialMidiRaw,
  }) {
    if (initialMidiRaw != null) {
      store.values['midi.configuration'] = initialMidiRaw;
    }
    store.values['pedal.setup'] = const PedalSetup()
        .copyWith(
          external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: setup})
              .withLogicalOn(
                const PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip),
                on: initialOn,
              ),
        )
        .encode();
    settings = SettingsRepository(store: store);
    midi = _Midi(settings);
    mix = MixSettingsCoordinator(
      repository: looper,
      persistence: SettingsMixPersistence(settings),
      device: () => 'dispatch test rig',
    );
    pedal = PedalRepository(link, clock: () => clock.elapsed);
    controller = ControllerRepository(
      sources: [ConsoleCtrlSource(pedal)],
    );
    performance = PerformanceRepository(
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    fx = FxChainPersistence(looper: looper);
    cubit = ControlCubit(
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: FakeRecordTimingControl(),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      recordStartControl: FakeRecordStartControl(),
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: fx,
      midiDevices: midi,
      midiClock: () => clock.elapsed,
      controller: controller,
    );
    link.hello();
    unawaited(cubit.load());
    clock.flushMicrotasks();
  }
  final FakeAsync clock;
  final PumpedNativeEngine engine;
  final LooperRepository looper;
  final store = _Store();
  final link = FakePedalLink();
  late final _Midi midi;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;
  late final FxChainPersistence fx;

  void bindMidi({
    int id = 21,
    String? target,
    double low = 0,
    double high = 1,
    List<MidiControl>? controls,
    MidiProtocol protocol = MidiProtocol.standard,
    MidiBehavior behavior = MidiBehavior.momentary,
  }) {
    final owner = Object();
    cubit.beginMidiEdit(device: 'test-midi', owner: owner);
    unawaited(
      cubit
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'test-midi',
                protocol: protocol,
                kind: ControllerSourceKind.midiCc,
                number: id,
              ),
              behavior: behavior,
              controls:
                  controls ??
                  [
                    MidiParameterControl(
                      key: target ?? _chain.canonicalString(),
                      low: switch (ControlValueTarget.tryParse(target ?? '')) {
                        final MixValueTarget mix => mix.fromDomain(low),
                        _ => low,
                      },
                      high: switch (ControlValueTarget.tryParse(target ?? '')) {
                        final MixValueTarget mix => mix.fromDomain(high),
                        _ => high,
                      },
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
    clock.flushMicrotasks();
    settle();
  }

  void midiValue(int value, {int id = 21}) {
    midi.push(
      RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: id,
        value: value,
      ),
    );
    clock.flushMicrotasks();
    settle();
  }

  void sample(
    int value, {
    PedalCtrlKind kind = PedalCtrlKind.switchPedal,
    PedalCtrlJack jack = PedalCtrlJack.ctrl1,
  }) {
    link.emit(CtrlMessage(jack: jack, kind: kind, value: value));
    clock.flushMicrotasks();
  }

  void settle() {
    for (var i = 0; i < 20; i++) {
      engine.pump(frames: 0);
      clock
        ..elapse(const Duration(milliseconds: 5))
        ..flushMicrotasks();
    }
  }

  void close() {
    unawaited(cubit.close());
    settle();
    unawaited(controller.dispose());
    unawaited(midi.dispose());
    unawaited(mix.close());
    unawaited(pedal.dispose());
    performance.dispose();
    clock.flushMicrotasks();
  }
}

void main() {
  final skip = Platform.environment['SEGNO_ENGINE_LIB'] == null
      ? 'Requires the native pump library'
      : null;
  late _RefusingEngine engine;
  late LooperRepository looper;
  setUp(() async {
    engine = _RefusingEngine();
    looper = LooperRepository(engine: engine);
    expect(
      looper.startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 2,
          outputChannels: 2,
          maxLoopFrames: 8192,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    await looper.settleMixSettings();
    expect(
      looper.setTrackEffects(
        channel: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive, slotId: 'drive')],
        chainEnabled: false,
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    await looper.settleFxRecipes();
  });
  tearDown(() async => looper.dispose());

  void check(
    String name,
    ExternalJackSetup setup,
    void Function(_Rig) body, {
    bool initialOn = false,
    String? initialMidiRaw,
  }) {
    test(name, () {
      fakeAsync((clock) {
        final rig = _Rig(
          clock,
          engine,
          looper,
          setup,
          initialOn: initialOn,
          initialMidiRaw: initialMidiRaw,
        );
        try {
          body(rig);
        } finally {
          rig.close();
        }
      });
    }, skip: skip);
  }

  ExternalJackSetup button(
    List<ExternalActivation> activations, {
    List<ExternalParameter> parameters = const [],
  }) => ExternalJackSetup(
    single: ExternalSwitchSetup(
      controls: ExternalControls(
        activations: activations,
        parameters: parameters,
      ),
    ),
  );

  check(
    'Mixer equal unity reset supersedes actual MIDI Held Released claim',
    ExternalJackSetup.empty,
    (r) {
      r
        ..bindMidi(
          target: const MonitorVolumeTarget(0).canonicalString(),
          low: .2,
        )
        ..midiValue(127);
      expect(looper.monitorVolume(0), 1);
      expect(r.mix.durableSnapshot.monitorLevels[0], .2);
      r.cubit
        ..setMode(InteractionMode.mixer)
        ..selectFootMixerDomain(FootMixerDomain.inputs);
      unawaited(r.cubit.resetFootMixerGain());
      r.settle();
      expect(r.mix.durableSnapshot.monitorLevels[0], 1);
      r.midiValue(0);
      expect(looper.monitorVolume(0), 1);
    },
  );

  check(
    'External saved Mixer hold enters once and consumes release',
    const ExternalJackSetup(
      single: ExternalSwitchSetup(
        gestures: ControlGesturePair(hold: ModeAction(InteractionMode.mixer)),
      ),
    ),
    (r) {
      r.sample(255);
      r.clock.elapse(const Duration(milliseconds: 801));
      r.settle();
      expect(r.cubit.state.mode, InteractionMode.mixer);
      r
        ..sample(0)
        ..settle();
      expect(r.cubit.state.mode, InteractionMode.mixer);
    },
  );

  check(
    'MIDI saved Mixer function enters and release does not toggle it',
    ExternalJackSetup.empty,
    (r) {
      r
        ..bindMidi(controls: [MidiActionControl(key: 'mode:mixer')])
        ..midiValue(127);
      expect(r.cubit.state.mode, InteractionMode.mixer);
      r.midiValue(0);
      expect(r.cubit.state.mode, InteractionMode.mixer);
      r.midiValue(127);
      expect(r.cubit.state.mode, InteractionMode.record);
    },
  );

  check(
    'malformed settings survive refused reset and recover on receipt',
    ExternalJackSetup.empty,
    (r) {
      expect(r.cubit.state.midiUnavailable, isTrue);
      r.store.failMidi = true;
      unawaited(r.cubit.resetMidiConfiguration());
      r
        ..clock.flushMicrotasks()
        ..settle();
      expect(r.cubit.state.midiUnavailable, isTrue);
      expect(r.store.values['midi.configuration'], 'broken raw');
      r.store.failMidi = false;
      unawaited(r.cubit.resetMidiConfiguration());
      r
        ..clock.flushMicrotasks()
        ..settle();
      expect(r.cubit.state.midiUnavailable, isFalse);
      expect(r.cubit.state.midiPersistenceUncertain, isFalse);
      expect(r.cubit.state.midiMappings, MidiMappingSet.empty);
    },
    initialMidiRaw: 'broken raw',
  );

  check(
    'unassigned CCs do nothing and mapped contacts dispatch once',
    ExternalJackSetup.empty,
    (r) {
      for (var id = 80; id <= 86; id++) {
        r.midiValue(127, id: id);
      }
      expect(engine.taps, 0);
      r
        ..bindMidi(
          controls: [
            MidiActionControl(key: 'command:tap-tempo'),
          ],
        )
        ..midiValue(127)
        ..midiValue(127);
      expect(engine.taps, 1);
      r
        ..midiValue(0)
        ..midiValue(127);
      expect(engine.taps, 2);
    },
  );

  check(
    'failed Remote Off remains paused until deliberate confirmed resume',
    ExternalJackSetup.empty,
    (r) {
      r
        ..bindMidi(
          controls: [
            MidiActionControl(key: 'command:tap-tempo'),
          ],
        )
        ..store.failMidi = true;
      unawaited(r.cubit.setMidiControlEnabled(enabled: false));
      r
        ..clock.flushMicrotasks()
        ..settle();
      expect(r.cubit.state.midiControlEnabled, isTrue);
      expect(r.cubit.state.midiRemotePaused, isTrue);
      expect(r.cubit.state.midiSaveError, isNotNull);
      r.midiValue(127);
      expect(engine.taps, 0);
      r.store.failMidi = false;
      unawaited(r.cubit.setMidiControlEnabled(enabled: true));
      r
        ..clock.flushMicrotasks()
        ..settle();
      expect(r.cubit.state.midiRemotePaused, isFalse);
      expect(engine.taps, 0);
      r.midiValue(127);
      expect(engine.taps, 1);
    },
  );

  check(
    'old editor cannot resume new editor and Learn never dispatches',
    ExternalJackSetup.empty,
    (r) {
      r.bindMidi(
        controls: [
          MidiActionControl(key: 'command:tap-tempo'),
        ],
      );
      final first = Object();
      final second = Object();
      r
        ..cubit.beginMidiEdit(device: 'test-midi', owner: first)
        ..cubit.beginMidiEdit(device: 'test-midi', owner: second)
        ..cubit.endMidiEdit(first)
        ..cubit.startMidiLearn(MidiProtocol.standard, owner: second)
        ..midiValue(127);
      expect(engine.taps, 0);
      expect(r.cubit.state.midiEdit!.owner, same(second));
      expect(r.cubit.state.midiEdit!.learn!.reading!.source.number, 21);
      r
        ..cubit.endMidiEdit(second)
        ..midiValue(127);
      expect(engine.taps, 1);
    },
  );

  double physical(MixSettingsSnapshot mix, MixValueTarget target) =>
      switch (target) {
        TrackVolumeTarget(:final channel) => mix.trackLevels[channel] ?? 1,
        LaneVolumeTarget(:final channel, :final lane) =>
          mix.laneLevels[(channel, lane)] ?? 1,
        MonitorVolumeTarget(:final input) => mix.monitorLevels[input] ?? 1,
        TrackPanTarget(:final channel) => mix.trackPans[channel] ?? 0,
        InputPanTarget(:final input) => mix.inputSetup.panOf(input),
        PairBalanceTarget(:final input) => mix.inputSetup.pairs[input] ?? 0,
        OutputLevelTarget(:final bus) => mix.outputSetup.of(bus).level,
        OutputBalanceTarget(:final bus) => mix.outputSetup.of(bus).balance,
      };

  for (final target in const <MixValueTarget>[
    TrackVolumeTarget(0),
    LaneVolumeTarget(0, 0),
    MonitorVolumeTarget(0),
    TrackPanTarget(0),
    InputPanTarget(0),
    PairBalanceTarget(0),
    OutputLevelTarget(0),
    OutputBalanceTarget(0),
  ]) {
    final gain =
        target is TrackVolumeTarget ||
        target is LaneVolumeTarget ||
        target is MonitorVolumeTarget;
    final low = gain || target is OutputLevelTarget ? 0.0 : -1.0;
    final high = gain && target is! MonitorVolumeTarget ? 2.0 : 1.0;
    check(
      'MIDI and External ${target.canonicalString()} '
      'share full range and durable low',
      button(
        [],
        parameters: [
          ExternalParameter(
            target: target,
            active: 1,
            inactive: 0,
            condition: ExternalValueCondition.heldReleased,
          ),
        ],
      ),
      (r) {
        if (target is PairBalanceTarget) {
          unawaited(r.mix.setInputPair(input: 0, paired: true));
          r.settle();
          expect(looper.inputSetup.pairs, contains(0));
        }
        r
          ..sample(255)
          ..settle();
        expect(
          physical(looper.mixSettingsSnapshot, target),
          closeTo(high, 1e-6),
        );
        expect(physical(r.mix.durableSnapshot, target), closeTo(low, 1e-6));
        r
          ..sample(0)
          ..settle();
        expect(
          physical(looper.mixSettingsSnapshot, target),
          closeTo(low, 1e-6),
        );
        r
          ..bindMidi(target: target.canonicalString(), low: low, high: high)
          ..midiValue(127);
        expect(
          physical(looper.mixSettingsSnapshot, target),
          closeTo(high, 1e-6),
        );
        expect(physical(r.mix.durableSnapshot, target), closeTo(low, 1e-6));
        r.midiValue(0);
        expect(
          physical(looper.mixSettingsSnapshot, target),
          closeTo(low, 1e-6),
        );
      },
    );
  }

  for (final midi in [false, true]) {
    for (final later in [false, true]) {
      check(
        '${midi ? 'MIDI' : 'External'} authored release respects '
        '${later ? 'newer' : 'superseded'} ordinary mix intent',
        button(
          [],
          parameters: [
            ExternalParameter(
              target: const TrackPanTarget(0),
              active: .9,
              inactive: .2,
              condition: ExternalValueCondition.heldReleased,
            ),
          ],
        ),
        (r) {
          unawaited(r.mix.setTrackPan(.25));
          r.settle();
          if (midi) {
            r
              ..bindMidi(
                target: const TrackPanTarget(0).canonicalString(),
                low: -.6,
                high: .8,
              )
              ..midiValue(127);
          } else {
            r
              ..sample(255)
              ..settle();
          }
          expect(looper.mixSettingsSnapshot.trackPans[0], closeTo(.8, 1e-6));
          if (later) {
            unawaited(r.mix.setTrackPan(.3));
            r.settle();
          }
          if (midi) {
            r.midiValue(0);
          } else {
            r
              ..sample(0)
              ..settle();
          }
          expect(
            looper.mixSettingsSnapshot.trackPans[0],
            closeTo(later ? .3 : -.6, 1e-6),
          );
        },
      );
    }
    check(
      '${midi ? 'MIDI' : 'External'} refused press '
      'preserves ordinary mix intent',
      button(
        [],
        parameters: [
          ExternalParameter(
            target: const TrackPanTarget(0),
            active: .9,
            inactive: .2,
            condition: ExternalValueCondition.heldReleased,
          ),
        ],
      ),
      (r) {
        unawaited(r.mix.setTrackPan(.25));
        r.settle();
        r.store.failMix = true;
        if (midi) {
          r
            ..bindMidi(
              target: const TrackPanTarget(0).canonicalString(),
              low: -.6,
              high: .8,
            )
            ..midiValue(127);
        } else {
          r
            ..sample(255)
            ..settle();
        }
        expect(looper.mixSettingsSnapshot.trackPans[0], .25);
        r.store.failMix = false;
        if (midi) {
          r.midiValue(0);
        } else {
          r
            ..sample(0)
            ..settle();
        }
        expect(looper.mixSettingsSnapshot.trackPans[0], .25);
      },
    );
  }

  check(
    'missing External mix sibling does not reject a valid held target',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: const TrackPanTarget(0),
          active: .9,
          inactive: .2,
          condition: ExternalValueCondition.heldReleased,
        ),
        ExternalParameter(
          target: const PairBalanceTarget(0),
          active: 1,
          inactive: 0,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      expect(looper.inputSetup.pairs, isEmpty);
      r
        ..sample(255)
        ..settle();
      expect(looper.mixSettingsSnapshot.trackPans[0], closeTo(.8, 1e-6));
      expect(r.mix.durableSnapshot.trackPans[0], closeTo(-.6, 1e-6));
      r
        ..sample(0)
        ..settle();
      expect(looper.mixSettingsSnapshot.trackPans[0], closeTo(-.6, 1e-6));
      expect(looper.inputSetup.pairs, isEmpty);
    },
  );

  check(
    'pair replacement detaches MIDI and External held releases',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: const PairBalanceTarget(0),
          active: .875,
          inactive: .375,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      void pair({required bool linked}) {
        unawaited(r.mix.setInputPair(input: 0, paired: linked));
        r.settle();
      }

      pair(linked: true);
      r
        ..bindMidi(
          target: const PairBalanceTarget(0).canonicalString(),
          low: -.25,
          high: .75,
        )
        ..midiValue(127);
      expect(looper.inputSetup.pairs[0], .75);
      pair(linked: false);
      pair(linked: true);
      r.midiValue(0);
      expect(looper.inputSetup.pairs[0], 0);
      expect(r.mix.durableSnapshot.inputSetup.pairs[0], 0);
      r
        ..sample(255)
        ..settle();
      expect(looper.inputSetup.pairs[0], .75);
      pair(linked: false);
      pair(linked: true);
      r
        ..sample(0)
        ..settle();
      expect(looper.inputSetup.pairs[0], 0);
      expect(r.mix.durableSnapshot.inputSetup.pairs[0], 0);
    },
  );

  check(
    'External retirement restores surviving MIDI live and durable endpoints',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: const TrackVolumeTarget(0),
          active: const TrackVolumeTarget(0).fromDomain(.6),
          inactive: const TrackVolumeTarget(0).fromDomain(.3),
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      r
        ..bindMidi(
          target: const TrackVolumeTarget(0).canonicalString(),
          low: .2,
          high: .8,
        )
        ..midiValue(127);
      expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.2, 1e-12));
      r
        ..sample(255)
        ..settle();
      expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.3, 1e-12));
      r
        ..link.emit(
          const CtrlMessage(
            jack: PedalCtrlJack.ctrl1,
            kind: PedalCtrlKind.none,
            value: 0,
          ),
        )
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.8, .0001));
      expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.2, .0001));
    },
  );

  check(
    'accepted reset and hardware encoder survive older MIDI release',
    ExternalJackSetup.empty,
    (r) {
      r
        ..bindMidi(
          target: const TrackVolumeTarget(0).canonicalString(),
          low: .2,
          high: .8,
        )
        ..midiValue(127);
      unawaited(r.mix.resetMixer());
      r
        ..clock.flushMicrotasks()
        ..settle()
        ..midiValue(0);
      expect(looper.mixSettingsSnapshot.trackLevels[0] ?? 1, 1);
      r
        ..bindMidi(
          id: 22,
          target: const MasterGainTarget().canonicalString(),
          low: .2,
          high: .8,
        )
        ..midiValue(127, id: 22)
        ..cubit.encoderTurned(1);
      final hardware = looper.masterGain;
      r.midiValue(0, id: 22);
      expect(looper.masterGain, hardware);
    },
  );

  check(
    'built-in toggle and equal restore supersede older MIDI power hold',
    ExternalJackSetup.empty,
    (r) {
      r
        ..bindMidi()
        ..midiValue(127)
        ..cubit.toggleTrackChain(0)
        ..settle()
        ..cubit.toggleTrackChain(0)
        ..settle()
        ..midiValue(0);
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..midiValue(127)
        ..cubit.restoreAllTrackChains()
        ..settle()
        ..midiValue(0);
      expect(looper.trackChainEnabled(0), isTrue);
    },
  );

  for (final behavior in [MidiBehavior.continuous, MidiBehavior.toggle]) {
    check(
      '$behavior retirement preserves accepted sound over older UI value',
      ExternalJackSetup.empty,
      (r) {
        unawaited(r.mix.setTrackVolume(.3));
        r
          ..clock.flushMicrotasks()
          ..settle()
          ..bindMidi(
            target: const TrackVolumeTarget(0).canonicalString(),
            high: .8,
            protocol: behavior == MidiBehavior.continuous
                ? MidiProtocol.relative
                : MidiProtocol.standard,
            behavior: behavior,
          )
          ..midiValue(behavior == MidiBehavior.continuous ? 50 : 127);
        final accepted = looper.mixSettingsSnapshot.trackLevels[0]!;
        expect(accepted, greaterThan(.3));
        unawaited(r.cubit.setMidiControlEnabled(enabled: false));
        r
          ..clock.flushMicrotasks()
          ..settle();
        expect(looper.mixSettingsSnapshot.trackLevels[0], accepted);
        expect(r.mix.durableSnapshot.trackLevels[0], accepted);
      },
    );
  }

  for (final behavior in [MidiBehavior.continuous, MidiBehavior.toggle]) {
    check(
      '$behavior non-held intent replaces older External durable projection',
      button(
        [],
        parameters: [
          ExternalParameter(
            target: const TrackVolumeTarget(0),
            active: const TrackVolumeTarget(0).fromDomain(.75),
            inactive: const TrackVolumeTarget(0).fromDomain(.4),
            condition: ExternalValueCondition.heldReleased,
          ),
        ],
      ),
      (r) {
        unawaited(r.mix.setTrackVolume(.47));
        r
          ..clock.flushMicrotasks()
          ..settle()
          ..bindMidi(
            target: const TrackVolumeTarget(0).canonicalString(),
            high: 1.5,
            protocol: behavior == MidiBehavior.continuous
                ? MidiProtocol.relative
                : MidiProtocol.standard,
            behavior: behavior,
          )
          ..sample(255)
          ..settle();
        expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.75, 1e-6));
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.4, 1e-6));

        r.midiValue(behavior == MidiBehavior.continuous ? 50 : 127);
        const accepted = 1.5;
        expect(
          looper.mixSettingsSnapshot.trackLevels[0],
          closeTo(accepted, 1e-6),
        );
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(accepted, 1e-6));
        unawaited(r.cubit.setMidiControlEnabled(enabled: false));
        r
          ..clock.flushMicrotasks()
          ..settle();
        expect(
          looper.mixSettingsSnapshot.trackLevels[0],
          closeTo(accepted, 1e-6),
        );
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(accepted, 1e-6));
        r
          ..sample(0)
          ..settle();
        expect(
          looper.mixSettingsSnapshot.trackLevels[0],
          closeTo(accepted, 1e-6),
        );
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(accepted, 1e-6));

        r
          ..sample(255)
          ..settle();
        expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.75, 1e-6));
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.4, 1e-6));
        r
          ..sample(0)
          ..settle();
        expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.4, 1e-6));
        expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.4, 1e-6));
      },
    );
  }

  check(
    'refused non-held intent preserves older External durable projection',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: const TrackVolumeTarget(0),
          active: const TrackVolumeTarget(0).fromDomain(.75),
          inactive: const TrackVolumeTarget(0).fromDomain(.4),
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      r
        ..bindMidi(
          target: const TrackVolumeTarget(0).canonicalString(),
          high: 1.5,
          behavior: MidiBehavior.toggle,
        )
        ..sample(255)
        ..settle();
      r.store.failMixWrites = 1;
      r.midiValue(127);
      expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.75, 1e-6));
      expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.4, 1e-6));
      unawaited(r.cubit.setMidiControlEnabled(enabled: false));
      r
        ..clock.flushMicrotasks()
        ..settle()
        ..sample(0)
        ..settle();
      expect(looper.mixSettingsSnapshot.trackLevels[0], closeTo(.4, 1e-6));
      expect(r.mix.durableSnapshot.trackLevels[0], closeTo(.4, 1e-6));
    },
  );

  for (final gap in [99, 101]) {
    check(
      'CC14 uses ${gap}ms native capture interval while dispatch is blocked',
      ExternalJackSetup.empty,
      (r) {
        r
          ..bindMidi()
          ..bindMidi(
            id: 1,
            target: const MasterGainTarget().canonicalString(),
            protocol: MidiProtocol.cc14,
            behavior: MidiBehavior.continuous,
          )
          ..store.fxGate = Completer<void>()
          ..midiValue(127);
        void cc(int id, int value, int micros) {
          r
            ..midi.push(
              RawControllerInput(
                kind: ControllerSourceKind.midiCc,
                id: id,
                value: value,
              ),
              timestampMicros: micros,
            )
            ..clock.flushMicrotasks();
        }

        cc(1, 127, 1000000);
        cc(33, 127, 1000000 + gap * 1000);
        cc(1, 0, 2000000);
        cc(33, 0, 2000001);
        r
          ..clock.elapse(const Duration(milliseconds: 500))
          ..store.fxGate!.complete()
          ..clock.flushMicrotasks()
          ..settle();
        expect(looper.masterGain, gap == 99 ? 0 : 1);
      },
    );
  }

  check(
    'built-in captured-prior restore becomes fresh shared intent',
    ExternalJackSetup.empty,
    (r) {
      unawaited(
        r.cubit.setGlobalBindings(
          PedalBindingSet([
            PedalBinding(
              key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
              target: _chain.canonicalString(),
              behavior: BindingBehavior.momentary,
            ),
          ]),
        ),
      );
      r
        ..clock.flushMicrotasks()
        ..cubit.setMode(InteractionMode.fx)
        ..link.press(PedalButton.track1, down: true)
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..bindMidi()
        ..midiValue(127)
        ..link.press(PedalButton.track1, down: false)
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r.midiValue(0);
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );

  check(
    'delayed monitor metadata save cannot resurrect a released MIDI snapshot',
    ExternalJackSetup.empty,
    (r) {
      const address = FxAddress(stage: FxStage.input);
      const target = FxParamTarget(
        address: address,
        slotId: 'monitor-drive',
        param: 0,
      );
      expect(
        looper.setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive, slotId: 'monitor-drive'),
          ],
        ),
        EngineResult.ok,
      );
      r.settle();
      final monitor = MonitorCubit(
        repository: looper,
        settings: r.settings,
        mixSettings: r.mix,
        fxPersistence: r.fx,
      );
      r
        ..bindMidi(target: target.canonicalString(), low: .2, high: .8)
        ..midiValue(127)
        ..store.monitorModeGate = Completer<void>();
      var saved = false;
      monitor.projectFromRepository();
      unawaited(
        r.fx
            .saveConfirmed(
              const FxAddress(stage: FxStage.input),
              r.settings,
            )
            .then((_) => saved = true),
      );
      r
        ..clock.flushMicrotasks()
        ..settle();
      expect(saved, isFalse);
      r
        ..midiValue(0)
        ..store.monitorModeGate!.complete()
        ..clock.flushMicrotasks()
        ..settle();
      expect(saved, isTrue);
      final envelope = decodeFxChain(r.store.values['monitor_fx.0'] as String?);
      expect(
        (envelope.entries.single as BuiltInEffect).params.first,
        closeTo(.2, .0001),
      );
      unawaited(monitor.close());
      r.clock.flushMicrotasks();
    },
  );

  check(
    'shutdown waits for track and monitor toggle storage',
    ExternalJackSetup.empty,
    (r) {
      r
        ..store.fxGate = Completer<void>()
        ..cubit.toggleTrackChain(0)
        ..settle();
      var done = false;
      unawaited(r.cubit.flushMidiConfiguration().then((_) => done = true));
      r.clock.flushMicrotasks();
      expect(done, isFalse);
      r
        ..store.fxGate!.complete()
        ..clock.flushMicrotasks()
        ..settle();
      expect(done, isTrue);
      expect(
        looper.setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive, slotId: 'monitor-drive'),
          ],
        ),
        EngineResult.ok,
      );
      r.settle();
      final monitor = MonitorCubit(
        repository: looper,
        settings: r.settings,
        mixSettings: r.mix,
        fxPersistence: r.fx,
      )..projectFromRepository();
      r
        ..clock.flushMicrotasks()
        ..settle()
        ..store.monitorFxGate = Completer<void>();
      monitor.setChainEnabled(0, enabled: false);
      r.settle();
      done = false;
      unawaited(monitor.flushPersistence().then((_) => done = true));
      r.clock.flushMicrotasks();
      expect(done, isFalse);
      r
        ..store.monitorFxGate!.complete()
        ..clock.flushMicrotasks()
        ..settle();
      expect(done, isTrue);
      unawaited(monitor.close());
      r.clock.flushMicrotasks();
    },
  );

  check(
    'one owner applies all power and parameter rows together',
    button(
      [
        const ExternalActivation(
          target: _chain,
          condition: ExternalCondition.held,
        ),
        const ExternalActivation(
          target: _slot,
          condition: ExternalCondition.held,
        ),
      ],
      parameters: [
        ExternalParameter(
          target: _param,
          active: .8,
          inactive: .2,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      expect(looper.trackEffects(0).single.enabled, isTrue);
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.8, .0001),
      );
      r
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      expect(looper.trackEffects(0).single.enabled, isFalse);
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.2, .0001),
      );
    },
  );
  check(
    'Released is literal, source loss never synthesizes its true endpoint',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.released,
      ),
    ]),
    (r) {
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..sample(0, kind: PedalCtrlKind.none)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );
  check(
    'release before recipe acknowledgment cannot strand a held activation',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.held,
      ),
    ]),
    (r) {
      r
        ..sample(255)
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );
  check(
    'reversed byte precision with calibration replay suppression',
    ExternalJackSetup(
      type: ExternalJackType.expression,
      expression: ExternalExpressionSetup(
        calibration: ExpressionCalibration(heel: 255, toe: 0),
        mappings: [ExpressionMapping(target: _param)],
      ),
    ),
    (r) {
      r
        ..sample(255, kind: PedalCtrlKind.expression)
        ..sample(201, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(54 / 255, .0001),
      );
      final calibration = Object();
      r
        ..cubit.beginExternalCalibration(
          PedalCtrlJack.ctrl1,
          owner: calibration,
        )
        ..sample(0, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(54 / 255, .0001),
      );
      r
        ..cubit.endExternalCalibration(calibration)
        ..sample(0, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(54 / 255, .0001),
      );
      r
        ..sample(1, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(254 / 255, .0001),
      );
    },
  );
  check(
    'false held priority and available Released survive MIDI retirement',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.released,
      ),
    ]),
    (r) {
      r.bindMidi();
      void midi(int value) {
        r
          ..midi.push(
            RawControllerInput(
              kind: ControllerSourceKind.midiCc,
              id: 21,
              value: value,
            ),
          )
          ..clock.flushMicrotasks();
      }

      midi(127);
      r.settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      midi(0);
      r.settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..sample(255)
        ..settle();
      midi(127);
      r.settle();
      expect(looper.trackChainEnabled(0), isTrue);
      midi(0);
      r.settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
    },
  );
  check(
    'old calibration owner cannot release a newer editor',
    ExternalJackSetup(
      type: ExternalJackType.expression,
      expression: ExternalExpressionSetup(
        calibration: ExpressionCalibration(heel: 0, toe: 255),
        mappings: [ExpressionMapping(target: _param)],
      ),
    ),
    (r) {
      final old = Object();
      r.cubit.beginExternalCalibration(PedalCtrlJack.ctrl1, owner: old);
      final next = Object();
      r
        ..cubit.beginExternalCalibration(PedalCtrlJack.ctrl1, owner: next)
        ..cubit.endExternalCalibration(old)
        ..sample(0, kind: PedalCtrlKind.expression)
        ..sample(255, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        isNot(1),
      );
      r
        ..cubit.endExternalCalibration(next)
        ..sample(0, kind: PedalCtrlKind.expression)
        ..sample(254, kind: PedalCtrlKind.expression)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(254 / 255, .0001),
      );
    },
  );
  check(
    'incompatible HELLO retires held state and never accepts queued old input',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.held,
      ),
    ]),
    (r) {
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..link.emit(
          const HelloMessage(
            protocolVersion: PedalLinkCodec.protocolVersion + 1,
            firmwareMajor: 1,
            firmwareMinor: 0,
          ),
        )
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..link.hello()
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r
        ..sample(255)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
    },
  );
  check(
    'saved source intent survives downstream changes and queued toggles',
    button([
      const ExternalActivation(target: _chain),
    ]),
    (r) {
      const input = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip);
      expect(r.cubit.state.pedalSetup.external.logicalOn[input], isTrue);
      r
        ..sample(255)
        ..sample(0)
        ..settle();
      expect(r.cubit.state.pedalSetup.external.logicalOn[input], isFalse);
      r
        ..sample(255)
        ..sample(0)
        ..sample(255)
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      expect(
        PedalSetup.decode(
          r.store.values['pedal.setup']! as String,
        ).external.logicalOn[input],
        isFalse,
      );
    },
    initialOn: true,
  );
  check(
    'failed persistence keeps live direction and permits same-value retry',
    button([
      const ExternalActivation(target: _chain),
    ]),
    (r) {
      const input = PedalCtrlInput(PedalCtrlJack.ctrl1, PedalCtrlContact.tip);
      r
        ..store.failSetup = true
        ..sample(255)
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      expect(r.cubit.state.pedalSetupRuntimeUnsaved, isTrue);
      expect(r.cubit.state.pedalSetup.external.logicalOn[input], isFalse);
      r
        ..sample(255)
        ..sample(0)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
      r.store.failSetup = false;
      unawaited(r.cubit.setPedalSetup(r.cubit.state.pedalSetup));
      r.clock.flushMicrotasks();
      expect(r.cubit.state.pedalSetupRuntimeUnsaved, isFalse);
      expect(
        PedalSetup.decode(
          r.store.values['pedal.setup']! as String,
        ).external.logicalOn[input],
        isFalse,
      );
    },
  );
  check(
    'numeric disconnect reapplies surviving endpoint then literal Released',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: _param,
          active: .8,
          inactive: .2,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: r.cubit.state.pedalSetup.external.withJack(
              PedalCtrlJack.ctrl2,
              button(
                [],
                parameters: [
                  ExternalParameter(
                    target: _param,
                    active: .6,
                    inactive: .3,
                    condition: ExternalValueCondition.heldReleased,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      r
        ..clock.flushMicrotasks()
        ..sample(255)
        ..settle()
        ..sample(255, jack: PedalCtrlJack.ctrl2)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.6, .0001),
      );
      r
        ..sample(0, jack: PedalCtrlJack.ctrl2, kind: PedalCtrlKind.none)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.8, .0001),
      );
      r
        ..sample(0, kind: PedalCtrlKind.none)
        ..settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.2, .0001),
      );
    },
  );
  check(
    'refused numeric disconnect is retained until mix admission becomes safe',
    button(
      [],
      parameters: [
        ExternalParameter(
          target: _param,
          active: .8,
          inactive: .2,
          condition: ExternalValueCondition.heldReleased,
        ),
      ],
    ),
    (r) {
      r
        ..sample(255)
        ..settle();
      engine.refuseRecipes = true;
      r
        ..sample(0, kind: PedalCtrlKind.none)
        ..clock.flushMicrotasks();
      expect(engine.refused, 2);
      r.clock.elapse(const Duration(milliseconds: 100));
      expect(
        engine.refused,
        2,
        reason: 'no retry loop while eligibility is unchanged',
      );
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.8, .0001),
      );
      engine.refuseRecipes = false;
      expect(
        looper.applyMixSettings(
          looper.mixSettingsSnapshot.copyWith(
            trackLevels: {0: .5},
          ),
        ),
        EngineResult.ok,
      );
      r.settle();
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.2, .0001),
      );
    },
  );
  check(
    'release retry resolves a MIDI holder acquired during recipe wait',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.held,
      ),
    ]),
    (r) {
      r
        ..bindMidi()
        ..sample(255)
        ..settle();
      expect(
        looper.setTrackEffects(
          channel: 0,
          effects: looper.trackEffects(0),
          chainEnabled: true,
        ),
        EngineResult.ok,
      );
      r
        ..sample(0)
        ..midi.push(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 21,
            value: 127,
          ),
        )
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..midi.push(
          const RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 21,
            value: 0,
          ),
        )
        ..clock.flushMicrotasks()
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );
  check(
    'genuine Released acquires fresh priority and survives other contact loss',
    button([
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.released,
      ),
    ]),
    (r) {
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: r.cubit.state.pedalSetup.external.withJack(
              PedalCtrlJack.ctrl2,
              button([
                const ExternalActivation(
                  target: _chain,
                  condition: ExternalCondition.released,
                ),
              ]),
            ),
          ),
        ),
      );
      r
        ..clock.flushMicrotasks()
        ..sample(255)
        ..settle()
        ..sample(255, jack: PedalCtrlJack.ctrl2)
        ..settle()
        ..sample(0)
        ..settle();
      // A's true release is newer than B's still-held false predicate.
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..sample(0, jack: PedalCtrlJack.ctrl2, kind: PedalCtrlKind.none)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: r.cubit.state.pedalSetup.external.withJack(
              PedalCtrlJack.ctrl2,
              button([
                const ExternalActivation(
                  target: _chain,
                  condition: ExternalCondition.held,
                ),
              ]),
            ),
          ),
        ),
      );
      r.clock.flushMicrotasks();
      // Reacquire A after the explicit setup edit retires old lifetimes.
      r
        ..sample(255)
        ..settle()
        ..sample(0)
        ..settle()
        ..sample(255, jack: PedalCtrlJack.ctrl2)
        ..settle()
        ..sample(0, jack: PedalCtrlJack.ctrl2, kind: PedalCtrlKind.none)
        ..settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r
        ..sample(0, kind: PedalCtrlKind.none)
        ..settle();
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );
  ExternalJackSetup heldPowerAndValue() => button(
    [
      const ExternalActivation(
        target: _chain,
        condition: ExternalCondition.held,
      ),
    ],
    parameters: [
      ExternalParameter(
        target: _param,
        active: .83,
        inactive: .17,
        condition: ExternalValueCondition.heldReleased,
      ),
    ],
  );

  void mixBoundary(_Rig r) {
    expect(
      looper.applyMixSettings(
        looper.mixSettingsSnapshot.copyWith(
          trackLevels: {0: .43},
        ),
      ),
      EngineResult.ok,
    );
    r.settle();
  }

  for (final accepted in [true, false]) {
    check(
      'new ${accepted ? 'accepted' : 'refused'} press supersession '
      'is target-specific',
      heldPowerAndValue(),
      (r) {
        r
          ..sample(255)
          ..settle();
        engine.refuseRecipes = true;
        r.sample(0);
        expect(engine.refused, 2);
        engine.refuseRecipes = !accepted;
        r
          ..sample(255)
          ..settle();
        engine.refuseRecipes = false;
        mixBoundary(r);
        expect(looper.trackChainEnabled(0), accepted);
        expect(
          (looper.trackEffects(0).single as BuiltInEffect).params[0],
          closeTo(accepted ? .83 : .17, .0001),
        );
        r
          ..sample(0)
          ..settle();
        expect(looper.trackChainEnabled(0), isFalse);
        expect(
          (looper.trackEffects(0).single as BuiltInEffect).params[0],
          closeTo(.17, .0001),
        );
      },
    );
  }
  check(
    'accepted different target preserves older numeric and power cleanup',
    heldPowerAndValue(),
    (r) {
      r
        ..sample(255)
        ..settle();
      engine.refuseRecipes = true;
      r.sample(0);
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: r.cubit.state.pedalSetup.external.withJack(
              PedalCtrlJack.ctrl1,
              button([
                const ExternalActivation(
                  target: _slot,
                  condition: ExternalCondition.held,
                ),
              ]),
            ),
          ),
        ),
      );
      r.clock.flushMicrotasks();
      engine.refuseRecipes = false;
      r
        ..sample(255)
        ..settle();
      mixBoundary(r);
      expect(looper.trackChainEnabled(0), isFalse);
      expect(looper.trackEffects(0).single.enabled, isTrue);
      expect(
        (looper.trackEffects(0).single as BuiltInEffect).params[0],
        closeTo(.17, .0001),
      );
    },
  );
  check(
    'MIDI release retry cannot retire a newer accepted press on same trigger',
    ExternalJackSetup.empty,
    (r) {
      r.bindMidi(id: 27);
      void midi(int value) {
        r
          ..midi.push(
            RawControllerInput(
              kind: ControllerSourceKind.midiCc,
              id: 27,
              value: value,
            ),
          )
          ..clock.flushMicrotasks();
      }

      midi(127);
      r.settle();
      final effect = looper.trackEffects(0).single as BuiltInEffect;
      expect(
        looper.setTrackEffects(
          channel: 0,
          effects: [
            effect.copyWith(params: [.66, ...effect.params.skip(1)]),
          ],
          chainEnabled: true,
        ),
        EngineResult.ok,
      );
      midi(0);
      midi(127);
      r.settle();
      expect(looper.trackChainEnabled(0), isTrue);
      midi(0);
      r.settle();
      expect(looper.trackChainEnabled(0), isFalse);
    },
  );
  check(
    'encoded NONE retires pending Press and never fires latching Change',
    const ExternalJackSetup(
      single: ExternalSwitchSetup(
        gestures: ControlGesturePair(
          press: ModeAction(InteractionMode.mute),
          hold: ModeAction(InteractionMode.custom),
        ),
      ),
    ),
    (r) {
      final parser = PedalLinkParser();
      void frame(PedalLinkMessage message) {
        parser.push(PedalLinkCodec.encode(message)).forEach(r.link.emit);
        r.clock.flushMicrotasks();
      }

      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 255,
        ),
      );
      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.none,
          value: 0,
        ),
      );
      r.settle();
      expect(r.cubit.state.mode, InteractionMode.record);
      unawaited(
        r.cubit.setPedalSetup(
          r.cubit.state.pedalSetup.copyWith(
            external: r.cubit.state.pedalSetup.external.withJack(
              PedalCtrlJack.ctrl1,
              const ExternalJackSetup(
                single: ExternalSwitchSetup(
                  hardware: ExternalSwitchHardware.latching,
                  change: ModeAction(InteractionMode.mute),
                ),
              ),
            ),
          ),
        ),
      );
      r.clock.flushMicrotasks();
      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 0,
        ),
      );
      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: 255,
        ),
      );
      r.settle();
      expect(r.cubit.state.mode, InteractionMode.mute);
      r.cubit.setMode(InteractionMode.record);
      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.none,
          value: 0,
        ),
      );
      frame(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.expression,
          value: 128,
        ),
      );
      r.settle();
      expect(r.cubit.state.mode, InteractionMode.record);
    },
  );
  check(
    'master resolver reads the current desired value',
    ExternalJackSetup.empty,
    (r) {
      looper.setMasterGain(.37);
      expect(looper.readValueTarget(const MasterGainTarget()), .37);
    },
  );
}
