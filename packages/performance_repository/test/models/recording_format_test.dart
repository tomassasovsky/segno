import 'package:flutter_test/flutter_test.dart';
import 'package:performance_repository/performance_repository.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _take = '000102030405060708090a0b0c0d0e0f';

Map<String, dynamic> _part({
  int index = 1,
  int frames = 1000,
  String? sha256 = _sha,
}) => {
  'index': index,
  'file': 'master-${index.toString().padLeft(3, '0')}.wav',
  'frames': frames,
  'bytes': 84 + 6 * frames,
  'sha256': ?sha256,
};

Map<String, dynamic> _checkpoint({
  Object? version = 1,
  List<Object?>? parts,
  Map<String, Object?> overrides = const {},
}) => {
  'version': version,
  'take_id': _take,
  'boot_id': 'b5c4b7e5-6f0f-4f69-9d7f-6a9a3a8d2c11',
  'sample_rate': 48000,
  'encoding': 'pcm24',
  'frames': 1500,
  'streams': [
    {
      'stream': 0,
      'channels': 2,
      'parts': parts ?? [_part(), _part(index: 2, frames: 500, sha256: null)],
    },
  ],
  'events_bytes': 40,
  'layers': ['layer-0-0-1.pcm'],
  'written_at_ms': 1791244800000,
  ...overrides,
};

void main() {
  group('RecordingFormat', () {
    final stereo = RecordingFormat(sampleRate: 48000, channels: 2);

    test('a 2 GB part at 48 kHz stereo holds 1:55:44', () {
      expect(stereo.partBytes, 2000000000);
      expect(stereo.frameBytes, 6);
      expect(stereo.partFrames, 333333319);
      expect(stereo.fullPartBytes, 1999999998);
      final d = stereo.durationOf(stereo.partFrames);
      expect(d.inHours, 1);
      expect(d.inMinutes.remainder(60), 55);
      expect(d.inSeconds.remainder(60), 44);
    });

    test('remaining frames count every part header exactly', () {
      // 31 full parts of 1999999998 bytes, then 166666663 frames in a 32nd.
      expect(stereo.remainingFrames(63000000000), 10499999552);
      expect(stereo.bytesToAppend(10499999552), 63000000000);
      expect(stereo.bytesToAppend(10499999553), greaterThan(63000000000));
    });

    test('an open part has room before the next header', () {
      final small = RecordingFormat(
        sampleRate: 48000,
        channels: 1,
        partBytes: 84 + 3 * 100,
      );
      expect(small.partFrames, 100);
      // 40 frames left in the open part, then 84 + 3 * 10 for a new part.
      expect(small.bytesToAppend(50, openPartFrames: 60), 3 * 50 + 84);
      expect(small.remainingFrames(3 * 40, openPartFrames: 60), 40);
      expect(small.remainingFrames(3 * 40 + 84 + 3, openPartFrames: 60), 41);
      expect(small.remainingFrames(3 * 40 + 84 + 2, openPartFrames: 60), 40);
      // A full open part has no room; no open part pays the first header.
      expect(small.bytesToAppend(1, openPartFrames: 100), 84 + 3);
      expect(small.bytesToAppend(1), 84 + 3);
      expect(small.bytesToAppend(0), 0);
      expect(small.remainingFrames(0), 0);
      expect(small.remainingFrames(-5), 0);
      expect(small.remainingFrames(84 + 2), 0);
    });

    test('streams stop together at the same whole frame', () {
      final mono = RecordingFormat(sampleRate: 48000, channels: 1);
      final input = RecordingFormat(sampleRate: 48000, channels: 2);
      // Mono master and one stereo input, both without a part: two headers,
      // then 9 bytes a frame.
      expect(
        RecordingFormat.remainingFramesTogether([
          (format: mono, openPartFrames: null),
          (format: input, openPartFrames: null),
        ], 84 + 84 + 9 * 500),
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
        () => RecordingFormat(sampleRate: 48000, channels: 2, partBytes: 89),
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
    test('round-trips a sealed and an open part', () {
      final sealed = TakePart.fromJson({'stream': 0, ..._part()});
      expect(sealed.isSealed, isTrue);
      expect(sealed.toJson(), {'stream': 0, ..._part()});
      expect(TakePart.fromJson(sealed.toJson()), sealed);
      expect(TakePart.fromJson(sealed.toJson()).hashCode, sealed.hashCode);
      final open = TakePart.fromJson(_part(sha256: null), stream: 3);
      expect(open.stream, 3);
      expect(open.isSealed, isFalse);
      expect(open.toJson().containsKey('sha256'), isFalse);
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
    test('reads the native checkpoint', () {
      final c = TakeCheckpoint.fromJson(_checkpoint());
      expect(c.takeId, _take);
      expect(c.bootId, 'b5c4b7e5-6f0f-4f69-9d7f-6a9a3a8d2c11');
      expect(c.sampleRate, 48000);
      expect(c.frames, 1500);
      expect(c.streams.single.stream, 0);
      expect(c.streams.single.channels, 2);
      expect(c.streams.single.frames, 1500);
      expect(c.streams.single.parts.last.isSealed, isFalse);
      expect(c.eventsBytes, 40);
      expect(c.layers, ['layer-0-0-1.pcm']);
      expect(c.writtenAt, DateTime.utc(2026, 10, 6));
    });

    test('refuses another version, encoding or shape', () {
      for (final bad in <Map<String, dynamic>>[
        _checkpoint(version: 2),
        _checkpoint(overrides: {'encoding': 'f32'}),
        _checkpoint(overrides: {'take_id': 'XYZ'}),
        _checkpoint(overrides: {'boot_id': 1}),
        _checkpoint(overrides: {'sample_rate': 0}),
        _checkpoint(overrides: {'frames': -1}),
        _checkpoint(overrides: {'streams': 'none'}),
        _checkpoint(overrides: {'events_bytes': -1}),
        _checkpoint(overrides: {'layers': 'x'}),
        _checkpoint(overrides: {'written_at_ms': 'now'}),
        _checkpoint(
          overrides: {
            'streams': ['x'],
          },
        ),
        _checkpoint(
          overrides: {
            'streams': [
              {'stream': 0, 'channels': 0, 'parts': <Object>[]},
            ],
          },
        ),
        _checkpoint(parts: ['x']),
        _checkpoint(parts: [_part(index: 2)]),
        _checkpoint(parts: [_part(), _part()]),
        _checkpoint(
          parts: [
            {'stream': 1, ..._part()},
          ],
        ),
        _checkpoint(
          overrides: {
            'layers': [3],
          },
        ),
      ]) {
        expect(
          () => TakeCheckpoint.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('PerformanceManifest parts', () {
    test('reads the take id and parts the drain listed', () {
      final manifest = PerformanceManifest.fromJson({
        'take_id': _take,
        'parts': [
          {'stream': 0, ..._part()},
          {'stream': 1, ..._part(sha256: null)},
        ],
      });
      expect(manifest.takeId, _take);
      expect(manifest.parts.map((p) => p.stream), [0, 1]);
      expect(manifest.parts.last.isSealed, isFalse);
    });

    test('a capture written before ordered parts has none', () {
      final manifest = PerformanceManifest.fromJson(const {});
      expect(manifest.takeId, isNull);
      expect(manifest.parts, isEmpty);
    });
  });
}
