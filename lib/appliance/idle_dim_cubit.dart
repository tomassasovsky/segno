import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';

/// The idle period and whether it has run out.
class IdleDimState extends Equatable {
  /// Creates an [IdleDimState].
  const IdleDimState({this.seconds = 0, this.dimmed = false});

  /// The idle period before both panels dim; `0` never dims.
  final int seconds;

  /// Whether the console sat idle for [seconds] and dimmed.
  final bool dimmed;

  @override
  List<Object?> get props => [seconds, dimmed];
}

/// Dims both panels after a period with no activity (accepted design, Idle
/// dimming).
///
/// Activity is anything a player does: a touch, a key, the encoder, a pedal,
/// a MIDI message ([activity]). Music keeps the panels awake: while the
/// transport plays, a track records, or a performance recording runs
/// ([setBusy]), the period does not run at all, and it starts over when the
/// music stops. Never is the default, as the console has always been.
class IdleDimCubit extends Cubit<IdleDimState> {
  /// Creates an [IdleDimCubit].
  IdleDimCubit({required SettingsRepository settings})
    : _settings = settings,
      super(const IdleDimState());

  final SettingsRepository _settings;
  Timer? _timer;
  bool _busy = false;

  /// Restores the saved idle period and starts it.
  Future<void> load() async {
    final seconds = await _settings.loadIdleDimSeconds();
    if (isClosed) return;
    emit(IdleDimState(seconds: seconds, dimmed: state.dimmed));
    _restart();
  }

  /// Sets the idle period (one of [SettingsRepository.idleDimChoices]),
  /// wakes the panels and saves it. Throws when the save fails; the period
  /// applies either way.
  Future<void> setSeconds(int seconds) async {
    emit(IdleDimState(seconds: seconds));
    _restart();
    await _settings.saveIdleDimSeconds(seconds);
  }

  /// A player did something: wake the panels and start the period over.
  void activity() {
    if (state.dimmed) emit(IdleDimState(seconds: state.seconds));
    _restart();
  }

  /// Whether music is playing or being recorded. While [busy] the panels
  /// stay awake; when it ends the period starts over.
  void setBusy({required bool busy}) {
    if (busy == _busy) return;
    _busy = busy;
    if (busy && state.dimmed) emit(IdleDimState(seconds: state.seconds));
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (_busy || state.seconds == 0 || state.dimmed) return;
    _timer = Timer(Duration(seconds: state.seconds), () {
      if (!isClosed) emit(IdleDimState(seconds: state.seconds, dimmed: true));
    });
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
