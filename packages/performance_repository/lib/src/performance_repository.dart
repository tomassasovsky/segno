import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/src/models/capture_summary.dart';
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
    required GuardRegistry guards,
    DateTime Function() now = DateTime.now,
    Duration bootRecoveryPollInterval = const Duration(milliseconds: 200),
    Duration bootRecoveryRenderTimeout = defaultBootRecoveryRenderTimeout,
    int? reserveBytes,
  }) : _engine = engine,
       _guards = guards,
       _exportsRoot = exportsRoot,
       _reserveBytes = reserveBytes,
       _now = now,
       _bootRecoveryPollInterval = bootRecoveryPollInterval,
       _bootRecoveryRenderTimeout = bootRecoveryRenderTimeout;

  final AudioEngine _engine;
  final Future<String> Function() _exportsRoot;
  final DateTime Function() _now;
  final Duration _bootRecoveryPollInterval;
  final Duration _bootRecoveryRenderTimeout;

  /// The app's one guard table (accepted behaviour 6.12). A take holds a
  /// `capture` guard from the commit of [arm] until it is finalized or its
  /// failed arm is cancelled, so a device change, a calibration, a session
  /// apply or a shutdown sees it at their own commits, and [arm] itself is
  /// refused while one of them is in flight.
  final GuardRegistry _guards;
  OperationGuard? _captureGuard;

  final StreamController<GuardRefused> _armRefusals =
      StreamController<GuardRefused>.broadcast();

  /// Every [arm] the guard table refused, with what refused it. [arm] keeps
  /// its silent-ok contract (the pedal calls it with nothing in front of
  /// it), so this is where the reason goes; the recorder cubit listens.
  Stream<GuardRefused> get armRefusals => _armRefusals.stream;

  /// What the Storage page and the recorder name a take by.
  static const String capturePurpose = 'recording';

  /// Bytes every take leaves free on the exports volume (#1198): the engine
  /// stops a take at the last whole frame above it. Null means no budget, so
  /// a take stops only when a write fails. The app passes Internal's storage
  /// reserve.
  final int? _reserveBytes;

  /// The shortest take [minimumFreeBytesToArm] must leave room for.
  static const Duration minimumTake = Duration(seconds: 10);

  /// Free bytes the exports volume needs before a take may start: the
  /// reserve, the engine's allowance, and [minimumTake] of every stream the
  /// arm would capture (the master and each monitored input, as the engine
  /// reports them) at the current sample rate, with one part header each.
  /// Arming below this would start a take the reserve stops at once. When
  /// the engine reports nothing to capture, a stereo master is assumed.
  int get minimumFreeBytesToArm => minimumFreeBytesToArmAt();

  /// [minimumFreeBytesToArm] for a take armed under [root] (see [arm]): a
  /// take on a removable volume keeps no reserve (#1177), so only the
  /// allowance and [minimumTake] count there.
  int minimumFreeBytesToArmAt({String? root}) {
    final reserve = root == null ? (_reserveBytes ?? 0) : 0;
    final snapshot = _engine.snapshot();
    final rate = snapshot.sampleRate > 0 ? snapshot.sampleRate : 48000;
    final streams = snapshot.perfCaptureStreams > 0
        ? snapshot.perfCaptureStreams
        : 1;
    final frameBytes = snapshot.perfCaptureFrameBytes > 0
        ? snapshot.perfCaptureFrameBytes
        : 2 * 4;
    return reserve +
        PerfTarget.allowanceBytes +
        streams * PerfTarget.partHeaderBytes +
        rate * minimumTake.inSeconds * frameBytes;
  }

  /// Called with the hidden directory a delete is about to remove, so a
  /// test can see that the take left the listing before any file went.
  @visibleForTesting
  static void Function(String doomed)? debugBeforeDeleting;

  /// What a guard refusal names a recording's delete by.
  static const String deletePurpose = 'deleting a recording';

  /// The suffix a take's directory takes while [deleteCapture] removes it:
  /// a hidden sibling the listing skips and the next boot finishes.
  static const String deletingSuffix = '.deleting';

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
  Completer<void>? _armFinished;

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
  /// area, adopted by future salvages.
  static const String recoveredDirName = reservedRecoveredDirName;

  /// The largest raw `.pcm` file of a pre-#1198 capture that finalize still
  /// converts by reading it whole, as it always did. Reading costs the file
  /// once and the WAV it becomes once more, so this stays well inside the
  /// appliance's memory: the 6 GB and 36 GB takes found on one ran it out
  /// (#1198). A capture with a larger file stays unfinalized, in place, its
  /// files untouched, for Part 8's streaming conversion, and is reported in
  /// [unrecoveredTakes].
  static const int legacyConvertMaxBytes = 512 * 1024 * 1024;

  /// Captures the last [runBootRecovery] tried and could not finalize (a
  /// raw take too large to convert yet, a damaged sidecar, a failed write).
  /// Each stays where it is with every file kept; the app tells the player
  /// it could not be recovered.
  List<String> get unrecoveredTakes => List.unmodifiable(_unrecovered);
  final List<String> _unrecovered = [];

  /// The provenance stamp inside every recovered bundle: epoch
  /// milliseconds as text, written on the SOURCE bundle immediately before
  /// the move's rename so the rename carries it atomically — a bundle can
  /// never exist in the recovered area without its stamp, and a crash before
  /// the rename just re-stamps on that boot's retry. It records when the
  /// salvage moved the bundle in. Nothing ages or deletes a recovered
  /// bundle: recovered audio is kept until the user removes it (owner
  /// decision, #1198).
  static const String recoveredAtStampName = '.recovered-at';

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

  /// Total and free bytes of the volume holding [path], or `null` when the
  /// platform cannot answer.
  ///
  /// A capture re-checks the volume it is filling, and used to do it by running
  /// `df` — which forks the whole app, twelve times a minute, for the length
  /// of a take. On the appliance that is milliseconds of `mmap_lock` held for
  /// write while a 1.7 GB address space's page tables are copied, with the
  /// real-time audio thread asleep behind it (#806). The engine answers the
  /// same question with a `statvfs` and no child process. The Storage page
  /// reads Internal capacity through this same call (#1177).
  VolumeSpace? volumeSpace(String path) => _engine.volumeSpace(path);

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
  ({
    Duration elapsed,
    bool overrun,
    bool selfStopped,
    PerfStopReason stopReason,
  })
  get captureProgress {
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
      // Why it stopped (#1198): a failed write, the reserve, or the storage
      // falling behind. Set before the engine publishes the stop.
      stopReason: snapshot.perfStopReason,
    );
  }

  void _setStatus(PerformanceCaptureStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Sets the capture policy the next [arm] freezes for its take (accepted
  /// design, Performance recording): `false` (the default) leaves the final
  /// output volume and mute out of the take; `true` (Follow output volume)
  /// applies the selected destination's level and mute. Mono, Balance,
  /// hardware master gain and limiter remain outside either capture. A
  /// running take keeps the policy it was armed with.
  EngineResult setFollowOutput({required bool follow}) =>
      _engine.setPerfFollowOutput(follow: follow);

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
  ///
  /// [root] puts this take's bundle under another directory than the
  /// constructor's `exportsRoot` (a USB volume's `Segno/Performances`, #1177);
  /// [armedDirectory] stays the truth of where it went. [scope] is where the
  /// take's `capture` guard is held, so the guard table can refuse an eject
  /// or a copy on that volume while it records: a removable [root] must come
  /// with that volume's scope.
  Future<EngineResult> arm({
    PerformanceChains chains = const PerformanceChains(),
    String? root,
    GuardScope scope = const GuardScope.internal(),
  }) async {
    if (_armedDir != null || _armInFlight) return EngineResult.ok;
    if (_finalizesInFlight > 0 || !renderProgress.done) return EngineResult.ok;
    _armInFlight = true;
    final finished = Completer<void>();
    _armFinished = finished;
    try {
      return await _armGated(chains, root: root, scope: scope);
    } finally {
      _armInFlight = false;
      _armFinished = null;
      finished.complete();
    }
  }

  /// The body of [arm] past its entry gate; runs with [_armInFlight] held.
  Future<EngineResult> _armGated(
    PerformanceChains chains, {
    required String? root,
    required GuardScope scope,
  }) async {
    final under = root ?? await _exportsRoot();
    final base = performanceSlug(_now());
    var slug = base;
    var dir = '$under/$slug';
    var suffix = 1;
    while (Directory(dir).existsSync()) {
      slug = '$base-$suffix';
      dir = '$under/$slug';
      suffix++;
    }
    await Directory(dir).create(recursive: true);

    final snapshot = _engine.snapshot();
    final tracks = _captureSettledLanes(dir, chains: chains, writeChains: true);
    final armSnapshot = PerformanceArmSnapshot(
      // The master loop phase at arm is no longer recorded here: it was
      // sampled on the control thread BEFORE lane export and manifest I/O, an
      // unbounded gap before the capture's frame 0, so it was race-stale
      // (#262). The renderer reads the exact phase from events.log's
      // LE_PLOG_PERF_ARMED fact instead, and nothing else consumed it.
      masterGain: snapshot.masterGain,
      limiterEnabled: chains.limiterEnabled,
      limiterCeiling: chains.limiterCeiling,
      latencyOffsetFrames: snapshot.recordOffsetFrames,
      // The capture policy (slice 3b) the engine freezes for this take. The
      // destination it captures and that destination's facts are filled in
      // after the arm below, from the engine's own frozen choice.
      followOutput: snapshot.perfFollowOutput,
      // The engine tempo at the arm instant, verbatim (0 = unset, matching
      // the session manifest's own sentinel). The crash-salvage fallback
      // only — the disarm snapshot re-reads it authoritatively, because
      // D6's tempo lock may not even have engaged yet this early (#281).
      tempoBpm: snapshot.tempoBpm,
      tracks: tracks,
      monitors: _monitorsJson(chains),
      // The bus stages (FX v3, R20/R3): recorded so a replay can rebuild the
      // whole four-stage rig, bypass state included.
      trackChains: chains.trackChains,
      outputChains: chains.outputChains,
    );
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

    // The commit point (accepted behaviour 6.12): the guard is taken here,
    // after every await of this arm, never when a control was pressed.
    try {
      _captureGuard = _guards.enter(
        GuardKind.capture,
        scope,
        purpose: capturePurpose,
      );
    } on GuardRefused catch (refusal) {
      final created = Directory(dir);
      if (created.existsSync()) created.deleteSync(recursive: true);
      _armRefusals.add(refusal);
      return EngineResult.ok;
    }

    // The take's identity (#1198): random, minted before any audio exists,
    // and written into every part's `sgno` chunk by the drain.
    final random = Random.secure();
    final takeId = Uint8List.fromList([
      for (var i = 0; i < PerfTarget.takeIdBytes; i++) random.nextInt(256),
    ]);
    // The reserve is Internal's (#1198); a removable volume keeps none
    // (#1177), so a take there stops only when its writes fail.
    final result = _engine.perfArm(
      PerfTarget(
        captureDir: dir,
        takeId: takeId,
        reserveBytes: root == null ? _reserveBytes : null,
      ),
    );
    if (!result.isOk) {
      _releaseCaptureGuard();
      final created = Directory(dir);
      if (created.existsSync()) created.deleteSync(recursive: true);
      return result;
    }

    // perfArm queues the callback command. Claim its directory immediately:
    // the callback may begin draining before this future observes its frozen
    // facts, and a later I/O error must never leave that live capture hidden
    // behind an idle repository. The native disarm contract also cancels a
    // pending arm; a failed disarm retains ownership for retry.
    _armedDir = dir;
    try {
      final armWait = Stopwatch()..start();
      var armed = _engine.snapshot();
      while (!armed.isPerfArmed &&
          armWait.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        armed = _engine.snapshot();
      }
      if (!armed.isPerfArmed || armed.perfCaptureMask == 0) {
        return _cancelFailedArm(EngineResult.device);
      }

      // The captured destination and its facts, read AFTER the arm: the
      // engine picks the destination inside le_perf_arm from the output gate
      // as it stands then, and the lane export above ran before that. This
      // gap also made the old `clockFrame` anchor race-stale (#262). Taking
      // the destination from the pre-arm
      // snapshot would let the manifest name one destination while the take
      // captured another, and the offline render replays the level rides of
      // whichever the manifest names.
      final captureBus = armed.perfCaptureBus;
      if (captureBus < 0) {
        return _cancelFailedArm(EngineResult.device);
      }
      final outputChain = _engine.outputFxSnapshot(bus: captureBus);
      if (outputChain.effects.any(
        (effect) =>
            effect.type != 0 &&
            TrackEffectType.fromCode(effect.type) == TrackEffectType.none,
      )) {
        return _cancelFailedArm(EngineResult.invalid);
      }
      final finalArm = armSnapshot.withCapture(
        followOutput: armed.perfFollowOutput,
        captureBus: captureBus,
        captureMask: armed.perfCaptureMask,
        outputEnabledMask: armed.perfOutputEnabledMask,
        outputLevel: armed.perfOutputLevel,
        outputMuted: armed.perfOutputMuted,
        outputEffects: [
          for (final effect in outputChain.effects)
            BuiltInEffect(
              type: TrackEffectType.fromCode(effect.type),
              params: effect.params,
              enabled: effect.enabled,
            ),
        ],
        outputChainEnabled: outputChain.chainEnabled,
      );
      _armSnapshot = finalArm;
      // A pre-arm snapshot cannot truthfully name the callback-selected output
      // or policy. Write only the settled facts, then atomically publish them;
      // a crash or failed write leaves no misleading salvage snapshot. Keep
      // live ownership and the in-memory snapshot if publication fails, so a
      // later disarm can still stop and finalize this take.
      final pending = File('$dir/$_armSnapshotFileName.pending');
      try {
        await pending.writeAsString(jsonEncode(finalArm.toJson()), flush: true);
        await pending.rename('$dir/$_armSnapshotFileName');
      } on Object {
        try {
          if (pending.existsSync()) pending.deleteSync();
        } on FileSystemException {
          // The volume may still be unavailable; the pending file is ignored
          // by salvage, and the live capture remains owned above.
        }
        // The capture remains live and owned even though publication failed;
        // expose it now, with no gesture guard on the stop retry.
        _armedAt = null;
        _setStatus(PerformanceCaptureStatus.armed);
        rethrow;
      }
      _armedAt = _now();
      _setStatus(PerformanceCaptureStatus.armed);
      return EngineResult.ok;
    } catch (_) {
      // Snapshot/getter failures before the armed state is published still
      // have a live native owner. Stop it through the same pending-safe
      // contract; if that fails, expose ownership for a later disarm retry.
      // Once armed was published, a failed atomic file write keeps the
      // in-memory final snapshot and capture for disarm/finalize instead.
      if (_armedDir == dir && _status != PerformanceCaptureStatus.armed) {
        _cancelFailedArm(EngineResult.device);
      } else if (_armedDir == dir) {
        // This was an arm failure, not a second user tap. An immediate
        // disarm must be allowed through the gesture guard to stop it.
        _armedAt = null;
      }
      rethrow;
    }
  }

  EngineResult _cancelFailedArm(EngineResult reason) {
    EngineResult stopped;
    try {
      stopped = _engine.perfDisarm();
    } catch (_) {
      _armedAt = null;
      _setStatus(PerformanceCaptureStatus.armed);
      rethrow;
    }
    if (stopped.isOk) {
      _armedDir = null;
      _armSnapshot = null;
      _armedAt = null;
      _releaseCaptureGuard();
      if (_status != PerformanceCaptureStatus.idle) {
        _setStatus(PerformanceCaptureStatus.idle);
      }
    } else {
      _armedAt = null;
      _setStatus(PerformanceCaptureStatus.armed);
    }
    return reason;
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
    await _armFinished?.future;
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
    await _armFinished?.future;
    final dir = _armedDir;
    if (dir == null) return EngineResult.ok;
    return _finalizeArmed(dir);
  }

  Future<EngineResult> _finalizeArmed(String dir) async {
    _setStatus(PerformanceCaptureStatus.finalizing);
    final disarmSnapshot = PerformanceDisarmSnapshot(
      // Re-read here, not copied from the arm snapshot: D6's tempo lock
      // only engages once grid content exists, so a tempo dialed in — or
      // derived by the first loop — after an arm-over-empty-grid is only
      // knowable now. This is the authoritative tempo a DAW export stamps;
      // the arm-time copy serves crash salvage, which never gets this pass
      // (#281). Read before perfDisarm below, while the engine is still the
      // live session's.
      tempoBpm: _engine.snapshot().tempoBpm,
      tracks: _captureSettledLanes(
        dir,
        chains: const PerformanceChains(),
        writeChains: false,
        stampTakeId: true,
      ),
    );

    final result = _engine.perfDisarm();
    if (!result.isOk) {
      _setStatus(PerformanceCaptureStatus.armed);
      return result;
    }
    // Nothing is capturing from here on: the finalize below is file work
    // that _finalizesInFlight fences. On Internal the guard goes now. A take
    // on a USB drive keeps it through the finalize, which writes its WAVs to
    // that drive for as long as the take ran: a restart or an eject let in
    // meanwhile would cut them (#1177). Either way it is released in a
    // finally, so a finalize that throws leaves nothing refused behind it.
    if (_captureGuard?.operation.scope.generation == null) {
      _releaseCaptureGuard();
    }
    try {
      await _finalize(
        dir,
        armSnapshot: _armSnapshot,
        disarmSnapshot: disarmSnapshot,
      );
    } finally {
      _releaseCaptureGuard();
    }

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

  /// Boot-time crash salvage, run silently (D-SALVAGE, #679): salvages —
  /// finalize, stem render, move — every capture a crash
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
  /// -sidecar case is [_finalize]'s documented early return). Nothing here
  /// deletes audio: a permanently unrecoverable bundle stays on disk for the
  /// user, and a recovered one stays in [recoveredDirName] until the user
  /// removes it. A failed *stem render* on a finalized bundle still moves it —
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
    _unrecovered.clear();
    final String root;
    try {
      root = await _exportsRoot();
    } on Exception {
      return; // cannot resolve the root: nothing to recover this boot
    }
    _finishDeletes(root);
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
      // Still in place and still unfinalized: this boot could not recover
      // it. Its files stay; the player is told.
      if (Directory(dir).existsSync() && !_sidecarFinalized(dir)) {
        _unrecovered.add(dir);
      }
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
  /// else in the move: the rename then carries it atomically, so no crash
  /// window can land a bundle in the recovered area unstamped. A failure
  /// anywhere mid-move merely leaves a stamp travelling with the bundle,
  /// which the next boot's retry overwrites with its own fresh landing
  /// time.
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

  /// The DAW project files a bundle carries once written: the Ableton Live
  /// Set and the plain-text effect chains it is read with.
  static const List<String> dawProjectFiles = ['project.als', 'fx-chains.txt'];

  /// Every finished recording, newest first (#1178 Part 7): the takes in the
  /// exports root and the ones boot recovery salvaged under
  /// [recoveredDirName], which are kept and listed with
  /// [CaptureSummary.recovered] set (owner decision: no automatic delete
  /// from the Library's point of view).
  ///
  /// Left out: the take being recorded, any bundle whose sidecar is not
  /// finalized (a crash the boot salvage has not finished), and any bundle
  /// still carrying [recoveryMarkerName] (salvage output that has not moved
  /// yet). An unreadable sidecar leaves its bundle out; a missing root lists
  /// nothing.
  Future<List<CaptureSummary>> listCaptures() async {
    final root = await _exportsRoot();
    final out = <CaptureSummary>[
      ..._capturesIn(root, recovered: false),
      ..._capturesIn('$root/$recoveredDirName', recovered: true),
    ];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    out.sort((a, b) {
      final byTime = (b.startedAt ?? epoch).compareTo(a.startedAt ?? epoch);
      return byTime != 0 ? byTime : a.name.compareTo(b.name);
    });
    return out;
  }

  List<CaptureSummary> _capturesIn(String dir, {required bool recovered}) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync();
    } on FileSystemException {
      return const [];
    }
    return [
      for (final entity in entries)
        // The take being recorded is never finalized, so it is left out
        // with the crashed ones.
        if (entity is Directory &&
            !_basename(entity.path).startsWith('.') &&
            (recovered || _basename(entity.path) != recoveredDirName) &&
            !File('${entity.path}/$recoveryMarkerName').existsSync())
          ?_readCapture(entity.path, recovered: recovered),
    ];
  }

  CaptureSummary? _readCapture(String dir, {required bool recovered}) {
    final PerformanceManifest manifest;
    try {
      manifest = PerformanceManifest.fromJson(
        jsonDecode(File('$dir/$manifestName').readAsStringSync())
            as Map<String, dynamic>,
      );
    } on Object {
      return null;
    }
    if (!manifest.finalized) return null;
    final parts = _partsOf(dir, manifest);
    final listed = [
      for (final part in parts)
        if (part.isMaster) part.frames,
    ];
    return CaptureSummary(
      path: dir,
      name: _basename(dir),
      startedAt: performanceSlugTime(manifest.slug),
      durationFrames: listed.isEmpty
          ? manifest.captureFrames
          : listed.reduce((a, b) => a + b),
      sampleRate: manifest.sampleRate,
      recovered: recovered,
      hasDawProject: File('$dir/${dawProjectFiles.first}').existsSync(),
      parts: parts,
    );
  }

  /// The take's audio parts in order: the sidecar's `parts` list (#1198's
  /// format) when it has one, or the single-file `master.wav` and
  /// `live-input-<n>.wav` of a take written before it. A `parts` list that
  /// does not read is read as no parts: the take is listed without audio
  /// rather than with a guess at it.
  List<CapturePart> _partsOf(String dir, PerformanceManifest manifest) {
    final listed = manifest.native['parts'];
    if (listed is List<dynamic>) {
      try {
        final parts =
            [
              for (final entry in listed)
                CapturePart.fromJson(entry as Map<String, dynamic>),
            ]..sort(
              (a, b) => a.stream != b.stream
                  ? a.stream.compareTo(b.stream)
                  : a.index.compareTo(b.index),
            );
        return parts;
      } on Object {
        return const [];
      }
    }
    final layout =
        manifest.native['channel_layout'] as Map<String, dynamic>? ?? const {};
    final inputs = [
      for (final c in (layout['captured_inputs'] as List<dynamic>? ?? const []))
        if (c is num) c.toInt(),
    ]..sort();
    return [
      ?_legacyPart(dir, 'master.wav', 0, manifest.captureFrames),
      for (final input in inputs)
        ?_legacyPart(
          dir,
          'live-input-$input.wav',
          1 + input,
          manifest.captureFrames,
        ),
    ];
  }

  CapturePart? _legacyPart(String dir, String file, int stream, int frames) {
    final f = File('$dir/$file');
    if (!f.existsSync()) return null;
    return CapturePart(
      stream: stream,
      index: 1,
      file: file,
      frames: frames,
      bytes: f.lengthSync(),
    );
  }

  /// The files of [capture]'s DAW package, relative to its directory, that
  /// exist on disk: every audio part in order, the rendered stems the Live
  /// Set points at (`stems/dry/`, `stems/wet/`), then the [dawProjectFiles].
  /// The Library copies them keeping these paths, so the Live Set opens on
  /// the drive.
  List<String> dawPackageFiles(CaptureSummary capture) {
    final dir = capture.path;
    final stems = <String>[];
    for (final kind in const ['dry', 'wet']) {
      final List<FileSystemEntity> entries;
      try {
        entries = Directory('$dir/stems/$kind').listSync();
      } on FileSystemException {
        continue;
      }
      stems.addAll(
        [
          for (final e in entries)
            if (e is File && e.path.toLowerCase().endsWith('.wav'))
              'stems/$kind/${_basename(e.path)}',
        ]..sort(),
      );
    }
    return [
      for (final part in capture.parts)
        if (File('$dir/${part.file}').existsSync()) part.file,
      ...stems,
      for (final file in dawProjectFiles)
        if (File('$dir/$file').existsSync()) file,
    ];
  }

  /// Deletes the finished recording [capture] from internal storage (the
  /// Library's confirmed Delete, #1178 Part 7).
  ///
  /// Refused with [PerformanceCaptureBusy] while a take is being recorded,
  /// finalized or rendered, since any of them may be writing into a bundle,
  /// and with [GuardRefused] when the guard table forbids a bundle write
  /// (a shutdown in flight). Refuses a path that is not a finished take
  /// in the exports root or its recovered area with [ArgumentError].
  Future<void> deleteCapture(CaptureSummary capture) async {
    final root = await _exportsRoot();
    final dir = capture.path;
    final parent = _dirname(dir);
    if ((parent != root && parent != '$root/$recoveredDirName') ||
        _basename(dir) == recoveredDirName ||
        !_sidecarFinalized(dir)) {
      throw ArgumentError.value(dir, 'capture', 'not a finished take');
    }
    if (_armedDir != null ||
        _armInFlight ||
        _finalizesInFlight > 0 ||
        !renderProgress.done) {
      throw const PerformanceCaptureBusy();
    }
    final guard = _guards.enter(
      GuardKind.sessionWrite,
      GuardScope.internal(item: dir),
      purpose: deletePurpose,
    );
    try {
      // One rename takes the whole take out of the listing at once (atomic
      // on the internal ext4); the recursive delete then works on a hidden
      // directory, and the next boot finishes one a cut left behind.
      final doomed = '${_dirname(dir)}/.${_basename(dir)}$deletingSuffix';
      if (Directory(doomed).existsSync()) {
        Directory(doomed).deleteSync(recursive: true);
      }
      Directory(dir).renameSync(doomed);
      debugBeforeDeleting?.call(doomed);
      try {
        Directory(doomed).deleteSync(recursive: true);
      } on FileSystemException {
        // Hidden already; the next boot removes the rest.
      }
    } finally {
      guard.release();
    }
  }

  /// Removes the takes a delete hid but could not finish ([deletingSuffix]),
  /// in the exports root and the recovered area.
  void _finishDeletes(String root) {
    for (final dir in [root, '$root/$recoveredDirName']) {
      final List<FileSystemEntity> entries;
      try {
        entries = Directory(dir).listSync();
      } on FileSystemException {
        continue;
      }
      for (final e in entries) {
        final name = _basename(e.path);
        if (e is Directory &&
            name.startsWith('.') &&
            name.endsWith(deletingSuffix)) {
          try {
            e.deleteSync(recursive: true);
          } on FileSystemException {
            continue;
          }
        }
      }
    }
  }

  /// Plays [capture]'s first main-output part on the engine's audition voice
  /// (the Library's `Preview`), decoded by the engine's one decoder off the
  /// UI isolate. A take with no main-output part is refused with
  /// [EngineResult.invalid] before the engine.
  ///
  /// [stillWanted] is handed to the engine: a start the caller withdrew
  /// while it decoded never reaches the voice ([AuditionStart.cancelled]).
  Future<AuditionStart> startAudition(
    CaptureSummary capture, {
    bool Function()? stillWanted,
  }) async {
    final first = capture.masterParts.firstOrNull;
    final path = first == null ? null : '${capture.path}/${first.file}';
    if (path == null || !File(path).existsSync()) {
      return const AuditionStart(result: EngineResult.invalid);
    }
    return _engine.auditionStartFile(path, stillWanted: stillWanted);
  }

  /// Whether a take's stems may still be being written: the engine's one
  /// render slot is busy, and the render writes `stems/` in place. The DAW
  /// project and the DAW package wait for it (#1178 Part 7 review,
  /// finding 4); the take's own parts are final and may go.
  bool get rendering => !renderProgress.done;

  /// [buckets] absolute peaks over [capture]'s main output, streamed off the
  /// UI isolate through the engine's one decoder, the parts concatenated in
  /// proportion to their lengths; null when no part reads.
  Future<Float32List?> readPeaks(
    CaptureSummary capture, {
    int buckets = 256,
  }) async {
    final parts = capture.masterParts;
    final total = parts.fold<int>(0, (sum, p) => sum + p.frames);
    if (parts.isEmpty || total <= 0) return null;
    final out = Float32List(buckets);
    var filled = 0;
    var framesBefore = 0;
    for (final part in parts) {
      framesBefore += part.frames;
      final end = part == parts.last
          ? buckets
          : (framesBefore * buckets / total).round();
      final share = end - filled;
      if (share <= 0) continue;
      final path = '${capture.path}/${part.file}';
      final peaks = File(path).existsSync()
          ? await _engine.filePeaks(path, buckets: share)
          : null;
      if (peaks == null) return null;
      out.setRange(filled, end, peaks);
      filled = end;
    }
    return out;
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
      final capturedInputs = [
        for (final c
            in (layout['captured_inputs'] as List<dynamic>? ?? const []))
          (c as num).toInt(),
      ];
      final legacy = [
        File('$dir/master.pcm'),
        for (final input in capturedInputs) File('$dir/input-$input.pcm'),
      ].where((f) => f.existsSync()).toList();
      if (legacy.isNotEmpty && !File('$dir/master-001.wav').existsSync()) {
        // A capture from before #1198: raw PCM, no parts. Converted exactly
        // as before, so an existing install's takes keep their audio. A raw
        // file too large to read whole is left unfinalized, in place, for
        // Part 8's bounded conversion; it is never finalized without audio.
        if (legacy.any((f) => f.lengthSync() > legacyConvertMaxBytes)) return;
        await _convertLegacyPcm(dir, native, capturedInputs);
      } else {
        // The drain writes each stream as finished float WAV parts, so there
        // is nothing to convert. A crash leaves the open part's sizes
        // unpatched; seal it here so a salvaged take still plays (#1198).
        // Part 8 replaces this with the checkpoint-based recovery.
        _sealOpenParts(dir);
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
  /// `<dir>/loops/`, and returns metadata for every active lane at arm, including empty
  /// tracks that can be restored during capture. A track currently capturing (recording/overdubbing) contributes
  /// `deferred: true` lane entries instead of exporting (D-SNAP) — its buffer
  /// is being written by the audio thread and exporting it would tear.
  /// [stampTakeId] writes each track's settled take id onto its lane-0 entry
  /// as `takeId` (#819). Only the DISARM pass sets it: the offline renderer
  /// consumes `takeId` solely from `disarmSnapshot.tracks`, so an arm-time
  /// manifest stays byte-identical to a build without take ids.
  List<PerformanceTrackSnapshot> _captureSettledLanes(
    String dir, {
    required PerformanceChains chains,
    required bool writeChains,
    bool stampTakeId = false,
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
        final lane = track.lanes[laneIndex];
        final laneChain = writeChains
            ? _laneChain(chains, channel, laneIndex)
            : null;
        if (capturing || (writeChains && lane.lengthFrames <= 0)) {
          lanes.add(
            PerformanceLaneSnapshot(
              lane: laneIndex,
              lengthFrames: 0,
              deferred: true,
              effects: laneChain?.effects ?? const [],
              chainEnabled: laneChain?.chainEnabled ?? true,
              volume: track.lanes[laneIndex].volume,
              pan: track.lanes[laneIndex].pan,
              muted: track.lanes[laneIndex].muted,
              outputMask: track.lanes[laneIndex].outputMask,
            ),
          );
          continue;
        }
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
        lanes.add(
          PerformanceLaneSnapshot(
            lane: laneIndex,
            lengthFrames: pcm.length,
            deferred: false,
            pcmFile: filename,
            effects: laneChain?.effects ?? const [],
            chainEnabled: laneChain?.chainEnabled ?? true,
            volume: lane.volume,
            pan: lane.pan,
            muted: lane.muted,
            outputMask: lane.outputMask,
            // Take identity (#819): lane 0 of the DISARM pass carries the
            // track's settled take id so the offline renderer can anchor this
            // disarm image by identity. Presence-keyed (written only when > 0);
            // never stamped on the arm pass, which the renderer never reads it
            // from — see [stampTakeId].
            takeId: stampTakeId && laneIndex == 0 ? track.settledTakeId : 0,
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
          solo: track.solo,
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

  /// Converts a pre-#1198 capture's raw `master.pcm` and `input-<n>.pcm` to
  /// `master.wav` and `live-input-<n>.wav`, as every finalize did before the
  /// drain wrote parts.
  Future<void> _convertLegacyPcm(
    String dir,
    Map<String, dynamic> native,
    List<int> capturedInputs,
  ) async {
    final layout =
        native['channel_layout'] as Map<String, dynamic>? ?? const {};
    final sampleRate = (native['sample_rate'] as num?)?.toInt() ?? 0;
    final masterChannels = (layout['master_channels'] as num?)?.toInt() ?? 1;
    final masterPcm = File('$dir/master.pcm');
    if (masterPcm.existsSync()) {
      await File('$dir/master.wav').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: _readRawPcm(masterPcm),
          sampleRate: sampleRate,
          channels: masterChannels,
        ),
      );
    }
    for (final input in capturedInputs) {
      final raw = File('$dir/input-$input.pcm');
      if (!raw.existsSync()) continue;
      await File('$dir/live-input-$input.wav').writeAsBytes(
        WavCodec.encodeFloat32(
          samples: _readRawPcm(raw),
          sampleRate: sampleRate,
          channels: 2,
        ),
      );
    }
  }

  Float32List _readRawPcm(File file) {
    final bytes = file.readAsBytesSync();
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 4,
    );
  }

  void _releaseCaptureGuard() {
    _captureGuard?.release();
    _captureGuard = null;
  }

  /// A part file the drain names: `master-001.wav`, `input-3-002.wav`.
  static final _partFile = RegExp(r'^(master|input-\d+)-\d{3}\.wav$');

  /// Patches the RIFF and data sizes of every part [dir] holds whose header
  /// still reads 0 (the drain patches them only when it seals the part),
  /// dropping a torn trailing frame. A file that is not a recorded part is
  /// left alone; one that cannot be opened throws, which keeps the bundle in
  /// place for the next boot.
  void _sealOpenParts(String dir) {
    const header = PerfTarget.partHeaderBytes;
    for (final entity in Directory(dir).listSync()) {
      if (!_partFile.hasMatch(_basename(entity.path))) continue;
      final file = File(entity.path).openSync(mode: FileMode.append);
      try {
        final length = file.lengthSync();
        if (length < header) continue;
        file.setPositionSync(0);
        final head = ByteData.sublistView(file.readSync(header));
        String tag(int at) =>
            String.fromCharCodes(head.buffer.asUint8List(at, 4));
        if (tag(0) != 'RIFF' ||
            tag(8) != 'WAVE' ||
            tag(36) != 'sgno' ||
            tag(76) != 'data' ||
            head.getUint32(4, Endian.little) != 0) {
          continue;
        }
        final frameBytes = head.getUint16(22, Endian.little) * 4;
        if (frameBytes == 0) continue;
        final data = (length - header) ~/ frameBytes * frameBytes;
        file
          ..truncateSync(header + data)
          ..setPositionSync(4)
          ..writeFromSync(_u32(header - 8 + data))
          ..setPositionSync(header - 4)
          ..writeFromSync(_u32(data));
      } finally {
        file.closeSync();
      }
    }
  }

  static Uint8List _u32(int value) =>
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

  String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Releases the status stream. Does not disarm — callers that own the
  /// engine lifecycle are responsible for disarming before disposal.
  void dispose() {
    unawaited(_statusController.close());
    unawaited(_armRefusals.close());
  }
}
