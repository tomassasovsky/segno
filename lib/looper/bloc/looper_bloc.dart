import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/track_mute.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';
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
    required DecayControl decayControl,
    required OneShotControl oneShotControl,
    required RecordLengthControl recordLengthControl,
    required RecordTimingControl recordTimingControl,
    SettingsRepository? settings,
    Duration fxPersistDebounce = const Duration(milliseconds: 300),
    bool Function() takeLocked = _neverLocked,
  }) : _repository = repository,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _decayControl = decayControl,
       _oneShotControl = oneShotControl,
       _recordLengthControl = recordLengthControl,
       _recordTimingControl = recordTimingControl,
       _settings = settings,
       _takeLocked = takeLocked,
       _fxPersistDebounce = fxPersistDebounce,
       super(const LooperState()) {
    on<LooperStateUpdated>((event, emit) {
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
      (event, _) => _setMute(
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
      _setMute(
        muted: !_repository.laneMuted(event.channel, event.lane),
        channel: event.channel,
        lane: event.lane,
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
      _persistAfterFx(const FxAddress(stage: FxStage.allTracks));
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
      _persistAfterFx(FxAddress(stage: FxStage.track, index: event.channel));
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
      _persistAfterFx(FxAddress(stage: FxStage.output, index: event.bus));
    });
    on<LooperTrackEffectPlacementChanged>((event, _) {
      final result = _repository.setTrackEffectPlacement(
        channel: event.channel,
        slotId: event.slotId,
        placement: event.placement,
      );
      if (!result.isOk) return;
      _persistAfterFx(FxAddress(stage: FxStage.track, index: event.channel));
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
      _persistAfterFx(const FxAddress(stage: FxStage.allTracks));
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
      _persistAfterFx(const FxAddress(stage: FxStage.allTracks));
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
      _persistAfterFx(FxAddress(stage: FxStage.output, index: event.bus));
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
      _persistAfterFx(FxAddress(stage: FxStage.output, index: event.bus));
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
    on<LooperTrackRecordTimingChanged>((event, _) async {
      final write = _recordTimingControl.setTrackTiming(
        channel: event.channel,
        timing: event.timing,
      );
      _recordTimingWrites.add(write);
      try {
        await write;
      } finally {
        _recordTimingWrites.remove(write);
      }
    });
    on<LooperTrackOverdubDecayChanged>((event, _) async {
      final write = _decayControl.setTrackOverdubDecay(
        channel: event.channel,
        percent: event.percent,
      );
      _decayWrites.add(write);
      try {
        await write;
      } finally {
        _decayWrites.remove(write);
      }
    });
    on<LooperTrackLengthPresetChanged>((event, _) async {
      final write = _recordLengthControl.setTrackRecordLength(
        channel: event.channel,
        bars: event.bars,
      );
      _recordLengthWrites.add(write);
      try {
        await write;
      } finally {
        _recordLengthWrites.remove(write);
      }
    });
    on<LooperOneShotToggled>((event, _) async {
      final write = _oneShotControl.setTrackOneShot(
        channel: event.channel,
        oneShot: event.oneShot,
      );
      _oneShotWrites.add(write);
      try {
        await write;
      } finally {
        _oneShotWrites.remove(write);
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
    on<LooperModeChanged>((event, _) async {
      final write = _recordLengthControl.setLooperMode(event.mode);
      _recordLengthWrites.add(write);
      try {
        await write;
      } finally {
        _recordLengthWrites.remove(write);
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
    on<LooperPersistFlush>((event, _) async {
      try {
        await Future.wait(_decayWrites.toList());
        await Future.wait(_oneShotWrites.toList());
        await Future.wait(_recordLengthWrites.toList());
        await Future.wait(_recordTimingWrites.toList());
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
    // Persist repository-owned lane changes: inherited chains and accepted
    // mute resets on clear/new take/redo use the same lane save boundary.
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
  final DecayControl _decayControl;
  final OneShotControl _oneShotControl;
  final RecordLengthControl _recordLengthControl;
  final RecordTimingControl _recordTimingControl;
  final _recordTimingWrites = <Future<RecordTimingOutcome>>{};
  final _recordLengthWrites = <Future<RecordLengthOutcome>>{};
  final _oneShotWrites = <Future<OneShotOutcome>>{};
  final _decayWrites = <Future<DecayOutcome>>{};
  final SettingsRepository? _settings;
  final bool Function() _takeLocked;

  static bool _neverLocked() => false;

  final Duration _fxPersistDebounce;
  late final StreamSubscription<LooperState> _subscription;

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
    if (_fxPersistence.sessionTransitionActive) return;
    if (!_repository.clear(channel: channel).isOk) return;
    _setMute(muted: false, channel: channel);
  }

  EngineResult _setMute({
    required bool muted,
    required int channel,
    int? lane,
  }) => applyTrackMute(
    looper: _repository,
    settings: _settings,
    persistence: _fxPersistence,
    channel: channel,
    lane: lane,
    muted: muted,
    onError: (error, stack) {
      if (!isClosed) addError(error, stack);
    },
  );

  void _persistAfterFx(FxAddress address) {
    final settings = _settings;
    if (settings == null) return;
    unawaited(
      _fxPersistence.saveConfirmed(address, settings).catchError(
        (Object error, StackTrace stack) {
          if (!isClosed) addError(error, stack);
        },
      ),
    );
  }

  void _persistRepositoryLaneChain(int channel, int lane) => _persistAfterFx(
    FxAddress(stage: FxStage.loop, index: channel, lane: lane),
  );

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
  void _persistLaneChain(int channel, int lane) =>
      _persistRepositoryLaneChain(channel, lane);

  /// Coalesced twin of [_persistLaneChain], for the paths a knob drag drives.
  /// Keyed per lane, so dragging one lane's knob never delays another's write.
  void _schedulePersistLaneChain(int channel, int lane) =>
      _schedulePersistBusChain(
        FxAddress(stage: FxStage.loop, index: channel, lane: lane),
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
    _persistAfterFx(address);
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

  /// Coalesced bus-chain persistence — the bus half of
  /// [_schedulePersistLaneChain], keyed by the address it persists.
  void _schedulePersistBusChain(FxAddress address) {
    final settings = _settings;
    if (settings == null) return;
    _fxPersistence.scheduleSave(
      address,
      settings,
      debounce: _fxPersistDebounce,
    );
  }

  void _persistTrackChain(int channel) =>
      _persistAfterFx(FxAddress(stage: FxStage.track, index: channel));

  void _persistAllTracksChain() =>
      _persistAfterFx(const FxAddress(stage: FxStage.allTracks));

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
    _fxPersistence.flushScheduled();
    for (final timer in _lanePluginEditorTimers.values) {
      timer.cancel();
    }
    _lanePluginEditorTimers.clear();
    // The repository outlives the bloc; drop the chain-persist callback so a
    // later record doesn't call into a closed bloc.
    if (_repository.onLaneChainChanged == _persistRepositoryLaneChain) {
      _repository.onLaneChainChanged = null;
    }
    unawaited(_subscription.cancel());
    return super.close();
  }
}
