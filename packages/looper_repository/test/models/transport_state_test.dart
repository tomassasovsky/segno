import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('TransportState Song queue', () {
    test('defaults to no queued section or elapsed wait', () {
      const transport = TransportState();
      expect(transport.songQueuedTrack, isNull);
      expect(transport.songQueueProgress, 0);
    });

    test('target and progress both participate in value semantics', () {
      const idle = TransportState();
      const queued = TransportState(songQueuedTrack: 5);
      const advanced = TransportState(
        songQueuedTrack: 5,
        songQueueProgress: 0.5,
      );
      expect(idle, isNot(queued));
      expect(queued, isNot(advanced));
      expect(
        advanced,
        const TransportState(
          songQueuedTrack: 5,
          songQueueProgress: 0.5,
        ),
      );
      expect(
        advanced.hashCode,
        const TransportState(
          songQueuedTrack: 5,
          songQueueProgress: 0.5,
        ).hashCode,
      );
    });
  });
}
