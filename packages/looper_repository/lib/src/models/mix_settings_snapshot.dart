import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/session_rig.dart';
import 'package:segno_engine/segno_engine.dart' show kMaxChannels, kMaxLanes;

/// Detached live controls. Recorded source images are deliberately separate.
class MixSettingsSnapshot extends Equatable {
  /// Copies the maps so an awaited transaction cannot observe caller edits.
  MixSettingsSnapshot({
    Map<int, double> trackPans = const {},
    Map<(int, int), double> laneLevels = const {},
    Map<int, double> monitorLevels = const {},
    InputSetup inputSetup = const InputSetup.empty(),
    Map<int, bool> trackSolos = const {},
  }) : trackPans = Map.unmodifiable(trackPans),
       laneLevels = Map.unmodifiable(laneLevels),
       monitorLevels = Map.unmodifiable(monitorLevels),
       inputSetup = inputSetup.copyWith(),
       trackSolos = Map.unmodifiable(trackSolos);

  /// The live controls a session will restore, excluding recorded images and
  /// temporary Solo. Used before session replacement touches the active rig.
  factory MixSettingsSnapshot.fromRig(SessionRig rig) => MixSettingsSnapshot(
    trackPans: rig.trackPans,
    inputSetup: rig.inputSetup,
    laneLevels: {
      for (final track in rig.tracks)
        for (final lane in track.lanes) (track.channel, lane.lane): lane.volume,
    },
    monitorLevels: {
      for (final monitor in rig.monitors) monitor.input: monitor.volume,
    },
  );

  /// Track offsets, including tracks without audio.
  final Map<int, double> trackPans;

  /// Independent playback levels, before recorded source attenuation.
  final Map<(int, int), double> laneLevels;

  /// Independent live monitor levels.
  final Map<int, double> monitorLevels;

  /// Capture trim and future source positioning.
  final InputSetup inputSetup;

  /// Temporary audibility flags; persistence must omit these.
  final Map<int, bool> trackSolos;

  /// Structural validity, independent of the outgoing rig's arm state.
  bool get isValid =>
      inputSetup.isValid &&
      trackPans.entries.every(
        (e) => e.key >= 0 && e.key < 8 && _pan(e.value),
      ) &&
      trackSolos.keys.every((key) => key >= 0 && key < 8) &&
      laneLevels.entries.every(
        (e) =>
            e.key.$1 >= 0 &&
            e.key.$1 < 8 &&
            e.key.$2 >= 0 &&
            e.key.$2 < kMaxLanes &&
            _level(e.value),
      ) &&
      monitorLevels.entries.every(
        (e) => e.key >= 0 && e.key < kMaxChannels && _level(e.value),
      );

  static bool _level(double value) =>
      value.isFinite && value >= 0 && value <= 2;

  static bool _pan(double value) => value.isFinite && value >= -1 && value <= 1;

  /// Replaces only the supplied controls.
  MixSettingsSnapshot copyWith({
    Map<int, double>? trackPans,
    Map<(int, int), double>? laneLevels,
    Map<int, double>? monitorLevels,
    InputSetup? inputSetup,
    Map<int, bool>? trackSolos,
  }) => MixSettingsSnapshot(
    trackPans: trackPans ?? this.trackPans,
    laneLevels: laneLevels ?? this.laneLevels,
    monitorLevels: monitorLevels ?? this.monitorLevels,
    inputSetup: inputSetup ?? this.inputSetup,
    trackSolos: trackSolos ?? this.trackSolos,
  );

  @override
  List<Object?> get props => [
    trackPans,
    laneLevels,
    monitorLevels,
    inputSetup,
    trackSolos,
  ];
}
