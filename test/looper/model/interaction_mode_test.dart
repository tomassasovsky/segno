import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/model/interaction_mode.dart';

void main() {
  group('InteractionMode', () {
    group('token', () {
      test('derives from the member name (new saves write "mute")', () {
        expect(InteractionMode.record.token, 'record');
        expect(InteractionMode.mute.token, 'mute');
        expect(InteractionMode.fx.token, 'fx');
        expect(InteractionMode.custom.token, 'custom');
      });
    });
  });
}
