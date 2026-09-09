import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/src/daw_project.dart';

/// Reads `events.log`
/// (`docs/design/performance-event-log-format.md`) directly — a
/// fixed-width binary format, parsed here with no dependency on
/// `segno_engine` (own-input-model rule, same as `DawManifestReader`'s
/// `performance.json` reading). Every field offset below mirrors that
/// document's entry layout exactly.
abstract final class EventLogReader {
  static const int _headerBytes = 12;
  static const int _entryBytes = 28;

  // Values from perf_log_ring.h / segno_engine_api.h's audited command
  // table — never imported (this package has no segno_engine dependency),
  // reproduced verbatim as this reader's own constants.
  static const int _codeSetVolume = 7;
  static const int _codeSetMute = 8;
  static const int _codeSetLaneVolume = 28;
  static const int _codeSetLaneMute = 29;
  static const int _codeSetTrackSolo = 59;

  /// Reads `<captureDir>/events.log` and returns every entry in file order
  /// (already frame-monotonic *within* each of the two producer streams,
  /// per the format doc — not globally sorted; callers that need one merged
  /// timeline, like [readChannelAutomation], sort themselves), or `null` if
  /// the file is missing, too short for even a header, or the header's
  /// magic doesn't match (a graceful no-op, same convention as
  /// `DawManifestReader.read`'s missing/corrupt manifest handling).
  static List<RawLogEntry>? readAll(String captureDir) {
    final file = File('$captureDir/events.log');
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length < _headerBytes) return null;

    final header = ByteData.sublistView(bytes, 0, _headerBytes);
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != 'PLEV') return null;
    final sampleRate = header.getInt32(8, Endian.little);
    if (sampleRate <= 0) return null;

    final entries = <RawLogEntry>[];
    var offset = _headerBytes;
    while (offset + _entryBytes <= bytes.length) {
      final entry = ByteData.sublistView(bytes, offset, offset + _entryBytes);
      entries.add(
        RawLogEntry(
          frame: entry.getUint64(0, Endian.little),
          code: entry.getInt32(8, Endian.little),
          payload: ByteData.sublistView(bytes, offset + 12, offset + 28),
        ),
      );
      offset += _entryBytes;
    }
    return entries;
  }

  /// Extracts channel `channel`'s lane-0 volume-ride and audibility
  /// breakpoints (in beat units at [tempoBpm]) from [entries], matching the
  /// scope precedent the native offline renderer already established
  /// (`perf_render.c`, parts 7-8): only lane 0's track-addressed
  /// volume/mute — both the legacy generic-arm commands
  /// (`LE_CMD_SET_VOLUME`/`LE_CMD_SET_MUTE`, which the engine maps to lane 0
  /// for backward compatibility) and the explicit lane-addressed ones
  /// (`LE_CMD_SET_LANE_VOLUME`/`LE_CMD_SET_LANE_MUTE` with `lane == 0`) are
  /// read; a non-zero explicit lane is ignored, same scope restriction as
  /// the native renderer. Entries are sorted by frame before conversion —
  /// `events.log`'s two producer streams are not globally pre-sorted (see
  /// the format doc).
  ///
  /// The returned `mute` lane is Ableton's track activator (1 == audible),
  /// so it carries the channel's *effective* audibility rather than its raw
  /// mute flag: `!muted && (no track soloed || this track soloed)`. Solo
  /// (`LE_CMD_SET_TRACK_SOLO`, generic arm, non-zero == soloed) is tracked
  /// across ALL channels because a solo on another track silences this one
  /// and clearing the last solo restores it exactly as its mute flag left
  /// it. [initiallyMuted] and [initiallySoloed] seed that state from the
  /// arm-time manifest (events are logged relative to arm); a breakpoint is
  /// emitted only when the effective audibility actually changes, so a
  /// redundant gesture (muting an already-muted track, unmuting under
  /// someone else's solo) adds nothing.
  static ({List<AutomationBreakpoint> volume, List<AutomationBreakpoint> mute})
  readChannelAutomation(
    List<RawLogEntry> entries,
    int channel,
    int sampleRate,
    double tempoBpm, {
    bool initiallyMuted = false,
    Set<int> initiallySoloed = const {},
  }) {
    final sorted = [...entries]..sort((a, b) => a.frame.compareTo(b.frame));
    final volume = <AutomationBreakpoint>[];
    final mute = <AutomationBreakpoint>[];

    double beatOf(int frame) => (frame / sampleRate) * (tempoBpm / 60.0);

    var muted = initiallyMuted;
    final soloed = {...initiallySoloed};
    bool audible() => !muted && (soloed.isEmpty || soloed.contains(channel));
    var lastAudible = audible();

    for (final e in sorted) {
      switch (e.code) {
        case _codeSetVolume:
          if (e.payload.getInt32(0, Endian.little) == channel) {
            volume.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                value: e.payload.getFloat32(4, Endian.little),
              ),
            );
          }
        case _codeSetLaneVolume:
          if (e.payload.getInt32(0, Endian.little) == channel &&
              e.payload.getInt32(4, Endian.little) == 0) {
            volume.add(
              AutomationBreakpoint(
                beat: beatOf(e.frame),
                value: e.payload.getFloat32(8, Endian.little),
              ),
            );
          }
        case _codeSetMute:
          if (e.payload.getInt32(0, Endian.little) == channel) {
            muted = e.payload.getFloat32(4, Endian.little) != 0.0;
          }
        case _codeSetLaneMute:
          if (e.payload.getInt32(0, Endian.little) == channel &&
              e.payload.getInt32(4, Endian.little) == 0) {
            muted = e.payload.getFloat32(8, Endian.little) != 0.0;
          }
        case _codeSetTrackSolo:
          final soloChannel = e.payload.getInt32(0, Endian.little);
          if (e.payload.getFloat32(4, Endian.little) != 0.0) {
            soloed.add(soloChannel);
          } else {
            soloed.remove(soloChannel);
          }
        default:
          continue;
      }
      // Ableton's activator is on == audible; the logged mute flag is
      // inverted from that (1 == muted == inaudible), and a solo elsewhere
      // silences this channel without touching its own flag.
      final nowAudible = audible();
      if (nowAudible == lastAudible) continue;
      lastAudible = nowAudible;
      mute.add(
        AutomationBreakpoint(
          beat: beatOf(e.frame),
          value: nowAudible ? 1.0 : 0.0,
        ),
      );
    }

    return (volume: volume, mute: mute);
  }
}

/// One raw `events.log` entry: the frame it was logged at, its
/// `le_command_code`/`le_perf_log_code` value, and its 16-byte union
/// payload (interpretation keyed on [code], see
/// `docs/design/performance-event-log-format.md`).
class RawLogEntry {
  /// Creates a [RawLogEntry].
  const RawLogEntry({
    required this.frame,
    required this.code,
    required this.payload,
  });

  /// Frames elapsed since arm.
  final int frame;

  /// One of `le_command_code`'s audited values, or an `le_perf_log_code`.
  final int code;

  /// The raw 16-byte union payload.
  final ByteData payload;
}
