import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/backing/cubit/backing_mix_cubit.dart';
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

  /// The backing player and the click.
  players,
}

/// The two players under `Backing & click`, each with its own destinations.
enum RoutingPlayer {
  /// The backing player (#1200).
  backing,

  /// The click.
  click,
}

/// What the Output routing tab draws.
typedef _RoutingValues = ({
  int input,
  int channel,
  int inputCount,
  int outputChannels,
  int deviceBuses,
  int trackCount,
  List<Lane> lanes,
  Map<(int, int), int> laneOutputs,
  int laneCount,
  bool sourceBusy,
});

_RoutingValues _routingValues(
  LooperState state,
  int selectedInput,
  int selectedChannel,
) {
  // A device can narrow under a chosen source. Everything below reads the
  // source the page can actually show, so a control cannot end up editing one
  // jack while the row beside it draws another.
  final present = state.status.isConnected && state.status.devicePresent;
  final inputCount = present ? state.status.inputChannels : 0;
  final input = selectedInput < inputCount ? selectedInput : 0;
  final trackCount = state.tracks.length;
  final channel = selectedChannel < trackCount ? selectedChannel : 0;
  final track = channel < trackCount ? state.tracks[channel] : null;
  return (
    input: input,
    channel: channel,
    inputCount: inputCount,
    outputChannels: present ? state.status.outputChannels : 0,
    deviceBuses: present ? state.outputBusCount : 0,
    trackCount: trackCount,
    lanes: track?.lanes ?? const [],
    laneOutputs: state.laneOutputs,
    laneCount: state.laneCounts[channel] ?? (track?.lanes.length ?? 1),
    // Only Auto reads this, and only to say whether it is live right now.
    sourceBusy: inputBusy(state, input),
  );
}

/// How many destinations to draw: the device's own, plus any this source is
/// already routed to beyond them.
///
/// A session saved on a wider rig can carry a route to a destination this one
/// has not got. Drawing only the device's own would leave that route on with
/// no card to switch it off, and it would outlive every reopen.
int shownBuses(int deviceBuses, int mask) => deviceBuses == 0
    // With no interface open nothing is routable, and a card built from a
    // remembered mask would offer a destination that does not exist.
    ? 0
    : math.max(deviceBuses, (mask.bitLength + 1) ~/ 2);

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
  RoutingPlayer _player = RoutingPlayer.click;

  /// The pen's `source-grid` step, shared with Input setup.
  static const double _cardStep = 280;

  /// The pen's destination step: a 684-wide card and a 24 gap.
  static const double _destinationStep = 708;

  /// The mask the chosen source currently drives.
  int _mask(_RoutingValues values) => switch (_kind) {
    RoutingSourceKind.live =>
      context.watch<MonitorCubit>().state.forInput(values.input).outputMask,
    RoutingSourceKind.tracks => [
      for (var lane = 0; lane < kMaxLanes; lane++)
        if (lane < values.laneCount ||
            values.laneOutputs.containsKey((values.channel, lane)))
          values.laneOutputs[(values.channel, lane)] ??
              (lane < values.lanes.length
                  ? values.lanes[lane].outputMask
                  : const Lane().outputMask),
    ].fold<int>(0, (mask, laneMask) => mask | laneMask),
    RoutingSourceKind.players => switch (_player) {
      RoutingPlayer.backing =>
        context.watch<BackingMixCubit>().state.mix.outputMask,
      RoutingPlayer.click => context.watch<TempoCubit>().state.clickOutputMask,
    },
  };

  /// Sends the chosen source to [mask], through whichever owner holds it.
  void _send(_RoutingValues values, int mask) {
    switch (_kind) {
      case RoutingSourceKind.live:
        unawaited(
          context.read<MonitorCubit>().setOutputMask(values.input, mask),
        );
      case RoutingSourceKind.tracks:
        context.read<LooperBloc>().add(
          LooperTrackOutputChanged(values.channel, mask),
        );
      case RoutingSourceKind.players:
        switch (_player) {
          case RoutingPlayer.backing:
            context.read<BackingMixCubit>().setOutput(mask);
          case RoutingPlayer.click:
            unawaited(context.read<TempoCubit>().setClickOutput(mask));
        }
    }
  }

  /// Adds or removes destination [bus].
  ///
  /// Set only the jacks this device has; clear both, so a route saved on a
  /// wider rig can be switched off here rather than surviving every reopen.
  void _toggleDestination(_RoutingValues values, int bus, int mask) {
    final physical = outputBusMask(bus, channels: values.outputChannels);
    _send(
      values,
      mask & physical != 0 ||
              (bus >= values.deviceBuses && outputMaskDrivesBus(mask, bus))
          ? mask & ~outputBusBits(bus)
          : mask | physical,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final values = context.select<LooperBloc, _RoutingValues>(
      (bloc) => _routingValues(bloc.state, _input, _channel),
    );
    final mask = _mask(values);
    final outputAliases = context.watch<OutputsCubit>().state;
    final status = context.read<LooperBloc>().state.status;
    final names =
        status.isConnected &&
            status.devicePresent &&
            outputAliases.device == status.deviceName
        ? outputAliases.names
        : const <int, String>{};
    // The device's destinations, plus any this source already reaches beyond
    // them, so a route saved on a wider rig has a card to switch it off.
    final buses = shownBuses(values.deviceBuses, mask);
    final physicalMask = (1 << values.outputChannels) - 1;
    final missingFinalJack =
        values.outputChannels.isOdd && mask & (1 << values.outputChannels) != 0;
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
              input: values.input,
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
                    itemCount: buses + (missingFinalJack ? 1 : 0),
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: _destinationStep - 684),
                    itemBuilder: (context, bus) => bus == buses
                        ? RoutingDestinationCard(
                            key: const Key('routing_destination_missing_jack'),
                            jacks: l10n.outputSingleLabel(
                              values.outputChannels + 1,
                            ),
                            name: l10n.outputSingleLabel(
                              values.outputChannels + 1,
                            ),
                            selected: true,
                            available: false,
                            onTap: () => _send(
                              values,
                              mask & ~(1 << values.outputChannels),
                            ),
                          )
                        : RoutingDestinationCard(
                            key: Key('routing_destination_$bus'),
                            jacks: l10n.outputBusLabel(
                              bus,
                              channels: values.outputChannels,
                            ),
                            name: l10n.outputName(
                              names,
                              bus,
                              channels: values.outputChannels,
                            ),
                            selected:
                                mask &
                                        outputBusMask(
                                          bus,
                                          channels: values.outputChannels,
                                        ) !=
                                    0 ||
                                (bus >= values.deviceBuses &&
                                    outputMaskDrivesBus(mask, bus)),
                            available: bus < values.deviceBuses,
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
          // "Reaches nothing" is about the destinations this rig HAS: a mask
          // that only drives jacks the device has not got reaches nothing
          // audible, and saying otherwise would leave a silent source with no
          // explanation.
          child: buses == 0
              ? LoopNote(l10n.routingNoDestinationsYet)
              : mask & physicalMask == 0
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
              context.read<LooperBloc>().state.status.isConnected &&
                      context.read<LooperBloc>().state.status.devicePresent &&
                      context.watch<InputsCubit>().state.device ==
                          context.read<LooperBloc>().state.status.deviceName
                  ? context.watch<InputsCubit>().state.names
                  : const <int, String>{},
              input,
            ),
            selected: input == values.input,
            onTap: () => setState(() => _input = input),
          ),
        ),
      ),
      RoutingSourceKind.tracks => RoutingTrackScope(
        heading: l10n.loopScopeTracks,
        count: values.trackCount,
        selected: values.channel,
        names: trackDisplayNames(context, values.trackCount),
        onSelected: (channel) => setState(() => _channel = channel),
      ),
      // The pen's 21/04: the backing track and the click, each routed on
      // its own.
      RoutingSourceKind.players => Row(
        children: [
          for (final player in RoutingPlayer.values) ...[
            if (player.index > 0) const SizedBox(width: _cardStep - 264),
            RoutingSourceCard(
              key: Key('routing_source_${player.name}'),
              ordinal: null,
              name: switch (player) {
                RoutingPlayer.backing => l10n.routingSourceBacking,
                RoutingPlayer.click => l10n.routingSourceClick,
              },
              selected: player == _player,
              onTap: () => setState(() => _player = player),
            ),
          ],
        ],
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
