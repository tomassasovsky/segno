import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/l10n/localized.dart';
import 'package:settings_repository/settings_repository.dart';

part 'tracks_state.dart';

/// Tracks-view PREFERENCES: the persisted per-track display names and the
/// lane-cache indicator toggle, plus the (unpersisted) stage view.
///
/// The track cursor and active bank are NOT here — they are control state,
/// owned (once, for every surface) by `ControlOverlayCubit`; the record/mute
/// mode likewise. This cubit holds only what the tracks view persists about
/// its own presentation.
class TracksCubit extends Cubit<TracksState> {
  /// Creates a [TracksCubit] for [trackCount] tracks.
  TracksCubit({
    required SettingsRepository settings,
    int trackCount = TracksState.tracksPerBank * TracksState.bankCountMax,
  }) : _settings = settings,
       super(
         TracksState(
           names: List.generate(trackCount, storedDefaultTrackName),
         ),
       );

  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  int _loadGeneration = 0;

  /// Restores the persisted view state: track names and whether the lane-cache
  /// indicators are wanted.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final generation = ++_loadGeneration;
    final names = [...state.names];
    for (var i = 0; i < names.length; i++) {
      final saved = await _settings.loadTrackName(i);
      if (saved != null && saved.isNotEmpty) names[i] = saved;
    }
    if (!isClosed && generation == _loadGeneration) {
      emit(state.copyWith(names: names));
    }
  }

  /// Shows [view] on the main display — a presentation change only.
  void showView(StageView view) {
    if (view != state.stageView) emit(state.copyWith(stageView: view));
  }

  /// Renames track [channel] and persists the new [name].
  Future<void> rename(int channel, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || channel < 0 || channel >= state.names.length) return;
    _loadGeneration++;
    final names = [...state.names]..[channel] = trimmed;
    emit(state.copyWith(names: names));
    await _settings.saveTrackName(channel, trimmed);
  }
}
