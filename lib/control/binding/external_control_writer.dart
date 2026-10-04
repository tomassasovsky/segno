import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';

/// Submits each affected FX owner once, including all power and value edits.
/// Owners are independently admitted; callers await native recipe settlement.
extension ExternalControlWriter on LooperRepository {
  Set<FxAddress> writeExternalFx({
    required Map<FxBindingTarget, bool> activations,
    required Map<FxParamTarget, double> parameters,
  }) {
    final owners = <FxAddress>{
      for (final target in activations.keys)
        if (bindingResolves(target)) target.address,
      for (final target in parameters.keys)
        if (valueTargetResolves(target)) target.address,
    };
    final accepted = <FxAddress>{};
    for (final address in owners) {
      final original = chainEntriesAt(address);
      final currentPower = bindingEnabled(FxChainTarget(address));
      if (original == null || currentPower == null) continue;
      final power = activations[FxChainTarget(address)] ?? currentPower;
      final entries = [
        for (final effect in original)
          _edited(effect, address, activations, parameters),
      ];
      final result = switch (address.stage) {
        FxStage.input => setMonitorEffects(
          input: address.index,
          effects: entries,
          chainEnabled: power,
        ),
        FxStage.loop => setLaneEffects(
          channel: address.index,
          lane: address.lane!,
          effects: entries,
          chainEnabled: power,
        ),
        FxStage.track => setTrackEffects(
          channel: address.index,
          effects: entries,
          chainEnabled: power,
        ),
        FxStage.allTracks => setAllTracksEffects(
          effects: entries,
          chainEnabled: power,
        ),
        FxStage.output => setOutputEffects(
          bus: address.index,
          effects: entries,
          chainEnabled: power,
        ),
      };
      if (result.isOk) accepted.add(address);
    }
    return accepted;
  }
}

TrackEffect _edited(
  TrackEffect effect,
  FxAddress address,
  Map<FxBindingTarget, bool> activations,
  Map<FxParamTarget, double> parameters,
) {
  final id = effect.slotId;
  final enabled = id == null
      ? effect.enabled
      : activations[FxSlotTarget(address: address, slotId: id)] ??
            effect.enabled;
  return switch (effect) {
    BuiltInEffect() => effect.copyWith(
      enabled: enabled,
      params: [
        for (var p = 0; p < effect.params.length; p++)
          if (id == null)
            effect.params[p]
          else
            parameters[FxParamTarget(
                  address: address,
                  slotId: id,
                  param: p,
                )] ??
                effect.params[p],
      ],
    ),
    PluginEffect() => effect.copyWith(enabled: enabled),
  };
}
