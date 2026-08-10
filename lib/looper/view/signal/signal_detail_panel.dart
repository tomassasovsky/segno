import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/signal_add_effect.dart';
import 'package:segno/looper/view/signal/signal_cards.dart';
import 'package:segno/looper/view/signal/signal_fx_editor.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// The open card's panel: what the chain is, and the two or three questions
/// about hearing it that its stage can actually answer.
///
/// **Below the whole run, not beside the card.** The cards wrap, so a panel
/// anchored to one of them would sit at a different place on every rig; under
/// the run it is always in the same place and always the full width, which is
/// what lets it hold rows rather than a column of stubs.
///
/// **Its rows are per stage, because its carriers are.** Every stage has a
/// chain. Level and `in the mix` need a volume and a mute, which a lane, a
/// track and an input monitor each have and the master sum does not — the
/// master's audibility is the output gates, and those are already on its tab.
/// `hear while playing` needs a [MonitorMode], which only a hardware input
/// has: it is the one thing here that can be *armed*, and `auto` means nothing
/// for anything that cannot be. The mockup drew that row on a loop card; the
/// rig has no such gate to draw, so the drawing is corrected rather than
/// implemented (see `c/signal-detail`).
///
/// Racks are #535, so the panel carries no rack chooser yet. A chain chip
/// opens that entry in the editor, which takes the place of `level` and
/// `in the mix` while it is open.
class SignalDetailPanel extends StatelessWidget {
  /// Creates a [SignalDetailPanel] for the chain at [address].
  const SignalDetailPanel({required this.address, super.key});

  /// Which chain's panel this is.
  final FxAddress address;

  /// Inside padding, as the mockups draw it.
  static const double padding = 18;

  /// Gap between two rows.
  static const double rowGap = 14;

  @override
  Widget build(BuildContext context) => switch (address.stage) {
    FxStage.input => _InputPanel(input: address.index),
    // A loop address with no lane names no chain — `FxAddress.fromJson` can
    // mint one from a corrupt persisted string. Defaulting it to lane A would
    // drive a take nobody selected, and no card would match to close it.
    FxStage.loop =>
      address.lane == null
          ? const SizedBox.shrink()
          : _LoopPanel(track: address.index, lane: address.lane!),
    FxStage.track => _TrackPanel(track: address.index),
    FxStage.master => const _MasterPanel(),
  };
}

/// The lane at [lane] on [track], or null when it is gone.
Lane? _laneOf(LooperState state, int track, int lane) {
  for (final t in state.tracks) {
    if (t.channel != track) continue;
    return lane >= 0 && lane < t.lanes.length ? t.lanes[lane] : null;
  }
  return null;
}

/// The bus at [track], or null when it is gone.
Track? _trackOf(LooperState state, int track) {
  for (final t in state.tracks) {
    if (t.channel == track) return t;
  }
  return null;
}

/// Whether the facts a panel draws about a lane are unchanged.
///
/// Deliberately NOT `a == b`: a [Lane] carries live meters, so value equality
/// on the whole object is false on every audio frame and the panel would
/// redraw at the meter rate. It draws a chain, a volume, a mute and the
/// chain's own power; only those decide. Same argument as `sameChainShape`
/// makes for the card runs.
bool sameLaneFacts(Lane? a, Lane? b) => a == null || b == null
    ? identical(a, b)
    : a.volume == b.volume &&
          a.muted == b.muted &&
          // The chain's own power is drawn too, by the editor's notice that
          // says why un-bypassing an entry changed nothing audible. Left out
          // of this list, that notice could never appear: nothing else in the
          // panel subscribes to the flag.
          a.chainEnabled == b.chainEnabled &&
          // And whether the take has drifted from its input, which the
          // overdub notice and the re-inherit action both read. It changes
          // when an input's chain is edited, not when the lane is — so a
          // panel watching only the lane's own numbers would never redraw for
          // it, and the A7 warning would appear only if the player happened
          // to touch this lane's fader while the overdub ran.
          a.inputChainDiverges == b.inputChainDiverges &&
          listEquals(a.effects, b.effects);

/// Whether the facts a panel draws about a track bus are unchanged.
/// See [sameLaneFacts] — a [Track] carries live meters for the same reason.
bool sameTrackFacts(Track? a, Track? b) => a == null || b == null
    ? identical(a, b)
    : a.volume == b.volume &&
          a.muted == b.muted &&
          a.chainEnabled == b.chainEnabled &&
          listEquals(a.effects, b.effects);

/// An input's panel: its monitor chain, and the three facts about hearing it.
class _InputPanel extends StatelessWidget {
  const _InputPanel({required this.input});

  final int input;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<InputsCubit>().state.names;
    final cubit = context.read<MonitorCubit>();
    // The socket has to still BE there. `MonitorState.forInput` synthesizes a
    // default rather than reporting absence, so without this the panel would
    // draw invented facts for a jack the rig no longer has — and writing to it
    // would persist a monitor against a socket that is gone. Checked against
    // the ENGINE's roster, not `MonitorCubit.hasInput`: the question is
    // whether the rig still has the jack, not whether anyone has configured
    // it.
    final (count, excluded) = context.select<LooperBloc, (int, int)>(
      (b) => (b.state.status.inputChannels, b.state.status.excludedInputMask),
    );
    // `input < 0` first: `1 << -1` throws, and the lane helper next door
    // already shrinks on a negative rather than crashing.
    if (input < 0 || input >= count || excluded & (1 << input) != 0) {
      return const SizedBox.shrink();
    }
    final monitor = context.watch<MonitorCubit>().state.forInput(input);

    return _PanelBody(
      address: FxAddress(stage: FxStage.input, index: input),
      scope: InputFxScope(
        monitor: cubit,
        looper: context.read<LooperBloc>(),
        repository: context.read<LooperRepository>(),
        input: input,
      ),
      title: l10n.inputName(names, input),
      subtitle: l10n.signalPanelSubtitle(
        l10n.signalCoordInput(input + 1),
        l10n.signalStageInput,
      ),
      chain: monitor.effects,
      level: monitor.volume,
      onLevel: (value) => cubit.setVolume(input, value),
      heard: !monitor.muted,
      onHeard: (heard) => cubit.setMute(input, muted: !heard),
      // The one stage with a monitor gate: an input is the only thing here
      // that can be armed, which is what `auto` resolves against.
      monitorMode: monitor.mode,
      onMonitorMode: (mode) => cubit.setMode(input, mode),
    );
  }
}

/// A lane's panel: the take's playback chain, its level and its mute.
class _LoopPanel extends StatelessWidget {
  const _LoopPanel({required this.track, required this.lane});

  final int track;
  final int lane;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    // Watched, not read: whether this take can be re-inherited is a fact
    // about the INPUT's chain, not the lane's — a pedal switching that chain
    // on is what makes the action appear, and nothing about the lane moves
    // when it does. `MonitorState` carries no meters, so this is a handful of
    // rebuilds a session, not a rebuild a frame.
    context.watch<MonitorCubit>();
    final bloc = context.read<LooperBloc>();
    // NOT `context.select` on the lane itself: a [Lane] carries live meters,
    // so selecting it would rebuild this panel at the meter rate. Only the
    // three facts the panel draws decide whether it needs redrawing — the
    // same argument `sameChainShape` makes for the card runs.
    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) =>
          !sameLaneFacts(
            _laneOf(previous, track, lane),
            _laneOf(current, track, lane),
          ) ||
          // The overdub notice is about the TRACK's state, which no lane
          // fact carries: an overdub starting or ending changes nothing on
          // the lane itself.
          _trackOf(previous, track)?.state != _trackOf(current, track)?.state,
      builder: (context, state) {
        final take = _laneOf(state, track, lane);
        // The lane can go while its panel is open — a track's lane count is a
        // live setting. Nothing beats a panel of stale numbers.
        if (take == null) return const SizedBox.shrink();
        return _PanelBody(
          address: FxAddress(stage: FxStage.loop, index: track, lane: lane),
          scope: LaneFxScope(
            looper: bloc,
            repository: context.read<LooperRepository>(),
            track: track,
            lane: lane,
          ),
          title: l10n.trackName(names, track),
          subtitle: l10n.signalPanelSubtitle(
            l10n.signalCoordTrackLane(track + 1, laneLetter(lane)),
            l10n.signalStageLoop,
          ),
          chain: take.effects,
          level: take.volume,
          onLevel: (value) =>
              bloc.add(LooperLaneVolumeChanged(track, lane, value)),
          heard: !take.muted,
          // The lane's event is a TOGGLE and this control is a pick-one, so
          // it only fires when the pick actually differs from the rig.
          onHeard: (heard) {
            if (heard == !take.muted) return;
            bloc.add(LooperLaneMuteToggled(track, lane));
          },
        );
      },
    );
  }
}

/// A track bus's panel: the bus chain, its level and its mute.
class _TrackPanel extends StatelessWidget {
  const _TrackPanel({required this.track});

  final int track;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final bloc = context.read<LooperBloc>();
    // Same reason as the loop panel: a [Track] carries live meters.
    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) =>
          !sameTrackFacts(_trackOf(previous, track), _trackOf(current, track)),
      builder: (context, state) {
        final bus = _trackOf(state, track);
        if (bus == null) return const SizedBox.shrink();
        return _PanelBody(
          address: FxAddress(stage: FxStage.track, index: track),
          scope: StageFxScope(
            looper: bloc,
            address: FxAddress(stage: FxStage.track, index: track),
            trackNames: names,
          ),
          title: l10n.trackName(names, track),
          subtitle: l10n.signalPanelSubtitle(
            l10n.signalCoordTrack(track + 1),
            l10n.signalStageTrack,
          ),
          chain: bus.effects,
          level: bus.volume,
          onLevel: (value) => bloc.add(LooperVolumeChanged(track, value)),
          heard: !bus.muted,
          onHeard: (heard) {
            if (heard == !bus.muted) return;
            bloc.add(LooperMuteToggled(track));
          },
        );
      },
    );
  }
}

/// The Master insert's panel: the chain, and nothing else.
///
/// No level and no `in the mix`: the master sum has neither a volume nor a
/// mute in the rig, and the question its tab actually answers — where does
/// this go — is the `OUTPUTS` group already sitting under the card.
class _MasterPanel extends StatelessWidget {
  const _MasterPanel();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A list compares by identity, so `context.select` on `masterEffects`
    // would redraw whenever the projection rebuilt the list — every meter
    // tick. Compared by VALUE here, the same way the other two panels do it;
    // a hash would be a collision-shaped subscription.
    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) =>
          !listEquals(previous.masterEffects, current.masterEffects) ||
          previous.masterChainEnabled != current.masterChainEnabled,
      builder: (context, state) => _PanelBody(
        address: const FxAddress(stage: FxStage.master),
        scope: StageFxScope(
          looper: context.read<LooperBloc>(),
          address: const FxAddress(stage: FxStage.master),
          trackNames: const [],
        ),
        title: l10n.signalMasterCardName,
        subtitle: l10n.signalPanelSubtitle(
          l10n.signalCoordMain,
          l10n.signalStageMaster,
        ),
        chain: state.masterEffects,
      ),
    );
  }
}

/// The panel's shape: a captioned stack of rows, in signal order — what is on
/// the chain, then how loud it is, then whether it is heard at all.
class _PanelBody extends StatefulWidget {
  const _PanelBody({
    required this.address,
    required this.scope,
    required this.title,
    required this.subtitle,
    required this.chain,
    this.level,
    this.onLevel,
    this.heard,
    this.onHeard,
    this.monitorMode,
    this.onMonitorMode,
  });

  /// Which chain this panel is for — the fader keys off it, so a drag on one
  /// card cannot leave its value showing on the next.
  final FxAddress address;

  /// The chain's own edit surface, for the editor the chips open.
  final FxScope scope;

  final String title;
  final String subtitle;
  final List<TrackEffect> chain;
  final double? level;
  final ValueChanged<double>? onLevel;
  final bool? heard;
  final ValueChanged<bool>? onHeard;
  final MonitorMode? monitorMode;
  final ValueChanged<MonitorMode>? onMonitorMode;

  @override
  State<_PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends State<_PanelBody> {
  /// Whether an entry is being dragged along the chain right now.
  ///
  /// While one is, the panel is the chain and nothing else. Dragging is its
  /// own mode: the rows below would jump as the panel changed height under a
  /// held finger, and an editor open on the entry being carried would be
  /// describing a thing in motion.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final chain = widget.chain;
    final address = widget.address;
    final scope = widget.scope;
    final title = widget.title;
    final gain = widget.level;
    final onLevel = widget.onLevel;
    final inMix = widget.heard;
    final onHeard = widget.onHeard;
    final mode = widget.monitorMode;
    final onMonitorMode = widget.onMonitorMode;

    final selected = context.select<SettingsTrayCubit, String?>(
      (c) => c.state.signalEffectSlot,
    );
    final tray = context.read<SettingsTrayCubit>();
    // Identity resolved to a position at DRAW time, so a reorder moves the
    // editor with its entry and needs no follow-up write. An entry can also
    // go while its editor is open — removed from another surface, or the
    // whole chain rewritten by a record-time snapshot copy — and then it
    // resolves to nothing. The editor is DROPPED rather than rendered empty:
    // leaving the selection set would suppress `level` and `in the mix` too,
    // and with no chip left to tap there would be nothing able to clear it.
    final at = selected == null
        ? -1
        : chain.indexWhere((effect) => effect.slotId == selected);
    final editing = at >= 0 ? at : null;
    if (selected != null && editing == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // `context.mounted` guards the element; the cubit needs its own check,
        // since emitting on a closed one throws — reachable in tests whose
        // tearDown closes the cubit before the frame settles.
        if (context.mounted && !tray.isClosed) tray.clearSignalEffect();
      });
    }
    // The fader, which is the one thing under the chain that HOLDS anything:
    // the value a finger set, kept until the rig answers. It is guarded
    // rather than torn down for exactly that reason — see [_LevelRow.live]
    // and the keyed subtree below.
    final level = <Widget>[
      if (editing == null && gain != null && onLevel != null) ...[
        _Caption(l10n.signalPanelLevel),
        _LevelRow(
          key: ValueKey(address),
          value: gain,
          live: !_dragging,
          onChanged: onLevel,
        ),
      ],
    ];

    // The rest, in signal order. Every one of these is stateless, so it can
    // be thrown away and rebuilt for nothing.
    final tail = <Widget>[
      if (editing != null)
        SignalFxEditor(
          scope: scope,
          index: editing,
          onClose: tray.clearSignalEffect,
        )
      else ...[
        if (inMix != null && onHeard != null) ...[
          _Caption(l10n.signalPanelInMix),
          ConsoleSegmented<bool>(
            key: const Key('signal_panel_in_mix'),
            stretch: true,
            selected: inMix,
            onChanged: onHeard,
            segments: [
              ConsoleSegment(value: false, label: l10n.signalMixMuted),
              ConsoleSegment(value: true, label: l10n.signalMixHeard),
            ],
          ),
        ],
      ],
      if (mode != null && onMonitorMode != null) ...[
        _Caption(l10n.signalPanelHearWhilePlaying),
        ConsoleSegmented<MonitorMode>(
          key: const Key('signal_panel_monitor'),
          stretch: true,
          selected: mode,
          onChanged: onMonitorMode,
          segments: [
            ConsoleSegment(
              value: MonitorMode.off,
              label: l10n.signalMonitorSegOff,
            ),
            ConsoleSegment(
              value: MonitorMode.auto,
              label: l10n.signalMonitorSegAuto,
            ),
            ConsoleSegment(
              value: MonitorMode.on,
              label: l10n.signalMonitorSegOn,
            ),
          ],
        ),
      ],
    ];

    return Container(
      key: const Key('signal_detail_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(SignalDetailPanel.padding - 1),
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(12),
        // The same accent the open card wears, so the two read as one object.
        border: Border.all(color: surface.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: SignalDetailPanel.rowGap,
        children: [
          _Header(title: title, subtitle: widget.subtitle),
          // A7: an overdub never re-inherits, so a chain that has drifted
          // from its input since the take is worth saying while it counts.
          if (scope.overdubMismatch)
            _Notice(
              key: const Key('signal_panel_overdub_mismatch'),
              message: l10n.fxOverdubMismatchHint,
            ),
          _ChainCaption(scope: scope),
          _ChainStrip(
            chain: chain,
            // The slot only when it still resolves — an id naming nothing
            // would mark no chip and the panel is already dropping it.
            editing: editing == null ? null : selected,
            onSelect: tray.selectSignalEffect,
            onReorder: scope.moveEffect,
            onDragging: (dragging) => setState(() => _dragging = dragging),
            onAdd: scope.canAddEffect
                ? () => unawaited(
                    showSignalAddEffect(
                      context,
                      scope: scope,
                      chainName: title,
                    ),
                  )
                : null,
          ),
          // Everything below the chain is hidden while an entry is being
          // carried, and its ROOM IS KEPT. Actually removing it shortens the
          // panel, and the panel is the last thing in a scroll view: on a
          // 1024x600 console, scrolled far enough down to be touching the
          // chain at all, the clamp then drags the whole strip up to 180px
          // out from under the finger the instant the press lands, and a
          // release where the chip was picked up hits a track card instead.
          //
          // The editor takes the place of `level` and `in the mix`: you are
          // looking at ONE effect now, and how loud the whole chain is is a
          // question about the chain. The monitor segment stays — what you
          // hear is still true while you change what it sounds like.
          if (level.isNotEmpty || tail.isNotEmpty)
            Visibility(
              key: const Key('signal_panel_tail'),
              visible: !_dragging,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: SignalDetailPanel.rowGap,
                children: [
                  ...level,
                  // Keyed on the mode, so engaging the fold rebuilds this part
                  // from scratch and every recogniser under it is disposed.
                  // `Visibility` only stops NEW hit tests: a finger already on
                  // the remove button, the mute segment or a parameter bar
                  // would otherwise complete its gesture on a control no
                  // longer on screen — deleting an effect, mid-drag, with
                  // nothing said. The fader is outside this because it is the
                  // one control that would LOSE something: its held value,
                  // which the rig may not have answered on yet.
                  if (tail.isNotEmpty)
                    KeyedSubtree(
                      key: ValueKey(_dragging),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        spacing: SignalDetailPanel.rowGap,
                        children: tail,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The panel's title and the coordinate under it.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      // 9, not an eyeballed 5: title 23x1.17 + subtitle 14x1.21 + this gap is
      // what makes the header the 53 the mockups measure.
      spacing: kConsoleLabelGap,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: surface.textPrimary,
            fontSize: 23,
            height: 1.17,
            leadingDistribution: TextLeadingDistribution.even,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: surface.textMuted,
            fontSize: 14,
            height: 1.21,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ],
    );
  }
}

/// The `chain` caption, and the two things that act on the chain as a whole.
///
/// The power switch used to live in the dock's header, and the dock is gone.
/// Without it a chain switched off from anywhere else — a pedal binding, a
/// restored session — could be SEEN to be off (the editor says so) and never
/// turned back on. It sits on the caption because it belongs to the whole
/// run, not to any one entry: an entry's own power is the editor's bypass.
class _ChainCaption extends StatelessWidget {
  const _ChainCaption({required this.scope});

  final FxScope scope;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final on = scope.chainEnabled;
    return Row(
      children: [
        _Caption(l10n.signalPanelChain),
        // What the switch COSTS while it is off, in the warning pair — the
        // same sentence the dock put beside it.
        if (!on) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              scope.chainDisabledConsequence(l10n),
              key: const Key('signal_panel_chain_off_consequence'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.warning,
                fontSize: 14,
                height: 1.21,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ],
        const Spacer(),
        // A6: an explicit, user-initiated re-inherit, offered only while the
        // routed input actually has an audible chain to copy.
        if (scope.canResyncFromInput) ...[
          _ChainAction(
            actionKey: const Key('signal_panel_resync'),
            label: l10n.fxResyncFromInput,
            onTap: scope.resyncFromInput,
          ),
          const SizedBox(width: 10),
        ],
        // A chain whose target is gone has nothing to switch: writing through
        // a vanished input would mint a phantom monitor and persist a key
        // that comes back on the next boot.
        if (scope.isPresent)
          _ChainAction(
            actionKey: const Key('signal_panel_chain_power'),
            label: on ? l10n.signalChainOn : l10n.signalChainOff,
            semanticLabel: on ? l10n.a11yFxChainOn : l10n.a11yFxChainOff,
            active: on,
            onTap: () => scope.setChainEnabled(enabled: !on),
          ),
      ],
    );
  }
}

/// A small pill acting on the whole chain — power, or re-sync.
class _ChainAction extends StatelessWidget {
  const _ChainAction({
    required this.actionKey,
    required this.label,
    required this.onTap,
    this.semanticLabel,
    this.active = false,
  });

  final Key actionKey;
  final String label;
  final String? semanticLabel;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: active,
      label: semanticLabel ?? label,
      child: InkWell(
        key: actionKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(119),
        child: ExcludeSemantics(
          child: Container(
            height: 33,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: active ? surface.accentSurface : null,
              borderRadius: BorderRadius.circular(119),
              border: Border.all(
                color: active ? surface.accent : surface.line,
              ),
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  color: active ? surface.accent : surface.textSecondary,
                  fontSize: 14,
                  height: 1.21,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A line the panel says out loud, in the warning pair.
class _Notice extends StatelessWidget {
  const _Notice({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: TextStyle(
      color: context.surface.warning,
      fontSize: 14,
      height: 1.21,
      leadingDistribution: TextLeadingDistribution.even,
    ),
  );
}

/// An inline caption over the row it names. Sentence case, as the mockups set
/// them — these read as questions about the chain, not as group headings.
class _Caption extends StatelessWidget {
  const _Caption(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      color: context.surface.textSecondary,
      fontSize: 14,
      height: 1.21,
      leadingDistribution: TextLeadingDistribution.even,
    ),
  );
}

/// The chain as a strip of chips, in processing order.
///
/// A chip opens its entry in the editor below, and the open one takes the
/// accent pair. The last chip is `+ effect`, which is where the effect it
/// adds will land — the end of the chain.
/// A chip as a drop target: its two halves are the insertion points on either
/// side of it.
///
/// NOT a gap widget between the chips. A gap wide enough for a finger has to
/// come from somewhere, and taking it from the run relaid the whole strip out
/// the instant a press matured — chips sliding sideways, rows appearing and
/// disappearing, the panel changing height under the hand that was holding
/// it. Half a chip is both a bigger target than any gap could be and free:
/// the strip is laid out exactly the same whether a drag is up or not.
///
/// Two targets, one per half, rather than one target that works out which
/// half the pointer is on. Hit testing already answers that question exactly,
/// for the right pointer, with no bookkeeping: nothing hands a drop target
/// the pointer id that belongs to the drag, and a strip that tried to track
/// that itself had to guess which finger was carrying — a guess any second
/// touch during the half-second press could steal.
class _DropHalves extends StatelessWidget {
  const _DropHalves({
    required this.index,
    required this.carrying,
    required this.positionOf,
    required this.onDrop,
    required this.child,
  });

  /// This chip's position in the chain as drawn.
  final int index;

  /// The slot id of the entry the strip considers to be in flight.
  ///
  /// A drop from anything else is refused. The chips are disarmed on the
  /// rebuild that follows a drag starting, but two long presses maturing in
  /// the SAME frame both go live, and placing both is corruption: each drop
  /// is expressed against the chain as drawn, and the second lands on a chain
  /// the first has already rewritten — moving an entry that finger never
  /// touched.
  final String? carrying;

  /// Where the entry with this slot id sits in the chain right now, or -1 if
  /// it is gone.
  ///
  /// Resolved on every accept rather than carried in the payload: Flutter
  /// snapshots a [Draggable]'s data when the drag starts and never revisits
  /// it, so an index put in there goes stale the moment anything else edits
  /// the chain — and the drop then moves whichever entry has since slid into
  /// that position.
  final int Function(String slotId) positionOf;

  final void Function(int from, int insertAt) onDrop;

  final Widget child;

  /// One half of the chip, and the insertion point it stands for.
  Widget _side(BuildContext context, {required bool leading}) {
    final surface = context.surface;
    final insertAt = leading ? index : index + 1;
    return Expanded(
      child: DragTarget<String>(
        // The two sides flanking the dragged entry name the place it already
        // occupies. Refusing them here is what keeps the strip from marking a
        // landing place for a move that would do nothing — and an entry that
        // has left the chain mid-drag has no place at all.
        onWillAcceptWithDetails: (d) {
          if (d.data != carrying) return false;
          final from = positionOf(d.data);
          return from >= 0 && from != insertAt && from + 1 != insertAt;
        },
        onAcceptWithDetails: (d) => onDrop(positionOf(d.data), insertAt),
        builder: (context, candidate, rejected) => Align(
          alignment: leading
              ? AlignmentDirectional.centerStart
              : AlignmentDirectional.centerEnd,
          child: candidate.isEmpty
              ? const SizedBox.expand()
              : Container(
                  key: Key('signal_panel_mark_$insertAt'),
                  width: 4,
                  decoration: BoxDecoration(
                    color: surface.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      // Over the chip, so marking a landing place moves nothing. A drop
      // target hit-tests translucently, so the chip underneath still takes
      // the tap that opens its entry in the editor.
      Positioned.fill(
        child: Row(
          children: [
            _side(context, leading: true),
            _side(context, leading: false),
          ],
        ),
      ),
    ],
  );
}

/// The chip under the pointer during a drag.
///
/// Its own widget rather than [_ChainStripState._chip]: the feedback layer is
/// outside the strip's build, so it cannot read anything that would make it
/// look selected or ghosted, and it draws a fill even when the entry it came
/// from has none — otherwise the thing being carried is invisible over the
/// panel.
class _LiftedChip extends StatelessWidget {
  const _LiftedChip({required this.surface, required this.label, super.key});

  final SurfaceTheme surface;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 17),
    decoration: BoxDecoration(
      color: surface.accentSurface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: surface.accent),
    ),
    // Centred the same way the chips in the run are — this is the copy that
    // flies, and a label that sits differently here jumps on the lift.
    child: Center(
      widthFactor: 1,
      child: Text(
        label,
        style: TextStyle(
          color: surface.accent,
          fontSize: 16,
          height: 1.13,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    ),
  );
}

class _ChainStrip extends StatefulWidget {
  const _ChainStrip({
    required this.chain,
    required this.editing,
    required this.onSelect,
    required this.onAdd,
    required this.onReorder,
    required this.onDragging,
  });

  final List<TrackEffect> chain;

  /// Which entry is open in the editor, by slot id, or null when none is.
  final String? editing;

  /// Opens (or, on the open chip, closes) an entry's editor, by identity.
  final ValueChanged<String> onSelect;

  /// Opens the add dialog, or null when the chain is at its cap.
  ///
  /// The add affordance is the LAST CHIP, not a button beside the strip: it
  /// sits where the effect it makes will, which is the end of the chain.
  final VoidCallback? onAdd;

  /// Moves the entry at `from` to `to`, both post-normalisation indices.
  final void Function(int from, int to) onReorder;

  /// Reports whether a drag is in progress, so the panel can fold to the
  /// chain alone while one is.
  final ValueChanged<bool> onDragging;

  @override
  State<_ChainStrip> createState() => _ChainStripState();
}

class _ChainStripState extends State<_ChainStrip> {
  /// Between two chips, and between the last one and `+ effect`.
  ///
  /// The pen draws the run at 10: `Drive` ends at 74 and `Tremolo` starts at
  /// 84, the same on `SIGNAL / signal-detail` and `SIGNAL / fx-edit`. It was
  /// built at 5, which reads as a tighter strip than the design.
  static const double chipGap = 10;

  /// Every entry currently in the air, by slot id.
  ///
  /// Normally one. The chips are disarmed on the rebuild that follows a drag
  /// starting, but two long presses maturing in the SAME frame both go live —
  /// the gate cannot take effect between them. This set is what the panel's
  /// mode follows, so that whichever of the two is released first, the strip
  /// stays folded while a finger is still holding something.
  final Set<String> _airborne = {};

  /// The one entry that may actually be PLACED, or null.
  ///
  /// The first to start, and it is never handed on. Two entries in flight
  /// cannot both be placed: a drop is expressed against the chain as it is
  /// drawn, the rewrite only lands on the bloc round-trip, and so the second
  /// of a pair is computed in coordinates the first has already invalidated —
  /// moving an entry that finger never touched. There is nothing here that
  /// could speculatively apply the first move to make the second's
  /// coordinates true, so the second one springs back.
  String? _carrying;

  /// Where [slotId] sits in the chain right now, or -1 if it is gone.
  int _positionOf(String slotId) =>
      widget.chain.indexWhere((effect) => effect.slotId == slotId);

  /// A drop onto the gap [insertAt] — an index in the CURRENT list.
  ///
  /// The normalisation is ported from `signal_fx_rack.dart` rather than
  /// re-derived: a gap PAST the entry's own position has to come down by one,
  /// because the entry is removed before it is re-inserted, and every gap
  /// after it has already shifted by the time the insert happens. Off by one
  /// here and an entry dragged rightwards always lands one place short.
  ///
  /// The rack also guarded the two insertion points flanking the entry here;
  /// that guard is [_DropHalves]', which is where it can also decline to mark
  /// a landing place for a move that would do nothing.
  void _reorderTo(int from, int insertAt) {
    if (from < 0) return;
    widget.onReorder(from, insertAt > from ? insertAt - 1 : insertAt);
  }

  /// Records that [slotId] is now in flight, or no longer is.
  ///
  /// Both ends are reported by `onDragCompleted` / `onDraggableCanceled`
  /// rather than by `onDragEnd`, because Flutter gates `onDragEnd` on the
  /// draggable still being MOUNTED. The chips are keyed by slot id, so a
  /// chain that gets re-identified mid-drag — starting a recording inherits
  /// the monitor chain onto the lane with fresh ids — tears the held chip
  /// down, and `onDragEnd` is then silently skipped. The strip was left in
  /// drag mode with no way back out but closing the card.
  void _setDragging(String slotId, {required bool dragging}) {
    if (!mounted) return;
    setState(() {
      if (dragging) {
        _airborne.add(slotId);
        // Never handed on: promoting the survivor of a same-frame pair would
        // make its already-stale coordinates placeable.
        _carrying ??= slotId;
      } else {
        _airborne.remove(slotId);
        if (_carrying == slotId) _carrying = null;
      }
    });
    widget.onDragging(_airborne.isNotEmpty);
  }

  /// One entry of the run: the chip, what it accepts, and what carries it.
  Widget _entry(
    BuildContext context,
    int index,
    TrackEffect effect,
    String? carrying,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final onSelect = widget.onSelect;
    final editing = widget.editing;
    return Semantics(
      // Keyed, and keyed by IDENTITY: the gaps appear between the
      // chips when a drag starts, so every chip changes slot in the
      // run at that moment. Unkeyed, Flutter matches children by
      // position and the chip being dragged is torn down and rebuilt
      // mid-drag — its `onDragEnd` then never fires, and the strip
      // stays stuck in drag mode with no way out.
      key: ValueKey('slot-${effect.slotId ?? index}'),
      button: true,
      selected: effect.slotId != null && effect.slotId == editing,
      label: fxBlockName(l10n, effect),
      // An entry with no slot id has not crossed a repository write
      // yet, so nothing can name it — neither a selection nor a
      // drag payload. That is momentary, and the chip is simply
      // inert until it has one.
      child: _DropHalves(
        index: index,
        carrying: carrying,
        positionOf: _positionOf,
        onDrop: _reorderTo,
        child: LongPressDraggable<String>(
          data: effect.slotId ?? '',
          // One entry travels at a time, and one pointer carries it.
          // A second finger on a second chip would place its entry
          // against a chain the first drop has already rewritten; a
          // second finger on the SAME chip would register the same
          // slot id twice, and the first release would take the gaps
          // out from under the other one.
          maxSimultaneousDrags:
              effect.slotId == null ||
                  (_airborne.isNotEmpty && !_airborne.contains(effect.slotId))
              ? 0
              : 1,
          // The panel is a touch surface on a floor console: a plain
          // drag would steal every tap-to-open on the way past.
          // The press is what says "I mean to move this one".
          onDragStarted: () => _setDragging(effect.slotId!, dragging: true),
          // Not `onDragEnd` — see [_setDragging]. Between them these
          // two cover both endings, and neither is gated on the chip
          // still being mounted.
          onDragCompleted: () => _setDragging(effect.slotId!, dragging: false),
          onDraggableCanceled: (_, _) =>
              _setDragging(effect.slotId!, dragging: false),
          feedback: Material(
            color: Colors.transparent,
            // 74x38 lifts to 75x40 — the one scale the mockups draw.
            child: Transform.translate(
              offset: const Offset(-2, -5),
              child: Transform.scale(
                scale: 1.0135,
                child: _LiftedChip(
                  key: const Key('signal_panel_lift'),
                  surface: surface,
                  label: fxBlockName(l10n, effect),
                ),
              ),
            ),
          ),
          childWhenDragging: ExcludeSemantics(
            child: KeyedSubtree(
              key: Key('signal_panel_ghost_$index'),
              child: _chip(context, index, effect, ghosted: true),
            ),
          ),
          child: InkWell(
            key: Key('signal_panel_chip_$index'),
            onTap: effect.slotId == null
                ? null
                : () => onSelect(effect.slotId!),
            borderRadius: BorderRadius.circular(8),
            // Only the DRAWING is excluded. Wrapping the InkWell too
            // silences its tap action, and the chip then announces as
            // a button a screen reader cannot activate — the editor
            // becomes unreachable from assistive tech entirely.
            child: ExcludeSemantics(child: _chip(context, index, effect)),
          ),
        ),
      ),
    );
  }

  /// One chain chip, as it sits in the run.
  ///
  /// [ghosted] draws the entry a drag has picked up: it stays in the run so
  /// the other chips keep their places, and only fades — removing it would
  /// reflow the whole strip under the pointer at the moment the drag starts,
  /// which reads as the chip jumping away from the finger holding it.
  Widget _chip(
    BuildContext context,
    int index,
    TrackEffect effect, {
    bool ghosted = false,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final selected = effect.slotId != null && effect.slotId == widget.editing;
    return Opacity(
      opacity: ghosted ? 0.3 : 1,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 17),
        decoration: BoxDecoration(
          // Unselected carries no fill at all, as the mockups draw it; the
          // open one takes the accent pair.
          color: selected ? surface.accentSurface : null,
          borderRadius: BorderRadius.circular(8),
        ),
        // `Center` with a width factor, not the Container's `alignment`: an
        // alignment makes a Container expand to its constraints, which inside
        // a Wrap gives every chip the whole panel's width. Without either,
        // the label sits at the TOP of the 38 — beside an add chip that has
        // always centred its own, so the run read as misaligned.
        child: Center(
          widthFactor: 1,
          child: Text(
            fxBlockName(l10n, effect),
            style: TextStyle(
              color: selected ? surface.accent : surface.textSecondary,
              fontSize: 16,
              height: 1.13,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final chain = widget.chain;
    final add = widget.onAdd;
    // A landing place belongs to the entry that can be placed; the fold
    // belongs to anything still in the air.
    final carrying = _carrying;
    final airborne = _airborne.isNotEmpty;
    // The empty line and the add chip together: an empty chain is exactly the
    // case where "put something on it" needs to be reachable, so the early
    // return that used to sit here hid the one affordance that mattered.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 5,
      children: [
        if (chain.isEmpty)
          Text(
            l10n.signalPanelChainEmpty,
            key: const Key('signal_panel_chain_empty'),
            style: TextStyle(
              color: surface.textMuted,
              fontSize: 16,
              height: 1.13,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        Wrap(
          // Unchanged whether a drag is up or not: the drop targets are the
          // chips themselves, so nothing is inserted into the run and nothing
          // moves under the hand that just pressed one.
          spacing: chipGap,
          runSpacing: chipGap,
          children: [
            for (final (index, effect) in chain.indexed)
              _entry(context, index, effect, carrying),
            // The add chip stays exactly where it is and only goes dark: it
            // is not a drop target, and removing it would empty a row of the
            // run — six entries and a `+ effect` need two rows on a
            // 1024-wide console — shortening the panel, clamping the scroll
            // view it sits at the bottom of, and sliding the whole strip out
            // from under the finger that just pressed it.
            if (add != null)
              Visibility(
                key: const Key('signal_panel_add_room'),
                visible: !airborne,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Semantics(
                  button: true,
                  label: l10n.fxAddChip,
                  child: InkWell(
                    key: const Key('signal_panel_add_chip'),
                    onTap: add,
                    borderRadius: BorderRadius.circular(8),
                    child: ExcludeSemantics(
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 17),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: surface.line),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            l10n.fxAddChip,
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 16,
                              height: 1.13,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The level row: a full-bleed bar with its dB readout at the trailing edge.
///
/// Not [ConsoleValueBar], which draws a label in a 106px gutter, stands 51
/// tall on a 12 radius and reads `0..1`. Here the caption is *above* the row,
/// the bar is 24 on a 6, and the range runs to [kSignalMaxGain].
///
/// **Not a Material [Slider] either**, which was the first attempt: its track
/// shape rounds to half its height, its active segment paints 2px taller than
/// the track it sits in, it insets the rail by the thumb radius, and it pads
/// the thumb's travel by a full track height so the fill stops tracking the
/// pointer near both ends. The fill is drawn directly instead — the same way
/// [ConsoleValueBar] draws its own.
class _LevelRow extends StatefulWidget {
  const _LevelRow({
    required this.value,
    required this.onChanged,
    this.live = true,
    super.key,
  });

  /// Whether the fader may still write.
  ///
  /// False while an entry is being carried. Hiding the row stops new touches
  /// but not one already in flight: `Visibility` ignores POINTERS, and a
  /// finger already on the fader keeps its recogniser and goes on setting the
  /// gain on a control nobody can see. Guarded rather than torn down, because
  /// the value under that finger is the one thing here worth keeping.
  final bool live;

  final double value;
  final ValueChanged<double> onChanged;

  /// The bar's own height and corner, as the mockups draw them.
  static const double rowHeight = 52;

  /// The bar's own height and corner, as the mockups draw them.
  static const double barHeight = 24;
  static const double barRadius = 6;

  /// Inside inset of the row, and the gap before the readout.
  static const double inset = 14;

  /// Width of the readout column.
  static const double readoutWidth = 52;

  @override
  State<_LevelRow> createState() => _LevelRowState();
}

class _LevelRowState extends State<_LevelRow> {
  /// The fraction under the finger while a drag is live, so the bar tracks it
  /// at frame rate instead of waiting for the write to come back.
  double? _dragging;

  /// What the rig was reporting when the finger went down.
  ///
  /// The release rule is "has the rig spoken", and this is what it is
  /// measured against. Two failures sit either side of it: dropping the local
  /// value the instant the finger lifts snaps the bar back to a gain the rig
  /// has not answered with yet and animates it there and back, while waiting
  /// for the rig to AGREE strands the bar forever when it clamps, refuses, or
  /// is an engine with no device running — and a lane's volume only reaches
  /// the snapshot once the audio callback drains the command queue, so
  /// silence is the normal case, not an error. Silence means the write was
  /// cached and will apply; only a DIFFERENT answer is the rig overruling the
  /// finger.
  double? _valueAtGrab;

  void _report(double width, double dx) {
    // Right-to-left reads the other way: the fill grows from the leading
    // edge, which is the right one there.
    final leading = Directionality.of(context) == TextDirection.rtl
        ? width - dx
        : dx;
    _set((leading / width).clamp(0.0, 1.0));
  }

  void _set(double fraction) {
    if (!widget.live) return;
    setState(() {
      _valueAtGrab ??= widget.value;
      _dragging = fraction;
    });
    widget.onChanged(fraction * kSignalMaxGain);
  }

  /// One step of the assistive-tech increase/decrease actions: twenty across
  /// the travel, so a swipe moves audibly without crossing the whole range.
  static const double step = 0.05;

  void _nudge(double by) {
    final at =
        _dragging ?? widget.value.clamp(0.0, kSignalMaxGain) / kSignalMaxGain;
    _set((at + by).clamp(0.0, 1.0));
  }

  @override
  void didUpdateWidget(_LevelRow old) {
    super.didUpdateWidget(old);
    if (_dragging == null || widget.value == _valueAtGrab) return;
    // The rig has spoken — agreeing or overruling, either way it is now the
    // one telling the truth about this chain.
    setState(() {
      _dragging = null;
      _valueAtGrab = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final gain = widget.value.clamp(0.0, kSignalMaxGain);
    final fraction = _dragging ?? gain / kSignalMaxGain;
    final readout = signalGainReadout(fraction * kSignalMaxGain);

    return Container(
      height: _LevelRow.rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: _LevelRow.inset),
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              slider: true,
              label: l10n.signalPanelLevel,
              value: readout,
              // Flutter requires the neighbouring values alongside the
              // actions, and they are what the reader speaks after a swipe.
              increasedValue: fraction >= 1
                  ? readout
                  : signalGainReadout((fraction + step) * kSignalMaxGain),
              decreasedValue: fraction <= 0
                  ? readout
                  : signalGainReadout((fraction - step) * kSignalMaxGain),
              // The reader adjusts through THESE, not through the detector
              // below: Flutter synthesises `tap`/`scrollLeft`/`scrollRight`
              // from a bare GestureDetector, with a position in global space
              // that `_report` would read as a bar-local x — a swipe to turn
              // the monitor DOWN slammed it to +6 dB into whatever the rig is
              // plugged into.
              // Not offered where it cannot move: a swipe at the end of the
              // travel would otherwise write the value the rig already has.
              onIncrease: fraction >= 1 ? null : () => _nudge(step),
              onDecrease: fraction <= 0 ? null : () => _nudge(-step),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Silenced, so its synthesised actions cannot reach the
                    // rig; the slider node above is what the reader drives.
                    excludeFromSemantics: true,
                    onTapDown: (d) => _report(width, d.localPosition.dx),
                    onHorizontalDragStart: (d) =>
                        _report(width, d.localPosition.dx),
                    onHorizontalDragUpdate: (d) =>
                        _report(width, d.localPosition.dx),
                    // The grab area is the whole ROW, not the 24 the bar
                    // draws: this is the only fader on a console worked with
                    // a finger, and halving its height put dead bands above
                    // and below the thing you are aiming at.
                    child: SizedBox(
                      key: const Key('signal_panel_level'),
                      height: _LevelRow.rowHeight,
                      child: Center(
                        child: Container(
                          height: _LevelRow.barHeight,
                          decoration: BoxDecoration(
                            color: surface.control,
                            borderRadius: BorderRadius.circular(
                              _LevelRow.barRadius,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              _LevelRow.barRadius,
                            ),
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: AnimatedContainer(
                                duration: _dragging == null
                                    ? consoleMotion(context)
                                    : Duration.zero,
                                curve: Curves.easeOut,
                                width: width * fraction,
                                decoration: BoxDecoration(
                                  color: surface.accentSurface,
                                  border: BorderDirectional(
                                    end: BorderSide(
                                      color: surface.accent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: _LevelRow.inset),
          SizedBox(
            width: _LevelRow.readoutWidth,
            child: Text(
              readout,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: surface.textSecondary,
                fontFamily: SurfaceTheme.monoFont,
                fontSize: 14,
                height: 1.14,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
