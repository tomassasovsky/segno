import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Writes track [channel]'s Track-stage chain envelope (`{chainEnabled,
/// entries}`, R13/R15) to the settings store, read back by the boot restore.
///
/// ONE definition, shared by every surface that can flip a Track chain:
/// `LooperBloc` (the on-screen FX dock and the keyboard) and `ControlCubit`
/// (the pedal's FX-mode stomps). A cubit never calls a bloc, so the pedal path
/// cannot route its persistence through the bloc's handler — without this
/// helper the two paths would carry two copies of the envelope encoding and
/// could drift, leaving a stomped chain that resurrects on the next boot.
///
/// No-op when [settings] is null (the bloc's settings dependency is optional).
void persistTrackFxChain({
  required SettingsRepository? settings,
  required LooperRepository looper,
  required int channel,
}) {
  if (settings == null) return;
  unawaited(
    settings.saveTrackFxChain(
      channel,
      encodeFxChain(
        FxChainEnvelope(
          chainEnabled: looper.trackChainEnabled(channel),
          entries: looper.trackEffects(channel),
        ),
      ),
    ),
  );
}

/// Writes lane [lane] of track [channel]'s chain envelope — entries, the
/// chain-enabled flag, and the inheritance meta, all on the one `lane_effects`
/// key (R15) — to the settings store.
///
/// The lane twin of [persistTrackFxChain], and shared for the same reason: a
/// second copy of this encoding is how a stomped lane chain comes back
/// engaged on the next boot.
void persistLaneFxChain({
  required SettingsRepository? settings,
  required LooperRepository looper,
  required int channel,
  required int lane,
}) {
  if (settings == null) return;
  unawaited(
    settings.saveLaneEffects(
      channel,
      lane,
      encodeLaneFxChain(looper: looper, channel: channel, lane: lane),
    ),
  );
}

/// Encodes lane [lane] of [channel]'s CURRENT chain as its persisted envelope
/// string, read from the repository — the authority every lane write lands in
/// synchronously, and the only place a plugin entry carries its resolved
/// display name.
String encodeLaneFxChain({
  required LooperRepository looper,
  required int channel,
  required int lane,
}) => encodeFxChain(
  FxChainEnvelope(
    chainEnabled: looper.laneChainEnabled(channel, lane),
    meta: FxChainMeta(
      inheritedFrom: looper.laneChainInheritedFrom(channel, lane),
    ),
    entries: looper.laneEffects(channel, lane),
  ),
);

/// Writes the Master insert's chain envelope to the settings store. There is
/// exactly one, so it is overwritten rather than keyed.
void persistMasterFxChain({
  required SettingsRepository? settings,
  required LooperRepository looper,
}) {
  if (settings == null) return;
  unawaited(
    settings.saveMasterFxChain(
      encodeFxChain(
        FxChainEnvelope(
          chainEnabled: looper.masterChainEnabled,
          entries: looper.masterEffects,
        ),
      ),
    ),
  );
}

/// Writes whichever chain [address] names, for a caller holding a typed FX
/// address rather than a stage-specific one — a pedal/MIDI binding, or the
/// FX-mode cell's tap, both of which flip a target on ANY stage.
///
/// An Input address writes NOTHING here on purpose: a monitor's envelope
/// belongs to `MonitorCubit`, which follows `LooperRepository.monitorChanges`
/// and saves what it reads back. Writing it here as well would give one
/// settings key two writers.
void persistFxChainAt({
  required SettingsRepository? settings,
  required LooperRepository looper,
  required FxAddress address,
}) {
  final lane = address.lane;
  switch (address.stage) {
    case FxStage.input:
      return;
    case FxStage.loop:
      // A lane-less Loop address names no chain at all (A9), so there is
      // nothing to write.
      if (lane == null) return;
      persistLaneFxChain(
        settings: settings,
        looper: looper,
        channel: address.index,
        lane: lane,
      );
    case FxStage.track:
      persistTrackFxChain(
        settings: settings,
        looper: looper,
        channel: address.index,
      );
    case FxStage.master:
      persistMasterFxChain(settings: settings, looper: looper);
  }
}
