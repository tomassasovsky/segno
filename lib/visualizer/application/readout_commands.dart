import 'dart:async';

import 'package:clock/clock.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/visualizer/readout_command.dart';

/// Applies the changes a player asks for on the readout's Loop panel (#1654)
/// through the settings classes the Loop settings pages use, so a change
/// from the readout is persisted, recalled and refused exactly as one from
/// the main screen. Nothing is answered: the readout sees the accepted value
/// in its next readout push.
///
/// The tempo lock is checked here, not left to the engine: the engine takes
/// a locked tempo or signature command and drops it later on the audio
/// thread, while the settings owner would already have published and saved
/// it.
class ReadoutCommands {
  /// Creates a [ReadoutCommands] over the running rig's settings owners.
  /// [dimmed] says whether the console is idle-dimmed.
  ReadoutCommands({
    required LooperRepository repository,
    required TempoSettings tempo,
    required RecordSettings record,
    required RecordTimingSettings timing,
    required bool Function() dimmed,
  }) : _repository = repository,
       _tempo = tempo,
       _record = record,
       _timing = timing,
       _dimmed = dimmed;

  /// Where a nudge starts when no tempo is set: where the main screen's Tempo
  /// page starts its slider.
  static const double startingTempo = 120;

  /// How long a nudge's result stands in for a live tempo that has not
  /// caught up with it.
  static const Duration _pendingFor = Duration(seconds: 1);

  final LooperRepository _repository;
  final TempoSettings _tempo;
  final RecordSettings _record;
  final RecordTimingSettings _timing;
  final bool Function() _dimmed;

  /// The tempo the last accepted set put in, the live tempo it replaced,
  /// and a stopwatch running since (monotonic, so a clock step cannot
  /// stretch the window). Held while the live tempo still reads what it
  /// read then.
  ({double target, double from, Stopwatch age})? _pending;

  /// Applies [command].
  void handle(ReadoutCommand command) {
    // The touch that wakes a dimmed console presses nothing. The readout's
    // own barrier can be a push behind the dim; this is the main screen's
    // word on it. A step and Tap act on touch, before the waking activity
    // arrives, so they are dropped here too.
    if (_dimmed()) return;
    switch (command) {
      case TempoNudge(:final delta):
        if (_tempoLocked) return;
        _nudge(delta);
      case TempoSet(:final bpm):
        final (min, max) = kTempoRange;
        if (_tempoLocked || bpm < min || bpm > max) return;
        _setTempo(_hundredths(bpm), from: _liveTempo());
      case TempoTap():
        if (_tempoLocked) return;
        _pending = null;
        _tempo.tapTempo();
      case SignatureSet(:final num, :final den):
        // Only before the first take, as on the RC-600 (D6).
        if (_repository.lastState.tempoFollow != TempoFollowState.free) return;
        if (!kValidTimeSignatures.contains((num, den))) return;
        unawaited(_tempo.setTimeSignature(num, den));
      case LengthSet(:final bars):
        unawaited(_record.setDefaultLengthBars(bars));
      case TimingSet(:final timing):
        unawaited(_timing.setTiming(timing));
    }
  }

  /// Whether the tempo takes no change now: an external clock owns it, or
  /// the engine's lock holds it (#1179's follow state).
  bool get _tempoLocked {
    final state = _repository.lastState;
    if (state.transport.tempoSource == TempoSource.external) return true;
    return switch (state.tempoFollow) {
      TempoFollowState.free || TempoFollowState.retimes => false,
      TempoFollowState.noGrid ||
      TempoFollowState.noFollower ||
      TempoFollowState.busy => true,
    };
  }

  /// Adds [delta] to the live tempo. The live tempo lags a set by one engine
  /// snapshot, so while it still reads what the last set replaced, the
  /// nudge adds to that set's result: a held button counts every repeat.
  void _nudge(double delta) {
    final live = _liveTempo();
    final pending = _pending;
    final base =
        pending != null &&
            pending.from == live &&
            pending.age.elapsed < _pendingFor
        ? pending.target
        : live > 0
        ? live
        : startingTempo;
    final (min, max) = kTempoRange;
    _setTempo(_hundredths((base + delta).clamp(min, max)), from: live);
  }

  /// Sets [target] and remembers it as the tempo the next nudge builds on
  /// while the live tempo still reads [from].
  void _setTempo(double target, {required double from}) {
    unawaited(_tempo.setTempo(target));
    // The owner publishes an accepted tempo before it saves it; one the
    // repository refused leaves nothing for the next nudge to build on.
    if (_tempo.state.bpm != target) {
      _pending = null;
      return;
    }
    _pending = (target: target, from: from, age: clock.stopwatch()..start());
  }

  /// The tempo the rig runs at now, `0` when none is set.
  double _liveTempo() {
    final transport = _repository.sessionTransport;
    return transport.tempoSource == TempoSource.none ? 0 : transport.tempoBpm;
  }

  static double _hundredths(double bpm) => (bpm * 100).roundToDouble() / 100;
}
