import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_palette.dart';
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
import 'package:segno/theme/theme.dart';

/// Which half of the plate the setup is editing.
enum PedalSetupContext {
  /// The fixed plate, and the few gestures configurable on it.
  tracks,

  /// The free map: eight switches, each with its own Press and Hold.
  custom,

  /// The ten indicators, and which colour each of them uses.
  leds,
}

/// The accepted Pedals setup (Layout A): the hardware map stays on screen
/// while the chosen switch's Press and Hold are edited together.
///
/// One draft, two contexts, one Save. Every edit lands in a local draft and
/// nothing reaches the rig until Save, which is what lets Clear custom
/// assignments offer Restore and lets Cancel mean something. An unfinished
/// draft cannot ride out on someone else's save either: it lives here, not in
/// the cubit.
class PedalSetupPage extends StatefulWidget {
  /// Creates a [PedalSetupPage].
  const PedalSetupPage({super.key});

  @override
  State<PedalSetupPage> createState() => _PedalSetupPageState();
}

class _PedalSetupPageState extends State<PedalSetupPage> {
  /// The edit in progress, or `null` when nothing has been touched since the
  /// last Save or Cancel.
  ///
  /// Nullable rather than forked at init: the setup is restored from settings
  /// asynchronously, so a draft forked in `initState` would be the defaults
  /// on a rig that has a saved setup. While it is null the page reads the
  /// live one, and the first edit forks from whatever is current then.
  PedalSetup? _draft;

  /// The Custom assignments Clear took away, until the draft is saved or
  /// cancelled.
  ///
  /// The assignments alone, not the whole setup: the accepted design says
  /// recovery must not rewrite LED colours or anything else edited after the
  /// clear, so Restore puts these back INTO the current draft rather than
  /// rewinding it.
  Map<PedalBindingKey, ControlGesturePair>? _cleared;

  PedalSetupContext _context = PedalSetupContext.tracks;

  /// The switch being edited. MODE in Track controls (the only one there with
  /// both gestures free) and the first track switch in Custom controls, which
  /// is where the study opens each of them.
  PedalButton _selected = PedalButton.mode;

  int _bank = 0;

  bool _saved = false;

  /// The pen's insets inside the 1920 x 984 main area.
  static const double _left = 100;
  static const double _controlsTop = 120;
  static const double _mapTop = 218;
  static const double _editorTop = 724;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    final setup = _draft ?? control.state.pedalSetup;
    return Scaffold(
      body: LoopSettingsFrame(
        key: const Key('pedal_setup_page'),
        crumb: l10n.pedalSetupCrumb,
        title: l10n.pedalSetupTitle,
        titleLeft: _left,
        onBack: () => Navigator.of(context).maybePop(),
        onStage: () => Navigator.of(context).popUntil((route) => route.isFirst),
        actions: _actions(context, control, setup),
        children: [
          Positioned(
            left: _left,
            top: _controlsTop,
            child: _contexts(context),
          ),
          Positioned(
            left: _left,
            top: _mapTop,
            // The pills are lit by the RIG, from the very frame the pedal is
            // rendering — not re-projected here, which would pair an engine
            // state with an overlay that had not caught up with it and read a
            // rig that never existed. It changes only when the frame does.
            child: ValueListenableBuilder<PedalStateFrame>(
              valueListenable: context.read<PedalRepository>().lastFrame,
              builder: (context, frame, _) => PedalSetupMap(
                selected: _selectedGroup,
                editable: _editable,
                onSelect: (button) => setState(() => _selected = button),
                bank: _mapBank,
                bankSelectable: _context == PedalSetupContext.custom,
                onToggleBank: () => setState(() => _bank = 1 - _bank),
                // The DRAFT's palette, so a colour is on the plate before
                // Save; the frame's own colours are the saved ones.
                palette: setup.palette,
                lit: {
                  for (final button in PedalButton.values)
                    if (frame.isLit(button)) button,
                },
              ),
            ),
          ),
          Positioned(
            left: _left,
            top: _editorTop,
            child: _editor(context, setup),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Titlebar
  // ---------------------------------------------------------------------------

  Widget _actions(
    BuildContext context,
    ControlCubit control,
    PedalSetup setup,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final dirty = _draft != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_saved && !dirty)
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
        if (_context == PedalSetupContext.custom) ...[
          LoopOutlinedButton(
            key: const Key('pedal_setup_clear_custom'),
            width: 380,
            label: l10n.pedalSetupClearCustom,
            onTap: setup.hasCustomAssignments
                ? () => unawaited(_confirmClear(setup))
                : null,
          ),
          const SizedBox(width: 16),
          if (_cleared != null) ...[
            LoopOutlinedButton(
              key: const Key('pedal_setup_restore_custom'),
              width: 300,
              label: l10n.pedalSetupRestoreCustom,
              onTap: () => _restoreCleared(setup),
            ),
            const SizedBox(width: 16),
          ],
        ],
        LoopOutlinedButton(
          key: const Key('pedal_setup_cancel'),
          width: 125,
          label: l10n.pedalSetupCancel,
          onTap: dirty ? _cancel : null,
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('pedal_setup_save'),
          width: 125,
          tone: LoopButtonTone.accent,
          label: l10n.pedalSetupSave,
          onTap: dirty ? () => _save(control, setup) : null,
        ),
      ],
    );
  }

  void _cancel() => setState(() {
    _draft = null;
    _cleared = null;
    _saved = false;
  });

  void _save(ControlCubit control, PedalSetup setup) {
    unawaited(control.setPedalSetup(setup));
    setState(() {
      _draft = null;
      _cleared = null;
      _saved = true;
    });
  }

  void _restoreCleared(PedalSetup setup) => setState(() {
    _draft = setup.copyWith(custom: _cleared);
    _cleared = null;
    _saved = false;
  });

  Future<void> _confirmClear(PedalSetup setup) async {
    final confirmed = await showPedalClearDialog(context);
    if (!confirmed || !mounted) return;
    setState(() {
      // What Restore puts back is the DRAFT's assignments at the moment of the
      // clear, not the saved ones, so clearing after other edits and then
      // restoring keeps those edits.
      _cleared = setup.custom;
      _draft = setup.clearedCustom();
      _saved = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Contexts
  // ---------------------------------------------------------------------------

  Widget _contexts(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1720,
      height: 72,
      child: Row(
        children: [
          LoopChoiceButton(
            key: const Key('pedal_setup_context_tracks'),
            label: l10n.pedalSetupContextTracks,
            selected: _context == PedalSetupContext.tracks,
            onTap: () => _openContext(PedalSetupContext.tracks),
            width: 202,
            height: 64,
          ),
          const SizedBox(width: 8),
          LoopChoiceButton(
            key: const Key('pedal_setup_context_custom'),
            label: l10n.pedalSetupContextCustom,
            selected: _context == PedalSetupContext.custom,
            onTap: () => _openContext(PedalSetupContext.custom),
            width: 225,
            height: 64,
          ),
          const Spacer(),
          // The jacks are not a context of this screen: they are their own
          // screen, with their own draft and their own Save.
          LoopChoiceButton(
            key: const Key('pedal_setup_external'),
            label: l10n.externalPedalsTitle,
            selected: false,
            onTap: () => unawaited(openExternalPedals()),
            width: 216,
            height: 64,
          ),
          const SizedBox(width: 23),
          // Away from the pair, at the far end of the row: the colours are not
          // a third set of assignments to choose between, they are a different
          // question about the same ten switches.
          LoopChoiceButton(
            key: const Key('pedal_setup_context_leds'),
            label: l10n.pedalSetupContextLeds,
            selected: _context == PedalSetupContext.leds,
            onTap: () => _openContext(PedalSetupContext.leds),
            width: 168,
            height: 64,
          ),
        ],
      ),
    );
  }

  void _openContext(PedalSetupContext next) {
    if (next == _context) return;
    setState(() {
      _context = next;
      // Land on a switch this context can actually edit: keeping the old
      // selection would open on a dimmed cap with nothing under it.
      _selected = switch (next) {
        PedalSetupContext.tracks => PedalButton.mode,
        PedalSetupContext.custom => PedalButton.track1,
        // Every switch has a colour, so whichever one was being edited can
        // keep being the one on screen.
        PedalSetupContext.leds => _selected,
      };
    });
  }

  /// The bank the MAP is showing.
  ///
  /// Always A in Track controls: nothing there is per-bank — one hold covers
  /// all four track switches — so a map reading TRACK 5-8 would name a bank
  /// that context has no way to leave, since BANK is dimmed there.
  int? get _mapBank => switch (_context) {
    PedalSetupContext.custom => _bank,
    PedalSetupContext.tracks => 0,
    // No bank at all: a colour belongs to the switch, not to what the switch
    // is currently driving, so naming a bank here would promise a per-bank
    // colour that does not exist.
    PedalSetupContext.leds => null,
  };

  /// The switches this context can edit.
  Set<PedalButton> get _editable => switch (_context) {
    // Stop, Undo, Clear and Bank do one thing here and keep it: the accepted
    // design dims them rather than offering an assignment it would refuse.
    PedalSetupContext.tracks => {
      PedalButton.mode,
      PedalButton.recPlay,
      ...kTrackSwitches,
    },
    // Everything the binding model can key, which is every switch but MODE
    // and BANK — the two that must never stop being the way out and the way
    // to the other four tracks.
    PedalSetupContext.custom => {
      for (final button in PedalButton.values)
        if (!PedalBindingKey.unbindable.contains(button)) button,
    },
    // All ten, including the switches whose action is fixed: the accepted
    // design is explicit that colour is configurable on every one of them.
    PedalSetupContext.leds => PedalButton.values.toSet(),
  };

  /// The switches drawn as selected.
  ///
  /// In Track controls the four track caps light together, because one hold
  /// setting covers all four and marking only the tapped one would promise a
  /// per-switch assignment that does not exist.
  Set<PedalButton> get _selectedGroup =>
      _context == PedalSetupContext.tracks && kTrackSwitches.contains(_selected)
      ? kTrackSwitches.toSet()
      : {_selected};

  // ---------------------------------------------------------------------------
  // The editor
  // ---------------------------------------------------------------------------

  Widget _editor(BuildContext context, PedalSetup setup) => switch (_context) {
    PedalSetupContext.tracks => _tracksEditor(context, setup),
    PedalSetupContext.custom => _customEditor(context, setup),
    PedalSetupContext.leds => _ledEditor(context, setup),
  };

  /// LED colors: one switch, the palette, and a way to grow it.
  Widget _ledEditor(BuildContext context, PedalSetup setup) => PedalLedEditor(
    title: _controlName(context),
    palette: setup.palette,
    button: _selected,
    onChoose: (entry) => setState(
      () => _draft = setup.copyWith(
        palette: setup.palette.withChoice(_selected, entry),
      ),
    ),
    onAdd: () => unawaited(_mixColor(setup, editing: null)),
    onEdit: (entry) => unawaited(_mixColor(setup, editing: entry)),
  );

  /// Track controls: the fixed plate's three configurable gestures.
  ///
  /// Press is shown on every one of them and editable on none but MODE. A
  /// field that simply disappeared on the fixed switches would leave the
  /// performer guessing what the press does; the accepted design shows it and
  /// dims it.
  Widget _tracksEditor(BuildContext context, PedalSetup setup) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final (press, hold) = switch (_selected) {
      PedalButton.mode => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          value: controlActionLabel(l10n, names, ModeAction(setup.modePress)),
          onTap: () => unawaited(_editModePress(setup)),
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: setup.modeHold == null
              ? controlActionNone(l10n)
              : controlActionLabel(l10n, names, ModeAction(setup.modeHold!)),
          onTap: () => unawaited(_editModeHold(setup)),
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
          onTap: () => unawaited(_editRecordHold(setup)),
        ),
      ),
      _ when kTrackSwitches.contains(_selected) => (
        PedalSetupField(
          key: const Key('pedal_setup_press'),
          label: l10n.pedalSetupPress,
          // The track press is the mode's own track action — select and
          // advance in Tracks, mute in Mute, stomp the chain in FX — which is
          // exactly what this catalogue entry names.
          value: controlActionLabel(
            l10n,
            names,
            TrackPedalAction(_selectedChannel),
          ),
          onTap: null,
        ),
        PedalSetupField(
          key: const Key('pedal_setup_hold'),
          label: l10n.pedalSetupHold,
          value: trackHoldLabel(l10n, setup.trackHold),
          onTap: () => unawaited(_editTrackHold(setup)),
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
    return PedalSetupEditor(
      title: _controlName(context),
      press: press,
      hold: hold,
    );
  }

  /// Custom controls: both gestures, both from the shared catalogue.
  Widget _customEditor(BuildContext context, PedalSetup setup) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final pair = setup.customFor(_selected, bank: _bank);
    String label(ControlAction? action) => action == null
        ? controlActionNone(l10n)
        : controlActionLabel(l10n, names, action);
    return PedalSetupEditor(
      title: _controlName(context),
      press: PedalSetupField(
        key: const Key('pedal_setup_press'),
        label: l10n.pedalSetupPress,
        value: label(pair.press),
        onTap: () => unawaited(_editCustom(setup, hold: false)),
      ),
      hold: PedalSetupField(
        key: const Key('pedal_setup_hold'),
        label: l10n.pedalSetupHold,
        value: label(pair.hold),
        onTap: () => unawaited(_editCustom(setup, hold: true)),
      ),
    );
  }

  int get _selectedChannel => pedalTrackChannel(_selected, _mapBank ?? 0) ?? 0;

  String _controlName(BuildContext context) {
    final l10n = context.l10n;
    if (_context == PedalSetupContext.tracks &&
        kTrackSwitches.contains(_selected)) {
      return l10n.pedalSetupTrackGroup;
    }
    return pedalSwitchLabel(l10n, _selected, _mapBank ?? 0);
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

  /// Opens the colour editor: [editing] names the palette entry being changed,
  /// or `null` to mix a new one.
  Future<void> _mixColor(
    PedalSetup setup, {
    required CustomPaletteEntry? editing,
  }) async {
    final palette = setup.palette;
    final number = editing?.number ?? palette.nextCustomNumber;
    final chosen = await showPedalColorDialog(
      context,
      // A new colour starts mid-space rather than on the switch's current one,
      // which is white almost every time: white has no hue and no saturation,
      // so the hue slider would move with nothing happening on screen.
      initial: editing == null
          ? PedalColor.blue
          : palette.colorOf(editing) ?? PedalColor.defaultColor,
      editing: editing != null,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      // Adding puts the new colour on the switch that asked for it. Editing
      // touches no assignment at all: the colour moves, and every switch
      // pointing at it moves with it, which is what makes a custom colour
      // reusable.
      var next = palette.withCustom(number, chosen);
      if (editing == null) {
        next = next.withChoice(_selected, CustomPaletteEntry(number));
      }
      _draft = setup.copyWith(palette: next);
    });
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
