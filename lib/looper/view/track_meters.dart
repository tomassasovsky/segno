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
    // per-track `rms`/`peak`/`playheadFrames` and `transport
    // .masterPositionFrames` — so it changes on every poll tick while audio
    // flows, and watching it here rebuilt the whole row on every tick: one
    // track's level moving rebuilt all of the tiles. This selector holds only
    // the row's structure (which channels exist), so a level tick no longer
    // reaches the row; the live per-track data is subscribed one level down,
    // in [_MeterSlot] — the same split #646 applied to `TracksView` (#654).
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
/// Deliberately excludes everything a moving meter touches — `rms`, `peak`,
/// `playheadFrames`, `masterPositionFrames`. Those change on every poll tick
/// while audio flows, and including any of them here would put the whole row
/// back on the rebuild path this class exists to keep it off (#646, #654).
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

/// One [_TrackMeter], subscribed to nothing but its own [channel]'s [Track].
///
/// This is where the live audio data is allowed back in. Selecting per channel
/// means track 0's meter moving rebuilds track 0's tile and nothing else —
/// where watching [LooperBloc] in [TrackMeterRow] rebuilt every tile in the
/// row on every tick (#654). `Track` is Equatable with the level fields in its
/// props, so the select dedups when this channel's levels are unchanged.
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
    final track = context.select<LooperBloc, Track?>(
      (bloc) => bloc.state.tracks.cast<Track?>().firstWhere(
        (t) => t?.channel == channel,
        orElse: () => null,
      ),
    );
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
            child: PeakMeterBar(
              peak: track.peak,
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
