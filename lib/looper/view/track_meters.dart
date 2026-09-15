import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/theme/theme.dart';

/// One track's [PeakMeterBar], following [channel]'s live [Track.peak].
///
/// The leaf of the rebuild split (#646/#654/#832): every tile above it compares
/// on [Track.steadyProps], which excludes `peak`, so the only thing a meter
/// tick rebuilds is this bar. Everything else the bar needs — its colour,
/// whether the track has content, whether it is frozen — is derived from steady
/// fields and passed in by the tile, which is why this leaf can take the
/// channel and read the one moving number itself.
///
/// The level is therefore the RIG's, always: it is read here so it can reach
/// the bar without rebuilding the ~250 lines of tile around it. That makes
/// every surface built out of these tiles a live view of the ambient
/// [LooperBloc] rather than a function of the [Track] handed in — see
/// `TrackColumn.track`.
class TrackPeakMeter extends StatelessWidget {
  /// Creates a [TrackPeakMeter].
  const TrackPeakMeter({
    required this.channel,
    required this.color,
    required this.hasContent,
    required this.frozen,
    this.clipColor,
    super.key,
  });

  /// The channel whose level this bar follows.
  final int channel;

  /// The bar fill colour (the track's meter-state colour).
  final Color color;

  /// Whether the track holds recorded audio (an empty track shows no bar).
  final bool hasContent;

  /// Whether the track is stopped, so the last live fill is held.
  final bool frozen;

  /// The clip cap's colour; `null` draws no cap. See [PeakMeterBar.clipColor].
  final Color? clipColor;

  @override
  Widget build(BuildContext context) {
    final peak = context.select<LooperBloc, double>(
      (bloc) => peakOf(bloc.state, channel),
    );
    return PeakMeterBar(
      peak: peak,
      color: color,
      hasContent: hasContent,
      frozen: frozen,
      clipColor: clipColor,
    );
  }
}

/// One track's thin bottom progress bar, following [channel]'s own playhead
/// ([Track.positionFrames] over its length) — the second moving value a
/// playing track publishes, subscribed in its own leaf for the same reason
/// [TrackPeakMeter] subscribes to the level: a playhead tick redraws six
/// pixels, not the tile.
class TrackProgressBar extends StatelessWidget {
  /// Creates a [TrackProgressBar].
  const TrackProgressBar({
    required this.channel,
    required this.color,
    super.key,
  });

  /// The channel whose playhead this bar follows.
  final int channel;

  /// The fill colour (the track's meter-state colour).
  final Color color;

  /// The bar's height — the pen's 6.
  static const double height = 6;

  @override
  Widget build(BuildContext context) {
    final progress = context.select<LooperBloc, double>(
      (bloc) => progressOf(bloc.state, channel),
    );
    final looper = Theme.of(context).extension<LooperTheme>()!;
    return Semantics(
      label: '${(progress * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: ColoredBox(
          color: looper.tileBorder,
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [channel]'s current peak level, or `0` when [state] has no such channel.
///
/// Silence, not an exception — and not because losing a channel is harmless,
/// but because this runs at the wrong moment to react to it. A selector is
/// evaluated when the bloc EMITS, before anything rebuilds, so a state that
/// has dropped [channel] reaches this function on its way to the frame that
/// unmounts the whole tile: the tile's own selector ([SteadyTrack]) has gone
/// null, and the slot above it returns a `SizedBox` in the same frame. The
/// value computed here is never drawn, so throwing would only turn an
/// already-handled case into a crash.
double peakOf(LooperState state, int channel) {
  for (final track in state.tracks) {
    if (track.channel == channel) return track.peak;
  }
  return 0;
}

/// [channel]'s normalized play position, or `0` when [state] has no such
/// channel — the same emit-time tolerance as [peakOf].
double progressOf(LooperState state, int channel) {
  for (final track in state.tracks) {
    if (track.channel == channel) return track.progress;
  }
  return 0;
}

/// A [Track] compared by its [Track.steadyProps] alone — everything about it
/// EXCEPT the live [Track.peak] and [Track.positionFrames].
///
/// What a track tile selects. `Track`'s own equality includes `peak`, so
/// selecting the track itself puts the tile back on the meter's rebuild path —
/// exactly the leak that made #646/#654/#832 stop short: the tiles were
/// subscribed per channel, but every one of them still rebuilt on every poll
/// tick. Wrapping rather than restating the field list means a field added to
/// `Track` is compared here automatically.
class SteadyTrack extends Equatable {
  /// Wraps [track] for a peak-insensitive comparison.
  const SteadyTrack(this.track);

  /// The wrapped track. Its `peak` and `positionFrames` may be a tick stale —
  /// by design: whoever draws the level or the playhead subscribes to it
  /// directly ([TrackPeakMeter], [TrackProgressBar]).
  final Track track;

  @override
  List<Object?> get props => track.steadyProps;
}

/// [channel]'s track as a [SteadyTrack], or `null` when the rig no longer
/// has it.
SteadyTrack? steadyTrackOf(LooperState state, int channel) {
  for (final track in state.tracks) {
    if (track.channel == channel) return SteadyTrack(track);
  }
  return null;
}

/// A peak at or above this reads as clipping — the engine's level is the
/// absolute sample peak, so full scale is 1.0.
const double kClipPeak = 0.999;

/// A bottom-anchored level meter driven by the track's current [peak]. Updates
/// with the watched looper state — no own timer.
///
/// When [frozen] (the track is stopped), the bar holds the last live fill
/// instead of collapsing to the stopped track's zero peak, so a loaded-but-
/// paused loop keeps a visible level after a stop.
///
/// A [clipColor] adds the accepted stage's clip cap: a thin bar across the
/// top of the meter while a peak at full scale ([kClipPeak]) was seen within
/// the last [clipHold], so a single hot block stays visible for as long as a
/// glance takes. The hold is evaluated on each level tick rather than by a
/// timer of its own — a stopped (frozen) track never shows it, since a stale
/// cap on a silent track would be a lie.
class PeakMeterBar extends StatefulWidget {
  /// Creates a [PeakMeterBar].
  const PeakMeterBar({
    required this.peak,
    required this.color,
    required this.hasContent,
    required this.frozen,
    this.clipColor,
    super.key,
  });

  /// The track's current peak level (`0..1`).
  final double peak;

  /// The bar fill colour (the track's meter-state colour).
  final Color color;

  /// Whether the track holds recorded audio (an empty track shows no bar).
  final bool hasContent;

  /// Whether the track is stopped, so the last live fill is held.
  final bool frozen;

  /// The clip cap's colour; `null` draws no cap.
  final Color? clipColor;

  /// How long a clip stays visible after the last full-scale peak.
  static const Duration clipHold = Duration(milliseconds: 1500);

  /// The cap's height — the pen's 4.
  static const double clipCapHeight = 4;

  @override
  State<PeakMeterBar> createState() => _PeakMeterBarState();
}

class _PeakMeterBarState extends State<PeakMeterBar> {
  /// The last fill rendered while the track had a live level, held across the
  /// stopped (frozen) phase. Recomputed every live tick; reset when emptied.
  double _fill = 0;

  /// Live while the clip cap shows: armed by a full-scale peak, retiring the
  /// cap after [PeakMeterBar.clipHold] — a timer, not a wall-clock compare in
  /// [build], because a track that goes quiet after one hot block stops
  /// rebuilding this bar, and a cap that only retires on the next rebuild
  /// would then stay up for good.
  Timer? _clipTimer;

  @override
  void dispose() {
    _clipTimer?.cancel();
    super.dispose();
  }

  void _holdClip() {
    _clipTimer?.cancel();
    _clipTimer = Timer(PeakMeterBar.clipHold, () {
      if (mounted) setState(() => _clipTimer = null);
    });
  }

  void _dropClip() {
    _clipTimer?.cancel();
    _clipTimer = null;
  }

  @override
  void initState() {
    super.initState();
    _observe();
  }

  @override
  void didUpdateWidget(PeakMeterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _observe();
  }

  /// Reads the tick this widget carries. On a new WIDGET, not in [build]:
  /// the retire timer's own rebuild must not re-read a stale full-scale peak
  /// and hold the cap up again.
  void _observe() {
    // A track with nothing recorded has no bar; a live track tracks its peak;
    // a frozen (stopped) track keeps the last live fill.
    if (!widget.hasContent) {
      _fill = 0;
      _dropClip();
    } else if (!widget.frozen) {
      _fill = peakMeterFill(widget.peak);
      if (widget.peak >= kClipPeak) _holdClip();
    }
  }

  @override
  Widget build(BuildContext context) {
    final clipping =
        widget.clipColor != null &&
        widget.hasContent &&
        !widget.frozen &&
        _clipTimer != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: _fill,
            child: Container(color: widget.color),
          ),
        ),
        if (clipping)
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              key: const Key('meter_clip_cap'),
              height: PeakMeterBar.clipCapHeight,
              color: widget.clipColor,
            ),
          ),
      ],
    );
  }
}
