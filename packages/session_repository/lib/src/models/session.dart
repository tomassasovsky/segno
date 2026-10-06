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
/// [history] is the track's audio history (schema v12, #1164): the
/// [undoCount] undo entries oldest first, then the [redoCount] redo entries
/// newest-adjacent first, each with its kind. [layers] holds the images they
/// name oldest→newest: one per undo entry, the live buffer at
/// `layers[liveIndex]` (== [undoCount]), then one per redo entry except a
/// Peel marker, which holds no image ([TrackHistory.imageCount]).
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
    required this.history,
    this.pan = 0,
    this.balance = 1,
  });

  /// Projects a [SessionLane] from a decoded JSON map. The stored
  /// `redoCount` is derived on write and cross-checked by
  /// [SessionTrack.fromJson].
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
    pan: (json['pan'] as num?)?.toDouble() ?? 0,
    balance: (json['balance'] as num?)?.toDouble() ?? 1,
    history: TrackHistory(
      _readHistory(json['history']),
      undoCount: (json['undoCount'] as num).toInt(),
    ),
  );

  /// Lane index within the track.
  final int lane;

  /// The lane's LEVEL in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above
  /// unity): the looper repository's intent, not the gain the engine holds
  /// (that is the level times [balance]). Captured from the repository's
  /// projection when the save hands it in; a capture without one (an export)
  /// falls back to the engine's gain with a [balance] of `1`, which plays the
  /// same.
  final double volume;

  /// Whether the lane is muted.
  final bool muted;

  /// Bitmask of output channels this lane plays to (bit c => output c).
  final int outputMask;

  /// Hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  /// The lane's recorded image (slice 3), `-1` (left) .. `1` (right): where
  /// its input sat when the take was recorded, without the track's own pan
  /// ([Session.trackPans]), which the looper repository lands on top on
  /// load. Read from the repository's projection (`Lane.imagePan`), never
  /// from the engine, which only holds the sum. Written only when off
  /// centre; omitted at the current-schema default of `0`.
  final double pan;

  /// The gain the input pair's balance gave this lane's side when the take
  /// was recorded, `0..1` (`1` for a mono input; slice 3). The engine plays
  /// the lane at [volume] times this, and the mixdown does the same. Written
  /// only when below unity; omitted at the current-schema default of `1`.
  final double balance;

  /// The lane's audio images, oldest undo → live → newest redo.
  final List<SessionLayer> layers;

  /// The track's audio history in image-ordinal order: [undoCount] undo
  /// entries, then [redoCount] redo entries. Every lane of a track carries the
  /// same history; a lane with no history is [TrackHistory.none].
  final TrackHistory history;

  /// Number of leading [history] entries (and [layers]) on the undo side,
  /// below the live buffer.
  int get undoCount => history.undoCount;

  /// Number of trailing [history] entries on the redo side, above the live
  /// buffer.
  int get redoCount => history.redoCount;

  /// Maximum layers a lane can hold, mirroring the engine's `LE_POOL_SLOTS`
  /// (one live buffer plus up to 255 undo/redo snapshots). A bundle claiming
  /// more is rejected on load.
  static const int maxLayers = TrackHistory.maxImages;

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
    if (pan != 0) 'pan': pan,
    if (balance != 1) 'balance': balance,
    'history': [
      for (final e in history.entries)
        {'kind': e.kind.name, 'skipped': e.skipped},
    ],
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
          pan == other.pan &&
          balance == other.balance &&
          history == other.history &&
          _listEquals(layers, other.layers);

  @override
  int get hashCode => Object.hash(
    lane,
    volume,
    muted,
    outputMask,
    inputChannel,
    pan,
    balance,
    history,
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
    required this.fadeAmount,
    required this.lanes,
  });

  /// Projects a [SessionTrack] from a current-schema JSON map.
  factory SessionTrack.fromJson(Map<String, dynamic> json) {
    final amount = json['fadeAmount'];
    if (amount is! num || !amount.isFinite || amount < 0 || amount > 1) {
      throw const FormatException('invalid track Fade amount');
    }
    final channel = (json['channel'] as num).toInt();
    final lanes = <SessionLane>[];
    for (final raw in json['lanes'] as List<dynamic>) {
      final laneJson = raw as Map<String, dynamic>;
      final lane = SessionLane.fromJson(laneJson);
      _checkHistory(
        channel,
        lane,
        storedRedoCount: (laneJson['redoCount'] as num).toInt(),
      );
      lanes.add(lane);
    }
    for (final lane in lanes) {
      if (lane.history != lanes.first.history) {
        throw SessionCorruptLayers(
          channel: channel,
          lane: lane.lane,
          reason: 'history differs from lane ${lanes.first.lane}',
        );
      }
    }
    return SessionTrack(
      channel: channel,
      multiple: (json['multiple'] as num).toInt(),
      lengthFrames: (json['lengthFrames'] as num).toInt(),
      fadeAmount: amount.toDouble(),
      lanes: lanes,
    );
  }

  /// Track channel index.
  final int channel;

  /// Track length in whole base loops (`>= 1`).
  final int multiple;

  /// Captured length in frames (`multiple` × the base length).
  final int lengthFrames;

  /// Captured Fade coefficient, recalled as a stationary amount.
  final double fadeAmount;

  /// The track's lanes, each with its own mix/routing and audio layers.
  final List<SessionLane> lanes;

  /// Serializes this track to a JSON map.
  Map<String, dynamic> toJson() => {
    'channel': channel,
    'multiple': multiple,
    'lengthFrames': lengthFrames,
    'fadeAmount': fadeAmount,
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
          fadeAmount == other.fadeAmount &&
          _listEquals(lanes, other.lanes);

  @override
  int get hashCode => Object.hash(
    channel,
    multiple,
    lengthFrames,
    fadeAmount,
    Object.hashAll(lanes),
  );
}

/// One lane's Loop-stage effect chain within a [Session].
///
/// The chain is stored as the opaque [encoded] string the looper domain
/// produces — the same wire format settings persist — so this data package
/// never depends on the effect model. The string is the looper domain's chain
/// envelope (`encodeFxChain`: entries, enable flags, and inheritance).
/// Chains exist independently of audio, so a [channel]/[lane] here may not
/// match any [SessionTrack].
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

/// One output destination's post-sum effect chain within a [Session] (schema
/// v9): the destination [bus] and its [encoded] chain envelope.
@immutable
class SessionOutputChain {
  /// Creates a [SessionOutputChain].
  const SessionOutputChain({required this.bus, required this.encoded});

  /// Projects a [SessionOutputChain] from a decoded JSON map.
  factory SessionOutputChain.fromJson(Map<String, dynamic> json) {
    final bus = json['bus'];
    if (bus is! int || bus < 0 || bus >= 16) {
      throw const FormatException('invalid output chain destination');
    }
    return SessionOutputChain(bus: bus, encoded: json['encoded'] as String);
  }

  /// The output destination this chain sits after.
  final int bus;

  /// The chain as an opaque chain-envelope string.
  final String encoded;

  /// Serializes this chain to a JSON map.
  Map<String, dynamic> toJson() => {'bus': bus, 'encoded': encoded};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionOutputChain &&
          runtimeType == other.runtimeType &&
          bus == other.bus &&
          encoded == other.encoded;

  @override
  int get hashCode => Object.hash(bus, encoded);
}

/// One hardware input's live-monitor configuration within a [Session]:
/// routing / mix plus the monitor's [encoded] effect chain.
@immutable
class SessionMonitor {
  /// Creates a [SessionMonitor].
  const SessionMonitor({
    required this.input,
    required this.mode,
    required this.outputMask,
    required this.volume,
    required this.muted,
    required this.encoded,
  });

  /// Projects a [SessionMonitor] from a decoded JSON map.
  factory SessionMonitor.fromJson(Map<String, dynamic> json) {
    final mode = json['mode'];
    if (mode != 'off' && mode != 'on' && mode != 'auto') {
      throw const FormatException('invalid session monitor mode');
    }
    final volume = (json['volume'] as num).toDouble();
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw const FormatException('invalid session monitor volume');
    }
    return SessionMonitor(
      input: (json['input'] as num).toInt(),
      mode: mode as String,
      outputMask: (json['outputMask'] as num).toInt(),
      volume: volume,
      muted: json['muted'] as bool,
      encoded: json['encoded'] as String,
    );
  }

  /// Hardware input index.
  final int input;

  /// Bitmask of output channels the monitor plays to.
  final int outputMask;

  /// Monitor output gain from silence to unity (0–100%).
  final double volume;

  /// Whether the monitor is muted.
  final bool muted;

  /// The monitor chain as an opaque `encodeTrackEffects` string.
  final String encoded;

  /// The monitor's gate as its own name: `off`, `on`, or `auto`.
  ///
  /// A NAME, not the looper domain's enum: this package does not know that
  /// domain and must not learn it to carry one field. The app maps it, the
  /// same way the settings keys already store a mode by name.
  ///
  final String mode;

  /// Serializes this monitor to a JSON map.
  ///
  /// No pan: a monitor's pan is derived from [Session.inputSetup] on load
  /// (a pair member sits hard on its side, a mono input follows its pan),
  /// so a written copy would never be read back.
  Map<String, dynamic> toJson() => {
    'input': input,
    'mode': mode,
    'outputMask': outputMask,
    'volume': volume,
    'muted': muted,
    'encoded': encoded,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMonitor &&
          runtimeType == other.runtimeType &&
          input == other.input &&
          outputMask == other.outputMask &&
          volume == other.volume &&
          muted == other.muted &&
          encoded == other.encoded &&
          mode == other.mode;

  @override
  int get hashCode =>
      Object.hash(input, outputMask, volume, muted, encoded, mode);
}

/// The per-input capture setup a session was saved with (slice 3): capture
/// trim per input in dB, pan per mono input, and the balance of every stereo
/// pair keyed by the pair's lower (even) member. Every map is keyed by the
/// hardware input and holds only the inputs that are off their default
/// (unity, centre, unpaired), so an untouched rig serializes to nothing.
///
/// Plain maps rather than the looper domain's `InputSetup`: this package does
/// not know that domain (the same rule the chain strings follow). The app
/// maps between the two. Serialized as `{"trimDb": {"0": -6}, "pan":
/// {"2": -0.5}, "pairs": {"0": 0.2}}` with each empty map left out and the
/// whole object omitted from the manifest when all three are empty; absent
/// at the current-schema default reads as an empty setup.
@immutable
class SessionInputSetup {
  /// Creates a [SessionInputSetup].
  const SessionInputSetup({
    this.trimDb = const {},
    this.pan = const {},
    this.pairs = const {},
  });

  /// Projects a [SessionInputSetup] from a decoded JSON map; `null` is the
  /// current schema's omitted empty setup.
  factory SessionInputSetup.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SessionInputSetup();
    double value(Object? raw) => (raw! as num).toDouble();
    return SessionInputSetup(
      trimDb: _channelMapFromJson(json['trimDb'], value),
      pan: _channelMapFromJson(json['pan'], value),
      pairs: _channelMapFromJson(json['pairs'], value),
    );
  }

  /// Capture trim per input, in dB.
  final Map<int, double> trimDb;

  /// Pan per mono input, `-1` (left) .. `1` (right).
  final Map<int, double> pan;

  /// The balance of every stereo pair, keyed by its lower member: `-1`
  /// favours Left, `1` favours Right.
  final Map<int, double> pairs;

  /// Whether every map is empty (the whole object is then left out of the
  /// manifest).
  bool get isEmpty => trimDb.isEmpty && pan.isEmpty && pairs.isEmpty;

  /// Serializes this setup to a JSON map, each empty map left out.
  Map<String, dynamic> toJson() => {
    if (trimDb.isNotEmpty) 'trimDb': _channelMapToJson(trimDb),
    if (pan.isNotEmpty) 'pan': _channelMapToJson(pan),
    if (pairs.isNotEmpty) 'pairs': _channelMapToJson(pairs),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionInputSetup &&
          runtimeType == other.runtimeType &&
          _mapEquals(trimDb, other.trimDb) &&
          _mapEquals(pan, other.pan) &&
          _mapEquals(pairs, other.pairs);

  @override
  int get hashCode =>
      Object.hash(_mapHash(trimDb), _mapHash(pan), _mapHash(pairs));
}

/// The output setup a session persists (slice 3b): every output
/// destination's level, mute, Stereo/Mono and balance, each map keyed by
/// the destination (bus, one per stereo pair of outputs) and holding only
/// the destinations off that fact's default (unity, unmuted, Stereo,
/// centre), so an untouched rig serializes to nothing.
///
/// Plain maps rather than the looper domain's `OutputSetup`, like
/// [SessionInputSetup]. Serialized as `{"level": {"1": 0.5}, "muted":
/// {"0": true}, "mono": {"1": true}, "balance": {"0": -0.2}}` with each
/// empty map left out and the whole object omitted from the manifest when
/// all four are empty; absence in the current schema reads as the default.
@immutable
class SessionOutputSetup {
  /// Creates a [SessionOutputSetup].
  const SessionOutputSetup({
    this.level = const {},
    this.muted = const {},
    this.mono = const {},
    this.balance = const {},
  });

  /// Projects a [SessionOutputSetup] from a current-schema JSON map.
  factory SessionOutputSetup.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SessionOutputSetup();
    if (json.keys.any(
      (key) =>
          key != 'level' && key != 'muted' && key != 'mono' && key != 'balance',
    )) {
      throw const FormatException('invalid output setup field');
    }
    double number(Object? raw) {
      if (raw is! num) throw const FormatException('invalid output number');
      return raw.toDouble();
    }

    bool flag(Object? raw) {
      if (raw is! bool) throw const FormatException('invalid output flag');
      return raw;
    }

    final result = SessionOutputSetup(
      level: _channelMapFromJson(json['level'], number),
      muted: _channelMapFromJson(json['muted'], flag),
      mono: _channelMapFromJson(json['mono'], flag),
      balance: _channelMapFromJson(json['balance'], number),
    );
    if (!result.isValid) throw const FormatException('invalid output setup');
    return result;
  }

  /// Level per destination, `0..1`.
  final Map<int, double> level;

  /// The muted destinations (`true`).
  final Map<int, bool> muted;

  /// The destinations in Mono (`true`).
  final Map<int, bool> mono;

  /// Balance per destination, `-1` (left) .. `1` (right).
  final Map<int, double> balance;

  /// Whether every map is empty (the whole object is then left out of the
  /// manifest).
  bool get isEmpty =>
      level.isEmpty && muted.isEmpty && mono.isEmpty && balance.isEmpty;

  /// Strict current-schema shape and ranges; the engine accepts 16 buses.
  bool get isValid {
    bool channels(Iterable<int> keys) =>
        keys.every((key) => key >= 0 && key < 16);
    bool numbers(Map<int, double> values, double min, double max) =>
        channels(values.keys) &&
        values.values.every(
          (value) => value.isFinite && value >= min && value <= max,
        );
    return numbers(level, 0, 1) &&
        numbers(balance, -1, 1) &&
        channels(muted.keys) &&
        muted.values.every((value) => value) &&
        channels(mono.keys) &&
        mono.values.every((value) => value);
  }

  /// Serializes this setup to a JSON map, each empty map left out.
  Map<String, dynamic> toJson() {
    if (!isValid) throw const FormatException('invalid output setup');
    return {
      if (level.isNotEmpty) 'level': _channelMapToJson(level),
      if (muted.isNotEmpty) 'muted': _channelMapToJson(muted),
      if (mono.isNotEmpty) 'mono': _channelMapToJson(mono),
      if (balance.isNotEmpty) 'balance': _channelMapToJson(balance),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionOutputSetup &&
          runtimeType == other.runtimeType &&
          _mapEquals(level, other.level) &&
          _mapEquals(muted, other.muted) &&
          _mapEquals(mono, other.mono) &&
          _mapEquals(balance, other.balance);

  @override
  int get hashCode => Object.hash(
    _mapHash(level),
    _mapHash(muted),
    _mapHash(mono),
    _mapHash(balance),
  );
}

/// A saved Segno session, paired with per-lane, per-layer WAV files in a
/// `.segno` bundle directory. Only the current schema 12 is accepted.
///
/// Track settings are session-level maps, independent of audio entries.
/// Missing entries inherit the session default; explicit values, including
/// Loop (`false`) and values equal to the default, remain explicit.
/// Mixer gain and pan live in [trackLevels] and [trackPans], so an empty track
/// keeps both choices. [inputSetup] owns recording trim, mono pan and pairs.
/// [trackChains] and [outputChains] are the bus stages; [monitors] and
/// [laneChains] are the input and loop stages. Their chain strings use the
/// current chain envelope. [pedalBindings] remains opaque to this package.
@immutable
class Session {
  /// Creates a [Session].
  const Session({
    required this.sampleRate,
    required this.channels,
    required this.baseLengthFrames,
    required this.tracks,
    this.name,
    this.laneChains = const [],
    this.monitors = const [],
    this.trackChains = const [],
    this.outputChains = const [],
    this.allTracksChain = '',
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
    this.defaultLengthPresetBars = 0,
    this.defaultFadeDurationMs = 4000,
    this.trackFadeDurationOverrides = const {},
    this.trackRecordTimingOverrides = const {},
    this.trackOverdubDecayOverrides = const {},
    this.trackOneShotOverrides = const {},
    this.trackLengthPresetOverrides = const {},
    this.trackLevels = const {},
    this.trackPans = const {},
    this.laneInputs = const {},
    this.laneOutputs = const {},
    this.laneCounts = const {},
    this.syncTempo = true,
    this.recDub = false,
    this.autoRecord = false,
    this.defaultMultiple = 0,
    this.pedalBindings = '',
    this.inputSetup = const SessionInputSetup(),
    this.outputSetup = const SessionOutputSetup(),
  });

  /// Projects a [Session] from a decoded JSON map.
  ///
  /// Requires the current integer schema version. Current-schema defaults
  /// omitted by [toJson] still read as their declared defaults.
  factory Session.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int) {
      throw const FormatException('session version must be an integer');
    }
    if (version != formatVersion) {
      throw SessionUnsupportedVersion(
        version: version,
        supported: formatVersion,
      );
    }
    return Session(
      name: _readName(json['name']),
      sampleRate: (json['sampleRate'] as num).toInt(),
      channels: (json['channels'] as num).toInt(),
      baseLengthFrames: (json['baseLengthFrames'] as num).toInt(),
      tracks: [
        for (final t in json['tracks'] as List<dynamic>)
          SessionTrack.fromJson(t as Map<String, dynamic>),
      ],
      laneChains: [
        for (final c in json['laneChains'] as List<dynamic>)
          SessionLaneChain.fromJson(c as Map<String, dynamic>),
      ],
      monitors: [
        for (final m in json['monitors'] as List<dynamic>)
          SessionMonitor.fromJson(m as Map<String, dynamic>),
      ],
      trackChains: [
        for (final c in json['trackChains'] as List<dynamic>)
          SessionTrackChain.fromJson(c as Map<String, dynamic>),
      ],
      outputChains: _readOutputChains(json['outputChains']),
      allTracksChain: json['allTracksChain'] as String,
      tempoBpm: (json['tempoBpm'] as num).toDouble(),
      tempoSource: _readEnum(json['tempoSource'], TempoSource.values),
      tsNum: (json['tsNum'] as num).toInt(),
      tsDen: (json['tsDen'] as num).toInt(),
      quantizeDiv: _readEnum(json['quantizeDiv'], GridDivision.values),
      loopBars: (json['loopBars'] as num).toInt(),
      recordTiming: _readEnum(json['recordTiming'], RecordTiming.values),
      overdubDecay: (json['overdubDecay'] as num).toInt(),
      clickMode: _readEnum(json['clickMode'], ClickMode.values),
      clickOutputMask: (json['clickOutputMask'] as num).toInt(),
      clickVolume: (json['clickVolume'] as num).toDouble(),
      countInBars: _readCountIn(json['countInBars']),
      looperMode: _readEnum(json['looperMode'], LooperMode.values),
      primaryTrack: (json['primaryTrack'] as num).toInt(),
      defaultFadeDurationMs: _fadeDuration(json['defaultFadeDurationMs']),
      trackFadeDurationOverrides: _fadeOverrides(
        json['trackFadeDurationOverrides'],
      ),
      defaultOneShot: json['defaultOneShot'] as bool,
      defaultLengthPresetBars: (json['defaultLengthPresetBars'] as num).toInt(),
      trackRecordTimingOverrides: _readTrackOverrides(
        json['trackRecordTimingOverrides'] as Map<String, dynamic>,
        (value) => RecordTiming.values.byName(value! as String),
      ),
      trackOverdubDecayOverrides: _readTrackOverrides(
        json['trackOverdubDecayOverrides'] as Map<String, dynamic>,
        (value) => (value! as num).toInt(),
      ),
      trackOneShotOverrides: _readTrackOverrides(
        json['trackOneShotOverrides'] as Map<String, dynamic>,
        (value) => value! as bool,
      ),
      trackLengthPresetOverrides: _readTrackOverrides(
        json['trackLengthPresetOverrides'] as Map<String, dynamic>,
        (value) => (value! as num).toInt(),
      ),
      trackPans: _readTrackOverrides(
        json['trackPans'],
        (value) => (value! as num).toDouble(),
      ),
      trackLevels: _readTrackLevels(json['trackLevels']),
      laneInputs: _laneMapFromJson(json['laneInputs'], min: -1, max: 31),
      laneOutputs: _laneMapFromJson(
        json['laneOutputs'],
        min: 0,
        max: 0xffffffff,
      ),
      laneCounts: _routingCountsFromJson(json['laneCounts']),
      syncTempo: json['syncTempo'] as bool,
      recDub: json['recDub'] as bool,
      autoRecord: json['autoRecord'] as bool,
      defaultMultiple: (json['defaultMultiple'] as num).toInt(),
      pedalBindings: json['pedalBindings'] as String,
      inputSetup: SessionInputSetup.fromJson(
        json['inputSetup'] as Map<String, dynamic>?,
      ),
      outputSetup: SessionOutputSetup.fromJson(
        json['outputSetup'] as Map<String, dynamic>?,
      ),
    );
  }

  /// The current manifest schema stores per-track settings and all FX stages.
  static const int formatVersion = 12;

  /// The manifest filename within a session bundle.
  static const String manifestName = 'session.json';

  /// The session's display name, or `null` for a bundle saved before names
  /// were metadata (the catalog then shows the bundle directory's name).
  ///
  /// Rename rewrites this field and nothing else: the directory is the
  /// session's identity and the audio files are never touched. Read leniently
  /// (a blank or non-string value reads as absent) and written only when set,
  /// so a manifest without it stays byte-for-byte what it was.
  final String? name;

  /// Negotiated device sample rate the session was recorded at.
  final int sampleRate;

  /// Interleaved channel count of the stems.
  final int channels;

  /// The base (master) loop length in frames.
  final int baseLengthFrames;

  /// The session's tracks (those that hold audio).
  final List<SessionTrack> tracks;

  /// The Loop-stage (per-lane) effect chains the session defines.
  final List<SessionLaneChain> laneChains;

  /// The Input-stage per-input live monitors the session defines.
  final List<SessionMonitor> monitors;

  /// The Track-stage (per-track stereo bus) effect chains the session defines.
  final List<SessionTrackChain> trackChains;

  /// The single Master insert chain as an opaque chain-envelope string;
  /// `''` when the session defines none.
  final List<SessionOutputChain> outputChains;

  /// The single All tracks recorded-mix chain as an opaque chain-envelope
  /// string; `''` when the session defines none.
  final String allTracksChain;

  /// Denominator-note beats per minute (schema v4, Phase A); `0` = unset (no
  /// tempo was ever set — mirrors `TransportState.tempoBpm`/
  /// `EngineSnapshot.tempoBpm`).
  final double tempoBpm;

  /// Where [tempoBpm] came from (D7 precedence); [TempoSource.none] when
  /// unset.
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
  /// into. Captured on save like the tempo-grid fields.
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

  /// Default length for future recordings: zero is Auto, otherwise bars.
  final int defaultLengthPresetBars;

  /// Full-travel Fade time for tracks inheriting Default.
  final int defaultFadeDurationMs;

  /// Explicit Custom durations in milliseconds, including equality to Default.
  final Map<int, int> trackFadeDurationOverrides;

  /// Explicit record timing choices, including choices equal to the default.
  final Map<int, RecordTiming> trackRecordTimingOverrides;

  /// Explicit decay percentages; missing tracks follow [overdubDecay].
  final Map<int, int> trackOverdubDecayOverrides;

  /// Explicit playback choices; missing tracks follow [defaultOneShot].
  final Map<int, bool> trackOneShotOverrides;

  /// Configured track lengths in bars, independent of recorded audio.
  final Map<int, int> trackLengthPresetOverrides;

  /// Confirmed track pans, independent of whether a track holds audio.
  final Map<int, double> trackPans;

  /// Confirmed whole-track gains, independent of recorded lane levels.
  final Map<int, double> trackLevels;

  /// Whether the musical grid follows loop timing.
  final bool syncTempo;

  /// Whether ending a recording starts overdubbing.
  final bool recDub;

  /// Whether sound starts the recording.
  final bool autoRecord;

  /// Default track length in base loops; zero selects automatic length.
  final int defaultMultiple;

  /// This session's pedal remap as an opaque encoded string; `''` when the
  /// session defines none.
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

  /// The per-input capture setup the session was saved with (slice 3):
  /// trims, pans and pairs. Session-level like the override maps, because an
  /// input's setup exists whether or not anything was recorded from it.
  /// Omitted from the manifest when it is the default setup.
  final SessionInputSetup inputSetup;

  /// The output setup the session was saved with (slice 3b): every
  /// destination's level, mute, Stereo/Mono and balance. Session-level like
  /// [inputSetup]: a destination's setup exists whether or not anything was
  /// recorded. Omitted from the manifest when it is the default setup.
  final SessionOutputSetup outputSetup;

  /// Explicit source choices retained for inactive lanes and empty tracks.
  final Map<(int, int), int> laneInputs;

  /// Explicit destination choices retained for future-grown lanes.
  final Map<(int, int), int> laneOutputs;

  /// Active lane counts, including tracks without recorded audio.
  final Map<int, int> laneCounts;

  /// Serializes this session manifest to a JSON map. Always writes the
  /// current [formatVersion].
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    if (name != null) 'name': name,
    'sampleRate': sampleRate,
    'channels': channels,
    'baseLengthFrames': baseLengthFrames,
    'tracks': [for (final t in tracks) t.toJson()],
    'laneChains': [for (final c in laneChains) c.toJson()],
    'monitors': [for (final m in monitors) m.toJson()],
    'trackChains': [for (final c in trackChains) c.toJson()],
    'outputChains': [for (final c in outputChains) c.toJson()],
    'allTracksChain': allTracksChain,
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
    'defaultLengthPresetBars': defaultLengthPresetBars,
    'defaultFadeDurationMs': defaultFadeDurationMs,
    'trackFadeDurationOverrides': {
      for (final e in trackFadeDurationOverrides.entries) '${e.key}': e.value,
    },
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
    if (trackPans.isNotEmpty)
      'trackPans': {
        for (final entry in trackPans.entries) '${entry.key}': entry.value,
      },
    if (trackLevels.isNotEmpty)
      'trackLevels': {
        for (final entry in trackLevels.entries) '${entry.key}': entry.value,
      },
    if (laneInputs.isNotEmpty) 'laneInputs': _laneMapToJson(laneInputs),
    if (laneOutputs.isNotEmpty) 'laneOutputs': _laneMapToJson(laneOutputs),
    if (laneCounts.isNotEmpty) 'laneCounts': _channelMapToJson(laneCounts),
    'syncTempo': syncTempo,
    'recDub': recDub,
    'autoRecord': autoRecord,
    'defaultMultiple': defaultMultiple,
    'pedalBindings': pedalBindings,
    if (!inputSetup.isEmpty) 'inputSetup': inputSetup.toJson(),
    if (!outputSetup.isEmpty) 'outputSetup': outputSetup.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Session &&
          runtimeType == other.runtimeType &&
          name == other.name &&
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
          _listEquals(outputChains, other.outputChains) &&
          allTracksChain == other.allTracksChain &&
          pedalBindings == other.pedalBindings &&
          _listEquals(tracks, other.tracks) &&
          _listEquals(laneChains, other.laneChains) &&
          _listEquals(monitors, other.monitors) &&
          _listEquals(trackChains, other.trackChains) &&
          defaultOneShot == other.defaultOneShot &&
          defaultLengthPresetBars == other.defaultLengthPresetBars &&
          defaultFadeDurationMs == other.defaultFadeDurationMs &&
          _mapEquals(
            trackFadeDurationOverrides,
            other.trackFadeDurationOverrides,
          ) &&
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
          ) &&
          _mapEquals(trackPans, other.trackPans) &&
          _mapEquals(trackLevels, other.trackLevels) &&
          _laneMapEquals(laneInputs, other.laneInputs) &&
          _laneMapEquals(laneOutputs, other.laneOutputs) &&
          _mapEquals(laneCounts, other.laneCounts) &&
          inputSetup == other.inputSetup &&
          outputSetup == other.outputSetup;

  // hashAll, not hash: the field count passed v6's addition of
  // [pedalBindings], and `Object.hash` caps at 20 positional arguments.
  @override
  int get hashCode => Object.hashAll([
    name,
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
    Object.hashAll(outputChains),
    allTracksChain,
    pedalBindings,
    Object.hashAll(tracks),
    Object.hashAll(laneChains),
    Object.hashAll(monitors),
    Object.hashAll(trackChains),
    defaultOneShot,
    defaultLengthPresetBars,
    syncTempo,
    recDub,
    autoRecord,
    defaultMultiple,
    _mapHash(trackRecordTimingOverrides),
    _mapHash(trackOverdubDecayOverrides),
    _mapHash(trackOneShotOverrides),
    _mapHash(trackLengthPresetOverrides),
    defaultFadeDurationMs,
    _mapHash(trackFadeDurationOverrides),
    _mapHash(trackPans),
    _mapHash(trackLevels),
    _laneMapHash(laneInputs),
    _laneMapHash(laneOutputs),
    _mapHash(laneCounts),
    inputSetup,
    outputSetup,
  ]);
}

/// A blank or non-string `name` reads as absent rather than failing the load:
/// the name is display metadata, never a reason to refuse a bundle.
String? _readName(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

T _readEnum<T extends Enum>(Object? raw, List<T> values) {
  if (raw is! String) throw const FormatException('missing enum value');
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('unknown enum value: $raw');
}

/// Decodes a lane's history entries: each exactly `{kind, skipped}` with a
/// known kind name and an integer count.
List<HistoryEntry> _readHistory(Object? raw) {
  if (raw is! List) throw const FormatException('lane history must be a list');
  return [
    for (final entry in raw)
      switch (entry) {
        {'kind': final String kind, 'skipped': final int skipped}
            when entry.length == 2 =>
          HistoryEntry(_readEnum(kind, HistoryKind.values), skipped: skipped),
        _ => throw FormatException('invalid history entry: $entry'),
      },
  ];
}

/// Rejects a lane whose history the engine could not rebuild (#1164): a
/// stored redo count that disagrees with the entries, any
/// [TrackHistory.malformation] (the same rules as the engine's
/// `le_engine_finalize_history`), or an image list that is not exactly one
/// image per image-bearing entry plus the live buffer.
void _checkHistory(
  int channel,
  SessionLane lane, {
  required int storedRedoCount,
}) {
  Never corrupt(String reason) => throw SessionCorruptLayers(
    channel: channel,
    lane: lane.lane,
    reason: reason,
  );
  final history = lane.history;
  if (storedRedoCount != history.redoCount) {
    corrupt(
      'redoCount $storedRedoCount but ${history.entries.length} entries '
      'with undoCount ${history.undoCount}',
    );
  }
  final malformation = history.malformation;
  if (malformation != null) corrupt(malformation);
  final images = history.imageCount;
  if (lane.layers.length != images) {
    corrupt('${lane.layers.length} layers but the history names $images');
  }
}

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

/// A per-track map whose keys must name one of the eight fixed tracks, so a
/// bad Session is refused at decode, before the rig is cleared.
Map<int, T> _readTrackOverrides<T>(Object? json, T Function(Object?) decode) {
  final values = _readOverrides(json, decode);
  if (values.keys.any((channel) => channel < 0 || channel >= 8)) {
    throw const FormatException('invalid session track override');
  }
  return values;
}

/// Count-in is Off or 1, 2 or 4 bars.
int _readCountIn(Object? raw) {
  if (raw is! num || !const [0, 1, 2, 4].contains(raw)) {
    throw const FormatException('invalid session count-in');
  }
  return raw.toInt();
}

Map<int, double> _readTrackLevels(Object? raw) {
  final values = _readOverrides(raw, (value) {
    if (value is! num) throw const FormatException('invalid track gain');
    return value.toDouble();
  });
  if (values.entries.any(
    (entry) =>
        entry.key < 0 ||
        entry.key >= 8 ||
        !entry.value.isFinite ||
        entry.value < 0 ||
        entry.value > 2,
  )) {
    throw const FormatException('invalid track gain');
  }
  return values;
}

bool _mapEquals<T>(Map<int, T> a, Map<int, T> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

int _mapHash<T>(Map<int, T> values) => Object.hashAllUnordered(
  values.entries.map((entry) => Object.hash(entry.key, entry.value)),
);

Map<String, int> _laneMapToJson(Map<(int, int), int> values) => {
  for (final e in values.entries) '${e.key.$1}.${e.key.$2}': e.value,
};

Map<(int, int), int> _laneMapFromJson(
  Object? raw, {
  required int min,
  required int max,
}) {
  if (raw == null) return const {};
  final result = <(int, int), int>{};
  for (final entry in (raw as Map<String, dynamic>).entries) {
    final address = entry.key.split('.');
    if (address.length != 2 || entry.value is! int) {
      throw const FormatException('invalid lane map');
    }
    final channel = int.parse(address[0]);
    final lane = int.parse(address[1]);
    final value = entry.value as int;
    if (channel < 0 ||
        channel >= 8 ||
        lane < 0 ||
        lane >= 8 ||
        value < min ||
        value > max) {
      throw const FormatException('invalid lane address');
    }
    result[(channel, lane)] = value;
  }
  return result;
}

Map<int, int> _routingCountsFromJson(Object? raw) {
  if (raw == null) return const {};
  final result = <int, int>{};
  for (final entry in (raw as Map<String, dynamic>).entries) {
    final channel = int.parse(entry.key);
    final count = entry.value;
    if (channel < 0 ||
        channel >= 8 ||
        count is! int ||
        count < 1 ||
        count > 8) {
      throw const FormatException('invalid lane count');
    }
    result[channel] = count;
  }
  return result;
}

bool _laneMapEquals(Map<(int, int), int> a, Map<(int, int), int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

int _laneMapHash(Map<(int, int), int> values) => Object.hashAllUnordered(
  values.entries.map((e) => Object.hash(e.key, e.value)),
);

Map<String, Object?> _channelMapToJson<V>(Map<int, V> map) => {
  for (final entry in map.entries) '${entry.key}': entry.value,
};

Map<int, V> _channelMapFromJson<V>(Object? raw, V Function(Object?) value) {
  if (raw == null) return const {};
  return {
    for (final entry in (raw as Map<String, dynamic>).entries)
      int.parse(entry.key): value(entry.value),
  };
}

List<SessionOutputChain> _readOutputChains(Object? value) {
  final chains = [
    for (final c in value! as List<dynamic>)
      SessionOutputChain.fromJson(c as Map<String, dynamic>),
  ];
  if (chains.map((chain) => chain.bus).toSet().length != chains.length) {
    throw const FormatException('duplicate output chain destination');
  }
  return chains;
}

int _fadeDuration(Object? value) {
  if (value is! int || value < 500 || value > 30000 || value % 500 != 0) {
    throw const FormatException('Invalid Fade duration');
  }
  return value;
}

Map<int, int> _fadeOverrides(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Missing or invalid Fade overrides');
  }
  return Map.unmodifiable({
    for (final entry in value.entries)
      _fadeChannel(entry.key): _fadeDuration(entry.value),
  });
}

int _fadeChannel(String key) {
  final channel = int.tryParse(key);
  if (channel == null || channel < 0 || channel > 7 || '$channel' != key) {
    throw const FormatException('Invalid Fade track');
  }
  return channel;
}
