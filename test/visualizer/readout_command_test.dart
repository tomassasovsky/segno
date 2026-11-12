import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show RecordTiming;
import 'package:segno/visualizer/readout_command.dart';

void main() {
  group(ReadoutCommand, () {
    const commands = <ReadoutCommand>[
      TempoNudge(0.1),
      TempoNudge(-1),
      TempoSet(92.5),
      TempoTap(),
      TempoClear(),
      SignatureSet(6, 8),
      LengthSet(0),
      LengthSet(8),
      TimingSet(RecordTiming.bar),
      TimingSet(RecordTiming.sixteenth),
    ];

    for (final command in commands) {
      test('${command.toMap()} survives the link', () {
        expect(ReadoutCommand.fromMap(command.toMap()), command);
      });
    }

    test('an unknown or missing kind is no command', () {
      expect(ReadoutCommand.fromMap(const {'kind': 'tempo.reset'}), isNull);
      expect(ReadoutCommand.fromMap(const {'delta': 1}), isNull);
      expect(ReadoutCommand.fromMap('tempo.tap'), isNull);
      expect(ReadoutCommand.fromMap(null), isNull);
    });

    test('a missing or garbled field is no command', () {
      expect(ReadoutCommand.fromMap(const {'kind': 'tempo.nudge'}), isNull);
      expect(
        ReadoutCommand.fromMap(const {'kind': 'tempo.nudge', 'delta': '1'}),
        isNull,
      );
      expect(
        ReadoutCommand.fromMap(const {'kind': 'tempo.set', 'bpm': double.nan}),
        isNull,
      );
      expect(
        ReadoutCommand.fromMap(const {
          'kind': 'signature.set',
          'num': 6,
          'den': 8.0,
        }),
        isNull,
      );
      expect(
        ReadoutCommand.fromMap(const {'kind': 'length.set', 'bars': 4.5}),
        isNull,
      );
      expect(
        ReadoutCommand.fromMap(const {'kind': 'timing.set', 'timing': 'beat'}),
        isNull,
      );
    });

    test('a refusal survives the link by name', () {
      for (final refusal in ReadoutRefusal.values) {
        expect(ReadoutRefusal.fromName(refusal.name), refusal);
      }
      expect(ReadoutRefusal.fromName('tempoClearSomehow'), isNull);
      expect(ReadoutRefusal.fromName(null), isNull);
      expect(ReadoutRefusal.fromName(3), isNull);
    });

    test('a whole number arrives as a nudge or a tempo', () {
      expect(
        ReadoutCommand.fromMap(const {'kind': 'tempo.nudge', 'delta': 1}),
        const TempoNudge(1),
      );
      expect(
        ReadoutCommand.fromMap(const {'kind': 'tempo.set', 'bpm': 120}),
        const TempoSet(120),
      );
    });
  });
}
