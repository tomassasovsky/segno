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
class ReadoutCommands {
  /// Creates a [ReadoutCommands] over the running rig's settings owners.
  ReadoutCommands({
    required LooperRepository repository,
    required TempoSettings tempo,
    required RecordSettings record,
    required RecordTimingSettings timing,
  }) : _repository = repository,
       _tempo = tempo,
       _record = record,
       _timing = timing;

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

  /// The tempo the last accepted nudge set, the live tempo it was added to,
  /// and when. Held while the live tempo still reads what it read then.
  ({double target, double from, DateTime at})? _pending;

  /// Applies [command].
  void handle(ReadoutCommand command) {
    switch (command) {
      case TempoNudge(:final delta):
        _nudge(delta);
      case TempoSet(:final bpm):
        final (min, max) = kTempoRange;
        if (bpm < min || bpm > max) return;
        _setTempo(_hundredths(bpm), from: _liveTempo());
      case TempoTap():
        _pending = null;
        _tempo.tapTempo();
      case SignatureSet(:final num, :final den):
        if (!kValidTimeSignatures.contains((num, den))) return;
        unawaited(_tempo.setTimeSignature(num, den));
      case LengthSet(:final bars):
        unawaited(_record.setDefaultLengthBars(bars));
      case TimingSet(:final timing):
        unawaited(_timing.setTiming(timing));
    }
  }

  /// Adds [delta] to the live tempo. The live tempo lags a set by one engine
  /// snapshot, so while it still reads what the last nudge was added to, the
  /// nudge adds to that nudge's result: a held button counts every repeat.
  void _nudge(double delta) {
    final live = _liveTempo();
    final pending = _pending;
    final base =
        pending != null &&
            pending.from == live &&
            clock.now().difference(pending.at) < _pendingFor
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
    // The owner publishes an accepted tempo before it saves it; a refused
    // one (a locked tempo) leaves nothing for the next nudge to build on.
    _pending = _tempo.state.bpm == target
        ? (target: target, from: from, at: clock.now())
        : null;
  }

  /// The tempo the rig runs at now, `0` when none is set.
  double _liveTempo() {
    final transport = _repository.sessionTransport;
    return transport.tempoSource == TempoSource.none ? 0 : transport.tempoBpm;
  }

  static double _hundredths(double bpm) => (bpm * 100).roundToDouble() / 100;
}
