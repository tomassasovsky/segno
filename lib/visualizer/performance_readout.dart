import 'package:equatable/equatable.dart';

/// The selected track as the 7" display shows it (the accepted design): its
/// number, name, crown, state and the facts under the name.
class ReadoutTrack extends Equatable {
  /// Creates a [ReadoutTrack].
  const ReadoutTrack({
    required this.channel,
    required this.name,
    required this.state,
    this.muted = false,
    this.pending = false,
    this.primary = false,
    this.defaultName = false,
    this.bars = 0,
    this.layers = 0,
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory ReadoutTrack.fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    channel: map['channel'] as int? ?? 0,
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    pending: map['pending'] as bool? ?? false,
    primary: map['primary'] as bool? ?? false,
    defaultName: map['defaultName'] as bool? ?? false,
    bars: map['bars'] as int? ?? 0,
    layers: map['layers'] as int? ?? 0,
  );

  /// The track's channel, `0`-based; the display shows `channel + 1`.
  final int channel;

  /// Display name — the STORED name, with [defaultName] saying whether it is
  /// the track's default identity so the readout can localize that itself.
  final String name;

  /// `TrackState.name` — carried as a token rather than the enum because the
  /// sub-window is a separate engine and the payload crosses a method channel.
  final String state;

  /// Muted right now.
  final bool muted;

  /// A quantized action is armed and waiting for its boundary.
  final bool pending;

  /// Wears the primary crown — the first completed recording.
  final bool primary;

  /// [name] is the track's default identity, nobody having renamed it.
  final bool defaultName;

  /// Whole bars across the track, `0` when nothing counts them.
  final int bars;

  /// Layers: the base take plus every retired overdub pass; `0` when empty.
  final int layers;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'channel': channel,
    'name': name,
    'state': state,
    'muted': muted,
    'pending': pending,
    'primary': primary,
    'defaultName': defaultName,
    'bars': bars,
    'layers': layers,
  };

  @override
  List<Object?> get props => [
    channel,
    name,
    state,
    muted,
    pending,
    primary,
    defaultName,
    bars,
    layers,
  ];
}

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
/// field and ignores every unknown one: an older sender degrades a newer
/// receiver to the old facts, and a newer sender is losslessly read by an
/// older receiver — no version handshake to get wrong.
class PerformanceReadout extends Equatable {
  /// Creates a [PerformanceReadout].
  const PerformanceReadout({
    this.selected,
    this.tempoBpm = 0,
    this.hasTempo = false,
    this.tsNum = 4,
    this.tsDen = 4,
    this.mode = 'record',
    this.activeBank = 0,
    this.deviceLost = false,
    this.goodbye = ReadoutGoodbye.none,
  });

  /// Rebuilds a readout from [map] as pushed across the window channel.
  factory PerformanceReadout.fromMap(Map<Object?, Object?> map) {
    final selected = map['selected'];
    final tempoBpm = (map['tempoBpm'] as num? ?? 0).toDouble();
    return PerformanceReadout(
      selected: selected is Map<Object?, Object?>
          ? ReadoutTrack.fromMap(selected)
          : null,
      tempoBpm: tempoBpm,
      // An older main window never sends `hasTempo`; its own readout treated
      // "tempo > 0" as having one, so the fallback preserves that reading.
      hasTempo: map['hasTempo'] as bool? ?? tempoBpm > 0,
      tsNum: map['tsNum'] as int? ?? 4,
      tsDen: map['tsDen'] as int? ?? 4,
      mode: map['mode'] as String? ?? 'record',
      activeBank: map['activeBank'] as int? ?? 0,
      deviceLost: map['deviceLost'] as bool? ?? false,
      goodbye: _goodbyeOf(map['goodbye']),
    );
  }

  /// The cursor's track — what the small display follows. `null` only when
  /// the rig reports no tracks (a stopped engine).
  final ReadoutTrack? selected;

  /// Live tempo.
  final double tempoBpm;

  /// Whether a tempo grid exists at all (`TempoSource != none`). The readout
  /// shows `—` for the bpm figure on the tempo-free path rather than stating
  /// `0` over a grid that does not exist.
  final bool hasTempo;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// `InteractionMode.token` — what a track press means right now, shown as
  /// the current function in the footer.
  final String mode;

  /// `ControlState.activeBank` — which A/B pedal bank the footswitches
  /// address, shown beside the function.
  final int activeBank;

  /// The pinned audio interface is absent (#453): the stage holds a red
  /// banner, and the readout echoes the same line (`c/device-lost` — the
  /// performer is looking down, not at the main screen). A boolean, not a
  /// name: the echoed line is the pen's fixed copy.
  final bool deviceLost;

  /// Committed power-off face. Older senders omit the key → none.
  final ReadoutGoodbye goodbye;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'selected': selected?.toMap(),
    'tempoBpm': tempoBpm,
    'hasTempo': hasTempo,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'mode': mode,
    'activeBank': activeBank,
    'deviceLost': deviceLost,
    'goodbye': goodbye.name,
  };

  @override
  List<Object?> get props => [
    selected,
    tempoBpm,
    hasTempo,
    tsNum,
    tsDen,
    mode,
    activeBank,
    deviceLost,
    goodbye,
  ];
}

ReadoutGoodbye _goodbyeOf(Object? raw) {
  if (raw == 'saving') return ReadoutGoodbye.saving;
  if (raw == 'mark') return ReadoutGoodbye.mark;
  return ReadoutGoodbye.none;
}
