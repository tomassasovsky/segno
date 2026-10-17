import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/model/record_timing.dart';

/// Presents the application-owned recording timing settings.
class RecordTimingCubit extends Cubit<RecordTimingState> {
  /// Borrows [settings]; closing this projection does not close its owner.
  RecordTimingCubit({required RecordTimingSettings settings})
    : _settings = settings,
      super(settings.state) {
    _subscription = settings.stream.listen(emit);
  }

  final RecordTimingSettings _settings;
  late final StreamSubscription<RecordTimingState> _subscription;

  /// Changes the ordinary default recording timing.
  Future<void> setTiming(RecordTiming timing) async {
    await _settings.setTiming(timing);
  }

  /// Toggles quantization while retaining the confirmed remembered division.
  Future<void> setEnabled({required bool value}) async {
    await _settings.setEnabled(value: value);
  }

  /// Sets a track override, or removes it to follow the default.
  Future<void> setTrackTiming({
    required int channel,
    required RecordTiming? timing,
  }) async {
    await _settings.setTrackTiming(channel: channel, timing: timing);
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
