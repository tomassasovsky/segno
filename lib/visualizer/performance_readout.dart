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
    this.volume = 1,
    this.chainEnabled = true,
    this.defaultName = false,
    this.inputNames = const [],
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory ReadoutTrack.fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    pending: map['pending'] as bool? ?? false,
    selected: map['selected'] as bool? ?? false,
    volume: (map['volume'] as num? ?? 1).toDouble(),
    chainEnabled: map['chainEnabled'] as bool? ?? true,
    defaultName: map['defaultName'] as bool? ?? false,
    inputNames: _stringList(map['inputNames']),
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

  /// Linear output gain, `0..LE_MAX_GAIN` (2.0 = +6 dB). Defaults to unity so
  /// a pre-volume-overlay sender reads as an unmoved fader, not silence.
  final double volume;

  /// The track's FX chain is engaged (not bypassed).
  final bool chainEnabled;

  /// [name] is the track's default identity, nobody having renamed it. The
  /// volume overlay renders default names in the secondary tone — the same
  /// tone the tracks screen uses for a track's default identity.
  final bool defaultName;

  /// Display names of the inputs this track's lanes record — the read-only
  /// source pill(s) on the track's config panel.
  final List<String> inputNames;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'name': name,
    'state': state,
    'muted': muted,
    'pending': pending,
    'selected': selected,
    'volume': volume,
    'chainEnabled': chainEnabled,
    'defaultName': defaultName,
    'inputNames': inputNames,
  };

  @override
  List<Object?> get props => [
    name,
    state,
    muted,
    pending,
    selected,
    volume,
    chainEnabled,
    defaultName,
    inputNames,
  ];
}

/// One configured input's line on the volume overlay (#698).
///
/// "Volume" here is the input's **live-monitor output gain** — the engine has
/// no capture trim, so the recorded signal is always unity; this is the gain
/// of what the player hears through the monitor path. Only inputs with a
/// configured monitor are carried: an unmonitored input has no gain that does
/// anything, and a slider that does nothing is a lie.
class ReadoutInput extends Equatable {
  /// Creates a [ReadoutInput].
  const ReadoutInput({
    required this.index,
    required this.name,
    this.volume = 1,
    this.listeningTracks = const [],
  });

  /// Rebuilds an input from [map] as pushed across the window channel.
  factory ReadoutInput.fromMap(Map<Object?, Object?> map) => ReadoutInput(
    index: map['index'] as int? ?? 0,
    name: map['name'] as String? ?? '',
    volume: (map['volume'] as num? ?? 1).toDouble(),
    listeningTracks: _stringList(map['listeningTracks']),
  );

  /// Hardware input channel — the key volume commands address it by.
  final int index;

  /// Display name.
  final String name;

  /// Linear monitor output gain, `0..LE_MAX_GAIN` (2.0 = +6 dB).
  final double volume;

  /// Display names of the tracks whose lanes record this input — the
  /// read-only "listening tracks" pills on the input's config panel.
  final List<String> listeningTracks;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'index': index,
    'name': name,
    'volume': volume,
    'listeningTracks': listeningTracks,
  };

  @override
  List<Object?> get props => [index, name, volume, listeningTracks];
}

/// Coerces a channel payload into a string list, dropping non-strings — the
/// plugin re-serializes typed lists into `List<Object?>` across engines.
List<String> _stringList(Object? raw) => [
  if (raw is List)
    for (final item in raw)
      if (item is String) item,
];

/// Which goodbye face the 7" (and the stage overlay) should show.
enum ReadoutGoodbye {
  /// Live meters / stage — no overlay.
  none,

  /// Saving… on the stage; the 7" may keep meters until the mark.
  saving,

  /// Plymouth lockup on #08080A, covering the window.
  mark,
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
    this.inputs = const [],
    this.tempoBpm = 0,
    this.hasTempo = false,
    this.tsNum = 4,
    this.tsDen = 4,
    this.currentBeat = 0,
    this.countingIn = false,
    this.loopBars = 0,
    this.isRunning = false,
    this.mode = 'record',
    this.activeBank = 0,
    this.elapsedSeconds = 0,
    this.recordArmed = false,
    this.recordSeconds = 0,
    this.deviceLost = false,
    this.goodbye = ReadoutGoodbye.none,
  });

  /// Rebuilds a readout from [map] as pushed across the window channel.
  factory PerformanceReadout.fromMap(Map<Object?, Object?> map) {
    final tracks = map['tracks'];
    final inputs = map['inputs'];
    final tempoBpm = (map['tempoBpm'] as num? ?? 0).toDouble();
    return PerformanceReadout(
      tracks: [
        if (tracks is List)
          for (final track in tracks)
            if (track is Map<Object?, Object?>) ReadoutTrack.fromMap(track),
      ],
      inputs: [
        if (inputs is List)
          for (final input in inputs)
            if (input is Map<Object?, Object?>) ReadoutInput.fromMap(input),
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
      activeBank: map['activeBank'] as int? ?? 0,
      elapsedSeconds: map['elapsedSeconds'] as int? ?? 0,
      recordArmed: map['recordArmed'] as bool? ?? false,
      recordSeconds: map['recordSeconds'] as int? ?? 0,
      deviceLost: map['deviceLost'] as bool? ?? false,
      goodbye: _goodbyeOf(map['goodbye']),
    );
  }

  /// One entry per track, in channel order.
  final List<ReadoutTrack> tracks;

  /// One entry per configured (monitored) input, in socket order — the
  /// volume overlay's INPUTS group. Empty on a pre-overlay sender.
  final List<ReadoutInput> inputs;

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
  final String mode;

  /// `ControlState.activeBank` — which A/B pedal bank the footswitches
  /// address. Dropped in PR #696 while no second-screen face drew it; the
  /// readout's v2 header renders the bank pair, and the tolerant decode
  /// took the field back without any protocol ceremony, exactly as that
  /// removal promised.
  final int activeBank;

  /// The transport clock (`TransportClockCubit`): elapsed transport time in
  /// whole seconds — wall time while anything records or plays, holding
  /// across a stop.
  final int elapsedSeconds;

  /// A performance capture is running.
  final bool recordArmed;

  /// Whole seconds since the capture was armed; meaningless when
  /// [recordArmed] is false.
  final int recordSeconds;

  /// The pinned audio interface is absent (#453): the stage holds a red
  /// banner, and the readout echoes the same line (`c/device-lost` — the
  /// performer is looking down, not at the main screen). A boolean, not a
  /// name: the echoed line is the pen's fixed copy.
  final bool deviceLost;

  /// Committed power-off face. Older senders omit the key → none.
  final ReadoutGoodbye goodbye;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'tracks': [for (final track in tracks) track.toMap()],
    'inputs': [for (final input in inputs) input.toMap()],
    'tempoBpm': tempoBpm,
    'hasTempo': hasTempo,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'currentBeat': currentBeat,
    'countingIn': countingIn,
    'loopBars': loopBars,
    'isRunning': isRunning,
    'mode': mode,
    'activeBank': activeBank,
    'elapsedSeconds': elapsedSeconds,
    'recordArmed': recordArmed,
    'recordSeconds': recordSeconds,
    'deviceLost': deviceLost,
    'goodbye': goodbye.name,
  };

  @override
  List<Object?> get props => [
    tracks,
    inputs,
    tempoBpm,
    hasTempo,
    tsNum,
    tsDen,
    currentBeat,
    countingIn,
    loopBars,
    isRunning,
    mode,
    activeBank,
    elapsedSeconds,
    recordArmed,
    recordSeconds,
    deviceLost,
    goodbye,
  ];
}

ReadoutGoodbye _goodbyeOf(Object? raw) {
  if (raw == 'saving') return ReadoutGoodbye.saving;
  if (raw == 'mark') return ReadoutGoodbye.mark;
  return ReadoutGoodbye.none;
}
