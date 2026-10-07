import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _take = '000102030405060708090a0b0c0d0e0f';

/// A stand-in for the engine's SHA-256 (the real one is injected by the
/// caller): deterministic and sensitive to every byte, which is all the slot
/// logic relies on.
String _digest(Uint8List bytes) {
  var h = 0x811C9DC5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(64, '0');
}

Map<String, dynamic> _part({
  int index = 1,
  int frames = 1000,
  int overs = 0,
  String? sha256 = _sha,
}) => {
  'index': index,
  'file': 'master-${index.toString().padLeft(3, '0')}.wav',
  'frames': frames,
  'bytes': 84 + 8 * frames,
  'overs': overs,
  'sha256': ?sha256,
};

Map<String, dynamic> _body({
  int sequence = 1,
  List<Object?>? parts,
  Map<String, Object?> overrides = const {},
}) => {
  'version': 1,
  'sequence': sequence,
  'take_id': _take,
  'boot_id': 'b5c4b7e5-6f0f-4f69-9d7f-6a9a3a8d2c11',
  'volume_generation': 3,
  'sample_rate': 48000,
  'encoding': 'f32',
  'frames': 1500,
  'overs': 2,
  'streams': [
    {
      'stream': 0,
      'channels': 2,
      'parts':
          parts ??
          [
            _part(overs: 2),
            _part(index: 2, frames: 500, sha256: null),
          ],
    },
  ],
  'events_bytes': 40,
  'layers': ['layer-0-0-1.pcm'],
  'written_at_ms': 1791244800000,
  ...overrides,
};

/// Serializes [body] the way the native slot writer does: the JSON object
/// without its closing brace, then `"checksum":"<digest of everything
/// before the key>"}`.
Uint8List _slot(Map<String, dynamic> body, {String? checksum}) {
  final open = jsonEncode(body);
  final head = '${open.substring(0, open.length - 1)},';
  final digest = checksum ?? _digest(Uint8List.fromList(utf8.encode(head)));
  return Uint8List.fromList(utf8.encode('$head"checksum":"$digest"}'));
}

void main() {
  group('RecordingFormat', () {
    final stereo = RecordingFormat(sampleRate: 48000, channels: 2);

    test('a 2 GB float part at 48 kHz stereo holds 1:26:48', () {
      expect(stereo.partBytes, 2000000000);
      expect(RecordingFormat.bitDepth, 32);
      expect(stereo.frameBytes, 8);
      expect(stereo.partFrames, 249999989);
      expect(stereo.fullPartBytes, 1999999996);
      final d = stereo.durationOf(stereo.partFrames);
      expect(d.inHours, 1);
      expect(d.inMinutes.remainder(60), 26);
      expect(d.inSeconds.remainder(60), 48);
      final mono = RecordingFormat(sampleRate: 48000, channels: 1);
      expect(mono.partFrames, 499999979);
      expect(mono.fullPartBytes, 2000000000);
    });

    test('remaining frames count every part header exactly', () {
      // 31 full parts of 1999999996 bytes, then 125000005 frames in a 32nd.
      expect(stereo.remainingFrames(63000000000), 7874999664);
      expect(stereo.bytesToAppend(7874999664), 63000000000);
      expect(stereo.bytesToAppend(7874999665), greaterThan(63000000000));
    });

    test('an open part has room before the next header', () {
      final small = RecordingFormat(
        sampleRate: 48000,
        channels: 1,
        partBytes: 84 + 4 * 100,
      );
      expect(small.partFrames, 100);
      // 40 frames left in the open part, then 84 + 4 * 10 for a new part.
      expect(small.bytesToAppend(50, openPartFrames: 60), 4 * 50 + 84);
      expect(small.remainingFrames(4 * 40, openPartFrames: 60), 40);
      expect(small.remainingFrames(4 * 40 + 84 + 4, openPartFrames: 60), 41);
      expect(small.remainingFrames(4 * 40 + 84 + 3, openPartFrames: 60), 40);
      expect(small.bytesToAppend(1, openPartFrames: 100), 84 + 4);
      expect(small.bytesToAppend(1), 84 + 4);
      expect(small.bytesToAppend(0), 0);
      expect(small.remainingFrames(0), 0);
      expect(small.remainingFrames(-5), 0);
      expect(small.remainingFrames(84 + 3), 0);
    });

    test('streams stop together at the same whole frame', () {
      final mono = RecordingFormat(sampleRate: 48000, channels: 1);
      final input = RecordingFormat(sampleRate: 48000, channels: 2);
      // Mono master and one stereo input, both without a part: two headers,
      // then 12 bytes a frame.
      expect(
        RecordingFormat.remainingFramesTogether([
          (format: mono, openPartFrames: null),
          (format: input, openPartFrames: null),
        ], 84 + 84 + 12 * 500),
        500,
      );
      expect(RecordingFormat.remainingFramesTogether([], 1000), 0);
    });

    test('rejects impossible formats and compares by value', () {
      expect(
        () => RecordingFormat(sampleRate: 0, channels: 2),
        throwsArgumentError,
      );
      expect(
        () => RecordingFormat(sampleRate: 48000, channels: 0),
        throwsArgumentError,
      );
      expect(
        () => RecordingFormat(sampleRate: 48000, channels: 2, partBytes: 91),
        throwsArgumentError,
      );
      expect(stereo, RecordingFormat(sampleRate: 48000, channels: 2));
      expect(
        stereo.hashCode,
        RecordingFormat(sampleRate: 48000, channels: 2).hashCode,
      );
      expect(
        stereo == RecordingFormat(sampleRate: 96000, channels: 2),
        isFalse,
      );
    });
  });

  group('TakePart', () {
    test('round-trips a sealed and an open part with its overs', () {
      final sealed = TakePart.fromJson({'stream': 0, ..._part(overs: 3)});
      expect(sealed.isSealed, isTrue);
      expect(sealed.overs, 3);
      expect(sealed.toJson(), {'stream': 0, ..._part(overs: 3)});
      expect(TakePart.fromJson(sealed.toJson()), sealed);
      expect(TakePart.fromJson(sealed.toJson()).hashCode, sealed.hashCode);
      final open = TakePart.fromJson(_part(sha256: null), stream: 3);
      expect(open.stream, 3);
      expect(open.isSealed, isFalse);
      expect(open.toJson().containsKey('sha256'), isFalse);
      // A part listed before overs were counted reads 0.
      expect(
        TakePart.fromJson({'stream': 0, ..._part()..remove('overs')}).overs,
        0,
      );
    });

    test('refuses malformed entries', () {
      for (final bad in <Map<String, dynamic>>[
        _part(), // no stream at all
        {'stream': -1, ..._part()},
        {'stream': 0, ..._part(index: 0)},
        {'stream': 0, ..._part(), 'file': ''},
        {'stream': 0, ..._part(), 'file': '../x.wav'},
        {'stream': 0, ..._part(), 'file': r'a\b.wav'},
        {'stream': 0, ..._part(), 'frames': -1},
        {'stream': 0, ..._part(), 'bytes': 83},
        {'stream': 0, ..._part(), 'overs': -1},
        {'stream': 0, ..._part(), 'overs': '2'},
        {'stream': 0, ..._part(), 'sha256': 'ABC'},
        {'stream': 0, ..._part(), 'sha256': 7},
        {'stream': 0, ..._part(), 'index': 1.5},
      ]) {
        expect(
          () => TakePart.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('TakeCheckpoint', () {
    test('reads a slot the native writer produced', () {
      final c = TakeCheckpoint.fromSlot(_slot(_body()), digest: _digest);
      expect(c.sequence, 1);
      expect(c.takeId, _take);
      expect(c.bootId, 'b5c4b7e5-6f0f-4f69-9d7f-6a9a3a8d2c11');
      expect(c.volumeGeneration, 3);
      expect(c.sampleRate, 48000);
      expect(c.frames, 1500);
      expect(c.overs, 2);
      expect(c.streams.single.stream, 0);
      expect(c.streams.single.channels, 2);
      expect(c.streams.single.frames, 1500);
      expect(c.streams.single.parts.first.overs, 2);
      expect(c.streams.single.parts.last.isSealed, isFalse);
      expect(c.eventsBytes, 40);
      expect(c.layers, ['layer-0-0-1.pcm']);
      expect(c.writtenAt, DateTime.utc(2026, 10, 6));
    });

    test('takes the newer valid slot and falls back when one is torn', () {
      final older = _slot(_body());
      final newer = _slot(_body(sequence: 2, overrides: {'frames': 2000}));
      expect(
        TakeCheckpoint.fromSlots(older, newer, digest: _digest).frames,
        2000,
      );
      expect(
        TakeCheckpoint.fromSlots(newer, older, digest: _digest).frames,
        2000,
      );
      // One flipped byte in the newer slot: its checksum fails.
      final torn = Uint8List.fromList(newer);
      torn[40] ^= 0x01;
      expect(
        TakeCheckpoint.fromSlots(older, torn, digest: _digest).frames,
        1500,
      );
      // A truncated slot (a write cut short) fails too.
      expect(
        TakeCheckpoint.fromSlots(
          older,
          Uint8List.sublistView(newer, 0, newer.length - 10),
          digest: _digest,
        ).sequence,
        1,
      );
      expect(
        TakeCheckpoint.fromSlots(null, older, digest: _digest).sequence,
        1,
      );
      expect(
        () => TakeCheckpoint.fromSlots(torn, null, digest: _digest),
        throwsFormatException,
      );
      expect(
        () => TakeCheckpoint.fromSlots(null, null, digest: _digest),
        throwsFormatException,
      );
    });

    test('refuses a slot whose checksum is wrong or missing', () {
      expect(
        () => TakeCheckpoint.fromSlot(
          _slot(_body(), checksum: '0' * 64),
          digest: _digest,
        ),
        throwsFormatException,
      );
      expect(
        () => TakeCheckpoint.fromSlot(
          Uint8List.fromList(utf8.encode(jsonEncode(_body()))),
          digest: _digest,
        ),
        throwsFormatException,
      );
      expect(
        () => TakeCheckpoint.fromSlot(
          Uint8List.fromList(utf8.encode('{"checksum": [')),
          digest: _digest,
        ),
        throwsFormatException,
      );
    });

    test('refuses another version, encoding or shape', () {
      for (final bad in <Map<String, dynamic>>[
        _body(overrides: {'version': 2}),
        _body(overrides: {'encoding': 'pcm24'}),
        _body(overrides: {'sequence': -1}),
        _body(overrides: {'take_id': 'XYZ'}),
        _body(overrides: {'boot_id': 1}),
        _body(overrides: {'volume_generation': '3'}),
        _body(overrides: {'sample_rate': 0}),
        _body(overrides: {'frames': -1}),
        _body(overrides: {'overs': -1}),
        _body(overrides: {'streams': 'none'}),
        _body(overrides: {'events_bytes': -1}),
        _body(overrides: {'layers': 'x'}),
        _body(overrides: {'written_at_ms': 'now'}),
        _body(
          overrides: {
            'streams': ['x'],
          },
        ),
        _body(
          overrides: {
            'streams': [
              {'stream': 0, 'channels': 0, 'parts': <Object>[]},
            ],
          },
        ),
        _body(parts: ['x']),
        _body(parts: [_part(index: 2)]),
        _body(parts: [_part(), _part()]),
        _body(
          parts: [
            {'stream': 1, ..._part()},
          ],
        ),
        _body(
          overrides: {
            'layers': [3],
          },
        ),
      ]) {
        expect(
          () => TakeCheckpoint.fromSlot(_slot(bad), digest: _digest),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('trusts files beyond it only in the same boot on the same mount', () {
      final c = TakeCheckpoint.fromSlot(_slot(_body()), digest: _digest);
      const boot = 'b5c4b7e5-6f0f-4f69-9d7f-6a9a3a8d2c11';
      expect(
        c.trustsFilesBeyond(currentBootId: boot, currentGeneration: 3),
        isTrue,
      );
      // A pulled and re-inserted stick: same boot, new generation.
      expect(
        c.trustsFilesBeyond(currentBootId: boot, currentGeneration: 4),
        isFalse,
      );
      // A power cut: another boot.
      expect(
        c.trustsFilesBeyond(currentBootId: 'other', currentGeneration: 3),
        isFalse,
      );
      // No boot id where the platform has none.
      final unknown = TakeCheckpoint.fromSlot(
        _slot(_body(overrides: {'boot_id': ''})),
        digest: _digest,
      );
      expect(
        unknown.trustsFilesBeyond(currentBootId: '', currentGeneration: 3),
        isFalse,
      );
    });
  });

  group('PerformanceManifest parts', () {
    test('reads the take id, parts and overs the drain listed', () {
      final manifest = PerformanceManifest.fromJson({
        'take_id': _take,
        'overs': 5,
        'parts': [
          {'stream': 0, ..._part(overs: 5)},
          {'stream': 1, ..._part(sha256: null)},
        ],
      });
      expect(manifest.takeId, _take);
      expect(manifest.overs, 5);
      expect(manifest.parts.map((p) => p.stream), [0, 1]);
      expect(manifest.parts.first.overs, 5);
      expect(manifest.parts.last.isSealed, isFalse);
    });

    test('a capture written before ordered parts has none', () {
      final manifest = PerformanceManifest.fromJson(const {});
      expect(manifest.takeId, isNull);
      expect(manifest.overs, 0);
      expect(manifest.parts, isEmpty);
    });
  });
}
