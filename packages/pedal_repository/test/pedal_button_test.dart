import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('PedalButton', () {
    test('the wire index is the declaration order and is stable', () {
      expect(PedalButton.values.map((b) => b.index), [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, //
      ]);
      expect(PedalButton.recPlay.index, 0);
      expect(PedalButton.bank.index, 9);
    });

    test('fromIndex maps every assigned index and rejects the rest', () {
      for (final button in PedalButton.values) {
        expect(PedalButtonIndex.fromIndex(button.index), button);
      }
      expect(PedalButtonIndex.fromIndex(-1), isNull);
      expect(PedalButtonIndex.fromIndex(PedalButton.values.length), isNull);
    });
  });
}
