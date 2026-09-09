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
    // Sound start and the count-in exclude each other at the engine (D9): a
    // count-in set from the tempo settings turns Sound start off there, and
    // this cubit's own value must follow, or its toggle would show a start
    // the engine no longer performs.
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;

  void _onLooperState(LooperState looper) {
    final autoRecord = looper.transport.autoRecord;
    if (_loadFuture == null || autoRecord == state.autoRecord) return;
    emit(state.copyWith(autoRecord: autoRecord));
    unawaited(_settings.saveAutoRecord(value: autoRecord));
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }

  /// Restores the persisted options and applies them to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final recDub = await _settings.loadRecDub();
    final autoRecord = await _settings.loadAutoRecord();
    final defaultMultiple = await _settings.loadDefaultMultiple();
    _repository
      ..setRecDub(enabled: recDub)
      ..setAutoRecord(enabled: autoRecord)
      ..setDefaultMultiple(multiple: defaultMultiple);
    if (!isClosed) {
      emit(
        RecordOptions(
          recDub: recDub,
          autoRecord: autoRecord,
          defaultMultiple: defaultMultiple,
        ),
      );
    }
  }

  /// Sets and persists the rec/dub second-press mode, applying it now.
  Future<void> setRecDub({required bool value}) async {
    if (value != state.recDub) {
      emit(state.copyWith(recDub: value));
      _repository.setRecDub(enabled: value);
    }
    await _settings.saveRecDub(value: value);
  }

  /// Sets and persists sound-activated recording, applying it now. Turning
  /// it on clears the count-in (the engine's rule, D9), persisted here too
  /// so a restart does not bring the count-in back over it.
  Future<void> setAutoRecord({required bool value}) async {
    if (value != state.autoRecord) {
      emit(state.copyWith(autoRecord: value));
      _repository.setAutoRecord(enabled: value);
    }
    await _settings.saveAutoRecord(value: value);
    if (value) await _settings.saveCountInBars(0);
  }

  /// Sets and persists the global default loop length, applying it now.
  Future<void> setDefaultMultiple(int multiple) async {
    if (multiple != state.defaultMultiple) {
      emit(state.copyWith(defaultMultiple: multiple));
      _repository.setDefaultMultiple(multiple: multiple);
    }
    await _settings.saveDefaultMultiple(multiple);
  }
}
