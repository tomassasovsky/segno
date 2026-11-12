import 'dart:io';
import 'dart:typed_data';

/// The sample rate and length of a WAV file, read from its header.
///
/// Live's clips name both (`DefaultSampleRate`, `DefaultDuration`), and a
/// clip's length on the timeline comes from them, so they are read from the
/// file rather than assumed.
typedef WavInfo = ({int sampleRate, int frames});

/// Reads [path]'s `fmt ` and `data` chunks, or returns `null` when the file
/// is missing or is not a RIFF/WAVE file with both.
///
/// The frame count comes from the `data` chunk's size, limited to the bytes
/// the file actually holds: a writer that stopped before patching the size
/// leaves it at 0 or past the end of the file.
WavInfo? readWavInfo(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final raf = file.openSync();
  try {
    final length = raf.lengthSync();
    if (length < 12) return null;
    final riff = raf.readSync(12);
    if (String.fromCharCodes(riff.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(riff.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int? sampleRate;
    int? blockAlign;
    var offset = 12;
    while (offset + 8 <= length) {
      raf.setPositionSync(offset);
      final header = raf.readSync(8);
      final id = String.fromCharCodes(header.sublist(0, 4));
      final size = ByteData.sublistView(header).getUint32(4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && size >= 16 && body + 16 <= length) {
        final fmt = ByteData.sublistView(raf.readSync(16));
        sampleRate = fmt.getUint32(4, Endian.little);
        blockAlign = fmt.getUint16(12, Endian.little);
      } else if (id == 'data') {
        if (sampleRate == null || blockAlign == null) return null;
        if (sampleRate <= 0 || blockAlign <= 0) return null;
        final available = length - body;
        final bytes = size == 0 || size > available ? available : size;
        return (sampleRate: sampleRate, frames: bytes ~/ blockAlign);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  } finally {
    raf.closeSync();
  }
}
