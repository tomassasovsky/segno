import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:session_repository/src/models/session.dart';
import 'package:session_repository/src/session_exception.dart';
import 'package:session_repository/src/session_repository.dart';

/// The oldest manifest schema this build converts (#1196): the first one
/// Segno ever wrote. A manifest declaring an older one is refused with
/// [SessionUnconvertible].
const int oldestConvertibleSessionVersion = 1;

/// An audible change a conversion made, which the player is told about.
enum SessionConversionChange {
  /// A schema-7-or-older Master insert now runs on the All tracks stage, and
  /// pedals bound to it follow it there.
  masterEffectsMoved,

  /// A live input above unity was lowered to unity.
  monitorLevelLowered,

  /// A session that saved no tempo took the one its loop length defines.
  tempoFromLoop,
}

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
  final Set<SessionConversionChange> _changes = {};

  /// Every field the conversion filled in, moved or changed, in step order.
  List<String> get notes => List.unmodifiable(_notes);

  /// The audible changes the conversion made.
  Set<SessionConversionChange> get changes => Set.unmodifiable(_changes);

  /// Records that [field] was [what].
  void note(String field, String what) => _notes.add('$field: $what');

  /// Records an audible [change] the player is told about.
  void change(SessionConversionChange change) => _changes.add(change);
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
  1: _v1ToV2,
  2: _v2ToV3,
  3: _v3ToV4,
  4: _v4ToV5,
  5: _v5ToV6,
  6: _v6ToV7,
  7: _v7ToV8,
  8: _v8ToV9,
  9: _v9ToV10,
  10: _v10ToV11,
  11: _v11ToV12,
  12: _v12ToV13,
  // #1179's Audio & tempo. The number is assigned at landing: on the trunk
  // after Multiply/Divide (14) and the backing player (15) this entry is
  // `15: _addAudioTempo`, reading 15 and writing 16.
  13: _addAudioTempo,
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
    this.changes = const {},
  });

  /// The schema the bundle was written with.
  final int fromVersion;

  /// The original manifest text, byte for byte.
  final String original;

  /// The converted manifest, in the current schema.
  final Map<String, dynamic> manifest;

  /// What the conversion filled in, moved or changed, one line per field.
  final List<String> notes;

  /// The audible changes the conversion made.
  final Set<SessionConversionChange> changes;
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
      changes: context.changes,
    ),
  );
}

// ---- the steps ----

/// 1 → 2: the first schema's transport settings, which it saved and
/// re-applied, take their later names; the lane and monitor chains arrive
/// empty.
void _v1ToV2(Map<String, dynamic> m, SessionMigrationContext c) {
  final bpm = m.remove('tempoBpm');
  if (bpm is num && bpm >= 30 && bpm <= 300) {
    m
      ..['tempoBpm'] = bpm.toDouble()
      ..['tempoSource'] = 'manual'
      ..['tsNum'] = 4
      ..['tsDen'] = 4;
    c.note('tempoBpm', 'kept as a manual tempo in 4/4');
  }
  final sync = m.remove('syncLoopToTempo');
  if (sync is bool) {
    m['syncTempo'] = sync;
    c.note('syncLoopToTempo', 'kept as syncTempo');
  }
  final quantize = m.remove('quantizeMode');
  if (quantize is String) {
    final (timing, division) = switch (quantize) {
      'beat' => ('quarter', 'quarter'),
      'bar' => ('bar', 'bar'),
      _ => ('immediately', 'off'),
    };
    m
      ..['recordTiming'] = timing
      ..['quantizeDiv'] = division;
    c.note('quantizeMode', 'kept as record timing $timing');
  }
  if (m.remove('metronomeOn') == true) {
    m['clickMode'] = 'playRec';
    c.note('metronomeOn', 'kept as a click while playing or recording');
  }
  if (m.remove('countInEnabled') == true) {
    m['countInBars'] = 1;
    c.note('countInEnabled', 'kept as a one-bar count-in');
  }
  _fill(m, c, 'laneChains', <dynamic>[]);
  _fill(m, c, 'monitors', <dynamic>[]);
}

/// 2 → 3: a track's single stem becomes lane 0 holding one live layer, the
/// way master read these tracks: its level and mute, both outputs, no input.
void _v2ToV3(Map<String, dynamic> m, SessionMigrationContext c) {
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    if (track.containsKey('lanes')) continue;
    track['lanes'] = [
      {
        'lane': 0,
        'volume': track.remove('volume'),
        'muted': track.remove('muted'),
        'outputMask': 0x3,
        'inputChannel': -1,
        'layers': [
          {'file': track.remove('stem')},
        ],
        'undoCount': 0,
        'redoCount': 0,
      },
    ];
    c.note('tracks[${track['channel']}].stem', 'became lane 0');
  }
}

/// 3 → 4: the tempo grid. A session that saved no tempo takes the one its
/// loop defines, as a recording with loop sync does: whole bars of 4/4 at
/// the tempo nearest 120 between 30 and 300. With no loop there is none.
/// Everything else on the grid starts off, as master read these sessions.
void _v3ToV4(Map<String, dynamic> m, SessionMigrationContext c) {
  if (!m.containsKey('tempoSource')) {
    final frames = m['baseLengthFrames'];
    final rate = m['sampleRate'];
    final derived =
        frames is int && rate is int && _list(m, 'tracks').isNotEmpty
        ? _deriveTempo(frames, 4, rate)
        : null;
    if (derived != null) {
      m
        ..['tempoBpm'] = derived.bpm
        ..['tempoSource'] = 'derived'
        ..['loopBars'] = derived.bars;
      c
        ..note('tempoBpm', 'derived from the loop: ${derived.bars} bars')
        ..change(SessionConversionChange.tempoFromLoop);
    } else {
      m
        ..['tempoBpm'] = 0.0
        ..['tempoSource'] = 'none';
      c.note('tempoBpm', 'defaulted to none');
    }
  }
  _fill(m, c, 'tsNum', 4);
  _fill(m, c, 'tsDen', 4);
  _fill(m, c, 'quantizeDiv', 'off');
  _fill(m, c, 'clickMode', 'off');
  _fill(m, c, 'clickOutputMask', 0);
  _fill(m, c, 'clickVolume', 1.0);
  _fill(m, c, 'countInBars', 0);
  _fill(m, c, 'looperMode', 'multi');
  _fill(m, c, 'primaryTrack', -1);
}

/// 4 → 5: the Track and Master FX stages arrive empty.
void _v4ToV5(Map<String, dynamic> m, SessionMigrationContext c) {
  _fill(m, c, 'trackChains', <dynamic>[]);
  _fill(m, c, 'masterChain', '');
}

/// 5 → 6: no session pedal remap; the global bindings apply.
void _v5ToV6(Map<String, dynamic> m, SessionMigrationContext c) {
  _fill(m, c, 'pedalBindings', '');
}

/// 6 → 7: the monitor gate gains its name. A monitor without one keeps its
/// `enabled` flag, which the 7 → 8 step reads, so nothing changes here.
void _v6ToV7(Map<String, dynamic> m, SessionMigrationContext c) {}

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
  // joined the mix: the stage the current schema calls All tracks. Pedals
  // bound to it follow it there.
  final master = m.remove('masterChain');
  if (master is String && master.isNotEmpty) {
    m['allTracksChain'] = master;
    c
      ..note('masterChain', 'moved to allTracksChain')
      ..change(SessionConversionChange.masterEffectsMoved);
  }
  if (_retargetMasterBindings(m, 'allTracks')) {
    c
      ..note('pedalBindings', 'Master bindings moved to All tracks')
      ..change(SessionConversionChange.masterEffectsMoved);
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
      c
        ..note(
          'monitors[${monitor['input']}].volume',
          '$volume lowered to the live-input ceiling of 1',
        )
        ..change(SessionConversionChange.monitorLevelLowered);
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

/// 11 → 12: each lane names the kind of every history entry. Before Peel
/// every entry was a plain overdub layer: schema 11's recall filed them all
/// as `LE_HIST_LAYER`, so the images and counts are unchanged.
void _v11ToV12(Map<String, dynamic> m, SessionMigrationContext c) {
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    for (final lane in _list(track, 'lanes').cast<Map<String, dynamic>>()) {
      if (lane.containsKey('history')) continue;
      final entries = (lane['undoCount'] as int) + (lane['redoCount'] as int);
      lane['history'] = [
        for (var i = 0; i < entries; i++) {'kind': 'layer', 'skipped': 0},
      ];
      c.note(
        'tracks[${track['channel']}].lanes[${lane['lane']}].history',
        '$entries layer entries',
      );
    }
  }
}

/// 12 → 13: each track carries its playback direction (#1162). No earlier
/// schema saved one, and every earlier session recalled its tracks forward,
/// so every track is forward.
void _v12ToV13(Map<String, dynamic> m, SessionMigrationContext c) {
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    track['reversed'] = false;
    c.note('tracks[${track['channel']}].reversed', 'defaulted to forward');
  }
}

/// 13 → 14 (lands as 15 → 16): the Audio & tempo settings and the recorded
/// tempo (#1179). Follow tempo and Pitch were the player's global
/// preferences before (rule 1, the schema-8 precedent), so a session that
/// never carried them keeps the live values, as opening it did. Nothing
/// could retime a rig before this schema, so its takes are at its own tempo
/// on its own master: no recorded pair, no spans.
void _addAudioTempo(Map<String, dynamic> m, SessionMigrationContext c) {
  final live = c.live;
  _fill(m, c, 'defaultFollowTempo', live.defaultFollowTempo, live: true);
  _fill(m, c, 'trackFollowTempoOverrides', <String, dynamic>{
    for (final entry in live.trackFollowTempoOverrides.entries)
      '${entry.key}': entry.value,
  }, live: true);
  _fill(m, c, 'defaultPitchMode', live.defaultPitchMode.name, live: true);
  _fill(m, c, 'trackPitchModeOverrides', <String, dynamic>{
    for (final entry in live.trackPitchModeOverrides.entries)
      '${entry.key}': entry.value.name,
  }, live: true);
  _fill(m, c, 'recordedTempoBpm', 0.0);
  _fill(m, c, 'recordedLengthFrames', 0);
  for (final track in _list(m, 'tracks').cast<Map<String, dynamic>>()) {
    if (track.containsKey('spanFrames')) continue;
    track['spanFrames'] = 0;
    c.note('tracks[${track['channel']}].spanFrames', 'its own master');
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
  // Per-track timing did not exist before schema 8 (slices aside): every
  // track followed the global setting, which an empty map reproduces.
  _fill(m, c, 'trackRecordTimingOverrides', <String, dynamic>{});
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
  if (_retargetMasterBindings(m, 'output')) {
    c.note('pedalBindings', 'Master bindings moved to output bus 0');
  }
}

/// Points every pedal binding on the retired Master stage at [stage] (index
/// 0), where the chain moved, keeping its slot. Returns whether any moved.
/// An unparseable blob is left as it is: the binding decoder already drops
/// what it cannot read.
bool _retargetMasterBindings(Map<String, dynamic> m, String stage) {
  final blob = m['pedalBindings'];
  if (blob is! String || blob.isEmpty) return false;
  final Object? bindings;
  try {
    bindings = jsonDecode(blob);
  } on FormatException {
    return false;
  }
  if (bindings is! List) return false;
  var moved = false;
  for (final binding in bindings) {
    if (binding is! Map<String, dynamic>) continue;
    final target = binding['target'];
    if (target is! String) continue;
    final Object? address;
    try {
      address = jsonDecode(target);
    } on FormatException {
      continue;
    }
    if (address is! Map<String, dynamic> || address['stage'] != 'master') {
      continue;
    }
    binding['target'] = jsonEncode({
      'stage': stage,
      'index': 0,
      for (final entry in address.entries)
        if (!const {'stage', 'index', 'lane'}.contains(entry.key))
          entry.key: entry.value,
    });
    moved = true;
  }
  if (moved) m['pedalBindings'] = jsonEncode(bindings);
  return moved;
}

/// The engine's tempo for a loop of [frames] defining the grid
/// (`le_grid_derive_bpm`): whole bars of [beats] beats, the tempo nearest
/// 120 within 30..300, ties to the slower one. Null for a degenerate loop.
({double bpm, int bars})? _deriveTempo(int frames, int beats, int rate) {
  if (frames <= 0 || beats <= 0 || rate <= 0) return null;
  final perBar = 60.0 * rate * beats / frames;
  var low = (30 / perBar - 1e-9).ceil();
  if (low < 1) low = 1;
  final high = (300 / perBar + 1e-9).floor();
  if (high < low) return (bpm: 300, bars: 1);
  final near = (120 / perBar).round();
  var best = 0;
  var bestDistance = 0.0;
  for (var k = near - 1; k <= near + 1; k++) {
    final bars = math.min(math.max(k, low), high);
    final distance = (perBar * bars - 120).abs();
    if (best == 0 ||
        distance < bestDistance ||
        (distance == bestDistance && bars < best)) {
      best = bars;
      bestDistance = distance;
    }
  }
  // The engine keeps the tempo as a 32-bit float.
  return (bpm: (Float32List(1)..[0] = perBar * best)[0], bars: best);
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
