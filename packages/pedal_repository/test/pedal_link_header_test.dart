import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';

/// The scalar constants `pedal_link.h` and [PedalLinkCodec] must agree on.
/// The golden fixtures pin the frames; this pins the numbers no frame
/// carries — the sync byte, the protocol version, the state length and the
/// hello cadence every liveness clock derives from.
void main() {
  group('pedal_link.h', () {
    final header = File(
      '../../firmware/console_board/pedal_link.h',
    ).readAsStringSync();

    int define(String name) {
      final match = RegExp('#define $name (0x[0-9A-Fa-f]+|\\d+)u').firstMatch(
        header,
      );
      expect(match, isNotNull, reason: '$name is not defined in pedal_link.h');
      return int.parse(match!.group(1)!);
    }

    test(
      'sync byte',
      () => expect(define('PEDAL_LINK_SYNC'), PedalLinkCodec.sync),
    );

    test(
      'protocol version',
      () => expect(
        define('PEDAL_LINK_PROTOCOL_VERSION'),
        PedalLinkCodec.protocolVersion,
      ),
    );

    test(
      'state payload length',
      () => expect(
        define('PEDAL_LINK_STATE_LEN'),
        PedalLinkCodec.statePayloadLength,
      ),
    );

    test(
      'hello interval',
      () =>
          expect(define('PEDAL_LINK_HELLO_MS'), PedalLinkCodec.helloIntervalMs),
    );

    test('the board outlives a lost hello, and the app outlives two', () {
      // The board darkens after PEDAL_LINK_FRAME_TIMEOUT_MS without a STATE;
      // segno answers every hello with one, so the timeout must span more
      // than one hello or a single lost reply blanks the panel. The app's
      // default helloTimeout likewise spans several hellos.
      expect(
        define('PEDAL_LINK_FRAME_TIMEOUT_MS'),
        greaterThanOrEqualTo(2 * PedalLinkCodec.helloIntervalMs),
      );
      final repo = PedalRepository(FakePedalLink());
      addTearDown(repo.dispose);
      expect(
        repo.helloTimeout,
        greaterThanOrEqualTo(PedalLinkCodec.helloInterval * 2),
      );
    });
  });
}
