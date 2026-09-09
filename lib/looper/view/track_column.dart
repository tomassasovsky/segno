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
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/rename_track_dialog.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_commands.dart';
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

/// The [QueueTiming] a pending arm resolves to under [division], or
/// [QueueTiming.sound] when a Sound start ([soundStart]) armed it.
QueueTiming queueTimingOf(GridDivision division, {required bool soundStart}) {
  if (soundStart) return QueueTiming.sound;
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
    this.queueTiming = QueueTiming.loopStart,
    this.fxTarget,
    this.inputNames = const {},
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

  /// The FX stage the footswitch bound to this cell attaches to, in FX mode.
  ///
  /// FX mode identifies a cell CHAIN-FIRST — by the FX stage its bound chain
  /// targets, never by the column's track (#692): a footswitch may toggle a
  /// chain on any stage (an input monitor, a lane, another track's bus, the
  /// Master insert), so the cell names the chain it drives, not the track it
  /// happens to sit above.
  ///
  /// Null defaults to this column's own Track-stage chain — what the on-screen
  /// stage's per-column tap currently toggles ([LooperTrackChainToggled]) — so
  /// the identity still reads `TRACK n · …`, chain-first, exactly like any
  /// other target. The chain's entries and power state are always taken from
  /// [track] (the polled snapshot the stage renders); [fxTarget] renames the
  /// cell, it does not re-source the chain.
  final FxAddress? fxTarget;

  /// The player's own names for hardware inputs, keyed by socket index (the
  /// input-rename feature; `InputsState.names`).
  ///
  /// Only consulted when [fxTarget] is an Input-stage chain: a named socket
  /// makes the cell read `GUITAR 1 · …` instead of `INPUT 1 · …` (owner's
  /// call). Empty — the default — always yields the generic `INPUT n`.
  final Map<int, String> inputNames;

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

  /// What a pending arm on this track is waiting for — drawn in the queued
  /// cue beside its action.
  final QueueTiming queueTiming;

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
    final isFx = mode == InteractionMode.fx;
    final stateColor = looper.meterColor(meterState, mode: mode);
    // FX mode recedes the meter to 40% alpha so the chain dressing reads on top
    // of it (#692). The meter stays TRUTHFUL — it is taken pre-chain, so it is
    // the same fill and hue the other modes show — it just steps back to let
    // the chain identity own the tile. The other modes paint it at full weight.
    final barColor = isFx ? stateColor.withValues(alpha: 0.4) : stateColor;
    // The FX-mode cell identity, chain-first (#692): the FX stage the bound
    // chain sits on, then the chain's own name — the track name is deliberately
    // absent, since the cell drives an FX control that need not belong to this
    // column's track. The stage defaults to this column's own Track chain (what
    // the per-column tap toggles), so a track chain still reads `TRACK n · …`,
    // named like every other target rather than borrowing the track's name. The
    // chain name is the head of the entries the polled snapshot carries.
    final fxAddress =
        fxTarget ?? FxAddress(stage: FxStage.track, index: track.channel);
    final fxStageLabel = _stageFxTargetLabel(l10n, fxAddress);
    final fxChainName = track.effects.isEmpty
        ? null
        : fxBlockName(l10n, track.effects.first);
    // A NAMED input is the ONE two-tier identity (owner's call): the socket's
    // own name on top, a smaller `INPUT n` sub-label under it, and the chain in
    // the entry-run chips below (not jammed into the identity line). Every
    // other stage — and an UNNAMED input — is a single `TARGET · CHAIN` line,
    // or the bare stage when the chain is empty.
    final fxInputName = fxAddress.stage == FxStage.input
        ? (inputNames[fxAddress.index] ?? '')
        : '';
    final String fxIdentityPrimary;
    final String? fxIdentitySub;
    if (fxInputName.isNotEmpty) {
      fxIdentityPrimary = fxInputName.toUpperCase();
      fxIdentitySub = fxStageLabel;
    } else if (fxAddress.stage == FxStage.input || fxChainName == null) {
      // Unnamed input, or an empty chain on any stage: the bare stage label.
      fxIdentityPrimary = fxStageLabel;
      fxIdentitySub = null;
    } else {
      fxIdentityPrimary = l10n.stageFxCellLabel(
        fxStageLabel,
        fxChainName.toUpperCase(),
      );
      fxIdentitySub = null;
    }
    // The screen-reader identity flattens the two tiers into one phrase.
    final fxCellLabel = fxIdentitySub == null
        ? fxIdentityPrimary
        : '$fxIdentityPrimary $fxIdentitySub';

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
    final layers = track.undoDepth + (track.hasContent ? 1 : 0);
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
              layers: layers,
              fxMarker: fxMarker,
            ),
          ),
          const SizedBox(height: gap),
          Expanded(
            child: FocusableTapTarget(
              key: Key('tracks_tile_${track.channel}'),
              // The tap action follows the mode (mirroring the 1–8 number
              // keys): record/overdub in record mode, mute/unmute in mute
              // mode, FX-chain on/off in FX mode — one interaction mode for
              // every surface, touch included.
              // FX mode names the cell chain-first — its bound chain's target
              // identity (#692), not the track — and adds the CHAIN state,
              // which the meter never reports, while KEEPING the transport
              // word the other modes carry, which the meter otherwise conveys
              // by colour alone (WCAG 1.4.1).
              semanticLabel: switch (mode) {
                InteractionMode.record => l10n.a11yTrackTile(name, stateWord),
                InteractionMode.mute => l10n.a11yTrackTileMute(name, stateWord),
                InteractionMode.fx =>
                  track.chainEnabled
                      ? l10n.a11yTrackTileFxOn(fxCellLabel, stateWord)
                      : l10n.a11yTrackTileFxOff(fxCellLabel, stateWord),
              },
              selected: selected,
              borderRadius: 8,
              onTap: () {
                context.read<ControlCubit>().selectTrack(track.channel);
                switch (mode) {
                  case InteractionMode.record:
                    bloc.add(LooperRecordPressed(track.channel));
                  case InteractionMode.mute:
                    bloc.add(LooperMuteToggled(track.channel));
                  case InteractionMode.fx:
                    // Toggle event, not a computed set: `track` here is the
                    // polled snapshot, a poll behind any flip another surface
                    // just made. The announcement shares the keyboard path's
                    // helper so the two cannot drift.
                    TracksCommands(
                      context,
                    ).announceFxChainToggle(track.channel);
                    bloc.add(LooperTrackChainToggled(track.channel));
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
                    // FX mode re-dresses the tile in place (#692): over the
                    // receded meter, one centered vertical group in the
                    // cell's upper-middle — the chain-first `TARGET · CHAIN`
                    // identity as the dominant focal text, the chain's entries
                    // in signal order below it, then a large ON/OFF power pill
                    // (or a centered NO CHAIN when the chain is empty). This is
                    // the on-screen twin of the tile's semantic label and of
                    // the pedal's chain LED; the meter alone shows nothing
                    // about the chain, since it is taken pre-chain.
                    if (isFx)
                      Positioned.fill(
                        child: _FxChainDressing(
                          identityPrimary: fxIdentityPrimary,
                          identitySub: fxIdentitySub,
                          effects: track.effects,
                          chainEnabled: track.chainEnabled,
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
                              action: track.hasContent
                                  ? l10n.stageQueueOverdub
                                  : l10n.stageQueueRecord,
                              timing: _queueTimingLabel(l10n, queueTiming),
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
    required this.layers,
    required this.fxMarker,
  });

  final int channel;
  final String name;
  final bool isPrimary;
  final int? bars;
  final int layers;
  final _FxMarker fxMarker;

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
          layers: layers,
          fxMarker: fxMarker,
        ),
      ],
    );
  }
}

/// The meta row under the name: the channel number, the bar and layer counts
/// with their small units, and the FX marker at the trailing edge — bright
/// when the chain is engaged, dim when bypassed, invisible (but holding its
/// width) when no effect is assigned.
class _TrackMeta extends StatelessWidget {
  const _TrackMeta({
    required this.channel,
    required this.bars,
    required this.layers,
    required this.fxMarker,
  });

  final int channel;
  final int? bars;
  final int layers;
  final _FxMarker fxMarker;

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
    final barsCount = bars;
    final barsFigure = barsCount == null
        ? l10n.stageNoBarsFigure
        : l10n.stageBarsFigure(barsCount);
    return Semantics(
      label: l10n.a11yStageTrackMeta(
        channel + 1,
        barsFigure,
        l10n.stageLayersFigure(layers),
      ),
      child: ExcludeSemantics(
        // Spread across the column at the pen's size; scaled down as one
        // piece in a narrower column (a desktop window) rather than
        // overflowing or wrapping.
        child: ShrinkToWidth(
          child: Row(
            key: Key('tracks_meta_$channel'),
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
              _Figure(
                key: Key('tracks_bars_$channel'),
                figure: barsCount == null ? l10n.stageNoBars : '$barsCount',
                unit: l10n.stageBarsUnit(barsCount ?? 0),
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
        ),
      ),
    );
  }
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

/// The generic FX stage label of an FX-mode cell — the stage the bound chain
/// sits on: `INPUT n` / `TRACK n` / `LANE n` / `MASTER` (#692).
///
/// Indices are 1-based, matching every other jack name the rig gives. This is
/// name-free by design: TRACK never borrows the column's track name (the
/// conflation fix), and LANE / MASTER carry no name. A NAMED input's own name
/// is layered on TOP of this in [TrackColumn] as a two-tier identity (the name
/// over this `INPUT n` sub-label); this helper always returns the generic form.
String _stageFxTargetLabel(AppLocalizations l10n, FxAddress address) =>
    switch (address.stage) {
      FxStage.input => l10n.stageFxTargetInput(address.index + 1),
      FxStage.loop => l10n.stageFxTargetLane(address.lane ?? 0),
      FxStage.track => l10n.stageFxTargetTrack(address.index + 1),
      FxStage.master => l10n.stageFxTargetMaster,
    };

/// The FX-mode re-dressing drawn over a track's (receded) meter (#692).
///
/// Candidate A of the #692 spike: FX mode does not swap the stage, it
/// re-dresses each tile IN PLACE — geometry, the 1–8 key parity and the
/// footswitch map all stay frozen, so the performer's spatial map is untouched.
///
/// The dressing is ONE centered vertical group sitting in the cell's
/// upper-middle, over the waveform (the approved Pencil `stage-fx` frame), NOT
/// scattered to the corners:
///
/// 1. the chain-first `TARGET · CHAIN` identity — the dominant focal text,
///    white when engaged;
/// 2. the chain's entries as small chips joined by `→`, in signal order;
/// 3. a large ON/OFF power pill — purple-filled `ON`, ghost-outlined `OFF`.
///
/// A bypassed chain dims the whole group together. An empty chain replaces the
/// group with a centered NO CHAIN and its hint — there is nothing to power.
///
/// It carries no semantics ([ExcludeSemantics]) and no hit target
/// ([IgnorePointer]): [TrackColumn]'s tile already names the chain state for a
/// screen reader, and the FX-mode tap that toggles the chain has to fall
/// through to the tile beneath this overlay.
class _FxChainDressing extends StatelessWidget {
  const _FxChainDressing({
    required this.identityPrimary,
    required this.identitySub,
    required this.effects,
    required this.chainEnabled,
  });

  /// The cell's primary identity line — `TARGET · CHAIN` (e.g.
  /// `MASTER · REVERB`), the bare stage `TARGET`, or a NAMED input's own name.
  final String identityPrimary;

  /// The smaller, dimmer second identity tier, or null for a single-line
  /// identity. Only a named input carries one: its `INPUT n` under the name.
  final String? identitySub;

  /// The bound chain's entries, in processing order.
  final List<TrackEffect> effects;

  /// Whether the whole chain is engaged (drives the power pill and the group's
  /// engaged/dimmed reading).
  final bool chainEnabled;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: effects.isEmpty
              // Nothing loaded: no power pill (there is nothing to power), just
              // a centered NO CHAIN and the invitation to build one.
              ? const Align(
                  // Upper-middle: the NO CHAIN group centres at ~40% of the
                  // card, matching the pen. Scaled down, never overflowing,
                  // in a meter shorter than the pen's (a desktop window).
                  alignment: Alignment(0, -0.33),
                  child: FittedBox(fit: BoxFit.scaleDown, child: _FxNoChain()),
                )
              // The centered group, anchored so its centre sits at ~42.7% of
              // the card (the pen). A bypassed chain reads as dimmed — but
              // through OPAQUE muted colours, not a translucent group: dimming
              // white over the green fill tinted the identity green and the
              // pill blue (the pen's dimmed values are flat neutral greys).
              : Align(
                  alignment: const Alignment(0, -0.26),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // A FIXED two-line slot for the identity, top-anchored:
                        // a one-line identity leaves the lower line empty. This
                        // keeps the chip row and the ON/OFF pill at the SAME y
                        // in every cell — a named input's second tier no longer
                        // pushes the indicators down out of line with its one-
                        // line neighbours across the row.
                        SizedBox(
                          height: _kFxIdentitySlot,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: _FxCellIdentity(
                              primary: identityPrimary,
                              sub: identitySub,
                              enabled: chainEnabled,
                            ),
                          ),
                        ),
                        // Inter-element gaps opened to the pen's proportions:
                        // identity→chips ~3.8% of the card, chips→pill ~3.2%.
                        const SizedBox(height: 20),
                        _FxEntryRun(
                          effects: effects,
                          chainEnabled: chainEnabled,
                        ),
                        const SizedBox(height: 30),
                        _FxPowerPill(enabled: chainEnabled),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The centered "no effects loaded" state: a large NO CHAIN over a small,
/// dimmed hint pointing at the Signal tab where a chain is assembled. Both in
/// the UI sans, in the pen's flat muted grey.
class _FxNoChain extends StatelessWidget {
  const _FxNoChain();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          l10n.stageFxNoChain,
          key: const Key('tracks_tileFxNoChain'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textMuted,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        AppText(
          l10n.stageFxNoChainHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textMuted,
            fontSize: 18,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

/// The fixed height of the FX-cell identity slot — sized for the TWO-line
/// named input (primary 30 + 6 gap + `INPUT n` sub 18, plus the faces' line
/// overhead), so a one-line identity leaves the lower line empty and every
/// cell's chips + pill start at the same y.
const double _kFxIdentitySlot = 66;

/// The cell identity — the dominant focal text of an FX-mode cell, in the UI
/// sans, at the top of the centered group.
///
/// Usually a single [primary] line: `TARGET · CHAIN` (e.g. `MASTER · REVERB`),
/// a bare stage `TARGET`, or — for a NAMED input — the socket's own name, with
/// a smaller, dimmer [sub] tier (`INPUT n`) directly beneath it. Names the FX
/// control the cell drives, NOT the track in the column (#692). The [primary]
/// line is near-white ([SurfaceTheme.textPrimary]) when engaged and a flat,
/// OPAQUE muted grey ([SurfaceTheme.textSecondary]) when bypassed — never a
/// translucent white, which over the green meter tints green; the [sub] line is
/// always the muted grey. Carries no semantics of its own: the tile's FX label
/// already announces this same identity.
class _FxCellIdentity extends StatelessWidget {
  const _FxCellIdentity({
    required this.primary,
    required this.sub,
    required this.enabled,
  });

  final String primary;

  final String? sub;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final subLabel = sub;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          primary,
          key: const Key('tracks_tileFxTarget'),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: enabled ? surface.textPrimary : surface.textSecondary,
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            height: 1,
          ),
        ),
        if (subLabel != null) ...[
          const SizedBox(height: 6),
          AppText(
            subLabel,
            key: const Key('tracks_tileFxTargetSub'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textMuted,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              height: 1,
            ),
          ),
        ],
      ],
    );
  }
}

/// The large ON/OFF power pill — the prominent fully-round stadium below the
/// chips that states the whole chain's on/off at stage distance.
///
/// `ON` is purple-filled ([SurfaceTheme.fx]) with a WHITE label — a mode fill,
/// never an inline wash of `fx` (the high-contrast flavor could not reach that;
/// #737). `OFF` is the ghost of the same pill: transparent with a flat muted
/// grey ([SurfaceTheme.textMuted]) outline and label (the run's [Opacity] dims
/// it further when bypassed). The label is the UI sans, sized to the pen.
class _FxPowerPill extends StatelessWidget {
  const _FxPowerPill({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Container(
      key: const Key('tracks_tileFxPower'),
      padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 16),
      decoration: BoxDecoration(
        color: enabled ? surface.fx : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        // OFF ring is the pen's flat muted grey, not the fx purple (which over
        // the green meter read bluish).
        border: enabled ? null : Border.all(color: surface.textMuted, width: 2),
      ),
      child: AppText(
        enabled ? l10n.stageFxChainOn : l10n.stageFxChainOff,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: SurfaceTheme.displayFont,
          // White label (onAccent) on the purple ON fill; flat muted grey on
          // the ghost.
          color: enabled ? surface.onAccent : surface.textMuted,
          fontSize: 40,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          height: 1,
        ),
      ),
    );
  }
}

/// The chain's entries as small neutral chips joined by a sans `→`, in signal
/// order — the surface where #601's per-entry dim/strikethrough idiom will mark
/// bypassed entries. Sits directly below the identity, centered.
///
/// The whole run dims with the group when the chain is bypassed (the [Opacity]
/// here); the per-ENTRY seam is deliberate: [_FxEntryChip] already takes a
/// `bypassed` flag (always `false` until #601 wires per-entry state), so that
/// slice changes one argument here and nothing else.
class _FxEntryRun extends StatelessWidget {
  const _FxEntryRun({required this.effects, required this.chainEnabled});

  final List<TrackEffect> effects;

  final bool chainEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    // Interleave entry chips with arrow separators, in processing order.
    final children = <Widget>[];
    for (var i = 0; i < effects.length; i++) {
      if (i > 0) {
        // The literal '→' (U+2192) in the UI SANS — Inter has the glyph, so it
        // renders cleanly; the console's mono face does not, which is what drew
        // the .notdef tofu when the run inherited it.
        children.add(
          AppText(
            '→',
            style: TextStyle(
              fontFamily: SurfaceTheme.displayFont,
              color: surface.textMuted,
              fontSize: 16,
              height: 1,
            ),
          ),
        );
      }
      children.add(
        // #601 seam: `bypassed` is passed explicitly false today; that slice
        // computes it per entry and this is the one line it edits.
        _FxEntryChip(label: fxBlockName(l10n, effects[i]), bypassed: false),
      );
    }
    return Opacity(
      // A bypassed run reads dimmer, together with the rest of the group.
      opacity: chainEnabled ? 1 : surface.disabledOpacity,
      child: Container(
        key: const Key('tracks_tileFxEntryRun'),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: children,
        ),
      ),
    );
  }
}

/// One entry in the stage-tile chain run — the entry's name in a small neutral
/// pill chip (UI sans), a dark-grey fill with a hairline white border.
///
/// [bypassed] is the #601 seam: when that slice lands it will dim/strike a
/// single bypassed entry here without touching the whole-chain path above.
class _FxEntryChip extends StatelessWidget {
  const _FxEntryChip({required this.label, required this.bypassed});

  final String label;

  final bool bypassed;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: bypassed ? surface.disabledOpacity : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          // Neutral pills over the waveform (the pen): a dark-grey fill with a
          // hairline white border and a near-white label — NOT the FX purple,
          // which belongs to the power pill alone.
          color: surface.control,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: surface.borderSubtle),
        ),
        child: AppText(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: SurfaceTheme.displayFont,
            color: surface.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            decoration: bypassed ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }
}
