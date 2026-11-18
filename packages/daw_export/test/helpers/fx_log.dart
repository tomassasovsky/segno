import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/daw_export.dart';

/// `events.log` entries for an effect chain's changes, as the engine logs
/// them (`docs/formats/performance-event-log-format.md`).
abstract final class FxLog {
  /// `LE_CMD_SET_LANE_FX`: lane [lane] of [channel]'s slot [slot] to
  /// [type].
  static RawLogEntry laneType(
    int frame,
    int channel,
    int lane,
    int slot,
    int type,
  ) => _entry(frame, 20, _fx(channel, lane, slot, type));

  /// `LE_CMD_SET_LANE_FX_COUNT`.
  static RawLogEntry laneCount(int frame, int channel, int lane, int count) =>
      _entry(frame, 21, _fx(channel, lane, count, 0));

  /// `LE_PLOG_SET_LANE_FX_PARAM`: setting [param] of [slot] to [value].
  static RawLogEntry laneParam(
    int frame,
    int channel,
    int lane,
    int slot,
    int param,
    double value,
  ) => _entry(frame, 306, _fx(channel, lane, slot << 8 | param, _bits(value)));

  /// `LE_PLOG_SET_LANE_FX_ENABLED`.
  static RawLogEntry laneEnabled(
    int frame,
    int channel,
    int lane,
    int slot, {
    required bool on,
  }) => _entry(frame, 310, _fx(channel, lane, slot, on ? 1 : 0));

  /// `LE_PLOG_SET_LANE_FX_CHAIN_ENABLED` (a `lanef` payload).
  static RawLogEntry laneChain(
    int frame,
    int channel,
    int lane, {
    required bool on,
  }) {
    final b = ByteData(16)
      ..setInt32(0, channel, Endian.little)
      ..setInt32(4, lane, Endian.little)
      ..setFloat32(8, on ? 1 : 0, Endian.little);
    return _entry(frame, 311, b);
  }

  /// `LE_CMD_SET_MONITOR_INPUT_FX`.
  static RawLogEntry monitorType(int frame, int input, int slot, int type) =>
      _entry(frame, 31, _fx(input, 0, slot, type));

  /// `LE_CMD_SET_MONITOR_INPUT_FX_COUNT`.
  static RawLogEntry monitorCount(int frame, int input, int count) =>
      _entry(frame, 32, _fx(input, 0, count, 0));

  /// `LE_PLOG_SET_MONITOR_FX_PARAM`.
  static RawLogEntry monitorParam(
    int frame,
    int input,
    int slot,
    int param,
    double value,
  ) => _entry(frame, 307, _fx(input, -1, slot << 8 | param, _bits(value)));

  /// `LE_PLOG_SET_MONITOR_FX_ENABLED`.
  static RawLogEntry monitorEnabled(
    int frame,
    int input,
    int slot, {
    required bool on,
  }) => _entry(frame, 312, _fx(input, -1, slot, on ? 1 : 0));

  /// `LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED` (a generic payload).
  static RawLogEntry monitorChain(int frame, int input, {required bool on}) {
    final b = ByteData(16)
      ..setInt32(0, input, Endian.little)
      ..setFloat32(4, on ? 1 : 0, Endian.little);
    return _entry(frame, 313, b);
  }

  /// An entry of a code no chain reads (`LE_CMD_SET_VOLUME`).
  static RawLogEntry other(int frame) => _entry(frame, 7, _fx(0, 0, 0, 0));

  /// Writes [entries] as `<dir>/events.log` at [sampleRate].
  static void write(String dir, int sampleRate, List<RawLogEntry> entries) {
    final out = BytesBuilder()
      ..add('PLEV'.codeUnits)
      ..add((ByteData(4)..setUint32(0, 17, Endian.little)).buffer.asUint8List())
      ..add(
        (ByteData(
          4,
        )..setInt32(0, sampleRate, Endian.little)).buffer.asUint8List(),
      );
    for (final e in entries) {
      out
        ..add(
          (ByteData(12)
                ..setUint64(0, e.frame, Endian.little)
                ..setInt32(8, e.code, Endian.little))
              .buffer
              .asUint8List(),
        )
        ..add(Uint8List.sublistView(e.payload));
    }
    File('$dir/events.log').writeAsBytesSync(out.toBytes());
  }

  static RawLogEntry _entry(int frame, int code, ByteData payload) =>
      RawLogEntry(frame: frame, code: code, payload: payload);

  static ByteData _fx(int a, int b, int c, int d) => ByteData(16)
    ..setInt32(0, a, Endian.little)
    ..setInt32(4, b, Endian.little)
    ..setInt32(8, c, Endian.little)
    ..setInt32(12, d, Endian.little);

  static int _bits(double value) => (ByteData(
    4,
  )..setFloat32(0, value, Endian.little)).getInt32(0, Endian.little);
}
