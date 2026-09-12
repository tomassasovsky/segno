import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/looper/model/interaction_mode.dart';

const _mute = ModeAction(InteractionMode.mute);
const _stop = CommandAction(ControlCommand.stop);
const _pedal1 = TrackPedalAction(0);

void main() {
  group('defaults', () {
    test('are the accepted pair and holds', () {
      const setup = PedalSetup();
      expect(setup.modePress, InteractionMode.mute);
      expect(setup.modeHold, InteractionMode.custom);
      expect(setup.recordHold, RecordHold.undoRecording);
      expect(setup.trackHold, TrackHold.armOverdub);
      expect(setup.custom, isEmpty);
      expect(setup.hasCustomAssignments, isFalse);
    });
  });

  group('the Custom map', () {
    test('keys the four track switches per bank and the rest per switch', () {
      var setup = const PedalSetup()
          .withCustom(
            PedalButton.track1,
            bank: 0,
            pair: const ControlGesturePair(press: _mute),
          )
          .withCustom(
            PedalButton.track1,
            bank: 1,
            pair: const ControlGesturePair(press: _stop),
          );
      expect(setup.customFor(PedalButton.track1, bank: 0).press, _mute);
      expect(setup.customFor(PedalButton.track1, bank: 1).press, _stop);

      // A transport switch holds ONE pair whatever the bank: the accepted
      // design says shared transport assignments do not duplicate across
      // banks, so writing it in B has to be the same slot as A.
      setup = setup.withCustom(
        PedalButton.undo,
        bank: 1,
        pair: const ControlGesturePair(press: _pedal1),
      );
      expect(setup.customFor(PedalButton.undo, bank: 0).press, _pedal1);
      expect(
        setup.custom.keys.where((k) => k.button == PedalButton.undo),
        hasLength(1),
      );
    });

    test('refuses MODE and BANK — the two the plate can never give up', () {
      for (final button in [PedalButton.mode, PedalButton.bank]) {
        final setup = const PedalSetup().withCustom(
          button,
          bank: 0,
          pair: const ControlGesturePair(press: _mute),
        );
        expect(setup.custom, isEmpty, reason: button.name);
      }
    });

    test('an emptied pair leaves no entry behind, so a cleared switch and an '
        'untouched one encode identically', () {
      final assigned = const PedalSetup().withCustom(
        PedalButton.stop,
        bank: 0,
        pair: const ControlGesturePair(press: _mute),
      );
      final cleared = assigned.withCustom(
        PedalButton.stop,
        bank: 0,
        pair: ControlGesturePair.empty,
      );
      expect(cleared.custom, isEmpty);
      expect(cleared.encode(), const PedalSetup().encode());
      expect(cleared, const PedalSetup());
    });

    test('clearedCustom empties both banks and both gestures and keeps the '
        'fixed Track controls', () {
      final setup =
          const PedalSetup(
                modePress: InteractionMode.fx,
                trackHold: TrackHold.clearTrack,
              )
              .withCustom(
                PedalButton.track2,
                bank: 1,
                pair: const ControlGesturePair(press: _mute, hold: _stop),
              )
              .withCustom(
                PedalButton.clear,
                bank: 0,
                pair: const ControlGesturePair(hold: _stop),
              );
      expect(setup.hasCustomAssignments, isTrue);

      final cleared = setup.clearedCustom();
      expect(cleared.custom, isEmpty);
      expect(cleared.hasCustomAssignments, isFalse);
      expect(cleared.modePress, InteractionMode.fx);
      expect(cleared.trackHold, TrackHold.clearTrack);
    });

    test('clearedCustom keeps the LED colours, which the confirmation '
        'promises', () {
      final setup = const PedalSetup()
          .withCustom(
            PedalButton.track2,
            bank: 1,
            pair: const ControlGesturePair(press: _mute),
          )
          .copyWith(
            palette: const PedalPalette()
                .withCustom(1, PedalColor.violet)
                .withChoice(PedalButton.track2, const CustomPaletteEntry(1)),
          );

      final cleared = setup.clearedCustom();
      expect(cleared.custom, isEmpty);
      expect(cleared.palette, setup.palette);
      expect(cleared.palette.colorFor(PedalButton.track2), PedalColor.violet);
    });
  });

  group('encoding', () {
    test('round-trips a full setup', () {
      final setup =
          const PedalSetup(
            modePress: InteractionMode.fx,
            modeHold: InteractionMode.mute,
            recordHold: RecordHold.none,
            trackHold: TrackHold.clearTrack,
          ).withCustom(
            PedalButton.recPlay,
            bank: 0,
            pair: const ControlGesturePair(press: _stop, hold: _mute),
          );
      expect(PedalSetup.decode(setup.encode()), setup);
    });

    test('two setups differing only in one gesture are not equal — the '
        'ordered flattening props compares on has to see through the map', () {
      final a = const PedalSetup().withCustom(
        PedalButton.undo,
        bank: 0,
        pair: const ControlGesturePair(press: _stop),
      );
      final b = const PedalSetup().withCustom(
        PedalButton.undo,
        bank: 0,
        pair: const ControlGesturePair(press: _stop, hold: _mute),
      );
      expect(a, isNot(b));
      final c = const PedalSetup().withCustom(
        PedalButton.stop,
        bank: 0,
        pair: const ControlGesturePair(press: _stop),
      );
      expect(a, isNot(c));
    });

    test('is byte-stable for equal setups built in different orders', () {
      final a = const PedalSetup()
          .withCustom(
            PedalButton.undo,
            bank: 0,
            pair: const ControlGesturePair(press: _stop),
          )
          .withCustom(
            PedalButton.recPlay,
            bank: 0,
            pair: const ControlGesturePair(press: _mute),
          );
      final b = const PedalSetup()
          .withCustom(
            PedalButton.recPlay,
            bank: 0,
            pair: const ControlGesturePair(press: _mute),
          )
          .withCustom(
            PedalButton.undo,
            bank: 0,
            pair: const ControlGesturePair(press: _stop),
          );
      expect(a.encode(), b.encode());
      expect(a, b);
    });

    test('a hold of null is omitted rather than written', () {
      final setup = const PedalSetup().copyWith(clearModeHold: true);
      expect(setup.encode(), isNot(contains('modeHold')));
      expect(PedalSetup.decode(setup.encode()).modeHold, isNull);
    });

    test('an unreadable blob decodes to the accepted defaults', () {
      for (final blob in ['', 'not json', '[]', '{']) {
        expect(PedalSetup.decode(blob), const PedalSetup(), reason: blob);
      }
    });

    test('an entry naming an action this build cannot honour is dropped, and '
        'the rest of the setup survives it', () {
      const blob =
          '{"modePress":"fx","custom":['
          '{"button":"undo","press":"direct:teleport:selected"},'
          '{"button":"stop","press":"command:stop"}]}';
      final setup = PedalSetup.decode(blob);
      expect(setup.modePress, InteractionMode.fx);
      expect(setup.customFor(PedalButton.undo, bank: 0).isEmpty, isTrue);
      expect(setup.customFor(PedalButton.stop, bank: 0).press, _stop);
    });

    test('a bank on a control that is not bank-keyed is corruption, not a '
        'second slot', () {
      const blob =
          '{"custom":[{"button":"undo","bank":1,"press":"command:stop"}]}';
      expect(PedalSetup.decode(blob).custom, isEmpty);
    });

    test('round-trips the LED palette with the assignments', () {
      final setup = const PedalSetup(modePress: InteractionMode.fx)
          .withCustom(
            PedalButton.stop,
            bank: 0,
            pair: const ControlGesturePair(press: _pedal1),
          )
          .copyWith(
            palette: const PedalPalette()
                .withCustom(1, const PedalColor(0xED, 0x63, 0x9B))
                .withChoice(PedalButton.mode, const CustomPaletteEntry(1))
                .withChoice(
                  PedalButton.bank,
                  const BuiltInPaletteEntry(PedalPaletteColor.green),
                ),
          );
      final decoded = PedalSetup.decode(setup.encode());
      expect(decoded, setup);
      expect(decoded.palette.colorFor(PedalButton.mode).rgb, 0xED639B);
      expect(decoded.palette.colorFor(PedalButton.bank), PedalColor.green);
    });

    test('a default palette adds nothing to the encoding', () {
      expect(const PedalSetup().encode().contains('palette'), isFalse);
    });

    test('two setups differing only in a colour are not equal', () {
      const setup = PedalSetup();
      final coloured = setup.copyWith(
        palette: const PedalPalette().withChoice(
          PedalButton.track1,
          const BuiltInPaletteEntry(PedalPaletteColor.red),
        ),
      );
      expect(coloured, isNot(setup));
    });
  });
}
