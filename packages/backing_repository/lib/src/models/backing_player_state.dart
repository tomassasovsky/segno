import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart';

/// The backing player as the repository presents it: the engine's voice
/// mapped back to asset digests, plus what the repository is doing.
class BackingPlayerState extends Equatable {
  /// Creates a [BackingPlayerState].
  const BackingPlayerState({
    this.loaded,
    this.staged,
    this.loading,
    this.transport = BackingTransport.stopped,
    this.position = 0,
    this.frames = 0,
    this.sampleRate = 0,
    this.endMode = BackingEnd.stop,
    this.level = 1,
    this.pan = 0,
    this.outputMask = 0,
    this.lastEnd = BackingEndEvent.none,
    this.endCount = 0,
  });

  /// The loaded asset's digest, or null.
  final String? loaded;

  /// The staged (End = Next) asset's digest, or null.
  final String? staged;

  /// The asset a load is decoding, or null: what `Loading <name>…` names.
  final String? loading;

  /// The transport.
  final BackingTransport transport;

  /// Frames into the loaded file.
  final int position;

  /// The loaded file's length in frames.
  final int frames;

  /// The engine rate the frames are counted at (0 when not running).
  final int sampleRate;

  /// The End setting.
  final BackingEnd endMode;

  /// The backing gain, 0 to 2.
  final double level;

  /// The backing balance, -1 to 1.
  final double pan;

  /// The output channel mask.
  final int outputMask;

  /// What the latest end of a file did.
  final BackingEndEvent lastEnd;

  /// Bumps on every end of a file.
  final int endCount;

  /// Whether the loaded file is sounding.
  bool get playing => transport == BackingTransport.playing;

  /// The position as a duration.
  Duration get positionTime => _time(position);

  /// The loaded file's length as a duration.
  Duration get length => _time(frames);

  Duration _time(int f) => sampleRate > 0
      ? Duration(microseconds: f * Duration.microsecondsPerSecond ~/ sampleRate)
      : Duration.zero;

  /// A copy with the given fields replaced; [loading] and the digests are
  /// cleared by passing null through the `clear*` flags.
  BackingPlayerState copyWith({
    String? loaded,
    bool clearLoaded = false,
    String? staged,
    bool clearStaged = false,
    String? loading,
    bool clearLoading = false,
    BackingTransport? transport,
    int? position,
    int? frames,
    int? sampleRate,
    BackingEnd? endMode,
    double? level,
    double? pan,
    int? outputMask,
    BackingEndEvent? lastEnd,
    int? endCount,
  }) => BackingPlayerState(
    loaded: clearLoaded ? null : loaded ?? this.loaded,
    staged: clearStaged ? null : staged ?? this.staged,
    loading: clearLoading ? null : loading ?? this.loading,
    transport: transport ?? this.transport,
    position: position ?? this.position,
    frames: frames ?? this.frames,
    sampleRate: sampleRate ?? this.sampleRate,
    endMode: endMode ?? this.endMode,
    level: level ?? this.level,
    pan: pan ?? this.pan,
    outputMask: outputMask ?? this.outputMask,
    lastEnd: lastEnd ?? this.lastEnd,
    endCount: endCount ?? this.endCount,
  );

  @override
  List<Object?> get props => [
    loaded,
    staged,
    loading,
    transport,
    position,
    frames,
    sampleRate,
    endMode,
    level,
    pan,
    outputMask,
    lastEnd,
    endCount,
  ];
}

/// Something the player wants the performer told (rule 3: no silent change).
enum BackingNotice {
  /// The audio interface changed (a configure or a reopen) while the backing
  /// was playing; it stopped, and was reloaded at the new rate if needed.
  interfaceChanged,
}
