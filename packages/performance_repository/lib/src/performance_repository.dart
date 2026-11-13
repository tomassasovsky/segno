import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:performance_repository/src/legacy_capture.dart';
import 'package:performance_repository/src/models/arm_refusal.dart';
import 'package:performance_repository/src/models/capture_summary.dart';
import 'package:performance_repository/src/models/performance_chains.dart';
import 'package:performance_repository/src/models/performance_manifest.dart';
import 'package:performance_repository/src/models/performance_names.dart';
import 'package:performance_repository/src/models/recording_format.dart';
import 'package:performance_repository/src/models/unfinalized_capture.dart';
import 'package:performance_repository/src/performance_capture_status.dart';
import 'package:performance_repository/src/performance_exception.dart';
import 'package:performance_repository/src/performance_slug.dart';
import 'package:performance_repository/src/take_recovery.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:wav_codec/wav_codec.dart';

/// Owns the performance-recording capture lifecycle end-to-end.
///
/// Composes [AudioEngine] (never `NativeAudioEngine`) the same way every other
/// repository does. A capture's directory IS its final bundle location from
/// the moment of [arm] — `{exportsRoot}/<slug>/` — so there is no separate
/// temp-then-move step: the continuous taps (master/monitor, `perf_drain.c`,
/// written as float WAV parts) and this layer's own settled-lane WAV exports
/// all land directly where the finished bundle expects them, and [disarm]
/// only needs to merge the snapshot metadata into the sidecar.
class PerformanceRepository {
  /// Creates a [PerformanceRepository] driving [_engine].
  ///
  /// [_exportsRoot] resolves the `exports/` root directory new bundles are
  /// created under (mirrors `SessionRepository`'s `sessionsRoot`). [_now]
  /// supplies the timestamp [arm] slugs from; injectable for deterministic
  /// tests. [_bootRecoveryPollInterval] paces [runBootRecovery]'s wait for
  /// the salvage render to finish before it moves the bundle; injectable so
  /// tests interleave against the wait without real 200ms sleeps.
  /// [_bootRecoveryRenderTimeout] bounds that wait (default
  /// [defaultBootRecoveryRenderTimeout]) so a wedged render can never park
  /// boot recovery — and [arm]'s render-poll refusal — forever.
  ///
  /// [_storageIo] makes the engine's digest and directory sync, without an
  /// engine; it is called on a background isolate too, so it must be a
  /// top-level or static function. [_partBytes] is the size of the parts a
  /// take from before #1198 is converted into (tests pass small sizes).
  /// [_bootId] reads this boot's kernel id, which decides how far recovery
  /// trusts a take's files ([readBootId]).

  new({
    required this._engine,
    required this._exportsRoot,
    required this._guards,
    this._now = DateTime.now,
    this._bootRecoveryPollInterval = const Duration(milliseconds: 200),
    this._bootRecoveryRenderTimeout = defaultBootRecoveryRenderTimeout,
    this._reserveBytes,
    this._storageIo = NativeStorageIo.new,
    this._partBytes = RecordedPartWriter.defaultPartBytes,
    this._bootId = readBootId,
  });

  final AudioEngine _engine;
  final Future<String> Function() _exportsRoot;
  final DateTime Function() _now;
  final Duration _bootRecoveryPollInterval;
  final Duration _bootRecoveryRenderTimeout;
  final StorageIo Function() _storageIo;
  late final StorageIo _io = _storageIo();
  final int _partBytes;
  final String Function() _bootId;

  /// How long a take runs with nothing happening (no press, no transport
  /// change, no edit, no input above the playing level) before it stops on
  /// its own, keeping everything recorded (#1767, owner's call). A take left
  /// running with nobody at the console recorded 4.5 GB an hour (#1747).
  static const Duration idleStopAfter = Duration(minutes: 20);

  /// The longest a take runs (#1767): the rendered stereo master at 48 kHz
  /// fills one file on a FAT32 stick (4 GiB less one byte, header included)
  /// at 3 h 6 min (#1747, #1794), and the engine never lets a take run past
  /// what that stem can hold in one, whatever the rate: a stereo take at
  /// 96 kHz stops at 93 min. `test_perf_longest_take_fits_one_fat32_file`
  /// (the engine's native tests) checks every file a take renders.
  static const Duration longestTake = Duration(hours: 3);

  /// The app's one guard table (accepted behaviour 6.12). A take holds a
  /// `capture` guard from the commit of [arm] until it is finalized or its
  /// failed arm is cancelled, so a device change, a calibration, a session
  /// apply or a shutdown sees it at their own commits, and [arm] itself is
  /// refused while one of them is in flight.
  final GuardRegistry _guards;
  OperationGuard? _captureGuard;

  final StreamController<PerformanceArmRefusal> _armRefusals =
      StreamController<PerformanceArmRefusal>.broadcast();

  /// Every refused [arm], with why: a take finalizing or recovering, a render
  /// in progress, or the guard table. The pedal and MIDI controls call [arm]
  /// with nothing in front of it, so the reason goes here for every caller
  /// alike, and the recorder cubit listens (#1633).
  Stream<PerformanceArmRefusal> get armRefusals => _armRefusals.stream;

  /// The work in flight that refuses [arm] right now, or null when none
  /// does: a take finalizing or recovering, a render in progress, then a
  /// take whose delivery is still held ([holdArm]).
  PerformanceArmBusy? get armBusy {
    if (_finalizesInFlight > 0) return PerformanceArmBusy.finalizing;
    if (!renderProgress.done) return PerformanceArmBusy.rendering;
    if (_armHolds > 0) return PerformanceArmBusy.finalizing;
    return null;
  }

  /// Open [holdArm] holds; [arm] refuses while above zero.
  int _armHolds = 0;

  /// Keeps [arm] refused, as a take still being saved, until the returned
  /// hold is released (#1638). A finished take's delivery does not end with
  /// its finalize and stem render: the app still writes its DAW project
  /// into the bundle. A take armed in that window would be overwritten by
  /// the delivery that follows, so the app holds the gate from the take's
  /// finalize until it has delivered it, and every control, pedal and MIDI
  /// included, is refused alike.
  PerformanceArmHold holdArm() {
    _armHolds++;
    return PerformanceArmHold._(() => _armHolds--);
  }

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

  /// Captures the last [runBootRecovery] tried and could not finalize (a
  /// damaged sidecar, too little space to convert a take from before #1198,
  /// a failed write). Each stays where it is with every file kept and is
  /// tried again at the next start; the app tells the player it could not be
  /// recovered.
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

  /// The file a salvage writes in a bundle before its finalize and stem
  /// render begin, and removes once they (the render included, however long
  /// it outlives the wait) have ended (#1747): how many salvages of the
  /// bundle have begun without ending. Found at the next start, it says the
  /// app stopped while that salvage ran (it ran the console out of memory,
  /// crashed, was restarted, or the power went).
  static const String recoveryAttemptName = '.boot-recovery-attempt';

  /// The mark that a bundle's salvage did not finish and is not started
  /// again at boot (#1747): the app stopped during two salvages of it in a
  /// row (one is tried again: a restart or a power cut also stops one). The
  /// bundle and its files are kept and counted in [unrecoveredTakes];
  /// [retryUnrecovered] clears the mark and gives it one more salvage.
  /// Without it, a salvage that kills the app is run by every start, and the
  /// app never stays up.
  static const String recoveryFailedName = '.boot-recovery-failed';

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

  /// The sidecar key that marks a take converted from raw streams (#1078):
  /// its parts are sealed and kept exactly as recorded, so finalize does not
  /// bring its streams to one length as it does for a take the drain wrote.
  static const String convertedFromRawKey = 'converted_from_raw';

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

  /// Every track's render outcome discovered so far: all of them once the
  /// stems are written, which the tracks finish together (#1747). `succeeded`
  /// reflects both that track's dry AND wet
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
  /// arm overlapping one still in flight is a no-op success too: it is the
  /// same press arriving twice. [chains]
  /// supplies the lane/monitor effect chains and master-limiter state the
  /// engine snapshot alone cannot read back (see [PerformanceChains]), and
  /// [names] what the player calls each track and input
  /// ([PerformanceNames]).
  ///
  /// Refused with [EngineResult.notReady] while a take finalizes or
  /// recovers, or a render is in flight (#671), and when the guard table
  /// refuses the take at its commit: arming then would yank that
  /// in-progress finalize/render out from under whoever is watching it (the
  /// render's result dialog), and the pedal and MIDI controls call this
  /// directly with no cubit-level gate in front of it. Every such refusal is
  /// published on [armRefusals] with its reason, so the player is told why
  /// whichever control was pressed (#1633).
  ///
  /// [root] puts this take's bundle under another directory than the
  /// constructor's `exportsRoot` (a USB volume's `Segno/Performances`, #1177);
  /// [armedDirectory] stays the truth of where it went. [scope] is where the
  /// take's `capture` guard is held, so the guard table can refuse an eject
  /// or a copy on that volume while it records: a removable [root] must come
  /// with that volume's scope.
  Future<EngineResult> arm({
    PerformanceChains chains = const PerformanceChains(),
    PerformanceNames names = const PerformanceNames(),
    String? root,
    GuardScope scope = const GuardScope.internal(),
  }) async {
    // A take being finalized still owns its directory until the finalize
    // returns: that is a take being saved, not the same press arriving
    // twice, so it is refused and said like the rest (#1638).
    if (_status == PerformanceCaptureStatus.finalizing) {
      return _refuseArm(
        const PerformanceArmBusyRefusal(PerformanceArmBusy.finalizing),
      );
    }
    if (_armedDir != null || _armInFlight) return EngineResult.ok;
    final busy = armBusy;
    if (busy != null) return _refuseArm(PerformanceArmBusyRefusal(busy));
    _armInFlight = true;
    final finished = Completer<void>();
    _armFinished = finished;
    try {
      return await _armGated(chains, names, root: root, scope: scope);
    } finally {
      _armInFlight = false;
      _armFinished = null;
      finished.complete();
    }
  }

  /// Publishes [refusal] on [armRefusals] and answers the refused [arm].
  EngineResult _refuseArm(PerformanceArmRefusal refusal) {
    _armRefusals.add(refusal);
    return EngineResult.notReady;
  }

  /// The body of [arm] past its entry gate; runs with [_armInFlight] held.
  Future<EngineResult> _armGated(
    PerformanceChains chains,
    PerformanceNames names, {
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
    final tracks = _captureSettledLanes(
      dir,
      chains: chains,
      writeChains: true,
      names: names.tracks,
    );
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
      inputNames: {
        for (final MapEntry(:key, :value) in names.inputs.entries)
          if (value.trim().isNotEmpty) key: value.trim(),
      },
      monitors: _monitorsJson(chains),
      // The bus stages (FX v3, R20/R3): recorded so a replay can rebuild the
      // whole four-stage rig, bypass state included.
      trackChains: chains.trackChains,
      outputChains: chains.outputChains,
    );
    // Re-checked here, not just at entry: the awaits above suspend this arm,
    // and a boot-salvage ([recoverCapture]) starting inside that window
    // raises [_finalizesInFlight] too late for the entry gate to see — the
    // resumed arm would clobber the in-progress salvage. The same refusal as
    // the entry gate's; the just-created directory is discarded, exactly like
    // the failed-perfArm path below (#671).
    final busy = armBusy;
    if (_armedDir != null || busy != null) {
      // Ownership-checked belt to [_armInFlight]'s braces: never delete the
      // live armed capture directory (the drain thread is writing into it) —
      // only this call's own still-unclaimed one.
      if (dir != _armedDir) {
        final created = Directory(dir);
        if (created.existsSync()) created.deleteSync(recursive: true);
      }
      return busy == null
          ? EngineResult.ok
          : _refuseArm(PerformanceArmBusyRefusal(busy));
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
      return _refuseArm(PerformanceArmGuardRefusal(refusal));
    }

    // The take's identity (#1198): random, minted before any audio exists,
    // and written into every part's `sgno` chunk by the drain.
    final takeId = _mintTakeId();
    // The reserve is Internal's (#1198); a removable volume keeps none
    // (#1177), so a take there stops only when its writes fail.
    final result = _engine.perfArm(
      PerfTarget(
        captureDir: dir,
        takeId: takeId,
        reserveBytes: root == null ? _reserveBytes : null,
        idleStopSeconds: idleStopAfter.inSeconds,
        maxSeconds: longestTake.inSeconds,
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
    return await _finalizeArmed(dir);
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
  /// engine, and merges every snapshot into the sidecar with
  /// `finalized: true`.
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
    return await _finalizeArmed(dir);
  }

  /// The disarm-time snapshot of the take in [dir], taken while the engine
  /// is still the live session's.
  PerformanceDisarmSnapshot _disarmSnapshot(String dir) =>
      PerformanceDisarmSnapshot(
        // Re-read here, not copied from the arm snapshot: D6's tempo lock
        // only engages once grid content exists, so a tempo dialed in — or
        // derived by the first loop — after an arm-over-empty-grid is only
        // knowable now. This is the authoritative tempo a DAW export stamps;
        // the arm-time copy serves crash salvage, which never gets this pass
        // (#281). Read before perfDisarm, while the engine is still the live
        // session's.
        tempoBpm: _engine.snapshot().tempoBpm,
        tracks: _captureSettledLanes(
          dir,
          chains: const PerformanceChains(),
          writeChains: false,
          stampTakeId: true,
        ),
      );

  Future<EngineResult> _finalizeArmed(String dir) async {
    _setStatus(PerformanceCaptureStatus.finalizing);
    final PerformanceDisarmSnapshot disarmSnapshot;
    final EngineResult result;
    try {
      disarmSnapshot = _disarmSnapshot(dir);
      result = _engine.perfDisarm();
    } on Object {
      // The lanes could not be exported, or the engine's disarm threw:
      // nothing has stopped and the take keeps its owner. Saying so keeps no
      // one waiting on a finalize that never started (#1639).
      _setStatus(PerformanceCaptureStatus.armed);
      rethrow;
    }
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
        live: true,
      );
    } on Object {
      // The engine has stopped: the take is no longer live, whatever the
      // finalize did. It stays unfinalized on disk for the next start's
      // recovery, and the repository is free to record again.
      _armedDir = null;
      _armSnapshot = null;
      _armedAt = null;
      _setStatus(PerformanceCaptureStatus.idle);
      rethrow;
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
  /// was interrupted), and so does a take with a checkpoint slot but no
  /// sidecar at all (a power cut before the first sidecar was durable).
  Future<List<UnfinalizedCapture>> findUnfinalized() async {
    final root = Directory(await _exportsRoot());
    if (!root.existsSync()) return const [];
    final out = <UnfinalizedCapture>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      // A hidden directory is a delete in progress, never a take.
      if (_basename(entity.path).startsWith('.')) continue;
      if (!File('${entity.path}/$manifestName').existsSync() &&
          !checkpointSlotNames.any(
            (slot) => File('${entity.path}/$slot').existsSync(),
          )) {
        continue;
      }
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
  Future<void> recoverCapture(String directory) => _finalize(
    directory,
    armSnapshot: null,
    disarmSnapshot: null,
    live: false,
  );

  /// Discards a crashed (unfinalized) capture at [directory] by deleting it
  /// outright — the counterpart to [recoverCapture] when the user chooses
  /// not to salvage it. A no-op if [directory] no longer exists, including
  /// when it goes away during the delete: a USB drive pulled under the take
  /// takes the directory with it, which is the end this asks for.
  ///
  /// A render still running on [directory] (a take too short to keep is
  /// discarded right after its finalize started one) is cancelled first, so
  /// the render slot is free and Capture is not refused for a take that no
  /// longer exists (#1638).
  Future<void> discardUnfinalized(String directory) async {
    if (_renderDir == directory && !renderProgress.done) {
      _engine.renderCancel();
    }
    // Hidden first, as a delete is: a cut halfway through the delete must
    // not leave a checkpoint that the next start recovers as a take.
    final doomed =
        '${_dirname(directory)}/.${_basename(directory)}$deletingSuffix';
    try {
      if (Directory(doomed).existsSync()) {
        Directory(doomed).deleteSync(recursive: true);
      }
      Directory(directory).renameSync(doomed);
      Directory(doomed).deleteSync(recursive: true);
    } on FileSystemException {
      // Gone already, or going (a USB drive pulled under the take): remove
      // what is left; a hidden remainder is finished at the next start.
      for (final path in [directory, doomed]) {
        try {
          Directory(path).deleteSync(recursive: true);
        } on FileSystemException {
          continue;
        }
      }
    }
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
  Future<void> runBootRecovery() => _sweep(const {});

  /// [runBootRecovery], salvaging the bundles in [retry] even though they
  /// are marked failed ([retryUnrecovered]).
  Future<void> _sweep(Set<String> retry) async {
    final previous = _unrecovered.toSet();
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
    for (var i = 0; i < pending.length; i++) {
      final dir = pending[i];
      // Between-captures re-check, not just per-directory: a live arm owns
      // the one global render slot, so salvaging ANY capture while armed
      // would corrupt the take's own render/disarm flow, not only its
      // directory. Deferring the remainder to the next boot is the honest
      // outcome — recovery is a background nicety, the live take is not.
      //
      // A render still in flight — a prior capture's salvage timed out on
      // it — squats the engine's one global render slot: the next salvage's
      // renderBegin would be refused, its wait would watch the WRONG
      // render, and the bundle would land in the recovered area stemless
      // with its marker gone. Stop; the remainder waits for the next boot.
      if (_armedDir != null || _armInFlight || !renderProgress.done) {
        // What this sweep does not reach and was not recovered (counted
        // before, or marked failed) still is not.
        _unrecovered.addAll(
          pending
              .skip(i)
              .where(
                (d) =>
                    previous.contains(d) ||
                    File('$d/$recoveryFailedName').existsSync() ||
                    _attemptsBegun(d) >= 2,
              ),
        );
        return;
      }
      if (retry.contains(dir)) {
        _clearFailed(dir);
      } else if (_salvageFailed(dir)) {
        // A salvage the app did not survive is not run again by itself:
        // the take is counted as not recovered until the player asks again.
        _unrecovered.add(dir);
        continue;
      }
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
    if (_strandedSalvage(root).any((dir) => !_salvageFailed(dir))) {
      return true;
    }
    return (await findUnfinalized()).any(
      (capture) => !_salvageFailed(capture.directory),
    );
  }

  /// Salvages again every take [unrecoveredTakes] names, as a start does
  /// but past their failed mark (#1747): the player's Try again on the
  /// notice that says a take could not be recovered. Each gets one more
  /// salvage: one the app does not survive marks it failed again at the next
  /// start. A take the sweep does not reach (a take is being recorded, a
  /// render is still running) keeps its mark and stays counted.
  Future<void> retryUnrecovered() => _sweep(_unrecovered.toSet());

  /// Lifts [dir]'s failed mark for one more salvage: it is recorded as one
  /// salvage already interrupted, so the next that is fails it again.
  void _clearFailed(String dir) {
    try {
      File('$dir/$recoveryAttemptName').writeAsStringSync('1\n');
      final mark = File('$dir/$recoveryFailedName');
      if (mark.existsSync()) mark.deleteSync();
    } on FileSystemException {
      return; // the salvage below runs; its own write reports a bad disk
    }
  }

  /// Whether [dir]'s salvage is marked failed, marking it now when the app
  /// stopped during two salvages of it in a row ([recoveryAttemptName]). One
  /// interrupted salvage is run again: a restart or a power cut also stops
  /// one, and the boot id cannot tell those from a kill (an app restarted
  /// by its service runs in the same boot).
  bool _salvageFailed(String dir) {
    if (File('$dir/$recoveryFailedName').existsSync()) return true;
    if (_attemptsBegun(dir) < 2) return false;
    try {
      File('$dir/$recoveryFailedName').writeAsStringSync('');
      File('$dir/$recoveryAttemptName').deleteSync();
    } on FileSystemException {
      // Unwritable: still not run this boot; the next start decides again.
    }
    return true;
  }

  /// How many salvages of [dir] began without ending (0 when none).
  int _attemptsBegun(String dir) {
    final file = File('$dir/$recoveryAttemptName');
    try {
      if (!file.existsSync()) return 0;
      return int.tryParse(file.readAsStringSync().trim()) ?? 1;
    } on FileSystemException {
      return 1;
    }
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
      // Begun: if the app stops before it ends, the next start knows
      // (#1747). Written before the finalize, which can be as heavy as the
      // render for a take from before #1198.
      File('$dir/$recoveryAttemptName')
          .writeAsStringSync('${_attemptsBegun(dir) + 1}\n');
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
        _beginRender(dir);
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
          // The attempt stays while the render still runs (an app that
          // stops during it has not survived this salvage), and ends with
          // it.
          unawaited(_endAttemptWhenRendered(dir));
          return;
        }
        await Future<void>.delayed(_bootRecoveryPollInterval);
        waited += _bootRecoveryPollInterval;
      }
      // Ended, however it went: the app survived this salvage.
      _endAttempt(dir);
      if (!_sidecarFinalized(dir)) return; // nothing recovered; retried later
      // Re-checked at the last synchronous moment before the rename: the
      // awaits above suspended this salvage, and the one directory that must
      // never be renamed is the live capture's.
      if (_armedDir != null || _armInFlight) return;
      _moveToRecovered(root, dir);
    } on Exception {
      // One capture's failure neither aborts the loop for its siblings nor
      // escapes the unawaited boot call as an unhandled zone error. The
      // bundle (and its marker) stay for the next boot; a failure the app
      // survived is no reason not to try again then.
      if (renderProgress.done) _endAttempt(dir);
      return;
    }
  }

  /// Ends [dir]'s attempt once the render a timed-out salvage left running
  /// is done, or another render has taken the slot (so it is done too).
  Future<void> _endAttemptWhenRendered(String dir) async {
    while (!_disposed && _renderDir == dir && !renderProgress.done) {
      await Future<void>.delayed(_bootRecoveryPollInterval);
    }
    if (!_disposed) _endAttempt(dir);
  }

  /// Removes [dir]'s [recoveryAttemptName]: its salvage has ended.
  void _endAttempt(String dir) {
    try {
      final file = File('$dir/$recoveryAttemptName');
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      return; // read as an interrupted salvage at the next start
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
    File('$dir/$recoveredAtStampName')
        .writeAsStringSync(_now().millisecondsSinceEpoch.toString());
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
  /// exist on disk: every audio part in order, the rendered stems and lane
  /// loops the Live Set points at (`stems/dry/`, `stems/wet/`, `loops/`),
  /// then the [dawProjectFiles]. The Library copies them keeping these
  /// paths, so the Live Set opens on the drive with none of its media
  /// missing (#1799).
  List<String> dawPackageFiles(CaptureSummary capture) {
    final dir = capture.path;
    final stems = <String>[];
    for (final folder in const ['stems/dry', 'stems/wet', 'loops']) {
      final List<FileSystemEntity> entries;
      try {
        entries = Directory('$dir/$folder').listSync();
      } on FileSystemException {
        continue;
      }
      stems.addAll(
        [
          for (final e in entries)
            if (e is File && e.path.toLowerCase().endsWith('.wav'))
              '$folder/${_basename(e.path)}',
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
        _armHolds > 0 ||
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
    return await _engine.auditionStartFile(path, stillWanted: stillWanted);
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
    required bool live,
  }) async {
    _finalizesInFlight++;
    try {
      // The sidecar, or null when it is missing (a cut before the drain's
      // first one was durable) or does not read: a crashing writer can leave
      // well-formed JSON with wrong types, whose decode casts raise [Error]s
      // rather than [FormatException]. The checkpoint can still say what the
      // take holds.
      Map<String, dynamic>? native;
      try {
        native = PerformanceManifest.fromJson(
          jsonDecode(await File('$dir/$manifestName').readAsString())
              as Map<String, dynamic>,
        ).native;
      } on Object {
        native = null;
      }
      // A capture from before #1198 (#1078): raw PCM, no parts and no take
      // id, or one whose conversion a cut interrupted. A take the drain
      // wrote as parts always carries its id, so a stray raw file beside its
      // parts never sends it here.
      final rawCapture =
          native != null &&
          (native['take_id'] == null || native[convertedFromRawKey] == true);
      if (rawCapture && _holdsRawPcm(dir)) {
        // Converted into parts a stream at a time in bounded memory;
        // anything short of a complete conversion leaves it unfinalized, its
        // raw files kept, for the next start.
        final streams = streamsOf(native);
        if (streams == null) return; // a layout no conversion can trust
        final converted = await _convertLegacy(dir, native, streams);
        if (converted == null) return;
        native = converted;
      }

      // The parts as the durable record and the trust rule allow (D4):
      // sealed, every stream ending at the same frame. Null when the take's
      // shape cannot be known; it stays as it is for the next start. A take
      // converted from raw streams is already sealed and is kept exactly as
      // it was recorded, stream lengths included.
      final sidecar = native;
      if (sidecar?[convertedFromRawKey] == true) {
        return await _publishFinalized(
          dir,
          sidecar!,
          armSnapshot,
          disarmSnapshot,
        );
      }
      final storageIo = _storageIo;
      final bootId = _bootId();
      final reconciled = await Isolate.run(
        () => reconcileTake(
          dir: dir,
          native: sidecar,
          live: live,
          bootId: bootId,
          storageIo: storageIo(),
        ),
      );
      if (reconciled == null) return;
      await _publishFinalized(
        dir,
        _reconciledFields(native, reconciled),
        armSnapshot,
        disarmSnapshot,
      );
    } finally {
      // Decremented only after renderBegin: the render poll takes over
      // [arm]'s refusal from here with no uncovered gap between the two.
      _finalizesInFlight--;
    }
  }

  /// Writes [native] with the arm and disarm snapshots as the take's
  /// finalized manifest, durably, then starts its offline render.
  Future<void> _publishFinalized(
    String dir,
    Map<String, dynamic> native,
    PerformanceArmSnapshot? armSnapshot,
    PerformanceDisarmSnapshot? disarmSnapshot,
  ) async {
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
    // A failed directory sync does not undo the finalize: the manifest is
    // in place, and if a power cut takes it back the next start finalizes
    // the take again.
    await _publishManifest(dir, manifest.toJson());
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
    _beginRender(dir);
  }

  /// The take the engine's render slot was last given, so a discard of that
  /// take can stop its render ([discardUnfinalized]).
  String? _renderDir;

  /// Set by [dispose]: background waits stop.
  bool _disposed = false;

  void _beginRender(String dir) {
    if (_engine.renderBegin(dir).isOk) _renderDir = dir;
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
    Map<int, String> names = const {},
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
        // What the player heard (#1713): the wet stem plays it where the lane
        // played it. Exported in the same settled window as the clean take,
        // so the two stand frame for frame. This export replaces the lane's
        // earlier one, so a take without a heard image also removes the one
        // an earlier take left beside it.
        final heard = _engine.exportTrackLaneHeard(channel, laneIndex);
        final heardName = 'loops/track$channel-lane$laneIndex-heard.wav';
        final heardWav = File('$dir/$heardName');
        String? heardFile;
        if (heard.length == 2 * pcm.length) {
          heardFile = heardName;
          heardWav.writeAsBytesSync(
            WavCodec.encodeFloat32(
              samples: heard,
              sampleRate: snapshot.sampleRate,
              channels: 2,
            ),
          );
        } else if (heardWav.existsSync()) {
          heardWav.deleteSync();
        }
        lanes.add(
          PerformanceLaneSnapshot(
            lane: laneIndex,
            lengthFrames: pcm.length,
            deferred: false,
            pcmFile: filename,
            heardFile: heardFile,
            playsClean: heardFile != null && lane.source == LaneSource.clean,
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
          anchorLap: track.anchorLap,
          lanes: lanes,
          name: _givenName(names[channel]),
        ),
      );
    }
    return tracks;
  }

  /// [name] trimmed, or `null` when there is none to keep.
  static String? _givenName(String? name) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
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

  /// The sidecar fields of a finalized take from [reconciled]: its parts,
  /// overs and identity, and `capture_frames` set to the frames every
  /// stream holds, so a render or an export never lays out more than the
  /// audio (#727). A take with no part keeps its `capture_frames`.
  /// [native] is null when the sidecar was lost: the fields the checkpoint
  /// cannot give (overruns, gaps, layer details) are then empty, and its
  /// layer files are counted as dropped. When only the checkpoint was
  /// trusted, a layer it does not list is dropped too.
  Map<String, dynamic> _reconciledFields(
    Map<String, dynamic>? native,
    ReconciledTake reconciled,
  ) {
    final takeId = reconciled.takeId;
    // A take with no id has no part either; its fields stand as they are.
    if (takeId == null) return native!;
    final checkpoint = reconciled.checkpoint;
    final fields = <String, dynamic>{
      ...native ??
          {
            'sample_rate': reconciled.sampleRate,
            'channel_layout': {
              'master_channels': reconciled.streams.first.channels,
              'captured_inputs': [
                for (final s in reconciled.streams.skip(1)) s.stream - 1,
              ],
            },
            // Overwritten below by what the parts hold, when there are any.
            'capture_frames': checkpoint?.frames ?? 0,
            'overrun_count': 0,
            'zero_filled_frames': 0,
            'overrun_gaps': const <dynamic>[],
            'layers': const <dynamic>[],
            if (checkpoint != null && checkpoint.layers.isNotEmpty)
              'layers_dropped': checkpoint.layers.length,
          },
      // With no part on disk the stems still render to the captured
      // length, so it is kept.
      if (reconciled.parts.isNotEmpty) 'capture_frames': reconciled.frames,
      'take_id': takeId,
      'encoding': TakeCheckpoint.encoding,
      'overs': reconciled.parts.fold<int>(0, (sum, p) => sum + p.overs),
      'parts': [for (final p in reconciled.parts) p.toJson()],
    };
    final layers = fields['layers'];
    if (native != null &&
        checkpoint != null &&
        !reconciled.trustedFiles &&
        layers is List<dynamic>) {
      final durable = checkpoint.layers.toSet();
      final kept = [
        for (final l in layers)
          if (l is Map<String, dynamic> && durable.contains(l['filename'])) l,
      ];
      final dropped = layers.length - kept.length;
      if (dropped > 0) {
        fields['layers'] = kept;
        final before = fields['layers_dropped'];
        fields['layers_dropped'] = (before is int ? before : 0) + dropped;
      }
    }
    return fields;
  }

  /// A raw stream file the drain wrote before #1198.
  static final _rawPcmFile = RegExp(r'^(master|input-\d+)\.pcm$');

  /// Whether [dir] still holds a raw stream of a capture from before #1198.
  bool _holdsRawPcm(String dir) =>
      Directory(dir)
          .listSync()
          .any((e) => e is File && _rawPcmFile.hasMatch(_basename(e.path)));

  /// Converts a capture from before #1198 into float parts (#1078): each
  /// raw stream in turn is copied into parts on a background isolate, a
  /// megabyte at a time; the parts are digested, synced and listed in an
  /// interim sidecar published durably, and only then is that stream's raw
  /// file removed. So the conversion needs room for the largest stream
  /// only, and a cut anywhere leaves either the raw file or its listed
  /// parts. Returns the sidecar fields with the parts listed, or null when
  /// the take must stay as it is: too little space (nothing is touched),
  /// an interim sidecar that does not read, or a failed write (that stream's
  /// new parts are deleted and its raw file kept).
  Future<Map<String, dynamic>?> _convertLegacy(
    String dir,
    Map<String, dynamic> native,
    List<({int stream, int channels})> streams,
  ) async {
    final sampleRate = native['sample_rate'];
    if (sampleRate is! int || sampleRate < 1) return null;
    final takeHex = native['take_id'];
    final takeId = takeHex is String && _takeIdHex.hasMatch(takeHex)
        ? _hexBytes(takeHex)
        : _mintTakeId();
    final List<TakePart> parts;
    try {
      parts = [
        for (final entry in native['parts'] as List<dynamic>? ?? const [])
          TakePart.fromJson(entry as Map<String, dynamic>),
      ];
    } on Object {
      return null; // an interim list that does not read: never guess
    }

    final pending = <({int stream, int channels})>[];
    for (final s in streams) {
      final pcm = File('$dir/${legacyPcmName(s.stream)}');
      final listed = parts.where((p) => p.stream == s.stream).toList();
      final done =
          listed.isNotEmpty &&
          listed.every((p) {
            final f = File('$dir/${p.file}');
            return f.existsSync() && f.lengthSync() == p.bytes;
          });
      if (done) {
        // Converted and recorded before a cut; only the removal was lost.
        if (pcm.existsSync()) pcm.deleteSync();
      } else if (pcm.existsSync()) {
        pending.add(s);
      } else if (listed.isNotEmpty) {
        return null; // listed parts gone and no raw file: keep for a look
      }
    }

    // What a cut conversion left unlisted goes first, so its room counts.
    for (final s in pending) {
      _deleteStrayParts(dir, s.stream);
      parts.removeWhere((p) => p.stream == s.stream);
    }
    final format = [
      for (final s in pending)
        RecordingFormat(
          sampleRate: sampleRate,
          channels: s.channels,
          partBytes: _partBytes,
        ),
    ];
    var largest = 0;
    for (var i = 0; i < pending.length; i++) {
      final length = File('$dir/${legacyPcmName(pending[i].stream)}')
          .lengthSync();
      final frames = length ~/ format[i].frameBytes;
      final need =
          format[i].bytesToAppend(frames) +
          (frames == 0 ? RecordingFormat.headerBytes : 0);
      if (need > largest) largest = need;
    }
    // The conversion keeps the reserve a take keeps, so it never fills the
    // volume the console runs from.
    final space = _engine.volumeSpace(dir);
    if (space != null && space.freeBytes < largest + (_reserveBytes ?? 0)) {
      return null;
    }

    var out = native;
    for (final s in pending) {
      final pcm = '$dir/${legacyPcmName(s.stream)}';
      final partBytes = _partBytes;
      final List<TakePart> written;
      try {
        written = await Isolate.run(
          () => convertRawStream(
            pcmPath: pcm,
            dir: dir,
            stream: s.stream,
            channels: s.channels,
            sampleRate: sampleRate,
            takeId: takeId,
            partBytes: partBytes,
          ),
        );
      } on Object {
        return null; // its parts are already gone; the raw file stays
      }
      try {
        for (final part in written) {
          final sha = await _digestPayload(
            _storageIo,
            '$dir/${part.file}',
            part.bytes - RecordingFormat.headerBytes,
          );
          if (sha == null) throw FileSystemException('unreadable', part.file);
          parts.add(
            TakePart(
              stream: part.stream,
              index: part.index,
              file: part.file,
              frames: part.frames,
              bytes: part.bytes,
              overs: part.overs,
              sha256: sha,
            ),
          );
        }
        _io.syncDirectory(dir);
        final listed = {
          ...native,
          'take_id': _hex(takeId),
          'encoding': TakeCheckpoint.encoding,
          'overs': parts.fold<int>(0, (sum, p) => sum + p.overs),
          'parts': [for (final p in _ordered(parts)) p.toJson()],
          convertedFromRawKey: true,
        };
        final synced = await _publishManifest(dir, {
          ...listed,
          'slug': _basename(dir),
          'finalized': false,
        });
        // Listed but perhaps not durably: the parts stand, and so does the
        // raw file, until a later start can make the listing durable.
        if (!synced) return null;
        out = listed;
      } on Object {
        for (final part in written) {
          final f = File('$dir/${part.file}');
          if (f.existsSync()) f.deleteSync();
        }
        return null;
      }
      File(pcm).deleteSync();
    }
    return out;
  }

  /// Deletes every part file of [stream] in [dir]: what a conversion cut
  /// short left before it could list them.
  void _deleteStrayParts(String dir, int stream) {
    final prefix = stream == 0 ? 'master-' : 'input-${stream - 1}-';
    for (final entity in Directory(dir).listSync()) {
      final name = _basename(entity.path);
      if (entity is File &&
          name.startsWith(prefix) &&
          _partFile.hasMatch(name)) {
        entity.deleteSync();
      }
    }
  }

  /// [parts] in playback order: stream by stream, each by index.
  static List<TakePart> _ordered(List<TakePart> parts) => [...parts]
    ..sort(
      (a, b) => a.stream != b.stream
          ? a.stream.compareTo(b.stream)
          : a.index.compareTo(b.index),
    );

  /// The SHA-256 of [dataBytes] of the part at [path] after its header, on a
  /// background isolate through [storageIo]; null when it cannot be read
  /// whole. Static, so the isolate's closure captures nothing else.
  static Future<String?> _digestPayload(
    StorageIo Function() storageIo,
    String path,
    int dataBytes,
  ) => Isolate.run(
    () => switch (storageIo().digestFile(
      path,
      offset: RecordingFormat.headerBytes,
      length: dataBytes,
    )) {
      FileDigested(:final sha256) => sha256,
      _ => null,
    },
  );

  /// Writes [json] as [dir]'s `performance.json`: a temporary file, flushed,
  /// renamed over the sidecar, then the directory synced. A reader sees the
  /// old sidecar or the new one. Throws, leaving the old sidecar and no
  /// temporary file, when the write or the rename fails. Returns whether the
  /// directory sync also succeeded, which is what makes the new sidecar
  /// survive a power cut; when it did not, the new sidecar is already in
  /// place.
  Future<bool> _publishManifest(String dir, Map<String, dynamic> json) async {
    final pending = File('$dir/$manifestName.publishing');
    try {
      await pending.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      await pending.rename('$dir/$manifestName');
    } on Object {
      try {
        if (pending.existsSync()) pending.deleteSync();
      } on FileSystemException {
        // The volume may be gone; the temporary file is never read.
      }
      rethrow;
    }
    try {
      _io.syncDirectory(dir);
      return true;
    } on Object {
      // Whatever failed, the new sidecar is already in place.
      return false;
    }
  }

  static final RegExp _takeIdHex = RegExp(r'^[0-9a-f]{32}$');

  static Uint8List _mintTakeId() {
    final random = Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < PerfTarget.takeIdBytes; i++) random.nextInt(256),
    ]);
  }

  static Uint8List _hexBytes(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _releaseCaptureGuard() {
    _captureGuard?.release();
    _captureGuard = null;
  }

  /// A part file the drain names: `master-001.wav`, `input-3-002.wav`.
  static final _partFile = RegExp(r'^(master|input-\d+)-\d{3}\.wav$');

  String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Releases the status stream. Does not disarm — callers that own the
  /// engine lifecycle are responsible for disarming before disposal.
  void dispose() {
    _disposed = true;
    unawaited(_statusController.close());
    unawaited(_armRefusals.close());
  }
}

/// A hold on [PerformanceRepository.arm] from
/// [PerformanceRepository.holdArm]; [release] lets arming through again.
final class PerformanceArmHold {
  new _(this._onRelease);

  final void Function() _onRelease;
  bool _released = false;

  /// Ends this hold. Releasing it again does nothing.
  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}
