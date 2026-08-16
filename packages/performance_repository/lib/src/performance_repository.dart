import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:performance_repository/src/models/performance_chains.dart';
import 'package:performance_repository/src/models/performance_manifest.dart';
import 'package:performance_repository/src/models/unfinalized_capture.dart';
import 'package:performance_repository/src/performance_capture_status.dart';
import 'package:performance_repository/src/performance_exception.dart';
import 'package:performance_repository/src/performance_slug.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:wav_codec/wav_codec.dart';

/// Owns the performance-recording capture lifecycle end-to-end.
///
/// Composes [AudioEngine] (never `NativeAudioEngine`) the same way every other
/// repository does. A capture's directory IS its final bundle location from
/// the moment of [arm] — `{exportsRoot}/<slug>/` — so there is no separate
/// temp-then-move step: raw continuous taps (master/monitor, `perf_drain.c`)
/// and this layer's own settled-lane WAV exports all land directly where the
/// finished bundle expects them, and [disarm] only needs to convert the raw
/// taps to WAV and merge the snapshot metadata into the sidecar.
class PerformanceRepository {
  /// Creates a [PerformanceRepository] driving [engine].
  ///
  /// [exportsRoot] resolves the `exports/` root directory new bundles are
  /// created under (mirrors `SessionRepository`'s `sessionsRoot`). [now]
  /// supplies the timestamp [arm] slugs from; injectable for deterministic
  /// tests. [bootRecoveryPollInterval] paces [runBootRecovery]'s wait for
  /// the salvage render to finish before it moves the bundle; injectable so
  /// tests interleave against the wait without real 200ms sleeps.
  /// [bootRecoveryRenderTimeout] bounds that wait (default
  /// [defaultBootRecoveryRenderTimeout]) so a wedged render can never park
  /// boot recovery — and [arm]'s render-poll refusal — forever.
  PerformanceRepository({
    required AudioEngine engine,
    required Future<String> Function() exportsRoot,
    DateTime Function() now = DateTime.now,
    Duration bootRecoveryPollInterval = const Duration(milliseconds: 200),
    Duration bootRecoveryRenderTimeout = defaultBootRecoveryRenderTimeout,
  }) : _engine = engine,
       _exportsRoot = exportsRoot,
       _now = now,
       _bootRecoveryPollInterval = bootRecoveryPollInterval,
       _bootRecoveryRenderTimeout = bootRecoveryRenderTimeout;

  final AudioEngine _engine;
  final Future<String> Function() _exportsRoot;
  final DateTime Function() _now;
  final Duration _bootRecoveryPollInterval;
  final Duration _bootRecoveryRenderTimeout;

  /// The `exports/` root new bundles are created under.
  ///
  /// Public so a caller can ask about the volume a capture WOULD land on
  /// before [arm] creates anything on it — the free-space gate in
  /// `PerformanceRecorderCubit` needs a path to measure while still idle, and
  /// [armedDirectory] is necessarily null at that point (#640).
  Future<String> exportsRoot() => _exportsRoot();

  final StreamController<PerformanceCaptureStatus> _statusController =
      StreamController<PerformanceCaptureStatus>.broadcast();
  PerformanceCaptureStatus _status = PerformanceCaptureStatus.idle;

  /// The current capture directory, or `null` when not armed.
  String? _armedDir;
  PerformanceArmSnapshot? _armSnapshot;

  /// When the current capture was armed, or `null` when not armed. Backs
  /// [disarm]'s double-press guard (D-PEDAL/D-GUARD) — centralized here
  /// rather than in a caller, since arm/disarm now has more than one caller
  /// (the toolbar's `PerformanceRecorderCubit` and the pedal's `ControlCubit`
  /// MODE long-press) and both must share one guard rather than risk drift
  /// between two separately-tuned copies.
  DateTime? _armedAt;

  /// Whether an [arm] call is currently in flight (past its entry gate but
  /// not yet resolved either way). Backs [arm]'s overlapping-arm refusal:
  /// two arms passing the entry gate together can resolve the SAME slugged
  /// directory (the collision loop is synchronous, the create is not), after
  /// which the loser's re-check cleanup would delete the winner's just-armed
  /// live capture directory out from under the engine's drain thread.
  bool _armInFlight = false;

  /// The number of finalize passes ([_finalize]) currently in flight; [arm]
  /// refuses while it is above zero. A count, not a flag: finalizes can
  /// overlap entirely within the documented API (a boot-salvage
  /// [recoverCapture] mid-conversion while a live [disarm] finalizes its own
  /// directory), and a bool would let whichever finishes first reopen
  /// [arm]'s gate while the other is still mid-flight. Boot-salvage also
  /// finalizes with no armed directory at all, which is why [_armedDir]
  /// alone cannot cover this window.
  int _finalizesInFlight = 0;

  /// A disarm within this window of the matching arm is ignored — the arm
  /// and disarm gestures are easy to fat-finger back to back on the same
  /// control (a toolbar click, or a pedal long-press that fires again before
  /// the performer releases the footswitch).
  static const Duration disarmGuardWindow = Duration(seconds: 1);

  /// The sidecar manifest filename within a capture directory.
  static const String manifestName = 'performance.json';

  /// The directory under the exports root that [runBootRecovery] moves
  /// silently salvaged captures into, each keeping its own timestamped slug
  /// (`recovered/perf-YYYYMMDD-HHMMSS/`) so the take stays discoverable by
  /// name until a browsing UI exists for it.
  ///
  /// The same constant as [reservedRecoveredDirName]: [renameCapture]'s slug
  /// validation refuses the name, since a take renamed onto it would BE this
  /// area — enumerated by the retention prune, adopted by future salvages.
  static const String recoveredDirName = reservedRecoveredDirName;

  /// How long a salvaged capture lives under [recoveredDirName] before
  /// [runBootRecovery] prunes it at the next boot.
  ///
  /// Measured from when the bundle *landed* in the recovered area — read
  /// from the [recoveredAtStampName] stamp the move writes — not from when
  /// it was captured or finalized, so a bundle salvaged (or stranded, then
  /// swept) after the console sat unpowered for weeks still gets its full
  /// window on disk.
  static const Duration recoveredRetention = Duration(days: 30);

  /// The provenance + retention-clock stamp inside every recovered bundle:
  /// epoch milliseconds as text, written on the SOURCE bundle immediately
  /// before the move's rename so the rename carries it atomically — a
  /// bundle can never exist in the recovered area without its stamp, and a
  /// crash before the rename just re-stamps on that boot's retry. The prune
  /// ages ONLY stamped entries: the stamp is what proves the salvage moved
  /// a bundle in (a finished take a user drags into the area by hand has a
  /// sidecar but no stamp, and is never the prune's to delete), and its
  /// contents — not any filesystem mtime, which copies and moves rewrite
  /// freely — are the retention clock.
  static const String recoveredAtStampName = '.recovered-at';

  /// Timestamps before this instant are treated as evidence of a wrong
  /// clock, and the prune never acts on them. An RTC-less appliance (the Pi
  /// console) boots at/near the epoch until its first NTP sync, so a capture
  /// recovered before that sync carries a near-epoch [recoveredAtStampName]
  /// stamp — comparing it against the later-corrected clock computes
  /// decades of "age" and would delete yesterday's recovery. Anything
  /// stamped before this project's own era plainly wasn't recovered then;
  /// keep it and let a boot with a sane clock (which re-stamps nothing) age
  /// it out only if it truly is old.
  static final DateTime pruneSanityFloor = DateTime.utc(2026);

  /// The marker file [runBootRecovery] drops inside a bundle before
  /// salvaging it, and removes only after the bundle lands under
  /// [recoveredDirName]. Finished takes ALSO live finalized in the exports
  /// root (a capture's directory is its final bundle location), so a
  /// finalized sidecar alone cannot distinguish "salvage output stranded by
  /// a crash or render timeout before its move" from a take the user
  /// deliberately kept — the marker is what makes the boot-time sweep safe
  /// to run.
  static const String recoveryMarkerName = '.boot-recovery';

  /// Default for the ctor's `bootRecoveryRenderTimeout`: how long one
  /// salvage's stem render may run before [runBootRecovery] gives up
  /// waiting and keeps the bundle where it is (marker intact, for the next
  /// boot's sweep). Generous — a real render is minutes at the very worst —
  /// because expiring early merely defers the move, while a wedged render
  /// with NO bound would park the boot-recovery call forever.
  ///
  /// This bounds only the salvage *loop*, not [arm]'s render-poll refusal:
  /// after a timeout the engine may genuinely still be rendering, so [arm]
  /// stays refused (and the app keeps its busy flag up) until
  /// [renderProgress] actually reports done — anything else would re-enable
  /// a control whose every press is silently eaten. The loop also stops
  /// after a timeout rather than salvaging the next capture: the engine has
  /// one global render slot, and a sibling finalized while it is squatted
  /// would get no stems yet look fully recovered.
  static const Duration defaultBootRecoveryRenderTimeout = Duration(
    minutes: 10,
  );

  /// The arm-time snapshot's own file, written immediately at [arm] so it
  /// survives a crash before [disarm]'s finalize ever merges it into
  /// [manifestName] (which the drain thread keeps rewriting with only its own
  /// native fields while armed). Deleted once finalize folds it in.
  static const String _armSnapshotFileName = 'arm-snapshot.json';

  /// The repository-owned capture phase, replaying the current value to a new
  /// listener before live updates (mirrors `LooperRepository.looperState`).
  Stream<PerformanceCaptureStatus> get captureStatus async* {
    yield _status;
    yield* _statusController.stream;
  }

  /// The directory of the in-progress capture, or `null` when not armed.
  String? get armedDirectory => _armedDir;

  /// The offline renderer's current progress — dry stems (part 7), wet
  /// (FX-applied) stems, and the reconstructed master bus (both part 8) all
  /// run within the same render session, so one progress value covers all of
  /// them. A pure passthrough poll, the same on-demand convention
  /// `EngineSnapshot`'s own perf fields use. `PerformanceRenderProgress.empty`
  /// when no render has ever been started (or the most recent one already
  /// finished and nothing new has started since).
  PerformanceRenderProgress get renderProgress => _engine.renderPoll();

  /// Every track's render outcome discovered so far — grows progressively as
  /// each stem completes. `succeeded` reflects both that track's dry AND wet
  /// stem (either failing marks the track failed). A per-track failure does
  /// not mean the render as a whole failed (partial success); check
  /// [PerformanceRenderTrackStatus.succeeded] per entry.
  List<PerformanceRenderTrackStatus> get renderTrackStatuses =>
      _engine.renderTrackStatuses();

  /// The in-progress capture's elapsed time and overrun flag, read from the
  /// engine snapshot's own `perfFrames`/`perfOverruns`/
  /// `perfZeroFilledFrames` fields — meaningful only while armed; reads as
  /// zero/`false` otherwise, mirroring those fields' own at-rest defaults.
  /// Poll-on-demand, the same convention [renderProgress] uses, so a UI
  /// driving an elapsed-time readout ticks this itself rather than this
  /// repository owning a second internal timer.
  ({Duration elapsed, bool overrun, bool selfStopped}) get captureProgress {
    final snapshot = _engine.snapshot();
    final sampleRate = snapshot.sampleRate > 0 ? snapshot.sampleRate : 48000;
    return (
      elapsed: Duration(
        microseconds: snapshot.perfFrames * 1000000 ~/ sampleRate,
      ),
      // Either kind of hole counts. `perfOverruns` is only the frames the
      // audio thread could not enqueue; `perfZeroFilledFrames` is the silence
      // the drain actually wrote into the take, whatever its cause. #710's
      // takes had audible flickers with the first still reading zero, which
      // is how a glitched capture finalized claiming it was clean.
      overrun: snapshot.perfOverruns > 0 || snapshot.perfZeroFilledFrames > 0,
      // The drain thread died on a failed write. Carried alongside the
      // progress the UI already polls rather than on a second channel, so the
      // app learns about it at tick rate instead of not at all (#652).
      selfStopped: snapshot.perfStopped,
    );
  }

  void _setStatus(PerformanceCaptureStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Arms performance-recording capture: resolves a new collision-free
  /// `{exportsRoot}/perf-YYYYMMDD-HHMMSS/` bundle directory, takes the
  /// arm-time settled-lane snapshot (mid-overdub lanes marked deferred, never
  /// blocking on them), and arms the engine's capture taps into it.
  ///
  /// Idempotent — calling this while already armed is a no-op success,
  /// mirroring `EnginePerformanceCapture.perfArm`'s own idempotency (the
  /// original session keeps draining into its original directory). A second
  /// arm overlapping one still in flight is refused the same way (silent
  /// ok), preserving that same observable shape. [chains]
  /// supplies the lane/monitor effect chains and master-limiter state the
  /// engine snapshot alone cannot read back (see [PerformanceChains]).
  ///
  /// Refused — a no-op success, the same silent shape as the already-armed
  /// path and [disarm]'s guard-window refusal — while a salvage finalize or
  /// offline render is still in flight (#671): arming then would yank that
  /// in-progress finalize/render out from under whoever is watching it (the
  /// render's result dialog), and the pedal's MODE long-press calls this
  /// directly with no cubit-level gate in front of it. Callers observe
  /// the refusal through [captureStatus] never reporting armed (and
  /// [armedDirectory] staying null), not through the return value.
  Future<EngineResult> arm({
    PerformanceChains chains = const PerformanceChains(),
  }) async {
    if (_armedDir != null || _armInFlight) return EngineResult.ok;
    if (_finalizesInFlight > 0 || !renderProgress.done) return EngineResult.ok;
    _armInFlight = true;
    try {
      return await _armGated(chains);
    } finally {
      _armInFlight = false;
    }
  }

  /// The body of [arm] past its entry gate; runs with [_armInFlight] held.
  Future<EngineResult> _armGated(PerformanceChains chains) async {
    final root = await _exportsRoot();
    final base = performanceSlug(_now());
    var slug = base;
    var dir = '$root/$slug';
    var suffix = 1;
    while (Directory(dir).existsSync()) {
      slug = '$base-$suffix';
      dir = '$root/$slug';
      suffix++;
    }
    await Directory(dir).create(recursive: true);

    final snapshot = _engine.snapshot();
    final tracks = _captureSettledLanes(dir, chains: chains, writeChains: true);
    final armSnapshot = PerformanceArmSnapshot(
      clockFrame: snapshot.masterPositionFrames,
      masterLengthFrames: snapshot.masterLengthFrames,
      masterGain: snapshot.masterGain,
      limiterEnabled: chains.limiterEnabled,
      limiterCeiling: chains.limiterCeiling,
      latencyOffsetFrames: snapshot.recordOffsetFrames,
      tracks: tracks,
      monitors: _monitorsJson(chains),
      // The bus stages (FX v3, R20/R3): recorded so a replay can rebuild the
      // whole four-stage rig, bypass state included.
      trackChains: chains.trackChains,
      masterEffects: chains.masterEffects,
      masterChainEnabled: chains.masterChainEnabled,
    );
    await File(
      '$dir/$_armSnapshotFileName',
    ).writeAsString(jsonEncode(armSnapshot.toJson()));

    // Re-checked here, not just at entry: the awaits above suspend this arm,
    // and a boot-salvage ([recoverCapture]) starting inside that window
    // raises [_finalizesInFlight] too late for the entry gate to see — the
    // resumed arm would clobber the in-progress salvage. Same silent-ok
    // refusal shape; the just-created directory is discarded, exactly like
    // the failed-perfArm path below (#671).
    if (_armedDir != null || _finalizesInFlight > 0 || !renderProgress.done) {
      // Ownership-checked belt to [_armInFlight]'s braces: never delete the
      // live armed capture directory (the drain thread is writing into it) —
      // only this call's own still-unclaimed one.
      if (dir != _armedDir) {
        final created = Directory(dir);
        if (created.existsSync()) created.deleteSync(recursive: true);
      }
      return EngineResult.ok;
    }

    final result = _engine.perfArm(dir);
    if (!result.isOk) {
      final created = Directory(dir);
      if (created.existsSync()) created.deleteSync(recursive: true);
      return result;
    }

    _armedDir = dir;
    _armSnapshot = armSnapshot;
    _armedAt = _now();
    _setStatus(PerformanceCaptureStatus.armed);
    return EngineResult.ok;
  }

  /// Disarms performance-recording capture — the **toggle-gesture** path
  /// (toolbar click, pedal MODE long-press): a disarm within
  /// [disarmGuardWindow] of the matching [arm] is ignored, capture stays
  /// armed (D-GUARD; a fat-fingered re-press of the same physical control,
  /// not a deliberate disarm). Programmatic disarms that have nothing to do
  /// with that gesture — e.g. auto-disarm-before-load — must use
  /// [disarmAndFinalize] instead, which always proceeds.
  ///
  /// See [disarmAndFinalize] for what the disarm itself actually does;
  /// idempotent identically.
  Future<EngineResult> disarm() async {
    final dir = _armedDir;
    if (dir == null) return EngineResult.ok;
    final armedAt = _armedAt;
    if (armedAt != null && _now().difference(armedAt) < disarmGuardWindow) {
      return EngineResult.ok;
    }
    return _finalizeArmed(dir);
  }

  /// Disarms performance-recording capture unconditionally — the
  /// **programmatic** path (`SessionCubit` awaits this before applying a
  /// loaded session): never subject to [disarm]'s double-press guard, since
  /// a session load has nothing to do with a fat-fingered re-press of the
  /// arm/disarm control and must not be silently skipped by a guard built
  /// for a different scenario.
  ///
  /// Takes the disarm-time settled-lane snapshot pass (covers a track
  /// recorded fresh during the performance — recording finalization produces
  /// no retire event, so nothing else would persist its PCM), disarms the
  /// engine, converts the raw master/monitor PCM to WAV, and merges every
  /// snapshot into the sidecar with `finalized: true`.
  ///
  /// Idempotent — calling this while already disarmed is a no-op success.
  /// If `EnginePerformanceCapture.perfDisarm` itself fails (a stalled
  /// device), capture is left armed and finalize does not run — the rings
  /// and drain thread are retracted-but-running per its own contract, so
  /// finalizing now would race the still-writing drain thread.
  ///
  /// Once the bundle is finalized, starts the offline render (dry stems,
  /// wet/FX-applied stems, and the reconstructed master bus — parts 7-8) in
  /// the background — this method returns as soon as the bundle itself is
  /// complete, without waiting on the render; poll [renderProgress] /
  /// [renderTrackStatuses] for its outcome.
  Future<EngineResult> disarmAndFinalize() async {
    final dir = _armedDir;
    if (dir == null) return EngineResult.ok;
    return _finalizeArmed(dir);
  }

  Future<EngineResult> _finalizeArmed(String dir) async {
    _setStatus(PerformanceCaptureStatus.finalizing);
    final disarmSnapshot = PerformanceDisarmSnapshot(
      tracks: _captureSettledLanes(
        dir,
        chains: const PerformanceChains(),
        writeChains: false,
      ),
    );

    final result = _engine.perfDisarm();
    if (!result.isOk) {
      _setStatus(PerformanceCaptureStatus.armed);
      return result;
    }

    await _finalize(
      dir,
      armSnapshot: _armSnapshot,
      disarmSnapshot: disarmSnapshot,
    );

    _armedDir = null;
    _armSnapshot = null;
    _armedAt = null;
    _setStatus(PerformanceCaptureStatus.done);
    return EngineResult.ok;
  }

  /// Exports every currently-settled (non-capturing) lane's PCM into the
  /// in-progress capture directory's `loops/`, overwriting any prior export
  /// for that lane. A no-op when not armed.
  ///
  /// Supports D-CLEAR: `ControlCubit` awaits this before issuing a clear
  /// while armed — clear-all is a legitimate performance move (logged as an
  /// event), but a track currently capturing is skipped here (its buffer is
  /// being written by the audio thread and would tear); the retired-layer
  /// persistence path (part 5) covers those instead.
  Future<void> persistLiveLanes() async {
    final dir = _armedDir;
    if (dir == null) return;
    _captureSettledLanes(
      dir,
      chains: const PerformanceChains(),
      writeChains: false,
    );
  }

  /// Scans the exports root for capture directories whose sidecar lacks
  /// `finalized: true` — evidence of a crash while armed (D-SALVAGE). An
  /// unreadable/corrupt sidecar counts as unfinalized too (the write itself
  /// was interrupted).
  Future<List<UnfinalizedCapture>> findUnfinalized() async {
    final root = Directory(await _exportsRoot());
    if (!root.existsSync()) return const [];
    final out = <UnfinalizedCapture>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      if (!File('${entity.path}/$manifestName').existsSync()) continue;
      if (!_sidecarFinalized(entity.path)) {
        out.add(
          UnfinalizedCapture(
            directory: entity.path,
            slug: _basename(entity.path),
          ),
        );
      }
    }
    return out;
  }

  /// Recovers a crashed (unfinalized) capture at [directory]: runs the same
  /// finalize path [disarm] does, minus a live disarm (there is no engine
  /// session left to stop) and minus a disarm-time snapshot pass (there is no
  /// live engine state left to snapshot). The arm-time snapshot recovers from
  /// its own crash-survival file when present. Also starts the offline
  /// render (dry stems, wet stems, master reconstruction), same as [disarm]
  /// — a salvage render is free (D-RENDER reads only from the capture
  /// directory, never the live engine).
  Future<void> recoverCapture(String directory) =>
      _finalize(directory, armSnapshot: null, disarmSnapshot: null);

  /// Discards a crashed (unfinalized) capture at [directory] by deleting it
  /// outright — the counterpart to [recoverCapture] when the user chooses
  /// not to salvage it. A no-op if [directory] no longer exists.
  Future<void> discardUnfinalized(String directory) async {
    final dir = Directory(directory);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// Boot-time crash salvage, run silently (D-SALVAGE, #679): prunes the
  /// [recoveredDirName] area of entries older than [recoveredRetention],
  /// then salvages — finalize, stem render, move — every capture a crash
  /// left unfinalized, plus any bundle a previous boot finalized but never
  /// moved ([_strandedSalvage]), each finished bundle landing in
  /// `{exportsRoot}/`[recoveredDirName]`/<slug>/` — rendered, usable audio
  /// under the capture's own timestamped name. No prompt and no
  /// [captureStatus] emission: the only externally observable effects are
  /// the recovered bundles appearing on disk, and [arm]'s existing
  /// in-flight refusals (#671) holding for exactly as long as a salvage
  /// finalize or its render is running.
  ///
  /// Failure honesty: a salvage that could not finalize — a corrupt or
  /// missing sidecar, or a thrown write — leaves the raw bundle in place,
  /// untouched, to be retried at the next boot; what could not be rendered
  /// is never deleted. Retries are unbounded but cheap (the undecodable
  /// -sidecar case is [_finalize]'s documented early return), and the prune
  /// only ever touches bundles that DID recover, so a permanently
  /// unrecoverable bundle stays on disk for the user rather than aging out
  /// silently. A failed *stem render* on a finalized bundle still moves it —
  /// the bundle is complete and valid without its stems, the same
  /// partial-success posture [_finalize] itself takes. Each capture is
  /// salvaged under its own guard: one bundle's failure never aborts its
  /// siblings, and nothing escapes to the caller (the composition root runs
  /// this unawaited — a throw here would be an unhandled zone error).
  ///
  /// Never runs against a live capture: if an [arm] landed in one of the
  /// await gaps before a salvage takes its finalize guard (the exports-root
  /// lookups here and inside [findUnfinalized] both suspend), the armed
  /// session owns both the drain thread and the engine's single render slot
  /// — salvaging then would finalize/rename the live directory out from
  /// under the drain, and the salvage render would steal [renderProgress]
  /// from the take's own later disarm. Armed state is re-checked before
  /// every capture and again before each move; whatever is skipped waits
  /// for the next boot.
  Future<void> runBootRecovery() async {
    final String root;
    try {
      root = await _exportsRoot();
    } on Exception {
      return; // cannot resolve the root: nothing to recover this boot
    }
    _pruneRecovered(root);
    final List<UnfinalizedCapture> unfinalized;
    try {
      unfinalized = await findUnfinalized();
    } on Exception {
      return;
    }
    // Stranded bundles first (already finalized — the cheapest to finish),
    // then the crashed captures. Both go through the same per-capture
    // salvage, so a stranded bundle gets its stem render RE-attempted (the
    // render never survives the reboot that stranded it) rather than being
    // moved stemless.
    final pending = [
      ..._strandedSalvage(root),
      for (final capture in unfinalized) capture.directory,
    ];
    for (final dir in pending) {
      // Between-captures re-check, not just per-directory: a live arm owns
      // the one global render slot, so salvaging ANY capture while armed
      // would corrupt the take's own render/disarm flow, not only its
      // directory. Deferring the remainder to the next boot is the honest
      // outcome — recovery is a background nicety, the live take is not.
      if (_armedDir != null || _armInFlight) return;
      // A render still in flight — a prior capture's salvage timed out on
      // it — squats the engine's one global render slot: the next salvage's
      // renderBegin would be refused, its wait would watch the WRONG
      // render, and the bundle would land in the recovered area stemless
      // with its marker gone. Stop; the remainder waits for the next boot.
      if (!renderProgress.done) return;
      await _recoverSilently(root, dir);
    }
  }

  /// Whether [runBootRecovery] would have real salvage work this boot:
  /// captures a crash left unfinalized OR stranded finalized bundles still
  /// awaiting their move ([_strandedSalvage]). The app's boot probe reads
  /// this — not [findUnfinalized] alone — because a stranded-only boot
  /// re-attempts a stem render that holds [arm]'s gates just as long as a
  /// fresh salvage does, and a probe blind to it would leave the record
  /// button enabled-looking while every press is silently refused
  /// (#679 r4). `false` when the exports root cannot even be resolved,
  /// mirroring [runBootRecovery]'s own no-op on that boot.
  Future<bool> hasBootRecoveryWork() async {
    final String root;
    try {
      root = await _exportsRoot();
    } on Exception {
      return false;
    }
    if (_strandedSalvage(root).isNotEmpty) return true;
    return (await findUnfinalized()).isNotEmpty;
  }

  /// One capture's silent salvage: finalize + render in place, then — only
  /// once the sidecar proves finalized — move the bundle into the recovered
  /// area. The fire-and-forget stem render works on [dir]'s path on its own
  /// worker thread, so the move waits (bounded) for [renderProgress] to
  /// report done rather than renaming the directory out from under in-flight
  /// writes. The whole body is guarded: any failure keeps the bundle for the
  /// next boot's retry and lets the caller's loop continue to the next
  /// capture rather than escaping as an unhandled error.
  Future<void> _recoverSilently(String root, String dir) async {
    try {
      // Belt to the caller's armed bail: never, under any interleaving,
      // touch the directory the drain thread is writing.
      if (dir == _armedDir) return;
      // Dropped before the finalize, removed only after the move lands (in
      // [_moveToRecovered]): a crash or render timeout between those two
      // points strands a finalized bundle in the exports root, where it is
      // indistinguishable from a normal finished take by its sidecar alone —
      // the marker is what lets the next boot's [_strandedSalvage] finish
      // the move instead of the bundle falling outside retention forever.
      File('$dir/$recoveryMarkerName').writeAsStringSync('');
      if (_sidecarFinalized(dir)) {
        // A stranded bundle: its finalize already completed on a previous
        // boot, and re-running it would do real damage, not just waste work
        // — [_finalize] resolves the arm snapshot only from the
        // crash-survival file (deleted by that first finalize) and reads
        // only the native fields back, so a second pass would rewrite the
        // manifest with its armSnapshot (the chains/routing the export
        // depends on) stripped. Only the stem render is re-attempted — a
        // render never survives the reboot that stranded the bundle. Its
        // result is deliberately unchecked, [_finalize]'s own
        // partial-success posture: the bundle is complete without stems.
        _engine.renderBegin(dir);
      } else {
        await recoverCapture(dir);
      }
      var waited = Duration.zero;
      while (!renderProgress.done) {
        if (waited >= _bootRecoveryRenderTimeout) {
          // A wedged render must not park recovery forever. Keep the bundle
          // where it is — marker intact — so the next boot re-salvages it,
          // stem render and all; the caller's loop then stops on the very
          // render this wait gave up on (see the render-slot check there).
          return;
        }
        await Future<void>.delayed(_bootRecoveryPollInterval);
        waited += _bootRecoveryPollInterval;
      }
      if (!_sidecarFinalized(dir)) return; // nothing recovered; retried later
      // Re-checked at the last synchronous moment before the rename: the
      // awaits above suspended this salvage, and the one directory that must
      // never be renamed is the live capture's.
      if (_armedDir != null || _armInFlight) return;
      _moveToRecovered(root, dir);
    } on Exception {
      // One capture's failure neither aborts the loop for its siblings nor
      // escapes the unawaited boot call as an unhandled zone error. The
      // bundle (and its marker) stay for the next boot.
      return;
    }
  }

  /// Moves a finalized salvage bundle at [dir] under [recoveredDirName]
  /// (collision-suffixed, never overwriting a prior recovery) and removes
  /// its [recoveryMarkerName] — the marker's removal is what declares the
  /// salvage complete.
  ///
  /// Writes the [recoveredAtStampName] stamp on the SOURCE, before anything
  /// else in the move: the rename then carries provenance and retention
  /// clock atomically, so no crash window can land a bundle in the
  /// recovered area unstamped (where the prune would otherwise have only a
  /// stale finalize time to age it by — a bundle stranded through a month
  /// unpowered would be pruned on the very next boot). A failure anywhere
  /// mid-move merely leaves a stamp travelling with the bundle, which the
  /// next boot's retry overwrites with its own fresh landing time.
  void _moveToRecovered(String root, String dir) {
    File(
      '$dir/$recoveredAtStampName',
    ).writeAsStringSync(_now().millisecondsSinceEpoch.toString());
    final recoveredRoot = '$root/$recoveredDirName';
    Directory(recoveredRoot).createSync(recursive: true);
    final slug = _basename(dir);
    var target = '$recoveredRoot/$slug';
    var suffix = 1;
    while (Directory(target).existsSync()) {
      target = '$recoveredRoot/$slug-$suffix';
      suffix++;
    }
    Directory(dir).renameSync(target);
    final marker = File('$target/$recoveryMarkerName');
    if (marker.existsSync()) marker.deleteSync();
  }

  /// Bundles a previous boot finalized but never moved: still carrying
  /// [recoveryMarkerName] AND finalized means salvage output stranded
  /// between its finalize and its rename (a crash in that window, or a
  /// render timeout). [runBootRecovery] routes these through the same
  /// per-capture salvage as crashed captures, so their stem render — which
  /// never survives the reboot that stranded them — is re-attempted before
  /// the move. A marked bundle still *unfinalized* is left for the normal
  /// [findUnfinalized] path, and unmarked finalized bundles are the user's
  /// own finished takes, never touched. An unreadable root yields nothing —
  /// this boot skips the sweep rather than crashing it.
  List<String> _strandedSalvage(String root) {
    final out = <String>[];
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(root).listSync();
    } on FileSystemException {
      return out; // missing or unreadable root: nothing stranded to see
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      if (entity.path == _armedDir) continue; // never the live capture
      if (!File('${entity.path}/$recoveryMarkerName').existsSync()) continue;
      if (!_sidecarFinalized(entity.path)) continue;
      out.add(entity.path);
    }
    return out;
  }

  /// Deletes recovered-area entries older than [recoveredRetention], aged
  /// by — and ONLY by — the salvage's own [recoveredAtStampName] stamp.
  /// The stamp is provenance, not just shape: a finished take a user drags
  /// into the area by hand carries a sidecar but no stamp, so nothing the
  /// salvage didn't move in is ever the prune's to delete (belt to
  /// [performanceCaptureSlug]'s reserved-name refusal). Age is read from
  /// the stamp's contents, never a filesystem mtime — mtimes are rewritten
  /// by copies and moves, and were the fragility behind two review rounds
  /// here. A stamp before [pruneSanityFloor] is never acted on — see that
  /// constant for the RTC-less-boot clock hazard — and an unreadable stamp
  /// means no age worth guessing at. An entry the filesystem refuses is
  /// skipped — and an unreadable recovered area skips the prune whole — the
  /// next boot retries; a prune must never be the thing that takes boot
  /// recovery down.
  void _pruneRecovered(String root) {
    final recoveredRoot = Directory('$root/$recoveredDirName');
    if (!recoveredRoot.existsSync()) return;
    final List<FileSystemEntity> entries;
    try {
      entries = recoveredRoot.listSync();
    } on FileSystemException {
      return; // unreadable area: prune waits for a healthier boot
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      try {
        final stampFile = File('${entity.path}/$recoveredAtStampName');
        if (!stampFile.existsSync()) continue; // not ours: never delete
        final millis = int.tryParse(stampFile.readAsStringSync().trim());
        if (millis == null) continue; // unreadable stamp: no age to act on
        final recoveredAt = DateTime.fromMillisecondsSinceEpoch(millis);
        if (recoveredAt.isBefore(pruneSanityFloor)) continue;
        if (_now().difference(recoveredAt) > recoveredRetention) {
          entity.deleteSync(recursive: true);
        }
      } on FileSystemException {
        continue;
      }
    }
  }

  /// Whether [dir]'s sidecar provably reads back with `finalized: true` — a
  /// checked read: absent, unreadable, undecodable, or wrong-shaped all
  /// answer `false` rather than throwing (a sidecar written by a crashing
  /// process can be malformed in ways that raise [Error]s from the decode
  /// casts, not just [FormatException]). Shared by [findUnfinalized] and
  /// [runBootRecovery]'s move-only-what-recovered check.
  bool _sidecarFinalized(String dir) {
    try {
      final manifestFile = File('$dir/$manifestName');
      if (!manifestFile.existsSync()) return false;
      final json =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      return json['finalized'] == true;
    } on Object {
      return false;
    }
  }

  /// Folds [to] into a folder-safe slug and renames the finished capture at
  /// [directory] to it, returning the new directory path. Mirrors
  /// `SessionRepository.renameSession`'s never-overwrite contract — this
  /// package can't import that one, so the fold is a small, deliberately
  /// duplicated copy, not a shared dependency.
  ///
  /// Throws [ArgumentError] when [to] folds to nothing usable, and
  /// [PerformanceNameCollision] when the target slug already exists. Renaming
  /// to the same slug is a no-op that returns [directory] unchanged.
  Future<String> renameCapture(String directory, String to) async {
    final slug = performanceCaptureSlug(to);
    if (slug == null) {
      throw ArgumentError.value(to, 'to', 'not a valid capture name');
    }
    if (slug == _basename(directory)) return directory;
    final target = '${_dirname(directory)}/$slug';
    if (Directory(target).existsSync()) {
      throw PerformanceNameCollision(slug: slug);
    }
    Directory(directory).renameSync(target);
    return target;
  }

  String _dirname(String path) {
    final idx = path.lastIndexOf(RegExp(r'[/\\]'));
    return idx == -1 ? '.' : path.substring(0, idx);
  }

  Future<void> _finalize(
    String dir, {
    required PerformanceArmSnapshot? armSnapshot,
    required PerformanceDisarmSnapshot? disarmSnapshot,
  }) async {
    _finalizesInFlight++;
    try {
      final manifestFile = File('$dir/$manifestName');
      final String rawManifest;
      try {
        rawManifest = await manifestFile.readAsString();
      } on FileSystemException {
        return; // no sidecar was ever written (e.g. disarmed within the drain
        // thread's first ~250ms cycle): nothing to finalize
      }
      final Map<String, dynamic> native;
      try {
        native = PerformanceManifest.fromJson(
          jsonDecode(rawManifest) as Map<String, dynamic>,
        ).native;
      } on Object {
        // Corrupt OR wrong-shaped sidecar: a crashing writer can leave
        // well-formed JSON with wrong types, whose decode casts raise
        // [Error]s rather than [FormatException] — this parse is the one
        // step where catching everything is the honest contract (nothing
        // recoverable to finalize), instead of upgrading every outer guard.
        return;
      }
      final layout =
          native['channel_layout'] as Map<String, dynamic>? ?? const {};
      final sampleRate = (native['sample_rate'] as num?)?.toInt() ?? 0;
      final masterChannels = (layout['master_channels'] as num?)?.toInt() ?? 1;
      final capturedInputs = [
        for (final c
            in (layout['captured_inputs'] as List<dynamic>? ?? const []))
          (c as num).toInt(),
      ];

      final masterPcm = File('$dir/master.pcm');
      if (masterPcm.existsSync()) {
        final samples = _readRawPcm(masterPcm);
        await File('$dir/master.wav').writeAsBytes(
          WavCodec.encodeFloat32(
            samples: samples,
            sampleRate: sampleRate,
            channels: masterChannels,
          ),
        );
      }
      for (final input in capturedInputs) {
        final raw = File('$dir/input-$input.pcm');
        if (!raw.existsSync()) continue;
        final samples = _readRawPcm(raw);
        await File('$dir/live-input-$input.wav').writeAsBytes(
          WavCodec.encodeFloat32(
            samples: samples,
            sampleRate: sampleRate,
            channels: 2,
          ),
        );
      }

      var resolvedArm = armSnapshot;
      final armFile = File('$dir/$_armSnapshotFileName');
      if (resolvedArm == null && armFile.existsSync()) {
        resolvedArm = PerformanceArmSnapshot.fromJson(
          jsonDecode(await armFile.readAsString()) as Map<String, dynamic>,
        );
      }

      final manifest = PerformanceManifest(
        slug: _basename(dir),
        finalized: true,
        native: native,
        armSnapshot: resolvedArm,
        disarmSnapshot: disarmSnapshot,
      );
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      );
      if (armFile.existsSync()) armFile.deleteSync();

      // Kick off the offline render (dry stems, wet stems, master
      // reconstruction — parts 7-8, one render session covers all three):
      // fire-and-forget — the worker thread reads only from `dir` on disk from
      // here on, with no further dependency on this finalize call, so its
      // outcome is exposed purely via the poll-on-demand
      // `renderProgress`/`renderTrackStatuses` getters above rather than
      // awaited here. A failure to even START a
      // render (e.g. one is already running) is silently accepted — the
      // bundle itself is already complete and valid without its stems, which
      // is exactly the umbrella's partial-success posture applied one level up.
      _engine.renderBegin(dir);
    } finally {
      // Decremented only after renderBegin: the render poll takes over
      // [arm]'s refusal from here with no uncovered gap between the two.
      _finalizesInFlight--;
    }
  }

  /// Exports every currently-settled lane's PCM as a WAV directly into
  /// `<dir>/loops/`, and returns one [PerformanceTrackSnapshot] per non-empty
  /// track. A track currently capturing (recording/overdubbing) contributes
  /// `deferred: true` lane entries instead of exporting (D-SNAP) — its buffer
  /// is being written by the audio thread and exporting it would tear.
  List<PerformanceTrackSnapshot> _captureSettledLanes(
    String dir, {
    required PerformanceChains chains,
    required bool writeChains,
  }) {
    final snapshot = _engine.snapshot();
    final tracks = <PerformanceTrackSnapshot>[];
    for (var channel = 0; channel < snapshot.tracks.length; channel++) {
      final track = snapshot.tracks[channel];
      final capturing =
          track.state == TrackState.recording ||
          track.state == TrackState.overdubbing;
      final lanes = <PerformanceLaneSnapshot>[];
      for (var laneIndex = 0; laneIndex < track.lanes.length; laneIndex++) {
        if (capturing) {
          lanes.add(
            PerformanceLaneSnapshot(
              lane: laneIndex,
              lengthFrames: 0,
              deferred: true,
            ),
          );
          continue;
        }
        final lane = track.lanes[laneIndex];
        if (lane.lengthFrames <= 0) continue;
        final pcm = _engine.exportTrackLane(channel, laneIndex);
        if (pcm.isEmpty) continue;

        final filename = 'loops/track$channel-lane$laneIndex.wav';
        final wavFile = File('$dir/$filename');
        wavFile.parent.createSync(recursive: true);
        wavFile.writeAsBytesSync(
          WavCodec.encodeFloat32(
            samples: pcm,
            sampleRate: snapshot.sampleRate,
            channels: 1,
          ),
        );
        final laneChain = writeChains
            ? _laneChain(chains, channel, laneIndex)
            : null;
        lanes.add(
          PerformanceLaneSnapshot(
            lane: laneIndex,
            lengthFrames: pcm.length,
            deferred: false,
            pcmFile: filename,
            effects: laneChain?.effects ?? const [],
            chainEnabled: laneChain?.chainEnabled ?? true,
          ),
        );
      }
      if (lanes.isEmpty) continue;
      tracks.add(
        PerformanceTrackSnapshot(
          channel: channel,
          state: track.state,
          volume: track.volume,
          muted: track.muted,
          multiple: track.multiple,
          lanes: lanes,
        ),
      );
    }
    return tracks;
  }

  /// Lane [lane] of [channel]'s chain among [chains], or `null` when the rig
  /// defines none there (an all-default lane: dry and engaged).
  PerformanceLaneChain? _laneChain(
    PerformanceChains chains,
    int channel,
    int lane,
  ) {
    for (final c in chains.laneChains) {
      if (c.channel == channel && c.lane == lane) return c;
    }
    return null;
  }

  List<Map<String, dynamic>> _monitorsJson(PerformanceChains chains) => [
    for (final m in chains.monitors)
      {
        'input': m.input,
        'enabled': m.enabled,
        'outputMask': m.outputMask,
        'volume': m.volume,
        'muted': m.muted,
        // Omitted while engaged, like every other chain flag in the manifest.
        if (!m.chainEnabled) 'chainEnabled': false,
        'effects': [for (final e in m.effects) e.toJson()],
      },
  ];

  Float32List _readRawPcm(File file) {
    final bytes = file.readAsBytesSync();
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 4,
    );
  }

  String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Releases the status stream. Does not disarm — callers that own the
  /// engine lifecycle are responsible for disarming before disposal.
  void dispose() {
    unawaited(_statusController.close());
  }
}
