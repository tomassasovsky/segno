import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/fx_chain_lookup.dart';
import 'package:settings_repository/settings_repository.dart';

/// Shared application-owned durable projection for MIDI momentary FX values.
/// ControlCubit publishes only the effective winner from its shared holder
/// ledger. This object never interprets mappings or arbitrates source priority.
class FxChainPersistence {
  /// Binds projection lifetime to the same live repository used by its clients.
  FxChainPersistence({required LooperRepository looper}) : _looper = looper;

  final LooperRepository _looper;
  int? _session;
  final _pending = <Object, Completer<void>>{};
  Map<FxBindingTarget, bool> _powers = {};
  Map<FxParamTarget, double> _parameters = {};

  final _saves = <Future<void>>{};

  /// Tracks asynchronous writes started by debounced UI persistence.
  Future<void> trackSave(Future<void> save) {
    final tracked = save.whenComplete(() => _saves.remove(save));
    _saves.add(save);
    return tracked;
  }

  /// Waits for admitted receipts and every save launched before shutdown.
  Future<void> flush() async {
    await settlePending();
    while (_saves.isNotEmpty) {
      await Future.wait(_saves.toList());
    }
  }

  /// Reports an accepted ordinary target write to the shared holder owner.
  void Function(Object target, double value)? onOrdinaryWrite;

  void _syncSession() {
    if (_session == _looper.sessionRevision) return;
    _session = _looper.sessionRevision;
    _powers = {};
    _parameters = {};
    for (final ticket in _pending.values) {
      ticket.complete();
    }
    _pending.clear();
  }

  /// Registers an admitted native recipe before yielding to its receipt.
  Object beginPending() {
    _syncSession();
    final ticket = Object();
    _pending[ticket] = Completer<void>();
    return ticket;
  }

  /// Publishes the controller ledger's effective Released substitutions.
  void replace({
    required Map<FxBindingTarget, bool> powers,
    required Map<FxParamTarget, double> parameters,
  }) {
    _syncSession();
    _powers = Map.unmodifiable(powers);
    _parameters = Map.unmodifiable(parameters);
  }

  /// Releases exactly one receipt barrier after its outcome was published.
  void finishPending(Object ticket) {
    _syncSession();
    _pending.remove(ticket)?.complete();
  }

  /// Saves wait for admitted MIDI recipes to receive an applied/refused result.
  Future<void> settlePending() async {
    _syncSession();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.values.map((ticket) => ticket.future));
      _syncSession();
    }
  }

  /// Records the precise parameter changed by a UI writer after its receipt.
  void ordinaryParameterAt(
    FxAddress address,
    int index,
    int parameter,
    double value,
  ) {
    final entries = _looper.chainEntriesAt(address);
    if (entries == null || index < 0 || index >= entries.length) return;
    final id = entries[index].slotId;
    if (id == null) return;
    _ordinaryConfirmed(
      FxParamTarget(address: address, slotId: id, param: parameter),
      value,
    );
  }

  /// Records only the explicitly edited effect activation.
  void ordinarySlotAt(FxAddress address, int index, {required bool enabled}) {
    final entries = _looper.chainEntriesAt(address);
    if (entries == null || index < 0 || index >= entries.length) return;
    final id = entries[index].slotId;
    if (id == null) return;
    _ordinaryConfirmed(
      FxSlotTarget(address: address, slotId: id),
      enabled ? 1 : 0,
    );
  }

  /// Records whole-chain activation without clearing parameter holds.
  void ordinaryChain(FxAddress address, {required bool enabled}) =>
      _ordinaryConfirmed(FxChainTarget(address), enabled ? 1 : 0);

  /// Confirms a built-in binding's explicit stable activation target.
  void ordinaryTarget(FxBindingTarget target, {required bool enabled}) =>
      _ordinaryConfirmed(target, enabled ? 1 : 0);

  void _ordinaryConfirmed(Object target, double value) {
    final session = _looper.sessionRevision;
    final ticket = beginPending();
    unawaited(() async {
      try {
        final result = await _looper.settleFxRecipes(
          waitForCallback: true,
          cancelled: () => _looper.sessionRevision != session,
        );
        if (result.isOk && _looper.sessionRevision == session) {
          ordinaryWrite(target, value);
        }
      } finally {
        finishPending(ticket);
      }
    }());
  }

  /// Ordinary UI writes supersede only their explicit stable target.
  void ordinaryWrite(Object target, double value) {
    _syncSession();
    if (target is FxBindingTarget) _powers = {..._powers}..remove(target);
    if (target is FxParamTarget) _parameters = {..._parameters}..remove(target);
    onOrdinaryWrite?.call(target, value);
  }

  /// Projects an acknowledged envelope, preserving unrelated fields.
  FxChainEnvelope project(FxAddress address, FxChainEnvelope live) {
    _syncSession();
    return FxChainEnvelope(
      chainEnabled: _powers[FxChainTarget(address)] ?? live.chainEnabled,
      meta: live.meta,
      entries: [
        for (final effect in live.entries) _projectEffect(address, effect),
      ],
    );
  }

  TrackEffect _projectEffect(FxAddress address, TrackEffect effect) {
    final id = effect.slotId;
    if (id == null) return effect;
    final enabled =
        _powers[FxSlotTarget(address: address, slotId: id)] ?? effect.enabled;
    return switch (effect) {
      BuiltInEffect() => effect.copyWith(
        enabled: enabled,
        params: [
          for (var index = 0; index < effect.params.length; index++)
            _parameters[FxParamTarget(
                  address: address,
                  slotId: id,
                  param: index,
                )] ??
                effect.params[index],
        ],
      ),
      PluginEffect() => effect.copyWith(enabled: enabled),
    };
  }
}

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
  required FxChainPersistence projection,
  required int channel,
}) {
  unawaited(
    saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: channel,
    ),
  );
}

/// Awaitable twin for lifecycle-fenced FX writes.
Future<void> saveTrackFxChain({
  required SettingsRepository? settings,
  required LooperRepository looper,
  required FxChainPersistence projection,
  required int channel,
}) => projection.trackSave(() async {
  if (settings == null) return;
  final session = looper.sessionRevision;
  await projection.settlePending();
  if (session != looper.sessionRevision) return;
  await settings.saveTrackFxChain(
    channel,
    encodeFxChain(
      projection.project(
        FxAddress(stage: FxStage.track, index: channel),
        FxChainEnvelope(
          chainEnabled: looper.trackChainEnabled(channel),
          entries: looper.trackEffects(channel),
        ),
      ),
    ),
  );
}());

/// Persists an acknowledged complete FX owner, retaining lane provenance.
Future<void> saveFxOwner({
  required SettingsRepository settings,
  required LooperRepository looper,
  required FxChainPersistence projection,
  required FxAddress address,
}) => projection.trackSave(() async {
  final session = looper.sessionRevision;
  await projection.settlePending();
  if (session != looper.sessionRevision) return;
  String encode(
    List<TrackEffect> entries, {
    required bool enabled,
    FxChainMeta? meta,
  }) => encodeFxChain(
    projection.project(
      address,
      FxChainEnvelope(
        entries: entries,
        chainEnabled: enabled,
        meta: meta ?? const FxChainMeta(),
      ),
    ),
  );
  return switch (address.stage) {
    FxStage.input => settings.saveMonitorEffects(
      address.index,
      encode(
        looper.monitorEffects(address.index),
        enabled: looper.monitorChainEnabled(address.index),
      ),
    ),
    FxStage.loop => settings.saveLaneEffects(
      address.index,
      address.lane!,
      encode(
        looper.laneEffects(address.index, address.lane!),
        enabled: looper.laneChainEnabled(address.index, address.lane!),
        meta: FxChainMeta(
          inheritedFrom: looper.laneChainInheritedFrom(
            address.index,
            address.lane!,
          ),
        ),
      ),
    ),
    FxStage.track => saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: address.index,
    ),
    FxStage.allTracks => settings.saveAllTracksFxChain(
      encode(looper.allTracksEffects, enabled: looper.allTracksChainEnabled),
    ),
    FxStage.output => settings.saveOutputFxChain(
      address.index,
      encode(
        looper.outputEffects(address.index),
        enabled: looper.outputChainEnabled(address.index),
      ),
    ),
  };
}());
