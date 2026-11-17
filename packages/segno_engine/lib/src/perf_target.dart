import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Where and how one performance take is written (#1198): the capture
/// directory on its destination, where the live sidecar is rewritten, the
/// take's identity, and the part and ring sizes. Mirrors `le_perf_target`.
@immutable
class PerfTarget {
  /// Creates a [PerfTarget]. [takeId] is the take's 16-byte identity, minted
  /// when recording starts; it is copied.
  new({
    required this.captureDir,
    required Uint8List takeId,
    this.liveSidecarDir,
    this.volumeGeneration = internalVolume,
    this.partBytes = 0,
    this.ringSeconds = 0,
    this.reserveBytes,
    this.mirrorDir,
    this.checkpointMs = defaultCheckpointMs,
    this.idleStopSeconds = 0,
    this.maxSeconds = 0,
  }) : takeId = Uint8List.fromList(takeId) {
    if (takeId.length != takeIdBytes) {
      throw ArgumentError.value(takeId, 'takeId', 'must be 16 bytes');
    }
    if (ringSeconds < 0 || ringSeconds > maxRingSeconds) {
      throw ArgumentError.value(ringSeconds, 'ringSeconds');
    }
    if (partBytes < 0) throw ArgumentError.value(partBytes, 'partBytes');
    if (reserveBytes != null && reserveBytes! < 0) {
      throw ArgumentError.value(reserveBytes, 'reserveBytes');
    }
    if (checkpointMs < 0 || checkpointMs > 0x7fffffff) {
      throw ArgumentError.value(checkpointMs, 'checkpointMs');
    }
    if (idleStopSeconds < 0 || idleStopSeconds > 0x7fffffff) {
      throw ArgumentError.value(idleStopSeconds, 'idleStopSeconds');
    }
    if (maxSeconds < 0 || maxSeconds > 0x7fffffff) {
      throw ArgumentError.value(maxSeconds, 'maxSeconds');
    }
  }

  /// The length of a take id.
  static const int takeIdBytes = 16;

  /// The length of a part's header: RIFF, `fmt `, the 32-byte `sgno` chunk
  /// and the `data` chunk header. Mirrors `LE_PERF_PART_HEADER_BYTES`.
  static const int partHeaderBytes = 84;

  /// The stream number of input `n`'s raw recording (#1805) is this plus
  /// `n`; input `n` as heard is stream `1 + n`, the master stream 0.
  /// Mirrors `LE_PERF_RAW_STREAM_BASE`.
  static const int rawStreamBase = 100;

  /// How often a take is made durable: at most this much is lost to a
  /// power cut (#1198 D4).
  static const int defaultCheckpointMs = 5000;

  /// [volumeGeneration] for a take on Internal storage.
  static const int internalVolume = -1;

  /// The take's directory on its destination, created if missing.
  final String captureDir;

  /// The take's identity, written into every part's `sgno` chunk.
  final Uint8List takeId;

  /// Where `performance.json` is rewritten every drain cycle; null means
  /// [captureDir]. A take on a removable volume points this at Internal.
  final String? liveSidecarDir;

  /// The removable volume generation the take is armed on, or
  /// [internalVolume].
  final int volumeGeneration;

  /// The most one part file may hold, header included; 0 means the engine's
  /// 2,000,000,000.
  final int partBytes;

  /// Seconds each capture ring holds, up to [maxRingSeconds]; 0 means the
  /// engine default.
  final int ringSeconds;

  /// The most [ringSeconds] may ask for. Mirrors `LE_PERF_RING_SECONDS_MAX`.
  static const int maxRingSeconds = 8;

  /// Bytes the take leaves free on its destination, on top of
  /// [allowanceBytes]: the take stops at the last whole frame every stream
  /// can hold above it. Null means no budget; the take then stops only on a
  /// failed write.
  final int? reserveBytes;

  /// Room the engine keeps above [reserveBytes] for files it rewrites in
  /// place while a take runs. Mirrors `LE_PERF_ALLOWANCE_BYTES`.
  static const int allowanceBytes = 1 << 20;

  /// An Internal directory that receives a copy of every checkpoint, for a
  /// take on a removable volume; null for none.
  final String? mirrorDir;

  /// How often the engine makes the take durable, in ms; 0 checkpoints only
  /// when the take stops.
  final int checkpointMs;

  /// Seconds with nothing happening after which the take stops on its own
  /// (`PerfStopReason.idle`, #1767): no logged event (a press, a transport
  /// change, an edit) and no captured input over the playing level. 0 never
  /// stops it.
  final int idleStopSeconds;

  /// The longest the take runs, in seconds, before it stops on its own
  /// (`PerfStopReason.lengthLimit`); never past what the rendered master
  /// stem can hold in one file on FAT32 (4 GiB less one byte, header
  /// included). 0 sets no limit.
  final int maxSeconds;
}
