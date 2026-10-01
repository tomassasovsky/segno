import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Global record-behavior options applied to the [LooperRepository] and
/// persisted via [SettingsRepository].
class RecordOptions extends Equatable {
  /// Creates a [RecordOptions].
  const RecordOptions({
    this.recDub = false,
    this.autoRecord = false,
    this.defaultMultiple = 0,
  });

  /// When `true`, a record press finalizing a recording continues into overdub
  /// instead of playback (the second-press "rec/dub" mode).
  final bool recDub;

  /// When `true`, recording is sound-activated: a record press on an empty
  /// track waits and starts when the input crosses the threshold.
  final bool autoRecord;

  /// The global default loop length used by inheriting tracks (`0` = auto).
  final int defaultMultiple;

  /// Returns a copy with the given overrides.
  RecordOptions copyWith({
    bool? recDub,
    bool? autoRecord,
    int? defaultMultiple,
  }) => RecordOptions(
    recDub: recDub ?? this.recDub,
    autoRecord: autoRecord ?? this.autoRecord,
    defaultMultiple: defaultMultiple ?? this.defaultMultiple,
  );

  @override
  List<Object?> get props => [recDub, autoRecord, defaultMultiple];
}

/// Owns the global record-behavior options: applies them to the repository and
/// persists them. Defaults to both off (the classic rec → play behavior).
class RecordOptionsCubit extends Cubit<RecordOptions> {
  /// Creates a [RecordOptionsCubit] driving [repository], persisted through
  /// [settings].
  RecordOptionsCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const RecordOptions()) {
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  int _userEditRevision = 0;

  void _onLooperState(LooperState looper) {
    emit(
      RecordOptions(
        recDub: looper.transport.recDub,
        autoRecord: looper.transport.autoRecord,
        defaultMultiple: looper.transport.defaultMultiple,
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
    final recDub = await _settings.loadRecDub();
    final defaultMultiple = await _settings.loadDefaultMultiple();
    if (isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    var restored = state;
    if (_repository.setRecDub(enabled: recDub).isOk) {
      restored = restored.copyWith(recDub: recDub);
    }
    if (_repository.setDefaultMultiple(multiple: defaultMultiple).isOk) {
      restored = restored.copyWith(defaultMultiple: defaultMultiple);
    }
    emit(restored);
  }

  /// Sets and persists the rec/dub second-press mode, applying it now.
  Future<void> setRecDub({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setRecDub(enabled: value).isOk) return;
    emit(state.copyWith(recDub: value));

    await _settings.saveRecDub(value: value);
  }

  /// Sets and persists sound-activated recording, applying it now. Turning
  /// it on clears the count-in (the engine's rule, D9), persisted here too
  /// so a restart does not bring the count-in back over it.
  Future<void> setAutoRecord({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setAutoRecord(enabled: value).isOk) return;
    emit(state.copyWith(autoRecord: value));

    await Future.wait([
      _settings.saveAutoRecord(value: value),
      if (value) _settings.saveCountInBars(0),
    ]);
  }

  /// Sets and persists the global default loop length, applying it now.
  Future<void> setDefaultMultiple(int multiple) async {
    final clamped = multiple < 0 ? 0 : multiple;
    _userEditRevision++;
    if (!_repository.setDefaultMultiple(multiple: clamped).isOk) return;
    emit(state.copyWith(defaultMultiple: clamped));

    await _settings.saveDefaultMultiple(clamped);
  }
}
