import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:session_repository/src/models/session.dart';
import 'package:session_repository/src/session_exception.dart';
import 'package:session_repository/src/session_repository.dart';

/// The oldest manifest schema this build converts: the one master and the
/// appliances in the field write (#1196). Anything older is refused with
/// [SessionUnconvertible].
const int oldestConvertibleSessionVersion = 7;

/// What a conversion step may read besides the manifest, and where it records
/// every field it filled in, moved or changed.
class SessionMigrationContext {
  /// Creates a context that fills formerly global settings from [live].
  SessionMigrationContext({this.live = const SessionSettings()});

  /// The player's settings at the moment of opening. A schema-7 session never
  /// carried the settings that master kept as global preferences (sync, rec
  /// dub, auto record, default length, record timing), and opening one on
  /// master left them as they were; the conversion keeps them the same way.
  final SessionSettings live;

  final List<String> _notes = [];

  /// Every field the conversion filled in, moved or changed, in step order.
  List<String> get notes => List.unmodifiable(_notes);

  /// Records that [field] was [what].
  void note(String field, String what) => _notes.add('$field: $what');
}

/// One schema bump: rewrites a decoded `vN` manifest in place into `vN+1`,
/// except for the `version` key, which the driver advances.
typedef SessionMigrationStep =
    void Function(
      Map<String, dynamic> manifest,
      SessionMigrationContext context,
    );

/// One step per schema bump, keyed by the version it reads. Each later bump
/// adds its own entry here; the chain from [oldestConvertibleSessionVersion]
/// to [Session.formatVersion] must be complete, and a test enforces it.
///
/// Schemas 8 and 9 were each written by two parallel histories that the trunk
/// later merged (the September slices and the October 1 reconstruction), so
/// the steps for 7, 8 and 9 also accept the slice spellings.
@visibleForTesting
const Map<int, SessionMigrationStep> sessionMigrationSteps = {
  7: _v7ToV8,
  8: _v8ToV9,
  9: _v9ToV10,
  10: _v10ToV11,
};

/// A manifest written by an older schema, converted in memory: the exact
/// [original] bytes for the backup, the current-schema [manifest] to write
/// back, and the [notes] of every field the conversion filled in or changed.
@immutable
class SessionConversion {
  /// Creates a [SessionConversion].
  const SessionConversion({
    required this.fromVersion,
    required this.original,
    required this.manifest,
    required this.notes,
  });

  /// The schema the bundle was written with.
  final int fromVersion;

  /// The original manifest text, byte for byte.
  final String original;

  /// The converted manifest, in the current schema.
  final Map<String, dynamic> manifest;

  /// What the conversion filled in, moved or changed, one line per field.
  final List<String> notes;
}

/// Decodes a manifest [source] of any convertible schema.
///
/// The current schema decodes through the strict [Session.fromJson] with no
/// conversion. An older schema is converted step by step and the result must
/// then pass that same strict decode. A newer schema throws
/// [SessionUnsupportedVersion]; one older than
/// [oldestConvertibleSessionVersion], or one a step or the strict decode
/// rejects, throws [SessionUnconvertible]. A converted bundle's own layer
/// corruption still throws [SessionCorruptLayers].
({Session session, SessionConversion? conversion}) decodeSessionManifest(
  String source, {
  SessionSettings live = const SessionSettings(),
}) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final version = json['version'];
  if (version is! int || version >= Session.formatVersion) {
    return (session: Session.fromJson(json), conversion: null);
  }
  if (version < oldestConvertibleSessionVersion) {
    throw SessionUnconvertible(
      version: version,
      reason: 'older than schema $oldestConvertibleSessionVersion',
    );
  }
  final manifest = jsonDecode(source) as Map<String, dynamic>;
  final context = SessionMigrationContext(live: live);
  for (var from = version; from < Session.formatVersion; from++) {
    final step = sessionMigrationSteps[from];
    if (step == null) {
      throw SessionUnconvertible(version: version, reason: 'no step $from');
    }
    try {
      step(manifest, context);
    } on Object catch (error) {
      throw SessionUnconvertible(
        version: version,
        reason: 'schema $from: $error',
      );
    }
    manifest['version'] = from + 1;
  }
  final Session session;
  try {
    session = Session.fromJson(manifest);
  } on SessionCorruptLayers {
    rethrow;
  } on Object catch (error) {
    throw SessionUnconvertible(version: version, reason: '$error');
  }
  return (
    session: session,
    conversion: SessionConversion(
      fromVersion: version,
      original: source,
      manifest: manifest,
      notes: context.notes,
    ),
  );
}

// ---- the steps ----

/// 7 → 8: track settings leave the audio tracks for session-level maps, the
/// monitor gate is stored by name only, and the settings master kept as
/// global preferences become session settings.
void _v7ToV8(Map<String, dynamic> m, SessionMigrationContext c) {
  _adoptSliceSpellings(m, c);
  final presets = <String, dynamic>{};
  final once = <String, dynamic>{};
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    final channel = '${track['channel'] as int}';
    final preset = track.remove('lengthPresetBars');
    if (preset is int && preset > 0) presets[channel] = preset;
    if (track.remove('oneShot') == true) once[channel] = true;
  }
  for (final channel in m.remove('oneShotChannels') as List<dynamic>? ?? []) {
    once['${channel as int}'] = true;
  }
  if (presets.isNotEmpty) {
    _map(m, 'trackLengthPresetOverrides').addAll(presets);
    c.note('trackLengthPresetOverrides', 'moved from the tracks');
  }
  if (once.isNotEmpty) {
    _map(m, 'trackOneShotOverrides').addAll(once);
    c.note('trackOneShotOverrides', 'moved from the One Shot channels');
  }
  // Master's Master insert ran on the summed tracks before live monitoring
  // joined the mix: the stage the current schema calls All tracks.
  final master = m.remove('masterChain');
  if (master is String && master.isNotEmpty) {
    m['allTracksChain'] = master;
    c.note('masterChain', 'moved to allTracksChain');
  }
  _fillSessionSettings(m, c);
}

/// 8 → 9: the All tracks chain becomes required, and a Master insert (which
/// by schema 8 was output bus 0's chain) becomes that destination's chain.
void _v8ToV9(Map<String, dynamic> m, SessionMigrationContext c) {
  _adoptSliceSpellings(m, c);
  _fillSessionSettings(m, c);
  _settleBusChains(m, c);
}

/// 9 → 10: Fade durations become session settings, and a live-input level
/// above unity, which schema 9 stopped accepting, is lowered to unity.
void _v9ToV10(Map<String, dynamic> m, SessionMigrationContext c) {
  _adoptSliceSpellings(m, c);
  _fillSessionSettings(m, c);
  _settleBusChains(m, c);
  for (final monitor in _list(m, 'monitors').cast<Map<String, dynamic>>()) {
    final volume = monitor['volume'];
    if (volume is num && volume > 1) {
      monitor['volume'] = 1.0;
      c.note(
        'monitors[${monitor['input']}].volume',
        '$volume lowered to the live-input ceiling of 1',
      );
    }
  }
  _fill(m, c, 'defaultFadeDurationMs', 4000);
  _fill(m, c, 'trackFadeDurationOverrides', <String, dynamic>{});
}

/// 10 → 11: each recorded track carries its stationary Fade level; a session
/// from before Fade levels were saved plays its tracks unfaded.
void _v10ToV11(Map<String, dynamic> m, SessionMigrationContext c) {
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    if (!track.containsKey('fadeAmount')) {
      track['fadeAmount'] = 1.0;
      c.note('tracks[${track['channel']}].fadeAmount', 'defaulted to 1');
    }
  }
}

// ---- shared pieces ----

/// The settings schema 8 made session-owned. Those master kept as global
/// preferences come from the player's live values; those master never had
/// take the value that reproduces master's behaviour. Present values stay.
void _fillSessionSettings(Map<String, dynamic> m, SessionMigrationContext c) {
  final live = c.live;
  _fill(m, c, 'syncTempo', live.syncTempo, live: true);
  _fill(m, c, 'recDub', live.recDub, live: true);
  _fill(m, c, 'autoRecord', live.autoRecord, live: true);
  _fill(m, c, 'defaultMultiple', live.defaultMultiple, live: true);
  _fill(m, c, 'recordTiming', live.recordTiming.name, live: true);
  _fill(m, c, 'trackRecordTimingOverrides', {
    for (final entry in live.trackRecordTimingOverrides.entries)
      '${entry.key}': entry.value.name,
  }, live: true);
  _fill(m, c, 'loopBars', 0);
  _fill(m, c, 'overdubDecay', 0);
  _fill(m, c, 'defaultOneShot', false);
  _fill(m, c, 'defaultLengthPresetBars', 0);
  _fill(m, c, 'trackOverdubDecayOverrides', <String, dynamic>{});
  _fill(m, c, 'trackOneShotOverrides', <String, dynamic>{});
  _fill(m, c, 'trackLengthPresetOverrides', <String, dynamic>{});
  for (final monitor in _list(m, 'monitors').cast<Map<String, dynamic>>()) {
    final enabled = monitor.remove('enabled');
    final mode = monitor['mode'];
    if (mode is! String || mode.isEmpty) {
      monitor['mode'] = enabled == true ? 'on' : 'off';
      c.note('monitors[${monitor['input']}].mode', 'taken from enabled');
    }
  }
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    for (final lane in _list(track, 'lanes').cast<Map<String, dynamic>>()) {
      lane
        ..putIfAbsent('undoCount', () => 0)
        ..putIfAbsent('redoCount', () => 0);
    }
  }
}

/// Requires the All tracks chain and the output-chain list. A remaining
/// `masterChain` was written when the Master insert was output bus 0's
/// chain, so it becomes that destination's chain.
void _settleBusChains(Map<String, dynamic> m, SessionMigrationContext c) {
  _fill(m, c, 'allTracksChain', '');
  final outputs = m.putIfAbsent('outputChains', () => <dynamic>[]) as List;
  final master = m.remove('masterChain');
  if (master is String && master.isNotEmpty) {
    if (outputs.any((chain) => (chain as Map)['bus'] == 0)) {
      throw const FormatException('masterChain and an output bus 0 chain');
    }
    outputs.insert(0, {'bus': 0, 'encoded': master});
    c.note('masterChain', 'moved to output bus 0');
  }
}

/// Rewrites the September slices' spellings of schemas 7–9 into the trunk's.
/// Idempotent, and a no-op for a manifest that never used them.
void _adoptSliceSpellings(Map<String, dynamic> m, SessionMigrationContext c) {
  if (m.containsKey('defaultOnce')) {
    m.putIfAbsent('defaultOneShot', () => m['defaultOnce']);
    m.remove('defaultOnce');
  }
  for (final (from, to) in const [
    ('onceOverrides', 'trackOneShotOverrides'),
    ('lengthPresetOverrides', 'trackLengthPresetOverrides'),
  ]) {
    final values = m.remove(from) as Map<String, dynamic>?;
    if (values != null) _map(m, to).addAll(values);
  }
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    final channel = '${track['channel'] as int}';
    for (final (from, to) in const [
      ('pan', 'trackPans'),
      ('recordTiming', 'trackRecordTimingOverrides'),
      ('overdubDecay', 'trackOverdubDecayOverrides'),
    ]) {
      if (track.containsKey(from)) _map(m, to)[channel] = track.remove(from);
    }
  }
}

void _fill(
  Map<String, dynamic> m,
  SessionMigrationContext c,
  String key,
  Object value, {
  bool live = false,
}) {
  if (m.containsKey(key)) return;
  m[key] = value;
  c.note(key, live ? 'taken from the live setting' : 'defaulted');
}

List<dynamic> _list(Map<String, dynamic> m, String key) =>
    m[key] as List<dynamic>? ?? const [];

Map<String, dynamic> _map(Map<String, dynamic> m, String key) =>
    m.putIfAbsent(key, () => <String, dynamic>{}) as Map<String, dynamic>;
