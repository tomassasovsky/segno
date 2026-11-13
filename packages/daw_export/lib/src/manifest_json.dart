/// Shared, tiny JSON-shape helpers for reading a decoded `performance.json`
/// map — used by both `manifest_reader.dart` and `fx_chains.dart`, which
/// otherwise each parse the same `armSnapshot`/`disarmSnapshot` shape for
/// two genuinely different outputs (track/clip layout vs. an FX-chain
/// summary). Factored out so the one thing they'd otherwise duplicate byte
/// for byte — "what does a tracks[] array look like" — can't silently drift
/// between the two.
library;

/// Returns `snapshot['tracks']` as a typed list, or an empty list if
/// `snapshot` isn't a `Map` or has no (or a non-list) `tracks` field —
/// tolerant of a missing/malformed `armSnapshot`/`disarmSnapshot` rather
/// than throwing.
List<Map<String, dynamic>> tracksOf(dynamic snapshot) {
  if (snapshot is! Map<String, dynamic>) return const [];
  final tracks = snapshot['tracks'];
  if (tracks is! List) return const [];
  return [for (final t in tracks) t as Map<String, dynamic>];
}

/// What a capture calls looper track [channel]: the name recorded at arm
/// (#1799), or `Track N` (1-based) for a track without one.
String trackNameOf(Map<String, dynamic> manifest, int channel) {
  for (final t in tracksOf(manifest['armSnapshot'])) {
    final name = t['name'];
    if (t['channel'] == channel && name is String && name.isNotEmpty) {
      return name;
    }
  }
  return 'Track ${channel + 1}';
}

/// The hardware inputs a capture recorded as heard
/// (`channel_layout.captured_inputs`: those monitored at arm), in order.
List<int> capturedInputsOf(Map<String, dynamic> manifest) {
  final layout = manifest['channel_layout'];
  final inputs = layout is Map<String, dynamic>
      ? layout['captured_inputs']
      : null;
  if (inputs is! List) return const [];
  return [
    for (final i in inputs)
      if (i is num) i.toInt(),
  ]..sort();
}

/// The inputs a capture recorded raw (`channel_layout.raw_inputs`, #1805:
/// every input the device had, monitored or not), in order; empty for a
/// capture from before it.
List<int> rawInputsOf(Map<String, dynamic> manifest) {
  final layout = manifest['channel_layout'];
  final inputs = layout is Map<String, dynamic> ? layout['raw_inputs'] : null;
  if (inputs is! List) return const [];
  return [
    for (final i in inputs)
      if (i is num) i.toInt(),
  ]..sort();
}

/// The stream number of input `n`'s raw recording is this plus `n`
/// (docs/formats/performance-manifest-format.md); as heard, input `n` is
/// stream `1 + n`.
const int kRawStreamBase = 100;

/// What a capture calls hardware input [input]: the name recorded at arm
/// (#1799), or `Input N` (1-based) for an input without one.
String inputNameOf(Map<String, dynamic> manifest, int input) {
  final arm = manifest['armSnapshot'];
  final inputs = arm is Map<String, dynamic> ? arm['inputs'] : null;
  if (inputs is List) {
    for (final entry in inputs) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['name'];
      if (entry['input'] == input && name is String && name.isNotEmpty) {
        return name;
      }
    }
  }
  return 'Input ${input + 1}';
}

/// The name of the reference track holding the captured output.
const String kMasterTrackName = 'Master (as heard)';
