import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
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
      expect(setup.leds, const PedalLedMap());
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
      expect(cleared.leds, setup.leds);
    });
  });

  group('encoding', () {
    test('LED colours save with gestures, round-trip, keep equal bytes', () {
      final leds = const PedalLedMap()
          .withColor(
            InteractionMode.mute,
            PedalLedGroup.tracks,
            PedalLedState.armed,
            const PedalColor(0, 0, 0),
          )
          .withCustomColor(
            const PedalBindingKey(button: PedalButton.track2, bank: 1),
            PedalLedState.pressed,
            const PedalColor(1, 2, 3),
          );
      final setup = const PedalSetup(
        trackHold: TrackHold.clearTrack,
      ).copyWith(leds: leds);
      final decoded = PedalSetup.decode(setup.encode());
      expect(decoded, setup);
      expect(decoded.encode(), setup.encode());
      expect(
        decoded.leds
            .colorFor(
              InteractionMode.mute,
              PedalLedGroup.tracks,
              PedalLedState.armed,
            )
            .rgb,
        0,
      );
      expect(
        PedalSetup.decode(const PedalSetup().encode()).leds.isEmpty,
        isTrue,
      );
    });

    test('a stored setup from the retired palette resets its colours', () {
      final decoded = PedalSetup.decode(
        '{"modePress":"fx","palette":{"leds":{"stop":"violet"}}}',
      );
      expect(decoded.modePress, InteractionMode.fx);
      expect(decoded.leds, const PedalLedMap());
    });

    test('an explicit invalid LED map rejects the entire setup', () {
      const duplicate =
          '{"leds":{"custom":[{"button":"undo","lit":0},'
          '{"button":"undo","lit":1}]}}';
      for (final blob in [
        '{"leds":null}',
        '{"leds":42}',
        '{"leds":{"future":{}}}',
        '{"leds":{"modes":{"record":{"tracks":{"armed":0}}}}}',
        '{"leds":{"modes":{"record":{"tracks":{"playing":"red"}}}}}',
        '{"leds":{"modes":{"record":{"tracks":{"playing":16777216}}}}}',
        '{"leds":{"modes":{"future":{}}}}',
        '{"leds":{"modes":{"custom":{"tracks":{"pressed":0}}}}}',
        '{"leds":{"custom":[{"button":"mode","lit":0}]}}',
        '{"leds":{"custom":[{"button":"track1","lit":0}]}}',
        '{"leds":{"custom":[{"button":"stop","glow":0}]}}',
        duplicate,
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
