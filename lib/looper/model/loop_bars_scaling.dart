import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/tempo_state.dart';

/// Whether the loop can read as half or twice its bars now (#1936, D4):
/// the same checks the engine makes before it applies the change, so the
/// controls are only live when a press would do something.
///
/// The tempo must be derived from the loop and not retimed since (the
/// recorded tempo is still the tempo), with whole bars, one shared loop
/// (not Free or Song), no take recording and no count-in. Halving needs an
/// even bar count; either way the tempo must stay in [kTempoRange].
({bool halve, bool double}) loopBarsScaling(LooperState state) {
  const none = (halve: false, double: false);
  final transport = state.transport;
  if (transport.tempoSource != TempoSource.derived ||
      transport.masterLengthFrames <= 0 ||
      transport.loopBars < 1 ||
      transport.countingIn) {
    return none;
  }
  if (transport.looperMode == LooperMode.free ||
      transport.looperMode == LooperMode.song) {
    return none;
  }
  if ((state.recordedTempoBpm - transport.tempoBpm).abs() > 0.01) return none;
  if (state.tracks.any((track) => track.state == TrackState.recording)) {
    return none;
  }
  final (min, max) = kTempoRange;
  return (
    halve: transport.loopBars.isEven && transport.tempoBpm / 2 >= min,
    double: transport.tempoBpm * 2 <= max,
  );
}
