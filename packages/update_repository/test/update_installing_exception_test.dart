import 'package:flutter_test/flutter_test.dart';
import 'package:update_repository/update_repository.dart';

void main() {
  group('UpdateInstallingException', () {
    test('names itself and carries the helper detail', () {
      const error = UpdateInstallingException('RAUC is installing');
      expect(error.detail, 'RAUC is installing');
      expect('$error', 'UpdateInstallingException: RAUC is installing');
    });
  });
}
