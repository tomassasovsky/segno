import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/routing_facts.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';

/// The kinds of thing that can be sent somewhere.
///
/// Each kind carries its OWN destination choice, per the accepted design: a
/// recording-only track route never implicitly becomes a live input route.
enum RoutingSourceKind {
  /// What the jacks are hearing right now.
  live,

  /// What the tracks play back.
  tracks,

  /// The click, and the backing player when there is one.
  players,
}

/// What the Output routing tab draws.
typedef _RoutingValues = ({
  int inputCount,
  int outputChannels,
  int busCount,
  int trackCount,
  List<Lane> lanes,
  bool sourceBusy,
});

_RoutingValues _routingValues(LooperState state, int input, int channel) {
  final track = channel < state.tracks.length ? state.tracks[channel] : null;
  return (
    inputCount: state.status.inputChannels,
    outputChannels: state.status.outputChannels,
    busCount: state.outputBusCount,
    trackCount: state.tracks.length,
    lanes: track?.lanes ?? const [],
    // Only Auto reads this, and only to say whether it is live right now.
    sourceBusy: inputBusy(state, input),
  );
}

/// Output routing (accepted design, Audio routing): pick a source, then the
/// destinations it reaches. Choosing a destination never starts playback and
/// never opens monitoring.
class OutputRoutingTab extends StatefulWidget {
  /// Creates an [OutputRoutingTab].
  const OutputRoutingTab({super.key});

  @override
  State<OutputRoutingTab> createState() => _OutputRoutingTabState();
}

class _OutputRoutingTabState extends State<OutputRoutingTab> {
  RoutingSourceKind _kind = RoutingSourceKind.live;
  int _input = 0;
  int _channel = 0;

  /// The pen's `source-grid` step, shared with Input setup.
  static const double _cardStep = 280;

  /// The pen's destination step: a 684-wide card and a 24 gap.
  static const double _destinationStep = 708;

  /// The mask the chosen source currently drives.
  int _mask(_RoutingValues values) => switch (_kind) {
    RoutingSourceKind.live =>
      context.watch<MonitorCubit>().state.forInput(_input).outputMask,
    // A track's route is track-wide, so lane 0 speaks for the track. Lanes
    // can only disagree by way of a session saved before this surface owned
    // the route, and writing every lane is what puts them back in step.
    RoutingSourceKind.tracks =>
      values.lanes.isEmpty
          ? const Lane().outputMask
          : values.lanes.first.outputMask,
    RoutingSourceKind.players =>
      context.watch<TempoCubit>().state.clickOutputMask,
  };

  /// Sends the chosen source to [mask], through whichever owner holds it.
  void _send(_RoutingValues values, int mask) {
    switch (_kind) {
      case RoutingSourceKind.live:
        unawaited(context.read<MonitorCubit>().setOutputMask(_input, mask));
      case RoutingSourceKind.tracks:
        final bloc = context.read<LooperBloc>();
        // Every lane, because the choice is the TRACK's. A track with no lanes
        // yet still has lane 0 — the engine gives it one whether or not the
        // projection has reported it.
        final lanes = values.lanes.isEmpty ? 1 : values.lanes.length;
        for (var lane = 0; lane < lanes; lane++) {
          bloc.add(LooperLaneOutputChanged(_channel, lane, mask));
        }
      case RoutingSourceKind.players:
        unawaited(context.read<TempoCubit>().setClickOutput(mask));
    }
  }

  /// Adds or removes destination [bus].
  void _toggleDestination(_RoutingValues values, int bus, int mask) {
    final bits = outputBusMask(bus, channels: values.outputChannels);
    _send(values, outputMaskDrivesBus(mask, bus) ? mask & ~bits : mask | bits);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _RoutingValues>(
      (bloc) => _routingValues(bloc.state, _input, _channel),
    );
    final mask = _mask(values);
    // Live inputs carry Hear live above Send to; the other kinds have only
    // Send to, so their row moves up to where it would have been.
    final live = _kind == RoutingSourceKind.live;
    final sendTop = live ? 665.0 : 497.0;

    return Stack(
      children: [
        Positioned(
          left: 100,
          top: 257,
          child: _SourceKinds(
            selected: _kind,
            onSelected: (kind) => setState(() => _kind = kind),
          ),
        ),
        Positioned(
          left: 100,
          top: _kind == RoutingSourceKind.tracks ? 353 : 359,
          child: _sources(values),
        ),
        if (live)
          Positioned(
            left: 100,
            top: 545,
            child: _HearLive(
              input: _input,
              busy: values.sourceBusy,
            ),
          ),
        Positioned(
          left: 100,
          top: sendTop,
          child: SizedBox(
            width: 1720,
            height: 144,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 56,
                  child: LoopSectionLabel(l10n.routingSendTo),
                ),
                Positioned(
                  left: 328,
                  top: 0,
                  width: 1392,
                  height: 144,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: values.busCount,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: _destinationStep - 684),
                    itemBuilder: (context, bus) => RoutingDestinationCard(
                      key: Key('routing_destination_$bus'),
                      jacks: l10n.outputBusLabel(
                        bus,
                        channels: values.outputChannels,
                      ),
                      name: l10n.outputName(
                        context.watch<OutputsCubit>().state.names,
                        bus,
                        channels: values.outputChannels,
                      ),
                      selected: outputMaskDrivesBus(mask, bus),
                      onTap: () => _toggleDestination(values, bus, mask),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 428,
          top: sendTop + 168,
          child: values.busCount == 0
              ? LoopNote(l10n.routingNoDestinationsYet)
              : mask == 0
              ? LoopNote(l10n.routingNoDestinations)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// The sources of the chosen kind.
  Widget _sources(_RoutingValues values) {
    final l10n = context.l10n;
    return switch (_kind) {
      RoutingSourceKind.live => SizedBox(
        width: 1720,
        height: 112,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: values.inputCount,
          separatorBuilder: (_, _) => const SizedBox(width: _cardStep - 264),
          itemBuilder: (context, input) => RoutingSourceCard(
            key: Key('routing_source_input_$input'),
            ordinal: l10n.routingInputOrdinal(input + 1),
            name: l10n.inputName(
              context.watch<InputsCubit>().state.names,
              input,
            ),
            selected: input == _input,
            onTap: () => setState(() => _input = input),
          ),
        ),
      ),
      RoutingSourceKind.tracks => RoutingTrackScope(
        heading: l10n.loopScopeTracks,
        count: values.trackCount,
        selected: _channel,
        names: trackDisplayNames(context, values.trackCount),
        onSelected: (channel) => setState(() => _channel = channel),
      ),
      // The click is the only player this console has. The accepted design's
      // backing track has no engine, repository or bloc seam yet; a card for
      // it would be a control that routes nothing.
      RoutingSourceKind.players => RoutingSourceCard(
        key: const Key('routing_source_click'),
        ordinal: null,
        name: l10n.routingSourceClick,
        selected: true,
        onTap: () {},
      ),
    };
  }
}

/// The pen's `Audio sources` row: which kind of thing is being routed.
class _SourceKinds extends StatelessWidget {
  const _SourceKinds({required this.selected, required this.onSelected});

  final RoutingSourceKind selected;
  final ValueChanged<RoutingSourceKind> onSelected;

  /// The pen's pill widths, in [RoutingSourceKind] order.
  static const List<double> _widths = [165, 225, 211];

  /// The pen's pill lefts, in the same order.
  static const List<double> _lefts = [0, 177, 414];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1720,
      height: 64,
      child: Stack(
        children: [
          for (final kind in RoutingSourceKind.values)
            Positioned(
              left: _lefts[kind.index],
              top: 0,
              child: LoopChoiceButton(
                key: Key('routing_kind_${kind.name}'),
                label: switch (kind) {
                  RoutingSourceKind.live => l10n.routingKindLive,
                  RoutingSourceKind.tracks => l10n.routingKindTracks,
                  RoutingSourceKind.players => l10n.routingKindPlayers,
                },
                selected: kind == selected,
                onTap: () => onSelected(kind),
                width: _widths[kind.index],
                height: 64,
                fontSize: 22,
              ),
            ),
        ],
      ),
    );
  }
}

/// The pen's `Hear live` row: whether a jack is heard now, never, or whenever
/// a track that records it is armed.
class _HearLive extends StatelessWidget {
  const _HearLive({required this.input, required this.busy});

  final int input;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final monitor = context.watch<MonitorCubit>().state.forInput(input);
    return SizedBox(
      width: 1720,
      height: 74,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 21,
            child: LoopSectionLabel(l10n.routingHearLive),
          ),
          Positioned(
            left: 328,
            top: 0,
            child: LoopChoiceRow<MonitorMode>(
              values: MonitorMode.values,
              labelOf: (mode) => switch (mode) {
                MonitorMode.off => l10n.routingHearOff,
                MonitorMode.auto => l10n.routingHearAuto,
                MonitorMode.on => l10n.routingHearOn,
              },
              keyOf: (mode) => Key('routing_monitor_${mode.name}'),
              selected: monitor.mode,
              onSelected: (mode) =>
                  unawaited(context.read<MonitorCubit>().setMode(input, mode)),
              width: 284,
              height: 74,
              gap: 5,
              fontSize: 22,
            ),
          ),
          Positioned(
            left: 640,
            top: 22,
            child: switch (monitor) {
              // Muting the input in Mixer keeps it silent whatever this row
              // says, so this row says so rather than looking switched on.
              final it when it.muted => LoopNote(l10n.routingHearMuted),
              final it when it.mode == MonitorMode.auto => LoopNote(
                busy ? l10n.routingHearAutoOn : l10n.routingHearAutoOff,
              ),
              _ => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }
}
