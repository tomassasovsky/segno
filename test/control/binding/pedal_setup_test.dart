import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_binding.dart';
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
      expect(setup.palette, const PedalPalette());
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
      expect(cleared.palette, setup.palette);
    });
  });

  group('encoding', () {
    test('palette saves with gestures, round-trips, and keeps equal bytes', () {
      final palette = const PedalPalette()
          .withCustom(1, const PedalColor(0, 0, 0))
          .withChoice(PedalButton.stop, const CustomPaletteEntry(1));
      final setup = const PedalSetup(
        trackHold: TrackHold.clearTrack,
      ).copyWith(palette: palette);
      expect(PedalSetup.decode(setup.encode()), setup);
      expect(
        PedalSetup.decode(
          setup.encode(),
        ).palette.colorFor(PedalButton.stop).rgb,
        0,
      );
      expect(
        PedalSetup.decode(const PedalSetup().encode()).palette.isEmpty,
        isTrue,
      );
    });

    test('an explicit invalid palette rejects the entire setup', () {
      for (final blob in [
        '{"palette":null}',
        '{"palette":42}',
        '{"palette":{"leds":{"mode":"custom:1"}}}',
        '{"palette":{"leds":{"futureButton":"white"}}}',
        '{"palette":{"customs":[{"number":1,"rgb":0},{"number":1,"rgb":1}]}}',
      ]) {
        expect(
          () => PedalSetup.decode(blob),
          throwsFormatException,
          reason: blob,
        );
      }
    });

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

    test(
      'a copied setup owns its custom map after the caller mutates theirs',
      () {
        const key = PedalBindingKey(button: PedalButton.track1, bank: 0);
        final callerMap = <PedalBindingKey, ControlGesturePair>{
          key: const ControlGesturePair(press: _mute),
        };
        final setup = const PedalSetup().copyWith(custom: callerMap);
        final encoded = setup.encode();
        callerMap.clear();
        expect(setup.encode(), encoded);
        expect(setup.custom[key]?.press, _mute);
        expect(setup.custom.clear, throwsUnsupportedError);
      },
    );

    test('a hold of null is omitted rather than written', () {
      final setup = const PedalSetup().copyWith(clearModeHold: true);
      expect(setup.encode(), isNot(contains('modeHold')));
      expect(PedalSetup.decode(setup.encode()).modeHold, isNull);
    });

    test('an explicit unreadable blob cannot become a fresh setup', () {
      for (final blob in ['', 'not json', '[]', '{']) {
        expect(() => PedalSetup.decode(blob), throwsFormatException);
      }
    });

    test('an unavailable action retains its exact identity through Save', () {
      const blob =
          '{"modePress":"fx","custom":['
          '{"button":"undo","press":"direct:teleport:selected"},'
          '{"button":"stop","press":"command:stop"}]}';
      final setup = PedalSetup.decode(blob);
      expect(setup.modePress, InteractionMode.fx);
      expect(
        setup.customFor(PedalButton.undo, bank: 0).press,
        const UnavailableAction('direct:teleport:selected'),
      );
      expect(setup.customFor(PedalButton.stop, bank: 0).press, _stop);
      expect(PedalSetup.decode(setup.encode()), setup);
    });

    test('a bank on a control that is not bank-keyed is corruption, not a '
        'second slot', () {
      const blob =
          '{"custom":[{"button":"undo","bank":1,"press":"command:stop"}]}';
      expect(() => PedalSetup.decode(blob), throwsFormatException);
    });

    test('malformed explicit choices never become different actions', () {
      for (final blob in [
        '{"modePress":"sideways"}',
        '{"modeHold":42}',
        '{"recordHold":"eraseAll"}',
        '{"trackHold":"unknown"}',
        '{"custom":[{"button":"track1","bank":0.5,"press":"command:stop"}]}',
        '{"custom":[{"button":"undo","press":9}]}',
        '{"custom":[{"button":"undo","press":null}]}',
      ]) {
        expect(
          () => PedalSetup.decode(blob),
          throwsFormatException,
          reason: blob,
        );
      }
    });
  });
}
