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
import 'package:segno/looper/cubit/fx_cubit.dart';
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
  new({ExternalJackSetup? jack}) {
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

  /// What one Overdrive charges at the rig's rate and block: a heavy kind
  /// with no tail, so switched off it stops at once (#1723).
  int get overdriveNs => looper.fxGrowthNs({
    const FxAddress(stage: FxStage.track, index: 7): [
      BuiltInEffect(type: TrackEffectType.overdrive),
    ],
  });

  /// Input 1's A/B pair (#1711) as two Overdrives: rack A (Reverb + Delay)
  /// switched off, rack B (Soft Chords) on.
  Future<void> heavyRacks() async {
    expect(
      looper.setMonitorEffects(
        input: 0,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.overdrive,
            slotId: 'reverb',
            rack: _reverb.copyWith(bypassed: true),
          ),
          BuiltInEffect(
            type: TrackEffectType.overdrive,
            slotId: 'chords',
            rack: _chords,
          ),
        ],
      ),
      EngineResult.ok,
    );
    expect(await looper.settleFxRecipes(), EngineResult.ok);
  }

  /// Fills track 1's chain with Overdrives that are on until less than
  /// [spare] + 1 more fit the effects budget.
  Future<void> fill({int spare = 0}) async {
    final count = looper.fxRoomNs ~/ overdriveNs - spare;
    expect(
      looper.setTrackEffects(
        channel: 0,
        effects: [
          for (var i = 0; i < count; i++)
            BuiltInEffect(type: TrackEffectType.overdrive),
        ],
      ),
      EngineResult.ok,
    );
    expect(await looper.settleFxRecipes(), EngineResult.ok);
    expect(
      looper.fxRoomNs,
      inInclusiveRange(spare * overdriveNs, (spare + 1) * overdriveNs - 1),
    );
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

  test("an effect's LED follows its sound: dark while its rack is off, "
      'and its press still flips its own switch', () async {
    final rig = _Rig();
    try {
      await rig.twoRacks();
      await rig.control.load();
      await rig.control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: const FxSlotTarget(
              address: _input,
              slotId: 'chords',
            ).canonicalString(),
          ),
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track2, bank: 0),
            target: _chordsRack.canonicalString(),
          ),
        ]),
      );
      rig.control.setMode(InteractionMode.fx);
      await rig._settle();
      expect(rig.lit(PedalButton.track1), isTrue);

      // The rack off: the effect is silent, so its LED is dark.
      await rig.stomp(PedalButton.track2);
      expect(rig.lit(PedalButton.track1), isFalse);
      expect(rig.looper.monitorEffects(0).last.enabled, isTrue);

      // Its press flips its own switch, which the rack keeps for later.
      await rig.stomp(PedalButton.track1);
      expect(rig.looper.monitorEffects(0).last.enabled, isFalse);
      expect(rig.lit(PedalButton.track1), isFalse);

      // The rack back on: still dark, its own switch is now off.
      await rig.stomp(PedalButton.track2);
      expect(rig.lit(PedalButton.track1), isFalse);
      await rig.stomp(PedalButton.track1);
      expect(rig.lit(PedalButton.track1), isTrue);

      // The chain off: what the LED reads goes dark too, as the Effects page
      // dims it.
      rig.looper.setMonitorChainEnabled(input: 0, enabled: false);
      expect(
        rig.looper.bindingLit(
          const FxSlotTarget(address: _input, slotId: 'chords'),
        ),
        isFalse,
      );
    } finally {
      await rig.close();
    }
  });

  test('a stomp that switches an empty chain off saves nothing', () async {
    final rig = _Rig();
    try {
      await rig.control.load();
      await rig.control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: const FxChainTarget(FxAddress(stage: FxStage.allTracks))
                .canonicalString(),
          ),
        ]),
      );
      rig.control.setMode(InteractionMode.fx);
      await rig._settle();

      await rig.stomp(PedalButton.track1);

      expect(rig.looper.allTracksChainEnabled, isFalse);
      expect(await rig.settings.loadAllTracksFxChain(), isNull);
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

  group('the effects budget (#1723)', () {
    const spare = FxSlotTarget(
      address: FxAddress(stage: FxStage.track, index: 1),
      slotId: 'spare',
    );

    /// Track 2's chain: one Overdrive, switched off.
    Future<void> putSpare(_Rig rig) async {
      expect(
        rig.looper.setTrackEffects(
          channel: 1,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.overdrive,
              slotId: 'spare',
              enabled: false,
            ),
          ],
        ),
        EngineResult.ok,
      );
      expect(await rig.looper.settleFxRecipes(), EngineResult.ok);
    }

    PedalBindingSet bound(FxBindingTarget target) => PedalBindingSet([
      PedalBinding(
        key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
        target: target.canonicalString(),
      ),
    ]);

    test('the A/B pair one switch alternates charges its larger side, and '
        'its presses are never refused', () async {
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
        await rig.heavyRacks();
        await rig.control.load();
        await rig._settle();
        // One rack's Overdrive, not two.
        expect(rig.looper.fxCostNs, rig.overdriveNs);
        await rig.fill();

        for (final expected in [
          (reverb: true, chords: false),
          (reverb: false, chords: true),
          (reverb: true, chords: false),
        ]) {
          await rig.pressExternal();
          expect(rig.sounding(), expected);
          expect(rig.looper.state.fxHeld, isEmpty);
          expect(rig.looper.fxRoomNs, greaterThanOrEqualTo(0));
        }

        // A console switch on rack A as well could turn both on: refused,
        // with nothing saved.
        await expectLater(
          rig.control.setGlobalBindings(bound(_reverbRack)),
          throwsA(isA<FxReachOverBudget>()),
        );
        expect(rig.control.state.globalBindings, PedalBindingSet.empty);
        expect(await rig.settings.loadPedalBindings(), isNull);
      } finally {
        await rig.close();
      }
    });

    test('an off effect no control reaches charges nothing, and the screen '
        'refuses to switch it on when it does not fit', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await putSpare(rig);
        expect(rig.looper.fxCostNs, 0);
        await rig.fill();
        final fx = FxCubit(
          repository: rig.looper,
          settings: rig.settings,
          persistence: rig.persistence,
        );
        addTearDown(fx.close);

        final result = fx.setEffectEnabled(
          spare.address,
          'spare',
          enabled: true,
        );

        expect(result.status, FxEditStatus.overBudget);
        // Its card's power says the same.
        expect(
          fx.setGroupEnabled(spare.address, 'spare', enabled: true).status,
          FxEditStatus.overBudget,
        );
        expect(rig.looper.trackEffects(1).single.enabled, isFalse);
        // Binding it now would not fit either: refused at bind time.
        await expectLater(
          rig.control.setGlobalBindings(bound(spare)),
          throwsA(isA<FxReachOverBudget>()),
        );
        expect(rig.control.state.globalBindings, PedalBindingSet.empty);
      } finally {
        await rig.close();
      }
    });

    test('replacing a session remap is weighed as one change: the globals '
        'it replaced are never weighed on their own', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await putSpare(rig);
        await rig.control.setGlobalBindings(bound(spare));
        // A session remap in force: the globals, and the spare they reach,
        // are not.
        rig.control.applySessionBindings(
          bound(const FxChainTarget(FxAddress(stage: FxStage.track))),
        );
        expect(rig.looper.fxCostNs, 0);
        await rig.fill();

        await rig.control.setGlobalBindings(
          PedalBindingSet.empty,
          promote: true,
        );

        expect(rig.control.state.sessionBindings, PedalBindingSet.empty);
        expect(rig.control.state.globalBindings, PedalBindingSet.empty);
        expect(rig.looper.state.fxHeld, isEmpty);
      } finally {
        await rig.close();
      }
    });

    test('an off effect a pedal reaches is charged, so its press is never '
        'refused', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await putSpare(rig);
        await rig.control.setGlobalBindings(bound(spare));
        expect(rig.looper.fxCostNs, rig.overdriveNs);
        await rig.fill();
        rig.control.setMode(InteractionMode.fx);
        await rig._settle();

        await rig.stomp(PedalButton.track1);

        expect(rig.looper.bindingEnabled(spare), isTrue);
        expect(rig.looper.state.fxHeld, isEmpty);
        expect(rig.looper.fxRoomNs, greaterThanOrEqualTo(0));
        expect(rig.lit(PedalButton.track1), isTrue);
      } finally {
        await rig.close();
      }
    });

    /// Track 2's chain: one off effect per id, Overdrives unless named in
    /// [light] (Filters).
    Future<void> putOff(
      _Rig rig,
      List<String> ids, {
      Set<String> light = const {},
    }) async {
      expect(
        rig.looper.setTrackEffects(
          channel: 1,
          effects: [
            for (final id in ids)
              BuiltInEffect(
                type: light.contains(id)
                    ? TrackEffectType.filter
                    : TrackEffectType.overdrive,
                slotId: id,
                enabled: false,
              ),
          ],
        ),
        EngineResult.ok,
      );
      expect(await rig.looper.settleFxRecipes(), EngineResult.ok);
    }

    FxSlotTarget slot(String id) => FxSlotTarget(
      address: const FxAddress(stage: FxStage.track, index: 1),
      slotId: id,
    );

    MidiParameterControl power(String id, double low, double high) =>
        MidiParameterControl(
          key: slot(id).canonicalString(),
          low: low,
          high: high,
        );

    var number = 0;
    Future<MidiSaveResult> saveMidi(
      _Rig rig,
      List<MidiControl> controls, {
      MidiBehavior behavior = MidiBehavior.toggle,
    }) {
      final owner = Object();
      rig.control.beginMidiEdit(device: 'buttons', owner: owner);
      return rig.control
          .saveMidiMapping(
            MidiMapping(
              id: 'draft',
              source: MidiSource(
                device: 'buttons',
                kind: ControllerSourceKind.midiCc,
                number: ++number,
              ),
              behavior: behavior,
              controls: controls,
            ),
            owner: owner,
            create: true,
          )
          .whenComplete(() => rig.control.endMidiEdit(owner));
    }

    test('two saves from different pages at once are admitted one after the '
        'other: only one fits, so only one lands', () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await putOff(rig, ['x', 'y']);
        // Room for one more Overdrive, not two.
        await rig.fill(spare: 1);

        var externalRefused = false;
        final external = rig.control
            .setPedalSetup(
              rig.control.state.pedalSetup.copyWith(
                external: ExternalPedalSetup(
                  jacks: {
                    PedalCtrlJack.ctrl1: ExternalJackSetup(
                      single: ExternalSwitchSetup(
                        controls: ExternalControls(
                          activations: [ExternalActivation(target: slot('x'))],
                        ),
                      ),
                    ),
                  },
                ),
              ),
            )
            .then<void>(
              (_) {},
              onError: (Object error) =>
                  externalRefused = error is FxReachOverBudget,
            );
        final midi = saveMidi(rig, [power('y', 0, 1)]);
        await external;
        final saved = (await midi).saved;

        expect([externalRefused, !saved].where((refused) => refused), [true]);
        expect(rig.looper.state.fxHeld, isEmpty);
        expect(rig.looper.fxRoomNs, greaterThanOrEqualTo(0));
      } finally {
        await rig.close();
      }
    });

    test(
      'removing a binding is never refused: a charge that rises past the '
      'alternation cap holds chains off, and they come back once it fits',
      () async {
        final rig = _Rig();
        try {
          await rig.control.load();
          // Six MIDI buttons that alternate two pedals each, five of them
          // Delays and the last two Overdrives; and before them one that
          // alternates two Filters, one of which another mapping also reaches,
          // so it alternates nothing.
          final light = {
            'p',
            'q',
            for (var i = 1; i <= 5; i++) ...['a$i', 'b$i'],
          };
          await putOff(rig, [...light, 'x1', 'x2', 'y1', 'y2'], light: light);
          expect(
            (await saveMidi(rig, [power('p', 0, 1), power('q', 1, 0)])).saved,
            isTrue,
          );
          for (var i = 1; i <= 5; i++) {
            expect(
              (await saveMidi(rig, [
                power('a$i', 0, 1),
                power('b$i', 1, 0),
              ])).saved,
              isTrue,
            );
          }
          final heavy = await saveMidi(rig, [
            power('x1', 0, 1),
            power('x2', 0, 1),
            power('y1', 1, 0),
            power('y2', 1, 0),
          ]);
          expect(heavy.saved, isTrue);
          final shared = await saveMidi(rig, [
            power('q', 0, 1),
          ], behavior: MidiBehavior.continuous);
          expect(shared.saved, isTrue);
          await rig.fill();
          expect(rig.looper.state.fxHeld, isEmpty);

          // Without the shared one, the first pair alternates and takes the
          // last place under the cap: the Overdrives are charged together.
          final removed = await rig.control.deleteMidiMapping(
            shared.mappingId!,
          );
          await rig._settle();

          expect(removed.saved, isTrue);
          expect(rig.looper.state.fxHeld, isNotEmpty);
          expect(rig.looper.fxRoomNs, greaterThanOrEqualTo(0));

          // Taking the Overdrives' button away too, the rest fits again.
          expect(
            (await rig.control.deleteMidiMapping(heavy.mappingId!)).saved,
            isTrue,
          );
          await rig._settle();
          expect(rig.looper.state.fxHeld, isEmpty);
        } finally {
          await rig.close();
        }
      },
    );
  });
}
