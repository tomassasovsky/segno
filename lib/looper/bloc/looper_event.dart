part of 'looper_bloc.dart';

/// Base type for [LooperBloc] events.
sealed class LooperEvent extends Equatable {
  const LooperEvent();

  @override
  List<Object?> get props => [];
}

/// Internal: a new [LooperState] arrived from the repository stream.
final class LooperStateUpdated extends LooperEvent {
  /// Creates a [LooperStateUpdated].
  const LooperStateUpdated(this.state);

  /// The latest projected looper state.
  final LooperState state;

  @override
  List<Object?> get props => [state];
}

/// Base for events targeting a single track [channel].
sealed class LooperChannelEvent extends LooperEvent {
  const LooperChannelEvent(this.channel);

  /// The target track channel.
  final int channel;

  @override
  List<Object?> get props => [channel];
}

/// The record/overdub control was pressed on [channel].
final class LooperRecordPressed extends LooperChannelEvent {
  /// Creates a [LooperRecordPressed].
  const LooperRecordPressed(super.channel);
}

/// The stop control was pressed on [channel].
final class LooperStopPressed extends LooperChannelEvent {
  /// Creates a [LooperStopPressed].
  const LooperStopPressed(super.channel);
}

/// The play control was pressed on [channel].
final class LooperPlayPressed extends LooperChannelEvent {
  /// Creates a [LooperPlayPressed].
  const LooperPlayPressed(super.channel);
}

/// The clear control was pressed on [channel].
final class LooperClearPressed extends LooperChannelEvent {
  /// Creates a [LooperClearPressed].
  const LooperClearPressed(super.channel);
}

/// The undo control was pressed on [channel].
final class LooperUndoPressed extends LooperChannelEvent {
  /// Creates a [LooperUndoPressed].
  const LooperUndoPressed(super.channel);
}

/// The redo control was pressed on [channel].
final class LooperRedoPressed extends LooperChannelEvent {
  /// Creates a [LooperRedoPressed].
  const LooperRedoPressed(super.channel);
}

/// The mute control was toggled on [channel].
final class LooperMuteToggled extends LooperChannelEvent {
  /// Creates a [LooperMuteToggled].
  const LooperMuteToggled(super.channel);
}

/// The track volume slider changed on [channel].
final class LooperVolumeChanged extends LooperChannelEvent {
  /// Creates a [LooperVolumeChanged].
  const LooperVolumeChanged(super.channel, this.volume);

  /// New gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  @override
  List<Object?> get props => [channel, volume];
}

/// Track [channel]'s record timing override changed (accepted design, Length
/// & quantize): `null` follows the default, else the timing this track's own
/// record and overdub requests wait for.
final class LooperTrackRecordTimingChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackRecordTimingChanged].
  const LooperTrackRecordTimingChanged(super.channel, {required this.timing});

  /// The override (`null` => follow the default).
  final RecordTiming? timing;

  @override
  List<Object?> get props => [channel, timing];
}

/// Track [channel]'s overdub decay override changed (accepted design,
/// Playback & overdub): `null` follows the default, else a percent in
/// `0..100`.
final class LooperTrackOverdubDecayChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackOverdubDecayChanged].
  const LooperTrackOverdubDecayChanged(super.channel, {required this.percent});

  /// The override (`null` => follow the default).
  final int? percent;

  @override
  List<Object?> get props => [channel, percent];
}

/// Track [channel]'s forced loop multiple changed (`0` = auto-round-up).
final class LooperTrackMultipleChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackMultipleChanged].
  const LooperTrackMultipleChanged(super.channel, this.multiple);

  /// The forced loop length in whole base loops, or `0` for auto.
  final int multiple;

  @override
  List<Object?> get props => [channel, multiple];
}

/// Track [channel]'s length preset override changed (A6, D17): `null`
/// follows the default, `0` is an explicit Auto, else a fixed bar count.
///
/// Governs the DEFINING (first/master) recording only — orthogonal to
/// [LooperTrackMultipleChanged], which governs a non-defining track once a
/// master already exists.
final class LooperTrackLengthPresetChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackLengthPresetChanged].
  const LooperTrackLengthPresetChanged(super.channel, this.bars);

  /// The fixed bar count, `0` for an explicit Auto, or `null` to follow the
  /// default.
  final int? bars;

  @override
  List<Object?> get props => [channel, bars];
}

/// Track [channel]'s Loop/Once override changed (accepted design, Playback
/// & overdub): `null` follows the default, `true` plays once then stops,
/// `false` loops.
final class LooperTrackOnceChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackOnceChanged].
  const LooperTrackOnceChanged(super.channel, {required this.once});

  /// The override (`null` => follow the default).
  final bool? once;

  @override
  List<Object?> get props => [channel, once];
}

/// Track [channel]'s Mixer pan changed (accepted design, Mixer): `-1` is
/// hard left, `1` hard right. Every lane's recorded image moves by it.
final class LooperTrackPanChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackPanChanged].
  const LooperTrackPanChanged(super.channel, {required this.pan});

  /// The pan, `-1..1`.
  final double pan;

  @override
  List<Object?> get props => [channel, pan];
}

/// Track [channel] was soloed or un-soloed (accepted design, Mixer): while
/// any track is soloed, only soloed tracks route. Not persisted: Solo is a
/// performance state the engine drops on restart.
final class LooperTrackSoloToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackSoloToggled].
  const LooperTrackSoloToggled(super.channel, {required this.solo});

  /// Whether the track is soloed.
  final bool solo;

  @override
  List<Object?> get props => [channel, solo];
}

/// The Mixer's clear Solo: every track is un-soloed.
final class LooperSoloCleared extends LooperEvent {
  /// Creates a [LooperSoloCleared].
  const LooperSoloCleared();
}

/// The Mixer's Reset mixer: every track's level back to unity and pan to
/// centre; mute, Solo, effects and audio stay as they are.
final class LooperMixerReset extends LooperEvent {
  /// Creates a [LooperMixerReset].
  const LooperMixerReset();
}

/// Base for events targeting a single hardware [input]'s capture setup
/// (accepted design, Audio routing). The setup is keyed by the open device
/// in settings, like the input names.
sealed class LooperInputEvent extends LooperEvent {
  const LooperInputEvent(this.input);

  /// The hardware input channel, `0`-based.
  final int input;

  @override
  List<Object?> get props => [input];
}

/// Hardware [input]'s capture trim changed, in dB.
final class LooperInputTrimChanged extends LooperInputEvent {
  /// Creates a [LooperInputTrimChanged].
  const LooperInputTrimChanged(super.input, {required this.db});

  /// The trim in dB (`kMinInputTrimDb..kMaxInputTrimDb`; `0` = unity).
  final double db;

  @override
  List<Object?> get props => [input, db];
}

/// Mono hardware [input]'s pan changed.
final class LooperInputPanChanged extends LooperInputEvent {
  /// Creates a [LooperInputPanChanged].
  const LooperInputPanChanged(super.input, {required this.pan});

  /// The pan, `-1..1`.
  final double pan;

  @override
  List<Object?> get props => [input, pan];
}

/// The stereo pair whose lower (even) member is [input] was linked or
/// unlinked.
final class LooperInputPairChanged extends LooperInputEvent {
  /// Creates a [LooperInputPairChanged].
  const LooperInputPairChanged(super.input, {required this.paired});

  /// Whether [input] and the odd input above it form a stereo pair.
  final bool paired;

  @override
  List<Object?> get props => [input, paired];
}

/// The balance of the pair whose lower member is [input] changed.
final class LooperInputBalanceChanged extends LooperInputEvent {
  /// Creates a [LooperInputBalanceChanged].
  const LooperInputBalanceChanged(super.input, {required this.balance});

  /// The balance, `-1` (Left only) .. `1` (Right only).
  final double balance;

  @override
  List<Object?> get props => [input, balance];
}

/// An edit to one output destination (accepted design, Output setup).
sealed class LooperOutputEvent extends LooperEvent {
  /// Creates a [LooperOutputEvent].
  const LooperOutputEvent(this.bus);

  /// The destination: one per stereo pair of hardware outputs, `0`-based.
  final int bus;

  @override
  List<Object?> get props => [bus];
}

/// Output destination [bus]'s level changed.
final class LooperOutputLevelChanged extends LooperOutputEvent {
  /// Creates a [LooperOutputLevelChanged].
  const LooperOutputLevelChanged(super.bus, {required this.level});

  /// The level, `0..1`.
  final double level;

  @override
  List<Object?> get props => [bus, level];
}

/// Output destination [bus] was muted or unmuted.
final class LooperOutputMuteChanged extends LooperOutputEvent {
  /// Creates a [LooperOutputMuteChanged].
  const LooperOutputMuteChanged(super.bus, {required this.muted});

  /// Whether the destination is muted.
  final bool muted;

  @override
  List<Object?> get props => [bus, muted];
}

/// Output destination [bus] switched between Stereo and Mono.
final class LooperOutputMonoChanged extends LooperOutputEvent {
  /// Creates a [LooperOutputMonoChanged].
  const LooperOutputMonoChanged(super.bus, {required this.mono});

  /// Whether the destination is in Mono.
  final bool mono;

  @override
  List<Object?> get props => [bus, mono];
}

/// Output destination [bus]'s balance changed.
final class LooperOutputBalanceChanged extends LooperOutputEvent {
  /// Creates a [LooperOutputBalanceChanged].
  const LooperOutputBalanceChanged(super.bus, {required this.balance});

  /// The balance, `-1` (left only) .. `1` (right only).
  final double balance;

  @override
  List<Object?> get props => [bus, balance];
}

/// Cut all sound (accepted design): every audible track stops and every
/// effect tail is cleared; the rig's settings stay.
final class LooperCutSoundPressed extends LooperEvent {
  /// Creates a [LooperCutSoundPressed].
  const LooperCutSoundPressed();
}

/// [channel] was crowned the primary track (Sync/Band, D18;
/// `crownPrimary` — D20). No "un-crown" event exists — the only way to move
/// the crown is to crown a different channel.
final class LooperCrownPrimaryPressed extends LooperChannelEvent {
  /// Creates a [LooperCrownPrimaryPressed].
  const LooperCrownPrimaryPressed(super.channel);
}

/// The five-mode axis (Multi/Sync/Song/Band/Free) changed (D4). The UI is
/// responsible for the D4 clear-all confirmation BEFORE dispatching this —
/// the engine silently ignores the change while any track has content (see
/// `LooperModeControl.setLooperMode`'s doc), so this event assumes the
/// caller has already confirmed/cleared.
final class LooperModeChanged extends LooperEvent {
  /// Creates a [LooperModeChanged].
  const LooperModeChanged(this.mode);

  /// The new looper mode.
  final LooperMode mode;

  @override
  List<Object?> get props => [mode];
}

/// Base for events targeting one [lane] of a track [channel].
sealed class LooperLaneEvent extends LooperChannelEvent {
  const LooperLaneEvent(super.channel, this.lane);

  /// The target lane index within the track.
  final int lane;

  @override
  List<Object?> get props => [channel, lane];
}

/// Track [channel]'s active lane count changed (add/remove a lane). Lanes are a
/// stack: growing appends an empty lane, shrinking drops the last one.
final class LooperLaneCountChanged extends LooperChannelEvent {
  /// Creates a [LooperLaneCountChanged].
  const LooperLaneCountChanged(super.channel, this.count);

  /// The new active lane count (`>= 1`).
  final int count;

  @override
  List<Object?> get props => [channel, count];
}

/// Lane [lane] of track [channel] now records hardware input [inputChannel]
/// (`-1` records nothing). A lane captures a single clean input.
final class LooperLaneInputChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneInputChanged].
  const LooperLaneInputChanged(super.channel, super.lane, this.inputChannel);

  /// The hardware input channel this lane records (`-1` = none).
  final int inputChannel;

  @override
  List<Object?> get props => [channel, lane, inputChannel];
}

/// Lane [lane] of track [channel]'s output-routing bitmask changed.
final class LooperLaneOutputChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneOutputChanged].
  const LooperLaneOutputChanged(super.channel, super.lane, this.mask);

  /// Bitmask of hardware output channels to play to (bit c => out c).
  final int mask;

  @override
  List<Object?> get props => [channel, lane, mask];
}

/// Lane [lane] of track [channel]'s playback volume changed.
final class LooperLaneVolumeChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneVolumeChanged].
  const LooperLaneVolumeChanged(super.channel, super.lane, this.volume);

  /// New gain in `0..LE_MAX_GAIN` (2.0, +6.02 dB headroom above unity).
  final double volume;

  @override
  List<Object?> get props => [channel, lane, volume];
}

/// Lane [lane] of track [channel]'s mute was toggled.
final class LooperLaneMuteToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneMuteToggled].
  const LooperLaneMuteToggled(super.channel, super.lane);
}

/// A default effect (drive) was appended to lane [lane] of track [channel]'s
/// chain. A structural edit — the bloc reads the current chain and pushes the
/// grown one, so the view never computes the new list itself.
final class LooperLaneEffectAdded extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectAdded]; [type] defaults to drive.
  const LooperLaneEffectAdded(super.channel, super.lane, {this.type});

  /// The device type to add, carried so add-of-type is ONE intent — the UI
  /// never has to name the new entry's index, which it could only read from a
  /// projection that lags this write.
  final TrackEffectType? type;

  @override
  List<Object?> get props => [channel, lane, type];
}

/// Lane [lane] of track [channel]'s chain was replaced with [effects] — the
/// lane twin of [LooperTrackEffectsChanged].
///
/// The structural write: rename, reorder and removal all rewrite the chain
/// rather than edit one slot, because a rack is several entries and every one
/// of them moves together.
final class LooperLaneEffectsChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectsChanged].
  const LooperLaneEffectsChanged(super.channel, super.lane, this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [channel, lane, effects];
}

/// Appends [entries] to lane [lane] of track [channel]'s chain in one write
/// — the lane twin of [LooperBusEffectsAppended], for the same reason.
final class LooperLaneEffectsAppended extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectsAppended].
  const LooperLaneEffectsAppended(super.channel, super.lane, this.entries);

  /// The entries to append, in order.
  final List<TrackEffect> entries;

  @override
  List<Object?> get props => [channel, lane, entries];
}

/// Chain entry [index] was removed from lane [lane] of track [channel].
final class LooperLaneEffectRemoved extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectRemoved].
  const LooperLaneEffectRemoved(super.channel, super.lane, this.index);

  /// The chain entry index to drop (`0..length-1`).
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
}

/// Chain entry [index] on lane [lane] of track [channel] became [type] (resets
/// that entry's DSP and seeds its default params).
final class LooperLaneEffectTypeChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectTypeChanged].
  const LooperLaneEffectTypeChanged(
    super.channel,
    super.lane,
    this.index,
    this.type,
  );

  /// The chain entry index to retype (`0..length-1`).
  final int index;

  /// The new effect type.
  final TrackEffectType type;

  @override
  List<Object?> get props => [channel, lane, index, type];
}

/// Chain entry [from] on lane [lane] of track [channel] was reordered to slot
/// [to].
final class LooperLaneEffectMoved extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectMoved].
  const LooperLaneEffectMoved(super.channel, super.lane, this.from, this.to);

  /// The entry's current index.
  final int from;

  /// The entry's target index.
  final int to;

  @override
  List<Object?> get props => [channel, lane, from, to];
}

/// Sets chain entry [index] on lane [lane] of track [channel] to [channels] —
/// its input handling, its output handling, its placement between the sides
/// and its own level.
///
/// One event for all four, because they are one control: the accepted design
/// applies the input choice before the effects, the output choice and its
/// placement after them, and the level last, and a half-applied change is
/// audible.
final class LooperLaneEffectChannelsChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectChannelsChanged].
  const LooperLaneEffectChannelsChanged(
    super.channel,
    super.lane,
    this.index,
    this.channels,
  );

  /// The entry's current index in the chain.
  final int index;

  /// Its channel handling and level.
  final FxChannels channels;

  @override
  List<Object?> get props => [channel, lane, index, channels];
}

/// Sets entry [index] of the bus chain at [address] to [channels] — the bus
/// twin of the lane event above.
final class LooperBusEffectChannelsChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectChannelsChanged].
  const LooperBusEffectChannelsChanged(
    super.address,
    this.index,
    this.channels,
  );

  /// The entry's current index in the chain.
  final int index;

  /// Its channel handling and level.
  final FxChannels channels;

  @override
  List<Object?> get props => [address, index, channels];
}

/// Sets entry [index] of the All tracks chain to [channels].
final class LooperAllTracksEffectChannelsChanged extends LooperEvent {
  /// Creates a [LooperAllTracksEffectChannelsChanged].
  const LooperAllTracksEffectChannelsChanged(this.index, this.channels);

  /// The entry's current index in the chain.
  final int index;

  /// Its channel handling and level.
  final FxChannels channels;

  @override
  List<Object?> get props => [index, channels];
}

/// Moves entry [index] of lane [lane] of track [channel]'s chain to
/// [placement].
///
/// The entry keeps its identity, parameters and enable state and lands at the
/// end of the destination stage's run.
final class LooperLaneEffectPlacementChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectPlacementChanged].
  const LooperLaneEffectPlacementChanged(
    super.channel,
    super.lane,
    this.index,
    this.placement,
  );

  /// The entry's current index in the chain.
  final int index;

  /// Where the entry should sit relative to the loop player.
  final FxPlacement placement;

  @override
  List<Object?> get props => [channel, lane, index, placement];
}

/// Parameter [param] of chain entry [index] on lane [lane] of track [channel]
/// changed to [value] (`0..1`). A live tweak — does not reset DSP state.
final class LooperLaneEffectParamChanged extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectParamChanged].
  const LooperLaneEffectParamChanged(
    super.channel,
    super.lane,
    this.index,
    this.param,
    this.value,
  );

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The parameter index (`0..kTrackEffectParams-1`).
  final int param;

  /// The normalized parameter value (`0..1`).
  final double value;

  @override
  List<Object?> get props => [channel, lane, index, param, value];
}

/// Sets a hosted-plugin parameter on lane [lane]'s chain entry [index]. Unlike
/// [LooperLaneEffectParamChanged] (built-in, normalized + positional), this
/// addresses a parameter by its stable plugin [paramId] and carries a plain
/// (already-scaled) [value], routed to the plugin through the RT param queue.
final class LooperLanePluginParamChanged extends LooperLaneEvent {
  /// Creates a [LooperLanePluginParamChanged].
  const LooperLanePluginParamChanged(
    super.channel,
    super.lane,
    this.index,
    this.paramId,
    this.value,
  );

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The stable plugin parameter id (VST3 ParamID / CLAP clap_id).
  final int paramId;

  /// The plain (already-scaled) parameter value.
  final double value;

  @override
  List<Object?> get props => [channel, lane, index, paramId, value];
}

/// Appends a hosted plugin (identified by [ref]) to lane [lane]'s FX chain.
/// The repository loads it through the slot ABI on the next chain apply.
final class LooperLanePluginInserted extends LooperLaneEvent {
  /// Creates a [LooperLanePluginInserted].
  const LooperLanePluginInserted(super.channel, super.lane, this.ref);

  /// The identity of the plugin to insert (format + stable id + version).
  final PluginRef ref;

  @override
  List<Object?> get props => [channel, lane, ref];
}

/// Relinks lane [lane]'s plugin chain entry [index] to [ref] (umbrella D-MISS):
/// resolves an unavailable placeholder (or accepts a version change), keeping
/// the captured state + tweaks.
final class LooperLanePluginRelinked extends LooperLaneEvent {
  /// Creates a [LooperLanePluginRelinked].
  const LooperLanePluginRelinked(
    super.channel,
    super.lane,
    this.index,
    this.ref,
  );

  /// The chain entry index.
  final int index;

  /// The replacement plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [channel, lane, index, ref];
}

/// Opens the native editor window for lane [lane]'s plugin chain entry [index]
/// (umbrella D-WIN). While open, the bloc polls the plugin (≤10 Hz) to mirror
/// editor-driven param moves onto the in-app knobs (D-SYNC).
final class LooperLanePluginEditorOpened extends LooperLaneEvent {
  /// Creates a [LooperLanePluginEditorOpened].
  const LooperLanePluginEditorOpened(super.channel, super.lane, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
}

/// Closes lane [lane]'s plugin chain entry [index] editor window and stops the
/// sync poll, with a final read-back of the plugin's params (D-SYNC).
final class LooperLanePluginEditorClosed extends LooperLaneEvent {
  /// Creates a [LooperLanePluginEditorClosed].
  const LooperLanePluginEditorClosed(super.channel, super.lane, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [channel, lane, index];
}

/// Entry [index] of lane [lane] of track [channel]'s chain was toggled to
/// [enabled] — the loop-stage twin of [LooperTrackEffectEnabledToggled]
/// (per-slot flag; click-free ramp engine-side).
final class LooperLaneEffectEnabledToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneEffectEnabledToggled].
  const LooperLaneEffectEnabledToggled(
    super.channel,
    super.lane,
    this.index, {
    required this.enabled,
  });

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, lane, index, enabled];
}

/// Lane [lane] of track [channel]'s WHOLE chain was toggled to [enabled] in
/// one atomic flip (per-entry flags untouched).
final class LooperLaneChainEnabledToggled extends LooperLaneEvent {
  /// Creates a [LooperLaneChainEnabledToggled].
  const LooperLaneChainEnabledToggled(
    super.channel,
    super.lane, {
    required this.enabled,
  });

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, lane, enabled];
}

/// Re-copies lane [lane] of track [channel]'s routed input chain onto the lane
/// by value, with a fresh provenance stamp (A6/R13). Explicit and user
/// initiated — inheritance is never automatic, and an overdub never
/// re-inherits (A7).
final class LooperLaneChainResyncedFromInput extends LooperLaneEvent {
  /// Creates a [LooperLaneChainResyncedFromInput].
  const LooperLaneChainResyncedFromInput(super.channel, super.lane);
}

/// Base for the **bus-stage** chain edits — the Track stereo bus and the
/// output chains — addressed by [FxAddress] rather than by a stage-specific
/// event pair, since the stage is data (A9/R19) and the two differ only in
/// which chain the handler reads and writes.
///
/// Every one of these carries an *intent*, never a computed chain: the bloc
/// composes the next list from the repository's current chain while it handles
/// the event. Composing in the UI instead would read `LooperState`, which lags
/// each write by the bloc's async hop, so two edits dispatched in one frame
/// (the rack's add-then-retype) would collapse into one.
sealed class LooperBusChainEvent extends LooperEvent {
  /// Creates a [LooperBusChainEvent] for the chain at [address].
  const LooperBusChainEvent(this.address);

  /// The bus chain being edited ([FxStage.track] or [FxStage.output]).
  final FxAddress address;

  @override
  List<Object?> get props => [address];
}

/// Appends a built-in effect to the bus chain at [address]. [type] carries the
/// device browser's pick, so add-of-type is ONE intent rather than an append
/// followed by a retype of an index the UI had to guess.
final class LooperBusEffectAdded extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectAdded]; [type] defaults to drive.
  const LooperBusEffectAdded(super.address, {this.type});

  /// The device type to add, or null for the default (drive).
  final TrackEffectType? type;

  @override
  List<Object?> get props => [address, type];
}

/// The bus chain at [address] was replaced with [effects] — the addressed
/// twin of [LooperTrackEffectsChanged] / [LooperOutputEffectsChanged], so one
/// structural edit reaches either bus stage without the caller switching.
final class LooperBusEffectsChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectsChanged].
  const LooperBusEffectsChanged(super.address, this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [address, effects];
}

/// Appends [entries] to the bus chain at [address] in one write.
///
/// One event rather than a run of [LooperBusEffectAdded], because a rack is
/// one thing the player chose: adding its pedals one at a time would push the
/// chain to the engine once per pedal and let a half-built rack be heard on
/// the way.
final class LooperBusEffectsAppended extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectsAppended].
  const LooperBusEffectsAppended(super.address, this.entries);

  /// The entries to append, in order.
  final List<TrackEffect> entries;

  @override
  List<Object?> get props => [address, entries];
}

/// Removes entry [index] from the bus chain at [address].
final class LooperBusEffectRemoved extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectRemoved].
  const LooperBusEffectRemoved(super.address, this.index);

  /// The chain entry index.
  final int index;

  @override
  List<Object?> get props => [address, index];
}

/// Moves entry [from] to [to] in the bus chain at [address] (the processing
/// order is the signal order, so a move re-sequences the FX).
final class LooperBusEffectMoved extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectMoved].
  const LooperBusEffectMoved(super.address, this.from, this.to);

  /// The entry's current index.
  final int from;

  /// The post-removal target index.
  final int to;

  @override
  List<Object?> get props => [address, from, to];
}

/// Retypes built-in entry [index] of the bus chain at [address] to [type]
/// (resets its DSP state and seeds default params).
final class LooperBusEffectTypeChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectTypeChanged].
  const LooperBusEffectTypeChanged(super.address, this.index, this.type);

  /// The chain entry index.
  final int index;

  /// The new device type.
  final TrackEffectType type;

  @override
  List<Object?> get props => [address, index, type];
}

/// Sets built-in parameter [param] of entry [index] of the bus chain at
/// [address] to the normalized [value], without a structural reset.
final class LooperBusEffectParamChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusEffectParamChanged].
  const LooperBusEffectParamChanged(
    super.address,
    this.index,
    this.param,
    this.value,
  );

  /// The chain entry index.
  final int index;

  /// The positional built-in parameter index.
  final int param;

  /// The new normalized (`0..1`) value.
  final double value;

  @override
  List<Object?> get props => [address, index, param, value];
}

/// Appends the hosted plugin [ref] to the bus chain at [address]. The domain
/// preserves the entry but marks it unsupported until a bus-stage slot ABI
/// lands, so it renders as a placeholder rather than as controls.
final class LooperBusPluginInserted extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginInserted].
  const LooperBusPluginInserted(super.address, this.ref);

  /// The plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [address, ref];
}

/// Sets hosted-plugin parameter [paramId] of entry [index] of the bus chain at
/// [address] to the plain [value].
final class LooperBusPluginParamChanged extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginParamChanged].
  const LooperBusPluginParamChanged(
    super.address,
    this.index,
    this.paramId,
    this.value,
  );

  /// The chain entry index.
  final int index;

  /// The stable plugin parameter id.
  final int paramId;

  /// The plain (already-scaled) parameter value.
  final double value;

  @override
  List<Object?> get props => [address, index, paramId, value];
}

/// Relinks plugin entry [index] of the bus chain at [address] to [ref].
final class LooperBusPluginRelinked extends LooperBusChainEvent {
  /// Creates a [LooperBusPluginRelinked].
  const LooperBusPluginRelinked(super.address, this.index, this.ref);

  /// The chain entry index.
  final int index;

  /// The replacement plugin's identity.
  final PluginRef ref;

  @override
  List<Object?> get props => [address, index, ref];
}

/// Track [channel]'s Track-stage (stereo bus) chain was replaced with
/// [effects] — the bus twin of the lane chain-set path (FX v3 part 3a). The
/// bloc owns Track/output chain state: it pushes through the repository and
/// persists the encoded envelope.
final class LooperTrackEffectsChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackEffectsChanged].
  const LooperTrackEffectsChanged(super.channel, this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [channel, effects];
}

/// Entry [index] of track [channel]'s Track-stage chain was toggled to
/// [enabled] (per-slot flag; click-free ramp engine-side).
final class LooperTrackEffectEnabledToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackEffectEnabledToggled].
  const LooperTrackEffectEnabledToggled(
    super.channel,
    this.index, {
    required this.enabled,
  });

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, index, enabled];
}

/// Track [channel]'s WHOLE Track-stage chain was toggled to [enabled] in one
/// atomic flip (per-entry flags untouched).
final class LooperTrackChainEnabledToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackChainEnabledToggled].
  const LooperTrackChainEnabledToggled(super.channel, {required this.enabled});

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [channel, enabled];
}

/// Track [channel]'s Track-stage chain was FLIPPED — the relative twin of
/// [LooperTrackChainEnabledToggled], mirroring [LooperMuteToggled].
///
/// The surfaces that toggle rather than set (the tracks tiles, the number
/// keys) must not compute the new value themselves: their only reading of the
/// flag is the ~16 ms-polled `LooperState`, which is missing entirely before
/// the engine publishes tracks and stale for a poll after any other surface
/// flips the same chain. The handler resolves it against the repository's
/// remembered intent instead, so every surface agrees on what "the other way"
/// means.
final class LooperTrackChainToggled extends LooperChannelEvent {
  /// Creates a [LooperTrackChainToggled].
  const LooperTrackChainToggled(super.channel);
}

/// Output destination [bus]'s post-sum chain was replaced with [effects].
final class LooperOutputEffectsChanged extends LooperEvent {
  /// Creates a [LooperOutputEffectsChanged].
  const LooperOutputEffectsChanged(this.bus, this.effects);

  /// The output destination.
  final int bus;

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [bus, effects];
}

/// Entry [index] of output destination [bus]'s chain was toggled to
/// [enabled].
final class LooperOutputEffectEnabledToggled extends LooperEvent {
  /// Creates a [LooperOutputEffectEnabledToggled].
  const LooperOutputEffectEnabledToggled(
    this.bus,
    this.index, {
    required this.enabled,
  });

  /// The output destination.
  final int bus;

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [bus, index, enabled];
}

/// The WHOLE chain on output destination [bus] was toggled to [enabled] in
/// one atomic flip.
final class LooperOutputChainEnabledToggled extends LooperEvent {
  /// Creates a [LooperOutputChainEnabledToggled].
  const LooperOutputChainEnabledToggled(this.bus, {required this.enabled});

  /// The output destination.
  final int bus;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [bus, enabled];
}

/// Entry [index] of track [channel]'s Track-stage chain moved to [placement]
/// — Pre (recorded into the loop) or Post (can ring after Stop).
///
/// A whole track's Pre run processes the combination of its parts as one
/// signal, which is why it is not the same as putting the effect on each
/// part.
final class LooperTrackEffectPlacementChanged extends LooperChannelEvent {
  /// Creates a [LooperTrackEffectPlacementChanged].
  const LooperTrackEffectPlacementChanged(
    super.channel,
    this.index,
    this.placement,
  );

  /// The entry's current index in the chain.
  final int index;

  /// Where the entry should sit relative to the loop player.
  final FxPlacement placement;

  @override
  List<Object?> get props => [channel, index, placement];
}

/// The All tracks recorded-mix chain was replaced with [effects] (slice 3e).
///
/// The chain applied after the loop tracks are combined, and only them: live
/// monitoring, the click and the output chains all join after it.
final class LooperAllTracksEffectsChanged extends LooperEvent {
  /// Creates a [LooperAllTracksEffectsChanged].
  const LooperAllTracksEffectsChanged(this.effects);

  /// The new chain, in processing order.
  final List<TrackEffect> effects;

  @override
  List<Object?> get props => [effects];
}

/// Appends [entries] to the All tracks chain in one write — see
/// [LooperBusEffectsAppended].
final class LooperAllTracksEffectsAppended extends LooperEvent {
  /// Creates a [LooperAllTracksEffectsAppended].
  const LooperAllTracksEffectsAppended(this.entries);

  /// The entries to append, in order.
  final List<TrackEffect> entries;

  @override
  List<Object?> get props => [entries];
}

/// Entry [index] of the All tracks chain was toggled to [enabled].
final class LooperAllTracksEffectEnabledToggled extends LooperEvent {
  /// Creates a [LooperAllTracksEffectEnabledToggled].
  const LooperAllTracksEffectEnabledToggled(
    this.index, {
    required this.enabled,
  });

  /// The chain entry index (`0..kTrackEffectMax-1`).
  final int index;

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [index, enabled];
}

/// The WHOLE All tracks chain was toggled to [enabled] in one atomic flip.
final class LooperAllTracksChainEnabledToggled extends LooperEvent {
  /// Creates a [LooperAllTracksChainEnabledToggled].
  const LooperAllTracksChainEnabledToggled({required this.enabled});

  /// The new flag value.
  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// Parameter [param] of All tracks chain entry [index] changed to [value]
/// (`0..1`). A live tweak — does not reset DSP state.
final class LooperAllTracksEffectParamChanged extends LooperEvent {
  /// Creates a [LooperAllTracksEffectParamChanged].
  const LooperAllTracksEffectParamChanged(this.index, this.param, this.value);

  /// The chain entry index.
  final int index;

  /// The parameter index (`0..kTrackEffectParams-1`).
  final int param;

  /// The new normalized value.
  final double value;

  @override
  List<Object?> get props => [index, param, value];
}

/// Play every track that has content.
final class LooperPlayAllPressed extends LooperEvent {
  /// Creates a [LooperPlayAllPressed].
  const LooperPlayAllPressed();
}

/// Stop every track.
final class LooperStopAllPressed extends LooperEvent {
  /// Creates a [LooperStopAllPressed].
  const LooperStopAllPressed();
}

/// Toggles the structural output gate for hardware [output] to [enabled]: a
/// disabled output is removed as a routing target (its lane/monitor masks are
/// preserved) and re-enabling restores them.
final class LooperOutputEnabledToggled extends LooperEvent {
  /// Creates a [LooperOutputEnabledToggled].
  const LooperOutputEnabledToggled(this.output, {required this.enabled});

  /// The hardware output channel index.
  final int output;

  /// Whether the output is a routing target.
  final bool enabled;

  @override
  List<Object?> get props => [output, enabled];
}

/// A session load landed, so the bloc must write its chains, its track pans
/// and its input setup back to the boot-restore keys — see
/// `_resyncSessionChains`.
///
/// Named for the trigger rather than the work, like every other event here: a
/// load is what HAPPENED; re-persisting is this bloc's response to it.
final class LooperSessionLoaded extends LooperEvent {
  /// Creates a [LooperSessionLoaded].
  const LooperSessionLoaded();
}

/// Flushes coalesced FX persistence now — a clean halt must not wait for
/// cubit teardown.
final class LooperPersistFlush extends LooperEvent {
  /// Creates a [LooperPersistFlush].
  const LooperPersistFlush();
}
