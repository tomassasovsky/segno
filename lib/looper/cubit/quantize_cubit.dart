import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Whether recording is quantized to the loop grid: a record/overdub press
/// over an existing master loop is deferred to the next loop top so captures
/// align to the grid (a second press before the boundary cancels it). Applied
/// to the [LooperRepository] and persisted via [SettingsRepository]. Defaults
/// to off (the free-running behaviour).
class QuantizeCubit extends Cubit<bool> {
  /// Creates a [QuantizeCubit] driving [repository], with the choice persisted
  /// through [settings]. Starts off until [load] restores the saved value.
  QuantizeCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(false) {
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  int _userEditRevision = 0;

  void _onLooperState(LooperState looper) {
    emit(looper.transport.quantize);
  }

  void _syncFromRepository() => _onLooperState(
    LooperState(transport: _repository.sessionTransport),
  );

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }

  /// Restores the persisted preference and applies it to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final on = await _settings.loadQuantize();
    if (isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    if (_repository.setQuantize(enabled: on).isOk) emit(on);
  }

  /// Sets and persists whether recording is quantized, applying it now.
  Future<void> setEnabled({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setQuantize(enabled: value).isOk) return;
    emit(value);

    await _settings.saveQuantize(value: value);
  }

  /// Toggles the preference.
  Future<void> toggle() => setEnabled(value: !state);
}
