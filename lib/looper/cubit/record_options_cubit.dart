import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:segno/looper/model/record_options_view_state.dart';

/// Presents accepted recording options and the latest length edit result.
class RecordOptionsCubit extends Cubit<RecordOptionsViewState> {
  /// Borrows the application owner without taking over its lifetime.
  RecordOptionsCubit({required RecordSettings settings})
    : _settings = settings,
      super(RecordOptionsViewState(options: settings.state)) {
    _subscription = settings.stream.listen(_onSettings);
  }

  final RecordSettings _settings;
  late final StreamSubscription<RecordOptions> _subscription;
  int _nextAttempt = 0;
  RecordLengthLifetime? _attemptLifetime;

  void _onSettings(RecordOptions options) {
    emit(
      RecordOptionsViewState(
        options: options,
        lengthAttempt: _attemptLifetime == _settings.recordLengthLifetime
            ? state.lengthAttempt
            : null,
      ),
    );
  }

  Future<void> setRecDub({required bool value}) =>
      _settings.setRecDub(value: value);
  Future<void> setDefaultMultiple(int multiple) =>
      _settings.setDefaultMultiple(multiple);
  Future<void> setDefaultLengthBars(int bars) => _setLength(null, bars);

  /// Switches the looper mode through the Record length owner.
  Future<void> setLooperMode(LooperMode mode) async {
    await _settings.setLooperMode(mode);
  }

  Future<void> setTrackRecordLength({
    required int channel,
    required int? bars,
  }) => _setLength(channel, bars);

  Future<void> _setLength(int? channel, int? bars) async {
    if (isClosed) return;
    final id = ++_nextAttempt;
    final lifetime = _settings.recordLengthLifetime;
    _attemptLifetime = lifetime;
    emit(
      RecordOptionsViewState(
        options: state.options,
        lengthAttempt: LengthEditAttempt(
          id: id,
          channel: channel,
          bars: bars,
          phase: LengthEditPhase.pending,
        ),
      ),
    );
    final outcome = channel == null
        ? await _settings.setDefaultLengthBars(bars ?? 0)
        : await _settings.setTrackRecordLength(channel: channel, bars: bars);
    if (isClosed || state.lengthAttempt?.id != id) return;
    if (lifetime != _settings.recordLengthLifetime ||
        outcome.status == RecordLengthStatus.superseded) {
      emit(RecordOptionsViewState(options: state.options));
      return;
    }
    emit(
      RecordOptionsViewState(
        options: state.options,
        lengthAttempt: LengthEditAttempt(
          id: id,
          channel: channel,
          bars: bars,
          phase: outcome.isOk
              ? LengthEditPhase.applied
              : LengthEditPhase.refused,
        ),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
