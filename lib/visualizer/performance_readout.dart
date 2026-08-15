import 'package:equatable/equatable.dart';

/// One track's line on the 7" performance readout.
class ReadoutTrack extends Equatable {
  /// Creates a [ReadoutTrack].
  const ReadoutTrack({
    required this.name,
    required this.state,
    this.muted = false,
    this.pending = false,
    this.selected = false,
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory ReadoutTrack.fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    pending: map['pending'] as bool? ?? false,
    selected: map['selected'] as bool? ?? false,
  );

  /// Display name.
  final String name;

  /// `TrackState.name` — carried as a token rather than the enum because the
  /// sub-window is a separate engine and the payload crosses a method channel.
  final String state;

  /// Muted right now.
  final bool muted;

  /// A quantized action is armed and waiting for the loop boundary — the
  /// single most useful thing to see from across a stage.
  final bool pending;

  /// The cursor's track.
  final bool selected;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'name': name,
    'state': state,
    'muted': muted,
    'pending': pending,
    'selected': selected,
  };

  @override
  List<Object?> get props => [name, state, muted, pending, selected];
}

/// Everything the 7" screen shows besides the waveform.
///
/// A value type on purpose: the main window pushes this only when it *changes*
/// (see `WaveformWindowService.pushReadout`), rather than riding the waveform's
/// per-frame timer, so `==` is what keeps the channel quiet while a loop plays
/// unchanged.
///
/// **Wire tolerance instead of a version number.** The payload crosses a
/// method channel between two engines that can be built from different
/// revisions (a hot-restarted main window over a surviving sub-window, or
/// vice versa). [PerformanceReadout.fromMap] therefore defaults every missing
/// field and ignores
/// every unknown one: an older sender degrades a newer receiver to the old
/// facts, and a newer sender is losslessly read by an older receiver — no
/// version handshake to get wrong.
class PerformanceReadout extends Equatable {
  /// Creates a [PerformanceReadout].
  const PerformanceReadout({
    this.tracks = const [],
    this.tempoBpm = 0,
    this.hasTempo = false,
    this.tsNum = 4,
    this.tsDen = 4,
    this.currentBeat = 0,
    this.countingIn = false,
    this.loopBars = 0,
    this.isRunning = false,
    this.mode = 'record',
    this.elapsedSeconds = 0,
    this.recordArmed = false,
    this.recordSeconds = 0,
  });

  /// Rebuilds a readout from [map] as pushed across the window channel.
  factory PerformanceReadout.fromMap(Map<Object?, Object?> map) {
    final tracks = map['tracks'];
    final tempoBpm = (map['tempoBpm'] as num? ?? 0).toDouble();
    return PerformanceReadout(
      tracks: [
        if (tracks is List)
          for (final track in tracks)
            if (track is Map<Object?, Object?>) ReadoutTrack.fromMap(track),
      ],
      tempoBpm: tempoBpm,
      // An older main window never sends `hasTempo`; its own readout treated
      // "tempo > 0" as having one, so the fallback preserves that reading.
      hasTempo: map['hasTempo'] as bool? ?? tempoBpm > 0,
      tsNum: map['tsNum'] as int? ?? 4,
      tsDen: map['tsDen'] as int? ?? 4,
      currentBeat: map['currentBeat'] as int? ?? 0,
      countingIn: map['countingIn'] as bool? ?? false,
      loopBars: map['loopBars'] as int? ?? 0,
      isRunning: map['isRunning'] as bool? ?? false,
      mode: map['mode'] as String? ?? 'record',
      elapsedSeconds: map['elapsedSeconds'] as int? ?? 0,
      recordArmed: map['recordArmed'] as bool? ?? false,
      recordSeconds: map['recordSeconds'] as int? ?? 0,
    );
  }

  /// One entry per track, in channel order.
  final List<ReadoutTrack> tracks;

  /// Live tempo.
  final double tempoBpm;

  /// Whether a tempo grid exists at all (`TempoSource != none`). The stage
  /// surfaces hide the beat dots and the bpm figure on the tempo-free path
  /// rather than stating `0.0 bpm` over a grid that does not exist.
  final bool hasTempo;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// Beat within the bar, `0`-based — which of the [tsNum] dots is lit.
  final int currentBeat;

  /// A count-in is sounding: the recording starts at the next bar line.
  final bool countingIn;

  /// Master loop length in bars, `0` when nothing defines it yet.
  final int loopBars;

  /// Transport running.
  final bool isRunning;

  /// `InteractionMode.token` — what a track press means right now.
  ///
  /// The pedal bank is deliberately NOT carried: no second-screen face draws
  /// it (the plate and the 16" status bar do), and a dead wire field's only
  /// runtime effect would be defeating the `==` push-diff on every BANK
  /// press. The tolerant decode means it can be added back later without any
  /// protocol ceremony.
  final String mode;

  /// The transport clock (`TransportClockCubit`): elapsed transport time in
  /// whole seconds — wall time while anything records or plays, holding
  /// across a stop.
  final int elapsedSeconds;

  /// A performance capture is running.
  final bool recordArmed;

  /// Whole seconds since the capture was armed; meaningless when
  /// [recordArmed] is false.
  final int recordSeconds;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'tracks': [for (final track in tracks) track.toMap()],
    'tempoBpm': tempoBpm,
    'hasTempo': hasTempo,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'currentBeat': currentBeat,
    'countingIn': countingIn,
    'loopBars': loopBars,
    'isRunning': isRunning,
    'mode': mode,
    'elapsedSeconds': elapsedSeconds,
    'recordArmed': recordArmed,
    'recordSeconds': recordSeconds,
  };

  @override
  List<Object?> get props => [
    tracks,
    tempoBpm,
    hasTempo,
    tsNum,
    tsDen,
    currentBeat,
    countingIn,
    loopBars,
    isRunning,
    mode,
    elapsedSeconds,
    recordArmed,
    recordSeconds,
  ];
}
