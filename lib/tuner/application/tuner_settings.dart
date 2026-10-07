import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

/// The tuner's appliance preferences: the A4 reference and the input it
/// listens to. Not Session state: loading a Session keeps them (#1229).
class TunerPreferences extends Equatable {
  /// Creates a set of tuner preferences.
  const TunerPreferences({
    this.referenceHz = SettingsRepository.tunerReferenceDefaultHz,
    this.input = -1,
  });

  /// Concert A in Hz, within 420–460.
  final int referenceHz;

  /// The stored hardware input, or `-1` for the first one available.
  final int input;

  /// Whether a step of the reference would leave the 420–460 Hz range.
  bool atLimit(int delta) {
    final next = referenceHz + delta;
    return next < SettingsRepository.tunerReferenceMinHz ||
        next > SettingsRepository.tunerReferenceMaxHz;
  }

  /// Returns a copy with the given fields replaced.
  TunerPreferences copyWith({int? referenceHz, int? input}) => TunerPreferences(
    referenceHz: referenceHz ?? this.referenceHz,
    input: input ?? this.input,
  );

  @override
  List<Object?> get props => [referenceHz, input];
}

/// Owns the tuner preferences for the reading (`TunerCubit`) and the foot
/// Tuner (Control): one live value, written through, with a failed write
/// restoring the previous value.
class TunerSettings {
  /// Creates the owner over [settings].
  TunerSettings({required SettingsRepository settings}) : _settings = settings;

  final SettingsRepository _settings;
  final _changes = StreamController<TunerPreferences>.broadcast(sync: true);
  TunerPreferences _live = const TunerPreferences();
  bool _closed = false;

  /// The current preferences: the stored ones once [load] has run, else the
  /// defaults.
  TunerPreferences get live => _live;

  /// Every change of [live], including a restore after a failed write.
  Stream<TunerPreferences> get changes => _changes.stream;

  /// Reads the stored preferences once.
  Future<void> load() async {
    final reference = await _settings.loadTunerReferenceHz();
    final input = await _settings.loadTunerInput();
    _set(TunerPreferences(referenceHz: reference, input: input));
  }

  /// Sets the A4 reference, clamped to 420–460 Hz. Completes false, with the
  /// previous value restored, when the write fails.
  Future<bool> setReference(int hz) {
    final clamped = hz.clamp(
      SettingsRepository.tunerReferenceMinHz,
      SettingsRepository.tunerReferenceMaxHz,
    );
    return _write(
      _live.copyWith(referenceHz: clamped),
      () => _settings.saveTunerReferenceHz(clamped),
    );
  }

  /// Sets the input the tuner listens to (`-1` for the first available).
  /// Completes false, with the previous value restored, when the write fails.
  Future<bool> setInput(int input) {
    final stored = input < 0 ? -1 : input;
    return _write(
      _live.copyWith(input: stored),
      () => _settings.saveTunerInput(stored),
    );
  }

  Future<bool> _write(
    TunerPreferences next,
    Future<void> Function() save,
  ) async {
    if (_closed) return false;
    if (next == _live) return true;
    final previous = _live;
    _set(next);
    try {
      await save();
      return true;
    } on Object {
      // Only undo our own value: a later accepted write stays.
      if (_live == next) _set(previous);
      return false;
    }
  }

  void _set(TunerPreferences next) {
    if (_closed || next == _live) return;
    _live = next;
    _changes.add(next);
  }

  /// Stops publishing changes.
  Future<void> close() {
    _closed = true;
    return _changes.close();
  }
}
