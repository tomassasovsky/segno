import 'package:flutter_test/flutter_test.dart';
import 'package:storage_repository/storage_repository.dart';

/// Every pair in [values] is equal exactly when the indices are, and equal
/// values hash alike, so the values key maps and sets.
void expectValueSemantics(List<Object> values, List<int> identity) {
  for (var i = 0; i < values.length; i++) {
    for (var j = 0; j < values.length; j++) {
      expect(
        values[i] == values[j],
        identity[i] == identity[j],
        reason: '${values[i]} vs ${values[j]}',
      );
    }
  }
  expect({
    for (final value in values) value,
  }, hasLength(identity.toSet().length));
}

void main() {
  test('destinations: Internal is one place, a volume is its generation', () {
    expectValueSemantics(
      const [
        StorageDestination.internal(),
        StorageDestination.internal(),
        StorageDestination.removable(1),
        StorageDestination.removable(1),
        StorageDestination.removable(2),
      ],
      [0, 0, 1, 1, 2],
    );
  });

  test('failures tell their kinds apart', () {
    expectValueSemantics(
      const [
        StorageFailure.full(),
        StorageFailure.readOnly(),
        StorageFailure.volumeLost(1),
        StorageFailure.volumeLost(1),
        StorageFailure.volumeLost(2),
        StorageFailure.unsupported(),
        StorageFailure.io('a'),
        StorageFailure.io('b'),
      ],
      [0, 1, 2, 2, 3, 4, 5, 6],
    );
    expect(const StorageFailure.volumeLost(3), isA<Exception>());
  });

  test('eject outcomes tell their kinds apart', () {
    expectValueSemantics(
      const [
        EjectOutcome.safeToRemove(),
        EjectOutcome.cancelled(),
        EjectOutcome.failed('busy'),
        EjectOutcome.failed('busy'),
        EjectOutcome.failed('timeout'),
      ],
      [0, 1, 2, 2, 3],
    );
  });
}
