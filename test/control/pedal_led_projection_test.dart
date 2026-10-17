import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fx.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/looper/model/interaction_mode.dart';

LooperState _looper(List<Track> overrides, {int masterLengthFrames = 48000}) =>
    LooperState(
      transport: TransportState(
        isRunning: true,
        masterLengthFrames: masterLengthFrames,
      ),
      tracks: [
        for (var i = 0; i < 8; i++)
          overrides.firstWhere(
            (t) => t.channel == i,
            orElse: () => Track(channel: i),
          ),
      ],
      status: const EngineStatus(sampleRate: 48000),
    );

final LooperState _empty = _looper(const [], masterLengthFrames: 0);

/// The light of every pedal, by button, for a projection with no frame
/// invariants in the way.
Map<PedalButton, PedalLedState?> _lights(
  LooperState looper,
  ControlState overlay, {
  bool performanceArmed = false,
  Map<PedalButton, bool> physicalCustomStates = const {},
  Map<PedalButton, bool> tunerStates = const {},
  Map<PedalButton, FxSwitchReading> boundSwitches = const {},
  Set<PedalButton> pressed = const {},
}) {
  final frame = projectFrame(looper, overlay);
  final lights = projectPedalLights(
    looper,
    overlay,
    frame.trackLeds,
    global: frame.globalColor,
    performanceArmed: performanceArmed,
    physicalCustomStates: physicalCustomStates,
    tunerStates: tunerStates,
    boundSwitches: boundSwitches,
    pressed: pressed,
  );
  return {for (final b in PedalButton.values) b: lights[b.index]};
}

const _magenta = PedalColor(200, 0, 200);

void main() {
  group('defaults are the pedal original colours', () {
    test('MODE: red in Record, green in Mute, blue in FX, else yellow', () {
      for (final mode in InteractionMode.values) {
        expect(
          PedalLedMap.schema(
            mode,
          )[PedalLedGroup.mode]![PedalLedState.current],
          switch (mode) {
            InteractionMode.record => ledRed,
            InteractionMode.mute => ledGreen,
            InteractionMode.fx => ledBlue,
            _ => ledYellow,
          },
          reason: mode.name,
        );
      }
    });

    test('a press flashes white, Clear red as it always lit while held', () {
      for (final mode in InteractionMode.values) {
        for (final MapEntry(key: group, value: states) in PedalLedMap.schema(
          mode,
        ).entries) {
          expect(
            states[PedalLedState.pressed],
            group == PedalLedGroup.clear ? ledRed : ledWhite,
            reason: '${mode.name} ${group.name}',
          );
        }
      }
    });

    test('Custom mode owns MODE and Bank only; its pedals default white', () {
      expect(PedalLedMap.schema(InteractionMode.custom).keys, [
        PedalLedGroup.mode,
        PedalLedGroup.bank,
      ]);
      const key = PedalBindingKey(button: PedalButton.stop);
      for (final state in PedalLedMap.customStates) {
        expect(const PedalLedMap().customColorFor(key, state), ledWhite);
      }
    });

    test('every non-Custom mode colours all seven groups', () {
      for (final mode in InteractionMode.values) {
        if (mode == InteractionMode.custom) continue;
        expect(
          PedalLedMap.schema(mode).keys,
          PedalLedGroup.values,
          reason: mode.name,
        );
      }
    });
  });

  group('Record mode', () {
    const overlay = ControlState(cursor: 1);
    final looper = _looper(const [
      Track(state: TrackState.recording),
      Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
      Track(channel: 2, state: TrackState.overdubbing, lengthFrames: 48000),
      Track(channel: 3, state: TrackState.playing, lengthFrames: 48000),
    ]);

    test('track pedals show their own track state', () {
      final lights = _lights(
        looper,
        overlay.copyWith(cursor: 3),
      );
      expect(lights[PedalButton.track1], PedalLedState.recording);
      expect(lights[PedalButton.track2], isNull);
      expect(lights[PedalButton.track3], PedalLedState.overdubbing);
      expect(lights[PedalButton.track4], PedalLedState.playing);
      expect(
        _lights(looper, overlay)[PedalButton.track2],
        PedalLedState.selected,
      );
    });

    test('colours default to the original and follow each override', () {
      final frame = projectFrame(looper, overlay);
      expect(frame.colorFor(PedalButton.track1), ledRed);
      expect(frame.colorFor(PedalButton.track2), ledWhite);
      expect(frame.colorFor(PedalButton.track3), ledRed);
      expect(frame.colorFor(PedalButton.recPlay), ledRed);
      expect(frame.colorFor(PedalButton.mode), ledRed);
      expect(frame.colorFor(PedalButton.clear), ledRed);
      expect(frame.colorFor(PedalButton.bank), ledBankB);

      var leds = const PedalLedMap();
      for (final state in [
        PedalLedState.recording,
        PedalLedState.overdubbing,
        PedalLedState.selected,
      ]) {
        leds = leds.withColor(
          InteractionMode.record,
          PedalLedGroup.tracks,
          state,
          _magenta,
        );
      }
      final edited = projectFrame(
        looper,
        overlay.copyWith(pedalSetup: PedalSetup(leds: leds)),
      );
      for (final b in [
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
      ]) {
        expect(edited.colorFor(b), _magenta, reason: b.name);
      }
      // Another mode's override never leaks into Record.
      final mute = projectFrame(
        looper,
        overlay.copyWith(
          pedalSetup: PedalSetup(
            leds: const PedalLedMap().withColor(
              InteractionMode.mute,
              PedalLedGroup.mode,
              PedalLedState.current,
              _magenta,
            ),
          ),
        ),
      );
      expect(mute.colorFor(PedalButton.mode), ledRed);
    });

    test('Rec/Play: recording, playing, idle while armed, dark idle', () {
      expect(
        _lights(looper, overlay)[PedalButton.recPlay],
        PedalLedState.recording,
      );
      final playing = _looper(const [
        Track(state: TrackState.playing, lengthFrames: 48000),
      ]);
      expect(
        _lights(playing, overlay)[PedalButton.recPlay],
        PedalLedState.playing,
      );
      expect(
        projectFrame(playing, overlay).colorFor(PedalButton.recPlay),
        ledGreen,
      );
      expect(_lights(_empty, overlay)[PedalButton.recPlay], isNull);
      expect(
        _lights(_empty, overlay, performanceArmed: true)[PedalButton.recPlay],
        PedalLedState.idle,
      );
    });

    test('Stop, Undo and Clear light only while held', () {
      final lights = _lights(_empty, const ControlState());
      for (final b in [PedalButton.stop, PedalButton.undo, PedalButton.clear]) {
        expect(lights[b], isNull, reason: b.name);
      }
    });

    test('Bank lights for bank B', () {
      expect(_lights(_empty, const ControlState())[PedalButton.bank], isNull);
      expect(
        _lights(_empty, const ControlState(activeBank: 1))[PedalButton.bank],
        PedalLedState.laterBank,
      );
    });
  });

  test('Mute mode: an armed audible track reads armed, green', () {
    final looper = _looper(const [
      Track(state: TrackState.playing, lengthFrames: 48000),
    ]);
    const overlay = ControlState(mode: InteractionMode.mute);
    expect(_lights(looper, overlay)[PedalButton.track1], PedalLedState.armed);
    expect(_lights(looper, overlay)[PedalButton.track2], isNull);
    final frame = projectFrame(looper, overlay);
    expect(frame.colorFor(PedalButton.track1), ledGreen);
    expect(frame.colorFor(PedalButton.mode), ledGreen);
    final edited = projectFrame(
      looper,
      overlay.copyWith(
        pedalSetup: PedalSetup(
          leds: const PedalLedMap().withColor(
            InteractionMode.mute,
            PedalLedGroup.tracks,
            PedalLedState.armed,
            _magenta,
          ),
        ),
      ),
    );
    expect(edited.colorFor(PedalButton.track1), _magenta);
  });

  group('FX mode', () {
    const overlay = ControlState(mode: InteractionMode.fx);

    test('an engaged chain reads engaged, blue', () {
      final looper = _looper(const [
        Track(state: TrackState.playing, lengthFrames: 48000),
      ]);
      expect(
        _lights(looper, overlay)[PedalButton.track1],
        PedalLedState.engaged,
      );
      expect(
        projectFrame(looper, overlay).colorFor(PedalButton.track1),
        ledBlue,
      );
      expect(projectFrame(looper, overlay).colorFor(PedalButton.mode), ledBlue);
    });

    test('bound transport switches light for what they drive', () {
      const on = (lit: true, stale: false);
      final lights = _lights(
        _empty,
        overlay,
        boundSwitches: const {
          PedalButton.recPlay: on,
          PedalButton.stop: on,
          PedalButton.undo: on,
          PedalButton.clear: (lit: false, stale: false),
        },
      );
      expect(lights[PedalButton.recPlay], PedalLedState.idle);
      expect(lights[PedalButton.stop], PedalLedState.engaged);
      expect(lights[PedalButton.undo], PedalLedState.engaged);
      expect(lights[PedalButton.clear], isNull);
    });
  });

  test('Fade, Reverse and Peel light their track state blue', () {
    for (final (mode, track, state) in [
      (
        InteractionMode.fade,
        const Track(
          state: TrackState.playing,
          lengthFrames: 48000,
          fade: FadeImage(amount: 0, target: 0),
        ),
        PedalLedState.fading,
      ),
      (
        InteractionMode.reverse,
        const Track(
          state: TrackState.playing,
          lengthFrames: 48000,
          reversed: true,
        ),
        PedalLedState.reversed,
      ),
      (
        InteractionMode.peel,
        const Track(
          state: TrackState.playing,
          lengthFrames: 48000,
          peelDepth: 2,
        ),
        PedalLedState.peelable,
      ),
    ]) {
      final looper = _looper([track]);
      final overlay = ControlState(mode: mode);
      final lights = _lights(looper, overlay);
      expect(lights[PedalButton.track1], state, reason: mode.name);
      // Slot-less pedals stay dark on these surfaces until pressed.
      expect(lights[PedalButton.recPlay], isNull, reason: mode.name);
      expect(lights[PedalButton.stop], isNull, reason: mode.name);
      final frame = projectFrame(looper, overlay);
      expect(frame.colorFor(PedalButton.track1), ledBlue, reason: mode.name);
      expect(frame.colorFor(PedalButton.mode), ledYellow, reason: mode.name);
    }
  });

  test('Multiply and Divide light the selected recorded track red', () {
    final looper = _looper(const [
      Track(state: TrackState.playing, lengthFrames: 48000),
    ]);
    for (final mode in [InteractionMode.multiply, InteractionMode.divide]) {
      final overlay = ControlState(mode: mode);
      expect(
        _lights(looper, overlay)[PedalButton.track1],
        PedalLedState.selected,
        reason: mode.name,
      );
      expect(
        projectFrame(looper, overlay).colorFor(PedalButton.track1),
        ledRed,
        reason: mode.name,
      );
    }
  });

  test('Mixer lights the selected channel white; Bank only while held', () {
    const overlay = ControlState(
      mode: InteractionMode.mixer,
      activeBank: 1,
      footMixer: FootMixerSelection(channel: 2),
    );
    final lights = _lights(_empty, overlay);
    expect(lights[PedalButton.track3], PedalLedState.selected);
    expect(lights[PedalButton.track1], isNull);
    expect(lights[PedalButton.bank], isNull);
    expect(
      _lights(_empty, overlay, pressed: {PedalButton.bank})[PedalButton.bank],
      PedalLedState.pressed,
    );
  });

  test('Tuner lights the tuned input, Stop while muted, a later page', () {
    const overlay = ControlState(mode: InteractionMode.tuner);
    final lights = _lights(
      _empty,
      overlay,
      tunerStates: const {
        PedalButton.track2: true,
        PedalButton.stop: true,
        PedalButton.bank: true,
        PedalButton.track1: false,
      },
    );
    expect(lights[PedalButton.track2], PedalLedState.tuned);
    expect(lights[PedalButton.stop], PedalLedState.muted);
    expect(lights[PedalButton.bank], PedalLedState.laterBank);
    expect(lights[PedalButton.track1], isNull);
    expect(lights[PedalButton.undo], isNull);
  });

  group('Custom mode', () {
    final setup = const PedalSetup().withCustom(
      PedalButton.stop,
      bank: 0,
      pair: const ControlGesturePair(
        press: CommandAction(ControlCommand.recordPerformance),
      ),
    );

    test('each assignment lights in its own colour; MODE and Bank in the '
        'mode map', () {
      const stopKey = PedalBindingKey(button: PedalButton.stop);
      final overlay = ControlState(
        mode: InteractionMode.custom,
        activeBank: 1,
        pedalSetup: setup.copyWith(
          leds: const PedalLedMap()
              .withCustomColor(stopKey, PedalLedState.lit, _magenta)
              .withColor(
                InteractionMode.custom,
                PedalLedGroup.mode,
                PedalLedState.current,
                ledGreen,
              ),
        ),
      );
      final frame = projectFrame(
        _empty,
        overlay,
        physicalCustomStates: const {PedalButton.stop: true},
      );
      expect(frame.isLit(PedalButton.stop), isTrue);
      expect(frame.colorFor(PedalButton.stop), _magenta);
      expect(frame.isLit(PedalButton.undo), isFalse);
      expect(frame.colorFor(PedalButton.mode), ledGreen);
      expect(frame.isLit(PedalButton.bank), isTrue);
      expect(frame.colorFor(PedalButton.bank), ledBankB);
    });

    test('track assignments are coloured per bank', () {
      const bankB = PedalBindingKey(button: PedalButton.track1, bank: 1);
      final leds = const PedalLedMap().withCustomColor(
        bankB,
        PedalLedState.lit,
        _magenta,
      );
      ControlState overlay(int bank) => ControlState(
        mode: InteractionMode.custom,
        activeBank: bank,
        pedalSetup: PedalSetup(leds: leds),
      );
      expect(
        projectFrame(_empty, overlay(0)).colorFor(PedalButton.track1),
        ledWhite,
      );
      expect(
        projectFrame(_empty, overlay(1)).colorFor(PedalButton.track1),
        _magenta,
      );
    });

    test('a held assignment shows its own pressed colour', () {
      const stopKey = PedalBindingKey(button: PedalButton.stop);
      final frame = projectFrame(
        _empty,
        ControlState(
          mode: InteractionMode.custom,
          pedalSetup: setup.copyWith(
            leds: const PedalLedMap().withCustomColor(
              stopKey,
              PedalLedState.pressed,
              _magenta,
            ),
          ),
        ),
        pressed: const {PedalButton.stop, PedalButton.undo},
      );
      expect(frame.isLit(PedalButton.stop), isTrue);
      expect(frame.colorFor(PedalButton.stop), _magenta);
      // An unassigned pedal still lights while held.
      expect(frame.isLit(PedalButton.undo), isTrue);
      expect(frame.colorFor(PedalButton.undo), ledWhite);
    });
  });

  test('every press lights its pedal at once in every mode, MODE included, '
      'in that group pressed colour', () {
    for (final mode in InteractionMode.values) {
      final overlay = ControlState(mode: mode);
      final lights = _lights(
        _empty,
        overlay,
        pressed: PedalButton.values.toSet(),
      );
      for (final button in PedalButton.values) {
        expect(
          lights[button],
          PedalLedState.pressed,
          reason: '${mode.name} ${button.name}',
        );
      }
      if (mode == InteractionMode.custom) continue;
      var leds = const PedalLedMap();
      for (final group in PedalLedGroup.values) {
        leds = leds.withColor(mode, group, PedalLedState.pressed, _magenta);
      }
      final frame = projectFrame(
        _empty,
        overlay.copyWith(pedalSetup: PedalSetup(leds: leds)),
        pressed: PedalButton.values.toSet(),
      );
      for (final button in PedalButton.values) {
        expect(frame.isLit(button), isTrue, reason: '$mode $button');
        expect(frame.colorFor(button), _magenta, reason: '$mode $button');
      }
    }
  });
}
