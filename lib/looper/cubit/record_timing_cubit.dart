import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the default timing used by recording and overdubbing. The engine's
/// gate and remembered musical division are applied together.
class RecordTimingCubit extends Cubit<RecordTiming> {
  /// Creates the cubit and follows repository changes such as session recall.
  RecordTimingCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(RecordTiming.immediately) {
    _subscription = _repository.looperState.listen(_onLooperState);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  late final StreamSubscription<LooperState> _subscription;
  Future<void>? _loadFuture;
  int _userEditRevision = 0;
  GridDivision _division = GridDivision.off;

  void _onLooperState(LooperState _) => _syncFromRepository();

  void _syncFromRepository() {
    final transport = _repository.sessionTransport;
    _division = transport.quantizeDiv;
    emit(transport.recordTiming);
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }

  /// Restores the startup preference unless a session or a newer user edit
  /// has taken ownership while the settings reads were pending.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final division = GridDivision.fromCode(await _settings.loadQuantizeDiv());
    final timing = RecordTiming.of(
      quantize: await _settings.loadQuantize(),
      division: division,
    );
    if (isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _syncFromRepository();
      return;
    }
    if (!_repository.setRecordTiming(timing).isOk) return;
    _division = division;
    emit(timing);
  }

  /// Applies and persists an explicit timing. Immediately keeps the last
  /// division so the old two-way quantize toggle can turn it back on.
  Future<void> setTiming(RecordTiming timing) async {
    _userEditRevision++;
    if (!_repository.setRecordTiming(timing).isOk) return;
    if (timing.quantize) _division = timing.division;
    emit(timing);
    await _settings.saveQuantize(value: timing.quantize);
    if (timing.quantize) {
      await _settings.saveQuantizeDiv(timing.division.code);
    }
  }

  /// Toggles the timing gate while retaining the last musical division.
  Future<void> setEnabled({required bool value}) => setTiming(
    RecordTiming.of(quantize: value, division: _division),
  );
}
