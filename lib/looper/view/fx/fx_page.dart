import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/fx_chain_persistence.dart';
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
import 'package:segno/looper/model/fx_library_choice.dart';
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
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';

/// The Effects route (accepted design, slice 3f): the pen's
/// `01 Effects · destinations`.
///
/// One page for every destination, not one page per stage. The Sound type row
/// picks the strip, the strip picks the source, and the chain underneath is
/// whatever that source carries — which is why a live input, a recorded part,
/// a whole track, All tracks and an output all arrive at the same editor.
class FxPage extends StatelessWidget {
  /// Creates an [FxPage] opened on [initial].
  const FxPage({this.initial, this.catalogue, this.onStage, super.key});

  /// Where the page opens, or the first live input when absent.
  final FxDestination? initial;

  /// The catalogue Add effects offers. Injected so a test and a screenshot
  /// need no asset bundle, and so the app loads it once rather than per open.
  final FxCatalogue? catalogue;

  /// Runs when Stage is chosen, after the route's navigation ends.
  final VoidCallback? onStage;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => FxCubit(
      repository: context.read<LooperRepository>(),
      settings: context.read<SettingsRepository>(),
      persistence: context.read<FxChainPersistence>(),
      initial: initial,
    ),
    child: FxView(catalogue: catalogue, onStage: onStage),
  );
}

/// The Effects page's body, with its [FxCubit] already provided.
@visibleForTesting
class FxView extends StatefulWidget {
  /// Creates an [FxView].
  const FxView({this.catalogue, this.onStage, super.key});

  /// The catalogue Add effects offers, or the bundled one when absent.
  final FxCatalogue? catalogue;

  /// Clears the tray when this route is left for Stage.
  final VoidCallback? onStage;

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
    final groups = fxChainGroups(_entriesOf(context, address));
    if (group < 0 || group >= groups.length) return;
    _openEditorById(destination, fxGroupId(groups[group]));
  }

  void _openEditorById(FxDestination destination, String id) {
    final address = destination.address;
    if (address == null) return;
    final label = _destinationLabel(destination);
    final monitor = context.read<MonitorCubit>();
    final bloc = context.read<LooperBloc>();
    final presets = context.read<FxPresetsCubit>();
    final fx = context.read<FxCubit>();
    if (!fxChainGroups(_entriesOf(context, address)).any(
      (group) => fxGroupId(group) == id,
    )) {
      return;
    }
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
            BlocProvider<FxCubit>.value(value: fx),
          ],
          child: Builder(
            builder: (context) {
              final chain = _watchEntriesOf(context, address);
              final found = fxChainGroups(
                chain,
              ).where((g) => fxGroupId(g) == id).firstOrNull;
              if (found == null) {
                final l10n = context.l10n;
                return Material(
                  type: MaterialType.transparency,
                  child: LoopSettingsFrame(
                    crumb: l10n.fxAddCrumb(label),
                    title: l10n.fxTitle,
                    onBack: () => Navigator.maybePop(context),
                    onStage: _stage,
                    children: [
                      Positioned(
                        left: 36,
                        top: 160,
                        child: AppText(l10n.fxEditorScopeGone),
                      ),
                    ],
                  ),
                );
              }
              final edits = _editsFor(context, fx, address);
              return found.isRack
                  ? FxRackEditor(
                      group: found,
                      destination: destination,
                      destinationLabel: label,
                      edits: edits,
                      onStage: _stage,
                      onBack: () => Navigator.maybePop(context),
                      onOptions: () => unawaited(
                        _rackOptions(context, address, found, label),
                      ),
                      onSavePreset: () =>
                          unawaited(_savePreset(context, found)),
                      onAddEffect: () =>
                          unawaited(_addToRack(context, address, found)),
                    )
                  : FxEffectEditor(
                      group: found,
                      destination: destination,
                      destinationLabel: label,
                      edits: edits,
                      onStage: _stage,
                      onBack: () => Navigator.maybePop(context),
                      onOptions: () => unawaited(
                        _effectOptions(context, address, found),
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
  Future<void> _rackOptions(
    BuildContext context,
    FxAddress address,
    FxChainGroup group,
    String label,
  ) async {
    final l10n = context.l10n;
    final rack = group.rack;
    if (rack == null) return;
    final fx = context.read<FxCubit>();
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
        final result = await fx.renameRack(address, rack.id, name);
        if (context.mounted) _notifyEditResult(context, result);
      case 'reorder':
        final ordered = await Navigator.push<List<String>>(
          context,
          MaterialPageRoute(
            builder: (_) => FxReorderPage(
              onStage: _stage,
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
        final result = await fx.reorderRack(address, rack.id, ordered);
        if (context.mounted) _notifyEditResult(context, result);
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
        final result = await fx.removeRackModule(address, rack.id, id);
        if (context.mounted) _notifyEditResult(context, result);
      case 'remove':
        // Asked first, because a rack is several pedals with their settings
        // and a chain has no undo. What it says is the accepted rule: removing
        // a rack leaves the sounds saved from it alone.
        final confirmed = await showConsoleConfirmDialog(
          context,
          title: l10n.fxRemoveRackTitle(rack.name),
          body: l10n.fxRemoveRackBody,
          confirmLabel: l10n.fxRemoveRack,
        );
        if (!confirmed || !context.mounted) return;
        final result = await fx.removeRack(address, rack.id);
        if (!context.mounted) return;
        _notifyEditResult(context, result);
        if (!_committed(result)) {
          return;
        }
        showAppSnackToast(
          id: 'fx-rack-removed',
          title: AppText(l10n.fxRackRemoved(rack.name)),
        );
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.maybePop(context);
        }
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
          onStage: _stage,
          crumb: l10n.fxAddCrumb(_destinationLabel(destination)),
          cards: [
            for (var i = 0; i < groups.length; i++)
              FxReorderCard(
                id: fxGroupId(groups[i]),
                name: fxGroupName(l10n, groups[i]),
                art: groups[i].rack?.art == null
                    ? null
                    : fxFootswitchAsset(groups[i].rack!.art!),
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
    final result = await context.read<FxCubit>().reorderGroups(
      address,
      ordered,
    );
    if (mounted) _notifyEditResult(context, result);
  }

  /// The pen's `02 Add an effect to a rack`: the same full-page catalogue,
  /// with what it resolves to joining THIS rack rather than starting a second
  /// one beside it.
  ///
  /// The new pedals land at the end of the rack and arrive bypassed, like every
  /// other addition, and Back from the catalogue changes nothing.
  Future<void> _addToRack(
    BuildContext context,
    FxAddress address,
    FxChainGroup group,
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
            onStage: _stage,
            catalogue: widget.catalogue ?? FxCatalogue.empty,
            destinationLabel: rack.name,
            freeSlots: kTrackEffectMax - chain.length,
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final result = await context.read<FxCubit>().appendToRack(
      address,
      rack.id,
      choice,
    );
    if (context.mounted) _notifyEditResult(context, result);
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
        try {
          await presets.save(name: name, entries: entries, art: art);
        } on Object {
          if (context.mounted) {
            showAppSnackToast(
              id: 'fx-preset-save-failed',
              type: ToastificationType.error,
              title: AppText(l10n.storageActionFailed),
            );
          }
          return;
        }
        if (!context.mounted) return;
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
        try {
          await presets.replace(id: existing.id, entries: entries, art: art);
        } on Object {
          if (context.mounted) {
            showAppSnackToast(
              id: 'fx-preset-save-failed',
              type: ToastificationType.error,
              title: AppText(l10n.storageActionFailed),
            );
          }
          return;
        }
        if (!context.mounted) return;
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
    FxAddress address,
    FxChainGroup group,
  ) async {
    final l10n = context.l10n;
    final name = fxPedalName(l10n, group.entries.first);
    final choice = await showFxOptionsSheet(
      context,
      title: l10n.fxEffectOptions,
      options: [FxOption(id: 'remove', label: l10n.fxRemoveEffect(name))],
    );
    if (choice != 'remove' || !context.mounted) return;
    final id = group.entries.first.slotId;
    final fx = context.read<FxCubit>();
    if (id == null) return;
    final result = await fx.removeEffect(address, id);
    if (!context.mounted) return;
    _notifyEditResult(context, result);
    if (!_committed(result)) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.maybePop(context);
    }
  }

  static void _changeRefused(BuildContext context) => showAppSnackToast(
    id: 'fx-change-refused',
    type: ToastificationType.error,
    title: AppText(context.l10n.fxChangeNotApplied),
  );

  static bool _committed(FxEditResult result) =>
      result.status == FxEditStatus.applied ||
      result.status == FxEditStatus.unsaved;

  static void _notifyEditResult(BuildContext context, FxEditResult result) {
    switch (result.status) {
      case FxEditStatus.refused:
        _changeRefused(context);
      case FxEditStatus.unsaved:
        showAppSnackToast(
          id: 'fx-storage-failed',
          type: ToastificationType.error,
          title: AppText(context.l10n.storageActionFailed),
        );
      case FxEditStatus.applied || FxEditStatus.unchanged || FxEditStatus.stale:
        break;
    }
  }

  /// Forwards editor gestures to the route owner by stable identity.
  static FxEdits _editsFor(
    BuildContext context,
    FxCubit fx,
    FxAddress address,
  ) {
    void report(FxEditResult result) {
      if (context.mounted) _notifyEditResult(context, result);
    }

    Future<void> reportLater(Future<FxEditResult> future) async {
      report(await future);
    }

    return (
      setEnabled: (slotId, {required enabled}) =>
          report(fx.setEffectEnabled(address, slotId, enabled: enabled)),
      setGroupEnabled: (groupId, {required enabled}) =>
          report(fx.setGroupEnabled(address, groupId, enabled: enabled)),
      setParam: (slotId, parameter, value) =>
          report(fx.setParameter(address, slotId, parameter, value)),
      setChannels: (groupId, channels) => unawaited(
        reportLater(fx.setGroupChannels(address, groupId, channels)),
      ),
      setPlacement: (groupId, placement) => unawaited(
        reportLater(fx.setGroupPlacement(address, groupId, placement)),
      ),
    );
  }

  /// Opens the library for [destination] and appends what comes back.
  ///
  /// The library resolves to a CHOICE and changes nothing itself: what the
  /// choice does to a chain is this page's business, which is what makes one
  /// Back from a completed addition land on the destination rather than
  /// walking back out through the family and the grid.
  Future<void> _addEffects(FxDestination destination) async {
    final address = destination.address;
    if (address == null) return;
    final route = ModalRoute.of(context);
    final bloc = context.read<LooperBloc>();
    final generation = bloc.state.mixGeneration;
    final selection = context.read<FxCubit>();
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
            onStage: _stage,
            catalogue: widget.catalogue ?? FxCatalogue.empty,
            destinationLabel: _destinationLabel(destination),
            freeSlots: kTrackEffectMax - entries.length,
          ),
        ),
      ),
    );
    if (choice == null ||
        !mounted ||
        !(route?.isCurrent ?? false) ||
        !bloc.hasMixGeneration(generation) ||
        selection.state.destination != destination) {
      return;
    }
    bool stillHere() =>
        mounted &&
        (route?.isCurrent ?? false) &&
        selection.state.destination == destination &&
        bloc.hasMixGeneration(generation);
    final result = await selection.appendChoice(destination, choice);
    if (!mounted || !stillHere()) return;
    _notifyEditResult(context, result);
    if (!_committed(result)) {
      return;
    }
    final id = result.groupId;
    if (id == null) return;
    if (await _waitForAddedGroup(destination, id, generation, route) &&
        stillHere()) {
      _openEditorById(destination, id);
    }
  }

  /// Waits for the confirmed recipe to reach the page's projected source.
  /// The receipt can precede the next looper-state publication, and opening
  /// then would show an editor with no group to edit.
  Future<bool> _waitForAddedGroup(
    FxDestination destination,
    String id,
    int generation,
    ModalRoute<Object?>? route,
  ) async {
    final address = destination.address;
    if (address == null || !mounted) return false;
    final selection = context.read<FxCubit>();
    final bloc = context.read<LooperBloc>();
    final monitor = context.read<MonitorCubit>();
    bool valid() =>
        mounted &&
        (route?.isCurrent ?? false) &&
        selection.state.destination == destination &&
        bloc.hasMixGeneration(generation);
    bool found() =>
        valid() &&
        fxChainGroups(_entriesOf(context, address)).any(
          (group) => fxGroupId(group) == id,
        );
    if (!valid()) return false;
    if (found()) return true;

    final ready = Completer<bool>();
    void check() {
      if (ready.isCompleted) return;
      if (!valid()) {
        ready.complete(false);
      } else if (found()) {
        ready.complete(true);
      }
    }

    final selectionSub = selection.stream.listen(
      (_) => check(),
      onDone: () {
        if (!ready.isCompleted) ready.complete(false);
      },
    );
    final rigSub = address.stage == FxStage.input
        ? null
        : bloc.stream.listen(
            (_) => check(),
            onDone: () {
              if (!ready.isCompleted) ready.complete(false);
            },
          );
    final monitorSub = address.stage == FxStage.input
        ? monitor.stream.listen(
            (_) => check(),
            onDone: () {
              if (!ready.isCompleted) ready.complete(false);
            },
          )
        : null;
    check();
    try {
      return await ready.future;
    } finally {
      await selectionSub.cancel();
      await rigSub?.cancel();
      await monitorSub?.cancel();
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

  void _stage() {
    widget.onStage?.call();
    Navigator.popUntil(context, (route) => route.isFirst);
  }

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
    final state = monitor.state.forInput(input);
    final mode = state.mode;
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
        if (state.muted) ...[
          const SizedBox(width: 16),
          AppText(
            l10n.fxMutedInMixer,
            style: TextStyle(color: context.surface.warning, fontSize: 20),
          ),
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
    final chainEnabled = switch (address.stage) {
      FxStage.input =>
        context
            .watch<MonitorCubit>()
            .state
            .forInput(address.index)
            .chainEnabled,
      FxStage.loop => context.select<LooperBloc, bool>(
        (b) =>
            b.state.tracks
                .elementAtOrNull(address.index)
                ?.lanes
                .elementAtOrNull(address.lane ?? 0)
                ?.chainEnabled ??
            true,
      ),
      FxStage.track => context.select<LooperBloc, bool>(
        (b) =>
            b.state.tracks.elementAtOrNull(address.index)?.chainEnabled ?? true,
      ),
      FxStage.output => context.select<LooperBloc, bool>(
        (b) => b.state.outputChainEnabled(address.index),
      ),
      FxStage.allTracks => context.select<LooperBloc, bool>(
        (b) => b.state.allTracksChain.chainEnabled,
      ),
    };
    return FxChainStrip(
      key: Key('fx_chain_${address.canonicalString()}'),
      entries: entries,
      chainEnabled: chainEnabled,
      controller: controller,
      showPlacement: destination.placementIsEditable,
      onTogglePower: (group, {required enabled}) {
        final groups = fxChainGroups(entries);
        if (group < 0 || group >= groups.length) return;
        final outcome = context.read<FxCubit>().setGroupEnabled(
          address,
          fxGroupId(groups[group]),
          enabled: enabled,
        );
        _FxViewState._notifyEditResult(context, outcome);
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
}
