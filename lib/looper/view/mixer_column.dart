import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart'
    show routingPlacementLabel;
import 'package:segno/looper/view/rename_track_dialog.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/looper/view/track_column.dart'
    show PrimaryCrown, ShrinkToWidth;
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/theme/theme.dart';

/// One track's Mixer strip (accepted design, the Mixer view): its name and
/// meta, Mute, Solo and the FX pair, its pan, and a stereo meter with the
/// level's own marker riding on it.
///
/// A LIVE view of the ambient [LooperBloc] for `track.channel`, like
/// `TrackColumn`: the meter and the playhead subscribe to their own values in
/// their own leaves, so a level tick redraws two bars rather than the strip.
///
/// The level marker sits ON the meter rather than beside it as a fader,
/// because that is what the accepted design draws: one control, over the
/// thing it governs. Dragging it anywhere in the meter's height sets the
/// level; the meter keeps metering underneath.
class MixerColumn extends StatelessWidget {
  /// Creates a [MixerColumn].
  const MixerColumn({
    required this.track,
    required this.name,
    required this.selected,
    required this.mode,
    this.isPrimary = false,
    this.bars,
    super.key,
  });

  /// The track this strip draws. Its live fields may be a tick stale; the
  /// meter and the progress bar read their own.
  final Track track;

  /// The track's display name.
  final String name;

  /// Whether this is the cursor's track.
  final bool selected;

  /// The interaction mode, which colours the meter as it does elsewhere.
  final InteractionMode mode;

  /// Whether this track wears the crown.
  final bool isPrimary;

  /// The track's length in bars, when the grid knows it.
  final int? bars;

  /// The pen's strip padding, and the height of every fixed part between the
  /// meter and the edges. A COLUMN, not absolute offsets: the pen's strip is
  /// 858 tall and a desktop window is not, and a strip laid out by `top:`
  /// would push its meter off the bottom rather than shrink it.
  static const double padding = 20;
  static const double _infoHeight = 119;
  static const double _buttonsHeight = 54;
  static const double _panHeight = 89;
  static const double _captionHeight = 24;
  static const double _labelsHeight = 16;
  static const double _gap = 14;
  static const double _captionGap = 12;

  /// The pen's small-button height, its bypass width, the pan bar's own
  /// height and the level marker's thickness.
  static const double buttonHeight = _buttonsHeight;
  static const double panHeight = 54;
  static const double markerHeight = 4;

  /// What the stage's dB scale aligns to, the same contract `TrackColumn`
  /// publishes: the scale lines up with the meter, not with the strip.
  static const double meterTopInset =
      padding +
      _infoHeight +
      _gap +
      _buttonsHeight +
      _gap +
      _panHeight +
      _gap +
      _captionHeight +
      _captionGap;
  static const double meterBottomInset =
      padding + _gap + _labelsHeight + _gap + TrackProgressBar.height;

  /// The shortest meter worth drawing, and so the shortest strip: below this
  /// the whole strip scales down as one piece rather than overflowing.
  ///
  /// The pen draws the strip 858 tall and every part inside it at a fixed
  /// height, which is right at 1080p and impossible in a desktop window a
  /// third of that. Scaling keeps the proportions the design chose instead of
  /// picking, silently, which part to sacrifice.
  static const double _meterMin = 120;
  static const double _minHeight = meterTopInset + _meterMin + meterBottomInset;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final looper = Theme.of(context).extension<LooperTheme>()!;
    final l10n = context.l10n;
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final barColor = looper.meterColor(meterState, mode: mode);

    final content = Container(
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: selected ? surface.onAccent : surface.card,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _infoHeight,
            child: _StripInfo(
              track: track,
              name: name,
              isPrimary: isPrimary,
              bars: bars,
            ),
          ),
          const SizedBox(height: _gap),
          SizedBox(
            height: _buttonsHeight,
            child: _StripButtons(track: track),
          ),
          const SizedBox(height: _gap),
          SizedBox(
            height: _panHeight,
            child: _StripPan(track: track),
          ),
          const SizedBox(height: _gap),
          SizedBox(
            height: _captionHeight,
            child: _StripGainCaption(volume: track.volume),
          ),
          const SizedBox(height: _captionGap),
          Expanded(
            child: _StripMeter(
              track: track,
              color: barColor,
              clipColor: looper.recordColor,
            ),
          ),
          const SizedBox(height: _gap),
          SizedBox(
            height: _labelsHeight,
            child: _StripSideLabels(
              left: l10n.routingPairLeft,
              right: l10n.routingPairRight,
            ),
          ),
          const SizedBox(height: _gap),
          TrackProgressBar(
            key: Key('mixer_progress_${track.channel}'),
            channel: track.channel,
            color: barColor,
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight >= _minHeight) return content;
        return FittedBox(
          child: SizedBox(
            width: constraints.maxWidth,
            height: _minHeight,
            child: content,
          ),
        );
      },
    );
  }
}

/// The strip's head: the crown, the name (which renames on tap) and the meta
/// row the Track view already prints.
class _StripInfo extends StatelessWidget {
  const _StripInfo({
    required this.track,
    required this.name,
    required this.isPrimary,
    required this.bars,
  });

  final Track track;
  final String name;
  final bool isPrimary;
  final int? bars;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: FocusableTapTarget(
              key: Key('mixer_name_${track.channel}'),
              semanticLabel: l10n.a11yRenameTrack(name),
              onTap: () => showRenameTrackDialog(
                context: context,
                cubit: context.read<TracksCubit>(),
                channel: track.channel,
                current: context.read<TracksCubit>().state.nameOf(
                  track.channel,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPrimary) ...[
                    const PrimaryCrown(size: 28),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: AppText(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: SurfaceTheme.displayFont,
                        color: surface.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _StripMeta(channel: track.channel, layers: track.layers, bars: bars),
      ],
    );
  }
}

/// The strip's meta row: the track number, its bars and its layers, in the
/// Track view's own words.
class _StripMeta extends StatelessWidget {
  const _StripMeta({
    required this.channel,
    required this.layers,
    required this.bars,
  });

  final int channel;
  final int layers;
  final int? bars;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final figure = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textSecondary,
      fontSize: 24,
      height: 1,
    );
    final unit = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textTertiary,
      fontSize: 17,
      height: 1,
    );
    final barsCount = bars;
    return Semantics(
      label: l10n.a11yStageTrackMeta(
        channel + 1,
        barsCount == null
            ? l10n.stageNoBarsFigure
            : l10n.stageBarsFigure(barsCount),
        l10n.stageLayersFigure(layers),
      ),
      child: ExcludeSemantics(
        child: ShrinkToWidth(
          child: Row(
            key: Key('mixer_meta_$channel'),
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              AppText(
                '${channel + 1}',
                style: TextStyle(
                  fontFamily: SurfaceTheme.displayFont,
                  color: surface.textTertiary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
              _MetaFigure(
                figure: barsCount == null ? l10n.stageNoBars : '$barsCount',
                unit: l10n.stageBarsUnit(barsCount ?? 0),
                figureStyle: figure,
                unitStyle: unit,
              ),
              _MetaFigure(
                figure: '$layers',
                unit: l10n.stageLayersUnit(layers),
                figureStyle: figure,
                unitStyle: unit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaFigure extends StatelessWidget {
  const _MetaFigure({
    required this.figure,
    required this.unit,
    required this.figureStyle,
    required this.unitStyle,
  });

  final String figure;
  final String unit;
  final TextStyle figureStyle;
  final TextStyle unitStyle;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      AppText(figure, style: figureStyle),
      const SizedBox(width: 6),
      AppText(unit, style: unitStyle),
    ],
  );
}

/// Mute, Solo and the FX pair. Mute and Solo are independent facts: a soloed
/// track that is also muted stays silent, which is why neither button reads
/// the other's state.
class _StripButtons extends StatelessWidget {
  const _StripButtons({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bloc = context.read<LooperBloc>();
    final channel = track.channel;
    return Row(
      children: [
        Expanded(
          child: _StripButton(
            key: Key('mixer_mute_$channel'),
            label: l10n.mixerMute,
            on: track.muted,
            semanticLabel: track.muted
                ? l10n.a11yMixerUnmute(channel + 1)
                : l10n.a11yMixerMute(channel + 1),
            onTap: () => bloc.add(LooperMuteToggled(channel)),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: _StripButton(
            key: Key('mixer_solo_$channel'),
            label: l10n.mixerSolo,
            on: track.solo,
            semanticLabel: track.solo
                ? l10n.a11yMixerUnsolo(channel + 1)
                : l10n.a11yMixerSolo(channel + 1),
            onTap: () =>
                bloc.add(LooperTrackSoloToggled(channel, solo: !track.solo)),
            // Clearing every Solo at once has no control of its own in the
            // accepted design, and the stage already uses a long press for
            // its second action (a tile's long press stops the track). One
            // gesture, on the control it is about.
            onLongPress: () => bloc.add(const LooperSoloCleared()),
            longPressLabel: l10n.a11yMixerClearSolo,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(child: _StripFxPair(track: track)),
      ],
    );
  }
}

/// One of the strip's small state buttons: lit when [on].
class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.label,
    required this.on,
    required this.semanticLabel,
    required this.onTap,
    this.onLongPress,
    this.longPressLabel,
    super.key,
  });

  final String label;
  final bool on;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? longPressLabel;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      semanticLabel: semanticLabel,
      selected: on,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {
        if (onLongPress != null && longPressLabel != null)
          CustomSemanticsAction(label: longPressLabel!): onLongPress!,
      },
      borderRadius: 10,
      child: Container(
        height: MixerColumn.buttonHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? surface.accentSurface : surface.card,
          border: Border.all(
            color: on ? surface.borderStrong : surface.borderSubtle,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: AppText(
          label,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: on ? surface.textPrimary : surface.textSecondary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The track's FX bypass.
///
/// The pen draws a PAIR here — an edit button beside this one — but the FX
/// editor is slice 3f and does not exist yet, so that button would open
/// nothing. The bypass has a real owner today and ships on its own; the edit
/// button lands with the surface it opens.
///
/// Absent entirely when the track has no chain, which is the accepted
/// design's own rule for the Track view's FX marker: a control over nothing
/// is a promise the rig cannot keep.
///
/// A TOGGLE event, never a computed set: `track` here is the polled snapshot,
/// a poll behind any flip another surface just made.
class _StripFxPair extends StatelessWidget {
  const _StripFxPair({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (track.effects.isEmpty) return const SizedBox.shrink();
    final on = track.chainEnabled;
    return _StripButton(
      key: Key('mixer_fx_${track.channel}'),
      label: l10n.stageFxMarker,
      on: on,
      semanticLabel: on
          ? l10n.a11yMixerBypassFx(track.channel + 1)
          : l10n.a11yMixerEnableFx(track.channel + 1),
      onTap: () {
        TracksCommands(context).announceFxChainToggle(track.channel);
        context.read<LooperBloc>().add(LooperTrackChainToggled(track.channel));
      },
    );
  }
}

/// Where the track sits between the two jacks, with its readout.
class _StripPan extends StatefulWidget {
  const _StripPan({required this.track});

  final Track track;

  @override
  State<_StripPan> createState() => _StripPanState();
}

class _StripPanState extends State<_StripPan> {
  /// The pen's label row inside the 89-high pan block: 25 + 10 + 54.
  static const double _labelHeight = 25;

  /// The value being dragged, so the readout follows the finger without
  /// persisting one write per pointer move; `null` between touches.
  double? _drag;

  @override
  void didUpdateWidget(_StripPan oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The rig has spoken: a pan that moved from anywhere else (a session
    // load, a pedal binding, Reset mixer) ends the preview rather than being
    // overwritten by it.
    if (widget.track.pan != oldWidget.track.pan) _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final pan = _drag ?? widget.track.pan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The pen's own label height, fixed: left to its natural size the
        // row is a pixel or two over on some faces and the block that has to
        // add up to 89 does not.
        SizedBox(
          height: _labelHeight,
          child: ShrinkToWidth(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                AppText(
                  l10n.routingPan,
                  style: TextStyle(
                    fontFamily: SurfaceTheme.displayFont,
                    color: surface.textSecondary,
                    fontSize: 22,
                    height: 1,
                  ),
                ),
                AppText(
                  routingPlacementLabel(l10n, pan),
                  key: Key('mixer_pan_readout_${widget.track.channel}'),
                  style: TextStyle(
                    fontFamily: SurfaceTheme.displayFont,
                    color: surface.textPrimary,
                    fontSize: 22,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _StripPanBar(
          channel: widget.track.channel,
          pan: pan,
          onChanged: (v) => setState(() => _drag = v),
          onCommit: (v) {
            setState(() => _drag = null);
            context.read<LooperBloc>().add(
              LooperTrackPanChanged(widget.track.channel, pan: v),
            );
          },
        ),
      ],
    );
  }
}

/// The pan bar: a fill from the centre out, with a centre tick under it.
///
/// Not the Loop settings slider: that one takes a fixed pen width and fills
/// from the left, which reads as a level rather than a placement. A pan wants
/// its centre marked and its fill to grow from there.
class _StripPanBar extends StatelessWidget {
  const _StripPanBar({
    required this.channel,
    required this.pan,
    required this.onChanged,
    required this.onCommit,
  });

  final int channel;
  final double pan;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  double _panAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width * 2 - 1).clamp(-1.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Semantics(
          slider: true,
          label: l10n.a11yMixerPan(channel + 1),
          value: routingPlacementLabel(l10n, pan),
          child: GestureDetector(
            key: Key('mixer_pan_$channel'),
            behavior: HitTestBehavior.opaque,
            // On the LIFT, not the press: a press that wrote would commit
            // wherever the finger landed before a drag had a chance to move
            // it, so every drag would write twice.
            onTapUp: (d) => onCommit(_panAt(d.localPosition.dx, width)),
            onHorizontalDragUpdate: (d) =>
                onChanged(_panAt(d.localPosition.dx, width)),
            onHorizontalDragEnd: (_) => onCommit(pan),
            // Double-tap returns the track to the centre: the accepted design
            // gives every mix control a way home, and dragging back to
            // exactly zero by finger is not one.
            onDoubleTap: () => onCommit(0),
            child: SizedBox(
              height: MixerColumn.panHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.meterTrack,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  // The fill grows from the middle towards the side the track
                  // is placed on.
                  Positioned(
                    left: pan < 0 ? width / 2 + pan * width / 2 : width / 2,
                    width: (pan.abs() * width / 2).clamp(0.0, width / 2),
                    top: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.controlStrong,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  Positioned(
                    left: width / 2 - 1,
                    top: 0,
                    bottom: 0,
                    width: 2,
                    child: ColoredBox(color: surface.borderStrong),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The level's caption: the word and the gain the marker below is at.
class _StripGainCaption extends StatelessWidget {
  const _StripGainCaption({required this.volume});

  final double volume;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return ShrinkToWidth(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AppText(
            l10n.mixerLevel,
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textSecondary,
              fontSize: 22,
              height: 1,
            ),
          ),
          AppText(
            signalGainReadout(volume),
            style: signalMono(color: surface.textPrimary, size: 22),
          ),
        ],
      ),
    );
  }
}

/// The two sides' labels under the meter.
class _StripSideLabels extends StatelessWidget {
  const _StripSideLabels({required this.left, required this.right});

  final String left;
  final String right;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: context.surface.textTertiary,
      fontSize: 17,
      height: 1,
    );
    return Row(
      children: [
        Expanded(
          child: Center(child: AppText(left, style: style)),
        ),
        Expanded(
          child: Center(child: AppText(right, style: style)),
        ),
      ],
    );
  }
}

/// The strip's meter: two lanes of live level, the unity tick, and the
/// level's own marker riding over both.
///
/// One target. Dragging anywhere in the meter's height sets the level, and
/// the marker follows; the lanes keep metering underneath. That is what the
/// accepted design draws — a control over the thing it governs rather than a
/// fader beside it — and it is why the meter is a `Stack` rather than a
/// `Row` of bars.
class _StripMeter extends StatefulWidget {
  const _StripMeter({
    required this.track,
    required this.color,
    required this.clipColor,
  });

  final Track track;
  final Color color;
  final Color clipColor;

  @override
  State<_StripMeter> createState() => _StripMeterState();
}

class _StripMeterState extends State<_StripMeter> {
  /// The gain being dragged; `null` between touches. Same rule as the pan:
  /// the readout follows the finger, one write lands on release.
  double? _drag;

  @override
  void didUpdateWidget(_StripMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.track.volume != oldWidget.track.volume) _drag = null;
  }

  /// A gain from a pointer at [dy] in a meter [height] tall. Bottom is
  /// silence, top is the engine's ceiling, so the marker travels the same
  /// axis the level it sets does.
  double _gainAt(double dy, double height) => height <= 0
      ? 0
      : ((1 - dy / height) * kSignalMaxGain).clamp(0.0, kSignalMaxGain);

  void _commit(double gain) {
    setState(() => _drag = null);
    context.read<LooperBloc>().add(
      LooperVolumeChanged(widget.track.channel, gain),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final channel = widget.track.channel;
    final gain = _drag ?? widget.track.volume;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        // Unity is the reference the ear uses, so it gets a rule of its own
        // rather than being a position the player has to find.
        final unity = (height * (1 - 1 / kSignalMaxGain)).clamp(0.0, height);
        final marker = (height * (1 - gain / kSignalMaxGain)).clamp(
          0.0,
          height,
        );
        return Semantics(
          slider: true,
          label: l10n.a11yMixerLevel(channel + 1),
          value: signalGainReadout(gain),
          child: GestureDetector(
            key: Key('mixer_level_$channel'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _commit(_gainAt(d.localPosition.dy, height)),
            onVerticalDragUpdate: (d) => setState(
              () => _drag = _gainAt(d.localPosition.dy, height),
            ),
            onVerticalDragEnd: (_) => _commit(gain),
            // Back to unity, the same way the pan returns to centre.
            onDoubleTap: () => _commit(1),
            child: Stack(
              children: [
                Positioned.fill(
                  child: TrackStereoMeter(
                    channel: channel,
                    color: widget.color,
                    hasContent: widget.track.hasContent,
                    frozen: widget.track.state == TrackState.stopped,
                    clipColor: widget.clipColor,
                  ),
                ),
                Positioned(
                  left: -MixerColumn.padding,
                  right: -MixerColumn.padding,
                  top: unity,
                  height: 1,
                  child: ColoredBox(color: surface.borderHairline),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: marker,
                  height: MixerColumn.markerHeight,
                  child: ColoredBox(
                    key: Key('mixer_level_marker_$channel'),
                    color: surface.onAccent,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
