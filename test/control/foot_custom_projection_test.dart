import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_custom.dart';
import 'package:segno/looper/model/interaction_mode.dart';

void main() {
  const fade = TrackOperationAction(
    operation: TrackOperation.fade,
    scope: SelectedTrackScope(),
  );
  const future = UnavailableAction('instrument:transpose');
  final setup = const PedalSetup()
      .withCustom(
        PedalButton.track1,
        bank: 0,
        pair: const ControlGesturePair(
          press: SelectTrackAction(0),
          hold: fade,
        ),
      )
      .withCustom(
        PedalButton.track1,
        bank: 1,
        pair: const ControlGesturePair(press: SelectTrackAction(4)),
      )
      // Hold only.
      .withCustom(
        PedalButton.undo,
        bank: 0,
        pair: const ControlGesturePair(
          hold: CommandAction(ControlCommand.redo),
        ),
      )
      .withCustom(
        PedalButton.clear,
        bank: 0,
        pair: const ControlGesturePair(press: future),
      )
      .withCustom(
        PedalButton.stop,
        bank: 0,
        pair: const ControlGesturePair(
          press: CommandAction(ControlCommand.recordPerformance),
        ),
      );

  ControlState state({
    int bank = 0,
    Map<PedalButton, bool> lit = const {},
    bool unavailable = false,
  }) => ControlState(
    mode: InteractionMode.custom,
    pedalSetup: setup,
    pedalSetupUnavailable: unavailable,
    activeBank: bank,
    customLit: lit,
  );

  test('each switch reads its assignment for the bank in view', () {
    final a = projectFootCustom(state());
    expect(a.bank, 0);
    expect(a[PedalButton.track1].press, const SelectTrackAction(0));
    expect(a[PedalButton.track1].hold, fade);
    final b = projectFootCustom(state(bank: 1));
    expect(b.bank, 1);
    expect(b[PedalButton.track1].press, const SelectTrackAction(4));
    expect(b[PedalButton.track1].hold, isNull);
    // A switch that is not bank-keyed reads the same in both banks.
    expect(
      b[PedalButton.stop].press,
      const CommandAction(ControlCommand.recordPerformance),
    );
  });

  test('assigned switches take contacts; only unassigned ones are inert', () {
    final face = projectFootCustom(state());
    expect(face[PedalButton.track1].enabled, isTrue);
    expect(face[PedalButton.undo].enabled, isTrue, reason: 'hold only');
    // An action this build cannot run still takes the press, so the
    // refusal can say so.
    expect(face[PedalButton.clear].enabled, isTrue);
    expect(face[PedalButton.clear].unavailable, isTrue);
    expect(face[PedalButton.track1].unavailable, isFalse);
    for (final button in [
      PedalButton.recPlay,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ]) {
      expect(face[button].enabled, isFalse, reason: button.name);
    }
    expect(face[PedalButton.mode].enabled, isTrue);
    expect(face[PedalButton.bank].enabled, isTrue);
  });

  test('a setup that could not be loaded assigns nothing', () {
    final face = projectFootCustom(state(unavailable: true));
    for (final pedal in face.pedals.values) {
      expect(
        pedal.enabled,
        pedal.role != FootCustomRole.assignment,
        reason: pedal.button.name,
      );
    }
  });

  test('lit switches are the published LED value; Exit is lit and Bank '
      'lights on bank B', () {
    final face = projectFootCustom(
      state(lit: const {PedalButton.stop: true, PedalButton.track1: false}),
    );
    expect(face[PedalButton.stop].lit, isTrue);
    expect(face[PedalButton.track1].lit, isFalse);
    expect(face[PedalButton.recPlay].lit, isFalse);
    expect(face[PedalButton.mode].lit, isTrue);
    expect(face[PedalButton.bank].lit, isFalse);
    expect(projectFootCustom(state(bank: 1))[PedalButton.bank].lit, isTrue);
  });
}
