import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/record_start.dart';

/// The tempo range the engine accepts, inclusive.
///
/// `LooperRepository.setTempo` clamps to this and reports nothing, so a
/// surface that submits outside it closes on a value the rig never took.
/// Stated here so every tempo control can clamp before it writes.
const (double, double) kTempoRange = (30, 300);

/// The 17 Sheeran-verified time signatures (index plan D1): denominator `4`
/// with numerator `2..7`, denominator `8` with numerator `5..15`. Shared by
/// tempo controls and the settings picker so both agree on the valid
/// set without duplicating it.
const List<(int num, int den)> kValidTimeSignatures = [
  (2, 4),
  (3, 4),
  (4, 4),
  (5, 4),
  (6, 4),
  (7, 4),
  (5, 8),
  (6, 8),
  (7, 8),
  (8, 8),
  (9, 8),
  (10, 8),
  (11, 8),
  (12, 8),
  (13, 8),
  (14, 8),
  (15, 8),
];

/// The tempo, click and count-in settings, following repository changes such
/// as session recall. Explicit edits are also persisted as startup defaults.
class TempoState extends Equatable {
  /// Creates a [TempoState].
  const TempoState({
    this.bpm = 0,
    this.tsNum = 4,
    this.tsDen = 4,
    this.clickMode = ClickMode.off,
    this.clickModeReady = false,
    bool? clickModeInitialized,
    this.clickModeCaptureLocked = false,
    this.clickOutputMask = 0,
    this.clickVolume = 1,
    this.clickReady = false,
    this.countInBars = 0,
    this.soundStart = false,
    this.recordStartReady = false,
    bool? recordStartInitialized,
    this.recordStartCaptureLocked = false,
  }) : clickModeInitialized = clickModeInitialized ?? clickModeReady,
       recordStartInitialized = recordStartInitialized ?? recordStartReady;

  /// The tempo in BPM; `0` means no tempo has been established.
  final double bpm;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator (`4` or `8`).
  final int tsDen;

  /// Click audibility mode.
  final ClickMode clickMode;

  /// Hear click has independently initialized and has no unresolved receipt.
  final bool clickModeReady;

  /// Whether this field has ever reached an accepted initialization.
  final bool clickModeInitialized;

  /// Actual capture prevents mode editing, without locking waiting arms.
  final bool clickModeCaptureLocked;

  /// Click output routing bitmask.
  final int clickOutputMask;

  /// Click volume (`0..LE_MAX_GAIN`).
  final double clickVolume;

  /// Whether Click initialization has established an accepted value.
  final bool clickReady;

  /// Count-in length in measures (`0` = off).
  final int countInBars;

  /// Confirmed Sound-start choice, mutually exclusive with positive Count-in.
  final bool soundStart;

  /// The pair has independently initialized and has no pending recovery.
  final bool recordStartReady;

  /// Whether this field has ever reached an accepted initialization.
  final bool recordStartInitialized;

  /// Actual recording or overdubbing prevents pair edits.
  final bool recordStartCaptureLocked;

  /// Returns a copy with the given overrides.
  TempoState copyWith({
    double? bpm,
    int? tsNum,
    int? tsDen,
    ClickMode? clickMode,
    bool? clickModeReady,
    bool? clickModeInitialized,
    bool? clickModeCaptureLocked,
    int? clickOutputMask,
    double? clickVolume,
    bool? clickReady,
    int? countInBars,
    bool? soundStart,
    bool? recordStartReady,
    bool? recordStartInitialized,
    bool? recordStartCaptureLocked,
  }) => TempoState(
    bpm: bpm ?? this.bpm,
    tsNum: tsNum ?? this.tsNum,
    tsDen: tsDen ?? this.tsDen,
    clickMode: clickMode ?? this.clickMode,
    clickModeReady: clickModeReady ?? this.clickModeReady,
    clickModeInitialized: clickModeInitialized ?? this.clickModeInitialized,
    clickModeCaptureLocked:
        clickModeCaptureLocked ?? this.clickModeCaptureLocked,
    clickOutputMask: clickOutputMask ?? this.clickOutputMask,
    clickVolume: clickVolume ?? this.clickVolume,
    clickReady: clickReady ?? this.clickReady,
    countInBars: countInBars ?? this.countInBars,
    soundStart: soundStart ?? this.soundStart,
    recordStartReady: recordStartReady ?? this.recordStartReady,
    recordStartInitialized:
        recordStartInitialized ?? this.recordStartInitialized,
    recordStartCaptureLocked:
        recordStartCaptureLocked ?? this.recordStartCaptureLocked,
  );

  /// Accepted volume for controls, unavailable before initialization.
  double? get confirmedClickVolume => clickReady ? clickVolume : null;

  /// Last confirmed choice remains visible while recovery blocks editing.
  ClickMode? get confirmedClickMode => clickModeInitialized ? clickMode : null;

  /// Editable mode snapshot; pending initialization/recovery stays unavailable.
  ClickModeSnapshot? get clickModeSnapshot => clickModeReady
      ? ClickModeSnapshot(
          mode: clickMode,
          captureLocked: clickModeCaptureLocked,
        )
      : null;

  /// Last confirmed recording-start pair, including through recovery.
  RecordStartSettings? get confirmedRecordStart => recordStartInitialized
      ? RecordStartSettings(countInBars: countInBars, soundStart: soundStart)
      : null;

  /// Editable recording-start snapshot.
  RecordStartSnapshot? get recordStartSnapshot => recordStartReady
      ? RecordStartSnapshot(
          settings: confirmedRecordStart!,
          captureLocked: recordStartCaptureLocked,
        )
      : null;

  @override
  List<Object?> get props => [
    bpm,
    tsNum,
    tsDen,
    clickMode,
    clickModeReady,
    clickModeInitialized,
    clickModeCaptureLocked,
    clickOutputMask,
    clickVolume,
    clickReady,
    countInBars,
    soundStart,
    recordStartReady,
    recordStartInitialized,
    recordStartCaptureLocked,
  ];
}
