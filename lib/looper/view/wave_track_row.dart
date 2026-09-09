import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/track_column.dart'
    show PrimaryCrown, ShrinkToWidth;
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';

/// One row of the Wave view: the track's number, crown and name with its
/// bar/layer/FX facts at the leading edge, and the track's own recorded
/// waveform — a continuous sample-derived shape with the bar ruler under it
/// and the playhead over it — filling the rest. An empty track shows the
/// bare baseline, never a borrowed shape.
///
/// The row is a tap target with the same by-mode action as a Track column's
/// meter, and the selection outline is the same white ring.
class WaveTrackRow extends StatelessWidget {
  /// Creates a [WaveTrackRow].
  const WaveTrackRow({
    required this.track,
    required this.name,
    required this.selected,
    required this.mode,
    this.isPrimary = false,
    this.bars,
    super.key,
  });

  /// The track this row renders. A live view, like `TrackColumn.track`.
  final Track track;

  /// The track's resolved display name.
  final String name;

  /// Whether this row is selected.
  final bool selected;

  /// The active system mode.
  final InteractionMode mode;

  /// Whether [track] wears the primary crown.
  final bool isPrimary;

  /// The track's length in bars, or `null` when nothing counts them.
  final int? bars;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = Theme.of(context).extension<LooperTheme>()!;
    final surface = context.surface;
    final bloc = context.read<LooperBloc>();
    final meterState = LooperMeterState.of(track.state, muted: track.muted);
    final stateWord = switch (meterState) {
      LooperMeterState.empty => l10n.trackStateEmpty,
      LooperMeterState.recording => l10n.trackStateRecording,
      LooperMeterState.overdubbing => l10n.trackStateOverdubbing,
      LooperMeterState.playing => l10n.trackStatePlaying,
      LooperMeterState.stopped => l10n.trackStateStopped,
      LooperMeterState.muted => l10n.trackStateMuted,
    };
    final layers = track.layers;
    final barsCount = bars;
    final meta = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textPrimary,
      fontSize: 22,
      height: 1,
    );
    final unit = TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      color: surface.textTertiary,
      fontSize: 16,
      height: 1,
    );
    return FocusableTapTarget(
      key: Key('wave_row_${track.channel}'),
      semanticLabel: switch (mode) {
        InteractionMode.record => l10n.a11yTrackTile(name, stateWord),
        InteractionMode.mute => l10n.a11yTrackTileMute(name, stateWord),
        InteractionMode.fx =>
          track.chainEnabled
              ? l10n.a11yTrackTileFxOn(name, stateWord)
              : l10n.a11yTrackTileFxOff(name, stateWord),
      },
      selected: selected,
      borderRadius: 17,
      onTap: () {
        context.read<ControlCubit>().selectTrack(track.channel);
        switch (mode) {
          case InteractionMode.record:
            bloc.add(LooperRecordPressed(track.channel));
          case InteractionMode.mute:
            bloc.add(LooperMuteToggled(track.channel));
          case InteractionMode.fx:
            TracksCommands(context).announceFxChainToggle(track.channel);
            bloc.add(LooperTrackChainToggled(track.channel));
        }
      },
      onLongPress: () => bloc.add(LooperStopPressed(track.channel)),
      child: Container(
        decoration: BoxDecoration(
          color: looper.tileBackground,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: selected ? surface.onAccent : looper.tileBorder,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              SizedBox(
                // The pen's 360 info block; a narrower desktop window gives it
                // a third of the row instead.
                width: constraints.maxWidth.isFinite
                    ? (constraints.maxWidth * 0.3).clamp(0.0, 360.0)
                    : 360,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 40,
                      child: AppText(
                        '${track.channel + 1}',
                        style: TextStyle(
                          fontFamily: SurfaceTheme.displayFont,
                          color: surface.textTertiary,
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isPrimary) ...[
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: PrimaryCrown(
                                    key: Key('wave_crown_${track.channel}'),
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(width: 10),
                              ],
                              Flexible(
                                child: AppText(
                                  name,
                                  key: Key('wave_name_${track.channel}'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: SurfaceTheme.displayFont,
                                    color: surface.textPrimary,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Semantics(
                            label: l10n.a11yStageTrackMeta(
                              track.channel + 1,
                              barsCount == null
                                  ? l10n.stageNoBarsFigure
                                  : l10n.stageBarsFigure(barsCount),
                              l10n.stageLayersFigure(layers),
                            ),
                            child: ExcludeSemantics(
                              child: ShrinkToWidth(
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    AppText(
                                      barsCount == null
                                          ? l10n.stageNoBars
                                          : '$barsCount',
                                      style: meta,
                                    ),
                                    const SizedBox(width: 5),
                                    AppText(
                                      l10n.stageBarsUnit(barsCount ?? 0),
                                      style: unit,
                                    ),
                                    const SizedBox(width: 24),
                                    AppText('$layers', style: meta),
                                    const SizedBox(width: 5),
                                    AppText(
                                      l10n.stageLayersUnit(layers),
                                      style: unit,
                                    ),
                                    if (track.effects.isNotEmpty)
                                      AppText(
                                        l10n.stageFxMarker,
                                        key: Key('wave_fx_${track.channel}'),
                                        style: TextStyle(
                                          fontFamily: SurfaceTheme.displayFont,
                                          color: track.chainEnabled
                                              ? surface.textPrimary
                                              : surface.textMuted,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1,
                                          height: 1,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                color: surface.line,
              ),
              Expanded(
                child: TrackWaveform(
                  channel: track.channel,
                  state: meterState,
                  contentKey: WaveformKey.of(track),
                  bars: barsCount ?? 0,
                  semanticLabel: l10n.a11ySelectedTrackWaveform(name),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One track's own recorded waveform with its playhead — the leaf that
/// follows the moving position, like `TrackPeakMeter` follows the level.
///
/// The peaks are read from the repository on each rebuild: the loop-indexed
/// buffer stands still through playback, so the copy is cheap, and it changes
/// exactly when the playhead does during a take.
class TrackWaveform extends StatefulWidget {
  /// Creates a [TrackWaveform].
  const TrackWaveform({
    required this.channel,
    required this.state,
    required this.contentKey,
    this.bars = 0,
    this.semanticLabel,
    super.key,
  });

  /// The channel whose waveform and playhead this follows.
  final int channel;

  /// The state the stroke colour speaks for.
  final LooperMeterState state;

  /// The facts the track's recorded shape is a function of: the waveform is
  /// re-read from the engine when these change, or on every rebuild while a
  /// take or a pass is being captured — never on a mere playhead tick.
  final WaveformKey contentKey;

  /// Whole bars across the loop, for the ruler.
  final int bars;

  /// Accessible name, see [WaveformView.semanticLabel].
  final String? semanticLabel;

  @override
  State<TrackWaveform> createState() => _TrackWaveformState();
}

class _TrackWaveformState extends State<TrackWaveform> {
  WaveformKey? _readUnder;
  Float32List _samples = Float32List(0);

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.contentKey.hasContent;
    final progress = context.select<LooperBloc, double>(
      (bloc) => progressOf(bloc.state, widget.channel),
    );
    // The playhead moves this widget every poll while the track plays; the
    // shape behind it only changes when the content does, so the copy across
    // the engine boundary is taken once per content change (or per block
    // while capturing, when the buffer grows under the reader).
    final key = widget.contentKey;
    if (!hasContent) {
      _readUnder = null;
      _samples = Float32List(0);
    } else if (key.capturing || key != _readUnder) {
      _samples = context.read<LooperRepository>().readTrackWaveform(
        widget.channel,
      );
      _readUnder = key;
    }
    return WaveformView(
      key: Key('wave_waveform_${widget.channel}'),
      samples: _samples,
      state: widget.state,
      progress: hasContent ? progress : 0,
      bars: hasContent ? widget.bars : 0,
      semanticLabel: widget.semanticLabel,
    );
  }
}

/// The steady facts a track's recorded waveform is a function of.
///
/// Two equal keys mean the engine's peak buffer for the track has the same
/// shape, so a cached read stands — except while [capturing], when the buffer
/// grows under the reader every block and must be re-read each frame. A
/// playhead tick, a level tick, a mute or a volume change move none of these.
class WaveformKey extends Equatable {
  /// Creates a [WaveformKey].
  const WaveformKey({
    required this.channel,
    required this.state,
    required this.lengthFrames,
    required this.undoDepth,
    required this.redoDepth,
    required this.clearRestore,
  });

  /// [track]'s key.
  factory WaveformKey.of(Track track) => WaveformKey(
    channel: track.channel,
    state: track.state,
    lengthFrames: track.lengthFrames,
    undoDepth: track.undoDepth,
    redoDepth: track.redoDepth,
    clearRestore: track.clearRestore,
  );

  /// The track's channel.
  final int channel;

  /// The track's transport state.
  final TrackState state;

  /// Recorded length: a finalize, a clear or a length change moves it.
  final int lengthFrames;

  /// Retired passes: an overdub finalize or an undo moves it.
  final int undoDepth;

  /// Undone passes: an undo or a redo moves it.
  final int redoDepth;

  /// Whether a cleared take is held for restore.
  final bool clearRestore;

  /// Whether the track holds recorded audio.
  bool get hasContent => lengthFrames > 0;

  /// Whether the engine is writing into the track right now, so the shape
  /// changes every block.
  bool get capturing =>
      state == TrackState.recording || state == TrackState.overdubbing;

  @override
  List<Object?> get props => [
    channel,
    state,
    lengthFrames,
    undoDepth,
    redoDepth,
    clearRestore,
  ];
}
