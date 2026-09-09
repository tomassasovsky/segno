import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the default record timing (accepted design, Length & quantize): the
/// one setting the engine's quantize gate and musical division pair into.
/// Applies it to the [LooperRepository] as one call and persists it as the
/// gate and the division the repository already exposes, so a switch that
/// only turns the gate off keeps the division on disk.
class RecordTimingCubit extends Cubit<RecordTiming> {
  /// Creates a [RecordTimingCubit] driving [repository], persisted through
  /// [settings]. Starts at Immediately until [load] restores the saved
  /// value.
  RecordTimingCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(RecordTiming.immediately);

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// The last musical division chosen, kept while the gate is off so
  /// [setEnabled] can bring it back: Immediately carries no division of its
  /// own, and the persisted division key is left as it was.
  GridDivision _division = GridDivision.off;

  /// Restores the persisted timing and applies it to the repository.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _division = GridDivision.fromCode(await _settings.loadQuantizeDiv());
    final timing = RecordTiming.of(
      quantize: await _settings.loadQuantize(),
      division: _division,
    );
    _repository.setRecordTiming(timing);
    if (!isClosed) emit(timing);
  }

  /// Sets and persists the default record timing, applying it now.
  Future<void> setTiming(RecordTiming timing) async {
    if (timing != state) {
      emit(timing);
      _repository.setRecordTiming(timing);
    }
    await _settings.saveQuantize(value: timing.quantize);
    // Immediately says nothing about the division: the one on disk stays,
    // so turning the gate back on finds it again.
    if (timing.quantize) {
      _division = timing.division;
      await _settings.saveQuantizeDiv(timing.division.code);
    }
  }

  /// Turns the gate on or off, keeping the division: off is Immediately,
  /// on is the division last chosen, or the loop top when none was (the
  /// older two-way surfaces' toggle).
  Future<void> setEnabled({required bool value}) =>
      setTiming(RecordTiming.of(quantize: value, division: _division));
}
