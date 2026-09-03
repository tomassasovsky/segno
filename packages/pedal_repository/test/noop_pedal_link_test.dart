import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

void main() {
  group('NoopPedalLink', () {
    test('never speaks, swallows sends, and closes cleanly', () async {
      final link = NoopPedalLink();
      final repo = PedalRepository(link);
      expect(repo.status, PedalLinkStatus.disconnected);
      repo.pushState(PedalStateFrame.blank());
      await pumpEventQueue();
      expect(repo.status, PedalLinkStatus.disconnected);
      await repo.dispose();
      await expectLater(link.inbound, emitsDone);
    });
  });
}
