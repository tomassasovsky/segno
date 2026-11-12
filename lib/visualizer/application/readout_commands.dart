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
/// the main screen. An accepted change is not answered: the readout sees the
/// accepted value in its next readout push. A refused Clear tempo is, through
/// [ReadoutCommands.new]'s `onRefused`, because nothing in the push says it
/// was refused.
///
/// The tempo lock is checked here, not left to the engine: the engine takes
/// a locked tempo or signature command and drops it later on the audio
/// thread, while the settings owner would already have published and saved
/// it.
class ReadoutCommands {
  /// Creates a [ReadoutCommands] over the running rig's settings owners.
  /// [_dimmed] says whether the console is idle-dimmed.
  ReadoutCommands({
    required this._repository,
    required this._tempo,
    required this._record,
    required this._timing,
    required this._dimmed,
    required this._onRefused,
  });

  /// Where a nudge starts when no tempo is set: where the main screen's Tempo
  /// page starts its slider.
  static const double startingTempo = 120;

  /// How long a nudge's result stands in for a live tempo that has not
  /// caught up with it.
  static const Duration _pendingFor = Duration(seconds: 1);

  /// How long after a touch on the readout wakes the console its commands
  /// are dropped: the length of the waking touch.
  static const Duration wakeGesture = Duration(seconds: 1);

  final LooperRepository _repository;
  final TempoSettings _tempo;
  final RecordSettings _record;
  final RecordTimingSettings _timing;
  final bool Function() _dimmed;
  final void Function(ReadoutRefusal refusal) _onRefused;

  /// The tempo the last accepted set put in, the live tempo it replaced,
  /// and a stopwatch running since (monotonic, so a clock step cannot
  /// stretch the window). Held while the live tempo still reads what it
  /// read then.
  ({double target, double from, Stopwatch age})? _pending;

  /// Running since a touch on the readout woke the console.
  Stopwatch? _woke;

  /// A touch on the readout woke the dimmed console. A button that acts on
  /// release (Clear tempo, a length, a signature) sends its command after
  /// the wake, when the console is no longer dimmed, so for [wakeGesture]
  /// commands are dropped as the dimmed console drops them.
  void woke() => _woke = clock.stopwatch()..start();

  /// Applies [command].
  void handle(ReadoutCommand command) {
    // The touch that wakes a dimmed console presses nothing. The readout's
    // own barrier can be a push behind the dim; this is the main screen's
    // word on it. A step and Tap act on touch, before the waking activity
    // arrives, so they are dropped here too.
    if (_dimmed()) return;
    final woke = _woke;
    if (woke != null && woke.elapsed < wakeGesture) return;
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
      case TempoClear():
        // No lock check here: the engine's tempo lock decides, as it does
        // for the main screen's Clear tempo.
        unawaited(_clearTempo());
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

  /// Clears the tempo, and reports a refusal with the reason the main
  /// screen's notice gives.
  Future<void> _clearTempo() async {
    final result = await _tempo.clearTempo();
    if (result.isOk) {
      // No tempo is left for a pending nudge to build on.
      _pending = null;
      return;
    }
    _onRefused(switch (result) {
      EngineResult.notReady => ReadoutRefusal.tempoClearLocked,
      EngineResult.notRunning => ReadoutRefusal.tempoClearStopped,
      _ => ReadoutRefusal.tempoClearOther,
    });
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
