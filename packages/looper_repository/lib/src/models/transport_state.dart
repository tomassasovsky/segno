import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart';

/// The master loop transport plus the tempo grid, click, and count-in state
/// (plan A1/A2; `2026-07-22-feat-tempo-aware-looper-modes-plan.md`).
///
/// With the grid at every default (no tempo ever set, click off, count-in
/// off) this mirrors the tempo-free transport exactly — the fields are
/// additive, direct projections of [EngineSnapshot]'s tempo-grid fields.
class TransportState extends Equatable {
  /// Creates a [TransportState].
  const TransportState({
    this.isRunning = false,
    this.masterLengthFrames = 0,
    this.masterPositionFrames = 0,
    this.tempoBpm = 0,
    this.tempoSource = TempoSource.none,
    this.tsNum = 4,
    this.tsDen = 4,
    this.syncTempo = true,
    this.quantizeDiv = GridDivision.off,
    this.loopBars = 0,
    this.currentBeat = 0,
    this.clickMode = ClickMode.off,
    this.clickMask = 0,
    this.clickVolume = 1,
    this.countInBars = 0,
    this.countingIn = false,
    this.countInBeatsLeft = 0,
    this.looperMode = LooperMode.multi,
    this.primaryTrack = -1,
    this.outputPeak = 0,
    this.recDub = false,
    this.quantize = false,
    this.autoRecord = false,
    this.overdubDecay = 0,
    this.recordTiming = RecordTiming.immediately,
  });

  /// Whether the audio device is open and processing.
  final bool isRunning;

  /// Master loop length in frames; `0` before the first loop is finalized.
  final int masterLengthFrames;

  /// Current master loop playhead in frames.
  final int masterPositionFrames;

  /// Denominator-note beats per minute; `0` when [tempoSource] is
  /// [TempoSource.none] (no tempo ever set).
  final double tempoBpm;

  /// Where [tempoBpm] came from (D7 precedence).
  final TempoSource tempoSource;

  /// Time-signature numerator (default `4`).
  final int tsNum;

  /// Time-signature denominator, `4` or `8` (default `4`).
  final int tsDen;

  /// Whether loop↔grid sync is on (default `true`).
  final bool syncTempo;

  /// Musical quantization granularity (default [GridDivision.off]).
  final GridDivision quantizeDiv;

  /// Whole bars in the master loop, or `0` when no grid relationship exists.
  final int loopBars;

  /// Beat index (`0..tsNum-1`) within the bar; `0` when idle.
  final int currentBeat;

  /// Click audibility mode (default [ClickMode.off]).
  final ClickMode clickMode;

  /// Bitmask of hardware output channels the click sounds on. Default `0`.
  final int clickMask;

  /// Click volume in `0..LE_MAX_GAIN` (default `1`).
  final double clickVolume;

  /// Count-in length in measures; `0` = off (default). The repository's
  /// held value (slice 2b), which a Sound start clears (D9) and which reads
  /// right while the engine is stopped.
  final int countInBars;

  /// Whether a count-in is currently running.
  final bool countingIn;

  /// Beat countdown while counting in; `0` when idle.
  final int countInBeatsLeft;

  /// The five-mode axis (default [LooperMode.multi]). Locked (rejected,
  /// no-op) while any track has content (D4). No semantics beyond the field
  /// exist yet for the non-multi values (B2a — see [LooperMode]'s class doc).
  final LooperMode looperMode;

  /// The crowned track every surface draws, or `-1` for an empty session.
  ///
  /// The first completed recording is crowned; a later, lower-numbered take
  /// or a selection never moves it, an explicit handoff does. Resolved from
  /// the engine's designation ([EngineSnapshot.primaryTrack]) so it always
  /// names a track that holds a completed take — see
  /// `resolvedPrimaryTrack`.
  final int primaryTrack;

  /// Master-bus absolute peak for the most recent block, in `0..1`, after the
  /// master gain and limiter — what reaches the outputs. Moves at the poll
  /// rate while audio flows, like [masterPositionFrames].
  final double outputPeak;

  /// The rec/dub second-press setting the repository holds and re-applies to
  /// the engine: with it on, a take's end lands the track OVERDUBBING rather
  /// than PLAYING — what a queued take-end will do.
  final bool recDub;

  /// The default record quantize gate the repository holds and re-applies:
  /// whether a record or overdub request over an existing loop waits for the
  /// grid at all. With [quantizeDiv] it names the default [recordTiming].
  final bool quantize;

  /// Whether recording starts on sound at the input (Sound start) rather
  /// than on the press. The repository's held value, which mirrors the
  /// engine's rule that a count-in clears it and it clears the count-in
  /// (D9), so this and [countInBars] never both read on.
  final bool autoRecord;

  /// The default overdub decay in percent (`0..100`): what each overdub pass
  /// removes from the existing layer before adding the new input; `0` keeps
  /// it all. Tracks inherit it unless they carry
  /// `Track.overdubDecayOverride`.
  final int overdubDecay;

  /// The default record timing the repository holds and re-applies
  /// (accepted design, Length & quantize): the one setting [quantize] and the
  /// division pair into. Held beside [quantizeDiv] (the engine's live
  /// division) rather than derived from it, so it reads right while the
  /// engine is stopped and has nothing to report.
  final RecordTiming recordTiming;

  /// Whether a master loop length has been established.
  bool get hasLoop => masterLengthFrames > 0;

  /// Normalized loop progress in `0..1`, or `0` when no loop exists.
  double get progress =>
      hasLoop ? masterPositionFrames / masterLengthFrames : 0;

  @override
  List<Object?> get props => [
    isRunning,
    masterLengthFrames,
    masterPositionFrames,
    tempoBpm,
    tempoSource,
    tsNum,
    tsDen,
    syncTempo,
    quantizeDiv,
    loopBars,
    currentBeat,
    clickMode,
    clickMask,
    clickVolume,
    countInBars,
    countingIn,
    countInBeatsLeft,
    looperMode,
    primaryTrack,
    outputPeak,
    recDub,
    quantize,
    autoRecord,
    overdubDecay,
    recordTiming,
  ];
}
