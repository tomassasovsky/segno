import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The scalar constants `pedal_link.h` and [PedalLinkCodec] must agree on.
/// The golden fixtures pin the frames; this pins the numbers no frame
/// carries — the sync byte, the protocol version, the state length and the
/// hello cadence every liveness clock derives from. The firmware's own
/// liveness relation (frame timeout vs hello) is the C test's.
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

    test('hello is the frozen three-byte message', () {
      // The one frame shape no protocol revision may change: it is how a
      // board built against another revision is recognised as incompatible
      // rather than read as line noise.
      expect(PedalLinkCodec.payloadLengthFor(PedalLinkCodec.typeHello), 3);
    });
  });
}
