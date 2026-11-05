import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno_engine/segno_engine.dart' show FxOwner;
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

/// Input 1's chain from #1711: Reverb + Delay (its second pedal switched off
/// on its own) and Soft Chords.
const _input = FxAddress(stage: FxStage.input);
const _reverb = FxRack(id: 'rack-reverb', name: 'Reverb + Delay');
const _chords = FxRack(id: 'rack-chords', name: 'Soft Chords');
const _reverbRack = FxRackTarget(address: _input, rackId: 'rack-reverb');
const _chordsRack = FxRackTarget(address: _input, rackId: 'rack-chords');

BuiltInEffect _module(String slotId, FxRack rack, {bool enabled = true}) =>
    BuiltInEffect(
      type: TrackEffectType.drive,
      slotId: slotId,
      rack: rack,
      enabled: enabled,
    );

/// A console rig over the in-memory engine: the real repository, persistence
/// and control cubit, with an external switch on CTRL 1.
class _Rig {
  _Rig({ExternalJackSetup? jack}) {
    if (jack != null) {
      store.values['pedal.setup'] = const PedalSetup()
          .copyWith(
            external: ExternalPedalSetup(jacks: {PedalCtrlJack.ctrl1: jack}),
          )
          .encode();
    }
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    controller = ControllerRepository(sources: [ConsoleCtrlSource(pedal)]);
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    fade = FadeSettings(
      repository: looper,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: persistence,
      fadeSettings: fade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: fade,
      ),
      controller: controller,
    );
    link.hello();
  }

  final engine = FakeAudioEngine();
  final store = FakeKeyValueStore();
  final ticks = StreamController<void>.broadcast();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final FxChainPersistence persistence;
  late final PedalRepository pedal;
  late final ControllerRepository controller;
  late final PerformanceRepository performance;
  late final FadeSettings fade;
  late final ControlCubit control;

  /// Puts input 1's two racks on the rig, Soft Chords sounding and Reverb +
  /// Delay switched off as a rack: what the switch's Off state asks for.
  Future<void> twoRacks() async {
    expect(
      looper.setMonitorEffects(
        input: 0,
        effects: [
          _module('reverb', _reverb.copyWith(bypassed: true)),
          _module('delay', _reverb.copyWith(bypassed: true), enabled: false),
          _module('chords', _chords),
        ],
      ),
      EngineResult.ok,
    );
    expect(await looper.settleFxRecipes(), EngineResult.ok);
  }

  /// One press of the external switch: contact closed, then open.
  Future<void> pressExternal() async {
    for (final value in [255, 0]) {
      link.emit(
        CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.switchPedal,
          value: value,
        ),
      );
      await _pump(const Duration(milliseconds: 30));
    }
    await _settle();
  }

  /// Stomps a console switch.
  Future<void> stomp(PedalButton button) async {
    link.press(button, down: true);
    await _pump(const Duration(milliseconds: 50));
    link.press(button, down: false);
    await _pump(const Duration(milliseconds: 30));
    await _settle();
  }

  Future<void> _settle() async {
    for (var i = 0; i < 5; i++) {
      ticks.add(null);
      await _pump(const Duration(milliseconds: 10));
    }
  }

  bool lit(PedalButton button) =>
      link.lastFrame!.activeButtonMask & (1 << button.index) != 0;

  /// Which racks sound, as the rig holds them and as the engine was told.
  ({bool reverb, bool chords}) sounding() => (
    reverb: looper.bindingEnabled(_reverbRack)!,
    chords: looper.bindingEnabled(_chordsRack)!,
  );

  /// The engine's flag for each of input 1's entries, from the last recipe.
  List<bool> engineFlags() => [
    for (final slot in engine.fxRecipes[(FxOwner.monitor, 0, 0)]!.slots)
      slot.enabled,
  ];

  /// Input 1's chain as the settings store holds it.
  Future<List<TrackEffect>> saved() async =>
      decodeFxChain(await settings.loadMonitorEffects(0)).entries;

  Future<void> close() async {
    await control.close();
    await fade.close();
    await persistence.close();
    await mix.close();
    await controller.dispose();
    await pedal.dispose();
    performance.dispose();
    await looper.dispose();
    await ticks.close();
  }
}

Future<void> _pump([Duration duration = Duration.zero]) =>
    Future<void>.delayed(duration);

void main() {
  test('one external switch bound to both racks, one On and one Off, '
      'alternates them on every press (#1711)', () async {
    final rig = _Rig(
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [
              ExternalActivation(target: _reverbRack),
              ExternalActivation(
                target: _chordsRack,
                condition: ExternalCondition.off,
              ),
            ],
          ),
        ),
      ),
    );
    try {
      await rig.twoRacks();
      await rig.control.load();
      await rig._settle();
      expect(rig.sounding(), (reverb: false, chords: true));

      for (final expected in [
        (reverb: true, chords: false),
        (reverb: false, chords: true),
        (reverb: true, chords: false),
        (reverb: false, chords: true),
      ]) {
        await rig.pressExternal();
        expect(rig.sounding(), expected);
        // Each pedal keeps its own switch: the Delay, off on its own, stays
        // off whichever rack is sounding.
        expect(rig.looper.monitorEffects(0).map((fx) => fx.enabled), [
          true,
          false,
          true,
        ]);
        expect(rig.engineFlags(), [expected.reverb, false, expected.chords]);
        final saved = await rig.saved();
        expect(saved.map((fx) => fx.rack?.bypassed), [
          !expected.reverb,
          !expected.reverb,
          !expected.chords,
        ]);
        expect(saved.map((fx) => fx.enabled), [true, false, true]);
      }
    } finally {
      await rig.close();
    }
  });

  test('a console switch bound to a rack switches it, lights with it and '
      'saves it', () async {
    final rig = _Rig();
    try {
      await rig.twoRacks();
      await rig.control.load();
      await rig.control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: _chordsRack.canonicalString(),
          ),
        ]),
      );
      rig.control.setMode(InteractionMode.fx);
      await rig._settle();
      expect(rig.lit(PedalButton.track1), isTrue);

      await rig.stomp(PedalButton.track1);

      expect(rig.sounding(), (reverb: false, chords: false));
      expect(rig.lit(PedalButton.track1), isFalse);
      expect((await rig.saved()).last.rack?.bypassed, isTrue);

      await rig.stomp(PedalButton.track1);

      expect(rig.sounding(), (reverb: false, chords: true));
      expect(rig.lit(PedalButton.track1), isTrue);
      expect((await rig.saved()).last.rack?.bypassed, isFalse);
    } finally {
      await rig.close();
    }
  });

  test(
    'a binding whose rack was removed is missing and switches nothing',
    () async {
      final rig = _Rig();
      try {
        await rig.twoRacks();
        await rig.control.load();
        await rig.control.setGlobalBindings(
          PedalBindingSet([
            PedalBinding(
              key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
              target: _reverbRack.canonicalString(),
            ),
          ]),
        );
        rig.control.setMode(InteractionMode.fx);
        rig.looper.setMonitorEffects(
          input: 0,
          effects: [_module('chords', _chords)],
        );
        await rig._settle();

        await rig.stomp(PedalButton.track1);

        expect(rig.looper.bindingResolves(_reverbRack), isFalse);
        expect(rig.looper.bindingEnabled(_chordsRack), isTrue);
        expect(rig.looper.monitorChainEnabled(0), isTrue);
        expect(rig.lit(PedalButton.track1), isFalse);
      } finally {
        await rig.close();
      }
    },
  );
}
