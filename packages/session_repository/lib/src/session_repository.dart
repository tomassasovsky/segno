import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/src/models/session.dart';
import 'package:session_repository/src/models/session_preview.dart';
import 'package:session_repository/src/models/session_summary.dart';
import 'package:session_repository/src/session_exception.dart';
import 'package:session_repository/src/session_id.dart';
import 'package:session_repository/src/session_migration.dart';
import 'package:session_repository/src/session_name.dart';
import 'package:wav_codec/wav_codec.dart';

/// The decoded contents of a `.segno` session bundle: the manifest plus each
/// lane's ordinal-ordered layer PCM (undo… live … redo), keyed by
/// `(channel, lane)`.
typedef SessionBundle = ({
  Session session,
  Map<(int, int), List<Float32List>> laneStems,
});

/// A bundle opened for loading: its decoded [SessionBundle] and, when the
/// manifest was written by an older schema, the in-memory conversion that
/// [SessionRepository.commitConversion] writes back once the load succeeds.
typedef OpenedSession = ({
  SessionBundle bundle,
  SessionConversion? conversion,
});

/// The effect-chain data a [SessionRepository.save] persists that the engine
/// snapshot alone cannot supply: every FX stage's chains — Input
/// ([monitors]), Loop ([laneChains]), Track ([trackChains]), All tracks
/// ([allTracksChain]) and the output destinations ([outputChains]).
///
/// The bloc layer gathers these from the looper repository (the live rig is
/// the truth being saved) and hands them to [SessionRepository.save]. Kept as
/// pre-built manifest models so this package never depends on the effect model:
/// each chain arrives as an already-encoded opaque envelope string.
@immutable
class SessionChains {
  /// Creates a [SessionChains].
  const SessionChains({
    this.laneChains = const [],
    this.monitors = const [],
    this.trackChains = const [],
    this.outputChains = const [],
    this.allTracksChain = '',
  });

  /// The Loop-stage (per-lane) effect chains to persist.
  final List<SessionLaneChain> laneChains;

  /// The Input-stage per-input monitor configurations to persist.
  final List<SessionMonitor> monitors;

  /// The Track-stage (per-track stereo bus) effect chains to persist.
  final List<SessionTrackChain> trackChains;

  /// Each output destination's post-sum chain to persist, one entry per
  /// destination the rig configured.
  final List<SessionOutputChain> outputChains;

  /// The All tracks recorded-mix chain to persist as an opaque envelope
  /// string; `''` when the rig has none.
  final String allTracksChain;
}

/// Repository-owned lane mix that cannot be recovered from engine products.
typedef SessionLaneMix = ({double level, double imagePan, double balance});

/// Desired musical settings supplied by the app layer when saving.
///
/// These values belong to the live repository, independently of the engine's
/// running state and of whether a track contains recorded audio. Missing map
/// entries mean Use default; explicit entries are never collapsed to defaults.
@immutable
class SessionSettings {
  /// Creates the settings payload for a session save.
  const SessionSettings({
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.syncTempo = true,
    this.quantizeDiv = GridDivision.off,
    this.loopBars = 0,
    this.recordTiming = RecordTiming.immediately,
    this.overdubDecay = 0,
    this.defaultOneShot = false,
    this.defaultLengthPresetBars = 0,
    this.defaultFadeDurationMs = 4000,
    this.trackFadeDurationOverrides = const {},
    this.trackRecordTimingOverrides = const {},
    this.trackOverdubDecayOverrides = const {},
    this.trackOneShotOverrides = const {},
    this.trackLengthPresetOverrides = const {},
    this.clickMode = ClickMode.off,
    this.clickMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.recDub = false,
    this.autoRecord = false,
    this.defaultMultiple = 0,
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.trackLevels = const {},
    this.trackPans = const {},
    this.laneMix = const {},
    this.laneInputs = const {},
    this.laneOutputs = const {},
    this.laneCounts = const {},
    this.inputSetup = const SessionInputSetup(),
    this.outputSetup = const SessionOutputSetup(),
  });

  SessionSettings._detached(SessionSettings source)
    : tempoBpm = source.tempoBpm,
      tempoSource = source.tempoSource,
      tsNum = source.tsNum,
      tsDen = source.tsDen,
      syncTempo = source.syncTempo,
      quantizeDiv = source.quantizeDiv,
      loopBars = source.loopBars,
      recordTiming = source.recordTiming,
      overdubDecay = source.overdubDecay,
      defaultOneShot = source.defaultOneShot,
      defaultLengthPresetBars = source.defaultLengthPresetBars,
      defaultFadeDurationMs = source.defaultFadeDurationMs,
      trackFadeDurationOverrides = Map.unmodifiable(
        source.trackFadeDurationOverrides,
      ),
      trackRecordTimingOverrides = Map.unmodifiable(
        source.trackRecordTimingOverrides,
      ),
      trackOverdubDecayOverrides = Map.unmodifiable(
        source.trackOverdubDecayOverrides,
      ),
      trackOneShotOverrides = Map.unmodifiable(source.trackOneShotOverrides),
      trackLengthPresetOverrides = Map.unmodifiable(
        source.trackLengthPresetOverrides,
      ),
      clickMode = source.clickMode,
      clickMask = source.clickMask,
      clickVolume = source.clickVolume,
      countInBars = source.countInBars,
      recDub = source.recDub,
      autoRecord = source.autoRecord,
      defaultMultiple = source.defaultMultiple,
      looperMode = source.looperMode,
      primaryTrack = source.primaryTrack,
      trackLevels = Map.unmodifiable(source.trackLevels),
      trackPans = Map.unmodifiable(source.trackPans),
      laneMix = Map.unmodifiable(source.laneMix),
      laneInputs = Map.unmodifiable(source.laneInputs),
      laneOutputs = Map.unmodifiable(source.laneOutputs),
      laneCounts = Map.unmodifiable(source.laneCounts),
      inputSetup = SessionInputSetup(
        trimDb: Map.unmodifiable(source.inputSetup.trimDb),
        pan: Map.unmodifiable(source.inputSetup.pan),
        pairs: Map.unmodifiable(source.inputSetup.pairs),
      ),
      outputSetup = SessionOutputSetup(
        level: Map.unmodifiable(source.outputSetup.level),
        muted: Map.unmodifiable(source.outputSetup.muted),
        mono: Map.unmodifiable(source.outputSetup.mono),
        balance: Map.unmodifiable(source.outputSetup.balance),
      );

  /// Denominator-note beats per minute; zero means unset.
  final double tempoBpm;

  /// The origin of the stored tempo.
  final TempoSource tempoSource;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// Whether loop and musical grid timing are synchronized.
  final bool syncTempo;

  /// The musical grid division.
  final GridDivision quantizeDiv;

  /// Saved master-loop grid relationship; zero preserves a grid-free loop.
  final int loopBars;

  /// The default record timing.
  final RecordTiming recordTiming;

  /// The default overdub decay percentage.
  final int overdubDecay;

  /// The default playback choice: Loop or Once.
  final bool defaultOneShot;

  /// Default length for future recordings: zero is Auto, otherwise bars.
  final int defaultLengthPresetBars;

  /// Default full-travel Fade duration in milliseconds.
  final int defaultFadeDurationMs;

  /// Explicit Custom durations for the eight track slots.
  final Map<int, int> trackFadeDurationOverrides;

  /// Explicit record timing choices for any track.
  final Map<int, RecordTiming> trackRecordTimingOverrides;

  /// Explicit overdub decay percentages for any track.
  final Map<int, int> trackOverdubDecayOverrides;

  /// Explicit playback choices for any track.
  final Map<int, bool> trackOneShotOverrides;

  /// Configured track lengths in bars, including empty tracks.
  final Map<int, int> trackLengthPresetOverrides;

  /// Click audibility mode.
  final ClickMode clickMode;

  /// Click output-channel mask.
  final int clickMask;

  /// Click output gain.
  final double clickVolume;

  /// Count-in duration in bars.
  final int countInBars;

  /// Whether ending recording begins overdubbing.
  final bool recDub;

  /// Whether sound starts recording.
  final bool autoRecord;

  /// Default track length in base loops; zero is automatic.
  final int defaultMultiple;

  /// The session recording mode.
  final LooperMode looperMode;

  /// The crowned track, or minus one when none is crowned.
  final int primaryTrack;

  /// Confirmed pan for every track, including tracks without recorded audio.
  final Map<int, double> trackPans;

  /// Confirmed gain for every track, independent of lane levels.
  final Map<int, double> trackLevels;

  /// Recorded image, balance, and level for every captured lane.
  final Map<(int, int), SessionLaneMix> laneMix;

  /// Recorded source choices, including inactive future lanes.
  final Map<(int, int), int> laneInputs;

  /// Playback destination choices, including inactive future lanes.
  final Map<(int, int), int> laneOutputs;

  /// Active lane counts for tracks whether or not they hold audio.
  final Map<int, int> laneCounts;

  /// Session-owned recording trim, mono pan, and stereo pair balance.
  final SessionInputSetup inputSetup;

  /// The output setup (slice 3b), persisted session-level.
  final SessionOutputSetup outputSetup;
}

/// Saves Segno sessions, reads them back, keeps their catalog, and exports a
/// saved bundle's mixdown and stems.
///
/// A session is a `.segno` bundle directory: a [Session.manifestName] manifest,
/// one 32-bit-float WAV per layer, and a `mixdown.wav`. This repository only
/// does file I/O plus the engine READS a save needs (snapshot + loop PCM);
/// applying a loaded session to the engine is the looper repository's job
/// (the single owner of looper state) — see [read].
class SessionRepository {
  /// Creates a [SessionRepository] capturing from [engine].
  ///
  /// [sessionsRoot] resolves the `sessions/` root directory the catalog
  /// ([listSessions] / [bundlePathOf] / [renameSession] / [deleteSession] and
  /// the rest) operates under; it is optional so the path-addressed
  /// save/read flow needs no root. The catalog methods throw [StateError]
  /// when it is absent. Injecting a resolver keeps the catalog testable
  /// (point it at a temp dir). [now] stamps new bundle ids ([newSessionId]);
  /// injectable for deterministic tests.
  ///
  /// [clearPollInterval]/[clearPollAttempts] bound how long a save/export waits
  /// for queued commands and in-flight overdub layers to settle before
  /// capturing. Tests can shrink
  /// these.
  SessionRepository({
    required AudioEngine engine,
    required GuardRegistry guards,
    Future<String> Function()? sessionsRoot,
    DateTime Function() now = DateTime.now,
    Duration clearPollInterval = const Duration(milliseconds: 8),
    int clearPollAttempts = 64,
  }) : _engine = engine,
       _guards = guards,
       _sessionsRoot = sessionsRoot,
       _now = now,
       _clearPollInterval = clearPollInterval,
       _clearPollAttempts = clearPollAttempts;

  final AudioEngine _engine;
  final Future<String> Function()? _sessionsRoot;
  final DateTime Function() _now;
  final Duration _clearPollInterval;
  final int _clearPollAttempts;

  /// The app's one guard table (accepted behaviour 6.12). A save holds a
  /// `sessionWrite` guard on its bundle while it writes, so a second write
  /// of the same bundle and a shutdown are refused at their commits, and the
  /// save itself is refused once a shutdown has begun.
  final GuardRegistry _guards;

  /// What a refusal names a session write by.
  static const String writePurpose = 'saving a session';

  /// The mixdown filename within a session bundle.
  static const String mixdownName = 'mixdown.wav';

  // ---- the session catalog ----
  //
  // `sessions/[<folder>/]<id>/` bundles. A bundle's directory name is its
  // identity ([SessionId]); its display name is manifest metadata. A directory
  // without a manifest is a folder (one level only), unless it holds layer
  // WAVs or a mixdown, in which case it is an interrupted save and belongs to
  // nobody here. The filesystem is the only index. These methods never touch
  // the path-addressed read/save below — the bloc layer resolves an id to a
  // path via [bundlePathOf] and feeds that into those.

  Future<String> _rootPath() async {
    final resolver = _sessionsRoot;
    if (resolver == null) {
      throw StateError('SessionRepository has no sessionsRoot configured');
    }
    final root = await resolver();
    _recoverInterruptedSwaps(Directory(root), inFlight: _staging);
    return root;
  }

  static bool _isBundle(String path) =>
      File('$path/${Session.manifestName}').existsSync();

  /// A manifest-less directory holding what a save writes is a save that
  /// never reached its manifest, not a folder: it is listed nowhere and left
  /// alone.
  static bool _isInterruptedSave(Directory dir) {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (name == mixdownName || _layerFilePattern.hasMatch(name)) return true;
    }
    return false;
  }

  static bool _isFolder(Directory dir) =>
      !_isTransient(_basename(dir.path)) &&
      !_isBundle(dir.path) &&
      !_isInterruptedSave(dir) &&
      !_isReservation(dir);

  /// An empty directory named like a minted id is a reservation
  /// ([newSessionId]): a save in flight, or one a crash or a failed copy left
  /// behind. It is no folder, so it never shows as a chip.
  static bool _isReservation(Directory dir) =>
      isMintedSessionId(_basename(dir.path)) && dir.listSync().isEmpty;

  static String _requireId(SessionId id) {
    if (!isValidSessionId(id)) {
      throw ArgumentError.value(id, 'id', 'not a valid session id');
    }
    return id;
  }

  static String _requireName(String name, String argument) {
    final slug = sessionSlug(name);
    if (slug == null) {
      throw ArgumentError.value(name, argument, 'not a valid session name');
    }
    return slug;
  }

  /// The bundle directory holding [id], at the root or one folder down, or
  /// `null` when no bundle has that id.
  String? _locate(String root, SessionId id) {
    if (_isBundle('$root/$id')) return '$root/$id';
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity is Directory &&
          _isFolder(entity) &&
          _isBundle('${entity.path}/$id')) {
        return '${entity.path}/$id';
      }
    }
    return null;
  }

  /// Resolves [id]'s bundle directory: where it lives today, or `root/<id>`
  /// (Unfiled) for an id that has no bundle yet. Throws [ArgumentError] for
  /// an id that cannot be a directory name.
  Future<String> bundlePathOf(SessionId id) async {
    _requireId(id);
    final root = await _rootPath();
    return _locate(root, id) ?? '$root/$id';
  }

  /// Mints an unused bundle id from the clock, `s-YYYYMMDD-HHMMSS`, and
  /// reserves it by creating its empty bundle directory at the root
  /// (Unfiled). The id takes a `-N` suffix when any directory at the root or
  /// one level down already has that name (a bundle, a folder, an interrupted
  /// save or another reservation), so a same-second Save as and Duplicate, or
  /// a folder named like an id, can never share a directory.
  ///
  /// A caller whose save then writes nothing gives the id back with
  /// [releaseSessionId]; an empty directory would otherwise list as a folder.
  Future<SessionId> newSessionId() async => _reserveId(await _rootPath());

  /// Picks the first free id for this second and creates `parent/<id>`
  /// (`parent` defaults to the root).
  ///
  /// The check and the create are synchronous with no await between them, so
  /// no other catalog call in this isolate can claim the same id in between.
  SessionId _reserveId(String root, {String? parent}) {
    final base = sessionIdFor(_now());
    var candidate = base;
    for (var n = 2; _isTaken(root, candidate); n++) {
      candidate = '$base-$n';
    }
    Directory('${parent ?? root}/$candidate').createSync(recursive: true);
    return candidate;
  }

  /// Whether any entry named [id] exists at the root or inside any directory
  /// directly under it.
  static bool _isTaken(String root, String id) {
    bool exists(String path) =>
        FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound;
    if (exists('$root/$id')) return true;
    final dir = Directory(root);
    if (!dir.existsSync()) return false;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory && exists('${entity.path}/$id')) return true;
    }
    return false;
  }

  /// Gives back an id [newSessionId] reserved when the save that was meant
  /// to fill it wrote nothing: removes its directory only while it is still
  /// empty. Anything written into it (a bundle, or an interrupted save's
  /// layers) is left in place.
  Future<void> releaseSessionId(SessionId id) async {
    _requireId(id);
    final dir = Directory('${await _rootPath()}/$id');
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    } on FileSystemException {
      // Something landed in it between the check and the delete: keep it.
    }
  }

  /// Lists every bundle under the root and one folder down, newest save
  /// first (unknown dates last, then by name). A bundle whose manifest does
  /// not decode still lists, flagged [SessionSummary.unreadable]; an
  /// interrupted save lists nowhere. Empty when the root does not exist yet.
  Future<List<SessionSummary>> listSessions() async {
    final root = Directory(await _rootPath());
    if (!root.existsSync()) return const [];
    final out = <SessionSummary>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      if (_isTransient(_basename(entity.path))) continue;
      if (_isBundle(entity.path)) {
        out.add(_summaryOf(entity, folder: null));
        continue;
      }
      if (_isInterruptedSave(entity)) continue;
      final folder = _basename(entity.path);
      for (final child in entity.listSync()) {
        if (child is Directory &&
            !_isTransient(_basename(child.path)) &&
            _isBundle(child.path)) {
          out.add(_summaryOf(child, folder: folder));
        }
      }
    }
    out.sort(_newestFirst);
    return out;
  }

  static int _newestFirst(SessionSummary a, SessionSummary b) {
    final at = a.modifiedAt;
    final bt = b.modifiedAt;
    if (at != null && bt != null && at != bt) return bt.compareTo(at);
    if (at == null && bt != null) return 1;
    if (at != null && bt == null) return -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// The catalog row for the bundle at [dir]: a lenient read of its manifest
  /// as a JSON map, never through [Session.fromJson], so a bundle this build
  /// cannot load is still listed.
  SessionSummary _summaryOf(Directory dir, {required String? folder}) {
    final id = _basename(dir.path);
    final manifest = File('${dir.path}/${Session.manifestName}');
    final modifiedAt = _manifestModifiedAt(manifest);
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is Map<String, dynamic>) json = decoded;
    } on Object {
      json = null;
    }
    if (json == null) {
      return SessionSummary(
        id: id,
        name: id,
        folder: folder,
        modifiedAt: modifiedAt,
        unreadable: true,
      );
    }
    return SessionSummary(
      id: id,
      name: _displayName(json['name'], id),
      folder: folder,
      modifiedAt: modifiedAt,
      trackCount: _lengthOf(json['tracks']),
      populatedChannels: _channelsOf(json['tracks']),
      tempoBpm: _doubleOf(json['tempoBpm'], 0),
      tsNum: _intOf(json['tsNum'], 4),
      tsDen: _intOf(json['tsDen'], 4),
      fxCount: _fxCountOf(json),
    );
  }

  static String _displayName(Object? raw, String fallback) {
    if (raw is! String) return fallback;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static int _lengthOf(Object? raw) => raw is List ? raw.length : 0;

  static List<int> _channelsOf(Object? raw) => raw is! List
      ? const []
      : [
          for (final track in raw)
            if (track is Map<String, dynamic> && track['channel'] is num)
              (track['channel'] as num).toInt(),
        ];

  static double _doubleOf(Object? raw, double fallback) =>
      raw is num && raw.isFinite ? raw.toDouble() : fallback;

  static int _intOf(Object? raw, int fallback) =>
      raw is num && raw.isFinite ? raw.toInt() : fallback;

  /// Effect entries across every chain stage the manifest carries.
  ///
  /// The one place this package looks inside a chain string, and only as far
  /// as counting its entries: the envelope is `{"entries": [...]}` or a bare
  /// array (`docs/design/session-bundle-format.md`), and the Library's row
  /// shows the count. Anything else reads as zero.
  static int _fxCountOf(Map<String, dynamic> json) {
    // `masterChain` is the older schemas' spelling of a bus-stage chain.
    var count =
        _chainEntries(json['allTracksChain']) +
        _chainEntries(json['masterChain']);
    for (final key in const [
      'laneChains',
      'monitors',
      'trackChains',
      'outputChains',
    ]) {
      final chains = json[key];
      if (chains is! List) continue;
      for (final chain in chains) {
        if (chain is Map<String, dynamic>) {
          count += _chainEntries(chain['encoded']);
        }
      }
    }
    return count;
  }

  static int _chainEntries(Object? encoded) {
    if (encoded is! String || encoded.isEmpty) return 0;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is List) return decoded.length;
      if (decoded is Map<String, dynamic>) {
        final entries = decoded['entries'];
        return entries is List ? entries.length : 0;
      }
    } on FormatException {
      return 0;
    }
    return 0;
  }

  /// The manifest's mtime — the moment the session was last SAVED, which is
  /// what the Library's date column claims. Null on a stat failure rather than
  /// epoch: a wrong "1 Jan 1970" is worse than no date.
  static DateTime? _manifestModifiedAt(File manifest) {
    try {
      return manifest.lastModifiedSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The decoded manifest and derived facts for the Library's preview panel
  /// — populated tracks, bars, layers, mutes, effect counts — with no audio
  /// read. Throws the typed [SessionException]s a load would, and
  /// [StateError] for an id with no bundle.
  Future<SessionPreview> readPreview(SessionId id) async {
    _requireId(id);
    final root = await _rootPath();
    final path = _locate(root, id);
    if (path == null) throw StateError('no session with id "$id"');
    final dir = Directory(path);
    final folder = dir.parent.path == root ? null : _basename(dir.parent.path);
    final summary = _summaryOf(dir, folder: folder);
    final session = decodeSessionManifest(
      await File('$path/${Session.manifestName}').readAsString(),
    ).session;
    final laneFx = <int, int>{};
    for (final chain in session.laneChains) {
      laneFx[chain.channel] =
          (laneFx[chain.channel] ?? 0) + _chainEntries(chain.encoded);
    }
    for (final chain in session.trackChains) {
      laneFx[chain.channel] =
          (laneFx[chain.channel] ?? 0) + _chainEntries(chain.encoded);
    }
    final tracks = <SessionPreviewTrack>[];
    for (final track in session.tracks) {
      if (track.lanes.isEmpty) continue;
      final lane0 = track.lanes.first;
      final live = lane0.undoCount < lane0.layers.length
          ? lane0.layers[lane0.undoCount].file
          : lane0.layers.last.file;
      tracks.add(
        SessionPreviewTrack(
          channel: track.channel,
          lengthFrames: track.lengthFrames,
          baseLengthFrames: session.baseLengthFrames,
          bars: _barsOf(
            frames: track.lengthFrames,
            sampleRate: session.sampleRate,
            tempoBpm: session.tempoBpm,
            tsNum: session.tsNum,
            tsDen: session.tsDen,
          ),
          layers: lane0.undoCount + 1,
          muted: track.lanes.every((lane) => lane.muted),
          fxCount: laneFx[track.channel] ?? 0,
          liveLayerFile: live,
        ),
      );
    }
    tracks.sort((a, b) => a.channel.compareTo(b.channel));
    return SessionPreview(
      summary: summary,
      tracks: tracks,
      fxCount: summary.fxCount,
      sampleRate: session.sampleRate,
      hasMixdown: File('$path/$mixdownName').existsSync(),
    );
  }

  /// Starts the Library's preview of the saved session [id] (plan D10): its
  /// `mixdown.wav` through the engine's audition voice on the main outputs,
  /// decoded off the UI isolate by the engine's one decoder, at most
  /// [kAuditionMaxSeconds] of it ([AuditionStart.truncated] says when the
  /// file is longer). A session with no mixdown is refused with
  /// [EngineResult.invalid] and nothing reaches the engine. Never loads the
  /// session. [stillWanted] is handed to the engine: a start the caller
  /// withdrew while it decoded never reaches the voice
  /// ([AuditionStart.cancelled]).
  Future<AuditionStart> startAudition(
    SessionId id, {
    bool Function()? stillWanted,
  }) async {
    _requireId(id);
    final path = _locate(await _rootPath(), id);
    if (path == null) {
      return const AuditionStart(result: EngineResult.invalid);
    }
    final mixdown = '$path/$mixdownName';
    if (!File(mixdown).existsSync()) {
      return const AuditionStart(result: EngineResult.invalid);
    }
    return _engine.auditionStartFile(mixdown, stillWanted: stillWanted);
  }

  /// Silences the Library's preview at the next block.
  EngineResult stopAudition() => _engine.auditionStop();

  /// The preview as the engine last reported it; a length of 0 means none
  /// plays (it ended, was stopped, or a device reopen or a performance arm
  /// ended it).
  AuditionState auditionState() => _engine.auditionState();

  /// [buckets] absolute peaks over [track]'s lane-0 live layer in the saved
  /// session [id], streamed off the UI isolate through the app's one decoder,
  /// or null when the layer cannot be read (plan D11: the lane then draws its
  /// length only).
  Future<Float32List?> readPeaks(
    SessionId id,
    SessionPreviewTrack track, {
    int buckets = 256,
  }) async {
    _requireId(id);
    final path = _locate(await _rootPath(), id);
    if (path == null || !_layerFilePattern.hasMatch(track.liveLayerFile)) {
      return null;
    }
    final layer = '$path/${track.liveLayerFile}';
    if (!File(layer).existsSync()) return null;
    return _engine.filePeaks(layer, buckets: buckets);
  }

  /// Whole bars at the saved tempo and signature, or 0 without a tempo.
  static int _barsOf({
    required int frames,
    required int sampleRate,
    required double tempoBpm,
    required int tsNum,
    required int tsDen,
  }) {
    if (tempoBpm <= 0 || sampleRate <= 0 || tsNum <= 0 || tsDen <= 0) return 0;
    final framesPerBeat = sampleRate * 60 / tempoBpm * (4 / tsDen);
    return (frames / (framesPerBeat * tsNum)).round();
  }

  /// The smallest `"<prefix> N"` (N from 1) no catalog name carries,
  /// compared case-insensitively so an automatic name never differs from an
  /// existing one by case alone. This only skips numbers and never refuses;
  /// a name the player picks collides case-sensitively ([_requireFreeName]).
  Future<String> nextAutomaticName(String prefix) async {
    final taken = {
      for (final s in await listSessions()) s.name.toLowerCase(),
    };
    for (var n = 1; ; n++) {
      final candidate = '$prefix $n';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// Throws [SessionNameCollision] when another session already carries
  /// exactly [slug]. [except] is the id allowed to carry it.
  ///
  /// Case-sensitive, as the appliance has always been: a name used to be a
  /// directory on case-sensitive ext4, so `Song` and `song` could both be
  /// saved and existing installs may hold such pairs. Refusing them now would
  /// turn a Save as that used to work into an error (rule 1, preserve
  /// existing installs).
  Future<void> _requireFreeName(String slug, {SessionId? except}) async {
    for (final s in await listSessions()) {
      if (s.id != except && s.name == slug) {
        throw SessionNameCollision(slug: slug);
      }
    }
  }

  /// Rewrites the manifest's `name` and nothing else; the bundle's identity
  /// and every WAV stay as they are. Throws [SessionNameCollision] when
  /// another session carries the name and [ArgumentError] for an invalid
  /// name. Renaming a session to its own name, or a missing id, is a no-op.
  Future<void> renameSession(SessionId id, String name) async {
    _requireId(id);
    final slug = _requireName(name, 'name');
    final root = await _rootPath();
    final path = _locate(root, id);
    if (path == null) return;
    final current = _summaryOf(
      Directory(path),
      folder: null,
    ).name;
    if (current == slug) return;
    await _requireFreeName(slug, except: id);
    final manifest = '$path/${Session.manifestName}';
    _writeManifestNamed(from: manifest, to: manifest, name: slug);
  }

  /// Writes the manifest at [from] to [to] carrying [name], atomically: the
  /// new manifest is written and flushed to a sibling temp file, then
  /// renamed into place, so a power cut leaves the old manifest (or none)
  /// or the new one at [to], never a torn file that would make the session
  /// unopenable.
  static void _writeManifestNamed({
    required String from,
    required String to,
    required String name,
  }) {
    final json =
        jsonDecode(File(from).readAsStringSync()) as Map<String, dynamic>;
    json['name'] = name;
    final temp = File('$to.tmp');
    try {
      temp
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(json),
          flush: true,
        )
        ..renameSync(to);
    } on Object {
      if (temp.existsSync()) temp.deleteSync();
      rethrow;
    }
  }

  /// Copies the bundle [from] to a new bundle beside it (same folder) under
  /// a fresh id, carrying [name] in the copy's own manifest. Returns the new
  /// id. Throws [SessionNameCollision] when a session already carries [name],
  /// [ArgumentError] for an invalid name, and [StateError] when [from] has no
  /// bundle. The copy is independent — editing it never touches [from].
  Future<SessionId> duplicateSession(SessionId from, String name) async {
    _requireId(from);
    final slug = _requireName(name, 'name');
    final root = await _rootPath();
    final source = _locate(root, from);
    if (source == null) throw StateError('no session with id "$from"');
    await _requireFreeName(slug);
    final parent = Directory(source).parent.path;
    final id = _reserveId(root, parent: parent);
    final target = Directory('$parent/$id');
    try {
      // The manifest goes last: until it lands, the copy is a manifest-less
      // directory of layer WAVs, an interrupted save that lists nowhere, so
      // a power cut mid-copy never lists a half copy (D2).
      _copyDirSync(
        Directory(source),
        target,
        skip: const {Session.manifestName, '${Session.manifestName}.tmp'},
      );
      _writeManifestNamed(
        from: '$source/${Session.manifestName}',
        to: '${target.path}/${Session.manifestName}',
        name: slug,
      );
      debugOnDuplicateWrite?.call('${target.path}/${Session.manifestName}');
    } on Object {
      // Everything in the reserved directory is this copy's own: remove it,
      // so a failed Duplicate leaves neither a half bundle under the
      // source's name nor an empty reservation. The source is untouched.
      if (target.existsSync()) target.deleteSync(recursive: true);
      rethrow;
    }
    return id;
  }

  /// Called with each path a Duplicate has just written, in order, so a
  /// test can see what a power cut at that moment would leave behind.
  @visibleForTesting
  static void Function(String path)? debugOnDuplicateWrite;

  /// Recursively copies [src] to [dst] (files + nested folders), leaving out
  /// the top-level entries named in [skip]. The catalog bundles are
  /// shallow, but this stays correct for any nesting.
  static void _copyDirSync(
    Directory src,
    Directory dst, {
    Set<String> skip = const {},
  }) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync()) {
      final name = _basename(entity.path);
      if (skip.contains(name)) continue;
      if (entity is Directory) {
        _copyDirSync(entity, Directory('${dst.path}/$name'));
      } else if (entity is File) {
        entity.copySync('${dst.path}/$name');
        debugOnDuplicateWrite?.call('${dst.path}/$name');
      }
    }
  }

  /// Deletes the bundle [id] wherever it sits. A missing id is a no-op.
  Future<void> deleteSession(SessionId id) async {
    _requireId(id);
    final path = _locate(await _rootPath(), id);
    if (path != null) Directory(path).deleteSync(recursive: true);
  }

  /// Moves the bundle [id] into [folder], or to the root (Unfiled) when
  /// [folder] is null. Throws [ArgumentError] when the folder does not exist.
  /// A move to where the bundle already is, or of a missing id, is a no-op.
  Future<void> moveSession(SessionId id, {String? folder}) async {
    _requireId(id);
    final root = await _rootPath();
    final path = _locate(root, id);
    if (path == null) return;
    final String parent;
    if (folder == null) {
      parent = root;
    } else {
      final slug = _requireName(folder, 'folder');
      final dir = Directory('$root/$slug');
      if (!dir.existsSync() || !_isFolder(dir)) {
        throw ArgumentError.value(folder, 'folder', 'no such folder');
      }
      parent = dir.path;
    }
    final target = '$parent/$id';
    if (target == path) return;
    Directory(path).renameSync(target);
  }

  /// The one-level folders under the root, sorted case-insensitively.
  Future<List<String>> listFolders() async {
    final root = Directory(await _rootPath());
    if (!root.existsSync()) return const [];
    return <String>[
      for (final entity in root.listSync())
        if (entity is Directory && _isFolder(entity)) _basename(entity.path),
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Creates the folder [name] under the root. Throws [SessionNameCollision]
  /// when a folder or bundle already has that directory name and
  /// [ArgumentError] for an invalid name, or one shaped like a session id.
  Future<void> createFolder(String name) async {
    final slug = _requireName(name, 'name');
    if (isMintedSessionId(slug)) {
      // An empty folder with an id's name would read as a reservation.
      throw ArgumentError.value(name, 'name', 'reads as a session id');
    }
    final root = await _rootPath();
    if (Directory('$root/$slug').existsSync()) {
      throw SessionNameCollision(slug: slug);
    }
    Directory('$root/$slug').createSync(recursive: true);
  }

  /// Renames the folder [name] to [to]; the sessions inside move with it and
  /// keep their ids. Throws [SessionNameCollision] when a folder or bundle
  /// already has that directory name, [ArgumentError] for an invalid name
  /// (or one shaped like a session id) and for a missing folder. Renaming a
  /// folder to its own name is a no-op.
  Future<void> renameFolder(String name, String to) async {
    final from = _requireName(name, 'name');
    final slug = _requireName(to, 'to');
    if (isMintedSessionId(slug)) {
      throw ArgumentError.value(to, 'to', 'reads as a session id');
    }
    final root = await _rootPath();
    final dir = Directory('$root/$from');
    if (!dir.existsSync() || !_isFolder(dir)) {
      throw ArgumentError.value(name, 'name', 'no such folder');
    }
    if (slug == from) return;
    if (FileSystemEntity.typeSync('$root/$slug', followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw SessionNameCollision(slug: slug);
    }
    dir.renameSync('$root/$slug');
  }

  /// Deletes the folder [name]. Throws [SessionFolderNotEmpty] while any
  /// directory inside it holds anything: a bundle, or an interrupted save
  /// the catalog does not list but leaves in place (plan D2). A missing
  /// folder is a no-op.
  Future<void> deleteFolder(String name) async {
    final slug = _requireName(name, 'name');
    final dir = Directory('${await _rootPath()}/$slug');
    if (!dir.existsSync() || !_isFolder(dir)) return;
    for (final child in dir.listSync(followLinks: false)) {
      if (child is Directory && child.listSync().isNotEmpty) {
        throw SessionFolderNotEmpty(folder: slug);
      }
    }
    dir.deleteSync(recursive: true);
  }

  /// Copies the saved bundle [id]'s `mixdown.wav` to [destinationPath]
  /// (creating its parent). Reads the saved bundle, never the live engine.
  /// Throws [StateError] when the bundle or its mixdown is missing (an empty
  /// session has none).
  Future<void> exportMixdown(SessionId id, String destinationPath) async {
    _requireId(id);
    final path = _locate(await _rootPath(), id);
    if (path == null) throw StateError('no session with id "$id"');
    final source = File('$path/$mixdownName');
    if (!source.existsSync()) {
      throw StateError('session "$id" has no mixdown to export');
    }
    await File(destinationPath).parent.create(recursive: true);
    await source.copy(destinationPath);
  }

  /// Copies every lane's live layer of the saved bundle [id] into
  /// [directory] as `track{c}_lane{l}_L0.wav` — the stems a DAW expects, one
  /// per lane, history dropped. Reads the saved bundle, never the live
  /// engine. Throws the typed [SessionException]s a load would and
  /// [StateError] when the bundle is missing.
  Future<void> exportStems(SessionId id, String directory) async {
    _requireId(id);
    final path = _locate(await _rootPath(), id);
    if (path == null) throw StateError('no session with id "$id"');
    final session = decodeSessionManifest(
      await File('$path/${Session.manifestName}').readAsString(),
    ).session;
    await Directory(directory).create(recursive: true);
    for (final track in session.tracks) {
      for (final lane in track.lanes) {
        if (lane.layers.isEmpty) continue;
        final live = lane.undoCount < lane.layers.length
            ? lane.layers[lane.undoCount].file
            : lane.layers.last.file;
        await File('$path/$live').copy(
          '$directory/track${track.channel}_lane${lane.lane}_L0.wav',
        );
      }
    }
  }

  /// The final path segment of [path] (the folder name), split on either
  /// separator so it is correct on every OS.
  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Saves the engine's current state to the `.segno` bundle [directory],
  /// writing the manifest, per-track stems, and a mixdown. Returns the saved
  /// [Session] manifest.
  ///
  /// The audio + per-track mix come from the engine snapshot; the effect chains
  /// come from [chains], gathered from the looper repository by the bloc layer
  /// (the live rig — not settings — is the truth being saved). Chains exist
  /// independently of audio, so they are written for every lane / monitor that
  /// has one, regardless of which tracks hold audio.
  ///
  /// [settings] carries the repository-owned musical choices, including
  /// settings for empty tracks and edits made while the engine is stopped.
  ///
  /// [pedalBindings] is this session's pedal remap as its opaque encoded
  /// string, handed in by the bloc layer the same way [chains] are (`''` for
  /// no session remap). It is a separate parameter rather than a
  /// [SessionChains] field because a remap is control-surface configuration,
  /// not an effect chain — the two travel together only by coincidence of
  /// both being opaque strings.
  /// [name] is the session's display name, written into the manifest; `null`
  /// leaves the manifest without one (the catalog then shows the directory
  /// name).
  /// [captureStillValid] guards the snapshot boundary after asynchronous
  /// command settlement. Once [_capture] detaches the audio, this save writes
  /// that coherent image even if the device lifecycle changes afterward.
  Future<Session> save(
    String directory, {
    required SessionSettings settings,
    SessionChains chains = const SessionChains(),
    String pedalBindings = '',
    String? name,
    bool Function()? captureStillValid,
  }) async {
    // Capture intent before any asynchronous audio or file work begins.
    final savedSettings = SessionSettings._detached(settings);
    await _awaitLayersSettled();
    if (captureStillValid?.call() == false) {
      throw StateError('session changed before save capture');
    }
    final captured = _capture(savedSettings);
    // The commit: the guard is taken where the bundle starts to change, and
    // a refusal leaves it untouched.
    final guard = _guards.enter(
      GuardKind.sessionWrite,
      GuardScope.internal(item: directory),
      purpose: writePurpose,
    );
    try {
      return await _saveCaptured(
        directory,
        captured,
        chains,
        savedSettings,
        pedalBindings,
        name,
      );
    } finally {
      guard.release();
    }
  }

  Future<Session> _saveCaptured(
    String directory,
    _Capture captured,
    SessionChains chains,
    SessionSettings savedSettings,
    String pedalBindings,
    String? name,
  ) async {
    final target = Directory(directory);
    // A save over an existing bundle never edits it in place: it writes a
    // whole new bundle beside it and swaps the two, so a failure (a full
    // disk, a power cut) leaves the previous save as it was. A new bundle is
    // written where it goes; until its manifest lands it is a hidden
    // interrupted save.
    final rewrite = _isBundle(directory);
    final dest = rewrite ? Directory('$directory$_stagingSuffix') : target;
    if (rewrite && dest.existsSync()) dest.deleteSync(recursive: true);
    await dest.create(recursive: true);
    // A catalog read while this save writes must not take its stage for a
    // leftover.
    if (rewrite) _staging.add(dest.path);
    final Session session;
    try {
      session = await _writeBundle(
        dest.path,
        captured,
        chains,
        savedSettings,
        pedalBindings,
        name,
      );
      if (rewrite) _carryForeignFiles(from: target, to: dest);
    } on Object {
      _staging.remove(dest.path);
      if (rewrite && dest.existsSync()) dest.deleteSync(recursive: true);
      rethrow;
    }
    try {
      if (rewrite) _swapIn(staging: dest, target: target);
    } on Object {
      // The previous save is back in place; the stage is not needed.
      if (dest.existsSync()) dest.deleteSync(recursive: true);
      rethrow;
    } finally {
      _staging.remove(dest.path);
    }
    return session;
  }

  /// The stages of write-backs being written right now, by any repository
  /// in this isolate: they all share the one sessions root.
  static final Set<String> _staging = {};

  /// The sibling a write-back is staged in before it is swapped in.
  static const String _stagingSuffix = '.saving';

  /// The name the previous save takes for the moment of the swap.
  static const String _retiredSuffix = '.old';

  /// Whether [name] is a staged or retired write-back, never a session or a
  /// folder: neither suffix can occur in an id or a folder name, which keep
  /// only letters, digits, spaces, hyphens and underscores.
  static bool _isTransient(String name) =>
      name.endsWith(_stagingSuffix) || name.endsWith(_retiredSuffix);

  /// Called with each file a save has just written, in order, and with the
  /// target before a write-back is swapped in; a test throws from it to
  /// stand for a full disk or a failed write at that moment.
  @visibleForTesting
  static void Function(String path)? debugOnSaveWrite;

  /// Writes the layers, the manifest and the mixdown of [captured] into the
  /// directory [path], each flushed to the device, and prunes layer files
  /// the manifest does not reference.
  Future<Session> _writeBundle(
    String path,
    _Capture captured,
    SessionChains chains,
    SessionSettings settings,
    String pedalBindings,
    String? name,
  ) async {
    final written = <String>{};
    for (final track in captured.tracks) {
      for (final lane in track.lanes) {
        final layerPcm = captured.laneStems[(track.channel, lane.lane)]!;
        for (var o = 0; o < lane.layers.length; o++) {
          final file = lane.layers[o].file;
          written.add(file);
          await File('$path/$file').writeAsBytes(
            WavCodec.encodeFloat32(
              samples: layerPcm[o],
              sampleRate: captured.snapshot.sampleRate,
              channels: 1,
            ),
            flush: true,
          );
          debugOnSaveWrite?.call('$path/$file');
        }
      }
    }

    final session = _sessionFrom(
      captured,
      chains,
      settings,
      pedalBindings,
      name,
    );
    await File('$path/${Session.manifestName}').writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
      flush: true,
    );
    debugOnSaveWrite?.call('$path/${Session.manifestName}');

    // The mixdown is the saved preview (Listen) and the mixdown export. An
    // empty mix leaves none: a re-save of an emptied rig must not keep audio
    // the session no longer holds.
    final mix = _mixdown(captured);
    final mixdownFile = File('$path/$mixdownName');
    if (mix.isNotEmpty) {
      await mixdownFile.writeAsBytes(
        WavCodec.encodeFloat32(
          samples: mix,
          sampleRate: captured.snapshot.sampleRate,
          channels: 1,
        ),
        flush: true,
      );
      debugOnSaveWrite?.call(mixdownFile.path);
    } else if (mixdownFile.existsSync()) {
      mixdownFile.deleteSync();
    }
    // The per-track file set is variable (lanes x layers shrink between
    // saves), so a save over files already there would otherwise leave
    // orphaned layer WAVs. The just-written manifest is the source of truth.
    await _pruneOrphanLayers(path, written);
    return session;
  }

  /// Copies into the staged bundle [to] every file of the previous bundle
  /// [from] that a save does not write itself, so a file this build does not
  /// know is kept through a re-save.
  static void _carryForeignFiles({
    required Directory from,
    required Directory to,
  }) {
    // Files an older-schema original names move with it (_keepOriginals).
    final originals = {
      for (final manifest in _originalManifests(from))
        ..._layerFilesOf(File('${from.path}/$manifest').readAsStringSync()),
    };
    for (final entity in from.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (originals.contains(name) ||
          name == Session.manifestName ||
          name == '${Session.manifestName}.tmp' ||
          name == mixdownName ||
          _layerFilePattern.hasMatch(name) ||
          _backupManifestPattern.hasMatch(name)) {
        continue;
      }
      entity.copySync('${to.path}/$name');
    }
  }

  /// Replaces [target] with [staging] in two renames: the previous save
  /// steps aside as `<id>.old`, the staged one takes its name, and the old
  /// one is deleted. A failed second rename puts the old one back. A power
  /// cut between the two leaves `<id>.old` and no `<id>`, which
  /// [_recoverInterruptedSwaps] puts back on the next catalog read: the
  /// previous save, whole.
  static void _swapIn({required Directory staging, required Directory target}) {
    debugOnSaveWrite?.call(target.path);
    final retired = Directory('${target.path}$_retiredSuffix');
    if (retired.existsSync()) retired.deleteSync(recursive: true);
    target.renameSync(retired.path);
    try {
      staging.renameSync(target.path);
    } on Object {
      retired.renameSync(target.path);
      rethrow;
    }
    _retire(retired, live: target);
  }

  /// Removes the previous save [retired] once [live] has replaced it, after
  /// moving its kept originals into [live] (see [_keepOriginals]). If that
  /// move fails, [retired] stays for the next catalog read to finish.
  static void _retire(Directory retired, {required Directory live}) {
    try {
      _keepOriginals(from: retired, to: live);
      retired.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the next catalog read to finish.
    }
  }

  /// Keeps every original of an older schema that the previous save
  /// [from] held, as a whole bundle folder inside [to] that opens on its
  /// own. A backup manifest (`session.v<N>.json`) and, when [from] was
  /// itself never converted, its own older manifest are first each
  /// assembled into a `session.v<N>/` folder inside [from], with the layer
  /// WAVs they name and the manifest last; then every complete folder moves
  /// into [to] in one rename. Moves, never copies: [from] is about to be
  /// deleted.
  ///
  /// Resumable: a folder without its manifest is an assembly a power cut
  /// interrupted, and the manifest it was for is still in [from], so the
  /// next run reuses that folder and finishes it. A folder is only ever
  /// moved whole, so a backup never ends up split across two folders.
  static void _keepOriginals({
    required Directory from,
    required Directory to,
  }) {
    for (final name in _originalManifests(from)..sort()) {
      final manifest = File('${from.path}/$name');
      final source = manifest.readAsStringSync();
      // A kept backup assembles under its own name; the bundle's own older
      // manifest under the first backup name its schema has free.
      final stem = name == Session.manifestName
          ? _assemblyStem(from, _versionOf(source)!)
          : name.substring(0, name.length - '.json'.length);
      final folder = Directory('${from.path}/$stem')..createSync();
      for (final file in _layerFilesOf(source)) {
        final layer = File('${from.path}/$file');
        if (layer.existsSync()) layer.renameSync('${folder.path}/$file');
      }
      debugOnKeepOriginal?.call(folder.path);
      manifest.renameSync('${folder.path}/${Session.manifestName}');
    }
    for (final entity in from.listSync()) {
      final name = _basename(entity.path);
      if (entity is Directory &&
          _backupFolderPattern.hasMatch(name) &&
          _isBundle(entity.path)) {
        entity.renameSync('${to.path}/${_freeBackupStem(to, name)}');
      }
    }
  }

  /// Called with each backup folder once its layer files are in and before
  /// its manifest is; a test throws from it to stand for a power cut there.
  @visibleForTesting
  static void Function(String folder)? debugOnKeepOriginal;

  /// The folder in [dir] to assemble a bundle's own schema-[version]
  /// manifest in: an unfinished one (no manifest yet) if there is one, else
  /// the first backup name no file or folder holds.
  static String _assemblyStem(Directory dir, int version) {
    for (var attempt = 1; ; attempt++) {
      final candidate = backupName(version, attempt).replaceAll('.json', '');
      final folder = Directory('${dir.path}/$candidate');
      if (folder.existsSync() && !_isBundle(folder.path)) return candidate;
      if (!folder.existsSync() &&
          !File('${dir.path}/$candidate.json').existsSync()) {
        return candidate;
      }
    }
  }

  /// The older-schema manifests in [dir]: its kept backups and, when it was
  /// never converted, its own `session.json`.
  static List<String> _originalManifests(Directory dir) {
    final names = [
      for (final entity in dir.listSync())
        if (entity is File &&
            _backupManifestPattern.hasMatch(_basename(entity.path)))
          _basename(entity.path),
    ];
    final own = File('${dir.path}/${Session.manifestName}');
    if (own.existsSync()) {
      final version = _versionOf(own.readAsStringSync());
      if (version != null && version < Session.formatVersion) {
        names.add(Session.manifestName);
      }
    }
    return names;
  }

  /// [stem], or the next numbered stem when [dir] already holds it as a
  /// backup file or folder.
  static String _freeBackupStem(Directory dir, String stem) {
    final match = RegExp(r'^session\.v(\d+)(?:\.(\d+))?$').firstMatch(stem)!;
    final version = int.parse(match.group(1)!);
    for (var attempt = int.parse(match.group(2) ?? '1'); ; attempt++) {
      final candidate = backupName(version, attempt).replaceAll('.json', '');
      if (!File('${dir.path}/$candidate.json').existsSync() &&
          !Directory('${dir.path}/$candidate').existsSync()) {
        return candidate;
      }
    }
  }

  /// The layer files a manifest [source] of any schema names.
  static Iterable<String> _layerFilesOf(String source) sync* {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    for (final track in json['tracks'] as List<dynamic>? ?? const []) {
      if (track is! Map<String, dynamic>) continue;
      final stem = track['stem'];
      if (stem is String) yield stem;
      for (final lane in track['lanes'] as List<dynamic>? ?? const []) {
        if (lane is! Map<String, dynamic>) continue;
        for (final layer in lane['layers'] as List<dynamic>? ?? const []) {
          if (layer is Map<String, dynamic> && layer['file'] is String) {
            yield layer['file'] as String;
          }
        }
      }
    }
  }

  /// A kept original manifest, `session.v<N>.json` or `session.v<N>.<k>.json`.
  static final RegExp _backupManifestPattern = RegExp(
    r'^session\.v\d+(\.\d+)?\.json$',
  );

  /// A kept original bundle folder, `session.v<N>` or `session.v<N>.<k>`.
  static final RegExp _backupFolderPattern = RegExp(r'^session\.v\d+(\.\d+)?$');

  /// Finishes or undoes write-backs a power cut interrupted, under [dir]
  /// (the root, then one folder down): a retired `<id>.old` with no `<id>`
  /// is put back (the swap never committed), one beside its `<id>` is
  /// deleted (it did), and a staged `<id>.saving` that is not [inFlight] is
  /// deleted (it was never swapped in).
  static void _recoverInterruptedSwaps(
    Directory dir, {
    required Set<String> inFlight,
    bool folders = true,
  }) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final path = entity.path;
      try {
        if (path.endsWith(_retiredSuffix)) {
          final live = path.substring(0, path.length - _retiredSuffix.length);
          if (Directory(live).existsSync()) {
            _retire(entity, live: Directory(live));
          } else {
            entity.renameSync(live);
          }
        } else if (path.endsWith(_stagingSuffix)) {
          if (!inFlight.contains(path)) entity.deleteSync(recursive: true);
        } else if (folders && !_isBundle(path)) {
          _recoverInterruptedSwaps(
            Directory(path),
            inFlight: inFlight,
            folders: false,
          );
        }
      } on FileSystemException {
        // Tried again on the next catalog read.
      }
    }
  }

  /// A fingerprint of everything [save] would write for the live rig, with
  /// no audio exported and no file touched (plan D7).
  ///
  /// It is the manifest [save] would build from [settings], [chains] and
  /// [pedalBindings], except that each lane's layer list is replaced by its
  /// track's content revision ([AudioEngine.trackAudioRev]), which changes
  /// on every write to that track's audio. Two equal fingerprints mean a
  /// save would write the same session; any edit to audio, effects, the
  /// mix, routing, settings or the pedal remap changes it. Only ever
  /// compared with another fingerprint from this method, never with a
  /// manifest.
  String fingerprint({
    required SessionSettings settings,
    SessionChains chains = const SessionChains(),
    String pedalBindings = '',
  }) {
    final snapshot = _engine.snapshot();
    final tracks = <SessionTrack>[];
    for (var i = 0; i < snapshot.tracks.length; i++) {
      final track = snapshot.tracks[i];
      if (track.state == TrackState.empty) continue;
      // A take in progress is content the next save may hold, so a
      // capturing track reads as changed. Playing and stopped are transport,
      // which a save does not write: a rig that was only played is
      // unchanged.
      final capturing =
          track.state == TrackState.recording ||
          track.state == TrackState.overdubbing;
      final content =
          'rev${_engine.trackAudioRev(i)}${capturing ? ':capturing' : ''}';
      final history = _engine.exportHistory(i);
      tracks.add(
        SessionTrack(
          channel: i,
          multiple: track.multiple,
          lengthFrames: track.lengthFrames,
          fadeAmount: track.fade.amount,
          reversed: track.reversed,
          lanes: [
            for (var l = 0; l < track.lanes.length; l++)
              SessionLane(
                lane: l,
                volume:
                    settings.laneMix[(i, l)]?.level ?? track.lanes[l].volume,
                muted: track.lanes[l].muted,
                outputMask: track.lanes[l].outputMask,
                inputChannel: track.lanes[l].inputChannel,
                layers: [SessionLayer(file: content)],
                pan: settings.laneMix[(i, l)]?.imagePan ?? 0,
                balance: settings.laneMix[(i, l)]?.balance ?? 1,
                history: history,
              ),
          ],
        ),
      );
    }
    final session = _sessionFrom(
      _Capture(
        snapshot: snapshot,
        laneStems: const {},
        tracks: tracks,
        trackLevels: const {},
      ),
      chains,
      SessionSettings._detached(settings),
      pedalBindings,
      null,
    );
    return jsonEncode(session.toJson());
  }

  /// The manifest [save] would build from [settings], [chains] and
  /// [pedalBindings], without its tracks, audio or name, and with no file
  /// touched: the settings half of the live rig, for `New loop` to start
  /// from (plan D9, through [Session.forNewLoop]).
  Session liveSession({
    required SessionSettings settings,
    SessionChains chains = const SessionChains(),
    String pedalBindings = '',
  }) => _sessionFrom(
    _Capture(
      snapshot: _engine.snapshot(),
      laneStems: const {},
      tracks: const [],
      trackLevels: const {},
    ),
    chains,
    SessionSettings._detached(settings),
    pedalBindings,
    null,
  );

  /// The pattern of a bundle's per-layer WAV filenames
  /// (`track{c}_lane{l}_L{n}.wav`).
  static final RegExp _layerFilePattern = RegExp(
    r'^track\d+_lane\d+_L\d+\.wav$',
  );

  /// Deletes every layer WAV in [directory] not in the [keep] set — the
  /// orphans a shrinking re-save leaves behind.
  Future<void> _pruneOrphanLayers(String directory, Set<String> keep) async {
    final dir = Directory(directory);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (_layerFilePattern.hasMatch(name) && !keep.contains(name)) {
        entity.deleteSync();
      }
    }
  }

  /// Reads and validates the `.segno` bundle [directory]: decodes the manifest
  /// and every lane's layer WAVs. Pure I/O — the engine is never driven and
  /// nothing is written; the caller (the bloc layer) hands the result to the
  /// looper repository's `applySession`, the one apply path. A manifest from
  /// an older schema is converted in memory with every formerly global
  /// setting at its default; [open] is the load path that keeps the player's.
  Future<SessionBundle> read(String directory) async =>
      (await open(directory)).bundle;

  /// Reads and validates the `.segno` bundle [directory] for loading, as
  /// [read] does, and converts a manifest written by an older schema in
  /// memory (see [decodeSessionManifest]). [liveSettings] supplies the
  /// player's current settings and is asked only for such a manifest. The
  /// bundle on disk is never touched here: [commitConversion] writes the
  /// conversion back once the caller has loaded it. Every refusal leaves the
  /// bundle byte-identical.
  ///
  /// The stems are raw PCM at the saved rate; loading them on a device running
  /// a different rate would play the session back at the wrong pitch (there is
  /// no resampling), so this refuses with [SessionSampleRateMismatch] rather
  /// than decode something unusable. A session without audio can restore its
  /// settings at any device sample rate.
  Future<OpenedSession> open(
    String directory, {
    FutureOr<SessionSettings> Function()? liveSettings,
  }) async {
    final source = await File(
      '$directory/${Session.manifestName}',
    ).readAsString();
    final version = _versionOf(source);
    final live =
        version != null &&
            version < Session.formatVersion &&
            liveSettings != null
        ? await liveSettings()
        : const SessionSettings();
    final (:session, :conversion) = decodeSessionManifest(source, live: live);
    try {
      _validateMusicalGrid(session);
    } on FormatException catch (error) {
      if (conversion == null) rethrow;
      throw SessionUnconvertible(
        version: conversion.fromVersion,
        reason: error.message,
      );
    }

    final current = _engine.snapshot();
    if (session.tracks.isNotEmpty &&
        current.sampleRate > 0 &&
        session.sampleRate > 0 &&
        current.sampleRate != session.sampleRate) {
      throw SessionSampleRateMismatch(
        sessionRate: session.sampleRate,
        deviceRate: current.sampleRate,
      );
    }

    // Decode every lane's layers in ordinal order (undo… live … redo).
    final laneStems = <(int, int), List<Float32List>>{};
    for (final track in session.tracks) {
      for (final lane in track.lanes) {
        final layers = <Float32List>[];
        for (final layer in lane.layers) {
          final bytes = await File('$directory/${layer.file}').readAsBytes();
          layers.add(WavCodec.decodeFloat32(bytes).samples);
        }
        laneStems[(track.channel, lane.lane)] = layers;
      }
    }
    return (
      bundle: (session: session, laneStems: laneStems),
      conversion: conversion,
    );
  }

  /// Writes an opened bundle's [conversion] back to [directory]: the original
  /// manifest is kept byte for byte beside it as `session.v<N>.json` (see
  /// [backupName]), then the converted manifest replaces `session.json`
  /// atomically. Does nothing when the manifest on disk is no longer the one
  /// that was converted. Until the next save the audio files are shared with
  /// the converted manifest, so the backup opens by putting it back as
  /// `session.json`; that save moves the backup and the original layer files
  /// into a `session.v<N>/` folder that opens as a bundle of its own.
  ///
  /// Returns whether the conversion was written: false when the manifest had
  /// changed, so nothing was.
  Future<bool> commitConversion(
    String directory,
    SessionConversion conversion,
  ) async {
    final manifest = File('$directory/${Session.manifestName}');
    if (await manifest.readAsString() != conversion.original) return false;
    await _keepOriginal(directory, conversion.fromVersion, conversion.original);
    await _replaceManifest(
      directory,
      const JsonEncoder.withIndent('  ').convert(conversion.manifest),
    );
    return true;
  }

  /// The backup name for an original manifest of schema [version]: a name no
  /// bundle file uses (`session.json`, `mixdown.wav`, the layer WAVs).
  /// [attempt] numbers further backups when one already holds other bytes.
  @visibleForTesting
  static String backupName(int version, [int attempt = 1]) => attempt == 1
      ? 'session.v$version.json'
      : 'session.v$version.$attempt.json';

  /// Keeps [original] under the first free backup name, or confirms an
  /// existing backup already holds exactly those bytes. Never overwrites.
  Future<void> _keepOriginal(
    String directory,
    int version,
    String original,
  ) async {
    for (var attempt = 1; ; attempt++) {
      final name = backupName(version, attempt);
      final backup = File('$directory/$name');
      final folder = File(
        '$directory/${name.replaceAll('.json', '')}/${Session.manifestName}',
      );
      if (folder.existsSync()) {
        if (await folder.readAsString() == original) return;
        continue;
      }
      if (backup.existsSync()) {
        if (await backup.readAsString() == original) return;
        continue;
      }
      try {
        await backup.create(exclusive: true);
      } on FileSystemException {
        if (backup.existsSync()) continue;
        rethrow;
      }
      await backup.writeAsString(original, flush: true);
      return;
    }
  }

  /// Called with the written temporary manifest before it is renamed into
  /// place; a test throws from it to stand for a failed rename.
  @visibleForTesting
  static void Function(String path)? debugOnReplaceManifest;

  /// Replaces the bundle's manifest with [contents] through a temporary file
  /// and a rename, so a crash leaves either the old or the new manifest.
  Future<void> _replaceManifest(String directory, String contents) async {
    final temporary = File('$directory/${Session.manifestName}.tmp');
    try {
      await temporary.writeAsString(contents, flush: true);
      debugOnReplaceManifest?.call(temporary.path);
      await temporary.rename('$directory/${Session.manifestName}');
    } on Object {
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  /// The integer `version` of a manifest [source], or null when it has none.
  static int? _versionOf(String source) {
    try {
      final json = jsonDecode(source);
      if (json is Map<String, dynamic>) {
        final version = json['version'];
        if (version is int) return version;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static void _validateMusicalGrid(Session session) {
    if (session.loopBars < 0 || session.loopBars > 0x7fffffff ~/ 15) {
      throw const FormatException('session contains an invalid bar grid');
    }

    final validTempo = switch (session.tempoSource) {
      TempoSource.none => session.tempoBpm == 0,
      TempoSource.manual ||
      TempoSource.tapped ||
      TempoSource.derived => session.tempoBpm >= 30 && session.tempoBpm <= 300,
      TempoSource.external => false,
    };
    if (!validTempo) {
      throw const FormatException('session contains an unsupported tempo pair');
    }
  }

  /// Reads the engine snapshot and each settled track's per-lane overdub layers
  /// once.
  ///
  /// Every active lane's full history is exported: the track's history entries
  /// with their kinds (#1164), and per lane the images they name — one per
  /// undo entry, the live buffer, then one per redo entry that is not a Peel
  /// marker (the history is track-wide, so every lane carries the same
  /// images). The split is the engine's raw stack count that comes with the
  /// entries, never the snapshot's `undoDepth`, which reads 0 while a Clear
  /// restore is in flight. A lane whose live buffer is empty is skipped, and
  /// a track left with no lane is dropped.
  _Capture _capture(SessionSettings settings) {
    final snapshot = _engine.snapshot();
    final laneStems = <(int, int), List<Float32List>>{};
    final tracks = <SessionTrack>[];
    final trackLevels = <int, double>{};
    for (var i = 0; i < snapshot.tracks.length; i++) {
      final track = snapshot.tracks[i];
      // Only export settled tracks: a recording/overdubbing track's buffer is
      // being written by the audio thread, so exporting it would race.
      if (track.state != TrackState.playing &&
          track.state != TrackState.stopped) {
        continue;
      }
      if (track.lengthFrames <= 0) continue;
      // The kinds name the images (#1164): a redo-side Peel marker holds
      // none, so the image count is not simply undo + 1 + redo.
      final history = _engine.exportHistory(i);
      final undoCount = history.undoCount;
      final total = history.imageCount;
      final lanes = <SessionLane>[];
      for (var l = 0; l < track.lanes.length; l++) {
        // The live layer sits at ordinal `undoCount`; skip a lane whose live
        // buffer is empty (nothing recorded on it).
        final live = _engine.exportLayer(i, l, undoCount);
        if (live.isEmpty) continue;
        final layerPcm = <Float32List>[];
        final layerFiles = <SessionLayer>[];
        for (var ordinal = 0; ordinal < total; ordinal++) {
          final pcm = ordinal == undoCount
              ? live
              : _engine.exportLayer(i, l, ordinal);
          if (pcm.isEmpty) break; // torn history — drop this lane
          layerPcm.add(pcm);
          layerFiles.add(
            SessionLayer(file: 'track${i}_lane${l}_L$ordinal.wav'),
          );
        }
        if (layerPcm.length != total) continue;
        laneStems[(i, l)] = layerPcm;
        final laneSnap = track.lanes[l];
        // The lane's mix (slice 3) comes from the looper repository, not
        // the engine: the engine holds the level times the balance and the
        // image plus the track's pan, and neither product can be taken
        // apart again. A lane the settings do not describe falls back to the
        // engine's gain times unity, which plays the same.
        final mix = settings.laneMix[(i, l)];
        lanes.add(
          SessionLane(
            lane: l,
            volume: mix?.level ?? laneSnap.volume,
            muted: laneSnap.muted,
            outputMask: laneSnap.outputMask,
            inputChannel: laneSnap.inputChannel,
            layers: layerFiles,
            pan: mix?.imagePan ?? 0,
            balance: mix?.balance ?? 1,
            history: history,
          ),
        );
      }
      if (lanes.isEmpty) continue;
      // Save uses its detached confirmed settings (absence means unity).
      trackLevels[i] = settings.trackLevels[i] ?? 1;
      tracks.add(
        SessionTrack(
          channel: i,
          multiple: track.multiple,
          lengthFrames: track.lengthFrames,
          fadeAmount: track.fade.amount,
          reversed: track.reversed,
          lanes: lanes,
        ),
      );
    }
    return _Capture(
      snapshot: snapshot,
      laneStems: laneStems,
      tracks: tracks,
      trackLevels: trackLevels,
    );
  }

  Session _sessionFrom(
    _Capture captured,
    SessionChains chains,
    SessionSettings settings,
    String pedalBindings,
    String? name,
  ) {
    final snapshot = captured.snapshot;
    return Session(
      name: name,
      sampleRate: snapshot.sampleRate,
      channels: 1,
      // The engine keeps the master grid alive after the last track is undone
      // to empty (redo needs it), but a session with zero tracks must not
      // persist that ghost length — loading it would re-establish a grid
      // with no content, silently locking the next recording's length.
      baseLengthFrames: captured.tracks.isEmpty
          ? 0
          : snapshot.masterLengthFrames,
      tracks: captured.tracks,
      laneChains: chains.laneChains,
      monitors: chains.monitors,
      // The two BUS stages (schema v5): like the chains above, these are the
      // live rig's — handed in already encoded, since a chain's insides are
      // the looper domain's business, not this package's.
      trackChains: chains.trackChains,
      outputChains: chains.outputChains,
      allTracksChain: chains.allTracksChain,
      // Running captures own the tempo and exact grid as one settled report.
      // Stopped saves retain the app's intended settings instead.
      tempoBpm: snapshot.isRunning ? snapshot.tempoBpm : settings.tempoBpm,
      tempoSource: snapshot.isRunning
          ? snapshot.tempoSource
          : settings.tempoSource,
      tsNum: snapshot.isRunning ? snapshot.tsNum : settings.tsNum,
      tsDen: snapshot.isRunning ? snapshot.tsDen : settings.tsDen,
      syncTempo: settings.syncTempo,
      quantizeDiv: settings.quantizeDiv,
      loopBars: snapshot.isRunning ? snapshot.loopBars : settings.loopBars,
      recordTiming: settings.recordTiming,
      overdubDecay: settings.overdubDecay,
      defaultOneShot: settings.defaultOneShot,
      defaultLengthPresetBars: settings.defaultLengthPresetBars,
      defaultFadeDurationMs: settings.defaultFadeDurationMs,
      trackFadeDurationOverrides: settings.trackFadeDurationOverrides,
      trackRecordTimingOverrides: settings.trackRecordTimingOverrides,
      trackOverdubDecayOverrides: settings.trackOverdubDecayOverrides,
      trackOneShotOverrides: settings.trackOneShotOverrides,
      trackLengthPresetOverrides: settings.trackLengthPresetOverrides,
      trackLevels: settings.trackLevels,
      trackPans: settings.trackPans,
      laneInputs: settings.laneInputs,
      laneOutputs: settings.laneOutputs,
      laneCounts: settings.laneCounts,
      inputSetup: settings.inputSetup,
      outputSetup: settings.outputSetup,
      clickMode: settings.clickMode,
      clickOutputMask: settings.clickMask,
      clickVolume: settings.clickVolume,
      countInBars: settings.countInBars,
      recDub: settings.recDub,
      autoRecord: settings.autoRecord,
      defaultMultiple: settings.defaultMultiple,
      looperMode: snapshot.isRunning
          ? snapshot.looperMode
          : settings.looperMode,
      primaryTrack: snapshot.isRunning
          ? snapshot.primaryTrack
          : settings.primaryTrack,

      // Control-surface configuration (schema v6), opaque here like the
      // chains — handed straight through from the bloc layer.
      pedalBindings: pedalBindings,
    );
  }

  /// Sums every unmuted lane at its part level and balance, with its track
  /// fader applied once, over
  /// the session period — the LCM of the lane lengths, so every lane's loop
  /// closes cleanly. Lanes are summed, never merged: a two-lane track
  /// contributes both lanes to the mix.
  Float32List _mixdown(_Capture captured) {
    final active = <(Float32List, double)>[];
    for (final track in captured.tracks) {
      for (final lane in track.lanes) {
        if (lane.muted) continue;
        final layerPcm = captured.laneStems[(track.channel, lane.lane)];
        if (layerPcm == null) continue;
        final pcm = layerPcm[lane.liveIndex]; // mix the live buffer per lane
        if (pcm.isEmpty) continue;
        active.add((
          pcm,
          lane.volume * lane.balance * captured.trackLevels[track.channel]!,
        ));
      }
    }
    if (active.isEmpty) return Float32List(0);

    var period = 1;
    for (final (pcm, _) in active) {
      period = _lcm(period, pcm.length);
    }

    final mix = Float32List(period);
    for (final (pcm, volume) in active) {
      final frames = pcm.length;
      if (frames == 0) continue;
      for (var f = 0; f < period; f++) {
        mix[f] += pcm[f % frames] * volume;
      }
    }
    return mix;
  }

  /// Waits for queued commands to publish their reports and for no track to
  /// have an overdub undo layer in flight (the punch-out
  /// fade tail / drain window, ~tens of ms): exporting during it would copy a
  /// buffer the audio thread is still writing, losing the tail. Throws on
  /// timeout rather than silently exporting a mid-fade stem.
  Future<void> _awaitLayersSettled() async {
    for (var attempt = 0; attempt < _clearPollAttempts; attempt++) {
      // Acquire the command publication before reading its resulting layers.
      final commandsSettled = _engine.commandsSettled;
      final snapshot = _engine.snapshot();
      if ((!snapshot.isRunning || commandsSettled) &&
          snapshot.tracks.every((t) => !t.layerInFlight)) {
        return;
      }
      await Future<void>.delayed(_clearPollInterval);
    }
    throw StateError(
      'engine commands or an overdub layer never settled — '
      'cannot export a stable capture',
    );
  }
}

int _gcd(int a, int b) {
  var x = a;
  var y = b;
  while (y != 0) {
    final t = y;
    y = x % y;
    x = t;
  }
  return x;
}

int _lcm(int a, int b) => (a == 0 || b == 0) ? 0 : (a ~/ _gcd(a, b)) * b;

/// The engine state captured once for a save/export.
class _Capture {
  const _Capture({
    required this.snapshot,
    required this.laneStems,
    required this.tracks,
    required this.trackLevels,
  });

  final EngineSnapshot snapshot;
  final Map<(int, int), List<Float32List>> laneStems;
  final List<SessionTrack> tracks;
  final Map<int, double> trackLevels;
}
