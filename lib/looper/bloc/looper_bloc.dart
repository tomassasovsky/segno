import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/common/write_debouncer.dart';
import 'package:settings_repository/settings_repository.dart';

part 'looper_event.dart';

/// Drives the multi-track looper transport from UI events and
/// mirrors the repository's [LooperState] stream as the bloc state.
///
/// Commands are forwarded to the repository; the resulting engine state flows
/// back through the stream, keeping the repository the single source of truth.
/// Hardware assignments are interpreted by the shared control layer.
class LooperBloc extends Bloc<LooperEvent, LooperState> {
  /// Creates a [LooperBloc] backed by [repository].
  LooperBloc({
    required LooperRepository repository,
    required MixSettingsCoordinator mixSettings,
    required FxChainPersistence fxPersistence,
    SettingsRepository? settings,
    Duration fxPersistDebounce = const Duration(milliseconds: 300),
    bool Function() takeLocked = _neverLocked,
  }) : _repository = repository,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _settings = settings,
       _takeLocked = takeLocked,
       _fxPersist = WriteDebouncer(debounce: fxPersistDebounce),
       super(const LooperState()) {
    on<LooperStateUpdated>((event, emit) {
      // Persist only settled reports from a connected engine. A settlement
      // can repeat the visible state after a rejected request or boot replay.
      final settled = _repository.settledLooperMode;
      if (event.state.status.isConnected && settled != null) {
        _persistLooperMode(settled);
      }
      emit(event.state);
    });
    on<LooperRecordPressed>((event, _) {
      if (_takeLocked()) return;
      _repository.record(channel: event.channel);
    });
    on<LooperStopPressed>(
      (event, _) => _repository.stopTrack(channel: event.channel),
    );
    on<LooperPlayPressed>(
      (event, _) => _repository.play(channel: event.channel),
    );
    on<LooperClearPressed>((event, _) {
      if (_takeLocked()) return;
      _clearAndArm(event.channel);
    });
    on<LooperUndoPressed>(
      // Undo is per-layer all the way down: the engine peels one overdub pass
      // per press, and undoing past the base recording empties the track while
      // keeping the redo history, so redo can reinstate it layer by layer.
      (event, _) => _repository.undo(channel: event.channel),
    );
    on<LooperRedoPressed>(
      (event, _) => _repository.redo(channel: event.channel),
    );
    on<LooperVolumeChanged>((event, _) {
      unawaited(
        _mixSettings.setTrackVolume(event.volume, channel: event.channel),
      );
    });
    on<LooperMuteToggled>(
      // Resolved against the repository's remembered intent, NOT the
      // poll-mirrored [state]: the snapshot is ~16 ms stale, so a fast
      // double-toggle inside the echo window would read the pre-toggle
      // value twice and re-apply the first flip (staying muted) instead of
      // undoing it. Same discipline as `LooperTrackChainToggled` below.
      (event, _) => _repository.setMute(
        muted: !_repository.trackMuted(event.channel),
        channel: event.channel,
      ),
    );
    on<LooperRecordingInputChanged>((event, _) {
      unawaited(
        _mixSettings.setRecordingInput(
          channel: event.channel,
          input: event.input,
          selected: event.selected,
        ),
      );
    });
    on<LooperTrackOutputChanged>((event, _) {
      unawaited(
        _mixSettings.setTrackOutput(
          channel: event.channel,
          mask: event.mask,
        ),
      );
    });
    on<LooperLaneVolumeChanged>((event, _) {
      unawaited(
        _mixSettings.setLaneVolume(
          event.volume,
          channel: event.channel,
          lane: event.lane,
        ),
      );
    });
    on<LooperLaneMuteToggled>((event, _) {
      final muted = !_laneMuted(event.channel, event.lane);
      _repository.setLaneMute(
        muted: muted,
        channel: event.channel,
        lane: event.lane,
      );
      unawaited(
        _settings?.saveLaneMute(event.channel, event.lane, muted: muted),
      );
    });
    on<LooperLaneEffectAdded>((event, _) {
      _pushLaneEffects(event.channel, event.lane, [
        ..._repository.laneEffects(event.channel, event.lane),
        BuiltInEffect(type: event.type ?? TrackEffectType.drive),
      ]);
    });
    on<LooperLaneEffectsChanged>((event, _) {
      if ((event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final result = _pushLaneEffects(event.channel, event.lane, event.effects);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperLaneEffectsAppended>((event, _) {
      if (event.entries.isEmpty ||
          (event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final current = _repository.laneEffects(event.channel, event.lane);
      if (current.length + event.entries.length > kTrackEffectMax) {
        event.receipt?.complete(false);
        return;
      }
      final result = _pushLaneEffects(event.channel, event.lane, [
        ...current,
        ...event.entries,
      ]);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperLaneEffectRemoved>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.index < 0 || event.index >= effects.length) return;
      _pushLaneEffects(
        event.channel,
        event.lane,
        [...effects]..removeAt(event.index),
      );
    });
    on<LooperLaneEffectTypeChanged>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.index < 0 || event.index >= effects.length) return;
      final old = effects[event.index];
      _pushLaneEffects(
        event.channel,
        event.lane,
        [...effects]
          ..[event.index] = BuiltInEffect(
            type: event.type,
            // The bus handler's rule, which this stage was missing: a retype
            // changes the device, not the user's power decision, the slot's
            // identity, or where in the signal the player put it.
            enabled: old.enabled,
            slotId: old.slotId,
            placement: old.placement,
            channels: old.channels,
          ),
      );
    });
    on<LooperLaneEffectMoved>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.from < 0 || event.from >= effects.length) return;
      var target = event.to;
      if (target < 0) target = 0;
      if (target > effects.length - 1) target = effects.length - 1;
      if (event.from == target) return;
      // Reorder stays within a stage (slice 3e): the chain is stored
      // Pre-first, so a move across the boundary would be re-partitioned back
      // and land somewhere nobody asked for. Placement moves through the
      // placement control, which says where it lands.
      if (effects[event.from].placement != effects[target].placement) return;
      final next = [...effects];
      next.insert(target, next.removeAt(event.from));
      _pushLaneEffects(event.channel, event.lane, next);
    });
    on<LooperLaneEffectChannelsChanged>((event, _) {
      final effects = _repository.laneEffects(event.channel, event.lane);
      if (event.index < 0 || event.index >= effects.length) return;
      final slotId = effects[event.index].slotId;
      if (slotId == null) return;
      // By identity, like placement: channel handling belongs to the
      // INSTANCE, and an index is what a reorder or a placement move changes.
      final result = _repository.setLaneEffectChannels(
        channel: event.channel,
        lane: event.lane,
        slotId: slotId,
        channels: event.channels,
      );
      if (!result.isOk) return;
      _persistRepositoryLaneChain(event.channel, event.lane);
    });
    on<LooperBusEffectChannelsChanged>((event, _) {
      final chain = _busChain(event.address);
      if (event.index < 0 || event.index >= chain.length) return;
      // A bus stage has no by-slot channel setter: channel handling rides the
      // entry, and the whole-chain push is what carries an entry's own fields
      // to the engine. Re-pushing a chain re-sends every slot's type, which
      // resets that slot's DSP — acceptable here because this is a settled
      // choice, not a swept knob.
      _pushBusChain(event.address, [
        for (var i = 0; i < chain.length; i++)
          if (i == event.index)
            _withChannels(chain[i], event.channels)
          else
            chain[i],
      ]);
    });
    on<LooperAllTracksEffectChannelsChanged>((event, _) {
      final chain = _repository.allTracksEffects;
      if (event.index < 0 || event.index >= chain.length) return;
      final result = _repository.setAllTracksEffects(
        effects: [
          for (var i = 0; i < chain.length; i++)
            if (i == event.index)
              _withChannels(chain[i], event.channels)
            else
              chain[i],
        ],
      );
      if (!result.isOk) return;
      _persistAfterFx(#allTracks, _saveAllTracksChain);
    });
    on<LooperLaneEffectPlacementChanged>((event, _) {
      final result = _repository.setLaneEffectPlacement(
        channel: event.channel,
        lane: event.lane,
        slotId: event.slotId,
        placement: event.placement,
      );
      if (!result.isOk) return;
      _persistRepositoryLaneChain(event.channel, event.lane);
    });
    on<LooperLaneEffectParamChanged>((event, _) {
      final result = _repository.setLaneEffectParam(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
        param: event.param,
        value: event.value,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryParameterAt(
        FxAddress(stage: FxStage.loop, index: event.channel, lane: event.lane),
        event.index,
        event.param,
        event.value,
      );
      // Re-save the whole chain (the engine call above was granular and did not
      // reset DSP; persistence stores the chain as one encoded string) — and
      // DEBOUNCED, because this is the knob-drag path: one pointer move used
      // to re-encode the envelope and rewrite the preferences file.
      _schedulePersistLaneChain(event.channel, event.lane);
    });
    on<LooperLanePluginParamChanged>((event, _) {
      final result = _repository.setLanePluginParam(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
        paramId: event.paramId,
        value: event.value,
      );
      if (!result.isOk) return;
      // Persist the whole chain (the param set above was granular); the encoded
      // chain carries the plugin's remembered paramValues. Debounced for the
      // same reason as the built-in param path above.
      _schedulePersistLaneChain(event.channel, event.lane);
    });
    on<LooperLanePluginInserted>((event, _) {
      _pushLaneEffects(event.channel, event.lane, [
        ..._repository.laneEffects(event.channel, event.lane),
        PluginEffect(ref: event.ref),
      ]);
    });
    on<LooperLanePluginRelinked>((event, _) {
      final result = _repository.relinkLanePlugin(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
        ref: event.ref,
      );
      if (!result.isOk) return;
      _persistRepositoryLaneChain(event.channel, event.lane);
    });
    on<LooperLaneEffectEnabledToggled>((event, _) {
      final result = _repository.setLaneEffectEnabled(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinarySlotAt(
        FxAddress(stage: FxStage.loop, index: event.channel, lane: event.lane),
        event.index,
        enabled: event.enabled,
      );
      _persistLaneChain(event.channel, event.lane);
    });
    on<LooperLaneChainEnabledToggled>((event, _) {
      final result = _repository.setLaneChainEnabled(
        channel: event.channel,
        lane: event.lane,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryChain(
        FxAddress(stage: FxStage.loop, index: event.channel, lane: event.lane),
        enabled: event.enabled,
      );
      _persistLaneChain(event.channel, event.lane);
    });
    on<LooperLaneChainResyncedFromInput>((event, _) {
      // A re-copy replaces every entry and reseats the lane's slots, so any
      // editor-sync poll keyed by a now-stale chain index must be cancelled —
      // otherwise it rebinds to whatever plugin lands at that index and the
      // replaced instance is destroyed with its native window still open.
      _cancelLaneEditorTimers(event.channel, event.lane);
      // The repository notifies `onLaneChainChanged` on a successful re-copy,
      // which persists the fresh envelope — nothing to persist here when it
      // declines (there was nothing inheritable to copy).
      _repository.resyncLaneChainFromInput(
        channel: event.channel,
        lane: event.lane,
      );
    });
    // Bus-stage chain surgery (Track + Master). Each handler composes the next
    // chain from the REPOSITORY's current one — never from `state`, which lags
    // by this hop — so edits dispatched together in one frame compose instead
    // of clobbering one another.
    on<LooperBusEffectAdded>((event, _) {
      final chain = _busChain(event.address);
      if (chain.length >= kTrackEffectMax) return;
      _pushBusChain(event.address, [
        ...chain,
        BuiltInEffect(type: event.type ?? TrackEffectType.drive),
      ]);
    });
    on<LooperBusEffectsChanged>((event, _) {
      if ((event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final result = _pushBusChain(event.address, event.effects);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperBusEffectsAppended>((event, _) {
      if (event.entries.isEmpty ||
          (event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final current = _busChain(event.address);
      if (current.length + event.entries.length > kTrackEffectMax) {
        event.receipt?.complete(false);
        return;
      }
      final result = _pushBusChain(event.address, [
        ...current,
        ...event.entries,
      ]);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperBusEffectRemoved>((event, _) {
      final chain = _busChain(event.address);
      if (event.index < 0 || event.index >= chain.length) return;
      _pushBusChain(event.address, [...chain]..removeAt(event.index));
    });
    on<LooperBusEffectMoved>((event, _) {
      final chain = _busChain(event.address);
      if (event.from < 0 || event.from >= chain.length) return;
      final to = event.to.clamp(0, chain.length - 1);
      if (event.from == to) return;
      // Reorder stays within a stage — see the lane handler. An output chain
      // is wholly Post, so this only ever refuses anything on the Track
      // stage.
      if (chain[event.from].placement != chain[to].placement) return;
      final next = [...chain];
      next.insert(to, next.removeAt(event.from));
      _pushBusChain(event.address, next);
    });
    on<LooperBusEffectTypeChanged>((event, _) {
      final chain = _busChain(event.address);
      if (event.index < 0 || event.index >= chain.length) return;
      final old = chain[event.index];
      _pushBusChain(
        event.address,
        [...chain]
          ..[event.index] = BuiltInEffect(
            type: event.type,
            // A retype changes the DEVICE, not the user's power decision, the
            // slot's identity, or its placement: keeping them means a
            // powered-off device stays off (D-POWER/R23), bindings targeting
            // the slot survive (A9), and the entry stays where it sat.
            enabled: old.enabled,
            slotId: old.slotId,
            placement: old.placement,
            channels: old.channels,
          ),
      );
    });
    on<LooperBusEffectParamChanged>((event, _) {
      // Granular, NOT a whole-chain push: re-pushing the chain would re-send
      // every slot's type, and the engine resets a slot's DSP state on every
      // type push — so a knob drag would clear the bus's reverb tails and
      // delay lines at pointer-move rate.
      final result = event.address.stage == FxStage.output
          ? _repository.setOutputEffectParam(
              bus: event.address.index,
              index: event.index,
              param: event.param,
              value: event.value,
            )
          : _repository.setTrackEffectParam(
              channel: event.address.index,
              index: event.index,
              param: event.param,
              value: event.value,
            );
      if (!result.isOk) return;
      _fxPersistence.ordinaryParameterAt(
        event.address,
        event.index,
        event.param,
        event.value,
      );
      // Debounced: the engine write above is per-move, this is per-drag.
      _schedulePersistBusChain(event.address);
    });
    on<LooperBusPluginInserted>((event, _) {
      final chain = _busChain(event.address);
      if (chain.length >= kTrackEffectMax) return;
      _pushBusChain(event.address, [...chain, PluginEffect(ref: event.ref)]);
    });
    on<LooperBusPluginParamChanged>((event, _) {
      // Granular, NOT a whole-chain push — the same argument as
      // [LooperBusEffectParamChanged] above, and it bites HARDER here: a bus
      // plugin never instantiates, so the chain re-push would reset the DSP of
      // the BUILT-INS sharing the bus without the plugin's own value even
      // having somewhere to go.
      final result = event.address.stage == FxStage.output
          ? _repository.setOutputPluginParam(
              bus: event.address.index,
              index: event.index,
              paramId: event.paramId,
              value: event.value,
            )
          : _repository.setTrackPluginParam(
              channel: event.address.index,
              index: event.index,
              paramId: event.paramId,
              value: event.value,
            );
      if (!result.isOk) return;
      // Debounced: the model write above is per-move, this is per-drag.
      _schedulePersistBusChain(event.address);
    });
    on<LooperBusPluginRelinked>((event, _) {
      final chain = _busChain(event.address);
      if (event.index < 0 || event.index >= chain.length) return;
      final old = chain[event.index];
      if (old is! PluginEffect) return;
      // Identity, placement, channels and power belong to this entry. A
      // different plugin id cannot inherit the old one's state bytes or
      // parameter ids, even while bus hosting is unavailable.
      final samePlugin = old.ref.id == event.ref.id;
      _pushBusChain(
        event.address,
        [...chain]
          ..[event.index] = old.copyWith(
            ref: event.ref,
            // …except the name, when this points at a DIFFERENT plugin: the
            // repository re-resolves it from the catalog, and if the catalog
            // cannot (cold, uninstalled) an empty name falls back to the id.
            // Keeping the old one would leave the card naming the plugin that
            // was just replaced, which is worse than naming none.
            name: samePlugin ? old.name : '',
            state: samePlugin ? old.state : '',
            paramValues: samePlugin ? old.paramValues : const {},
            unavailable: false,
            unsupported: false,
            versionChanged: false,
          ),
      );
    });
    on<LooperTrackEffectsChanged>((event, _) {
      final result = _repository.setTrackEffects(
        channel: event.channel,
        effects: event.effects,
      );
      if (!result.isOk) return;
      _persistAfterFx(
        (#track, event.channel),
        () => saveTrackFxChain(
          settings: _settings,
          looper: _repository,
          projection: _fxPersistence,
          channel: event.channel,
        ),
      );
    });
    on<LooperTrackEffectEnabledToggled>((event, _) {
      final result = _repository.setTrackEffectEnabled(
        channel: event.channel,
        index: event.index,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinarySlotAt(
        FxAddress(stage: FxStage.track, index: event.channel),
        event.index,
        enabled: event.enabled,
      );
      _persistTrackChain(event.channel);
    });
    on<LooperTrackChainEnabledToggled>((event, _) {
      final result = _repository.setTrackChainEnabled(
        channel: event.channel,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryChain(
        FxAddress(stage: FxStage.track, index: event.channel),
        enabled: event.enabled,
      );
      _persistTrackChain(event.channel);
    });
    on<LooperTrackChainToggled>((event, _) {
      // Resolved here, against the repository's remembered intent — the same
      // truth `ControlCubit` toggles from, and the same shape as the mute
      // toggle above.
      final result = _repository.setTrackChainEnabled(
        channel: event.channel,
        enabled: !_repository.trackChainEnabled(event.channel),
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryChain(
        FxAddress(stage: FxStage.track, index: event.channel),
        enabled: _repository.trackChainEnabled(event.channel),
      );
      _persistTrackChain(event.channel);
    });
    on<LooperOutputEffectsChanged>((event, _) {
      final result = _repository.setOutputEffects(
        bus: event.bus,
        effects: event.effects,
      );
      if (!result.isOk) return;
      _persistAfterFx((#output, event.bus), () => _saveOutputChain(event.bus));
    });
    on<LooperTrackEffectPlacementChanged>((event, _) {
      final result = _repository.setTrackEffectPlacement(
        channel: event.channel,
        slotId: event.slotId,
        placement: event.placement,
      );
      if (!result.isOk) return;
      _persistAfterFx(
        (#track, event.channel),
        () => saveTrackFxChain(
          settings: _settings,
          looper: _repository,
          projection: _fxPersistence,
          channel: event.channel,
        ),
      );
    });
    on<LooperAllTracksEffectsChanged>((event, _) {
      if ((event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final result = _repository.setAllTracksEffects(effects: event.effects);
      if (!result.isOk) {
        event.receipt?.complete(false);
        return;
      }
      _persistAfterFx(#allTracks, _saveAllTracksChain);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperAllTracksEffectsAppended>((event, _) {
      if (event.entries.isEmpty ||
          (event.cancelled?.call() ?? false) ||
          (event.expectedMixGeneration != null &&
              event.expectedMixGeneration != _repository.mixGeneration)) {
        event.receipt?.complete(false);
        return;
      }
      final current = _repository.allTracksEffects;
      if (current.length + event.entries.length > kTrackEffectMax) {
        event.receipt?.complete(false);
        return;
      }
      final result = _repository.setAllTracksEffects(
        effects: [...current, ...event.entries],
      );
      if (!result.isOk) {
        event.receipt?.complete(false);
        return;
      }
      _persistAfterFx(#allTracks, _saveAllTracksChain);
      _confirmFxReceipt(event.receipt, result, cancelled: event.cancelled);
    });
    on<LooperAllTracksEffectEnabledToggled>((event, _) {
      final result = _repository.setAllTracksEffectEnabled(
        index: event.index,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinarySlotAt(
        const FxAddress(stage: FxStage.allTracks),
        event.index,
        enabled: event.enabled,
      );
      _persistAllTracksChain();
    });
    on<LooperAllTracksChainEnabledToggled>((event, _) {
      final result = _repository.setAllTracksChainEnabled(
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryChain(
        const FxAddress(stage: FxStage.allTracks),
        enabled: event.enabled,
      );
      _persistAllTracksChain();
    });
    on<LooperAllTracksEffectParamChanged>((event, _) {
      // Granular, NOT a whole-chain push — see the bus param handler: a
      // re-push would reset every slot's DSP state at pointer-move rate.
      final result = _repository.setAllTracksEffectParam(
        index: event.index,
        param: event.param,
        value: event.value,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryParameterAt(
        const FxAddress(stage: FxStage.allTracks),
        event.index,
        event.param,
        event.value,
      );
      _persistAllTracksChain();
    });
    on<LooperOutputEffectEnabledToggled>((event, _) {
      final result = _repository.setOutputEffectEnabled(
        bus: event.bus,
        index: event.index,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinarySlotAt(
        FxAddress(stage: FxStage.output, index: event.bus),
        event.index,
        enabled: event.enabled,
      );
      _persistAfterFx((#output, event.bus), () => _saveOutputChain(event.bus));
    });
    on<LooperOutputChainEnabledToggled>((event, _) {
      final result = _repository.setOutputChainEnabled(
        bus: event.bus,
        enabled: event.enabled,
      );
      if (!result.isOk) return;
      _fxPersistence.ordinaryChain(
        FxAddress(stage: FxStage.output, index: event.bus),
        enabled: event.enabled,
      );
      _persistAfterFx((#output, event.bus), () => _saveOutputChain(event.bus));
    });
    on<LooperLanePluginEditorOpened>((event, _) {
      final key = (event.channel, event.lane, event.index);
      _repository.openLanePluginEditor(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
      );
      // Start (or restart) the ≤10 Hz inbound sync poll for this entry: each
      // tick reads the plugin's live param values back into the model, which
      // re-emits through the repository stream and moves the in-app knobs.
      _lanePluginEditorTimers.remove(key)?.cancel();
      _lanePluginEditorTimers[key] = Timer.periodic(_editorPollInterval, (
        timer,
      ) {
        _repository.refreshLanePluginParams(
          channel: event.channel,
          lane: event.lane,
          index: event.index,
        );
        // The user can close the native window directly; when it's gone, stop
        // polling so no timer leaks (D-WIN/D-SYNC).
        if (!_repository.isLanePluginEditorOpen(
          channel: event.channel,
          lane: event.lane,
          index: event.index,
        )) {
          timer.cancel();
          _lanePluginEditorTimers.remove(key);
        }
      });
    });
    on<LooperLanePluginEditorClosed>((event, _) {
      final key = (event.channel, event.lane, event.index);
      _lanePluginEditorTimers.remove(key)?.cancel(); // no leaked timer
      _repository.closeLanePluginEditor(
        channel: event.channel,
        lane: event.lane,
        index: event.index,
      );
    });
    on<LooperTrackRecordTimingChanged>((event, _) {
      final result = _repository.setTrackRecordTiming(
        channel: event.channel,
        timing: event.timing,
      );
      if (!result.isOk) return;
      unawaited(
        _settings?.saveTrackRecordTiming(event.channel, event.timing?.code),
      );
    });
    on<LooperTrackOverdubDecayChanged>((event, _) {
      final result = _repository.setTrackOverdubDecay(
        channel: event.channel,
        percent: event.percent,
      );
      if (!result.isOk) return;
      unawaited(
        _settings?.saveTrackOverdubDecay(event.channel, event.percent),
      );
    });
    on<LooperTrackLengthPresetChanged>((event, _) async {
      final sessionRevision = _repository.sessionRevision;
      final result = _repository.setTrackLengthPreset(
        channel: event.channel,
        bars: event.bars,
      );
      if (!result.isOk) return;
      final settled = await _repository.settleLengthSettings();
      if (!settled.isOk || sessionRevision != _repository.sessionRevision) {
        return;
      }
      await _settings?.saveTrackLengthPreset(
        event.channel,
        _repository.trackLengthPresetOverrides[event.channel],
      );
    });
    on<LooperOneShotToggled>((event, _) {
      final result = _repository.setOneShot(
        channel: event.channel,
        oneShot: event.oneShot,
      );
      if (result.isOk) {
        unawaited(
          _settings?.saveTrackOneShot(event.channel, oneShot: event.oneShot),
        );
      }
    });
    on<LooperTrackPanChanged>((event, _) {
      unawaited(_mixSettings.setTrackPan(event.pan, channel: event.channel));
    });
    on<LooperTrackSoloToggled>((event, _) {
      unawaited(
        _mixSettings.toggleTrackSolo(channel: event.channel),
      );
    });
    on<LooperSoloCleared>((_, _) {
      unawaited(_mixSettings.clearSolo());
    });
    on<LooperMixerReset>((_, _) {
      unawaited(_mixSettings.resetMixer());
    });
    on<LooperInputTrimChanged>((event, _) {
      unawaited(_mixSettings.setInputTrimDb(input: event.input, db: event.db));
    });
    on<LooperInputPanChanged>((event, _) {
      unawaited(_mixSettings.setInputPan(input: event.input, pan: event.pan));
    });
    on<LooperInputPairChanged>((event, _) {
      unawaited(
        _mixSettings.setInputPair(
          input: event.input,
          paired: event.paired,
        ),
      );
    });
    on<LooperInputBalanceChanged>((event, _) {
      unawaited(
        _mixSettings.setPairBalance(
          input: event.input,
          balance: event.balance,
        ),
      );
    });
    on<LooperOutputLevelChanged>((event, _) {
      unawaited(
        _mixSettings.setOutputLevel(bus: event.bus, level: event.level),
      );
    });
    on<LooperOutputMuteChanged>((event, _) {
      unawaited(_mixSettings.setOutputMute(bus: event.bus, muted: event.muted));
    });
    on<LooperOutputMonoChanged>((event, _) {
      unawaited(_mixSettings.setOutputMono(bus: event.bus, mono: event.mono));
    });
    on<LooperOutputBalanceChanged>((event, _) {
      unawaited(
        _mixSettings.setOutputBalance(
          bus: event.bus,
          balance: event.balance,
        ),
      );
    });
    on<LooperCutSoundPressed>((_, _) => _repository.cutSound());
    on<LooperCrownPrimaryPressed>(
      (event, _) => _repository.crownPrimary(channel: event.channel),
    );
    on<LooperModeChanged>((event, _) {
      _repository.setLooperMode(event.mode);
      // Offline choices are settled immediately. Running-engine choices
      // reach persistence through the reported-state handler after acceptance.
      final settled = _repository.settledLooperMode;
      if (settled != null) {
        _persistLooperMode(settled);
      }
    });
    on<LooperPlayAllPressed>((_, _) {
      for (final track in state.tracks) {
        if (track.hasContent) _repository.play(channel: track.channel);
      }
    });
    on<LooperStopAllPressed>((_, _) {
      for (final track in state.tracks) {
        _repository.stopTrack(channel: track.channel);
      }
    });
    on<LooperOutputEnabledToggled>((event, _) {
      _repository.setOutputEnabled(
        output: event.output,
        enabled: event.enabled,
      );
      // Keyed to the open device (the latency-offset precedent): the gate is
      // a fact about this interface's socket, not about "output N" anywhere.
      unawaited(
        _settings?.saveOutputEnabled(
          device: _repository.state.status.deviceName,
          output: event.output,
          enabled: event.enabled,
        ),
      );
    });
    on<LooperSessionLoaded>((_, _) => _resyncSessionChains());
    on<LooperPersistFlush>((event, _) async {
      try {
        _fxPersist.flush();
        await _fxPersistence.flush();
        event.receipt?.complete();
      } on Object catch (error, stackTrace) {
        if (event.receipt case final receipt?) {
          receipt.completeError(error, stackTrace);
        } else {
          addError(error, stackTrace);
        }
      }
    });

    _subscription = _repository.looperState.listen(
      (s) => add(LooperStateUpdated(s)),
    );
    _fxReplaySubscription = _repository.fxReplayConfirmed.listen(
      _onFxReplayConfirmed,
    );
    // Persist chains the repository mutates on its own — the record-time
    // snapshot-copy of a monitor chain onto the take's lanes (F3). The bloc
    // stays the single settings writer for chains.
    _repository.onLaneChainChanged = _persistRepositoryLaneChain;
  }

  /// Checks whether [expected] still owns the current engine life. The
  /// displayed state can lag a session replacement by one poll, so a modal
  /// edit checks the actual lifetime after each await. Writes remain events.
  // ignore: avoid_public_bloc_methods
  bool hasMixGeneration(int expected) =>
      !isClosed && _repository.mixGeneration == expected;

  final LooperRepository _repository;
  final MixSettingsCoordinator _mixSettings;
  final FxChainPersistence _fxPersistence;
  final SettingsRepository? _settings;
  final bool Function() _takeLocked;

  LooperMode? _persistedLooperMode;

  void _persistLooperMode(LooperMode mode) {
    if (mode == _persistedLooperMode) return;
    _persistedLooperMode = mode;
    unawaited(_settings?.saveLooperMode(mode.code));
  }

  static bool _neverLocked() => false;

  /// Coalesces the per-target chain-envelope writes that a knob drag would
  /// otherwise emit at pointer rate. Flushed in [close].
  final WriteDebouncer _fxPersist;
  late final StreamSubscription<LooperState> _subscription;
  late final StreamSubscription<({int mixGeneration, int sessionRevision})>
  _fxReplaySubscription;
  final Map<
    Object,
    ({int sessionRevision, Object token, Future<void> Function() save})
  >
  _pendingFxSaves = {};
  final Set<Object> _savingFxKeys = {};

  /// The inbound editor-sync poll cadence (D-SYNC: ≤10 Hz).
  static const Duration _editorPollInterval = Duration(milliseconds: 100);

  /// Per-open-editor sync poll timers, keyed by `(channel, lane, index)`. Each
  /// is started when an editor opens and cancelled on close / [close] so a
  /// closed editor never leaves a ticking timer (D-WIN/D-SYNC).
  final Map<(int, int, int), Timer> _lanePluginEditorTimers = {};

  /// Clears track [channel] and returns it to its default armed-to-play state:
  /// unmuted. A cleared track should be ready to sound again on the next
  /// record/play rather than staying silently muted (the engine also unmutes
  /// every lane on clear), and the unmute is persisted per lane so it survives
  /// a restart. Shared by every clear path (per-track and clear-all).
  void _clearAndArm(int channel) {
    if (!_repository.clear(channel: channel).isOk) return;
    _repository.setMute(muted: false, channel: channel);
    final lanes = channel >= 0 && channel < state.tracks.length
        ? state.tracks[channel].lanes.length
        : 1;
    for (var lane = 0; lane < (lanes < 1 ? 1 : lanes); lane++) {
      unawaited(_settings?.saveLaneMute(channel, lane, muted: false));
    }
  }

  bool _laneMuted(int channel, int lane) {
    if (channel < 0 || channel >= state.tracks.length) return false;
    final lanes = state.tracks[channel].lanes;
    return lane >= 0 && lane < lanes.length && lanes[lane].muted;
  }

  void _persistAfterFx(Object key, Future<void> Function() save) {
    if (_settings == null) return;
    final sessionRevision = _repository.sessionRevision;
    _pendingFxSaves[key] = (
      sessionRevision: sessionRevision,
      token: Object(),
      save: save,
    );
    if (_repository.fxRecipesSettled) {
      unawaited(_fxPersistence.trackSave(_savePendingFx(key, sessionRevision)));
    } else {
      unawaited(
        _fxPersistence.trackSave(_waitAndPersistFx(key, sessionRevision)),
      );
    }
  }

  Future<void> _savePendingFx(Object key, int sessionRevision) async {
    if (!_savingFxKeys.add(key)) return;
    Object? attemptedToken;
    try {
      while (true) {
        final pending = _pendingFxSaves[key];
        if (pending == null ||
            pending.sessionRevision != sessionRevision ||
            sessionRevision != _repository.sessionRevision ||
            isClosed ||
            !_repository.fxRecipesSettled) {
          return;
        }
        attemptedToken = pending.token;
        try {
          await pending.save();
        } on Object catch (error, stackTrace) {
          // Keep this target dirty for a later confirmed replay or edit.
          addError(error, stackTrace);
          return;
        }
        if (identical(_pendingFxSaves[key]?.token, pending.token)) {
          _pendingFxSaves.remove(key);
          return;
        }
      }
    } finally {
      _savingFxKeys.remove(key);
      final next = _pendingFxSaves[key];
      if (next != null &&
          !identical(next.token, attemptedToken) &&
          next.sessionRevision == _repository.sessionRevision &&
          !isClosed &&
          _repository.fxRecipesSettled) {
        unawaited(
          _fxPersistence.trackSave(_savePendingFx(key, next.sessionRevision)),
        );
      }
    }
  }

  void _onFxReplayConfirmed(
    ({int mixGeneration, int sessionRevision}) replay,
  ) {
    if (isClosed ||
        replay.mixGeneration != _repository.mixGeneration ||
        replay.sessionRevision != _repository.sessionRevision) {
      return;
    }
    for (final entry in _pendingFxSaves.entries.toList()) {
      if (entry.value.sessionRevision == replay.sessionRevision) {
        unawaited(
          _fxPersistence.trackSave(
            _savePendingFx(entry.key, replay.sessionRevision),
          ),
        );
      }
    }
  }

  void _persistRepositoryLaneChain(int channel, int lane) {
    _persistAfterFx(
      (#lane, channel, lane),
      () => _saveLaneChain(channel, lane),
    );
  }

  Future<void> _waitAndPersistFx(Object key, int sessionRevision) async {
    final result = await _repository.settleFxRecipes(
      waitForCallback: true,
      cancelled: () => isClosed,
    );
    if (!result.isOk || isClosed) return;
    await _savePendingFx(key, sessionRevision);
  }

  /// Pushes a freshly-computed lane chain to the engine and persists it. The
  /// single home for lane FX structural edits — every add/remove/retype/move
  /// handler routes here so the chain surgery lives in one place, never the UI.
  EngineResult _pushLaneEffects(
    int channel,
    int lane,
    List<TrackEffect> effects,
  ) {
    // A structural edit reseats every slot in the lane (the engine rebuilds
    // the chain), so any editor-sync poll keyed by a now-stale chain index must
    // be cancelled — otherwise a reorder would silently rebind a poll to a
    // different plugin and close the wrong window.
    final result = _repository.setLaneEffects(
      channel: channel,
      lane: lane,
      effects: effects,
    );
    if (!result.isOk) return result;
    _cancelLaneEditorTimers(channel, lane);
    // Persist the repository's chain, not the input: applying it enriches each
    // plugin entry with its resolved display name (so the name survives a
    // restart), which the pre-apply `effects` list does not yet carry.
    _persistRepositoryLaneChain(channel, lane);
    return result;
  }

  void _confirmFxReceipt(
    Completer<bool>? receipt,
    EngineResult admission, {
    bool Function()? cancelled,
  }) {
    if (receipt == null) return;
    if (!admission.isOk) {
      receipt.complete(false);
      return;
    }
    final generation = _repository.mixGeneration;
    final session = _repository.sessionRevision;
    unawaited(() async {
      try {
        final applied = await _repository.settleFxRecipes(
          waitForCallback: true,
          cancelled: () => isClosed || (cancelled?.call() ?? false),
        );
        receipt.complete(
          applied.isOk &&
              !isClosed &&
              !(cancelled?.call() ?? false) &&
              _repository.mixGeneration == generation &&
              _repository.sessionRevision == session,
        );
      } on Object catch (error, stackTrace) {
        addError(error, stackTrace);
        receipt.complete(false);
      }
    }());
  }

  /// Persists lane [lane] of [channel]'s current chain — the sink for the
  /// repository's [LooperRepository.onLaneChainChanged] notification (F3: the
  /// record-time snapshot copy). Reads the repository's enriched chain so a
  /// persisted plugin entry keeps its resolved name.
  void _persistLaneChain(int channel, int lane) {
    unawaited(_fxPersistence.trackSave(_saveLaneChain(channel, lane)));
  }

  Future<void> _saveLaneChain(int channel, int lane) =>
      _fxPersistence.trackSave(() async {
        final session = _repository.sessionRevision;
        await _fxPersistence.settlePending();
        if (session != _repository.sessionRevision) return;
        await _settings?.saveLaneEffects(
          channel,
          lane,
          encodeFxChain(
            _fxPersistence.project(
              FxAddress(stage: FxStage.loop, index: channel, lane: lane),
              decodeFxChain(_encodedLaneChain(channel, lane)),
            ),
          ),
        );
      }());

  /// Coalesced twin of [_persistLaneChain], for the paths a knob drag drives.
  /// Keyed per lane, so dragging one lane's knob never delays another's write.
  void _schedulePersistLaneChain(int channel, int lane) => _fxPersist.schedule(
    (#lane, channel, lane),
    () => _persistRepositoryLaneChain(channel, lane),
  );

  /// Encodes lane [lane] of [channel]'s chain as the persisted envelope
  /// string (R15): the entries, the chain-enabled flag, and the inheritance
  /// meta all ride the one `lane_effects` key — no per-flag keys.
  String _encodedLaneChain(int channel, int lane) => encodeFxChain(
    FxChainEnvelope(
      chainEnabled: _repository.laneChainEnabled(channel, lane),
      meta: FxChainMeta(
        inheritedFrom: _repository.laneChainInheritedFrom(channel, lane),
      ),
      entries: _repository.laneEffects(channel, lane),
    ),
  );

  /// One entry with its channel handling replaced, dispatched over the
  /// sealed hierarchy.
  static TrackEffect _withChannels(TrackEffect fx, FxChannels channels) =>
      switch (fx) {
        BuiltInEffect() => fx.copyWith(channels: channels),
        PluginEffect() => fx.copyWith(channels: channels),
      };

  /// The current chain at bus [address], read from the repository (the
  /// authority that every bus write lands in synchronously) rather than from
  /// the projected [LooperState].
  List<TrackEffect> _busChain(FxAddress address) =>
      address.stage == FxStage.output
      ? _repository.outputEffects(address.index)
      : _repository.trackEffects(address.index);

  /// Writes [next] to the bus chain at [address] and persists its envelope.
  EngineResult _pushBusChain(FxAddress address, List<TrackEffect> next) {
    final result = _writeBusChain(address, next);
    if (!result.isOk) return result;
    _persistAfterFx(
      (address.stage, address.index),
      () => _saveBusChain(address),
    );
    return result;
  }

  /// The engine half of [_pushBusChain], on its own — for the knob-drag path,
  /// which needs the write immediate and the persistence coalesced.
  EngineResult _writeBusChain(FxAddress address, List<TrackEffect> next) =>
      address.stage == FxStage.output
      ? _repository.setOutputEffects(bus: address.index, effects: next)
      : _repository.setTrackEffects(
          channel: address.index,
          effects: next,
        );

  /// Persists the bus chain envelope at [address] — used on its own by the
  /// granular param path, which writes through the repository rather than
  /// replacing the chain.
  Future<void> _saveBusChain(FxAddress address) =>
      address.stage == FxStage.output
      ? _saveOutputChain(address.index)
      : saveTrackFxChain(
          settings: _settings,
          looper: _repository,
          projection: _fxPersistence,
          channel: address.index,
        );

  /// Coalesced bus-chain persistence — the bus half of
  /// [_schedulePersistLaneChain], keyed by the address it persists.
  void _schedulePersistBusChain(FxAddress address) => _fxPersist.schedule(
    address,
    () => _persistAfterFx(
      (address.stage, address.index),
      () => _saveBusChain(address),
    ),
  );

  /// Persists track [channel]'s Track-stage chain envelope (the bus twin of
  /// [_encodedLaneChain]; bus chains carry no inheritance meta) — through the
  /// helper `ControlCubit`'s FX-mode stomps share, so the on-screen and pedal
  /// paths write the same envelope.
  void _persistTrackChain(int channel) => persistTrackFxChain(
    settings: _settings,
    looper: _repository,
    projection: _fxPersistence,
    channel: channel,
  );

  /// Writes a loaded session's Loop / Track / Master chains, every track's
  /// pan and the input setup back to the boot-restore keys — the settings
  /// half of [LooperRepository.applySession], which updates the engine and
  /// the re-apply caches but leaves persistence to its caller (see its doc,
  /// and `SessionPersistenceSyncListener` for the full argument).
  ///
  /// Reads the repository's chain enumerations — the same truth a session SAVE
  /// captures — and writes through the same helpers the edit paths use, so a
  /// written-back envelope is byte-identical to an edited one.
  ///
  /// Also re-persists the lane COUNT, which is not decoration: the boot
  /// restore walks lanes `0..lane_count`, so without it every chain written
  /// for a lane above the PRE-LOAD count is stored and never read back, and a
  /// multi-lane session still restores wrong.
  ///
  /// The mix (slice 3) is re-persisted together: every track's pan and lane
  /// level in one Mixer value, and the input setup WHOLE under the
  /// open device (an edit writes one input; a load replaces the setup, so
  /// a key the loaded session does not carry is cleared). With no device
  /// open there is nothing to key the setup to and it is left alone, like an
  /// edit.
  ///
  /// Sweeps the whole key space (every engine track × [kMaxLanes]) rather than
  /// just the applied keys. A key above the live lane count is unreachable
  /// today but not forever — growing the lane count later would read it — so
  /// bounding the sweep by the live count would let a dropped chain resurrect
  /// on the next boot after a lane is added. That correctness is worth the
  /// bounded burst of removals per load: a load is a deliberate, infrequent
  /// action that already clears every track and re-imports its stems.
  void _resyncSessionChains() {
    _pendingFxSaves.clear();
    final settings = _settings;
    if (settings == null) return;
    // A loaded session supersedes every edit in flight. Without this, a knob
    // let go of less than one debounce window before the load would land
    // AFTER the sweep below and resurrect a chain the sweep just cleared —
    // exactly the stale-key revival the sweep exists to prevent.
    _fxPersist.cancelAll();
    final lanes = _repository.allLaneChains();
    final tracks = _repository.allTrackChains();
    // The engine's track count, read fresh rather than from this bloc's
    // state (only as current as the last poll tick).
    final channels = _repository.state.tracks.length;
    for (var channel = 0; channel < channels; channel++) {
      for (var lane = 0; lane < kMaxLanes; lane++) {
        if (lanes.containsKey((channel, lane))) {
          _persistLaneChain(channel, lane);
        } else {
          unawaited(settings.clearLaneEffects(channel, lane));
        }
      }
      if (tracks.containsKey(channel)) {
        _persistTrackChain(channel);
      } else {
        unawaited(settings.clearTrackFxChain(channel));
      }
    }
    // Every destination, not just the ones the loaded session configured: a
    // destination the session does not name has no chain, and leaving its old
    // key would restore the previous session's output FX on the next boot —
    // the same stale-key class the lane and track sweeps above prevent.
    final outputs = _repository.allOutputChains();
    for (var bus = 0; bus < kMaxOutputBuses; bus++) {
      if (outputs.containsKey(bus)) {
        _persistOutputChain(bus);
      } else {
        unawaited(settings.clearOutputFxChain(bus));
      }
    }
    _persistAllTracksChain();
  }

  /// Persists output destination [bus]'s chain envelope.
  void _persistOutputChain(int bus) {
    unawaited(_fxPersistence.trackSave(_saveOutputChain(bus)));
  }

  Future<void> _saveOutputChain(int bus) async {
    final settings = _settings;
    if (settings == null) return;
    await saveFxOwner(
      settings: settings,
      looper: _repository,
      projection: _fxPersistence,
      address: FxAddress(stage: FxStage.output, index: bus),
    );
  }

  /// Persists the All tracks recorded-mix chain envelope.
  void _persistAllTracksChain() {
    unawaited(_fxPersistence.trackSave(_saveAllTracksChain()));
  }

  Future<void> _saveAllTracksChain() async {
    final settings = _settings;
    if (settings == null) return;
    await saveFxOwner(
      settings: settings,
      looper: _repository,
      projection: _fxPersistence,
      address: const FxAddress(stage: FxStage.allTracks),
    );
  }

  /// Cancels every editor-sync poll timer for lane [lane] of [channel].
  void _cancelLaneEditorTimers(int channel, int lane) {
    _lanePluginEditorTimers.removeWhere((key, timer) {
      if (key.$1 == channel && key.$2 == lane) {
        timer.cancel();
        return true;
      }
      return false;
    });
  }

  @override
  Future<void> close() {
    // Before anything is torn down: a drag that ended in the debounce window
    // and was followed by a shutdown must still reach the store.
    _fxPersist.flush();
    for (final timer in _lanePluginEditorTimers.values) {
      timer.cancel();
    }
    _lanePluginEditorTimers.clear();
    // The repository outlives the bloc; drop the chain-persist callback so a
    // later record doesn't call into a closed bloc.
    if (_repository.onLaneChainChanged == _persistRepositoryLaneChain) {
      _repository.onLaneChainChanged = null;
    }
    _pendingFxSaves.clear();
    unawaited(_subscription.cancel());
    unawaited(_fxReplaySubscription.cancel());
    return super.close();
  }
}

/// Restores the persisted looper mode (B5c) and dispatches it through
/// [bloc] — the boot-time counterpart of the "seeded settings cubit" `load()`
/// convention used elsewhere (`TempoCubit`/`TracksCubit`/etc, called via
/// `app.dart`'s `unawaited(cubit.load())` wiring), but as a top-level
/// function rather than a bloc method: `Bloc` instances are driven only
/// through events (bloc_lint's `avoid_public_bloc_methods`), so this reads
/// [settings] itself and dispatches [LooperModeChanged] rather than adding a
/// second, non-event entry point to [LooperBloc]. Reuses the same event a
/// user-driven mode change dispatches, so the boot restore also re-persists
/// the value it just read — harmless (writing back the same value is a
/// no-op on disk) and keeps this to one code path instead of two.
Future<void> restoreLooperMode(
  LooperBloc bloc,
  SettingsRepository settings,
) async {
  final mode = LooperMode.fromCode(await settings.loadLooperMode());
  bloc.add(LooperModeChanged(mode));
}
