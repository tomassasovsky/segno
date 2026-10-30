import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';

/// What a New loop sets up on top of the empty rig (#1513 D4): a chain for
/// some tracks and a name for each of them. Resolved above the session layer,
/// which never sees where the chains came from.
class NewLoopTemplate extends Equatable {
  /// Creates a template that puts [trackChains] on their tracks and names
  /// them [names].
  const NewLoopTemplate({required this.trackChains, required this.names});

  /// The track chain each channel (0-based) starts with. It replaces the
  /// chain the track carried, and the channel's lane chains are dropped.
  final Map<int, FxChainEnvelope> trackChains;

  /// The name each channel takes. Track names are global settings, so this
  /// outlives the loop.
  final Map<int, String> names;

  @override
  List<Object?> get props => [trackChains, names];
}

/// Whether [template] fits the effects budget on [looper]'s live chains,
/// by the rule every effects edit uses: the growth is what the template's
/// chains cost less what the track and lane chains of its channels cost,
/// and only a growth larger than [LooperRepository.fxRoomNs] is refused. A
/// template that makes an over-budget rig lighter is never refused.
bool newLoopTemplateFits(LooperRepository looper, NewLoopTemplate template) {
  final channels = template.trackChains.keys.toSet();
  var growth = 0;
  for (final chain in template.trackChains.values) {
    growth += looper.fxCostOf(chain.entries);
  }
  for (final entry in looper.allTrackChains().entries) {
    if (channels.contains(entry.key)) {
      growth -= looper.fxCostOf(entry.value.entries);
    }
  }
  for (final entry in looper.allLaneChains().entries) {
    if (channels.contains(entry.key.$1)) {
      growth -= looper.fxCostOf(entry.value.entries);
    }
  }
  return growth <= 0 || growth <= looper.fxRoomNs;
}
