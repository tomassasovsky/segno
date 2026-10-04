import 'package:looper_repository/src/looper_repository.dart';
import 'package:looper_repository/src/models/fx_address.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// The shared stage-to-chain lookup for FX editing and control bindings.
extension FxChainLookup on LooperRepository {
  /// The entries at [address], or `null` when the rig has no such chain.
  /// Empty existing chains still resolve, while a missing lane does not
  /// silently fall back to lane zero.
  List<TrackEffect>? chainEntriesAt(FxAddress address) {
    if (address.index < 0) return null;
    final lane = address.lane;
    return switch (address.stage) {
      FxStage.input =>
        allMonitors().containsKey(address.index)
            ? monitorEffects(address.index)
            : null,
      FxStage.loop =>
        lane != null && allLaneChains().containsKey((address.index, lane))
            ? laneEffects(address.index, lane)
            : null,
      FxStage.track =>
        allTrackChains().containsKey(address.index)
            ? trackEffects(address.index)
            : null,
      FxStage.allTracks => address.index == 0 ? allTracksEffects : null,
      FxStage.output =>
        address.index < state.outputBusCount
            ? outputEffects(address.index)
            : null,
    };
  }
}
