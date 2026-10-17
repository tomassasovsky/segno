import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/tuner/application/tuner_settings.dart';

/// The foot Tuner's paging, pair muting and source fallback (pen 23/x,
/// `tuner-performance-study.js`; #1229).
void main() {
  LooperState rig(int inputs, {int excluded = 0, InputSetup? setup}) =>
      LooperState(
        status: EngineStatus(
          inputChannels: inputs,
          excludedInputMask: excluded,
        ),
        inputSetup: setup ?? const InputSetup.empty(),
      );

  FootTunerProjection project(
    LooperState looper, {
    FootTunerSelection selection = const FootTunerSelection(),
    TunerPreferences preferences = const TunerPreferences(),
  }) => projectFootTuner(looper, selection, preferences);

  List<int?> trackInputs(FootTunerProjection p) => [
    for (final button in [
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ])
      p[button].input,
  ];

  test('2 inputs: one page, two dimmed positions, Bank unavailable', () {
    final p = project(rig(2));
    expect(p.inputs, [0, 1]);
    expect(p.pageCount, 1);
    expect(p.source, 0);
    expect(trackInputs(p), [0, 1, null, null]);
    expect(p[PedalButton.track1].lit, isTrue);
    expect(p[PedalButton.track3].available, isFalse);
    expect(p[PedalButton.bank].available, isFalse);
    expect(p[PedalButton.bank].lit, isFalse);
  });

  test('4 inputs: one full page (pen 23/1)', () {
    final p = project(rig(4), preferences: const TunerPreferences(input: 2));
    expect(trackInputs(p), [0, 1, 2, 3]);
    expect(p.source, 2);
    expect(p[PedalButton.track3].lit, isTrue);
    expect(p[PedalButton.track1].lit, isFalse);
    expect(p[PedalButton.bank].available, isFalse);
    expect(p[PedalButton.mode].lit, isTrue);
    expect(p[PedalButton.recPlay].available, isFalse);
    expect(p[PedalButton.stop].lit, isTrue, reason: 'muted on entry');
  });

  test('6 inputs: two pages, Bank lit on the second', () {
    final first = project(rig(6));
    expect(first.pageCount, 2);
    expect(first[PedalButton.bank].available, isTrue);
    expect(first[PedalButton.bank].lit, isFalse);
    final second = project(
      rig(6),
      selection: const FootTunerSelection(page: 1),
      preferences: const TunerPreferences(input: 4),
    );
    expect(trackInputs(second), [4, 5, null, null]);
    expect(second[PedalButton.bank].lit, isTrue);
    expect(second[PedalButton.track1].lit, isTrue);
  });

  test('18 inputs: the last page is Inputs 17-18 with two empty positions '
      '(pen 23/5)', () {
    final p = project(
      rig(18),
      selection: const FootTunerSelection(page: 4),
      preferences: const TunerPreferences(input: 16),
    );
    expect(p.pageCount, 5);
    expect(p.pageInputs, [16, 17]);
    expect(trackInputs(p), [16, 17, null, null]);
    expect(p[PedalButton.track3].available, isFalse);
    expect(p[PedalButton.track4].available, isFalse);
    expect(p[PedalButton.bank].lit, isTrue);
    // A page past the end is clamped onto the last one.
    expect(
      project(rig(18), selection: const FootTunerSelection(page: 9)).page,
      4,
    );
  });

  test('a loopback capture is never tunable, and a stored input that is '
      'not tunable falls back to the first that is', () {
    final p = project(
      rig(4, excluded: 0x3),
      preferences: const TunerPreferences(input: 1),
    );
    expect(p.inputs, [2, 3]);
    expect(p.source, 2);
    expect(trackInputs(p), [2, 3, null, null]);
    // A stored input the device does not have falls back too.
    expect(
      project(rig(2), preferences: const TunerPreferences(input: 7)).source,
      0,
    );
  });

  test('muting a paired input mutes both members; unmuting mutes none', () {
    final paired = rig(4, setup: InputSetup(pairs: const {2: 0}));
    final p = project(paired, preferences: const TunerPreferences(input: 3));
    expect(p.mutedInputs, {2, 3});
    expect(
      project(
        paired,
        preferences: const TunerPreferences(input: 1),
      ).mutedInputs,
      {1},
    );
    final audible = project(
      paired,
      selection: const FootTunerSelection(muted: false),
      preferences: const TunerPreferences(input: 3),
    );
    expect(audible.mutedInputs, isEmpty);
    expect(audible.muted, isFalse);
    expect(audible[PedalButton.stop].lit, isFalse);
  });

  test('an empty device tunes nothing and offers nothing to press', () {
    final p = project(rig(0));
    expect(p.inputs, isEmpty);
    expect(p.hasSource, isFalse);
    expect(p.mutedInputs, isEmpty);
    expect(trackInputs(p), [null, null, null, null]);
    expect(p[PedalButton.stop].available, isFalse);
    expect(p[PedalButton.bank].available, isFalse);
    // The reference is still adjustable.
    expect(p[PedalButton.undo].available, isTrue);
    expect(p[PedalButton.clear].available, isTrue);
  });

  test('the reference is carried from the preferences', () {
    expect(
      project(
        rig(2),
        preferences: const TunerPreferences(referenceHz: 432),
      ).referenceHz,
      432,
    );
  });
}
