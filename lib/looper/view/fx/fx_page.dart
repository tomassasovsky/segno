import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/fx_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/fx/fx_chain_strip.dart';
import 'package:segno/looper/view/fx/fx_effect_editor.dart';
import 'package:segno/looper/view/fx/fx_library_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The Effects route (accepted design, slice 3f): the pen's
/// `01 Effects · destinations`.
///
/// One page for every destination, not one page per stage. The Sound type row
/// picks the strip, the strip picks the source, and the chain underneath is
/// whatever that source carries — which is why a live input, a recorded part,
/// a whole track, All tracks and an output all arrive at the same editor.
class FxPage extends StatelessWidget {
  /// Creates an [FxPage] opened on [initial].
  const FxPage({this.initial, this.catalogue, super.key});

  /// Where the page opens, or the first live input when absent.
  final FxDestination? initial;

  /// The catalogue Add effects offers. Injected so a test and a screenshot
  /// need no asset bundle, and so the app loads it once rather than per open.
  final FxCatalogue? catalogue;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => FxCubit(initial: initial),
    child: FxView(catalogue: catalogue),
  );
}

/// The Effects page's body, with its [FxCubit] already provided.
@visibleForTesting
class FxView extends StatefulWidget {
  /// Creates an [FxView].
  const FxView({this.catalogue, super.key});

  /// The catalogue Add effects offers, or the bundled one when absent.
  final FxCatalogue? catalogue;

  @override
  State<FxView> createState() => _FxViewState();
}

class _FxViewState extends State<FxView> {
  /// One scroll position per KIND, so returning to a strip lands where it was
  /// left. Browsing the chain never changes the selected source, so the two
  /// positions are independent (accepted design, "Input browsing and rack
  /// browsing have independent positions").
  final Map<FxDestinationKind, ScrollController> _chainScroll = {
    for (final kind in FxDestinationKind.values) kind: ScrollController(),
  };

  @override
  void dispose() {
    for (final controller in _chainScroll.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _back() => Navigator.maybePop(context);

  /// Opens [index] of [destination]'s chain in its own editor.
  ///
  /// A route rather than a panel, because the accepted design gives the
  /// editor the whole surface: its controls are direct, which is what the
  /// removed parameter dialog was in the way of.
  void _openEditor(FxDestination destination, int index) {
    final address = destination.address;
    if (address == null) return;
    final label = _destinationLabel(destination);
    final monitor = context.read<MonitorCubit>();
    final bloc = context.read<LooperBloc>();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        // The route is pushed on a navigator ABOVE the page's providers, so
        // the two the editor watches are carried in by value rather than
        // looked up — and carried rather than snapshotted, so an edit made
        // here and an edit made from a pedal land in the same place: the
        // editor renders the rig, it does not hold a copy of it.
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<MonitorCubit>.value(value: monitor),
          ],
          child: Builder(
            builder: (context) {
              final entries = _watchEntriesOf(context, address);
              if (index >= entries.length) return const SizedBox.shrink();
              return FxEffectEditor(
                effect: entries[index],
                destination: destination,
                destinationLabel: label,
                onBack: () => Navigator.maybePop(context),
                edits: _editsFor(bloc, monitor, address, index),
              );
            },
          ),
        ),
      ),
    );
  }

  /// How one entry's editor writes, per stage.
  ///
  /// Each stage keeps its own owner rather than routing through one shared
  /// setter: that is what stops a write meant for a live input landing on a
  /// track's chain.
  static FxEffectEdits _editsFor(
    LooperBloc bloc,
    MonitorCubit monitor,
    FxAddress address,
    int index,
  ) => (
    setEnabled: ({required enabled}) => _DestinationChain._togglePower(
      bloc,
      monitor,
      address,
      index,
      enabled: enabled,
    ),
    setParam: (param, value) {
      switch (address.stage) {
        case FxStage.input:
          monitor.setEffectParam(address.index, index, param, value);
        case FxStage.loop:
          bloc.add(
            LooperLaneEffectParamChanged(
              address.index,
              address.lane ?? 0,
              index,
              param,
              value,
            ),
          );
        case FxStage.track:
        case FxStage.output:
          bloc.add(LooperBusEffectParamChanged(address, index, param, value));
        case FxStage.allTracks:
          bloc.add(LooperAllTracksEffectParamChanged(index, param, value));
      }
    },
    setPlacement: (placement) {
      switch (address.stage) {
        case FxStage.input:
          monitor.setEffectPlacement(address.index, index, placement);
        case FxStage.loop:
          bloc.add(
            LooperLaneEffectPlacementChanged(
              address.index,
              address.lane ?? 0,
              index,
              placement,
            ),
          );
        case FxStage.track:
          bloc.add(
            LooperTrackEffectPlacementChanged(address.index, index, placement),
          );
        case FxStage.allTracks:
        case FxStage.output:
          // Fixed after their own mixes, so the editor never offers the
          // switch here and nothing can reach this.
          break;
      }
    },
    setChannels: (channels) {
      switch (address.stage) {
        case FxStage.input:
          monitor.setEffectChannels(address.index, index, channels);
        case FxStage.loop:
          bloc.add(
            LooperLaneEffectChannelsChanged(
              address.index,
              address.lane ?? 0,
              index,
              channels,
            ),
          );
        case FxStage.track:
        case FxStage.output:
          bloc.add(LooperBusEffectChannelsChanged(address, index, channels));
        case FxStage.allTracks:
          bloc.add(LooperAllTracksEffectChannelsChanged(index, channels));
      }
    },
  );

  /// Opens the library for [destination] and appends what comes back.
  ///
  /// The library resolves to a CHOICE and changes nothing itself: what the
  /// choice does to a chain is this page's business, which is what makes one
  /// Back from a completed addition land on the destination rather than
  /// walking back out through the family and the grid.
  Future<void> _addEffects(FxDestination destination) async {
    final address = destination.address;
    if (address == null) return;
    final entries = _entriesOf(context, address);
    final choice = await Navigator.push<FxLibraryChoice>(
      context,
      MaterialPageRoute(
        builder: (_) => FxLibraryPage(
          catalogue: widget.catalogue ?? FxCatalogue.empty,
          destinationLabel: _destinationLabel(destination),
          freeSlots: kTrackEffectMax - entries.length,
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final added = _entriesFor(choice, destination);
    if (added.isEmpty) return;
    _append(context, address, added);
  }

  /// The entries a choice becomes.
  ///
  /// Every one arrives BYPASSED, whatever the preset's own power keys say:
  /// the accepted design is explicit that a new instance starts bypassed, so
  /// adding a rack mid-set cannot change the sound until the player says so.
  /// The preset's power values are not lost — they ride each entry's own
  /// parameters and come back when the chain is engaged.
  static List<TrackEffect> _entriesFor(
    FxLibraryChoice choice,
    FxDestination destination,
  ) {
    final placement = destination.defaultPlacement;
    return switch (choice) {
      FxSingleChoice(:final type) => [
        BuiltInEffect(type: type, enabled: false, placement: placement),
      ],
      FxRackChoice(:final preset) => [
        for (final module in fxPresetModules(preset))
          fxModuleEntry(module, preset).copyWith(
            enabled: false,
            placement: placement,
          ),
      ],
    };
  }

  /// What the library's header calls the destination.
  String _destinationLabel(FxDestination destination) {
    final l10n = context.l10n;
    return switch (destination.kind) {
      FxDestinationKind.liveInput => l10n.inputName(
        context.read<InputsCubit>().state.names,
        destination.index,
      ),
      FxDestinationKind.recordedTrack when destination.isAllTracks =>
        l10n.fxAllTracks,
      FxDestinationKind.recordedTrack => l10n.trackName(
        context.read<TracksCubit>().state.names,
        destination.index,
      ),
      FxDestinationKind.output => l10n.outputName(
        context.read<OutputsCubit>().state.names,
        destination.index,
        channels: context.read<LooperBloc>().state.status.outputChannels,
      ),
    };
  }

  /// The chain at [address], read once — for a handler, which is outside the
  /// widget tree and so cannot listen.
  List<TrackEffect> _entriesOf(BuildContext context, FxAddress address) =>
      address.stage == FxStage.input
      ? context.read<MonitorCubit>().state.forInput(address.index).effects
      : _DestinationChain._entriesAt(
          context.read<LooperBloc>().state,
          address,
        );

  /// The chain at [address], WATCHED: the editor re-renders when the rig
  /// changes under it, whether the change came from this surface or a pedal.
  static List<TrackEffect> _watchEntriesOf(
    BuildContext context,
    FxAddress address,
  ) => address.stage == FxStage.input
      ? context.watch<MonitorCubit>().state.forInput(address.index).effects
      : _DestinationChain._entriesAt(
          context.watch<LooperBloc>().state,
          address,
        );

  void _append(
    BuildContext context,
    FxAddress address,
    List<TrackEffect> entries,
  ) {
    final bloc = context.read<LooperBloc>();
    switch (address.stage) {
      case FxStage.input:
        context.read<MonitorCubit>().appendEffects(address.index, entries);
      case FxStage.loop:
        bloc.add(
          LooperLaneEffectsAppended(address.index, address.lane ?? 0, entries),
        );
      case FxStage.track:
      case FxStage.output:
        bloc.add(LooperBusEffectsAppended(address, entries));
      case FxStage.allTracks:
        bloc.add(LooperAllTracksEffectsAppended(entries));
    }
  }

  void _stage() => Navigator.popUntil(context, (route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final destination = context.watch<FxCubit>().state.destination;
    // A transparent Material over the whole page: the chain cards and the
    // part picker are ink-splashing controls, and the settings frame is a
    // plain canvas with no Scaffold of its own.
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.loopSettingsCrumb,
        title: l10n.fxTitle,
        onBack: _back,
        onStage: _stage,
        children: [
          Positioned(
            left: 1633,
            top: 32,
            child: LoopOutlinedButton(
              key: const Key('fx_pedal_assignments'),
              width: 251,
              radius: 8,
              label: l10n.fxPedalAssignments,
              onTap: () {},
            ),
          ),
          Positioned(
            left: 36,
            top: 116,
            child: _SoundTypeRow(kind: destination.kind),
          ),
          Positioned(
            left: 36,
            top: 196,
            right: 30,
            height: _stripHeight(destination.kind),
            child: _SourceStrip(destination: destination),
          ),
          Positioned(
            left: 36,
            top: _contextTop(destination.kind),
            right: 36,
            height: 76,
            child: _SoundContext(
              destination: destination,
              onAdd: () => unawaited(_addEffects(destination)),
            ),
          ),
          Positioned(
            left: 32,
            top: _chainTop(destination.kind),
            right: 32,
            bottom: 24,
            child: _DestinationChain(
              destination: destination,
              controller: _chainScroll[destination.kind],
              onOpen: _openEditor,
            ),
          ),
        ],
      ),
    );
  }

  /// The pen gives the recorded-track strip one line and the other two the
  /// taller two-tier cards, so everything under it shifts by the difference.
  static double _stripHeight(FxDestinationKind kind) =>
      kind == FxDestinationKind.recordedTrack ? 64 : 112;

  static double _contextTop(FxDestinationKind kind) =>
      kind == FxDestinationKind.recordedTrack ? 288 : 336;

  static double _chainTop(FxDestinationKind kind) =>
      kind == FxDestinationKind.recordedTrack ? 380 : 428;
}

/// The pen's Sound type row: which strip is showing.
class _SoundTypeRow extends StatelessWidget {
  const _SoundTypeRow({required this.kind});

  final FxDestinationKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<FxCubit>();
    return Row(
      children: [
        for (final (value, label, width)
            in <(FxDestinationKind, String, double)>[
              (FxDestinationKind.liveInput, l10n.fxKindLiveInputs, 165),
              (FxDestinationKind.recordedTrack, l10n.fxKindRecordedTracks, 225),
              (FxDestinationKind.output, l10n.fxKindOutputs, 135),
            ]) ...[
          LoopChoiceButton(
            key: Key('fx_kind_${value.name}'),
            label: label,
            selected: value == kind,
            onTap: () => cubit.showKind(value),
            width: width,
            height: 64,
          ),
          const SizedBox(width: 12),
        ],
      ],
    );
  }
}

/// The strip of sources for the current kind.
class _SourceStrip extends StatelessWidget {
  const _SourceStrip({required this.destination});

  final FxDestination destination;

  @override
  Widget build(BuildContext context) => switch (destination.kind) {
    FxDestinationKind.liveInput => _InputStrip(selected: destination.index),
    FxDestinationKind.recordedTrack => _TrackStrip(
      selected: destination.index,
    ),
    FxDestinationKind.output => _OutputStrip(selected: destination.index),
  };
}

class _InputStrip extends StatelessWidget {
  const _InputStrip({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<FxCubit>();
    final names = context.watch<InputsCubit>().state;
    final count = math.max(
      context.select<LooperBloc, int>((b) => b.state.status.inputChannels),
      1,
    );
    // Eighteen jacks do not fit the pen's four cards, so the row scrolls
    // rather than shrinking them past legibility — the same answer Input
    // setup already gives.
    return ListView.separated(
      key: const Key('fx_input_strip'),
      scrollDirection: Axis.horizontal,
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, input) => RoutingSourceCard(
        key: Key('fx_input_card_$input'),
        ordinal: l10n.routingInputOrdinal(input + 1),
        name: l10n.inputName(names.names, input),
        selected: input == selected,
        onTap: () => cubit.selectSource(input),
      ),
    );
  }
}

class _TrackStrip extends StatelessWidget {
  const _TrackStrip({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<FxCubit>();
    final names = context.watch<TracksCubit>().state.names;
    final count = context.select<LooperBloc, int>(
      (b) => b.state.tracks.length,
    );
    return ListView.separated(
      key: const Key('fx_track_strip'),
      scrollDirection: Axis.horizontal,
      // All tracks sits beside Track 8 in the same strip, not in a kind of
      // its own: it is one more thing the recorded audio can be pointed at.
      itemCount: count + 1,
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemBuilder: (context, i) {
        final isAllTracks = i == count;
        final index = isAllTracks ? FxDestination.allTracksIndex : i;
        return RoutingSourceCard(
          key: Key(isAllTracks ? 'fx_all_tracks' : 'fx_track_card_$i'),
          ordinal: null,
          name: isAllTracks ? l10n.fxAllTracks : l10n.trackName(names, i),
          selected: index == selected,
          width: isAllTracks ? 176 : 197,
          onTap: () => cubit.selectSource(index),
        );
      },
    );
  }
}

class _OutputStrip extends StatelessWidget {
  const _OutputStrip({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<FxCubit>();
    final names = context.watch<OutputsCubit>().state.names;
    final (count, channels) = context.select<LooperBloc, (int, int)>(
      (b) => (b.state.outputBusCount, b.state.status.outputChannels),
    );
    return ListView.separated(
      key: const Key('fx_output_strip'),
      scrollDirection: Axis.horizontal,
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, bus) => RoutingSourceCard(
        key: Key('fx_output_card_$bus'),
        ordinal: l10n.outputBusLabel(bus, channels: channels),
        name: l10n.outputName(names, bus, channels: channels),
        selected: bus == selected,
        onTap: () => cubit.selectSource(bus),
      ),
    );
  }
}

/// The row under the strip: what this destination processes, the part picker
/// or the Hear live control when the destination has one, and the actions.
class _SoundContext extends StatelessWidget {
  const _SoundContext({required this.destination, required this.onAdd});

  final FxDestination destination;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final label = switch (destination.kind) {
      FxDestinationKind.liveInput => l10n.routingHearLive,
      FxDestinationKind.recordedTrack when destination.isAllTracks =>
        l10n.fxAllTracksContext,
      FxDestinationKind.recordedTrack => l10n.fxEffectsOn,
      FxDestinationKind.output => l10n.fxOutputContext,
    };
    return Row(
      children: [
        // Flexible, because the Outputs line is a sentence: it says what an
        // output chain actually processes, and the pen gives it 454px.
        Flexible(
          child: AppText(
            label,
            key: const Key('fx_context_label'),
            maxLines: 2,
            style: TextStyle(color: surface.textSecondary, fontSize: 20),
          ),
        ),
        const SizedBox(width: 20),
        if (destination.kind == FxDestinationKind.liveInput)
          _HearLive(input: destination.index),
        if (destination.kind == FxDestinationKind.recordedTrack &&
            !destination.isAllTracks)
          _PartPicker(destination: destination),
        const Spacer(),
        LoopOutlinedButton(
          key: const Key('fx_add_effects'),
          width: 217,
          radius: 8,
          tone: LoopButtonTone.raised,
          leadingIcon: LucideIcons.plus,
          label: l10n.fxAddEffects,
          onTap: onAdd,
        ),
      ],
    );
  }
}

/// The input's Off / Auto / On monitoring gate, in the row the pen puts it.
class _HearLive extends StatelessWidget {
  const _HearLive({required this.input});

  final int input;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final monitor = context.watch<MonitorCubit>();
    final mode = monitor.state.forInput(input).mode;
    return Row(
      children: [
        for (final (value, label) in <(MonitorMode, String)>[
          (MonitorMode.off, l10n.routingHearOff),
          (MonitorMode.auto, l10n.routingHearAuto),
          (MonitorMode.on, l10n.routingHearOn),
        ]) ...[
          LoopChoiceButton(
            key: Key('fx_hear_${value.name}'),
            label: label,
            selected: value == mode,
            onTap: () => unawaited(monitor.setMode(input, value)),
            width: 88,
            height: 64,
            fontSize: 20,
          ),
          const SizedBox(width: 5),
        ],
      ],
    );
  }
}

/// Which part of the selected track the chain belongs to.
///
/// Offers only the parts this track actually has: processing per recorded
/// input needs separately recorded parts, and offering one that does not
/// exist would point the editor at nothing.
class _PartPicker extends StatelessWidget {
  const _PartPicker({required this.destination});

  final FxDestination destination;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<FxCubit>();
    final names = context.watch<InputsCubit>().state;
    final lanes = context.select<LooperBloc, List<int>>(
      (b) => _recordedLanes(b.state, destination.index),
    );
    final part = destination.part;
    final label = switch (part) {
      FxWholeTrack() => l10n.fxWholeTrack,
      FxRecordedPart(:final lane) => _partName(context, lanes, lane, names),
    };
    return PopupMenuButton<FxTrackPart>(
      key: const Key('fx_part_picker'),
      onSelected: cubit.selectPart,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: FxTrackPart.whole,
          child: AppText(l10n.fxWholeTrack),
        ),
        for (final lane in lanes)
          PopupMenuItem(
            value: FxTrackPart.part(lane),
            child: AppText(_partName(context, lanes, lane, names)),
          ),
      ],
      child: Container(
        width: 240,
        height: 64,
        decoration: BoxDecoration(
          color: surface.card,
          border: Border.all(color: surface.borderSubtle),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AppText(
                  label,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 24,
                    height: 1,
                  ),
                ),
              ),
            ),
            Icon(
              LucideIcons.chevronDown,
              size: 28,
              color: surface.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  /// A part is named by the INPUT it recorded, which is what makes "edit only
  /// the guitar in this take" a thing the player can point at.
  String _partName(
    BuildContext context,
    List<int> lanes,
    int lane,
    InputsState names,
  ) {
    final l10n = context.l10n;
    final input = context
        .read<LooperBloc>()
        .state
        .tracks
        .elementAtOrNull(destination.index)
        ?.lanes
        .elementAtOrNull(lane)
        ?.inputChannel;
    return input == null || input < 0
        ? l10n.fxPartOrdinal(lane + 1)
        : l10n.inputName(names.names, input);
  }
}

/// The lanes of track [channel] that hold recorded audio, in lane order.
List<int> _recordedLanes(LooperState state, int channel) {
  final track = state.tracks.elementAtOrNull(channel);
  if (track == null) return const [];
  return [
    for (var lane = 0; lane < track.lanes.length; lane++)
      if (track.lanes[lane].lengthFrames > 0) lane,
  ];
}

/// The chain at the selected destination.
class _DestinationChain extends StatelessWidget {
  const _DestinationChain({
    required this.destination,
    required this.onOpen,
    this.controller,
  });

  final FxDestination destination;
  final void Function(FxDestination, int) onOpen;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final address = destination.address;
    if (address == null) return const SizedBox.shrink();
    final bloc = context.read<LooperBloc>();
    // A live input's chain is the monitor cubit's, not the projection's: the
    // Input stage is the one chain the engine snapshot does not carry, and
    // that cubit is its single owner (it mints slot ids and recovers plugins
    // on it). Reading it from anywhere else would be a second copy free to
    // drift from the one every other input surface edits.
    final entries = address.stage == FxStage.input
        ? context.watch<MonitorCubit>().state.forInput(address.index).effects
        : context.select<LooperBloc, List<TrackEffect>>(
            (b) => _entriesAt(b.state, address),
          );
    return FxChainStrip(
      key: Key('fx_chain_${address.canonicalString()}'),
      entries: entries,
      controller: controller,
      showPlacement: destination.placementIsEditable,
      onTogglePower: (index, {required enabled}) => _togglePower(
        bloc,
        context.read<MonitorCubit>(),
        address,
        index,
        enabled: enabled,
      ),
      onOpen: (index) => onOpen(destination, index),
    );
  }

  static List<TrackEffect> _entriesAt(LooperState state, FxAddress address) =>
      switch (address.stage) {
        // Handled above, from the monitor cubit.
        FxStage.input => const [],
        FxStage.loop =>
          state.tracks
                  .elementAtOrNull(address.index)
                  ?.lanes
                  .elementAtOrNull(address.lane ?? 0)
                  ?.effects ??
              const [],
        FxStage.track =>
          state.tracks.elementAtOrNull(address.index)?.effects ?? const [],
        FxStage.allTracks => state.allTracksChain.entries,
        FxStage.output => state.outputEffects(address.index),
      };

  static void _togglePower(
    LooperBloc bloc,
    MonitorCubit monitor,
    FxAddress address,
    int index, {
    required bool enabled,
  }) {
    switch (address.stage) {
      case FxStage.input:
        monitor.setEffectEnabled(address.index, index, enabled: enabled);
      case FxStage.loop:
        bloc.add(
          LooperLaneEffectEnabledToggled(
            address.index,
            address.lane ?? 0,
            index,
            enabled: enabled,
          ),
        );
      case FxStage.track:
        bloc.add(
          LooperTrackEffectEnabledToggled(
            address.index,
            index,
            enabled: enabled,
          ),
        );
      case FxStage.allTracks:
        bloc.add(
          LooperAllTracksEffectEnabledToggled(index, enabled: enabled),
        );
      case FxStage.output:
        bloc.add(
          LooperOutputEffectEnabledToggled(
            address.index,
            index,
            enabled: enabled,
          ),
        );
    }
  }
}
