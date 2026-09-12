import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_expression.dart';

void main() {
  group('ExpressionCalibration', () {
    test('positions a reading between the ends it was taught', () {
      const travel = ExpressionCalibration(heel: 0.2, toe: 0.8);
      expect(travel.positionOf(0.2), 0);
      expect(travel.positionOf(0.8), 1);
      expect(travel.positionOf(0.5), closeTo(0.5, 0.0001));
    });

    test('a pedal wired backwards needs no special case', () {
      // Toe below heel. The accepted design takes this calibration rather than
      // asking the player to rewire a pedal that works.
      const travel = ExpressionCalibration(heel: 0.9, toe: 0.1);
      expect(travel.positionOf(0.9), 0, reason: 'the heel end is still 0');
      expect(travel.positionOf(0.1), 1);
      expect(travel.positionOf(0.5), closeTo(0.5, 0.0001));
      expect(travel.span, closeTo(0.8, 0.0001));
      // Past either end of a reversed travel, the clamp has to land on the end
      // it went past — not on the one the unsigned distance is nearer.
      expect(travel.positionOf(1), 0);
      expect(travel.positionOf(0), 1);
    });

    test('a reading outside the taught travel stops at the end', () {
      const travel = ExpressionCalibration(heel: 0.3, toe: 0.7);
      expect(travel.positionOf(0), 0);
      expect(travel.positionOf(1), 1);
    });

    test('a travel too short to divide by positions nothing', () {
      // Readings as the wire delivers them: steps of 1/127. Ten of those is
      // under a tenth of the range.
      const short = ExpressionCalibration(heel: 10 / 127, toe: 20 / 127);
      expect(short.isUsable, isFalse);
      expect(
        short.positionOf(15 / 127),
        isNull,
        reason: 'dividing by this would turn pot noise into a full sweep',
      );
      const enough = ExpressionCalibration(heel: 10 / 127, toe: 30 / 127);
      expect(enough.isUsable, isTrue);
      expect(enough.positionOf(20 / 127), closeTo(0.5, 0.0001));
    });

    test('two ends captured at the same place divide by nothing', () {
      const none = ExpressionCalibration(heel: 0.4, toe: 0.4);
      expect(none.span, 0);
      expect(none.positionOf(0.4), isNull);
    });

    test('survives a round trip, and a corrupt end reads as untaught', () {
      const travel = ExpressionCalibration(heel: 0.15, toe: 0.95);
      expect(ExpressionCalibration.fromJson(travel.toJson()), travel);
      expect(ExpressionCalibration.fromJson({'heel': 0.1}), isNull);
      expect(
        ExpressionCalibration.fromJson({'heel': 'down', 'toe': 1}),
        isNull,
      );
    });

    test('an end the wire could not have produced reads as untaught', () {
      // Clamping would invent a travel the foot never took. The jack reading as
      // untaught is the honest answer, and the screen has a state for it.
      expect(ExpressionCalibration.fromJson({'heel': -0.5, 'toe': 1}), isNull);
      expect(ExpressionCalibration.fromJson({'heel': 0, 'toe': 4}), isNull);
    });
  });

  group('ExpressionMapping', () {
    const target = MasterGainTarget();

    test('sweeps between its two endpoints', () {
      const mapping = ExpressionMapping(target: target, heel: 0.2, toe: 0.9);
      expect(mapping.valueAt(0), closeTo(0.2, 0.0001));
      expect(mapping.valueAt(1), closeTo(0.9, 0.0001));
      expect(mapping.valueAt(0.5), closeTo(0.55, 0.0001));
    });

    test('a toe below the heel inverts the control', () {
      // Not a mistake to correct: it is how a player closes a filter as the
      // pedal goes down.
      const mapping = ExpressionMapping(target: target, heel: 1, toe: 0.25);
      expect(mapping.valueAt(0), closeTo(1, 0.0001));
      expect(mapping.valueAt(1), closeTo(0.25, 0.0001));
    });

    test('a new control covers the whole of its range', () {
      const mapping = ExpressionMapping(target: target);
      expect(mapping.heel, 0);
      expect(mapping.toe, 1);
    });

    test('survives a round trip', () {
      const mapping = ExpressionMapping(
        target: FxParamTarget(
          address: FxAddress(stage: FxStage.track, index: 2),
          slotId: 'slot-7f2a',
          param: 1,
        ),
        heel: 0.1,
        toe: 0.4,
      );
      expect(ExpressionMapping.fromJson(mapping.toJson()), mapping);
    });

    test('a target that does not decode drops the whole row', () {
      // Different from a target that decodes but is gone from the rig: that
      // row stays and says it is unavailable. A row that cannot say what it
      // used to drive is nothing a player could repair.
      expect(ExpressionMapping.fromJson({'heel': 0.0, 'toe': 1.0}), isNull);
      expect(ExpressionMapping.fromJson({'target': 'not json'}), isNull);
      expect(ExpressionMapping.fromJson({'target': 42}), isNull);
    });

    test('endpoints read from outside the range are held inside it', () {
      final mapping = ExpressionMapping.fromJson({
        'target': target.canonicalString(),
        'heel': -3.0,
        'toe': 9.0,
      })!;
      expect(mapping.heel, 0);
      expect(mapping.toe, 1);
    });
  });

  group('ExternalExpressionSetup', () {
    const master = MasterGainTarget();
    const volume = TrackVolumeTarget(1);

    test('a jack calibrated but unassigned is not empty', () {
      // The taught travel is work done to the jack; a setup that read as empty
      // would throw it away on the next save.
      const taught = ExternalExpressionSetup(
        calibration: ExpressionCalibration(heel: 0, toe: 1),
      );
      expect(taught.isEmpty, isFalse);
      expect(ExternalExpressionSetup.empty.isEmpty, isTrue);
      expect(
        const ExternalExpressionSetup(
          mappings: [ExpressionMapping(target: master)],
        ).isEmpty,
        isFalse,
      );
    });

    test('editing a control keeps its row where it was', () {
      const setup = ExternalExpressionSetup(
        mappings: [
          ExpressionMapping(target: master),
          ExpressionMapping(target: volume),
        ],
      );
      final edited = setup.withMapping(
        const ExpressionMapping(target: master, heel: 0.4, toe: 0.6),
      );
      expect(edited.mappings.length, 2);
      expect(edited.mappings.first.target, master);
      expect(edited.mappings.first.heel, 0.4);
      expect(edited.mappings.last.target, volume);
    });

    test('a control not yet mapped is appended', () {
      final setup = ExternalExpressionSetup.empty.withMapping(
        const ExpressionMapping(target: master),
      );
      expect(setup.mappings.single.target, master);
      expect(setup.mappingFor(master), isNotNull);
      expect(setup.mappingFor(volume), isNull);
    });

    test('removing a control leaves the others', () {
      const setup = ExternalExpressionSetup(
        mappings: [
          ExpressionMapping(target: master),
          ExpressionMapping(target: volume),
        ],
      );
      expect(setup.withoutMapping(master).mappings.single.target, volume);
      expect(
        setup.withoutMapping(const TrackVolumeTarget(7)).mappings.length,
        2,
      );
    });

    test('a stored file holding one target twice loses the repeat', () {
      final setup = ExternalExpressionSetup.fromJson({
        'mappings': [
          const ExpressionMapping(target: master, heel: 0.1, toe: 0.2).toJson(),
          const ExpressionMapping(target: master, heel: 0.8, toe: 0.9).toJson(),
        ],
      });
      expect(setup.mappings.length, 1);
      expect(
        setup.mappings.single.heel,
        0.1,
        reason: 'the first is kept, not whichever wrote last',
      );
    });

    test('survives a round trip and drops what nothing touched', () {
      const setup = ExternalExpressionSetup(
        calibration: ExpressionCalibration(heel: 0.05, toe: 0.95),
        mappings: [ExpressionMapping(target: volume, heel: 0.2, toe: 0.7)],
      );
      expect(ExternalExpressionSetup.fromJson(setup.toJson()), setup);
      expect(ExternalExpressionSetup.empty.toJson(), isEmpty);
    });

    test('an unreadable stored setup reads as untouched', () {
      final setup = ExternalExpressionSetup.fromJson(const {
        'calibration': 'broken',
        'mappings': 'broken',
      });
      expect(setup, ExternalExpressionSetup.empty);
    });

    test('clearing the travel needs its own flag', () {
      const setup = ExternalExpressionSetup(
        calibration: ExpressionCalibration(heel: 0, toe: 1),
      );
      expect(setup.copyWith().calibration, isNotNull);
      expect(setup.copyWith(clearCalibration: true).calibration, isNull);
    });
  });
}
