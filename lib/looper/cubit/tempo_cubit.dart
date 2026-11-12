import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/tempo_state.dart';

/// Presents the application-owned tempo, Click, and recording-start settings.
class TempoCubit extends Cubit<TempoState> {
  /// Borrows [settings]; closing the view never closes the transaction owner.
  new({required TempoSettings settings})
    : _settings = settings,
      super(settings.state) {
    _subscription = settings.stream.listen(emit);
  }

  final TempoSettings _settings;
  late final StreamSubscription<TempoState> _subscription;

  Future<void> setTempo(double bpm) => _settings.setTempo(bpm);

  /// Clears the tempo; the engine's answer, so a refusal can say why.
  // ignore: prefer_void_public_cubit_methods
  Future<EngineResult> clearTempo() => _settings.clearTempo();
  Future<void> setTimeSignature(int num, int den) =>
      _settings.setTimeSignature(num, den);
  Future<void> setClickOutput(int mask) => _settings.setClickOutput(mask);
  Future<void> setClickVolume(double volume) async {
    await _settings.clickVolumeOwner.set(volume);
  }

  Future<void> setClickMode(ClickMode mode) async {
    await _settings.clickModeOwner.set(mode);
  }

  Future<void> setCountInBars(int bars) async {
    await _settings.recordStartControl.setCountInBars(bars);
  }

  Future<void> setSoundStart({required bool enabled}) async {
    await _settings.recordStartControl.setSoundStart(enabled: enabled);
  }

  void tapTempo() {
    _settings.tapTempo();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
