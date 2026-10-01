import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/output_setup.dart';
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
    OutputSetup outputSetup = const OutputSetup(),
    Map<int, bool> trackSolos = const {},
    Map<(int, int), int> laneInputs = const {},
    Map<(int, int), int> laneOutputs = const {},
    Map<int, int> laneCounts = const {},
  }) : trackPans = Map.unmodifiable(trackPans),
       laneLevels = Map.unmodifiable(laneLevels),
       monitorLevels = Map.unmodifiable(monitorLevels),
       inputSetup = inputSetup.copyWith(),
       outputSetup = outputSetup.detached(),
       trackSolos = Map.unmodifiable(trackSolos),
       laneInputs = Map.unmodifiable(laneInputs),
       laneOutputs = Map.unmodifiable(laneOutputs),
       laneCounts = Map.unmodifiable(laneCounts);

  /// The live controls a session will restore, excluding recorded images and
  /// temporary Solo. Used before session replacement touches the active rig.
  /// Throws if an explicit active count excludes a saved lane.
  factory MixSettingsSnapshot.fromRig(SessionRig rig) {
    for (final track in rig.tracks) {
      final count = rig.laneCounts[track.channel];
      if (count != null && track.lanes.any((lane) => lane.lane >= count)) {
        throw StateError('session lane count excludes a recorded lane');
      }
    }
    return MixSettingsSnapshot(
      trackPans: rig.trackPans,
      inputSetup: rig.inputSetup,
      outputSetup: rig.outputSetup,
      laneInputs: {
        for (final track in rig.tracks)
          for (final lane in track.lanes)
            (track.channel, lane.lane): lane.inputChannel,
        ...rig.laneInputs,
      },
      laneOutputs: {
        for (final track in rig.tracks)
          for (final lane in track.lanes)
            (track.channel, lane.lane): lane.outputMask,
        ...rig.laneOutputs,
      },
      laneCounts: {
        for (final track in rig.tracks)
          if (track.lanes.isNotEmpty)
            track.channel: track.lanes
                .map((l) => l.lane + 1)
                .reduce((a, b) => a > b ? a : b),
        ...rig.laneCounts,
      },
      laneLevels: {
        for (final track in rig.tracks)
          for (final lane in track.lanes)
            (track.channel, lane.lane): lane.volume,
      },
      monitorLevels: {
        for (final monitor in rig.monitors) monitor.input: monitor.volume,
      },
    );
  }

  /// Track offsets, including tracks without audio.
  final Map<int, double> trackPans;

  /// Independent playback levels, before recorded source attenuation.
  final Map<(int, int), double> laneLevels;

  /// Independent live monitor levels.
  final Map<int, double> monitorLevels;

  /// Capture trim and future source positioning.
  final InputSetup inputSetup;

  /// Confirmed destination controls.
  final OutputSetup outputSetup;

  /// Temporary audibility flags; persistence must omit these.
  final Map<int, bool> trackSolos;

  /// Future input assignment per stable lane slot.
  final Map<(int, int), int> laneInputs;

  /// Playback routes including inactive lane slots.
  final Map<(int, int), int> laneOutputs;

  /// Active lane counts, independent from whether audio is present.
  final Map<int, int> laneCounts;

  /// Structural validity, independent of the outgoing rig's arm state.
  bool get isValid =>
      inputSetup.isValid &&
      outputSetup.isValid &&
      laneInputs.entries.every(
        (e) => _lane(e.key) && e.value >= -1 && e.value < kMaxChannels,
      ) &&
      laneOutputs.entries.every(
        (e) => _lane(e.key) && e.value >= 0 && e.value <= 0xffffffff,
      ) &&
      laneCounts.entries.every(
        (e) => e.key >= 0 && e.key < 8 && e.value >= 1 && e.value <= kMaxLanes,
      ) &&
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

  static bool _lane((int, int) key) =>
      key.$1 >= 0 && key.$1 < 8 && key.$2 >= 0 && key.$2 < kMaxLanes;

  static bool _level(double value) =>
      value.isFinite && value >= 0 && value <= 2;

  static bool _pan(double value) => value.isFinite && value >= -1 && value <= 1;

  /// Replaces only the supplied controls.
  MixSettingsSnapshot copyWith({
    Map<int, double>? trackPans,
    Map<(int, int), double>? laneLevels,
    Map<int, double>? monitorLevels,
    InputSetup? inputSetup,
    OutputSetup? outputSetup,
    Map<int, bool>? trackSolos,
    Map<(int, int), int>? laneInputs,
    Map<(int, int), int>? laneOutputs,
    Map<int, int>? laneCounts,
  }) => MixSettingsSnapshot(
    trackPans: trackPans ?? this.trackPans,
    laneLevels: laneLevels ?? this.laneLevels,
    monitorLevels: monitorLevels ?? this.monitorLevels,
    inputSetup: inputSetup ?? this.inputSetup,
    outputSetup: outputSetup ?? this.outputSetup,
    trackSolos: trackSolos ?? this.trackSolos,
    laneInputs: laneInputs ?? this.laneInputs,
    laneOutputs: laneOutputs ?? this.laneOutputs,
    laneCounts: laneCounts ?? this.laneCounts,
  );

  @override
  List<Object?> get props => [
    trackPans,
    laneLevels,
    monitorLevels,
    inputSetup,
    outputSetup,
    trackSolos,
    laneInputs,
    laneOutputs,
    laneCounts,
  ];
}
