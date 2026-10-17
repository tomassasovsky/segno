import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/record_length.dart';

/// Global record-behavior options applied to the [LooperRepository].
class RecordOptions extends Equatable {
  /// Creates a [RecordOptions].
  const RecordOptions({
    this.recDub = false,
    this.defaultMultiple = 0,
    this.defaultLengthBars = 0,
    this.recordLengthReady = false,
    this.trackLengthPresetOverrides = const {},
    this.recordLengthMode = LooperMode.multi,
    this.recordLengthCaptureLocked = false,
  });

  /// When `true`, a record press finalizing a recording continues into overdub
  /// instead of playback (the second-press "rec/dub" mode).
  final bool recDub;

  /// The global default loop length used by inheriting tracks (`0` = auto).
  final int defaultMultiple;

  /// The default length preset for a defining recording (`0` = Auto, else
  /// `1..64` bars; accepted design, Length & quantize). Tracks follow it
  /// unless they carry their own override.
  final int defaultLengthBars;
  final bool recordLengthReady;
  final Map<int, int> trackLengthPresetOverrides;
  final LooperMode recordLengthMode;
  final bool recordLengthCaptureLocked;

  /// Accepted future-recording presets, unavailable until initialized.
  RecordLengthSnapshot? get recordLengthSnapshot => recordLengthReady
      ? RecordLengthSnapshot(
          defaultBars: defaultLengthBars,
          trackOverrides: trackLengthPresetOverrides,
          mode: recordLengthMode,
          captureLocked: recordLengthCaptureLocked,
        )
      : null;

  /// Returns a copy with the given overrides.
  RecordOptions copyWith({
    bool? recDub,
    int? defaultMultiple,
    int? defaultLengthBars,
    bool? recordLengthReady,
    Map<int, int>? trackLengthPresetOverrides,
    LooperMode? recordLengthMode,
    bool? recordLengthCaptureLocked,
  }) => RecordOptions(
    recDub: recDub ?? this.recDub,
    defaultMultiple: defaultMultiple ?? this.defaultMultiple,
    defaultLengthBars: defaultLengthBars ?? this.defaultLengthBars,
    recordLengthReady: recordLengthReady ?? this.recordLengthReady,
    trackLengthPresetOverrides:
        trackLengthPresetOverrides ?? this.trackLengthPresetOverrides,
    recordLengthMode: recordLengthMode ?? this.recordLengthMode,
    recordLengthCaptureLocked:
        recordLengthCaptureLocked ?? this.recordLengthCaptureLocked,
  );

  @override
  List<Object?> get props => [
    recDub,
    defaultMultiple,
    defaultLengthBars,
    recordLengthReady,
    trackLengthPresetOverrides,
    recordLengthMode,
    recordLengthCaptureLocked,
  ];
}
