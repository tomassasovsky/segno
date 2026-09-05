import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

/// A chromeless row of the active-bank track level meters — the bars-only
/// tracks surface embedded in the on-screen pedal's screen.
///
/// Read-only: it shows the four meters (colour = track state, height = level,
/// white border = the selected track) with no controls, since the pedal
/// supplies every action. Watches the same blocs as the full `TracksView`.
class TrackMeterRow extends StatelessWidget {
  /// Creates a [TrackMeterRow].
  const TrackMeterRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = Theme.of(context).extension<LooperTheme>()!;

    // NOT `context.watch<LooperBloc>()`: `LooperState` carries live audio —
    // per-track `peak` and `transport.masterPositionFrames` — so it changes on
    // every poll tick while audio flows, and watching it here rebuilt the whole
    // row on every tick: one track's level moving rebuilt all of the tiles.
    // This selector holds only the row's structure (which channels exist), so a
    // level tick no longer reaches the row; the tile is subscribed one level
    // down in [_MeterSlot], and the moving level one level below THAT, in
    // [TrackPeakMeter] — the same split #646 applied to `TracksView` (#654).
    final channels = context.select<LooperBloc, _MeterChannels>(
      (bloc) => _MeterChannels.of(bloc.state),
    );
    final names = context.watch<TracksCubit>().state;
    // Mode / cursor / bank are the shared control overlay — this row sits on
    // the pedal's own screen, so it follows exactly what the footswitch sets.
    final overlay = context.watch<ControlCubit>().state;
    final mode = overlay.mode;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final channel in channels.channels)
          if (overlay.bankContains(channel))
            _MeterSlot(
              channel: channel,
              looper: looper,
              mode: mode,
              selected: channel == overlay.cursor,
              name: l10n.displayTrackName(names.nameOf(channel), channel),
            ),
      ],
    );
  }
}

/// The slice of [LooperState] that [TrackMeterRow]'s own layout depends on:
/// which channels exist, nothing else.
///
/// Deliberately excludes everything a moving meter touches — per-track `peak`
/// and `masterPositionFrames`. Those change on every poll tick while audio
/// flows, and including either here would put the whole row back on the
/// rebuild path this class exists to keep it off (#646, #654).
///
/// [channels] is every track's channel, not just the active bank's: the bank
/// filter lives on [ControlCubit], so filtering here would rebuild the row
/// whenever the bank changed for no benefit. It is compared element-wise, so a
/// fresh list of equal channels is still equal.
class _MeterChannels extends Equatable {
  const _MeterChannels({required this.channels});

  factory _MeterChannels.of(LooperState state) => _MeterChannels(
    channels: [for (final track in state.tracks) track.channel],
  );

  final List<int> channels;

  @override
  List<Object?> get props => [channels];
}

/// One [_TrackMeter], subscribed to nothing but its own [channel]'s [Track] —
/// and to that track's STEADY fields only ([Track.steadyProps]).
///
/// Selecting per channel means only track 0's tile can follow track 0
/// (#654); comparing on the steady slice means a moving level does not rebuild
/// even that tile — the level is subscribed one level further down, in the
/// [TrackPeakMeter] leaf, which is the only thing a meter tick redraws.
class _MeterSlot extends StatelessWidget {
  const _MeterSlot({
    required this.channel,
    required this.looper,
    required this.mode,
    required this.selected,
    required this.name,
  });

  final int channel;
  final LooperTheme looper;
  final InteractionMode mode;
  final bool selected;
  final String name;

  @override
  Widget build(BuildContext context) {
    final steady = context.select<LooperBloc, SteadyTrack?>(
      (bloc) => steadyTrackOf(bloc.state, channel),
    );
    final track = steady?.track;
    // Defence only: `channels` is derived from the same `tracks` list, and any
    // change to it changes [_MeterChannels], so the row rebuilds in the same
    // frame and this should be unreachable. Returning a bare SizedBox rather
    // than an Expanded matters if it ever is reached — an empty Expanded would
    // hold its flex share and leave a gap instead of letting the surviving
    // tiles widen.
    if (track == null) return const SizedBox.shrink();
    // The Expanded lives here, not at the call site, so the null case above
    // can opt out of the row's flex entirely.
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: _TrackMeter(
          track: track,
          looper: looper,
          mode: mode,
          selected: selected,
          name: name,
        ),
      ),
    );
  }
}

/// One track's meter tile: a state-coloured [PeakMeterBar] in a rounded panel,
/// its border white while the track is the selected one.
class _TrackMeter extends StatelessWidget {
  const _TrackMeter({
    required this.track,
    required this.looper,
    required this.mode,
    required this.selected,
    required this.name,
  });

  final Track track;
  final LooperTheme looper;
  final InteractionMode mode;
  final bool selected;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meterState = LooperMeterState.of(track.state, muted: track.muted);

    return Container(
      key: Key('pedalScreen_bar_${track.channel}'),
      decoration: BoxDecoration(
        color: looper.tileBackground,
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            '${track.channel + 1}',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: context.surface.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TrackPeakMeter(
              // Live, by channel: [track]'s own `peak` is deliberately not
              // read, so this tile stays off the meter's rebuild path. It
              // does mean the bar shows the RIG's level for the channel, not
              // whatever [track] carries — see `TrackColumn.track`.
              channel: track.channel,
              color: looper.meterColor(meterState, mode: mode),
              hasContent: track.hasContent,
              // A stopped track reports no live peak; hold the last fill so a
              // loaded-but-paused loop keeps a visible bar after a stop.
              frozen: track.state == TrackState.stopped,
            ),
          ),
          const SizedBox(height: 4),
          AppText(
            name,
            key: Key('pedalScreen_name_${track.channel}'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: context.surface.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

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

/// A [Track] compared by its [Track.steadyProps] alone — everything about it
/// EXCEPT the live [Track.peak].
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

  /// The wrapped track. Its `peak` may be a tick stale — by design: whoever
  /// draws the level subscribes to it directly ([TrackPeakMeter]).
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

/// A bottom-anchored level meter driven by the track's current [peak]. Updates
/// with the watched looper state — no own timer.
///
/// When [frozen] (the track is stopped), the bar holds the last live fill
/// instead of collapsing to the stopped track's zero peak, so a loaded-but-
/// paused loop keeps a visible level after a stop.
class PeakMeterBar extends StatefulWidget {
  /// Creates a [PeakMeterBar].
  const PeakMeterBar({
    required this.peak,
    required this.color,
    required this.hasContent,
    required this.frozen,
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

  @override
  State<PeakMeterBar> createState() => _PeakMeterBarState();
}

class _PeakMeterBarState extends State<PeakMeterBar> {
  /// The last fill rendered while the track had a live level, held across the
  /// stopped (frozen) phase. Recomputed every live tick; reset when emptied.
  double _fill = 0;

  @override
  Widget build(BuildContext context) {
    // A track with nothing recorded has no bar; a live track tracks its peak;
    // a frozen (stopped) track keeps the last live fill.
    if (!widget.hasContent) {
      _fill = 0;
    } else if (!widget.frozen) {
      _fill = peakMeterFill(widget.peak);
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: _fill,
        child: Container(color: widget.color),
      ),
    );
  }
}
