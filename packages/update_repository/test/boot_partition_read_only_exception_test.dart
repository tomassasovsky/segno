import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('BootPartitionReadOnlyException', () {
    test('names itself and carries the helper detail', () {
      const error = BootPartitionReadOnlyException('/boot is ro');
      expect(error.detail, '/boot is ro');
      expect('$error', 'BootPartitionReadOnlyException: /boot is ro');
    });
  });
}
