import 'package:meta/meta.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/src/session_exception.dart';

/// One captured audio buffer within a [SessionLane]: a single overdub layer,
/// stored as the WAV [file] in the session bundle. The audio itself lives in
/// the referenced file, not in this manifest.
///
/// A track's schema-v3 lanes carry an ordered list of these. Part 1 writes
/// exactly one per lane (the live buffer); the undo/redo layers are a later
/// revision, at which point a lane holds several.
@immutable
class SessionLayer {
  /// Creates a [SessionLayer].
  const SessionLayer({required this.file});

  /// Projects a [SessionLayer] from a decoded JSON map.
  factory SessionLayer.fromJson(Map<String, dynamic> json) =>
      SessionLayer(file: json['file'] as String);

  /// Filename of this layer's WAV within the session bundle.
  final String file;

  /// Serializes this layer to a JSON map.
  Map<String, dynamic> toJson() => {'file': file};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLayer &&
          runtimeType == other.runtimeType &&
          file == other.file;

  @override
  int get hashCode => file.hashCode;
}

/// One lane of a [SessionTrack] (schema v3): its mix/routing plus the ordered
/// audio [layers]. A lane records one input into its own mono buffer, so a
/// track persists one of these per active lane.
///
/// [layers] is the lane's pool contents oldest→newest: the [undoCount] undo
/// snapshots, then the live buffer, then the [redoCount] redo snapshots. The
/// live buffer is `layers[liveIndex]` (== [undoCount]), and
/// `layers.length == undoCount + 1 + redoCount`. Part 1 always emits a single
/// live layer (`undoCount == redoCount == 0`); later revisions populate the
/// undo/redo layers so a reloaded lane can undo/redo.
@immutable
class SessionLane {
  /// Creates a [SessionLane].
  const SessionLane({
    required this.lane,
    required this.volume,
    required this.muted,
    required this.outputMask,
    required this.inputChannel,
    required this.layers,
    this.undoCount = 0,
    this.redoCount = 0,
  });

  /// Projects a [SessionLane] from a decoded JSON map.
  factory SessionLane.fromJson(Map<String, dynamic> json) => SessionLane(
    lane: (json['lane'] as num).toInt(),
    volume: (json['volume'] as num).toDouble(),
    muted: json['muted'] as bool,
    outputMask: (json['outputMask'] as num).toInt(),
    inputChannel: (json['inputChannel'] as num).toInt(),
    layers: [
      for (final l in json['layers'] as List<dynamic>)
        SessionLayer.fromJson(l as Map<String, dynamic>),
    ],
    undoCount: (json['undoCount'] as num?)?.toInt() ?? 0,
    redoCount: (json['redoCount'] as num?)?.toInt() ?? 0,
  );

  /// Lane index within the track.
  final int lane;

  /// Playback gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Bitmask of output channels this lane plays to (bit c => output c).
  final int outputMask;

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// The lane's audio buffers, oldest undo → live → newest redo.
  final List<SessionLayer> layers;

  /// Number of leading [layers] that are undo snapshots (below the live
  /// buffer).
  final int undoCount;

  /// Number of trailing [layers] that are redo snapshots (above the live
  /// buffer).
  final int redoCount;

  /// Maximum layers a lane can hold, mirroring the engine's `LE_POOL_SLOTS`
  /// (one live buffer plus up to 255 undo/redo snapshots). A bundle claiming
  /// more is rejected on load.
  static const int maxLayers = 256;

  /// Index into [layers] of the live (currently playing) buffer.
  int get liveIndex => undoCount;

  /// Serializes this lane to a JSON map.
  Map<String, dynamic> toJson() => {
    'lane': lane,
    'volume': volume,
    'muted': muted,
    'outputMask': outputMask,
    'inputChannel': inputChannel,
    'layers': [for (final l in layers) l.toJson()],
    'undoCount': undoCount,
    'redoCount': redoCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLane &&
          runtimeType == other.runtimeType &&
          lane == other.lane &&
          volume == other.volume &&
          muted == other.muted &&
          outputMask == other.outputMask &&
          inputChannel == other.inputChannel &&
          undoCount == other.undoCount &&
          redoCount == other.redoCount &&
          _listEquals(layers, other.layers);

  @override
  int get hashCode => Object.hash(
    lane,
    volume,
    muted,
    outputMask,
    inputChannel,
    undoCount,
    redoCount,
    Object.hashAll(layers),
  );
}

/// One track's persisted settings within a [Session]: its length and its
/// [lanes] (schema v3). The audio lives in the lanes' layer WAV files, not in
/// this manifest.
@immutable
class SessionTrack {
  /// Creates a [SessionTrack].
  const SessionTrack({
    required this.channel,
    required this.multiple,
    required this.lengthFrames,
    required this.lanes,
  });

  /// Projects a [SessionTrack] from a decoded JSON map.
  ///
  /// A v1/v2 track (no `lanes`, one `stem` filename + track-level mix) migrates
  /// to a single lane-0 lane holding one live layer — presence-keyed on
  /// `lanes`, matching the manifest's other version rungs.
  factory SessionTrack.fromJson(Map<String, dynamic> json) {
    final rawLanes = json['lanes'] as List<dynamic>?;
    final lanes = rawLanes != null
        ? [
            for (final l in rawLanes)
              SessionLane.fromJson(l as Map<String, dynamic>),
          ]
        : <SessionLane>[
            SessionLane(
              lane: 0,
              volume: (json['volume'] as num).toDouble(),
              muted: json['muted'] as bool,
              outputMask: 0x3,
              inputChannel: -1,
              layers: [SessionLayer(file: json['stem'] as String)],
            ),
          ];
    final channel = (json['channel'] as num).toInt();
    for (final lane in lanes) {
      final expected = lane.undoCount + 1 + lane.redoCount;
      if (lane.undoCount < 0 || lane.redoCount < 0) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason: 'negative undo/redo count',
        );
      }
      if (lane.layers.length != expected) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason:
              '${lane.layers.length} layers but undoCount+1+redoCount == '
              '$expected',
        );
      }
      if (expected > SessionLane.maxLayers) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason: '$expected layers exceeds the ${SessionLane.maxLayers} cap',
        );
      }
    }
    return SessionTrack(
      channel: channel,
      multiple: (json['multiple'] as num).toInt(),
      lengthFrames: (json['lengthFrames'] as num).toInt(),
      lanes: lanes,
    );
  }

  /// Track channel index.
  final int channel;

  /// Track length in whole base loops (`>= 1`).
  final int multiple;

  /// Captured length in frames (`multiple` × the base length).
  final int lengthFrames;

  /// The track's lanes, each with its own mix/routing and audio layers.
  final List<SessionLane> lanes;

  /// Serializes this track to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'multiple': multiple,
    'lengthFrames': lengthFrames,
    'lanes': [for (final l in lanes) l.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTrack &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          multiple == other.multiple &&
          lengthFrames == other.lengthFrames &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode => Object.hash(
    channel,
    multiple,
    lengthFrames,
    Object.hashAll(lanes),
  );
}

/// One lane's Loop-stage effect chain within a [Session] (schema v2+).
///
/// The chain is stored as the opaque [encoded] string the looper domain
/// produces — the same wire format settings persist — so this data package
/// never depends on the effect model. Since schema v5 that string is the
/// looper domain's chain ENVELOPE (`encodeFxChain`: the entries plus the
/// chain-enabled flag and inheritance provenance); a v4-or-earlier manifest
/// carries the bare entries array (`encodeTrackEffects`), which the same
/// decoder still accepts. Either way the content stays opaque here. Chains
/// exist independently of audio, so a [channel]/[lane] here may not match any
/// [SessionTrack].
@immutable
class SessionLaneChain {
  /// Creates a [SessionLaneChain].
  const SessionLaneChain({
    required this.channel,
    required this.lane,
    required this.encoded,
  });

  /// Projects a [SessionLaneChain] from a decoded JSON map.
  factory SessionLaneChain.fromJson(Map<String, dynamic> json) =>
      SessionLaneChain(
        channel: (json['channel'] as num).toInt(),
        lane: (json['lane'] as num).toInt(),
        encoded: json['encoded'] as String,
      );

  /// Track channel this chain belongs to.
  final int channel;

  /// Lane index within the track.
  final int lane;

  /// The chain as an opaque `encodeTrackEffects` string.
  final String encoded;

  /// Serializes this chain to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'lane': lane,
    'encoded': encoded,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionLaneChain &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          lane == other.lane &&
          encoded == other.encoded;

  @override
  int get hashCode => Object.hash(channel, lane, encoded);
}

/// One track's Track-stage (stereo bus) effect chain within a [Session]
/// (schema v5).
///
/// The Track stage sits downstream of a track's lanes, so — unlike a
/// [SessionLaneChain] — one of these exists per track channel, with no lane
/// coordinate. Stored as the same opaque [encoded] envelope string (see
/// [SessionLaneChain]), so this data package still never depends on the effect
/// model. Chains exist independently of audio, so a [channel] here may not
/// match any [SessionTrack].
@immutable
class SessionTrackChain {
  /// Creates a [SessionTrackChain].
  const SessionTrackChain({required this.channel, required this.encoded});

  /// Projects a [SessionTrackChain] from a decoded JSON map.
  factory SessionTrackChain.fromJson(Map<String, dynamic> json) =>
      SessionTrackChain(
        channel: (json['channel'] as num).toInt(),
        encoded: json['encoded'] as String,
      );

  /// Track channel whose stereo bus this chain sits on.
  final int channel;

  /// The chain as an opaque chain-envelope string.
  final String encoded;

  /// Serializes this chain to a JSON map.
  Map<String, dynamic> toJson() => {'channel': channel, 'encoded': encoded};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTrackChain &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          encoded == other.encoded;

  @override
  int get hashCode => Object.hash(channel, encoded);
}

/// One hardware input's live-monitor configuration within a [Session] (schema
/// v2+): routing / mix plus the monitor's [encoded] effect chain.
@immutable
class SessionMonitor {
  /// Creates a [SessionMonitor].
  const SessionMonitor({
    required this.input,
    required this.enabled,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.encoded,
    this.mode = '',
  });

  /// Projects a [SessionMonitor] from a decoded JSON map.
  factory SessionMonitor.fromJson(Map<String, dynamic> json) => SessionMonitor(
    input: (json['input'] as num).toInt(),
    enabled: json['enabled'] as bool,
    outputMask: (json['outputMask'] as num).toInt(),
    volume: (json['volume'] as num).toDouble(),
    muted: json['muted'] as bool,
    encoded: json['encoded'] as String,
    mode: json['mode'] as String? ?? '',
  );

  /// Hardware input index.
  final int input;

  /// Whether live monitoring of the input is enabled.
  ///
  /// The coarse gate every manifest has carried, and the one this build's own
  /// fallback reads when a bundle predates [mode]. True for any monitor that
  /// is not off; [mode] is what says WHICH of the two non-off states it was.
  ///
  /// Not for older builds — a v6 reader rejects a v7 manifest on the version
  /// gate and never reaches this field. It is written because every manifest
  /// has it and because the fallback is real.
  final bool enabled;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above
  /// unity).
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor chain as an opaque `encodeTrackEffects` string.
  final String encoded;

  /// The monitor's gate as its own name (manifest v7), or `''` for a manifest
  /// written before this field existed.
  ///
  /// A NAME, not the looper domain's enum: this package does not know that
  /// domain and must not learn it to carry one field. The app maps it, the
  /// same way the settings keys already store a mode by name.
  ///
  /// Empty is not a state — it means "this manifest did not say", and the
  /// reader falls back to [enabled]. That is the same presence-keyed rung
  /// every version before it used.
  final String mode;

  /// Serializes this monitor to a JSON map.
  Map<String, dynamic> toJson() => {
    'input': input,
    'enabled': enabled,
    'outputMask': outputMask,
    'volume': volume,
    'muted': muted,
    'encoded': encoded,
    if (mode.isNotEmpty) 'mode': mode,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMonitor &&
          runtimeType == other.runtimeType &&
          input == other.input &&
          enabled == other.enabled &&
          outputMask == other.outputMask &&
          volume == other.volume &&
          muted == other.muted &&
          encoded == other.encoded &&
          mode == other.mode;

  @override
  int get hashCode =>
      Object.hash(input, enabled, outputMask, volume, muted, encoded, mode);
}

/// A saved Segno session: the transport/tempo settings, the tracks, and (schema
/// v2+) the lane + monitor effect chains. Paired with per-lane, per-layer WAV
/// files (schema v3) in a `.segno` bundle directory.
///
/// Schema v4 (`2026-07-22-feat-tempo-aware-looper-modes-plan.md`, decision
/// D12) adds the Phase-A tempo grid + click + count-in fields below. Every
/// one of them defaults to the tempo-free/grid-off value, so a v3 manifest
/// loads as "Multi, grid off" with zero data loss — the same
/// "grid-off is the compatible default" pattern used across the whole tempo
/// series (D6). [clickMode]/[clickOutputMask]/[clickVolume] and
/// [countInBars] intentionally carry the richer shape the engine/repository
/// layer actually shipped in A1/A2 (`TransportState`/`EngineSnapshot`) rather
/// than the index plan ERD's earlier sketch (`bool metronomeOn`,
/// `bool countIn`) — the ERD predates those implementation details and the
/// plan's own D12 says to prefer fidelity to the real model.
///
/// Track settings are session-level maps, independent of audio entries.
/// Missing entries inherit the session default; explicit values, including
/// Loop (`false`) and values equal to the default, remain explicit.
/// Schema v8 replaces per-audio-track settings and the One Shot channel set.
///
/// Schema v5 (FX system v3, #351 part 3b) adds the two BUS stages of the
/// four-stage FX model — [trackChains] (one per track channel) and the single
/// [masterChain] — and re-documents the two chain fields it already had as the
/// model's other two stages: [monitors] is the **Input** stage and
/// [laneChains] the **Loop** stage. Those keep their v2 key names (renaming
/// them would be churn with no presence-keyed payoff). Every chain string is
/// now the looper domain's chain ENVELOPE, which carries the per-chain enabled
/// flag, the per-slot enabled flags, stable slot ids, and inheritance
/// provenance INSIDE the opaque string — so v5 adds no per-flag manifest
/// fields, and a v4 manifest's bare entries array still decodes (with every
/// level defaulting to enabled). Both new fields are presence-keyed: a
/// v4-or-earlier manifest simply lacks them and loads with both bus stages
/// EMPTY.
///
/// Schema v6 (FX system v3, #351 part 6b) adds [pedalBindings] — this
/// session's pedal remap, carried as one more opaque string on the same rule
/// as the chains: the model lives app-side, this package only stores the blob.
/// Presence-keyed like every rung before it, so a v5 manifest loads with `''`
/// and the global remap applies.
///
/// Schema v7 (#575) adds [SessionMonitor.mode] — the monitor's gate by name,
/// beside the boolean the manifest has always carried. The gate grew a third
/// state (`auto`: follow the record arm), and a boolean cannot tell it from
/// `on`, so a session saved with an input on `auto` reloaded monitoring
/// unconditionally. Presence-keyed like the rest: a v6 manifest lacks the key
/// and restores exactly what its boolean used to say.
@immutable
class Session {
  /// Creates a [Session].
  const Session({
    required this.sampleRate,
    required this.channels,
    required this.baseLengthFrames,
    required this.tracks,
    this.laneChains = const [],
    this.monitors = const [],
    this.trackChains = const [],
    this.masterChain = '',
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.quantizeDiv = GridDivision.off,
    this.loopBars = 0,
    this.recordTiming = RecordTiming.immediately,
    this.overdubDecay = 0,
    this.clickMode = ClickMode.off,
    this.clickOutputMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.defaultOneShot = false,
    this.trackRecordTimingOverrides = const {},
    this.trackOverdubDecayOverrides = const {},
    this.trackOneShotOverrides = const {},
    this.trackLengthPresetOverrides = const {},
    this.syncTempo = true,
    this.recDub = false,
    this.autoRecord = false,
    this.defaultMultiple = 0,
    this.pedalBindings = '',
  });

  /// Projects a [Session] from a decoded JSON map.
  ///
  /// A v1 manifest (no `laneChains` / `monitors`) loads with empty chains, so a
  /// legacy bundle restores explicitly-cleared chains rather than leftovers. A
  /// v3-or-earlier manifest (no tempo grid fields at all) loads with every new
  /// field at its grid-off default (see the class doc) — zero data loss, and
  /// indistinguishable from a v4 session someone deliberately saved with the
  /// grid off. A v4-or-earlier manifest (no `trackChains` / `masterChain`)
  /// loads with both bus stages empty, on the same presence-keyed rule — and,
  /// since its chain strings are pre-envelope bare arrays, every chain and
  /// slot decodes ENABLED at the looper-domain envelope layer, which is what
  /// makes a v4 load fingerprint-identical to the session that wrote it.
  /// Throws [SessionUnsupportedVersion] for a manifest written by a newer,
  /// incompatible schema version than this code understands.
  factory Session.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? formatVersion;
    if (version > formatVersion) {
      throw SessionUnsupportedVersion(
        version: version,
        supported: formatVersion,
      );
    }
    return Session(
      sampleRate: (json['sampleRate'] as num).toInt(),
      channels: (json['channels'] as num).toInt(),
      baseLengthFrames: (json['baseLengthFrames'] as num).toInt(),
      tracks: [
        for (final t in json['tracks'] as List<dynamic>)
          SessionTrack.fromJson(t as Map<String, dynamic>),
      ],
      laneChains: [
        for (final c in (json['laneChains'] as List<dynamic>? ?? const []))
          SessionLaneChain.fromJson(c as Map<String, dynamic>),
      ],
      monitors: [
        for (final m in (json['monitors'] as List<dynamic>? ?? const []))
          SessionMonitor.fromJson(m as Map<String, dynamic>),
      ],
      trackChains: [
        for (final c in (json['trackChains'] as List<dynamic>? ?? const []))
          SessionTrackChain.fromJson(c as Map<String, dynamic>),
      ],
      masterChain: json['masterChain'] as String? ?? '',
      tempoBpm: (json['tempoBpm'] as num?)?.toDouble() ?? 0,
      tempoSource: _tempoSourceFromJson(json['tempoSource'] as String?),
      tsNum: (json['tsNum'] as num?)?.toInt() ?? 4,
      tsDen: (json['tsDen'] as num?)?.toInt() ?? 4,
      quantizeDiv: _gridDivisionFromJson(json['quantizeDiv'] as String?),
      loopBars: (json['loopBars'] as num?)?.toInt() ?? 0,
      recordTiming:
          RecordTiming.fromName(json['recordTiming'] as String?) ??
          RecordTiming.immediately,
      overdubDecay: (json['overdubDecay'] as num?)?.toInt() ?? 0,
      clickMode: _clickModeFromJson(json['clickMode'] as String?),
      clickOutputMask: (json['clickOutputMask'] as num?)?.toInt() ?? 0,
      clickVolume: (json['clickVolume'] as num?)?.toDouble() ?? 1,
      countInBars: (json['countInBars'] as num?)?.toInt() ?? 0,
      looperMode: _looperModeFromJson(json['looperMode'] as String?),
      primaryTrack: (json['primaryTrack'] as num?)?.toInt() ?? -1,
      defaultOneShot: json['defaultOneShot'] as bool? ?? false,
      trackRecordTimingOverrides: _readOverrides(
        json['trackRecordTimingOverrides'],
        (value) => RecordTiming.values.byName(value! as String),
      ),
      trackOverdubDecayOverrides: _readOverrides(
        json['trackOverdubDecayOverrides'],
        (value) => (value! as num).toInt(),
      ),
      trackOneShotOverrides: _readOverrides(
        json['trackOneShotOverrides'],
        (value) => value! as bool,
      ),
      trackLengthPresetOverrides: _readOverrides(
        json['trackLengthPresetOverrides'],
        (value) => (value! as num).toInt(),
      ),
      syncTempo: json['syncTempo'] as bool? ?? true,
      recDub: json['recDub'] as bool? ?? false,
      autoRecord: json['autoRecord'] as bool? ?? false,
      defaultMultiple: (json['defaultMultiple'] as num?)?.toInt() ?? 0,
      pedalBindings: json['pedalBindings'] as String? ?? '',
    );
  }

  /// The manifest schema version. v8 stores track settings independently
  /// of recorded audio and retains nullable override intent.
  static const int formatVersion = 8;

  /// The manifest filename within a session bundle.
  static const String manifestName = 'session.json';

  /// Negotiated device sample rate the session was recorded at.
  final int sampleRate;

  /// Interleaved channel count of the stems.
  final int channels;

  /// The base (master) loop length in frames.
  final int baseLengthFrames;

  /// The session's tracks (those that hold audio).
  final List<SessionTrack> tracks;

  /// The Loop-stage (per-lane) effect chains the session defines (empty for a
  /// v1 bundle).
  final List<SessionLaneChain> laneChains;

  /// The Input-stage per-input live monitors the session defines (empty for a
  /// v1 bundle).
  final List<SessionMonitor> monitors;

  /// The Track-stage (per-track stereo bus) effect chains the session defines
  /// (schema v5; empty for a v4-or-earlier bundle, which could not describe
  /// this stage at all).
  final List<SessionTrackChain> trackChains;

  /// The single Master insert chain as an opaque chain-envelope string (schema
  /// v5); `''` when the session defines none — the same "no chain" state a
  /// v4-or-earlier bundle loads with.
  final String masterChain;

  /// Denominator-note beats per minute (schema v4, Phase A); `0` = unset (no
  /// tempo was ever set — mirrors `TransportState.tempoBpm`/
  /// `EngineSnapshot.tempoBpm`).
  final double tempoBpm;

  /// Where [tempoBpm] came from (D7 precedence); [TempoSource.none] when
  /// unset (default, and every pre-v4 session).
  final TempoSource tempoSource;

  /// Time-signature numerator (schema v4, Phase A; default `4`).
  final int tsNum;

  /// Time-signature denominator, `4` or `8` (schema v4, Phase A; default
  /// `4`).
  final int tsDen;

  /// Musical quantization granularity (schema v4, Phase A; default
  /// [GridDivision.off]).
  final GridDivision quantizeDiv;

  /// Exact saved relationship between the master loop and the musical grid.
  /// Zero preserves an intentionally grid-free loop.
  final int loopBars;

  /// The session's default record timing (accepted design, slice 2b): the
  /// engine's quantize gate and [quantizeDiv] as the one setting they pair
  /// into. Captured on save like the tempo-grid fields; absent on an older
  /// manifest reads [RecordTiming.immediately].
  final RecordTiming recordTiming;

  /// The session's default overdub decay in percent (`0..100`, slice 2b);
  /// `0` keeps every layer whole. Captured on save like the tempo-grid
  /// fields.
  final int overdubDecay;

  /// Click audibility mode (schema v4, Phase A; default [ClickMode.off]).
  /// The richer 4-value replacement for the index plan ERD's `metronomeOn`
  /// sketch — see the class doc.
  final ClickMode clickMode;

  /// Bitmask of hardware output channels the click sounds on (schema v4,
  /// Phase A; default `0`, no outputs — matches D5's "click defaults to no
  /// master outputs").
  final int clickOutputMask;

  /// Click volume in `0..LE_MAX_GAIN` (schema v4, Phase A; default `1`).
  final double clickVolume;

  /// Count-in length in measures (schema v4, Phase A); `0` = off (default).
  /// The richer measures-count replacement for the index plan ERD's
  /// `countIn` boolean sketch — see the class doc.
  final int countInBars;

  /// The session's looper mode, restored with its musical settings on load.
  final LooperMode looperMode;

  /// The session's crowned primary track (schema v4, B5c, D18); `-1` = none
  /// was ever crowned (default).
  final int primaryTrack;

  /// The default playback choice: Loop (`false`) or Once (`true`).
  final bool defaultOneShot;

  /// Explicit record timing choices, including choices equal to the default.
  final Map<int, RecordTiming> trackRecordTimingOverrides;

  /// Explicit decay percentages; missing tracks follow [overdubDecay].
  final Map<int, int> trackOverdubDecayOverrides;

  /// Explicit playback choices; missing tracks follow [defaultOneShot].
  final Map<int, bool> trackOneShotOverrides;

  /// Configured track lengths in bars, independent of recorded audio.
  final Map<int, int> trackLengthPresetOverrides;

  /// Whether the musical grid follows loop timing.
  final bool syncTempo;

  /// Whether ending a recording starts overdubbing.
  final bool recDub;

  /// Whether sound starts the recording.
  final bool autoRecord;

  /// Default track length in base loops; zero selects automatic length.
  final int defaultMultiple;

  /// This session's pedal remap as an OPAQUE encoded string (schema v6);
  /// `''` when the session defines none — which is also what every
  /// v5-or-earlier bundle loads with.
  ///
  /// Opaque exactly like the chain strings above (see [SessionLaneChain]): the
  /// binding model lives app-side next to `ControlCubit`, so this data package
  /// persists the blob without depending on it. It rides [Session] rather than
  /// the looper domain's `SessionRig` because a remap is control-surface
  /// configuration, not part of the audio rig the engine applies.
  ///
  /// Presence, not content, is the merge discriminator (A12): a session whose
  /// blob decodes to ANY bindings overrides the global set wholesale, and one
  /// with `''` defers to the globals entirely. There is no per-button merge.
  final String pedalBindings;

  /// Serializes this session manifest to a JSON map. Always writes the
  /// current [formatVersion].
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'sampleRate': sampleRate,
    'channels': channels,
    'baseLengthFrames': baseLengthFrames,
    'tracks': [for (final t in tracks) t.toJson()],
    'laneChains': [for (final c in laneChains) c.toJson()],
    'monitors': [for (final m in monitors) m.toJson()],
    'trackChains': [for (final c in trackChains) c.toJson()],
    'masterChain': masterChain,
    'tempoBpm': tempoBpm,
    'tempoSource': tempoSource.name,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'quantizeDiv': quantizeDiv.name,
    'loopBars': loopBars,
    'recordTiming': recordTiming.name,
    'overdubDecay': overdubDecay,
    'clickMode': clickMode.name,
    'clickOutputMask': clickOutputMask,
    'clickVolume': clickVolume,
    'countInBars': countInBars,
    'looperMode': looperMode.name,
    'primaryTrack': primaryTrack,
    'defaultOneShot': defaultOneShot,
    'trackRecordTimingOverrides': {
      for (final entry in trackRecordTimingOverrides.entries)
        '${entry.key}': entry.value.name,
    },
    'trackOverdubDecayOverrides': {
      for (final entry in trackOverdubDecayOverrides.entries)
        '${entry.key}': entry.value,
    },
    'trackOneShotOverrides': {
      for (final entry in trackOneShotOverrides.entries)
        '${entry.key}': entry.value,
    },
    'trackLengthPresetOverrides': {
      for (final entry in trackLengthPresetOverrides.entries)
        '${entry.key}': entry.value,
    },
    'syncTempo': syncTempo,
    'recDub': recDub,
    'autoRecord': autoRecord,
    'defaultMultiple': defaultMultiple,
    'pedalBindings': pedalBindings,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Session &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          baseLengthFrames == other.baseLengthFrames &&
          tempoBpm == other.tempoBpm &&
          tempoSource == other.tempoSource &&
          tsNum == other.tsNum &&
          tsDen == other.tsDen &&
          quantizeDiv == other.quantizeDiv &&
          loopBars == other.loopBars &&
          recordTiming == other.recordTiming &&
          overdubDecay == other.overdubDecay &&
          clickMode == other.clickMode &&
          clickOutputMask == other.clickOutputMask &&
          clickVolume == other.clickVolume &&
          countInBars == other.countInBars &&
          looperMode == other.looperMode &&
          primaryTrack == other.primaryTrack &&
          masterChain == other.masterChain &&
          pedalBindings == other.pedalBindings &&
          _listEquals(tracks, other.tracks) &&
          _listEquals(laneChains, other.laneChains) &&
          _listEquals(monitors, other.monitors) &&
          _listEquals(trackChains, other.trackChains) &&
          defaultOneShot == other.defaultOneShot &&
          syncTempo == other.syncTempo &&
          recDub == other.recDub &&
          autoRecord == other.autoRecord &&
          defaultMultiple == other.defaultMultiple &&
          _mapEquals(
            trackRecordTimingOverrides,
            other.trackRecordTimingOverrides,
          ) &&
          _mapEquals(
            trackOverdubDecayOverrides,
            other.trackOverdubDecayOverrides,
          ) &&
          _mapEquals(trackOneShotOverrides, other.trackOneShotOverrides) &&
          _mapEquals(
            trackLengthPresetOverrides,
            other.trackLengthPresetOverrides,
          );

  // hashAll, not hash: the field count passed v6's addition of
  // [pedalBindings], and `Object.hash` caps at 20 positional arguments.
  @override
  int get hashCode => Object.hashAll([
    sampleRate,
    channels,
    baseLengthFrames,
    tempoBpm,
    tempoSource,
    tsNum,
    tsDen,
    quantizeDiv,
    loopBars,
    recordTiming,
    overdubDecay,
    clickMode,
    clickOutputMask,
    clickVolume,
    countInBars,
    looperMode,
    primaryTrack,
    masterChain,
    pedalBindings,
    Object.hashAll(tracks),
    Object.hashAll(laneChains),
    Object.hashAll(monitors),
    Object.hashAll(trackChains),
    defaultOneShot,
    syncTempo,
    recDub,
    autoRecord,
    defaultMultiple,
    _mapHash(trackRecordTimingOverrides),
    _mapHash(trackOverdubDecayOverrides),
    _mapHash(trackOneShotOverrides),
    _mapHash(trackLengthPresetOverrides),
  ]);
}

/// Maps a persisted [Session.tempoSource] name back to a [TempoSource].
/// Absent (pre-v4) or unrecognized (a hypothetical future value this code
/// predates) values map to [TempoSource.none] — the same "grid-off" default
/// every other new v4 field falls back to.
TempoSource _tempoSourceFromJson(String? name) => TempoSource.values.firstWhere(
  (v) => v.name == name,
  orElse: () => TempoSource.none,
);

/// Maps a persisted [Session.quantizeDiv] name back to a [GridDivision].
/// Absent or unrecognized values map to [GridDivision.off].
GridDivision _gridDivisionFromJson(String? name) => GridDivision.values
    .firstWhere((v) => v.name == name, orElse: () => GridDivision.off);

/// Maps a persisted [Session.clickMode] name back to a [ClickMode]. Absent or
/// unrecognized values map to [ClickMode.off].
ClickMode _clickModeFromJson(String? name) => ClickMode.values.firstWhere(
  (v) => v.name == name,
  orElse: () => ClickMode.off,
);

/// Maps a persisted [Session.looperMode] name back to a [LooperMode]. Absent
/// (pre-v4, or a v4 session predating B5c) or unrecognized values map to
/// [LooperMode.multi] — the same "grid-off"-style default every other new v4
/// field falls back to.
LooperMode _looperModeFromJson(String? name) => LooperMode.values.firstWhere(
  (v) => v.name == name,
  orElse: () => LooperMode.multi,
);

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<int, T> _readOverrides<T>(Object? json, T Function(Object?) decode) => {
  for (final entry in (json as Map<String, dynamic>? ?? const {}).entries)
    int.parse(entry.key): decode(entry.value),
};

bool _mapEquals<T>(Map<int, T> a, Map<int, T> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

int _mapHash<T>(Map<int, T> values) => Object.hashAllUnordered(
  values.entries.map((entry) => Object.hash(entry.key, entry.value)),
);
