import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';
import 'package:segno/theme/theme.dart';

/// What the Recording inputs tab draws for the track it is scoped to.
typedef _RecordValues = ({
  List<Lane> lanes,
  int trackCount,
  int inputCount,
  bool locked,
});

_RecordValues _recordValues(LooperState state, int channel) {
  final track = channel < state.tracks.length ? state.tracks[channel] : null;
  return (
    lanes: track?.lanes ?? const [],
    trackCount: state.tracks.length,
    inputCount: state.status.inputChannels,
    // The accepted rule: a track's sources are locked while it is armed or
    // capturing, and only that track's are.
    locked: track != null && (track.pending || track.isCapturing),
  );
}

/// Recording inputs (accepted design, Audio routing): pick a track, then the
/// jacks it records. Choices affect future captures; they never reinterpret
/// which inputs an existing recording holds.
class RecordingInputsTab extends StatefulWidget {
  /// Creates a [RecordingInputsTab].
  const RecordingInputsTab({super.key});

  @override
  State<RecordingInputsTab> createState() => _RecordingInputsTabState();
}

class _RecordingInputsTabState extends State<RecordingInputsTab> {
  int _channel = 0;

  /// The pen's `routing-record` card grid.
  static const double _cardWidth = 360;
  static const double _cardStep = 378;

  /// Records [input] on this track, or frees the lane that already does.
  ///
  /// A freed lane is left in place: compacting would renumber the lanes and
  /// move a recorded take onto another source.
  void _toggle(List<Lane> lanes, int input) {
    final bloc = context.read<LooperBloc>();
    final existing = lanes.indexWhere((lane) => lane.inputChannel == input);
    if (existing >= 0) {
      bloc.add(LooperLaneInputChanged(_channel, existing, -1));
      return;
    }
    final freed = lanes.indexWhere((lane) => lane.inputChannel < 0);
    if (freed >= 0) {
      bloc.add(LooperLaneInputChanged(_channel, freed, input));
      return;
    }
    // The engine caps a track at [kMaxLanes] and refuses both writes past it,
    // while a device may report more inputs than that — so stop rather than
    // dispatch a lane index the engine can never have and the restart would
    // replay for ever.
    if (lanes.length >= kMaxLanes) return;
    bloc
      ..add(LooperLaneCountChanged(_channel, lanes.length + 1))
      ..add(LooperLaneInputChanged(_channel, lanes.length, input));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _RecordValues>(
      (bloc) => _recordValues(bloc.state, _channel),
    );
    final names = context.watch<InputsCubit>().state;
    final trackNames = trackDisplayNames(context, values.trackCount);
    final recorded = {
      for (final lane in values.lanes)
        if (lane.inputChannel >= 0) lane.inputChannel,
    };

    return Stack(
      children: [
        Positioned(
          left: 100,
          top: 257,
          child: RoutingTrackScope(
            heading: l10n.loopScopeTracks,
            count: values.trackCount,
            selected: _channel,
            names: trackNames,
            onSelected: (channel) => setState(() => _channel = channel),
          ),
        ),
        Positioned(
          left: 100,
          top: 377,
          child: LoopSectionLabel(l10n.routingRecordFrom),
        ),
        Positioned(
          left: 100,
          top: 433,
          child: SizedBox(
            width: 1720,
            height: 180,
            // More jacks than the pen's four cards scroll rather than shrink.
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: math.max(values.inputCount, 0),
              separatorBuilder: (_, _) =>
                  const SizedBox(width: _cardStep - _cardWidth),
              itemBuilder: (context, index) => _InputChoiceCard(
                key: Key('routing_record_card_$index'),
                ordinal: '${index + 1}',
                name: l10n.inputName(names.names, index),
                selected: recorded.contains(index),
                enabled: !values.locked,
                onTap: () => _toggle(values.lanes, index),
              ),
            ),
          ),
        ),
        Positioned(
          left: 100,
          top: 645,
          child: values.locked
              ? LoopLockBanner(
                  text: l10n.routingLockedInputs,
                  width: 1720,
                )
              : recorded.isEmpty
              ? LoopNote(l10n.routingNoInputs)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// The pen's `routing-input` card: the jack's number and name with a check
/// badge that says whether this track records it.
class _InputChoiceCard extends StatelessWidget {
  const _InputChoiceCard({
    required this.ordinal,
    required this.name,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final String ordinal;
  final String name;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: enabled ? 1 : surface.disabledOpacity,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        label: name,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: Container(
            width: _RecordingInputsTabState._cardWidth,
            height: 180,
            padding: const EdgeInsets.all(25),
            decoration: BoxDecoration(
              color: selected ? surface.accentSurface : surface.card,
              border: Border.all(
                color: selected ? surface.borderStrong : surface.borderSubtle,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      ordinal,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 36,
                        height: 1,
                      ),
                    ),
                    const Spacer(),
                    RoutingCheck(selected: selected),
                  ],
                ),
                const Spacer(),
                SizedBox(
                  width: 310,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      name,
                      style: TextStyle(
                        color: selected
                            ? surface.textPrimary
                            : surface.textSecondary,
                        fontSize: 26,
                        height: 1,
                      ),
                    ),
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
