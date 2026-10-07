import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/pen_icons.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop_count_words.dart';
import 'package:segno/looper/view/rename_track_dialog.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/theme/theme.dart';

/// The boundary a queued (pending) action waits for, as the accepted stage
/// names it inside the track: the engine's quantize grid, or the Sound start
/// that arms a take on the chosen input's signal.
enum QueueTiming {
  /// The next loop top (quantize on with no finer grid).
  loopStart,

  /// The next bar line.
  bar,

  /// The next half note.
  half,

  /// The next quarter note.
  quarter,

  /// The next eighth note.
  eighth,

  /// The next sixteenth note.
  sixteenth,

  /// Sound start: the arm fires on signal at the recording input.
  sound,
}

/// What a queued (pending) action will do when its boundary comes.
enum QueueAction {
  /// Start the track's take.
  record,

  /// Start an overdub pass on the recorded track.
  overdub,

  /// Play: an overdub's punch-out, or a section arm on a stopped track.
  play,

  /// Stop: a section arm on a sounding track.
  stop,
}

/// The [QueueAction] [track]'s pending arm fires — read off the engine's own
/// facts (`pendingTrigger`, state, content), never guessed from settings.
///
/// A section arm (Band transport) plays a stopped track and stops a sounding
/// one; a record arm ends an overdub pass, ends a take (landing it playing,
/// or overdubbing under the rec/dub setting [recDub]), starts a pass on a
/// recorded track, or starts the take on an empty one.
QueueAction queueActionOf(Track track, {required bool recDub}) {
  if (track.pendingTrigger == ArmTrigger.section) {
    return track.state == TrackState.stopped
        ? QueueAction.play
        : QueueAction.stop;
  }
  return switch (track.state) {
    TrackState.overdubbing => QueueAction.play,
    TrackState.recording => recDub ? QueueAction.overdub : QueueAction.play,
    TrackState.playing || TrackState.stopped => QueueAction.overdub,
    TrackState.empty => QueueAction.record,
  };
}

/// The boundary [track]'s pending arm waits for under the live quantize
/// [division].
///
/// Sound start fires on signal; a section arm and an overdub's punch-out fire
/// only at the loop top (the engine holds those to the primary's cycle and the
/// layer boundary, never a subdivision); a grid arm follows the division.
QueueTiming queueTimingOf(Track track, GridDivision division) {
  switch (track.pendingTrigger) {
    case ArmTrigger.sound:
      return QueueTiming.sound;
    case ArmTrigger.section:
      return QueueTiming.loopStart;
    case ArmTrigger.grid:
    case null:
      break;
  }
  if (track.state == TrackState.overdubbing) return QueueTiming.loopStart;
  return switch (division) {
    GridDivision.off => QueueTiming.loopStart,
    GridDivision.bar => QueueTiming.bar,
    GridDivision.half => QueueTiming.half,
    GridDivision.quarter => QueueTiming.quarter,
    GridDivision.eighth => QueueTiming.eighth,
    GridDivision.sixteenth => QueueTiming.sixteenth,
  };
}

/// The FX marker's three readings: bright when the track's chain is engaged,
/// dim when it is bypassed, absent when no effect is assigned.
enum _FxMarker { active, bypassed, absent }

/// One tall track column of the accepted stage: the info block (name with the
/// primary crown, number, bars, layers and the FX marker) over one
/// whole-track level meter — the queued-action cue and the FX-mode dressing
/// ride over it — and the thin progress bar along the bottom.
///
/// Tapping the meter selects the track and acts by mode (record/overdub in
/// record mode, mute/unmute in mute mode, FX chain on/off in FX mode);
/// long-press stops. Tapping the name renames. The crown is a readout.
class TrackColumn extends StatelessWidget {
  /// Creates a [TrackColumn].
  const TrackColumn({
    required this.track,
    required this.name,
    required this.selected,
    required this.mode,
    this.isPrimary = false,
    this.bars,
    this.beats,
    this.quantizeDiv = GridDivision.off,
    this.recDub = false,
    super.key,
  });

  /// The track this column renders — every fact drawn here comes from it
  /// except the meter's level and the progress bar's playhead.
  ///
  /// **The level comes from the ambient [LooperBloc], for `track.channel`.**
  /// That is the rebuild split (#646/#654/#832): the [TrackPeakMeter] leaf
  /// subscribes to the one moving number itself, so this instance may carry a
  /// tick-stale `peak` and the column still draws correctly — and so a meter
  /// tick redraws a bar instead of this whole tile.
  ///
  /// The cost of that is a real constraint on callers: a column is a LIVE
  /// view, not a function of its argument. Passing a [Track] that is not the
  /// bloc's own track for that channel — a synthesized preview, a session or
  /// preset snapshot, a frozen "before" state in an A/B — draws that track's
  /// steady facts under the rig's current level, or under no level at all for
  /// a channel the rig does not have. Such a surface needs its own meter
  /// widget, not this one. Enforced by an assert in [build], so the mistake
  /// fails loudly in debug instead of rendering perfectly and lying.
  final Track track;

  /// The track's resolved display name.
  final String name;

  /// Whether this column is selected (a white rather than card-colored ring).
  final bool selected;

  /// The active system mode (Record vs Mute vs FX).
  final InteractionMode mode;

  /// Whether [track] wears the primary crown — the first completed recording,
  /// or the explicit timing handoff. A readout, never a control.
  final bool isPrimary;

  /// The track's length in bars, or `null` when nothing counts them (an empty
  /// track, or a session without a tempo grid).
  final int? bars;

  /// The track's length in whole beats when its bars are not whole (a Divide
  /// of a sole loop, #1168), else null.
  final int? beats;

  /// The live quantize grid: with a grid arm pending, the queued cue names
  /// the boundary it resolves to (the engine re-evaluates a pending arm on a
  /// granularity change, so the cue follows the live division too).
  final GridDivision quantizeDiv;

  /// The rec/dub second-press setting: what a queued take-end lands as.
  final bool recDub;

  /// The column's inset from its ring to its content — the pen's 18.
  static const double padding = 18;

  /// The ring's stroke.
  static const double border = 2;

  /// The info block's fixed height — the pen's 124: two name lines and the
  /// meta row, so every column's meter starts at the same y.
  static const double infoHeight = 124;

  /// The vertical gap between the info block, the meter and the progress bar.
  static const double gap = 14;

  /// Where the meter starts below the column's top edge — what the shared
  /// dBFS scales beside the run line their 0 dBFS mark up with.
  static const double meterTopInset = border + padding + infoHeight + gap;

  /// Where the meter ends above the column's bottom edge — the scales' -60.
  static const double meterBottomInset =
      border + padding + TrackProgressBar.height + gap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final looper = theme.extension<LooperTheme>()!;
    final surface = context.surface;
    final bloc = context.read<LooperBloc>();
    // Debug-only enforcement of the live-view rule on [track]. The meter reads
    // its level out of THIS bloc by channel, so handing a column a track the
    // bloc does not hold draws one track's facts under another's level — a
    // mis-wiring that renders perfectly and is invisible in a screenshot.
    //
    // Compared as `SteadyTrack`, not by `listEquals` on the prop lists: the
    // comparison has to be Equatable-deep, because `_project` builds a fresh
    // `lanes` literal every poll and a shallow list compare would call two
    // value-equal projections one tick apart different — rejecting the
    // tick-stale instance this widget is DESIGNED to be handed. Steady, so a
    // stale `peak` stays legal, which is the whole point of the split.
    assert(
      () {
        final live = bloc.state.tracks.where((t) => t.channel == track.channel);
        if (live.length != 1) return false;
        return SteadyTrack(live.first) == SteadyTrack(track);
      }(),
      'TrackColumn was given a Track the ambient LooperBloc does not hold '
      '(channel ${track.channel}). A column is a live view of that bloc, not '
      'a function of its argument — see TrackColumn.track.',
    );

    // The ring is always 2px; selection changes it from the card stroke to
    // white. The meter bar color is one table lookup on the track's meter state
    // (muted included; see LooperTheme.meterColors).
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final barColor = looper.meterColor(meterState, mode: mode);

    // The meter conveys state through colour only (WCAG 1.4.1); name the state
    // in words so it reaches the tile's accessible label.
    final stateWord = switch (meterState) {
      LooperMeterState.empty => l10n.trackStateEmpty,
      LooperMeterState.recording => l10n.trackStateRecording,
      LooperMeterState.overdubbing => l10n.trackStateOverdubbing,
      LooperMeterState.playing => l10n.trackStatePlaying,
      LooperMeterState.stopped => l10n.trackStateStopped,
      LooperMeterState.muted => l10n.trackStateMuted,
    };
    // Layers: the base take plus every retired overdub pass. The base loop is
    // not an engine undo layer (undo_depth counts retired passes only), but it
    // is a layer the performer hears, so it counts as the first.
    final layers = track.layers;
    final fxMarker = track.effects.isEmpty
        ? _FxMarker.absent
        : track.chainEnabled
        ? _FxMarker.active
        : _FxMarker.bypassed;

    return Container(
      decoration: BoxDecoration(
        color: looper.tileBackground,
        borderRadius: BorderRadius.circular(17),
        // 2px ring: white when selected (onAccent), otherwise the pen's
        // card stroke (the `card` token) — not borderless.
        border: Border.all(
          color: selected ? surface.onAccent : surface.card,
          width: border,
        ),
      ),
      padding: const EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: infoHeight,
            child: _TrackInfo(
              channel: track.channel,
              name: name,
              isPrimary: isPrimary,
              bars: bars,
              beats: beats,
              layers: layers,
              fxMarker: fxMarker,
              reversed: track.hasContent && track.reversed,
            ),
          ),
          const SizedBox(height: gap),
          Expanded(
            child: FocusableTapTarget(
              key: Key('tracks_tile_${track.channel}'),
              // The tap action follows the mode (mirroring the 1–8 number
              // keys): record/overdub in record mode, mute/unmute in mute
              // mode — one interaction mode for every surface, touch
              // included. The performance modes draw their own faces, so a
              // column there only selects.
              semanticLabel: switch (mode) {
                InteractionMode.record => l10n.a11yTrackTile(name, stateWord),
                InteractionMode.mute => l10n.a11yTrackTileMute(name, stateWord),
                InteractionMode.fx ||
                InteractionMode.custom ||
                InteractionMode.mixer ||
                InteractionMode.fade ||
                InteractionMode.reverse ||
                InteractionMode.peel ||
                InteractionMode.tuner ||
                InteractionMode.multiply ||
                InteractionMode.divide => l10n.a11yTrackTileCustom(
                  name,
                  stateWord,
                ),
              },
              selected: selected,
              borderRadius: 8,
              onTap: () {
                context.read<ControlCubit>().selectTrack(track.channel);
                switch (mode) {
                  case InteractionMode.mute:
                    bloc.add(LooperMuteToggled(track.channel));
                  case InteractionMode.fx:
                  case InteractionMode.record:
                  case InteractionMode.mixer:
                  case InteractionMode.fade:
                  case InteractionMode.reverse:
                  case InteractionMode.peel:
                  case InteractionMode.tuner:
                  case InteractionMode.multiply:
                  case InteractionMode.divide:
                  case InteractionMode.custom:
                    // Selection only. Record/Play operates the selected
                    // track, so a tap arms it rather than recording. What a
                    // control does in Custom controls is assigned per
                    // FOOTSWITCH, and a tile is not one.
                    break;
                }
              },
              child: GestureDetector(
                key: Key('tracks_tileStop_${track.channel}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
                child: Stack(
                  children: [
                    Positioned.fill(
                      // The one part of the column a level tick redraws: the
                      // bar subscribes to this channel's peak itself, so the
                      // ~250 lines around it stay off the meter's rebuild path
                      // (#646/#654/#832).
                      child: TrackPeakMeter(
                        // Live, by channel: [track]'s own `peak` is
                        // deliberately not read here — see [track]'s doc.
                        channel: track.channel,
                        color: barColor,
                        hasContent: track.hasContent,
                        // A stopped track reports no live peak; hold the last
                        // fill so a loaded-but-paused loop keeps a visible bar
                        // after a stop.
                        frozen: track.state == TrackState.stopped,
                        // The accepted stage's red clip cap.
                        clipColor: looper.recordColor,
                      ),
                    ),
                    // A queued action sits centrally in its own track, with
                    // its action and boundary (the accepted stage). A readout,
                    // never a target: the tap falls through to the tile.
                    if (track.pending)
                      Positioned.fill(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _QueuedCue(
                              key: Key('tracks_queued_${track.channel}'),
                              action: _queueActionLabel(
                                l10n,
                                queueActionOf(track, recDub: recDub),
                              ),
                              timing: _queueTimingLabel(
                                l10n,
                                queueTimingOf(track, quantizeDiv),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: gap),
          TrackProgressBar(
            key: Key('tracks_progress_${track.channel}'),
            channel: track.channel,
            color: barColor,
          ),
        ],
      ),
    );
  }
}

/// The accepted stage's wording for a [QueueAction].
String _queueActionLabel(AppLocalizations l10n, QueueAction action) =>
    switch (action) {
      QueueAction.record => l10n.stageQueueRecord,
      QueueAction.overdub => l10n.stageQueueOverdub,
      QueueAction.play => l10n.stageQueuePlay,
      QueueAction.stop => l10n.stageQueueStop,
    };

/// The accepted stage's wording for a [QueueTiming].
String _queueTimingLabel(AppLocalizations l10n, QueueTiming timing) =>
    switch (timing) {
      QueueTiming.loopStart => l10n.stageQueueLoopStart,
      QueueTiming.bar => l10n.stageQueueNextBar,
      QueueTiming.half => l10n.stageQueueHalf,
      QueueTiming.quarter => l10n.stageQueueQuarter,
      QueueTiming.eighth => l10n.stageQueueEighth,
      QueueTiming.sixteenth => l10n.stageQueueSixteenth,
      QueueTiming.sound => l10n.stageQueueSound,
    };

/// The column's info block: the name (with the crown before it when the track
/// is primary) centred over two lines, and the meta row — number, bars,
/// layers, FX — along the block's bottom edge. Tapping the name renames.
class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.channel,
    required this.name,
    required this.isPrimary,
    required this.bars,
    required this.beats,
    required this.layers,
    required this.fxMarker,
    required this.reversed,
  });

  final int channel;
  final String name;
  final bool isPrimary;
  final int? bars;

  /// The track's length in whole beats when its bars are not whole (a Divide
  /// of a sole loop, #1168), else null.
  final int? beats;
  final int layers;
  final _FxMarker fxMarker;
  final bool reversed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: FocusableTapTarget(
              key: Key('tracks_name_$channel'),
              semanticLabel: l10n.a11yRenameTrack(name),
              onTap: () => showRenameTrackDialog(
                context: context,
                cubit: context.read<TracksCubit>(),
                channel: channel,
                current: name,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPrimary) ...[
                    PrimaryCrown(
                      key: Key('tracks_crown_$channel'),
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: AppText(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // The pen's name: UI sans, 700 32/1.2, two lines.
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
        _TrackMeta(
          channel: channel,
          bars: bars,
          beats: beats,
          layers: layers,
          fxMarker: fxMarker,
          reversed: reversed,
        ),
      ],
    );
  }
}

/// The meta row under the name: the channel number, the bar and layer counts
/// with their small units, then the Reverse and FX markers at the trailing
/// edge. FX is bright when the chain is engaged, dim when bypassed, and always
/// holds its place. REV takes a slot only while the track plays reversed, so
/// a forward row is the pen row and a reversed row makes room for the marker.
class _TrackMeta extends StatelessWidget {
  const _TrackMeta({
    required this.channel,
    required this.bars,
    required this.beats,
    required this.layers,
    required this.fxMarker,
    required this.reversed,
  });

  final int channel;
  final int? bars;

  /// The track's length in whole beats when its bars are not whole (a Divide
  /// of a sole loop, #1168), else null.
  final int? beats;
  final int layers;
  final _FxMarker fxMarker;
  final bool reversed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final figure = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textPrimary,
      fontSize: 24,
      height: 1,
    );
    final unit = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textTertiary,
      fontSize: 17,
      height: 1,
    );
    final count = loopCountWords(l10n, bars: bars, beats: beats);
    final barsFigure = count.spoken;
    final meta = l10n.a11yStageTrackMeta(
      channel + 1,
      barsFigure,
      l10n.stageLayersFigure(layers),
    );
    return Semantics(
      // The row's markers are excluded below; the reversed state is read out
      // with the meta line instead.
      label: reversed ? '$meta, ${l10n.a11yStageReversed}' : meta,
      child: ExcludeSemantics(
        // Spread across the column at the pen's size; scaled down as one
        // piece in a narrower column (a desktop window) rather than
        // overflowing or wrapping.
        child: ShrinkToWidth(
          child: Row(
            key: Key('tracks_meta_$channel'),
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            // A floor under the pen's even spread: when long counts or units
            // fill the row, its parts still never touch (the row then scales
            // down as one piece). With room to spare the layout is unchanged.
            spacing: _ReverseMarker.gap,
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
              _Figure(
                key: Key('tracks_bars_$channel'),
                figure: count.figure,
                unit: count.unit,
                figureStyle: figure,
                unitStyle: unit,
              ),
              _Figure(
                key: Key('tracks_layers_$channel'),
                figure: '$layers',
                unit: l10n.stageLayersUnit(layers),
                figureStyle: figure,
                unitStyle: unit,
              ),
              // REV takes a real slot before FX while the track plays
              // reversed, so it can never paint over a long Spanish unit or
              // a two-digit count; a forward row is the pen's row exactly.
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  if (reversed) ...[
                    _ReverseMarker(channel: channel),
                    const SizedBox(width: _ReverseMarker.gap),
                  ],
                  Semantics(
                    label: switch (fxMarker) {
                      _FxMarker.active => l10n.a11yStageFxActive,
                      _FxMarker.bypassed => l10n.a11yStageFxBypassed,
                      _FxMarker.absent => null,
                    },
                    child: Opacity(
                      // Absent keeps its width so the row never reflows when a
                      // chain appears.
                      opacity: fxMarker == _FxMarker.absent ? 0 : 1,
                      child: AppText(
                        l10n.stageFxMarker,
                        key: Key('tracks_fx_$channel'),
                        style: TextStyle(
                          fontFamily: SurfaceTheme.displayFont,
                          color: fxMarker == _FxMarker.active
                              ? surface.textPrimary
                              : surface.textMuted,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "REV" while the track plays reversed. It reads the repository's
/// published direction, so it stays after the Reverse surface is left.
class _ReverseMarker extends StatelessWidget {
  const _ReverseMarker({required this.channel});

  final int channel;

  /// The gap kept between REV and the FX marker after it.
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) => AppText(
    context.l10n.stageReverseMarker,
    key: Key('tracks_reverse_$channel'),
    style: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: context.surface.textPrimary,
      fontSize: 19,
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
      height: 1,
    ),
  );
}

/// Lays [child] out at least as wide as the available width, then scales it
/// down uniformly when its own width exceeds that — the idiom for a row of
/// pen-sized readouts that must survive a narrower desktop window without
/// overflowing. At the pen's size nothing scales.
class ShrinkToWidth extends StatelessWidget {
  /// Creates a [ShrinkToWidth].
  const ShrinkToWidth({required this.child, super.key});

  /// The row to protect.
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
        ),
        child: child,
      ),
    ),
  );
}

/// A figure with its small unit after it: `2 bars`, `4 layers`.
class _Figure extends StatelessWidget {
  const _Figure({
    required this.figure,
    required this.unit,
    required this.figureStyle,
    required this.unitStyle,
    super.key,
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
      const SizedBox(width: 5),
      AppText(unit, style: unitStyle),
    ],
  );
}

/// The primary-track crown, drawn as the pen draws it. A readout: it names
/// the track as primary for a screen reader and takes no tap.
class PrimaryCrown extends StatelessWidget {
  /// Creates a [PrimaryCrown] [size] wide.
  const PrimaryCrown({required this.size, super.key});

  /// The glyph's width; the crown is wider than tall.
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.l10n.a11yTrackPrimary,
    child: PenIconView(
      icon: PenIcon.crown,
      size: size,
      color: context.surface.textPrimary,
    ),
  );
}

/// The queued-action cue: the action over its boundary, in a small card in
/// the middle of the track's meter. Carries its own semantics; takes no tap
/// (the tile beneath keeps the gesture, so a second press still cancels the
/// arm).
class _QueuedCue extends StatelessWidget {
  const _QueuedCue({required this.action, required this.timing, super.key});

  final String action;
  final String timing;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return IgnorePointer(
      child: Semantics(
        label: context.l10n.a11yTrackQueued(action, timing),
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(
                  action,
                  style: TextStyle(
                    fontFamily: SurfaceTheme.displayFont,
                    color: surface.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 8),
                AppText(
                  timing,
                  style: TextStyle(
                    fontFamily: SurfaceTheme.displayFont,
                    color: surface.warning,
                    fontSize: 20,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
