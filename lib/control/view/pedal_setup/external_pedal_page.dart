import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_editor.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The accepted External pedals screen: what is plugged into each CTRL jack,
/// and what it does.
///
/// A subview of Pedals with a draft of its own. The accepted design saves both
/// ports together and discards unsaved edits on the way out, so leaving is a
/// decision the performer makes by leaving — not something an unrelated Save
/// elsewhere can commit for them.
class ExternalPedalPage extends StatefulWidget {
  /// Creates an [ExternalPedalPage].
  const ExternalPedalPage({super.key});

  @override
  State<ExternalPedalPage> createState() => _ExternalPedalPageState();
}

class _ExternalPedalPageState extends State<ExternalPedalPage> {
  /// The edit in progress, or `null` when nothing has been touched.
  ///
  /// Nullable for the reason the Pedals draft is: the setup arrives from
  /// settings asynchronously, so a draft forked at init would be the defaults
  /// on a rig that has a saved one.
  ExternalPedalSetup? _draft;

  ExternalJack _jack = ExternalJack.ctrl1;
  int _button = 0;
  bool _saved = false;

  /// The pen's insets inside the 1920 x 984 main area.
  static const double _left = 100;
  static const double _toolbarTop = 122;
  static const double _workspaceTop = 214;
  static const double _editorLeft = 680;

  /// The types this screen offers.
  ///
  /// Expression is in the model and not here: what it needs — calibration, and
  /// a list of destinations with their own endpoints — is its own part, and a
  /// type that opened an empty panel would be worse than one not offered yet.
  static const List<ExternalJackType> _types = [
    ExternalJackType.singleSwitch,
    ExternalJackType.dualSwitch,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    final setup = _draft ?? control.state.pedalSetup.external;
    final jack = setup.forJack(_jack);
    return Scaffold(
      body: LoopSettingsFrame(
        key: const Key('external_pedal_page'),
        crumb: l10n.pedalSetupCrumb,
        title: l10n.externalPedalsTitle,
        titleLeft: _left,
        onBack: () => Navigator.of(context).maybePop(),
        onStage: () => Navigator.of(context).popUntil((route) => route.isFirst),
        actions: _actions(context, control, setup),
        children: [
          Positioned(
            left: _left,
            top: _toolbarTop,
            child: _toolbar(context, jack),
          ),
          Positioned(
            left: _left,
            top: _workspaceTop,
            child: SizedBox(
              width: 1720,
              height: ExternalPedalArt.penSize.height,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    child: ExternalPedalArt(
                      type: jack.type,
                      selected: _button,
                      onSelect: (index) => setState(() => _button = index),
                      // Nothing drives a real jack yet: the contact dot is
                      // wired to the hardware it reports on, and there is no
                      // transport behind these jacks to report anything.
                      contacts: const {},
                    ),
                  ),
                  Positioned(
                    left: _editorLeft,
                    top: 0,
                    child: _editor(context, setup, jack),
                  ),
                ],
              ),
            ),
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
    ExternalPedalSetup setup,
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
              key: const Key('external_saved'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 22,
                height: 1,
              ),
            ),
          ),
        LoopOutlinedButton(
          key: const Key('external_cancel'),
          width: 125,
          label: l10n.pedalSetupCancel,
          onTap: dirty ? _cancel : null,
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('external_save'),
          width: 106,
          tone: LoopButtonTone.accent,
          label: l10n.pedalSetupSave,
          onTap: dirty ? () => _save(control, setup) : null,
        ),
      ],
    );
  }

  void _cancel() => setState(() {
    _draft = null;
    _saved = false;
  });

  void _save(ControlCubit control, ExternalPedalSetup setup) {
    unawaited(
      control.setPedalSetup(
        control.state.pedalSetup.copyWith(external: setup),
      ),
    );
    setState(() {
      _draft = null;
      _saved = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Which jack, and what is in it
  // ---------------------------------------------------------------------------

  Widget _toolbar(BuildContext context, ExternalJackSetup jack) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1720,
      height: 64,
      child: Row(
        children: [
          for (final (index, value) in ExternalJack.values.indexed) ...[
            if (index > 0) const SizedBox(width: 9),
            LoopChoiceButton(
              key: Key('external_jack_${value.name}'),
              label: switch (value) {
                ExternalJack.ctrl1 => l10n.externalJackCtrl1,
                ExternalJack.ctrl2 => l10n.externalJackCtrl2,
              },
              selected: value == _jack,
              onTap: () => _openJack(value),
              width: 144,
              height: 64,
            ),
          ],
          const Spacer(),
          for (final (index, type) in _types.indexed) ...[
            if (index > 0) const SizedBox(width: 9),
            LoopChoiceButton(
              key: Key('external_type_${type.name}'),
              label: _typeLabel(context, type),
              selected: type == jack.type,
              onTap: () => _setType(type),
              width: type == ExternalJackType.singleSwitch ? 202 : 185,
              height: 64,
            ),
          ],
        ],
      ),
    );
  }

  String _typeLabel(BuildContext context, ExternalJackType type) {
    final l10n = context.l10n;
    return switch (type) {
      ExternalJackType.expression => l10n.externalTypeExpression,
      ExternalJackType.singleSwitch => l10n.externalTypeSingle,
      ExternalJackType.dualSwitch => l10n.externalTypeDual,
    };
  }

  void _openJack(ExternalJack jack) {
    if (jack == _jack) return;
    // The other jack has its own type, which may have fewer switches than the
    // one being left.
    setState(() {
      _jack = jack;
      _button = 0;
    });
  }

  void _setType(ExternalJackType type) {
    final setup =
        _draft ?? context.read<ControlCubit>().state.pedalSetup.external;
    final jack = setup.forJack(_jack);
    if (type == jack.type) return;
    setState(() {
      _draft = setup.withJack(_jack, jack.copyWith(type: type));
      // A type with fewer switches cannot keep the second one selected.
      if (_button >= type.switchCount) _button = 0;
      _saved = false;
    });
  }

  // ---------------------------------------------------------------------------
  // The switch being edited
  // ---------------------------------------------------------------------------

  Widget _editor(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final button = jack.switchAt(_button);
    if (button == null) return const SizedBox(width: 1040, height: 722);
    final latching = button.hardware == ExternalSwitchHardware.latching;
    return SizedBox(
      width: 1040,
      height: ExternalPedalArt.penSize.height,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 149.41,
            child: AppText(
              l10n.externalButton(_button + 1),
              key: const Key('external_selected'),
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 36,
                height: 1,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 238.41,
            child: _hardware(context, setup, jack, button),
          ),
          Positioned(
            left: 0,
            top: 386.41,
            child: latching
                ? _changeField(context, setup, jack, button)
                : _gestureFields(context, setup, jack, button),
          ),
          Positioned(
            left: 0,
            top: 551.41,
            width: 1040,
            child: AppText(
              latching
                  ? l10n.externalChangeNote
                  : button.gestures.hold == null
                  ? l10n.externalPressNote
                  : l10n.externalHoldNote,
              key: const Key('external_note'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 23,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hardware(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      width: 1040,
      height: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            l10n.externalSwitchType,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 24,
              height: 1,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              for (final (index, hardware)
                  in ExternalSwitchHardware.values.indexed) ...[
                if (index > 0) const SizedBox(width: 9),
                LoopChoiceButton(
                  key: Key('external_hardware_${hardware.name}'),
                  label: switch (hardware) {
                    ExternalSwitchHardware.momentary =>
                      l10n.externalHardwareMomentary,
                    ExternalSwitchHardware.latching =>
                      l10n.externalHardwareLatching,
                  },
                  selected: hardware == button.hardware,
                  onTap: () => _write(
                    setup,
                    jack,
                    button.copyWith(hardware: hardware),
                  ),
                  width: hardware == ExternalSwitchHardware.momentary
                      ? 182
                      : 153,
                  height: 64,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _gestureFields(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) {
    final l10n = context.l10n;
    return SizedBox(
      width: 1040,
      height: 129,
      child: Row(
        children: [
          _field(
            context,
            key: const Key('external_press'),
            label: l10n.pedalSetupPress,
            action: button.gestures.press,
            onPick: (action) => _write(
              setup,
              jack,
              button.copyWith(gestures: button.gestures.withPress(action)),
            ),
          ),
          const SizedBox(width: 28),
          _field(
            context,
            key: const Key('external_hold'),
            label: l10n.pedalSetupHold,
            action: button.gestures.hold,
            onPick: (action) => _write(
              setup,
              jack,
              button.copyWith(gestures: button.gestures.withHold(action)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _changeField(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) => SizedBox(
    width: 1040,
    height: 129,
    child: _field(
      context,
      key: const Key('external_change'),
      label: context.l10n.externalOnChange,
      action: button.change,
      onPick: (action) => _write(
        setup,
        jack,
        button.copyWith(change: action, clearChange: action == null),
      ),
    ),
  );

  /// One gesture's field: its name over the action it carries.
  Widget _field(
    BuildContext context, {
    required Key key,
    required String label,
    required ControlAction? action,
    required ValueChanged<ControlAction?> onPick,
  }) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    return PedalSetupField(
      key: key,
      label: label,
      width: 506,
      height: 129,
      buttonHeight: 80,
      valueFontSize: 28,
      value: action == null
          ? controlActionNone(l10n)
          : controlActionLabel(l10n, names, action),
      onTap: () => unawaited(_pick(label, action, onPick)),
    );
  }

  Future<void> _pick(
    String gesture,
    ControlAction? current,
    ValueChanged<ControlAction?> onPick,
  ) async {
    final l10n = context.l10n;
    final names = context.read<TracksCubit>().state.names;
    final chosen = await showControlActionPicker(
      context,
      title: l10n.pedalSetupChooser(
        l10n.externalButton(_button + 1),
        gesture,
      ),
      current: current,
      trackNames: names,
    );
    if (chosen == null || !mounted) return;
    onPick(chosen.value);
  }

  void _write(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) => setState(() {
    _draft = setup.withJack(_jack, jack.withSwitch(_button, button));
    _saved = false;
  });
}
