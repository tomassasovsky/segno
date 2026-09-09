import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The global playback options applied to the [LooperRepository] and
/// persisted via [SettingsRepository] (accepted design, Playback & overdub).
class PlaybackOptions extends Equatable {
  /// Creates a [PlaybackOptions].
  const PlaybackOptions({this.overdubDecay = 0});

  /// The default overdub decay in percent (`0..100`): what each overdub pass
  /// removes from the existing layer before adding the new input; `0` (Off)
  /// keeps every layer whole. Tracks follow it unless they carry their own
  /// override (`LooperTrackOverdubDecayChanged`).
  final int overdubDecay;

  /// Returns a copy with the given overrides.
  PlaybackOptions copyWith({int? overdubDecay}) =>
      PlaybackOptions(overdubDecay: overdubDecay ?? this.overdubDecay);

  @override
  List<Object?> get props => [overdubDecay];
}

/// Owns the global playback options: applies them to the repository and
/// persists them. Defaults to no decay (the classic additive overdub).
class PlaybackOptionsCubit extends Cubit<PlaybackOptions> {
  /// Creates a [PlaybackOptionsCubit] driving [repository], persisted through
  /// [settings].
  PlaybackOptionsCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const PlaybackOptions());

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted options and applies them to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final overdubDecay = await _settings.loadOverdubDecay();
    _repository.setOverdubDecay(overdubDecay);
    if (!isClosed) emit(PlaybackOptions(overdubDecay: overdubDecay));
  }

  /// Sets and persists the default overdub decay in percent, applying it
  /// now (a change during a pass ramps at the engine's write head).
  Future<void> setOverdubDecay(int percent) async {
    final clamped = percent.clamp(0, 100);
    if (clamped != state.overdubDecay) {
      emit(state.copyWith(overdubDecay: clamped));
      _repository.setOverdubDecay(clamped);
    }
    await _settings.saveOverdubDecay(clamped);
  }
}
