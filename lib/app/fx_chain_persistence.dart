import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:settings_repository/settings_repository.dart';

/// Application-owned FX saves and Released-value projection.
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
  final _dirty = <FxAddress, _FxSave>{};
  final _writing = <FxAddress, Future<void>>{};
  final _scheduled = <FxAddress, Timer>{};
  StreamSubscription<({int mixGeneration, int sessionRevision})>? _replay;
  Completer<void>? _sessionBootBarrier;
  Completer<void>? _sessionBootOutcome;
  _SessionBootImage? _sessionBootRecovery;
  bool _sessionLoadRequested = false;
  bool _sessionBootFailed = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  /// Whether a loaded rig still owes its complete boot-settings image.
  bool get sessionBootRecoveryRequired => _sessionBootRecovery != null;

  /// Whether a session replacement is excluding ordinary FX storage writes.
  bool get sessionTransitionActive =>
      _sessionLoadRequested || _sessionBootBarrier != null;

  /// Closes control admission synchronously, before a load's first await.
  void reserveSessionLoad() {
    if (_sessionLoadRequested ||
        _sessionBootBarrier != null ||
        _sessionBootRecovery != null) {
      throw StateError('session load is already active');
    }
    _sessionLoadRequested = true;
    _sessionBootOutcome = Completer<void>();
  }

  /// Drains outgoing edits, then reserves the one FX/monitor storage boundary.
  Future<void> beginSessionLoad() async {
    if (!_sessionLoadRequested ||
        _sessionBootBarrier != null ||
        _sessionBootRecovery != null) {
      throw StateError('session boot settings still need recovery');
    }
    await _flushOutgoing();
    if (_sessionBootBarrier != null || _sessionBootRecovery != null) {
      throw StateError('session boot settings still need recovery');
    }
    _sessionBootBarrier = Completer<void>();
  }

  /// Releases a reservation when the new rig was never accepted.
  void cancelSessionLoad() {
    if (_sessionBootRecovery != null) return;
    _sessionLoadRequested = false;
    _completeSessionBootOutcome();
    _releaseSessionBootBarrier();
  }

  /// Reports a post-apply failure to flush waiters without releasing writes.
  void markSessionBootFailed() {
    _sessionBootFailed = true;
    _completeSessionBootOutcome();
  }

  /// Captures and persists every boot FX/monitor key after a rig was accepted.
  /// A failed image remains immutable for [retrySessionBoot].
  Future<void> persistLoadedSession(SettingsRepository settings) async {
    if (_sessionBootBarrier == null || _sessionBootRecovery != null) {
      throw StateError('no session boot reservation');
    }
    final image = _captureSessionBoot(settings);
    _sessionBootRecovery = image;
    await retrySessionBoot();
  }

  /// Replays the exact captured image, including keys omitted by the session.
  Future<void> retrySessionBoot() async {
    final image = _sessionBootRecovery;
    if (image == null) return;
    if (image.session != _looper.sessionRevision) {
      throw StateError('session changed before boot-settings recovery');
    }
    final rig = _looper.state;
    if (rig.status.isConnected &&
        (image.mixGeneration != _looper.mixGeneration ||
            image.device != rig.status.deviceName)) {
      throw StateError('audio device changed before boot-settings recovery');
    }
    await settlePending();
    await _writeSessionBoot(image);
  }

  /// Commits the load barrier after its bindings have also been installed.
  void completeSessionBoot() {
    if (_sessionBootRecovery == null) {
      throw StateError('no completed session boot image');
    }
    _sessionBootRecovery = null;
    _sessionBootFailed = false;
    _sessionLoadRequested = false;
    _completeSessionBootOutcome();
    _releaseSessionBootBarrier();
  }

  void _completeSessionBootOutcome() {
    final outcome = _sessionBootOutcome;
    if (outcome != null && !outcome.isCompleted) outcome.complete();
    _sessionBootOutcome = null;
  }

  void _releaseSessionBootBarrier() {
    _sessionBootBarrier?.complete();
    _sessionBootBarrier = null;
  }

  _SessionBootImage _captureSessionBoot(SettingsRepository settings) {
    final rig = _looper.state;
    final lanes = _looper.allLaneChains();
    final tracks = _looper.allTrackChains();
    final outputs = _looper.allOutputChains();
    final monitors = _looper.allMonitors();
    final chains = <FxAddress, String?>{};
    final laneMutes = <(int, int), bool>{};
    String encoded(FxAddress address, FxChainEnvelope envelope) =>
        encodeFxChain(project(address, envelope));

    // Boot restore has eight track slots even before the native track array
    // exists. An absent slot must clear its old lane and track keys too.
    for (var channel = 0; channel < 8; channel++) {
      for (var lane = 0; lane < kMaxLanes; lane++) {
        final address = FxAddress(
          stage: FxStage.loop,
          index: channel,
          lane: lane,
        );
        laneMutes[(channel, lane)] = _looper.laneMuted(channel, lane);
        final saved = lanes[(channel, lane)];
        chains[address] = saved == null ? null : encoded(address, saved);
      }
      final address = FxAddress(stage: FxStage.track, index: channel);
      final saved = tracks[channel];
      chains[address] = saved == null ? null : encoded(address, saved);
    }
    for (var bus = 0; bus < kMaxOutputBuses; bus++) {
      final address = FxAddress(stage: FxStage.output, index: bus);
      final saved = outputs[bus];
      chains[address] = saved == null ? null : encoded(address, saved);
    }
    const allTracks = FxAddress(stage: FxStage.allTracks);
    chains[allTracks] = encoded(allTracks, _looper.allTracksChainEnvelope());

    final inputs = <int, _SessionBootMonitor>{};
    for (var input = 0; input < kMaxMonitoredInputs; input++) {
      final monitor = monitors[input] ?? InputMonitor(input: input);
      final address = FxAddress(stage: FxStage.input, index: input);
      inputs[input] = _SessionBootMonitor(
        mode: monitor.mode.name,
        outputMask: monitor.outputMask,
        muted: monitor.muted,
        effects: encoded(
          address,
          FxChainEnvelope(
            entries: monitor.effects,
            chainEnabled: monitor.chainEnabled,
          ),
        ),
      );
    }
    return _SessionBootImage(
      settings: settings,
      session: _looper.sessionRevision,
      mixGeneration: _looper.mixGeneration,
      device: rig.status.deviceName,
      chains: Map.unmodifiable(chains),
      laneMutes: Map.unmodifiable(laneMutes),
      monitors: Map.unmodifiable(inputs),
    );
  }

  Future<void> _writeSessionBoot(_SessionBootImage image) async {
    final settings = image.settings;
    for (final entry in image.chains.entries) {
      final address = entry.key;
      final encoded = entry.value;
      final stored = switch (address.stage) {
        FxStage.loop => () async {
          final lane = address.lane!;
          if (encoded == null) {
            await settings.clearLaneEffects(address.index, lane);
          } else {
            await settings.saveLaneEffects(address.index, lane, encoded);
          }
          return settings.loadLaneEffects(address.index, lane);
        }(),
        FxStage.track => () async {
          if (encoded == null) {
            await settings.clearTrackFxChain(address.index);
          } else {
            await settings.saveTrackFxChain(address.index, encoded);
          }
          return settings.loadTrackFxChain(address.index);
        }(),
        FxStage.output => () async {
          if (encoded == null) {
            await settings.clearOutputFxChain(address.index);
          } else {
            await settings.saveOutputFxChain(address.index, encoded);
          }
          return settings.loadOutputFxChain(address.index);
        }(),
        FxStage.allTracks => () async {
          await settings.saveAllTracksFxChain(encoded!);
          return settings.loadAllTracksFxChain();
        }(),
        FxStage.input => throw StateError('monitor FX is saved with its input'),
      };
      if (await stored != encoded) {
        throw StateError('session FX boot settings were not confirmed');
      }
    }
    for (final entry in image.laneMutes.entries) {
      await settings.saveLaneMute(
        entry.key.$1,
        entry.key.$2,
        muted: entry.value,
      );
    }
    for (final entry in image.monitors.entries) {
      final input = entry.key;
      final value = entry.value;
      await settings.saveMonitorInputMode(input, mode: value.mode);
      if (await settings.loadMonitorInputMode(input) != value.mode) {
        throw StateError('session monitor mode was not confirmed');
      }
      await settings.saveMonitorOutput(input, value.outputMask);
      if (await settings.loadMonitorOutput(input) != value.outputMask) {
        throw StateError('session monitor output was not confirmed');
      }
      await settings.saveMonitorMute(input, muted: value.muted);
      if (await settings.loadMonitorMute(input) != value.muted) {
        throw StateError('session monitor mute was not confirmed');
      }
      await settings.saveMonitorEffects(input, value.effects);
      if (await settings.loadMonitorEffects(input) != value.effects) {
        throw StateError('session monitor FX was not confirmed');
      }
    }
  }

  /// Retains an admitted recipe's save before its pending receipt is released.
  /// The caller then awaits [saveConfirmed] after [finishPending], since a save
  /// itself waits for all pending native receipts.
  void retainConfirmed(FxAddress address, SettingsRepository settings) {
    if (_closed) return;
    _queue(address, settings);
  }

  /// Persists the latest confirmed owner, retaining failed writes for retry.
  /// The queue is shared by track and input editors and contains no rig copy.
  Future<void> saveConfirmed(
    FxAddress address,
    SettingsRepository settings,
  ) => _saveConfirmed(address, settings);

  Future<void> _saveConfirmed(
    FxAddress address,
    SettingsRepository settings, {
    bool completeOnClose = false,
  }) async {
    if (_closed) return;
    _queue(address, settings, completeOnClose: completeOnClose);
    _scheduled.remove(address)?.cancel();
    await _startSave(address);
    final failure = _dirty[address]?.failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  /// Coalesces knob movement without delaying the live audio change.
  /// Shutdown flushes this work; failures remain dirty for a later retry.
  void scheduleSave(
    FxAddress address,
    SettingsRepository settings, {
    Duration debounce = const Duration(milliseconds: 250),
  }) {
    if (_closed) return;
    _queue(address, settings);
    _scheduled.remove(address)?.cancel();
    if (debounce <= Duration.zero) {
      unawaited(_startSave(address));
      return;
    }
    _scheduled[address] = Timer(debounce, () {
      _scheduled.remove(address);
      unawaited(_startSave(address));
    });
  }

  /// Starts queued edits when a borrowed UI owner closes. The application
  /// retains failures and awaits [flush] before shutdown.
  void flushScheduled() {
    _syncSession();
    final addresses = _scheduled.keys.toList();
    _cancelScheduled();
    for (final address in addresses) {
      unawaited(_startSave(address));
    }
  }

  void _queue(
    FxAddress address,
    SettingsRepository settings, {
    bool completeOnClose = false,
  }) {
    _syncSession();
    _replay ??= _looper.fxReplayConfirmed.listen((replay) {
      if (_closed ||
          replay.mixGeneration != _looper.mixGeneration ||
          replay.sessionRevision != _looper.sessionRevision) {
        return;
      }
      _syncSession();
      for (final address in _dirty.keys.toList()) {
        if (!_scheduled.containsKey(address)) {
          unawaited(_startSave(address));
        }
      }
    });
    _dirty[address] = _FxSave(
      settings,
      _looper.sessionRevision,
      completeOnClose:
          completeOnClose || (_dirty[address]?.completeOnClose ?? false),
    );
  }

  Future<void> _startSave(FxAddress address) {
    final running = _writing[address];
    if (running != null) return running;
    final saving = _drain(address);
    _writing[address] = saving;
    return saving.whenComplete(() => _writing.remove(address));
  }

  Future<void> _drain(FxAddress address) async {
    while (!_closed || (_dirty[address]?.completeOnClose ?? false)) {
      final boot = _sessionBootBarrier;
      if (boot != null) await boot.future;
      final pending = _dirty[address];
      if (pending == null) return;
      if (pending.session != _looper.sessionRevision) {
        _dirty.remove(address);
        return;
      }
      var attempted = pending;
      try {
        if (!_looper.fxRecipesSettled) {
          final receipt = await _looper.settleFxRecipes(
            waitForCallback: true,
            cancelled: () =>
                (_closed && !(_dirty[address]?.completeOnClose ?? false)) ||
                pending.session != _looper.sessionRevision,
          );
          if (!receipt.isOk) {
            throw StateError('FX changes are not confirmed: $receipt');
          }
        }
        if (_closed && !(_dirty[address]?.completeOnClose ?? false)) return;
        if (pending.session != _looper.sessionRevision) continue;
        await settlePending();
        if (_closed && !(_dirty[address]?.completeOnClose ?? false)) return;
        if (pending.session != _looper.sessionRevision) continue;
        // Edits before storage admission share this snapshot. Edits during
        // storage retain their newer token and require the following write.
        final latest = _dirty[address];
        if (latest == null) return;
        if (latest.session != _looper.sessionRevision) continue;
        attempted = latest;
        if (address.stage == FxStage.input) {
          await _saveMonitor(address.index, attempted.settings);
        } else {
          await _writeFxOwner(
            settings: attempted.settings,
            looper: _looper,
            projection: this,
            address: address,
          );
        }
        if (identical(_dirty[address], attempted)) {
          _dirty.remove(address);
          return;
        }
      } on Object catch (error, stack) {
        // Failure finishes this admitted attempt. Its dirty retry is not a
        // new disposal obligation until another controller save admits it.
        attempted
          ..failure = (error, stack)
          ..completeOnClose = false;
        if (identical(_dirty[address], attempted)) return;
      }
    }
  }

  /// Saves input routing and mute alongside its confirmed, Released FX values.
  /// An absent monitor is persisted as disabled, including after session load.
  Future<void> _saveMonitor(int input, SettingsRepository settings) async {
    final session = _looper.sessionRevision;
    final monitor = _looper.allMonitors()[input] ?? InputMonitor(input: input);
    final encoded = encodeFxChain(
      project(
        FxAddress(stage: FxStage.input, index: input),
        FxChainEnvelope(
          entries: _looper.monitorEffects(input),
          chainEnabled: _looper.monitorChainEnabled(input),
        ),
      ),
    );
    await settings.saveMonitorInputMode(input, mode: monitor.mode.name);
    if (session != _looper.sessionRevision) return;
    await settings.saveMonitorOutput(input, monitor.outputMask);
    if (session != _looper.sessionRevision) return;
    await settings.saveMonitorMute(input, muted: monitor.muted);
    if (session != _looper.sessionRevision) return;
    await settings.saveMonitorEffects(input, encoded);
  }

  /// Retires the application owner after its caller has attempted [flush].
  /// Waits for outstanding receipts and started storage work after failure.
  /// Disposal discards queued retries; a failed flush is not a durable save.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _sessionLoadRequested = false;
    _completeSessionBootOutcome();
    _releaseSessionBootBarrier();
    _cancelScheduled();
    // Started controller saves keep their receipt/storage obligation. Failed
    // retries and ordinary queued edits still require the caller's flush.
    _dirty.removeWhere((_, save) => !save.completeOnClose);
    // Genuine receipts still belong to their callers. Completing them here
    // would release a tracked save before the audio callback acknowledges it.
    // Release only our boot barrier above so cancelled drains cannot deadlock.
    await Future.wait<void>([
      ?_replay?.cancel(),
      settlePending(),
      ..._writing.values,
      ..._saves,
    ]);
  }

  /// Tracks an already-admitted asynchronous write, including UI persistence.
  /// Admission is checked by [saveConfirmed] or [saveFxOwner] before this call;
  /// a Future argument has already started and cannot be rejected here.
  Future<void> trackSave(Future<void> save) {
    final tracked = save.whenComplete(() => _saves.remove(save));
    _saves.add(save);
    return tracked;
  }

  /// Waits for admitted receipts and every save launched before shutdown.
  Future<void> flush() async {
    final outcome = _sessionBootOutcome;
    if (outcome != null) await outcome.future;
    if (_sessionBootRecovery != null || _sessionBootFailed) {
      throw StateError('session boot settings still need recovery');
    }
    await _flushOutgoing();
  }

  Future<void> _flushOutgoing() async {
    _cancelScheduled();
    await settlePending();
    await Future.wait(_writing.values.toList());
    _syncSession();
    await Future.wait(_dirty.keys.toList().map(_startSave));
    while (_saves.isNotEmpty) {
      await Future.wait(_saves.toList());
    }
    for (final pending in _dirty.values) {
      final failure = pending.failure;
      if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }

  /// Reports an accepted ordinary target write to the shared holder owner.
  void Function(Object target, double value)? onOrdinaryWrite;

  void _cancelScheduled() {
    for (final timer in _scheduled.values) {
      timer.cancel();
    }
    _scheduled.clear();
  }

  void _syncSession() {
    if (_session == _looper.sessionRevision) return;
    _session = _looper.sessionRevision;
    _cancelScheduled();
    _dirty.clear();
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
  required FxChainPersistence projection,
  required int channel,
}) {
  unawaited(
    saveTrackFxChain(
      settings: settings,
      projection: projection,
      channel: channel,
    ),
  );
}

/// Awaitable twin for lifecycle-fenced FX writes.
Future<void> saveTrackFxChain({
  required SettingsRepository? settings,
  required FxChainPersistence projection,
  required int channel,
}) async {
  if (settings == null) return;
  await saveFxOwner(
    settings: settings,
    projection: projection,
    address: FxAddress(stage: FxStage.track, index: channel),
  );
}

/// Persists an acknowledged complete FX owner, retaining lane provenance.
Future<void> saveFxOwner({
  required SettingsRepository settings,
  required FxChainPersistence projection,
  required FxAddress address,
}) {
  return projection.trackSave(
    projection._saveConfirmed(address, settings, completeOnClose: true),
  );
}

Future<void> _writeFxOwner({
  required SettingsRepository settings,
  required LooperRepository looper,
  required FxChainPersistence projection,
  required FxAddress address,
}) {
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
    FxStage.loop => () async {
      final session = looper.sessionRevision;
      final muted = looper.laneMuted(address.index, address.lane!);
      await settings.saveLaneEffects(
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
      );
      if (session != looper.sessionRevision) return;
      await settings.saveLaneMute(address.index, address.lane!, muted: muted);
    }(),
    FxStage.track => settings.saveTrackFxChain(
      address.index,
      encode(
        looper.trackEffects(address.index),
        enabled: looper.trackChainEnabled(address.index),
      ),
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
}

class _FxSave {
  _FxSave(this.settings, this.session, {required this.completeOnClose});
  final SettingsRepository settings;
  final int session;
  bool completeOnClose;
  (Object, StackTrace)? failure;
}

class _SessionBootImage {
  const _SessionBootImage({
    required this.settings,
    required this.session,
    required this.mixGeneration,
    required this.device,
    required this.chains,
    required this.laneMutes,
    required this.monitors,
  });

  final SettingsRepository settings;
  final int session;
  final int mixGeneration;
  final String device;
  final Map<FxAddress, String?> chains;
  final Map<(int, int), bool> laneMutes;
  final Map<int, _SessionBootMonitor> monitors;
}

class _SessionBootMonitor {
  const _SessionBootMonitor({
    required this.mode,
    required this.outputMask,
    required this.muted,
    required this.effects,
  });

  final String mode;
  final int outputMask;
  final bool muted;
  final String effects;
}
