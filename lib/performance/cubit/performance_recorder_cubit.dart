import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:daw_export/daw_export.dart';
import 'package:equatable/equatable.dart';
import 'package:performance_repository/performance_repository.dart';

part 'performance_recorder_state.dart';

/// Drives performance-recording's full app-facing lifecycle: arming/disarming
/// [PerformanceRepository], the offline render + `.als`/`fx-chains.txt`
/// pipeline once a capture finalizes, and kicking off boot-time silent
/// crash-recovery salvage (D-SALVAGE, #679).
///
/// State transitions for a *live* arm/disarm are driven reactively off
/// [PerformanceRepository.captureStatus] rather than from [toggleArm]'s own
/// call sites — `SessionCubit` also calls [PerformanceRepository.disarm]
/// directly (auto-disarm-before-load), and this cubit must reflect that too.
/// Boot-salvage ([load]) is the one path the status stream never reports
/// (`recoverCapture` has no live session to disarm) — deliberately: it runs
/// silently in the repository's background, emitting no state at all.
///
/// The manifest → [DawProject] mapping stays inside `daw_export`
/// ([DawManifestReader]) — this cubit only decides *when* to call it and
/// writes the resulting bytes to disk, keeping `daw_export` itself free of
/// write-side I/O.
class PerformanceRecorderCubit extends Cubit<PerformanceRecorderState> {
  /// Creates a [PerformanceRecorderCubit] driving [performance].
  ///
  /// [armedTickInterval] paces the [PerformanceRecorderArmed] elapsed-time
  /// readout; [renderPollInterval] paces polling
  /// [PerformanceRepository.renderProgress] after a disarm. [now] supplies
  /// the double-press-guard clock; injectable for deterministic tests.
  ///
  /// [freeSpaceBytes] answers "how much room is left on this volume", and
  /// defaults to [PerformanceRepository.freeSpaceBytes] — a `statvfs` through
  /// the engine. It used to shell out to `df`, and that turned out to be the
  /// single most expensive thing on the appliance's real-time path: a capture
  /// re-checks its volume every twenty ticks, `Process.run` is fork() + exec(),
  /// and fork() holds the process's `mmap_lock` for write for milliseconds
  /// while it copies a 1.7 GB address space's page tables. On the Pi 5 bench
  /// every audible dropout landed within 3 ms of one of those forks (#806).
  /// Still injectable, and still narrow — the tests that model a filling disk
  /// pass their own function and are unaffected.
  ///
  /// The `.als` export's tempo needs no dependency here at all (#281):
  /// `performance.json` persists the tempo D6 had locked in by disarm
  /// (`PerformanceDisarmSnapshot.tempoBpm`, arm-time copy for crash
  /// salvage), and `DawManifestReader.read` resolves it from the manifest
  /// itself — falling back to its own fixed 120 BPM for a bundle carrying
  /// none (written before the field existed, or captured with no tempo set),
  /// where the live transport tempo at export time would be an arbitrary
  /// value unrelated to the take anyway.
  ///
  /// [currentChains] resolves the REAL lane/monitor effect chains and
  /// master-limiter state to stamp into the arm snapshot
  /// ([PerformanceRepository.arm]'s `chains`), read fresh at each arm — a
  /// narrow function dependency (matching [now]/[freeSpaceBytes]'s own
  /// pattern here), since the mapping
  /// from the live rig lives in the session feature rather than in this cubit.
  /// Defaults to the empty snapshot (what every call site passed before this
  /// was wired); the composition root (`lib/app/view/app.dart`) supplies
  /// `performanceChainsFromLooper` over the live `LooperRepository`.
  PerformanceRecorderCubit({
    required PerformanceRepository performance,
    Duration armedTickInterval = const Duration(milliseconds: 250),
    Duration renderPollInterval = const Duration(milliseconds: 200),
    DateTime Function() now = DateTime.now,
    Future<int?> Function(String path)? freeSpaceBytes,
    PerformanceChains Function() currentChains = _noChains,
  }) : _performance = performance,
       _armedTickInterval = armedTickInterval,
       _renderPollInterval = renderPollInterval,
       _now = now,
       _freeSpaceBytes =
           freeSpaceBytes ??
           ((String path) async => performance.freeSpaceBytes(path)),
       _currentChains = currentChains,
       super(const PerformanceRecorderIdle()) {
    _statusSubscription = _performance.captureStatus.listen(_onStatus);
  }

  /// The default `currentChains`: an empty rig, which is what
  /// [PerformanceRepository.arm] already assumes when given nothing.
  static PerformanceChains _noChains() => const PerformanceChains();

  /// Below this, [PerformanceRecorderArmed.lowDiskWarning] is set (D-FAIL),
  /// and an arm is refused outright rather than started onto a volume that is
  /// already in trouble.
  static const int lowDiskThresholdBytes = 500 * 1024 * 1024;

  /// Slack above the finalize's own requirement, for the manifest, the WAV
  /// headers, and the few seconds of capture still landing between one
  /// free-space sample and the stop taking effect.
  ///
  /// A *fixed* floor was the first attempt and it was the wrong shape.
  /// Finalize does not write "headers and a manifest" — it writes a **full
  /// second copy** of every captured stream as WAV, keeping the `.pcm`
  /// alongside it. Measured on the appliance at 96 kHz: 384 KB/s per stream,
  /// three continuous streams (two inputs plus master), so a 20-minute capture
  /// is ~1.4 GB of `.pcm` needing ~1.4 GB more to finalize. Any constant would
  /// be either uselessly large for a short take or catastrophically small for
  /// a long one — and being small at the end of a long set means losing
  /// exactly the take worth keeping.
  static const int finalizeHeadroomBytes = 64 * 1024 * 1024;

  /// Free bytes a running capture needs to stop safely: room to duplicate what
  /// it has already written, plus [finalizeHeadroomBytes].
  ///
  /// Deliberately covers the finalize only, not the stem/`.als` render that
  /// follows. Guaranteeing the render too would need several times this and
  /// would cut captures short on a constrained disk; the render degrades
  /// cleanly instead (see [_writeDawExports]) and is re-runnable from the
  /// finished bundle.
  static int stopFloorFor(int capturedBytes) =>
      capturedBytes + finalizeHeadroomBytes;

  /// Armed ticks between free-space samples.
  ///
  /// The tick is 250ms and the sample shells out to `df`, so checking every
  /// tick would spawn four processes a second for the whole capture. At 20 the
  /// volume is read every ~5s — far finer than a disk fills, and cheap enough
  /// to leave running for hours.
  static const int _diskCheckEveryTicks = 20;

  final PerformanceRepository _performance;
  final DateTime Function() _now;
  final Future<int?> Function(String path) _freeSpaceBytes;
  final PerformanceChains Function() _currentChains;

  /// How often [PerformanceRecorderArmed.elapsed] refreshes while armed.
  final Duration _armedTickInterval;

  /// How often [PerformanceRepository.renderProgress] is polled after
  /// disarm.
  final Duration _renderPollInterval;

  late final StreamSubscription<PerformanceCaptureStatus> _statusSubscription;
  Timer? _armedTicker;
  Timer? _renderPoller;
  Timer? _recoveringPoller;
  String? _captureDir;
  DateTime? _armedAt;
  bool _lowDiskAtArm = false;
  int _ticksSinceDiskCheck = 0;
  bool _stoppingForDisk = false;

  /// Whether any armed tick saw dropped capture frames — see
  /// [PerformanceRecorderCompleted.hadGlitch]. Reset on every arm.
  bool _sawOverrun = false;

  /// How long the finished capture ran, measured in [_afterFinalized] —
  /// `Completed` is emitted later, from [_finishRender], by which point
  /// `_armedAt` is already gone.
  Duration? _completedDuration;

  /// The last path segment — captures live in a folder named after the take.
  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  /// Why this capture stopped, when the cubit itself stopped it. Preferred
  /// over the manifest's marker, which only the engine's own self-stop writes.
  PerformanceStopReason? _stopReason;
  bool _loaded = false;

  /// Silently salvages any capture a crash left unfinalized (D-SALVAGE,
  /// #679): [PerformanceRepository.runBootRecovery] finalizes + renders each
  /// one in the background into the repository's `recovered/` area (pruned
  /// there after [PerformanceRepository.recoveredRetention]) — no prompt and
  /// no dialog-triggering state. The one thing surfaced is the honest busy
  /// fact: while there is actual salvage work, idle carries
  /// [PerformanceRecorderIdle.recovering] so the record button can disable
  /// instead of looking alive while the repository's in-flight gates
  /// silently refuse every press. The composition root calls this unawaited
  /// at boot; [PerformanceRepository.arm]'s own gates (#671) cover the
  /// pedal for as long as the background finalize/render runs. Latched —
  /// safe to call once at boot.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    // Probed first so a clean boot (the overwhelmingly common case) emits
    // nothing at all — the recovering flag only ever shows for real work.
    // The probe counts stranded bundles too, not just crashed captures: a
    // stranded-only boot re-runs a stem render that holds arm's gates just
    // as long (#679 r4).
    bool hasWork;
    try {
      hasWork = await _performance.hasBootRecoveryWork();
    } on Exception {
      hasWork = false; // unreadable root: runBootRecovery no-ops on it too
    }
    if (hasWork) _emit(const PerformanceRecorderIdle(recovering: true));
    try {
      await _performance.runBootRecovery();
    } finally {
      // In a finally so the flag can never wedge true past this call: if
      // recovery itself blew up (a genuine bug escaping its guards), a
      // permanently-disabled record button must not be the second casualty.
      _clearRecoveringWhenRenderSettles();
    }
  }

  /// Clears the [PerformanceRecorderIdle.recovering] flag this cubit's
  /// [load] set — but only once [PerformanceRepository.renderProgress]
  /// actually reads done. A timed-out salvage render outlives
  /// `runBootRecovery` and keeps holding [PerformanceRepository.arm]'s
  /// render gate, so clearing the flag on return would re-enable a button
  /// whose every press is silently refused — the exact invisible refusal
  /// the flag exists to prevent. While the render is still live this polls
  /// at the same cadence as the post-disarm render poll, keeping the flag
  /// (and the disabled button) up until arming genuinely works again.
  /// Only ever clears the exact state [load] set — anything else on screen
  /// is not this method's to stomp.
  void _clearRecoveringWhenRenderSettles() {
    const recovering = PerformanceRecorderIdle(recovering: true);
    if (state != recovering) return;
    if (_performance.renderProgress.done) {
      _emit(const PerformanceRecorderIdle());
      return;
    }
    _recoveringPoller?.cancel();
    _recoveringPoller = Timer.periodic(_renderPollInterval, (timer) {
      if (isClosed || state != recovering) {
        timer.cancel();
        return;
      }
      if (!_performance.renderProgress.done) return;
      timer.cancel();
      _emit(const PerformanceRecorderIdle());
    });
  }

  /// Renames the just-delivered capture to [to] (D-NAME) — the completion
  /// sheet's rename action. A no-op when not currently
  /// [PerformanceRecorderCompleted] with a delivered result. Rethrows
  /// [ArgumentError] / [PerformanceNameCollision] so the caller can show an
  /// inline error, same as `SessionCubit.renameSession`'s callers.
  Future<void> renameCompletedCapture(String to) async {
    final current = state;
    if (current is! PerformanceRecorderCompleted) return;
    final result = current.result;
    if (result == null) return;
    final oldPath = switch (result) {
      PerformanceRecordDone(:final path) => path,
      PerformanceRecordPartial(:final path) => path,
      PerformanceRecordStoppedEarly(:final path) => path,
    };
    final newPath = await _performance.renameCapture(oldPath, to);
    final renamed = switch (result) {
      PerformanceRecordDone() => PerformanceRecordDone(newPath),
      PerformanceRecordPartial() => PerformanceRecordPartial(newPath),
      PerformanceRecordStoppedEarly(:final reason) =>
        PerformanceRecordStoppedEarly(
          newPath,
          reason,
        ),
    };
    _emit(
      PerformanceRecorderCompleted(
        renamed,
        tracks: current.tracks,
        duration: current.duration,
        hadGlitch: current.hadGlitch,
      ),
    );
  }

  /// Arms or disarms depending on the current state; a no-op while
  /// finalizing/rendering (no queue). That refusal is enforced
  /// authoritatively by [PerformanceRepository.arm] itself (#671) — that gate
  /// also covers the pedal's MODE long-press, which never passes through this
  /// cubit, and the boot-time background salvage (which runs entirely inside
  /// the repository with no state here to key a refusal off) — but the case
  /// here is not redundant: falling through to the arm
  /// branch would run the free-space probe and could emit a `lowDiskBlocked`
  /// idle state over the on-screen render progress, so refusing before it is
  /// UX-load-bearing. A settled [PerformanceRecorderCompleted] (delivered or
  /// auto-discarded-short alike) arms a fresh capture exactly like
  /// [PerformanceRecorderIdle] does — [PerformanceRepository.arm] has no
  /// precondition beyond not already being armed, so there is no need to
  /// route back through an explicit idle state first. The double-press guard
  /// (a disarm within 1s of arming is ignored — the arm and disarm gestures
  /// are easy to fat-finger back to back on the same control) lives in
  /// [PerformanceRepository.disarm] itself (D-GUARD), shared by every
  /// caller — this cubit's toolbar path and `ControlCubit`'s pedal
  /// MODE-long-press path alike — rather than duplicated here.
  Future<void> toggleArm() async {
    switch (state) {
      // Refused before the free-space probe, same reasoning as the
      // finalizing/rendering case: the repository's gate would silently
      // refuse the arm anyway, but falling through would let a probe emit
      // `lowDiskBlocked` over the recovering flag, blinding the button.
      case PerformanceRecorderIdle(recovering: true):
        break;
      case PerformanceRecorderIdle():
      case PerformanceRecorderCompleted():
        if (await _volumeTooFullToArm()) {
          _emit(const PerformanceRecorderIdle(lowDiskBlocked: true));
          return;
        }
        await _performance.arm(chains: _currentChains());
      case PerformanceRecorderArmed():
        await _performance.disarm();
      case PerformanceRecorderFinalizing():
      case PerformanceRecorderRendering():
        break;
    }
  }

  void _onStatus(PerformanceCaptureStatus status) {
    switch (status) {
      case PerformanceCaptureStatus.idle:
        break; // only ever the initial replay; nothing to react to yet
      case PerformanceCaptureStatus.armed:
        _captureDir = _performance.armedDirectory;
        _armedAt = _now();
        _sawOverrun = false;
        _lowDiskAtArm = false;
        _ticksSinceDiskCheck = 0;
        _stoppingForDisk = false;
        // Cleared on arm, not only in _finishRender: the short-empty path in
        // _afterFinalized emits `discardedShort` and returns before ever
        // reaching that reset, so a disk-stop on a capture too short to keep
        // would leave the reason set and the NEXT capture would report itself
        // as stopped-for-disk on a perfectly healthy volume.
        _stopReason = null;
        _armedTicker?.cancel();
        _emitArmedTick();
        _armedTicker = Timer.periodic(
          _armedTickInterval,
          (_) => _emitArmedTick(),
        );
        unawaited(_checkLowDisk(_captureDir));
      case PerformanceCaptureStatus.finalizing:
        _armedTicker?.cancel();
        _armedTicker = null;
        _emit(const PerformanceRecorderFinalizing());
      case PerformanceCaptureStatus.done:
        // One last read, and the only one that can see the whole capture.
        // The armed ticker stopped at `finalizing`, but the drain thread's
        // FINAL cycle — the one disarm joins, which flushes everything still
        // buffered — runs after that, so it can silence-fill frames no armed
        // tick ever sampled. `done` is emitted strictly after that join, and
        // the counters survive disarm (they reset on the next arm), so this
        // reads the complete total. Without it a glitch in the closing
        // quarter-second finalized as a clean take (#710).
        if (_performance.captureProgress.overrun) _sawOverrun = true;
        unawaited(_afterFinalized());
    }
  }

  void _emitArmedTick() {
    // Re-sample the volume periodically. The old behaviour checked once at arm
    // and carried that answer for the whole session, which is how a capture
    // that armed onto a healthy disk ran 13.5 hours and filled 110GB unnoticed
    // (#640) — the disk was fine at arm, and nothing ever looked again.
    if (++_ticksSinceDiskCheck >= _diskCheckEveryTicks) {
      _ticksSinceDiskCheck = 0;
      unawaited(_checkLowDisk(_captureDir));
    }
    final progress = _performance.captureProgress;
    // The engine stopped writing on its own — a failed write, which the
    // free-space floor cannot predict: a quota, a read-only remount, an I/O
    // error, or a volume filled by something else between two samples. Until
    // this was published the thread died silently and the capture stayed
    // "armed" forever with its handles open (#652).
    if (progress.selfStopped) {
      unawaited(_stopForLowDisk());
      return;
    }
    // Latched, not just displayed: the overrun counter lives on the live
    // snapshot, which is gone by the time the capture completes — the
    // completion dialog's glitch banner needs the fact carried across.
    if (progress.overrun) _sawOverrun = true;
    _emit(
      PerformanceRecorderArmed(
        elapsed: progress.elapsed,
        overrun: progress.overrun,
        lowDiskWarning: _lowDiskAtArm,
      ),
    );
  }

  /// Whether the export volume is already too full to start a capture.
  ///
  /// Gated at [lowDiskThresholdBytes] rather than [stopFloorFor]: arming into
  /// the band that would immediately trip the in-flight stop is worse than a
  /// refusal, because it costs a bundle directory and a finalize to end up in
  /// the same place. An unanswerable volume (Windows, or `df` failing) arms as
  /// before — this gate only ever acts on a number it actually has.
  Future<bool> _volumeTooFullToArm() async {
    final String root;
    try {
      root = await _performance.exportsRoot();
    } on Object {
      return false; // cannot resolve the root: not this gate's call to block
    }
    final free = await _freeSpaceBytes(root);
    return free != null && free < lowDiskThresholdBytes;
  }

  Future<void> _checkLowDisk(String? dir) async {
    if (dir == null) return;
    final free = await _freeSpaceBytes(dir);
    // A platform that cannot answer (Windows, or df failing) must not be read
    // as "no space" — that would stop every capture on it.
    if (free == null) return;
    if (free < stopFloorFor(_capturedBytes(dir))) {
      await _stopForLowDisk();
      return;
    }
    _lowDiskAtArm = free < lowDiskThresholdBytes;
    if (state is PerformanceRecorderArmed) _emitArmedTick();
  }

  /// Bytes this capture has written so far — what finalize will have to
  /// duplicate as WAV.
  ///
  /// Summed from the directory rather than estimated from elapsed time and a
  /// bitrate: the stream count varies with the rig (armed inputs, layers per
  /// loop), so a time-based guess would drift exactly on the big multi-track
  /// captures where being wrong costs the most. Runs on the ~5s sample, not
  /// per tick, so walking a few dozen entries is not a hot path.
  int _capturedBytes(String dir) {
    try {
      var total = 0;
      // Recursive: the bundle has `loops/` and `stems/` beneath it. Those are
      // populated at finalize rather than during capture today, so a flat walk
      // happens to be correct right now — but it would undercount silently the
      // moment anything lands in a subdirectory mid-capture, and undercounting
      // is precisely how the floor collapses to nothing.
      for (final entry in Directory(dir).listSync(recursive: true)) {
        if (entry is File) total += entry.lengthSync();
      }
      return total;
    } on FileSystemException {
      // Unreadable mid-capture: fall back to the headroom alone rather than
      // reporting 0 and letting the floor collapse to nothing.
      return 0;
    }
  }

  /// Stops a running capture and finalizes what it has, so the take is a
  /// playable bundle rather than orphaned `.pcm`.
  ///
  /// Two triggers, one path: the free-space floor ([stopFloorFor]) crossing
  /// PREVENTIVELY, and the engine's own drain reporting it already died on a
  /// failed write. The second is the case the floor cannot see coming, and the
  /// reason is recorded here either way because the engine's sidecar marker is
  /// only written on its own self-stop.
  ///
  /// Goes through [PerformanceRepository.disarmAndFinalize], not
  /// [PerformanceRepository.disarm]: this is not the operator's toggle
  /// gesture, so it must not be swallowed by the double-press guard that path
  /// applies.
  Future<void> _stopForLowDisk() async {
    if (_stoppingForDisk) return; // a slow finalize must not re-enter
    _stoppingForDisk = true;
    _armedTicker?.cancel();
    _armedTicker = null;
    // Remembered here because the engine's own `stopped_early` marker is
    // written by perf_drain.c only when IT self-stops on a failed write. This
    // stop happens before any write fails, so the manifest carries no marker
    // and _readStoppedEarly would report a plain success.
    _stopReason = PerformanceStopReason.diskFull;
    await _performance.disarmAndFinalize();
  }

  Future<void> _afterFinalized() async {
    final dir = _captureDir;
    final armedAt = _armedAt;
    _armedAt = null;
    if (dir == null) return;
    final elapsed = armedAt == null
        ? Duration.zero
        : _now().difference(armedAt);
    // Null rather than zero when there was no armed-at to measure from (a
    // recovered boot capture): the dialog drops the figure instead of
    // printing 0:00 for a take that plainly ran longer.
    _completedDuration = armedAt == null ? null : elapsed;
    if (_isShortEmptyCapture(dir, elapsed)) {
      // The offline render already started in the background (disarm's own
      // fire-and-forget) — deleting the directory here only wastes its
      // in-flight writes (the renderer only ever writes files, never asserts
      // the directory still exists between writes), so this race is benign.
      await _performance.discardUnfinalized(dir);
      _captureDir = null;
      _emit(const PerformanceRecorderCompleted.discardedShort());
      return;
    }
    await _runRenderPipeline(dir);
  }

  bool _isShortEmptyCapture(String dir, Duration elapsed) {
    if (elapsed >= const Duration(seconds: 2)) return false;
    final entries = EventLogReader.readAll(dir);
    return entries == null || entries.isEmpty;
  }

  Future<void> _runRenderPipeline(String dir) async {
    _emit(PerformanceRecorderRendering(percent: 0, name: _basename(dir)));
    final completer = Completer<void>();
    _renderPoller?.cancel();
    _renderPoller = Timer.periodic(_renderPollInterval, (_) {
      _pollRender(dir, completer);
    });
    _pollRender(dir, completer);
    return completer.future;
  }

  void _pollRender(String dir, Completer<void> completer) {
    if (completer.isCompleted) return;
    final progress = _performance.renderProgress;
    _emit(
      PerformanceRecorderRendering(
        percent: progress.progressPercent,
        name: _basename(dir),
      ),
    );
    if (!progress.done) return;
    _renderPoller?.cancel();
    unawaited(_finishRender(dir).whenComplete(completer.complete));
  }

  Future<void> _finishRender(String dir) async {
    // A full volume must not take the capture down with it. Observed on the
    // appliance: `writeFrom failed ... No space left on device` escaped
    // _writeDawExports, and because it is awaited on this method's FIRST line
    // the `PerformanceRecorderCompleted` emit on its last never ran — the
    // console sat in `Rendering` forever and never reported that the capture
    // had stopped at all (#640).
    //
    // The take is already safe by this point: finalize wrote the WAVs and the
    // manifest before the render started. The export is the only casualty, and
    // it is re-runnable from the finished bundle via [reExport] — which is why
    // the catch lives here and not inside _writeDawExports, whose throwing is
    // how that path detects its own failure.
    List<DawTrack> tracks;
    try {
      tracks = await _writeDawExports(dir);
    } on FileSystemException {
      tracks = const [];
    }
    _captureDir = null;
    final anyFailed = _performance.renderTrackStatuses.any((s) => !s.succeeded);
    final manifest = _readManifest(dir);
    final stoppedEarly = _stopReason ?? _stopReasonOf(manifest);
    _stopReason = null;
    // Belt to the `done`-time snapshot read's braces (#710). The engine's
    // counters are live state: a device change reconfigures the engine on the
    // way to finalize, and any future teardown ordering could do the same.
    // The sidecar is the durable record of what the drain actually wrote, so
    // a take whose silence only survives there still finalizes honestly.
    if ((manifest?.zeroFilledFrames ?? 0) > 0) _sawOverrun = true;
    final PerformanceRecordResult result;
    if (stoppedEarly != null) {
      result = PerformanceRecordStoppedEarly(dir, stoppedEarly);
    } else if (anyFailed) {
      result = PerformanceRecordPartial(dir);
    } else {
      result = PerformanceRecordDone(dir);
    }
    _emit(
      PerformanceRecorderCompleted(
        result,
        tracks: tracks,
        duration: _completedDuration,
        hadGlitch: _sawOverrun,
      ),
    );
  }

  /// Re-runs `.als`/`fx-chains.txt` generation from the capture directory's
  /// already-persisted `performance.json` — no engine, no re-render, no
  /// audio-file writes
  /// (part 11, D-REEXPORT). Useful after installing Segno's VST3 plugins (a
  /// fresh export can then resolve a live device chain a prior export
  /// couldn't, though resolution itself never depended on local plugin
  /// installation — only on the manifest's own effects data) or simply to
  /// regenerate without re-recording. A no-op when not currently
  /// [PerformanceRecorderCompleted] with a delivered result, mirroring
  /// [renameCompletedCapture]'s own guard. Failures (a malformed manifest
  /// `buildAls` rejects, or a file-write error) are caught and surfaced via
  /// [PerformanceRecorderCompleted.reExportFailed] rather than left
  /// uncaught — this is a user-triggered background action, not something
  /// that should crash the cubit.
  Future<void> reExport() async {
    final current = state;
    if (current is! PerformanceRecorderCompleted) return;
    final result = current.result;
    if (result == null) return;
    final dir = switch (result) {
      PerformanceRecordDone(:final path) => path,
      PerformanceRecordPartial(:final path) => path,
      PerformanceRecordStoppedEarly(:final path) => path,
    };
    _emit(
      PerformanceRecorderCompleted(
        result,
        tracks: current.tracks,
        isReExporting: true,
        duration: current.duration,
        hadGlitch: current.hadGlitch,
      ),
    );
    try {
      final tracks = await _writeDawExports(dir);
      _emit(
        PerformanceRecorderCompleted(
          result,
          tracks: tracks,
          duration: current.duration,
          hadGlitch: current.hadGlitch,
        ),
      );
    } on Object {
      _emit(
        PerformanceRecorderCompleted(
          result,
          tracks: current.tracks,
          reExportFailed: true,
          duration: current.duration,
          hadGlitch: current.hadGlitch,
        ),
      );
    }
  }

  /// Reads [dir]'s manifest and writes `.als`/`fx-chains.txt` from it,
  /// returning the resolved [DawTrack]s (empty when the manifest couldn't be
  /// read) for the caller to carry on [PerformanceRecorderCompleted.tracks].
  Future<List<DawTrack>> _writeDawExports(String dir) async {
    // Deliberately NOT catching here. [reExport] distinguishes success from
    // failure precisely by whether this throws, and swallowing it there would
    // report a failed re-export as a success. The capture-completion path
    // guards at its own call site instead — see [_finishRender].
    // Tempo comes from the manifest itself (#281): DawManifestReader.read
    // resolves the capture's own persisted disarm-time (arm-time for a
    // crash salvage) tempo, falling back to its fixed 120 BPM for a bundle
    // carrying none.
    final project = DawManifestReader.read(dir);
    if (project != null) {
      await File('$dir/project.als').writeAsBytes(buildAls(project));
    }
    final chains = FxChainsWriter.render(dir);
    if (chains != null) {
      await File('$dir/fx-chains.txt').writeAsString(chains);
    }
    return project?.tracks ?? const [];
  }

  /// The finalized capture's own sidecar, or `null` when it is missing or
  /// unparseable. The durable record of what the drain thread actually did —
  /// unlike the engine's live counters, it survives a reconfigure.
  PerformanceManifest? _readManifest(String dir) {
    final manifestFile = File('$dir/${PerformanceRepository.manifestName}');
    if (!manifestFile.existsSync()) return null;
    try {
      return PerformanceManifest.fromJson(
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>,
      );
    } on FormatException {
      return null;
    }
  }

  PerformanceStopReason? _stopReasonOf(PerformanceManifest? manifest) =>
      switch (manifest?.stoppedEarly) {
        'disk_full' => PerformanceStopReason.diskFull,
        'device_changed' => PerformanceStopReason.deviceChanged,
        _ => null,
      };

  void _emit(PerformanceRecorderState next) {
    if (isClosed) return;
    emit(next);
  }

  @override
  Future<void> close() {
    _armedTicker?.cancel();
    _renderPoller?.cancel();
    _recoveringPoller?.cancel();
    unawaited(_statusSubscription.cancel());
    return super.close();
  }
}
