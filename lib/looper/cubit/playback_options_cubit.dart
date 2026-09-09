import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The global playback options applied to the [LooperRepository] and
/// persisted via [SettingsRepository] (accepted design, Playback & overdub).
class PlaybackOptions extends Equatable {
  /// Creates a [PlaybackOptions].
  const PlaybackOptions({this.overdubDecay = 0, this.once = false});

  /// The default overdub decay in percent (`0..100`): what each overdub pass
  /// removes from the existing layer before adding the new input; `0` (Off)
  /// keeps every layer whole. Tracks follow it unless they carry their own
  /// override (`LooperTrackOverdubDecayChanged`).
  final int overdubDecay;

  /// The default Loop/Once: `true` = a track plays once then stops. Tracks
  /// follow it unless they carry their own override
  /// (`LooperTrackOnceChanged`).
  final bool once;

  /// Returns a copy with the given overrides.
  PlaybackOptions copyWith({int? overdubDecay, bool? once}) => PlaybackOptions(
    overdubDecay: overdubDecay ?? this.overdubDecay,
    once: once ?? this.once,
  );

  @override
  List<Object?> get props => [overdubDecay, once];
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
    final once = await _settings.loadDefaultOnce();
    _repository
      ..setOverdubDecay(overdubDecay)
      ..setDefaultOnce(once: once);
    if (!isClosed) {
      emit(PlaybackOptions(overdubDecay: overdubDecay, once: once));
    }
  }

  /// Sets and persists the default Loop/Once, applying it now.
  Future<void> setOnce({required bool value}) async {
    if (value != state.once) {
      emit(state.copyWith(once: value));
      _repository.setDefaultOnce(once: value);
    }
    await _settings.saveDefaultOnce(value: value);
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
