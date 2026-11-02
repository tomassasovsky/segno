import 'package:equatable/equatable.dart';
import 'package:segno/appliance/power_off/power_step.dart';

/// The selected track as the 7" display shows it (the accepted design): its
/// number, name, crown, state and the facts under the name.
class ReadoutTrack extends Equatable {
  /// Creates a [ReadoutTrack].
  const ReadoutTrack({
    required this.channel,
    required this.name,
    required this.state,
    this.muted = false,
    this.primary = false,
    this.defaultName = false,
    this.bars = 0,
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory ReadoutTrack.fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    channel: map['channel'] as int? ?? 0,
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    primary: map['primary'] as bool? ?? false,
    defaultName: map['defaultName'] as bool? ?? false,
    bars: map['bars'] as int? ?? 0,
  );

  /// The track's channel, `0`-based; the display shows `channel + 1`.
  final int channel;

  /// Display name — the STORED name, with [defaultName] saying whether it is
  /// the track's default identity so the readout can localize that itself.
  final String name;

  /// `TrackState.name` — carried as a token rather than the enum because the
  /// readout is a separate engine and the payload crosses the screen link.
  final String state;

  /// Muted right now.
  final bool muted;

  /// Wears the primary crown — the first completed recording.
  final bool primary;

  /// [name] is the track's default identity, nobody having renamed it.
  final bool defaultName;

  /// Whole bars across the track, `0` when nothing counts them.
  final int bars;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'channel': channel,
    'name': name,
    'state': state,
    'muted': muted,
    'primary': primary,
    'defaultName': defaultName,
    'bars': bars,
  };

  @override
  List<Object?> get props => [
    channel,
    name,
    state,
    muted,
    primary,
    defaultName,
    bars,
  ];
}

/// Which power face the 7" shows over its readout (pen 32).
enum ReadoutGoodbye {
  /// The live readout, no face.
  none,

  /// The power panel or Save As is up: "Power options on the main screen".
  options,

  /// The save before a restart or shutdown, with its current step.
  saving,

  /// The console is off: the check ring and "Safe to switch off".
  safeToSwitchOff,

  /// The console is restarting: the restart icon and "Restarting".
  restarting,
}

/// Everything the 7" screen shows besides the waveform.
///
/// A value type on purpose: the main window pushes this only when it *changes*
/// (see `WaveformWindowService.pushReadout`), rather than riding the waveform's
/// per-frame timer, so `==` is what keeps the channel quiet while a loop plays
/// unchanged.
///
/// Both windows use the same build and payload schema. Missing fields receive
/// neutral defaults; unknown fields are ignored. This does not translate older
/// readout schemas or promise compatibility between different app versions.
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
    this.lossLine = '',
    this.goodbye = ReadoutGoodbye.none,
    this.savingStep,
    this.savingProgress = 0,
    this.brightness = 1,
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
      lossLine: map['lossLine'] as String? ?? '',
      goodbye: _goodbyeOf(map['goodbye']),
      savingStep: _stepOf(map['savingStep']),
      savingProgress: (map['savingProgress'] as num? ?? 0).toDouble(),
      brightness: (map['brightness'] as num? ?? 1).toDouble(),
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

  /// The stage strip's line while the pinned audio interface is absent
  /// (#453), or while the boot waits for it; empty otherwise. The readout
  /// echoes it word for word (`c/device-lost` — the performer is looking
  /// down, not at the main screen), so the line is built once, on the main
  /// screen, with the device's name (#1270 Part 5).
  final String lossLine;

  /// The power face. A missing key reads as none.
  final ReadoutGoodbye goodbye;

  /// The save's current step under [ReadoutGoodbye.saving]; null otherwise.
  final PowerStep? savingStep;

  /// The share of the save's steps finished, `0..1`, under
  /// [ReadoutGoodbye.saving].
  final double savingProgress;

  /// The software dim over the Track display window, `0..1` (`1` = none):
  /// its panel's brightness and idle dim when the panel cannot dim itself.
  final double brightness;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'selected': selected?.toMap(),
    'tempoBpm': tempoBpm,
    'hasTempo': hasTempo,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'mode': mode,
    'activeBank': activeBank,
    'lossLine': lossLine,
    'goodbye': goodbye.name,
    'savingStep': savingStep?.name,
    'savingProgress': savingProgress,
    'brightness': brightness,
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
    lossLine,
    goodbye,
    savingStep,
    savingProgress,
    brightness,
  ];
}

ReadoutGoodbye _goodbyeOf(Object? raw) => ReadoutGoodbye.values.firstWhere(
  (face) => face.name == raw,
  orElse: () => ReadoutGoodbye.none,
);

PowerStep? _stepOf(Object? raw) {
  for (final step in PowerStep.values) {
    if (step.name == raw) return step;
  }
  return null;
}
