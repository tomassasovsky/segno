import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The global playback options applied to the [LooperRepository] and
/// persisted via [SettingsRepository] (accepted design, Playback & overdub).
class PlaybackOptions extends Equatable {
  /// Creates a [PlaybackOptions].
  const PlaybackOptions({this.overdubDecay = 0, this.defaultOneShot = false});

  /// The default overdub decay in percent (`0..100`): what each overdub pass
  /// removes from the existing layer before adding the new input; `0` (Off)
  /// keeps every layer whole. Tracks follow it unless they carry their own
  /// override (`LooperTrackOverdubDecayChanged`).
  final int overdubDecay;

  /// Whether inheriting tracks play once instead of looping.
  final bool defaultOneShot;

  /// Returns a copy with the given overrides.
  PlaybackOptions copyWith({int? overdubDecay, bool? defaultOneShot}) =>
      PlaybackOptions(
        overdubDecay: overdubDecay ?? this.overdubDecay,
        defaultOneShot: defaultOneShot ?? this.defaultOneShot,
      );

  @override
  List<Object?> get props => [overdubDecay, defaultOneShot];
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
       super(const PlaybackOptions()) {
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  int _userEditRevision = 0;

  void _onLooperState(LooperState looper) {
    emit(
      PlaybackOptions(
        overdubDecay: looper.transport.overdubDecay,
        defaultOneShot: looper.transport.defaultOneShot,
      ),
    );
  }

  void _syncFromRepository() => _onLooperState(
    LooperState(transport: _repository.sessionTransport),
  );

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }

  /// Restores the persisted options and applies them to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final overdubDecay = await _settings.loadOverdubDecay();
    final defaultOneShot = await _settings.loadDefaultOneShot();
    if (isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    var restored = state;
    if (_repository.setOverdubDecay(overdubDecay).isOk) {
      restored = restored.copyWith(overdubDecay: overdubDecay);
    }
    if (_repository.setDefaultOneShot(oneShot: defaultOneShot).isOk) {
      restored = restored.copyWith(defaultOneShot: defaultOneShot);
    }
    emit(restored);
  }

  /// Sets and persists the default overdub decay in percent, applying it
  /// now (a change during a pass ramps at the engine's write head).
  Future<void> setOverdubDecay(int percent) async {
    final clamped = percent.clamp(0, 100);
    _userEditRevision++;
    if (!_repository.setOverdubDecay(clamped).isOk) return;
    emit(state.copyWith(overdubDecay: clamped));

    await _settings.saveOverdubDecay(clamped);
  }

  /// Sets and persists whether inheriting tracks play once.
  Future<void> setDefaultOneShot({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setDefaultOneShot(oneShot: value).isOk) return;
    emit(state.copyWith(defaultOneShot: value));

    await _settings.saveDefaultOneShot(oneShot: value);
  }
}
