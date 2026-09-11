import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/fx_cubit.dart';
import 'package:segno/looper/cubit/fx_presets_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/fx/fx_chain_strip.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/fx/fx_effect_editor.dart';
import 'package:segno/looper/view/fx/fx_library_page.dart';
import 'package:segno/looper/view/fx/fx_options_sheet.dart';
import 'package:segno/looper/view/fx/fx_rack_editor.dart';
import 'package:segno/looper/view/fx/fx_reorder_page.dart';
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

  /// Opens group [group] of [destination]'s chain in its own editor.
  ///
  /// A route rather than a panel, because the accepted design gives the
  /// editor the whole surface: its controls are direct, which is what the
  /// removed parameter dialog was in the way of.
  ///
  /// The group is re-found by IDENTITY on every rebuild rather than held by
  /// index: a reorder or a removal made while this editor is open changes what
  /// index the rack sits at, and an editor keyed by index would silently start
  /// editing its neighbour.
  void _openEditor(FxDestination destination, int group) {
    final address = destination.address;
    if (address == null) return;
    final label = _destinationLabel(destination);
    final monitor = context.read<MonitorCubit>();
    final bloc = context.read<LooperBloc>();
    final presets = context.read<FxPresetsCubit>();
    final groups = fxChainGroups(_entriesOf(context, address));
    if (group < 0 || group >= groups.length) return;
    final id = fxGroupId(groups[group]);
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
            BlocProvider<FxPresetsCubit>.value(value: presets),
          ],
          child: Builder(
            builder: (context) {
              final chain = _watchEntriesOf(context, address);
              final found = fxChainGroups(
                chain,
              ).where((g) => fxGroupId(g) == id).firstOrNull;
              if (found == null) return const SizedBox.shrink();
              final edits = _editsFor(bloc, monitor, address);
              return found.isRack
                  ? FxRackEditor(
                      group: found,
                      destination: destination,
                      destinationLabel: label,
                      edits: edits,
                      onBack: () => Navigator.maybePop(context),
                      onOptions: () =>
                          unawaited(_rackOptions(context, found, edits, label)),
                      onSavePreset: () =>
                          unawaited(_savePreset(context, found)),
                      onAddEffect: () =>
                          unawaited(_addToRack(context, found, edits)),
                    )
                  : FxEffectEditor(
                      group: found,
                      destination: destination,
                      destinationLabel: label,
                      edits: edits,
                      onBack: () => Navigator.maybePop(context),
                      onOptions: () => unawaited(
                        _effectOptions(context, found, edits),
                      ),
                      onSavePreset: () =>
                          unawaited(_savePreset(context, found)),
                    );
            },
          ),
        ),
      ),
    );
  }

  /// The pen's `06 Rack options`: rename, reorder, remove one pedal, remove
  /// the rack.
  ///
  /// Reorder and Remove an effect are offered only on a rack with more than
  /// one pedal — there is no order to change in a rack of one, and taking its
  /// only pedal out is Remove rack said the long way. They are drawn dimmed
  /// rather than hidden so the list keeps its shape between two racks.
  static Future<void> _rackOptions(
    BuildContext context,
    FxChainGroup group,
    FxEdits edits,
    String label,
  ) async {
    final l10n = context.l10n;
    final rack = group.rack;
    if (rack == null) return;
    final several = group.length > 1;
    final choice = await showFxOptionsSheet(
      context,
      title: l10n.fxRackOptions,
      options: [
        FxOption(id: 'rename', label: l10n.fxRackRename),
        FxOption(
          id: 'reorder',
          label: l10n.fxReorderEffects,
          enabled: several,
        ),
        FxOption(
          id: 'remove-one',
          label: l10n.fxRemoveAnEffect,
          enabled: several,
        ),
        FxOption(id: 'remove', label: l10n.fxRemoveRack),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'rename':
        final name = await showConsoleRenameSheet(
          context,
          title: l10n.fxRackRename,
          subtitle: rack.name,
          current: rack.name,
          fieldLabel: l10n.fxRackRenameField,
        );
        if (name == null || !context.mounted) return;
        edits.setChain(fxRenameRack(group.chain, rack.id, name));
      case 'reorder':
        final ordered = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
            builder: (_) => FxReorderPage(
              crumb: l10n.fxAddCrumb(label),
              cards: [
                for (final fx in group.entries)
                  FxReorderCard(
                    id: fx.slotId ?? '',
                    name: fxPedalName(l10n, fx),
                    art: fx.module == null ? null : fxModuleArt(fx.module!),
                  ),
              ],
            ),
          ),
        );
        if (ordered == null || !context.mounted) return;
        edits.setChain(fxOrderRackModules(group.chain, rack.id, ordered));
      case 'remove-one':
        final id = await showFxOptionsSheet(
          context,
          title: l10n.fxRemoveAnEffect,
          options: [
            for (final fx in group.entries)
              FxOption(
                id: fx.slotId ?? '',
                label: fxPedalName(l10n, fx),
              ),
          ],
        );
        if (id == null || !context.mounted) return;
        final index = group.chain.indexWhere((fx) => fx.slotId == id);
        if (index < 0) return;
        edits.setChain(fxRemoveRange(group.chain, index, index + 1));
      case 'remove':
        final confirmed = await showConsoleConfirmDialog(
          context,
          title: l10n.fxPresetDeleteTitle(rack.name),
          body: l10n.fxPresetDeleteBody,
          confirmLabel: l10n.fxRemoveRack,
        );
        if (!confirmed || !context.mounted) return;
        edits.setChain(fxRemoveRange(group.chain, group.start, group.end));
        Navigator.maybePop(context);
    }
  }

  /// How many groups the destination's chain holds.
  int _groupCount(BuildContext context, FxDestination destination) {
    final address = destination.address;
    if (address == null) return 0;
    return fxChainGroups(_watchEntriesOf(context, address)).length;
  }

  /// The pen's `05 Reorder rack chain`: the destination's own racks and single
  /// effects, arranged on the shared reorder strip.
  ///
  /// The cards carry their stage, and a move across the Pre/Post break is
  /// refused, because the accepted design says reorder moves an effect within
  /// its stage and the explicit switch is what moves it between them.
  Future<void> _reorderChain(FxDestination destination) async {
    final address = destination.address;
    if (address == null) return;
    final l10n = context.l10n;
    final chain = _entriesOf(context, address);
    final groups = fxChainGroups(chain);
    if (groups.length < 2) return;
    final showStage = destination.placementIsEditable;
    final ordered = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => FxReorderPage(
          crumb: l10n.fxAddCrumb(_destinationLabel(destination)),
          cards: [
            for (var i = 0; i < groups.length; i++)
              FxReorderCard(
                id: fxGroupId(groups[i]),
                name: fxGroupName(l10n, groups[i]),
                art: groups[i].rack?.art == null
                    ? null
                    : fxRackArtAsset(groups[i].rack!.art!),
                stageTag: !showStage
                    ? null
                    : groups[i].placement == FxPlacement.pre
                    ? l10n.fxPlacementPre
                    : l10n.fxPlacementPost,
              ),
          ],
        ),
      ),
    );
    if (ordered == null || !mounted) return;
    _editsFor(
      context.read<LooperBloc>(),
      context.read<MonitorCubit>(),
      address,
    ).setChain(fxOrderGroups(chain, ordered));
  }

  /// The pen's `02 Add an effect to a rack`: the same full-page catalogue,
  /// with what it resolves to joining THIS rack rather than starting a second
  /// one beside it.
  ///
  /// The new pedals land at the end of the rack and arrive bypassed, like every
  /// other addition, and Back from the catalogue changes nothing.
  Future<void> _addToRack(
    BuildContext context,
    FxChainGroup group,
    FxEdits edits,
  ) async {
    final rack = group.rack;
    if (rack == null) return;
    final chain = group.chain;
    final presets = context.read<FxPresetsCubit>();
    final choice = await Navigator.push<FxLibraryChoice>(
      context,
      MaterialPageRoute(
        // My presets lives inside the library, and the library's route sits
        // above the page's providers, so the saved list is carried in by
        // value rather than looked up.
        builder: (_) => BlocProvider<FxPresetsCubit>.value(
          value: presets,
          child: FxLibraryPage(
            catalogue: widget.catalogue ?? FxCatalogue.empty,
            destinationLabel: rack.name,
            freeSlots: kTrackEffectMax - chain.length,
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final added = _entriesFor(
      choice,
      placement: group.placement,
      into: rack,
    );
    if (added.isEmpty) return;
    edits.setChain([
      ...chain.sublist(0, group.end),
      ...added,
      ...chain.sublist(group.end),
    ]);
  }

  /// The pen's `05 Save a preset` and `06 Replace a saved preset`: names the
  /// sound, then makes a reusable copy of it.
  ///
  /// Saving does NOT rename the active instance — the accepted design says so
  /// in as many words, and it is why this writes to the saved list and touches
  /// nothing on the chain. A name already taken asks whether to replace that
  /// definition or use another; cancelling the question keeps the previous
  /// preset, unchanged.
  static Future<void> _savePreset(
    BuildContext context,
    FxChainGroup group,
  ) async {
    final l10n = context.l10n;
    final presets = context.read<FxPresetsCubit>();
    final entries = group.entries;
    final art = group.rack?.art;
    final suggested = fxGroupName(l10n, group);
    var current = suggested;
    while (true) {
      final name = await showConsoleRenameSheet(
        context,
        title: l10n.fxSavePresetTitle,
        subtitle: suggested,
        current: current,
        fieldLabel: l10n.fxPresetNameField,
      );
      if (name == null || !context.mounted) return;
      current = name;
      final existing = fxPresetNamed(presets.state, name);
      if (existing == null) {
        await presets.save(name: name, entries: entries, art: art);
        showAppSnackToast(
          id: 'fx-preset-saved',
          title: AppText(l10n.fxPresetSaved(name.trim())),
        );
        return;
      }
      final answer = await showFxOptionsSheet(
        context,
        title: l10n.fxReplacePresetTitle(existing.name),
        body: l10n.fxPresetExists,
        options: [
          FxOption(id: 'replace', label: l10n.fxReplacePreset),
          FxOption(id: 'another', label: l10n.fxUseAnotherName),
        ],
      );
      // Cancel keeps the previous preset, which is the accepted wording: the
      // question is asked about a definition that already exists, and backing
      // out of it must not touch it.
      if (answer != 'replace' && answer != 'another') return;
      if (answer == 'replace') {
        // The definition changes; every instance already made from it does
        // not. That is the accepted rule, and it falls out of a saved preset
        // being a copy rather than a reference.
        await presets.replace(id: existing.id, entries: entries, art: art);
        showAppSnackToast(
          id: 'fx-preset-saved',
          title: AppText(l10n.fxPresetSaved(existing.name)),
        );
        return;
      }
      if (!context.mounted) return;
    }
  }

  /// A standalone effect's options.
  ///
  /// Removal and nothing else. The accepted design gives rename and reorder to
  /// a RACK — a single effect has no modules to arrange and no name of its own
  /// beyond the effect it is.
  static Future<void> _effectOptions(
    BuildContext context,
    FxChainGroup group,
    FxEdits edits,
  ) async {
    final l10n = context.l10n;
    final name = fxPedalName(l10n, group.entries.first);
    final choice = await showFxOptionsSheet(
      context,
      title: l10n.fxEffectOptions,
      options: [FxOption(id: 'remove', label: l10n.fxRemoveEffect(name))],
    );
    if (choice != 'remove' || !context.mounted) return;
    edits.setChain(fxRemoveRange(group.chain, group.start, group.end));
    Navigator.maybePop(context);
  }

  /// How a chain's editors write, per stage.
  ///
  /// Each stage keeps its own owner rather than routing through one shared
  /// setter: that is what stops a write meant for a live input landing on a
  /// track's chain.
  static FxEdits _editsFor(
    LooperBloc bloc,
    MonitorCubit monitor,
    FxAddress address,
  ) => (
    setEnabled: (index, {required enabled}) => _DestinationChain._togglePower(
      bloc,
      monitor,
      address,
      index,
      enabled: enabled,
    ),
    setParam: (index, param, value) {
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
    setChannels: (index, channels) {
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
    // The structural write. Rename, reorder, removal and the Pre/Post switch
    // all move several entries at once, so they hand back a whole chain rather
    // than editing one slot: a rack is one thing, and half a rack moved is not
    // a state any surface can draw.
    setChain: (chain) {
      switch (address.stage) {
        case FxStage.input:
          monitor.setEffects(address.index, chain);
        case FxStage.loop:
          bloc.add(
            LooperLaneEffectsChanged(address.index, address.lane ?? 0, chain),
          );
        case FxStage.track:
        case FxStage.output:
          bloc.add(LooperBusEffectsChanged(address, chain));
        case FxStage.allTracks:
          bloc.add(LooperAllTracksEffectsChanged(chain));
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
    final presets = context.read<FxPresetsCubit>();
    final choice = await Navigator.push<FxLibraryChoice>(
      context,
      MaterialPageRoute(
        // See the in-rack add: the library's route is above this page's
        // providers, and My presets lives inside it.
        builder: (_) => BlocProvider<FxPresetsCubit>.value(
          value: presets,
          child: FxLibraryPage(
            catalogue: widget.catalogue ?? FxCatalogue.empty,
            destinationLabel: _destinationLabel(destination),
            freeSlots: kTrackEffectMax - entries.length,
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final added = _entriesFor(
      choice,
      placement: destination.defaultPlacement,
    );
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
    FxLibraryChoice choice, {
    required FxPlacement placement,
    FxRack? into,
  }) {
    switch (choice) {
      case FxSingleChoice(:final type):
        return [
          BuiltInEffect(
            type: type,
            enabled: false,
            placement: placement,
            rack: into,
          ),
        ];
      case FxSavedChoice(:final preset):
        // The player's own sound, recalled as a NEW instance: a fresh rack id
        // so it is its own thing on the chain, this destination's placement,
        // and bypassed like every other addition. A single-effect preset
        // stays a single effect.
        final rack =
            into ??
            (preset.isRack
                ? FxRack(
                    id: SlotIds.mint(),
                    name: preset.name,
                    art: preset.art,
                  )
                : null);
        return [
          for (final fx in preset.entries)
            switch (fx) {
              BuiltInEffect() => fx.copyWith(
                enabled: false,
                placement: placement,
                rack: rack,
              ),
              PluginEffect() => fx.copyWith(
                enabled: false,
                placement: placement,
                rack: rack,
              ),
            },
        ];
      case FxRackChoice(:final preset):
        // Every module of one rack carries the same rack: a freshly minted id
        // that makes them one thing to every surface downstream, the preset's
        // own name (which the player may rename without touching the preset),
        // and the family's artwork slug for the card. Adding INTO a rack keeps
        // that rack instead, so the new pedals join it rather than starting a
        // second one beside it.
        final rack =
            into ??
            FxRack(
              id: SlotIds.mint(),
              name: preset.name,
              art: kFxFamilySlugs[preset.family],
            );
        return [
          for (final module in fxPresetModules(preset))
            fxModuleEntry(module, preset).copyWith(
              enabled: false,
              placement: placement,
              rack: rack,
            ),
        ];
    }
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
              onReorder: () => unawaited(_reorderChain(destination)),
              canReorder: _groupCount(context, destination) > 1,
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
  const _SoundContext({
    required this.destination,
    required this.onAdd,
    required this.onReorder,
    required this.canReorder,
  });

  final FxDestination destination;
  final VoidCallback onAdd;
  final VoidCallback onReorder;

  /// Whether there is an order to change. A chain of one has none, so the
  /// button is drawn dimmed rather than promising a page that could do
  /// nothing.
  final bool canReorder;

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
          key: const Key('fx_reorder'),
          width: 137,
          radius: 8,
          label: l10n.fxReorder,
          onTap: canReorder ? onReorder : null,
        ),
        const SizedBox(width: 12),
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
      onTogglePower: (group, {required enabled}) {
        final monitor = context.read<MonitorCubit>();
        final groups = fxChainGroups(entries);
        if (group < 0 || group >= groups.length) return;
        // A rack's power is every pedal's power, one write each. There is no
        // rack-level bypass bit in this engine, so a rack turned back on turns
        // every pedal on — see the rack editor's own note.
        for (var i = groups[group].start; i < groups[group].end; i++) {
          _togglePower(bloc, monitor, address, i, enabled: enabled);
        }
      },
      onOpen: (group) => onOpen(destination, group),
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
