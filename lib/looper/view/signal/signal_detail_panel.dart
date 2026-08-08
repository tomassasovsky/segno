import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/signal/signal_cards.dart';
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
/// Racks are #535, so the panel carries no rack chooser yet, and the chain's
/// chips are inert: opening one is the FX editor, which is the next PR.
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
    FxStage.loop => _LoopPanel(track: address.index, lane: address.lane ?? 0),
    FxStage.track => _TrackPanel(track: address.index),
    FxStage.master => const _MasterPanel(),
  };
}

/// An input's panel: its monitor chain, and the three facts about hearing it.
class _InputPanel extends StatelessWidget {
  const _InputPanel({required this.input});

  final int input;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<InputsCubit>().state.names;
    final cubit = context.read<MonitorCubit>();
    final monitor = context.watch<MonitorCubit>().state.forInput(input);

    return _PanelBody(
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
    final take = context.select<LooperBloc, Lane?>(
      (b) => b.state.tracks
          .where((t) => t.channel == track)
          .expand((t) => t.lanes.indexed)
          .where((entry) => entry.$1 == lane)
          .map((entry) => entry.$2)
          .firstOrNull,
    );
    // The lane can go while its panel is open — a track's lane count is a
    // live setting. Nothing to draw is better than a panel of stale numbers.
    if (take == null) return const SizedBox.shrink();

    return _PanelBody(
      title: l10n.trackName(names, track),
      subtitle: l10n.signalPanelSubtitle(
        l10n.signalCoordTrackLane(track + 1, laneLetter(lane)),
        l10n.signalStageLoop,
      ),
      chain: take.effects,
      level: take.volume,
      onLevel: (value) => bloc.add(LooperLaneVolumeChanged(track, lane, value)),
      heard: !take.muted,
      onHeard: (_) => bloc.add(LooperLaneMuteToggled(track, lane)),
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
    final bus = context.select<LooperBloc, Track?>(
      (b) => b.state.tracks.where((t) => t.channel == track).firstOrNull,
    );
    if (bus == null) return const SizedBox.shrink();

    return _PanelBody(
      title: l10n.trackName(names, track),
      subtitle: l10n.signalPanelSubtitle(
        l10n.signalCoordTrack(track + 1),
        l10n.signalStageTrack,
      ),
      chain: bus.effects,
      level: bus.volume,
      onLevel: (value) => bloc.add(LooperVolumeChanged(track, value)),
      heard: !bus.muted,
      onHeard: (_) => bloc.add(LooperMuteToggled(track)),
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
    final chain = context.select<LooperBloc, List<TrackEffect>>(
      (b) => b.state.masterEffects,
    );

    return _PanelBody(
      title: l10n.signalMasterCardName,
      subtitle: l10n.signalPanelSubtitle(
        l10n.signalCoordMain,
        l10n.signalStageMaster,
      ),
      chain: chain,
    );
  }
}

/// The panel's shape: a captioned stack of rows, in signal order — what is on
/// the chain, then how loud it is, then whether it is heard at all.
class _PanelBody extends StatelessWidget {
  const _PanelBody({
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
          _ChainStrip(chain: chain),
          if (gain != null && onLevel != null) ...[
            _Caption(l10n.signalPanelLevel),
            _LevelRow(value: gain, onChanged: onLevel!),
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
      spacing: 5,
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
/// Inert in this PR: a chip opens the FX editor, which is the next one, and a
/// chip that highlighted with nothing to show would be a state with no
/// consequence — the same rule the cards followed before this panel existed.
class _ChainStrip extends StatelessWidget {
  const _ChainStrip({required this.chain});

  final List<TrackEffect> chain;

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
          Container(
            key: Key('signal_panel_chip_$index'),
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 17),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: surface.control,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              fxBlockName(l10n, effect),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 16,
                height: 1.13,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
      ],
    );
  }
}

/// The level row: a full-bleed bar with its dB readout at the trailing edge.
///
/// Not [ConsoleValueBar], which draws its own label in a 106px gutter at the
/// left. Here the caption sits *above* the row, so a gutter would be an empty
/// column and the bar would stop short of the panel's edge for no reason.
class _LevelRow extends StatelessWidget {
  const _LevelRow({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
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
              value: signalGainReadout(value),
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 24,
                  activeTrackColor: surface.accentSurface,
                  inactiveTrackColor: surface.control,
                  thumbColor: surface.accent,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 3,
                  ),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  key: const Key('signal_panel_level'),
                  value: value.clamp(0, kSignalMaxGain),
                  max: kSignalMaxGain,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 52,
            child: Text(
              signalGainReadout(value),
              textAlign: TextAlign.right,
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
