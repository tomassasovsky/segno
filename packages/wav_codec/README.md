# wav_codec

Standalone library for the WAV files Segno writes. `WavCodec` encodes and
decodes 32-bit IEEE-float WAV, the format of loop stems and mixdowns in a
`.segno` session bundle. `RecordedPartHeader` and `RecordedPartWriter` handle
the ordered float parts a performance recording is written as.
`session_repository` and `performance_repository` depend on it. It has no
Flutter dependency.

## Usage

```dart
import 'dart:typed_data';

import 'package:wav_codec/wav_codec.dart';

final bytes = WavCodec.encodeFloat32(
  samples: Float32List.fromList([0, 0.5, -0.5, 0]), // interleaved
  sampleRate: 48000,
  channels: 2,
);
final wav = WavCodec.decodeFloat32(bytes);
print('${wav.frames} frames at ${wav.sampleRate} Hz');

final writer = RecordedPartWriter.create(
  '/path/to/master-001.wav',
  RecordedPartHeader(
    sampleRate: 48000,
    channels: 2,
    takeId: takeId, // 16 bytes
    stream: 0, // 0 is the main output, 1 + n is input n
    partIndex: 1,
  ),
);
writer.append(interleavedFrames);
final sealed = writer.seal();
```

## Notes

- Everything is little-endian on every host.
- `decodeFloat32` accepts only 32-bit float files and throws
  `FormatException` for anything else. Playback, preview and recovery decode
  audio in the engine (`le_backing_decode_file`), not here.
- A recorded part is at most 2,000,000,000 bytes, header included
  (`RecordedPartWriter.defaultPartBytes`). Its 84-byte header carries a
  `sgno` chunk with the take id, stream and part index, so a part can be
  recognized after it is copied or renamed. The native drain
  (`perf_drain.c`) writes the same layout.
- Samples are written unchanged, including values above full scale;
  `RecordedPartWriter.overs` counts them.
- `RecordedPartWriter` does synchronous file I/O; use it from a background
  isolate.

## Testing

Pure Dart package:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
