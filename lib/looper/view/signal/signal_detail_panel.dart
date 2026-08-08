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
    final bloc = context.read<LooperBloc>();
    // NOT `context.select` on the lane itself: a [Lane] carries live meters,
    // so selecting it would rebuild this panel at the meter rate. Only the
    // three facts the panel draws decide whether it needs redrawing — the
    // same argument `sameChainShape` makes for the card runs.
    return BlocBuilder<LooperBloc, LooperState>(
      buildWhen: (previous, current) => !sameLaneFacts(
        _laneOf(previous, track, lane),
        _laneOf(current, track, lane),
      ),
      builder: (context, state) {
        final take = _laneOf(state, track, lane);
        // The lane can go while its panel is open — a track's lane count is a
        // live setting. Nothing beats a panel of stale numbers.
        if (take == null) return const SizedBox.shrink();
        return _PanelBody(
          address: FxAddress(
            stage: FxStage.loop,
            index: track,
            lane: lane,
          ),
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
      buildWhen: (previous, current) => !sameTrackFacts(
        _trackOf(previous, track),
        _trackOf(current, track),
      ),
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
class _PanelBody extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final gain = level;
    final inMix = heard;
    final mode = monitorMode;

    final selected = context.select<SettingsTrayCubit, int?>(
      (c) => c.state.signalEffect,
    );
    final tray = context.read<SettingsTrayCubit>();
    // An entry can go while its editor is open — removed from another
    // surface, or the whole chain rewritten by a record-time snapshot copy.
    // The editor is DROPPED here rather than rendered empty: leaving the
    // selection set would suppress `level` and `in the mix` too, and with no
    // chip left to tap there would be nothing on the face able to clear it.
    final editing = selected != null && selected < chain.length
        ? selected
        : null;
    if (selected != null && editing == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // `context.mounted` guards the element; the cubit needs its own check,
        // since emitting on a closed one throws — reachable in tests whose
        // tearDown closes the cubit before the frame settles.
        if (context.mounted && !tray.isClosed) tray.clearSignalEffect();
      });
    }
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
          _Header(title: title, subtitle: subtitle),
          _Caption(l10n.signalPanelChain),
          _ChainStrip(
            chain: chain,
            editing: editing,
            onSelect: tray.selectSignalEffect,
          ),
          // The editor takes the place of `level` and `in the mix`: you are
          // looking at ONE effect now, and how loud the whole chain is is a
          // question about the chain. The monitor segment below stays — what
          // you hear is still true while you change what it sounds like.
          if (editing != null)
            SignalFxEditor(
              scope: scope,
              index: editing,
              onClose: () => tray.selectSignalEffect(editing),
              onMoved: tray.showSignalEffect,
            )
          else ...[
            if (gain != null && onLevel != null) ...[
              _Caption(l10n.signalPanelLevel),
              _LevelRow(
                key: ValueKey(address),
                value: gain,
                onChanged: onLevel!,
              ),
            ],
            if (inMix != null && onHeard != null) ...[
              _Caption(l10n.signalPanelInMix),
              ConsoleSegmented<bool>(
                key: const Key('signal_panel_in_mix'),
                stretch: true,
                selected: inMix,
                onChanged: onHeard!,
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
              onChanged: onMonitorMode!,
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
/// accent pair. `+ effect` — the add affordance the mockups draw as the last
/// chip — arrives with the browse-and-add PR.
class _ChainStrip extends StatelessWidget {
  const _ChainStrip({
    required this.chain,
    required this.editing,
    required this.onSelect,
  });

  final List<TrackEffect> chain;

  /// Which entry is open in the editor, or null when none is.
  final int? editing;

  /// Opens (or, on the open chip, closes) an entry's editor.
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (chain.isEmpty) {
      return Text(
        l10n.signalPanelChainEmpty,
        key: const Key('signal_panel_chain_empty'),
        style: TextStyle(
          color: surface.textMuted,
          fontSize: 16,
          height: 1.13,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      );
    }
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final (index, effect) in chain.indexed)
          Semantics(
            button: true,
            selected: index == editing,
            label: fxBlockName(l10n, effect),
            child: InkWell(
              key: Key('signal_panel_chip_$index'),
              onTap: () => onSelect(index),
              borderRadius: BorderRadius.circular(8),
              child: ExcludeSemantics(
                // No `alignment`: a Container with one expands to its
                // constraints, which inside a Wrap made every chip span the
                // whole panel. The padding centres the label on its own.
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 17),
                  decoration: BoxDecoration(
                    // Unselected carries no fill at all, as the mockups draw
                    // it; the open one takes the accent pair.
                    color: index == editing ? surface.accentSurface : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    fxBlockName(l10n, effect),
                    style: TextStyle(
                      color: index == editing
                          ? surface.accent
                          : surface.textSecondary,
                      fontSize: 16,
                      height: 1.13,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
              ),
            ),
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
  const _LevelRow({required this.value, required this.onChanged, super.key});

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
