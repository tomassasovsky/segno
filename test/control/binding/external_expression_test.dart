import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_expression.dart';

void main() {
  const gain = MasterGainTarget();
  const volume = TrackVolumeTarget(3);

  test('byte-domain calibration preserves both wiring directions', () {
    final forward = ExpressionCalibration(heel: 24, toe: 250);
    final reverse = ExpressionCalibration(heel: 250, toe: 24);
    expect(forward.positionOf(24), 0);
    expect(forward.positionOf(137), closeTo(0.5, 0.001));
    expect(forward.positionOf(250), 1);
    expect(reverse.positionOf(250), 0);
    expect(reverse.positionOf(137), closeTo(0.5, 0.001));
    expect(reverse.positionOf(24), 1);
    expect(reverse.positionOf(255), 0);
    expect(ExpressionCalibration.fromJson(reverse.toJson()), reverse);
  });

  test('25 raw counts fail and 26 pass in either direction', () {
    for (final pair in [(10, 35), (35, 10)]) {
      expect(
        () => ExpressionCalibration(heel: pair.$1, toe: pair.$2),
        throwsFormatException,
      );
    }
    for (final pair in [(10, 36), (36, 10)]) {
      expect(
        ExpressionCalibration(heel: pair.$1, toe: pair.$2).isUsable,
        isTrue,
      );
    }
  });

  test('explicit invalid raw calibration rejects instead of defaulting', () {
    for (final json in [
      {'heel': 0},
      {'heel': 0.0, 'toe': 255},
      {'heel': -1, 'toe': 255},
      {'heel': 0, 'toe': 256},
      {'heel': 50, 'toe': 50},
    ]) {
      expect(() => ExpressionCalibration.fromJson(json), throwsFormatException);
    }
  });

  test('one travel fans out through independent reversed target ranges', () {
    final travel = ExpressionCalibration(heel: 20, toe: 220);
    final position = travel.positionOf(70)!;
    final normal = ExpressionMapping(target: gain, heel: 0.2, toe: 0.8);
    final reversed = ExpressionMapping(target: volume, heel: 0.9, toe: 0.1);
    expect(normal.valueAt(position), closeTo(0.35, 0.001));
    expect(reversed.valueAt(position), closeTo(0.7, 0.001));
    expect(ExpressionMapping.fromJson(reversed.toJson()), reversed);
  });

  test('rows keep identity and order through endpoint edit and repoint', () {
    final initial = ExternalExpressionSetup(
      mappings: [
        ExpressionMapping(target: gain, heel: 0.2),
        ExpressionMapping(target: volume, heel: 0.3),
      ],
    );
    final edited = initial.withMapping(
      initial.mappingFor(gain)!.copyWith(toe: 0.7),
    );
    expect(edited.mappings.map((row) => row.target), [gain, volume]);
    expect(edited.mappings.first.heel, 0.2);
    expect(edited.mappings.first.toe, 0.7);
    expect(ExternalExpressionSetup.fromJson(edited.toJson()), edited);
  });

  test('public lists are detached and duplicate target identities reject', () {
    final source = [ExpressionMapping(target: gain)];
    final setup = ExternalExpressionSetup(mappings: source);
    source.add(ExpressionMapping(target: volume));
    expect(setup.mappings.length, 1);
    expect(setup.mappings.clear, throwsUnsupportedError);
    expect(
      () => ExternalExpressionSetup(
        mappings: [
          ExpressionMapping(target: gain),
          ExpressionMapping(target: gain, heel: 0.4),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => ExternalExpressionSetup.fromJson({
        'mappings': [
          ExpressionMapping(target: gain).toJson(),
          ExpressionMapping(target: gain, heel: 0.4).toJson(),
        ],
      }),
      throwsFormatException,
    );
  });

  test('malformed explicit endpoints and rows reject without clamping', () {
    final target = gain.canonicalString();
    for (final value in [double.nan, double.infinity, -0.1, 1.1]) {
      expect(
        () => ExpressionMapping.fromJson({
          'target': target,
          'heel': value,
          'toe': 0.8,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => ExternalExpressionSetup.fromJson(const {
        'mappings': [42],
      }),
      throwsFormatException,
    );
    expect(
      () => ExternalExpressionSetup.fromJson(const {'calibration': 'bad'}),
      throwsFormatException,
    );
  });

  test(
    'constructor rejects invalid targets but retains missing rig targets',
    () {
      expect(
        () => ExpressionMapping(target: const TrackVolumeTarget(-1)),
        throwsFormatException,
      );
      expect(
        () => ExpressionMapping(
          target: const FxParamTarget(
            address: FxAddress(stage: FxStage.allTracks, index: 2),
            slotId: 's',
            param: 0,
          ),
        ),
        throwsFormatException,
      );
      final missing = ExpressionMapping(target: const TrackVolumeTarget(999));
      expect(ExternalExpressionSetup(mappings: [missing]).mappings, [missing]);
    },
  );

  test('a new level mapping tops out at unity gain at full travel', () {
    final mapping = ExpressionMapping(target: volume);
    // Literal oracle: 0 dB is linear gain 1.0.
    expect(volume.toDomain(mapping.valueAt(1)), closeTo(1.0, 1e-9));
    expect(ExpressionMapping(target: gain).toe, 1);
  });

  test('a stored literal 1.0 on a level mapping reads as unity; other '
      'values and targets keep theirs', () {
    final stored = ExpressionMapping.fromJson({
      'target': volume.canonicalString(),
      'heel': 0,
      'toe': 1.0,
    });
    expect(volume.toDomain(stored.valueAt(1)), closeTo(1.0, 1e-9));
    expect(
      ExpressionMapping.fromJson({
        'target': volume.canonicalString(),
        'toe': .95,
      }).toe,
      .95,
    );
    expect(
      ExpressionMapping.fromJson({
        'target': gain.canonicalString(),
        'toe': 1.0,
      }).toe,
      1,
    );
    expect(
      ExpressionMapping.fromJson({
        'target': const MonitorVolumeTarget(0).canonicalString(),
        'toe': 1.0,
      }).toe,
      1,
    );
  });
}
