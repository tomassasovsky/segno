import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_led_labels.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/control/view/pedal_setup/pedal_color_dialog.dart';
import 'package:segno/control/view/pedal_setup/pedal_led_editor.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_editor.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_map.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Which half of the plate the setup is editing.
enum PedalSetupContext {
  /// The fixed plate, and the few gestures configurable on it.
  tracks,

  /// The free map: eight switches, each with its own Press and Hold.
  custom,

  /// The LED colour map: per mode, a colour for every state each pedal group
  /// can show. The four track pedals are one group.
  leds,
}

/// The accepted Pedals setup (Layout A): the hardware map stays on screen
/// while the chosen switch's Press and Hold are edited together.
///
/// One draft for assignments and colors, one Save. Every edit stays local and
/// nothing reaches the rig until Save, which is what lets Clear custom
/// assignments offer Restore and lets Cancel mean something. An unfinished
/// draft cannot ride out on someone else's save either: it lives here, not in
/// the cubit.
class PedalSetupPage extends StatefulWidget {
  /// Creates a [PedalSetupPage].
  const PedalSetupPage({this.onStage, super.key});

  /// Closes the calling setup tray before returning to performance.
  final VoidCallback? onStage;

  @override
  State<PedalSetupPage> createState() => _PedalSetupPageState();
}

class _PedalSetupPageState extends State<PedalSetupPage> {
  late final Future<void> _initialLoad;

  @override
  void initState() {
    super.initState();
    final control = context.read<ControlCubit>();
    _initialLoad = control.load();
    _ledMode = control.state.mode;
  }

  /// The edit in progress, or `null` when nothing has been touched since the
  /// last Save or Cancel.
  ///
  /// Nullable rather than forked at init: the setup is restored from settings
  /// asynchronously, so a draft forked in `initState` would be the defaults
  /// on a rig that has a saved setup. While it is null the page reads the
  /// live one, and the first edit forks from whatever is current then.
  PedalSetup? _draft;

  /// What Clear custom assignments took away, until the draft is saved or
  /// cancelled.
  PedalSetup? _cleared;

  PedalSetupContext _context = PedalSetupContext.tracks;

  /// The switch being edited. MODE in Track controls (the only one there with
  /// both gestures free) and the first track switch in Custom controls, which
  /// is where the study opens each of them.
  PedalButton _selected = PedalButton.mode;

  int _bank = 0;

  /// The mode whose colours LED colors is showing: the console's mode when
  /// the page opened, so the map shown is the one the pedals are lit from.
  late InteractionMode _ledMode;

  bool _saved = false;
  bool _saving = false;
  bool _saveFailed = false;

  /// The offsets inside the frame's content box. The LED colors mode tabs
  /// take the row at [_modeTabsTop]; the map starts an xl gap under it, and
  /// the editor box ends at the content box's bottom edge.
  static const double _modeTabsTop = 120;
  static const double _modeTabHeight = 64;
  static const double _mapTop = 208;
  static const double _editorTop = 772;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    final frame = context.select<PedalCubit, PedalStateFrame?>(
      (cubit) => cubit.state.frame,
    );
    return FutureBuilder<void>(
      future: _initialLoad,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError) {
          return Scaffold(
            body: LoopSettingsFrame(
              tabs: _ContextTabs(
                selected: _context,
                onOpen: _openContext,
                enabled: false,
              ),
              title: l10n.pedalSetupTitle,
              onBack: () => Navigator.of(context).maybePop(),
              onStage: _stage,
              children: [
                Positioned.fill(
                  child: Center(
                    child: AppText(
                      snapshot.hasError
                          ? l10n.pedalSetupLoadFailed
                          : l10n.pedalSetupLoading,
                      key: const Key('pedal_setup_loading'),
                      style: TextStyle(
                        color: context.surface.textSecondary,
                        fontSize: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        final setup = _draft ?? control.state.pedalSetup;
        // The rig may not hold the setup shown, so it can be saved again with
        // nothing edited.
        final pending =
            control.state.pedalSetupPersistenceUncertain ||
            control.state.pedalSetupUnavailable ||
            control.state.pedalSetupRuntimeUnsaved;
        return PopScope(
          canPop: !_saving,
          child: AbsorbPointer(
            absorbing: _saving,
            child: ExcludeFocus(
              excluding: _saving,
              child: Scaffold(
                body: LoopSettingsFrame(
                  key: const Key('pedal_setup_page'),
                  tabs: _ContextTabs(
                    selected: _context,
                    onOpen: _openContext,
                  ),
                  title: l10n.pedalSetupTitle,
                  onBack: () => Navigator.of(context).maybePop(),
                  onStage: _stage,
                  actions: _SetupActions(
                    setupContext: _context,
                    dirty: _draft != null,
                    saving: _saving,
                    saved: _saved,
                    pending: pending,
                    ledsEdited:
                        _context == PedalSetupContext.leds &&
                        setup.leds.isEdited(_ledMode),
                    hasCustomAssignments:
                        _context == PedalSetupContext.custom &&
                        setup.hasCustomAssignments,
                    canRestore: _cleared != null,
                    onResetLeds: _resetLeds,
                    onClearCustom: () => unawaited(_confirmClear(setup)),
                    onRestoreCustom: _restoreCleared,
                    onExternal: () => unawaited(openExternalPedals()),
                    onCancel: _cancel,
                    onSave: () => unawaited(_save(control, setup)),
                  ),
                  children: [
                    if (_context == PedalSetupContext.leds)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: _modeTabsTop,
                        height: _modeTabHeight,
                        child: _LedModeTabs(
                          selected: _ledMode,
                          onShow: _showLedMode,
                          height: _modeTabHeight,
                        ),
                      ),
                    // The pedal map keeps its drawn geometry, centred on the
                    // page as on the console.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _mapTop,
                      child: Center(
                        child: PedalSetupMap(
                          frame: frame,
                          // LED colors previews the shown mode's draft
                          // colours; every other context shows what the pedal
                          // lights now.
                          preview: _context == PedalSetupContext.leds
                              ? _ledPreview(setup)
                              : null,
                          physicalLabels: _context == PedalSetupContext.leds,
                          selected: _selectedGroup,
                          editable: _editable,
                          onSelect: (button) =>
                              setState(() => _selected = button),
                          bank: _mapBank,
                          bankSelectable: _context == PedalSetupContext.custom,
                          onToggleBank: () => setState(() => _bank = 1 - _bank),
                        ),
                      ),
                    ),
                    if (pending || _saveFailed)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 464,
                        height: 64,
                        child: Center(
                          child: AppText(
                            [
                              if (control.state.pedalSetupUnavailable)
                                l10n.pedalSetupUnavailable,
                              if (control.state.pedalSetupPersistenceUncertain)
                                l10n.pedalSetupSaveUncertain
                              else if (_saveFailed ||
                                  control.state.pedalSetupRuntimeUnsaved)
                                l10n.pedalSetupSaveFailed,
                            ].join('\n'),
                            key: Key(
                              control.state.pedalSetupUnavailable
                                  ? 'pedal_setup_unavailable'
                                  : control.state.pedalSetupPersistenceUncertain
                                  ? 'pedal_setup_save_uncertain'
                                  : 'pedal_setup_save_failed',
                            ),
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.surface.warning,
                              fontSize: 24,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _editorTop,
                      child: switch (_context) {
                        // One widget for both, so switching between them
                        // updates the same fields rather than rebuilding them.
                        PedalSetupContext.tracks ||
                        PedalSetupContext.custom => _GestureEditor(
                          title: _controlName(context),
                          custom: _context == PedalSetupContext.custom,
                          selected: _selected,
                          setup: setup,
                          bank: _bank,
                          customLeds: {
                            for (final state in PedalLedMap.customStates)
                              state: setup.leds.customColorFor(
                                _customKey,
                                state,
                              ),
                          },
                          onEditModePress: () =>
                              unawaited(_editModePress(setup)),
                          onEditModeHold: () => unawaited(_editModeHold(setup)),
                          onEditRecordHold: () =>
                              unawaited(_editRecordHold(setup)),
                          onEditTrackHold: () =>
                              unawaited(_editTrackHold(setup)),
                          onEditCustom: ({required hold}) =>
                              unawaited(_editCustom(setup, hold: hold)),
                          onEditColor: (state) =>
                              unawaited(_editCustomColor(state)),
                        ),
                        PedalSetupContext.leds => PedalLedEditor(
                          title: _controlName(context),
                          colors: {
                            for (final state in PedalLedMap.schema(
                              _ledMode,
                            )[PedalLedMap.groupOf(_selected)]!.keys)
                              state: setup.leds.colorFor(
                                _ledMode,
                                PedalLedMap.groupOf(_selected),
                                state,
                              ),
                          },
                          onEdit: (state) => unawaited(_editLedColor(state)),
                        ),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _stage() {
    widget.onStage?.call();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _cancel() => setState(() {
    _draft = null;
    _cleared = null;
    _saved = false;
    _saveFailed = false;
  });

  Future<void> _save(ControlCubit control, PedalSetup setup) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      // External has its own draft and may have been saved while this page
      // remained underneath it. Commit only the fields edited here.
      await control.setPedalSetup(
        setup.copyWith(external: control.state.pedalSetup.external),
      );
      if (!mounted) return;
      setState(() {
        _draft = null;
        _cleared = null;
        _saved = true;
      });
    } on Object {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _restoreCleared() => setState(() {
    _draft = (_draft ?? context.read<ControlCubit>().state.pedalSetup).copyWith(
      custom: _cleared!.custom,
    );
    _cleared = null;
    _saved = false;
  });

  Future<void> _confirmClear(PedalSetup setup) async {
    final confirmed = await showPedalClearDialog(context);
    if (!confirmed || !mounted) return;
    setState(() {
      // Restore keeps the Custom draft from before Clear. Later edits to
      // Track controls remain independent of restoring this map.
      _cleared = setup;
      _draft = setup.clearedCustom();
      _saved = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Contexts
  // ---------------------------------------------------------------------------

  void _openContext(PedalSetupContext next) {
    if (next == _context) return;
    setState(() {
      _context = next;
      // Land on a switch this context can actually edit: keeping the old
      // selection would open on a dimmed cap with nothing under it.
      _selected = switch (next) {
        PedalSetupContext.tracks => PedalButton.mode,
        PedalSetupContext.custom => PedalButton.track1,
        PedalSetupContext.leds => _firstLedButton(_ledMode),
      };
    });
  }

  /// The first pedal [mode] colours: Track 1 wherever the track pedals have a
  /// state, MODE in Custom, where only MODE and Bank are the mode's own.
  static PedalButton _firstLedButton(InteractionMode mode) =>
      PedalButton.values.firstWhere(
        (button) =>
            PedalLedMap.groupOf(button) == PedalLedMap.schema(mode).keys.first,
      );

  /// The bank the MAP is showing.
  ///
  /// Always A in Track controls: nothing there is per-bank — one hold covers
  /// all four track switches — so a map reading TRACK 5-8 would name a bank
  /// that context has no way to leave, since BANK is dimmed there.
  int get _mapBank => _context == PedalSetupContext.custom ? _bank : 0;

  /// The switches this context can edit.
  Set<PedalButton> get _editable => switch (_context) {
    // Colour is the performer's only where the function is: Record, Mute and
    // FX light in fixed state colours, so only the switches Custom mode can
    // assign take a colour.
    PedalSetupContext.leds => {
      for (final button in PedalButton.values)
        if (PedalLedMap.schema(
          _ledMode,
        ).containsKey(PedalLedMap.groupOf(button)))
          button,
    },
    PedalSetupContext.custom => {
      for (final button in PedalButton.values)
        if (!PedalBindingKey.unbindable.contains(button)) button,
    },
    // Stop, Undo, Clear and Bank do one thing here and keep it: the accepted
    // design dims them rather than offering an assignment it would refuse.
    PedalSetupContext.tracks => {
      PedalButton.mode,
      PedalButton.recPlay,
      ...kTrackSwitches,
    },
  };

  /// The switches drawn as selected.
  ///
  /// In Track controls the four track caps light together, because one hold
  /// setting covers all four and marking only the tapped one would promise a
  /// per-switch assignment that does not exist.
  Set<PedalButton> get _selectedGroup =>
      _context != PedalSetupContext.custom && kTrackSwitches.contains(_selected)
      ? kTrackSwitches.toSet()
      : {_selected};

  // ---------------------------------------------------------------------------
  // The editor
  // ---------------------------------------------------------------------------

  /// Each pedal the shown mode colours, in its first state's draft colour.
  Map<PedalButton, PedalColor> _ledPreview(PedalSetup setup) {
    final schema = PedalLedMap.schema(_ledMode);
    return {
      for (final button in PedalButton.values)
        if (schema[PedalLedMap.groupOf(button)] case final states?)
          button: setup.leds.colorFor(
            _ledMode,
            PedalLedMap.groupOf(button),
            states.keys.first,
          ),
    };
  }

  void _showLedMode(InteractionMode mode) => setState(() {
    _ledMode = mode;
    if (!_editable.contains(_selected)) {
      _selected = _firstLedButton(_ledMode);
    }
  });

  void _resetLeds() => setState(() {
    final latest = _draft ?? context.read<ControlCubit>().state.pedalSetup;
    _draft = latest.copyWith(leds: latest.leds.resetMode(_ledMode));
    _saved = false;
  });

  /// Opens the colour editor on one state of the selected group in the shown
  /// mode.
  Future<void> _editLedColor(PedalLedState state) async {
    final mode = _ledMode;
    final group = PedalLedMap.groupOf(_selected);
    await _editColor(
      (leds) => leds.colorFor(mode, group, state),
      (leds, color) => leds.withColor(mode, group, state, color),
    );
  }

  /// Opens the colour editor on the selected Custom assignment's [state].
  Future<void> _editCustomColor(PedalLedState state) async {
    final key = _customKey;
    await _editColor(
      (leds) => leds.customColorFor(key, state),
      (leds, color) => leds.withCustomColor(key, state, color),
    );
  }

  PedalBindingKey get _customKey => PedalBindingKey(
    button: _selected,
    bank: PedalBindingKey.isBankKeyed(_selected) ? _bank : null,
  );

  /// Mixes one colour and merges it into the latest draft, without
  /// resurrecting a setup replaced while the dialog was open.
  Future<void> _editColor(
    PedalColor Function(PedalLedMap leds) read,
    PedalLedMap Function(PedalLedMap leds, PedalColor color) write,
  ) async {
    final control = context.read<ControlCubit>();
    final liveAtOpen = control.state.pedalSetup;
    final chosen = await showPedalColorDialog(
      context,
      initial: read((_draft ?? liveAtOpen).leds),
    );
    if (chosen == null || !mounted || control.state.pedalSetup != liveAtOpen) {
      return;
    }
    setState(() {
      final latest = _draft ?? control.state.pedalSetup;
      _draft = latest.copyWith(leds: write(latest.leds, chosen));
      _saved = false;
    });
  }

  String _controlName(BuildContext context) {
    final l10n = context.l10n;
    if (_context == PedalSetupContext.leds) {
      return pedalLedGroupLabel(l10n, PedalLedMap.groupOf(_selected));
    }
    if (_context == PedalSetupContext.tracks &&
        kTrackSwitches.contains(_selected)) {
      return l10n.pedalSetupTrackGroup;
    }
    return pedalSwitchLabel(l10n, _selected, _mapBank);
  }

  String _pickerTitle(BuildContext context, {required bool hold}) {
    final l10n = context.l10n;
    return l10n.pedalSetupChooser(
      _controlName(context),
      hold ? l10n.pedalSetupHold : l10n.pedalSetupPress,
    );
  }

  // ---------------------------------------------------------------------------
  // Pickers
  // ---------------------------------------------------------------------------

  Future<void> _editModePress(PedalSetup setup) async {
    final l10n = context.l10n;
    final names = context.read<TracksCubit>().state.names;
    final chosen = await showPedalChoicePicker<InteractionMode>(
      context,
      title: _pickerTitle(context, hold: false),
      current: setup.modePress,
      groups: [
        PedalChoiceGroup(
          label: l10n.actionGroupFunctions,
          id: 'modes',
          choices: [
            for (final mode in PedalSetup.modeChoices)
              PedalChoice(
                value: mode,
                id: 'mode_${ModeAction(mode).token}',
                label: controlActionLabel(l10n, names, ModeAction(mode)),
              ),
          ],
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft = setup.copyWith(modePress: chosen.value));
  }

  Future<void> _editModeHold(PedalSetup setup) async {
    final l10n = context.l10n;
    final names = context.read<TracksCubit>().state.names;
    final chosen = await showPedalChoicePicker<InteractionMode?>(
      context,
      title: _pickerTitle(context, hold: true),
      current: setup.modeHold,
      groups: [
        PedalChoiceGroup(
          label: l10n.actionGroupFunctions,
          id: 'modes',
          choices: [
            PedalChoice(value: null, id: 'none', label: l10n.actionNone),
            for (final mode in PedalSetup.modeChoices)
              PedalChoice(
                value: mode,
                id: 'mode_${ModeAction(mode).token}',
                label: controlActionLabel(l10n, names, ModeAction(mode)),
              ),
          ],
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(
      () => _draft = setup.copyWith(
        modeHold: chosen.value,
        clearModeHold: chosen.value == null,
      ),
    );
  }

  Future<void> _editRecordHold(PedalSetup setup) async {
    final l10n = context.l10n;
    final chosen = await showPedalChoicePicker<RecordHold>(
      context,
      title: _pickerTitle(context, hold: true),
      current: setup.recordHold,
      groups: [
        PedalChoiceGroup(
          label: l10n.actionGroupFunctions,
          id: 'record_hold',
          choices: [
            for (final hold in RecordHold.values)
              PedalChoice(
                value: hold,
                id: 'record_hold_${hold.name}',
                label: recordHoldLabel(l10n, hold),
              ),
          ],
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft = setup.copyWith(recordHold: chosen.value));
  }

  Future<void> _editTrackHold(PedalSetup setup) async {
    final l10n = context.l10n;
    final chosen = await showPedalChoicePicker<TrackHold>(
      context,
      title: _pickerTitle(context, hold: true),
      current: setup.trackHold,
      groups: [
        PedalChoiceGroup(
          label: l10n.actionGroupFunctions,
          id: 'track_hold',
          choices: [
            for (final hold in TrackHold.values)
              PedalChoice(
                value: hold,
                id: 'track_hold_${hold.name}',
                label: trackHoldLabel(l10n, hold),
              ),
          ],
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft = setup.copyWith(trackHold: chosen.value));
  }

  Future<void> _editCustom(PedalSetup setup, {required bool hold}) async {
    final l10n = context.l10n;
    final names = context.read<TracksCubit>().state.names;
    final pair = setup.customFor(_selected, bank: _bank);
    final chosen = await showPedalChoicePicker<ControlAction?>(
      context,
      title: _pickerTitle(context, hold: hold),
      current: hold ? pair.hold : pair.press,
      groups: [
        for (final group in controlActionGroups())
          PedalChoiceGroup(
            label: controlActionGroupLabel(l10n, group),
            id: group.name,
            choices: [
              // None leads the first group rather than getting a tab of its
              // own: the accepted catalogue lists it among the functions, and
              // a tab holding one button would be a heading over nothing.
              if (group == controlActionGroups().first)
                PedalChoice(value: null, id: 'none', label: l10n.actionNone),
              for (final action in controlActionsIn(group))
                PedalChoice(
                  value: action,
                  id: action.key,
                  label: controlActionLabel(l10n, names, action),
                ),
            ],
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    setState(() {
      final next = hold
          ? pair.withHold(chosen.value)
          : pair.withPress(chosen.value);
      _draft = setup.withCustom(_selected, bank: _bank, pair: next);
    });
  }
}

/// The titlebar's actions: the context's own buttons, External pedals, and
/// Cancel and Save for the draft.
class _SetupActions extends StatelessWidget {
  const _SetupActions({
    required this.setupContext,
    required this.dirty,
    required this.saving,
    required this.saved,
    required this.pending,
    required this.ledsEdited,
    required this.hasCustomAssignments,
    required this.canRestore,
    required this.onResetLeds,
    required this.onClearCustom,
    required this.onRestoreCustom,
    required this.onExternal,
    required this.onCancel,
    required this.onSave,
  });

  final PedalSetupContext setupContext;

  /// Whether the page holds an unsaved draft.
  final bool dirty;

  final bool saving;

  /// Whether the last Save went through.
  final bool saved;

  /// Whether the rig may not hold the setup shown: unavailable, uncertain or
  /// unsaved at runtime.
  final bool pending;

  /// Whether the shown mode's LED colours differ from the defaults.
  final bool ledsEdited;

  final bool hasCustomAssignments;

  /// Whether Clear custom assignments has something to restore.
  final bool canRestore;

  final VoidCallback onResetLeds;
  final VoidCallback onClearCustom;
  final VoidCallback onRestoreCustom;
  final VoidCallback onExternal;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final canSave = (dirty || pending) && !saving;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (saved && !dirty && !pending)
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: AppText(
              l10n.pedalSetupSaved,
              key: const Key('pedal_setup_saved'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 24,
                height: 1,
              ),
            ),
          ),
        if (setupContext == PedalSetupContext.leds) ...[
          LoopOutlinedButton(
            key: const Key('pedal_led_reset'),
            width: 300,
            label: l10n.pedalLedReset,
            onTap: ledsEdited ? onResetLeds : null,
          ),
          const SizedBox(width: 16),
        ],
        if (setupContext == PedalSetupContext.custom) ...[
          LoopOutlinedButton(
            key: const Key('pedal_setup_clear_custom'),
            width: 380,
            label: l10n.pedalSetupClearCustom,
            onTap: hasCustomAssignments ? onClearCustom : null,
          ),
          const SizedBox(width: 16),
          if (canRestore) ...[
            LoopOutlinedButton(
              key: const Key('pedal_setup_restore_custom'),
              width: 300,
              label: l10n.pedalSetupRestoreCustom,
              onTap: onRestoreCustom,
            ),
            const SizedBox(width: 16),
          ],
        ],
        LoopOutlinedButton(
          key: const Key('pedal_setup_external'),
          width: 268,
          label: l10n.externalPedalsTitle,
          onTap: onExternal,
        ),
        const SizedBox(width: 24),
        Opacity(
          opacity: dirty && !saving ? 1 : surface.disabledOpacity,
          child: LoopOutlinedButton(
            key: const Key('pedal_setup_cancel'),
            width: 125,
            label: l10n.pedalSetupCancel,
            onTap: dirty && !saving ? onCancel : null,
          ),
        ),
        const SizedBox(width: 16),
        Opacity(
          opacity: canSave ? 1 : surface.disabledOpacity,
          child: LoopOutlinedButton(
            key: const Key('pedal_setup_save'),
            width: 125,
            tone: LoopButtonTone.accent,
            label: saving ? l10n.pedalSetupSaving : l10n.pedalSetupSave,
            onTap: canSave ? onSave : null,
          ),
        ),
      ],
    );
  }
}

/// The selected switch's Press and Hold, in Track controls or Custom
/// controls.
class _GestureEditor extends StatelessWidget {
  const _GestureEditor({
    required this.title,
    required this.custom,
    required this.selected,
    required this.setup,
    required this.bank,
    required this.customLeds,
    required this.onEditModePress,
    required this.onEditModeHold,
    required this.onEditRecordHold,
    required this.onEditTrackHold,
    required this.onEditCustom,
    required this.onEditColor,
  });

  final String title;

  /// Whether this is Custom controls rather than Track controls.
  final bool custom;

  /// The switch being edited.
  final PedalButton selected;

  final PedalSetup setup;

  /// The bank Custom controls is editing.
  final int bank;

  /// The selected Custom assignment's colour for each state.
  final Map<PedalLedState, PedalColor> customLeds;

  final VoidCallback onEditModePress;
  final VoidCallback onEditModeHold;
  final VoidCallback onEditRecordHold;
  final VoidCallback onEditTrackHold;
  final void Function({required bool hold}) onEditCustom;
  final ValueChanged<PedalLedState> onEditColor;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    if (custom) {
      // Custom controls: both gestures, both from the shared catalogue.
      final pair = setup.customFor(selected, bank: bank);
      String label(ControlAction? action) => action == null
          ? controlActionNone(l10n)
          : controlActionLabel(l10n, names, action);
      return PedalSetupEditor(
        title: title,
        press: PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          value: label(pair.press),
          width: PedalSetupField.compactWidth,
          onTap: () => onEditCustom(hold: false),
        ),
        hold: PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: label(pair.hold),
          width: PedalSetupField.compactWidth,
          onTap: () => onEditCustom(hold: true),
        ),
        // The pedal's own colours, beside the assignment they light for.
        trailing: [
          for (final MapEntry(key: state, value: color) in customLeds.entries)
            PedalColorField(
              key: Key('pedal_setup_color_${state.name}'),
              label: pedalLedStateLabel(l10n, state),
              color: color,
              width: PedalColorField.compactWidth,
              onTap: () => onEditColor(state),
            ),
        ],
      );
    }
    // Track controls: the fixed plate's three configurable gestures.
    //
    // Press is shown on every one of them and editable on none but MODE. A
    // field that simply disappeared on the fixed switches would leave the
    // performer guessing what the press does; the accepted design shows it
    // and dims it.
    final (press, hold) = switch (selected) {
      PedalButton.mode => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          value: controlActionLabel(l10n, names, ModeAction(setup.modePress)),
          onTap: onEditModePress,
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: setup.modeHold == null
              ? controlActionNone(l10n)
              : controlActionLabel(l10n, names, ModeAction(setup.modeHold!)),
          onTap: onEditModeHold,
        ),
      ),
      PedalButton.recPlay => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          value: controlActionLabel(
            l10n,
            names,
            const CommandAction(ControlCommand.recordPlay),
          ),
          onTap: null,
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: recordHoldLabel(l10n, setup.recordHold),
          onTap: onEditRecordHold,
        ),
      ),
      _ when kTrackSwitches.contains(selected) => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          // The track press is the mode's own track action — select and
          // advance in Tracks, mute in Mute, stomp the chain in FX — which is
          // exactly what this catalogue entry names.
          value: l10n.pedalSetupTrackPress,
          onTap: null,
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: trackHoldLabel(l10n, setup.trackHold),
          onTap: onEditTrackHold,
        ),
      ),
      _ => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          value: l10n.pedalSetupFixedNote,
          onTap: null,
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: controlActionNone(l10n),
          onTap: null,
        ),
      ),
    };
    return PedalSetupEditor(title: title, press: press, hold: hold);
  }
}

/// The accepted Clear custom assignments confirmation: what it covers, what
/// it keeps, and that it is undoable until Save.
Future<bool> showPedalClearDialog(BuildContext context) async {
  final surface = context.surface;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (context) => const _PedalClearDialog(),
  );
  return confirmed ?? false;
}

class _PedalClearDialog extends StatelessWidget {
  const _PedalClearDialog();

  static const double _panelWidth = 1040;
  static const double _pad = 40;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final body = TextStyle(
      color: surface.textSecondary,
      fontSize: 24,
      height: 1.35,
    );
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Material(
              key: const Key('pedal_setup_clear_dialog'),
              color: surface.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: surface.borderStrong),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: _panelWidth,
                child: Padding(
                  padding: const EdgeInsets.all(_pad),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppText(
                        l10n.pedalSetupClearTitle,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 38,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 28),
                      AppText(l10n.pedalSetupClearScope, style: body),
                      const SizedBox(height: 16),
                      AppText(l10n.pedalSetupClearKeeps, style: body),
                      const SizedBox(height: 16),
                      AppText(l10n.pedalSetupClearDraft, style: body),
                      const SizedBox(height: 36),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          LoopOutlinedButton(
                            key: const Key('pedal_setup_clear_cancel'),
                            width: 160,
                            label: l10n.pedalSetupCancel,
                            onTap: () => Navigator.of(context).pop(false),
                          ),
                          const SizedBox(width: 16),
                          LoopOutlinedButton(
                            key: const Key('pedal_setup_clear_confirm'),
                            width: 300,
                            tone: LoopButtonTone.accent,
                            label: l10n.pedalSetupClearConfirm,
                            onTap: () => Navigator.of(context).pop(true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The three contexts as the top bar's section tabs: peers, not a path, as
/// the Library draws Sessions and Audio.
///
/// While the setup loads they are drawn but not [enabled], so the top bar
/// does not change when the page arrives.
class _ContextTabs extends StatelessWidget {
  const _ContextTabs({
    required this.selected,
    required this.onOpen,
    this.enabled = true,
  });

  final PedalSetupContext selected;
  final ValueChanged<PedalSetupContext> onOpen;
  final bool enabled;

  /// Each tab's size: "Custom controls", the longest English label, at its
  /// full 24 px with the button's padding, and the top bar's height less its
  /// margins.
  static const double _width = 216;
  static const double _height = 64;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, (value, label)) in [
          (PedalSetupContext.tracks, l10n.pedalSetupContextTracks),
          (PedalSetupContext.custom, l10n.pedalSetupContextCustom),
          (PedalSetupContext.leds, l10n.pedalSetupContextLeds),
        ].indexed) ...[
          if (i > 0) SizedBox(width: context.spacing.md),
          LoopChoiceButton(
            key: Key('pedal_setup_context_${value.name}'),
            label: label,
            selected: selected == value,
            enabled: enabled,
            onTap: () => onOpen(value),
            width: _width,
            height: _height,
          ),
        ],
      ],
    );
  }
}

/// LED colors' modes, one tab each across the content box, every mode with
/// a colour map of its own.
class _LedModeTabs extends StatelessWidget {
  const _LedModeTabs({
    required this.selected,
    required this.onShow,
    required this.height,
  });

  final InteractionMode selected;
  final ValueChanged<InteractionMode> onShow;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gap = context.spacing.sm;
    final width = fillingCardWidth(
      width: LoopSettingsFrame.contentWidthOf(context),
      count: InteractionMode.values.length,
      gap: gap,
      minWidth: 0,
    );
    return Row(
      children: [
        for (final (i, mode) in InteractionMode.values.indexed) ...[
          if (i > 0) SizedBox(width: gap),
          LoopChoiceButton(
            key: Key('pedal_led_mode_${mode.name}'),
            label: pedalLedModeLabel(l10n, mode),
            selected: mode == selected,
            onTap: () => onShow(mode),
            width: width,
            height: height,
          ),
        ],
      ],
    );
  }
}
