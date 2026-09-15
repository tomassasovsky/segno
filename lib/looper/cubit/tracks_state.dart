part of 'tracks_cubit.dart';

/// Which presentation of the session the main display shows — the choices
/// behind the top bar's view icon (the accepted stage). Track, Wave and the
/// later Mixer are alternate views of the same music and mix; changing one
/// never changes playback or selection.
enum StageView {
  /// Four tall level columns for the active bank.
  track,

  /// One waveform row per track of the active bank.
  wave,
}

/// State for [TracksCubit]: the persisted tracks-view preferences (per-track
/// names, lane-cache indicator visibility) and the current stage view.
///
/// The track cursor, active bank, and record/mute mode are control state
/// owned by `ControlOverlayCubit` — one cursor for every surface, so the
/// keyboard, the tiles, and the pedal can never target different tracks.
class TracksState extends Equatable {
  /// Creates a [TracksState].
  const TracksState({
    required this.names,
    // Off by default on the console; the loaded
    // preference can still turn it on.
    this.showIndicators = false,
    this.stageView = StageView.track,
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCountMax = 2;

  /// Per-track display names, indexed by channel.
  final List<String> names;

  /// Whether the Signal face's lane-cache indicators are wanted (persisted
  /// view preference; it gates the cache telemetry, see `CacheTelemetryScope`).
  final bool showIndicators;

  /// The main display's current presentation. Not persisted: normal startup
  /// opens Tracks (the accepted stage), whatever was open last time.
  final StageView stageView;

  /// The display name for [channel], or a fallback.
  String nameOf(int channel) => channel >= 0 && channel < names.length
      ? names[channel]
      : storedDefaultTrackName(channel);

  /// Returns a copy with the given overrides.
  TracksState copyWith({
    List<String>? names,
    bool? showIndicators,
    StageView? stageView,
  }) => TracksState(
    names: names ?? this.names,
    showIndicators: showIndicators ?? this.showIndicators,
    stageView: stageView ?? this.stageView,
  );

  @override
  List<Object?> get props => [names, showIndicators, stageView];
}
