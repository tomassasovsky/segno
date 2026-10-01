import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
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
  @override
  Future<void> setString(String key, String value) async {
    if (key == 'pedal.setup' && failSetup) {
      throw StateError('setup storage refused');
    }
    await super.setString(key, value);
  }
}

class _Rig {
  _Rig(
    this.clock,
    this.engine,
    this.looper,
    ExternalJackSetup setup, {
    bool initialOn = false,
  }) {
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
    mix = testMixSettings(looper, settings: settings);
    pedal = PedalRepository(link, clock: () => clock.elapsed);
    controller = ControllerRepository(
      sources: [ConsoleCtrlSource(pedal), midi],
    );
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
  final midi = SimulatedControllerSource();
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final ControlCubit cubit;

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
  }) {
    test(name, () {
      fakeAsync((clock) {
        final rig = _Rig(clock, engine, looper, setup, initialOn: initialOn);
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
      r.cubit.beginExternalCalibration(PedalCtrlJack.ctrl1, owner: calibration);
      r
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
      unawaited(
        r.cubit.setControllerBindings(
          ControllerBindingSet([
            DiscreteBinding(
              trigger: const MappingTrigger(
                kind: ControllerSourceKind.midiCc,
                id: 21,
              ),
              target: _chain.canonicalString(),
              behavior: BindingBehavior.momentary,
            ),
          ]),
        ),
      );
      r.clock.flushMicrotasks();
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
      r.cubit.beginExternalCalibration(PedalCtrlJack.ctrl1, owner: next);
      r
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
      r.sample(0, kind: PedalCtrlKind.none);
      r.clock.flushMicrotasks();
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
      unawaited(
        r.cubit.setControllerBindings(
          ControllerBindingSet([
            DiscreteBinding(
              trigger: const MappingTrigger(
                kind: ControllerSourceKind.midiCc,
                id: 21,
              ),
              target: _chain.canonicalString(),
              behavior: BindingBehavior.momentary,
            ),
          ]),
        ),
      );
      r.clock.flushMicrotasks();
      r
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
      r.sample(0);
      r.midi.push(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 21,
          value: 127,
        ),
      );
      r.clock.flushMicrotasks();
      r.settle();
      expect(looper.trackChainEnabled(0), isTrue);
      r.midi.push(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 21,
          value: 0,
        ),
      );
      r.clock.flushMicrotasks();
      r.settle();
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
      r.clock.flushMicrotasks();
      r
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
      unawaited(
        r.cubit.setControllerBindings(
          ControllerBindingSet([
            DiscreteBinding(
              trigger: const MappingTrigger(
                kind: ControllerSourceKind.midiCc,
                id: 27,
              ),
              target: _chain.canonicalString(),
              behavior: BindingBehavior.momentary,
            ),
          ]),
        ),
      );
      r.clock.flushMicrotasks();
      void midi(int value) {
        r.midi.push(
          RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 27,
            value: value,
          ),
        );
        r.clock.flushMicrotasks();
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
