import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/pedal_setup/expression_calibration_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_controls_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_position_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_target_picker.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_editor.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
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

/// Which body the screen is showing.
///
/// The accepted design draws the pickers and the calibration as whole views
/// rather than panels over the page — the lists behind them are as long as the
/// rig is — so they are states of this page, not routes of their own. Back
/// steps through them rather than leaving, which is what keeps one draft.
enum _ExternalView {
  /// The jack, its type, and what it carries.
  main,

  /// Teaching an expression pedal its travel.
  calibrate,

  /// Choosing where a new control lives.
  destinations,

  /// Choosing the control itself.
  controls,
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

  _ExternalView _view = _ExternalView.main;

  /// Which tab of the destination picker is open, kept across visits so adding
  /// two controls on one input does not start from the first tab twice.
  FxDestinationKind _kind = FxDestinationKind.liveInput;

  /// The destination whose controls are open.
  ExpressionDestination? _destination;

  /// The mapping whose range is open.
  ControlValueTarget? _selected;

  /// The mapping being repointed, so choosing a control replaces it in place
  /// instead of adding a second row.
  ControlValueTarget? _replacing;

  /// The travel being captured: the raw readings at each end, staged until Use
  /// calibration puts them in the draft.
  double? _captureHeel;
  double? _captureToe;

  /// The pen's insets inside the 1920 x 984 main area.
  static const double _left = 100;
  static const double _toolbarTop = 122;
  static const double _workspaceTop = 214;
  static const double _editorLeft = 680;

  /// The types this screen offers, in the pen's order.
  static const List<ExternalJackType> _types = [
    ExternalJackType.expression,
    ExternalJackType.singleSwitch,
    ExternalJackType.dualSwitch,
  ];

  /// The pen's expression workspace: a narrow column for the pedal beside a
  /// wide one for what it does. Taller in the calibrate view, which has no
  /// toolbar above it.
  static const double _expressionTop = 226;
  static const double _calibrateTop = 134;
  static const double _expressionHeight = 710;
  static const double _calibrateHeight = 802;
  static const double _columnGap = 90;

  /// The pen's picker area: the whole main area under the titlebar.
  static const double _pickerTop = 122;
  static const double _pickerHeight = 814;

  @override
  void dispose() {
    // Leaving with the calibrate view open must not leave dispatch suppressed:
    // the page is gone, and nothing else would ever turn it back on.
    _control?.setCalibrating(null);
    super.dispose();
  }

  /// The cubit, remembered so [dispose] can reach it after the element is
  /// detached — `context.read` is not available by then.
  ControlCubit? _control;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    _control = control;
    final setup = _draft ?? control.state.pedalSetup.external;
    final jack = setup.forJack(_jack);
    final main = _view == _ExternalView.main;
    return Scaffold(
      body: LoopSettingsFrame(
        key: const Key('external_pedal_page'),
        crumb: l10n.pedalSetupCrumb,
        title: switch (_view) {
          _ExternalView.main => l10n.externalPedalsTitle,
          _ExternalView.calibrate => l10n.expressionCalibrateTitle,
          _ExternalView.destinations => l10n.expressionChooseDestination,
          _ExternalView.controls => l10n.expressionChooseControl,
        },
        titleLeft: _left,
        onBack: _back,
        onStage: () => Navigator.of(context).popUntil((route) => route.isFirst),
        // Save and Cancel belong to the page's one draft, and the subviews are
        // steps inside it: a Save offered from a half-chosen control would
        // commit a decision the performer has not finished making.
        actions: main ? _actions(context, control, setup) : null,
        children: [
          if (main)
            Positioned(
              left: _left,
              top: _toolbarTop,
              child: _toolbar(context, jack),
            ),
          ..._body(context, setup, jack),
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
  ) => switch (_view) {
    _ExternalView.main when jack.type == ExternalJackType.expression => [
      Positioned(
        left: _left,
        top: _expressionTop,
        child: _expressionWorkspace(context, setup, jack),
      ),
    ],
    _ExternalView.main => [
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
    _ExternalView.calibrate => [
      Positioned(
        left: _left,
        top: _calibrateTop,
        child: _calibrateWorkspace(context, setup, jack),
      ),
    ],
    _ExternalView.destinations => [
      Positioned(
        left: _left,
        top: _pickerTop,
        width: 1720,
        height: _pickerHeight,
        child: ExpressionDestinationPicker(
          destinations: _destinations(context),
          kind: _kind,
          onKind: (kind) => setState(() => _kind = kind),
          onOpen: (destination) => setState(() {
            _destination = destination;
            _view = _ExternalView.controls;
          }),
        ),
      ),
    ],
    _ExternalView.controls => [
      Positioned(
        left: _left,
        top: _pickerTop,
        width: 1720,
        height: _pickerHeight,
        child: ExpressionControlPicker(
          // An empty destination is still a destination: the picker says so
          // rather than this page guessing its way back a view.
          destination:
              _destination ??
              const ExpressionDestination(
                id: '',
                kind: FxDestinationKind.liveInput,
                label: '',
                groups: [],
              ),
          taken: {
            for (final mapping in jack.expression.mappings)
              if (mapping.target != _replacing) mapping.target,
          },
          onPick: (target) => _pickControl(setup, jack, target),
        ),
      ),
    ],
  };

  // ---------------------------------------------------------------------------
  // The expression pedal
  // ---------------------------------------------------------------------------

  /// The live readings, straight from the repository.
  ///
  /// Not from the control state: a pedal under a foot reports many times a
  /// second, and a screen that rebuilt its whole control surface for each one
  /// would pay for a readout. This rebuilds the workspace and nothing else.
  ValueListenable<PedalExpressionPositions> get _positions =>
      context.read<PedalRepository>().expressionPositions;

  PedalExpressionJack get _wireJack => switch (_jack) {
    ExternalJack.ctrl1 => PedalExpressionJack.ctrl1,
    ExternalJack.ctrl2 => PedalExpressionJack.ctrl2,
  };

  Widget _expressionWorkspace(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
  ) {
    final expression = jack.expression;
    return SizedBox(
      width: 1720,
      height: _expressionHeight,
      child: ValueListenableBuilder<PedalExpressionPositions>(
        valueListenable: _positions,
        builder: (context, positions, _) {
          final raw = positions.of(_wireJack);
          final position = raw == null
              ? null
              : expression.calibration?.positionOf(raw);
          return Row(
            children: [
              ExpressionPositionPanel(
                raw: raw,
                calibration: expression.calibration,
                height: _expressionHeight,
                onCalibrate: () => _openCalibrate(context),
              ),
              const SizedBox(width: _columnGap),
              SizedBox(
                height: _expressionHeight,
                child: ExpressionControlsPanel(
                  rows: _rows(context, expression),
                  selected: _openTarget(expression),
                  position: position,
                  onSelect: (target) => setState(() => _selected = target),
                  onAdd: () => setState(() {
                    _replacing = null;
                    _view = _ExternalView.destinations;
                  }),
                  onChange: () => setState(() {
                    _replacing = _openTarget(expression);
                    _view = _ExternalView.destinations;
                  }),
                  onRemove: () => _removeControl(setup, jack),
                  onEndpoint: ({required isHeel, required value}) =>
                      _moveEndpoint(setup, jack, isHeel: isHeel, value: value),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _calibrateWorkspace(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
  ) => SizedBox(
    width: 1720,
    height: _calibrateHeight,
    child: ValueListenableBuilder<PedalExpressionPositions>(
      valueListenable: _positions,
      builder: (context, positions, _) {
        final raw = positions.of(_wireJack);
        // The link dropped with captures in hand: they were readings from a
        // board that is no longer there, and the accepted design discards them
        // rather than letting half of an old travel meet half of a new one.
        if (raw == null && (_captureHeel != null || _captureToe != null)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _captureHeel = null;
              _captureToe = null;
            });
          });
        }
        return Row(
          children: [
            ExpressionPositionPanel(
              raw: raw,
              calibration: jack.expression.calibration,
              height: _calibrateHeight,
            ),
            const SizedBox(width: _columnGap),
            SizedBox(
              height: _calibrateHeight,
              child: ExpressionCalibrationPanel(
                heel: _captureHeel,
                toe: _captureToe,
                connected: raw != null,
                onCapture: ({required isHeel}) => setState(() {
                  if (isHeel) {
                    _captureHeel = raw;
                  } else {
                    _captureToe = raw;
                  }
                }),
                onCancel: _leaveCalibrate,
                onUse: (travel) => _useCalibration(setup, jack, travel),
              ),
            ),
          ],
        );
      },
    ),
  );

  /// The mapping whose range is open: the selected one, or the first row when
  /// nothing has been selected yet.
  ControlValueTarget? _openTarget(ExternalExpressionSetup expression) {
    final chosen = _selected;
    if (chosen != null && expression.mappingFor(chosen) != null) return chosen;
    return expression.mappings.isEmpty
        ? null
        : expression.mappings.first.target;
  }

  List<ExpressionRow> _rows(
    BuildContext context,
    ExternalExpressionSetup expression,
  ) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final names = context.watch<TracksCubit>().state.names;
    return [
      for (final mapping in expression.mappings)
        ExpressionRow(
          mapping: mapping,
          destination: expressionTargetName(
            l10n,
            names,
            looper,
            mapping.target,
          ).destination,
          control: expressionRowName(l10n, names, looper, mapping.target),
          available: looper.valueTargetResolves(mapping.target),
        ),
    ];
  }

  List<ExpressionDestination> _destinations(BuildContext context) =>
      expressionDestinations(
        context.l10n,
        context.watch<TracksCubit>().state.names,
        context.read<LooperRepository>(),
      );

  void _openCalibrate(BuildContext context) {
    // Told before the view opens, not after: a sweep arriving between the two
    // would be dispatched by a pedal the performer is already teaching.
    context.read<ControlCubit>().setCalibrating(_jack);
    setState(() {
      _view = _ExternalView.calibrate;
      _captureHeel = null;
      _captureToe = null;
    });
  }

  void _leaveCalibrate() {
    context.read<ControlCubit>().setCalibrating(null);
    setState(() {
      _view = _ExternalView.main;
      _captureHeel = null;
      _captureToe = null;
    });
  }

  void _useCalibration(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExpressionCalibration travel,
  ) {
    context.read<ControlCubit>().setCalibrating(null);
    setState(() {
      _draft = setup.withJack(
        _jack,
        jack.copyWith(
          expression: jack.expression.copyWith(calibration: travel),
        ),
      );
      _view = _ExternalView.main;
      _captureHeel = null;
      _captureToe = null;
      _saved = false;
    });
  }

  void _pickControl(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ControlValueTarget target,
  ) {
    final replacing = _replacing;
    final expression = jack.expression;
    // Repointing keeps the endpoints: the performer chose how far this pedal
    // should travel, and a different destination does not change that.
    final kept = replacing == null ? null : expression.mappingFor(replacing);
    final next = replacing == null
        ? expression.withMapping(ExpressionMapping(target: target))
        : expression
              .withoutMapping(replacing)
              .withMapping(
                ExpressionMapping(
                  target: target,
                  heel: kept?.heel ?? 0,
                  toe: kept?.toe ?? 1,
                ),
              );
    setState(() {
      _draft = setup.withJack(_jack, jack.copyWith(expression: next));
      _selected = target;
      _replacing = null;
      _view = _ExternalView.main;
      _saved = false;
    });
  }

  void _removeControl(ExternalPedalSetup setup, ExternalJackSetup jack) {
    final target = _openTarget(jack.expression);
    if (target == null) return;
    final next = jack.expression.withoutMapping(target);
    setState(() {
      _draft = setup.withJack(_jack, jack.copyWith(expression: next));
      _selected = next.mappings.isEmpty ? null : next.mappings.first.target;
      _saved = false;
    });
  }

  void _moveEndpoint(
    ExternalPedalSetup setup,
    ExternalJackSetup jack, {
    required bool isHeel,
    required double value,
  }) {
    final target = _openTarget(jack.expression);
    if (target == null) return;
    final mapping = jack.expression.mappingFor(target);
    if (mapping == null) return;
    final next = jack.expression.withMapping(
      isHeel ? mapping.copyWith(heel: value) : mapping.copyWith(toe: value),
    );
    setState(() {
      _draft = setup.withJack(_jack, jack.copyWith(expression: next));
      _saved = false;
    });
  }

  /// Back steps out of a subview before it leaves the page.
  void _back() {
    switch (_view) {
      case _ExternalView.main:
        Navigator.of(context).maybePop();
      case _ExternalView.calibrate:
        _leaveCalibrate();
      case _ExternalView.destinations:
        setState(() {
          _view = _ExternalView.main;
          _replacing = null;
        });
      case _ExternalView.controls:
        setState(() => _view = _ExternalView.destinations);
    }
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
              width: switch (type) {
                ExternalJackType.expression => 181,
                ExternalJackType.singleSwitch => 203,
                ExternalJackType.dualSwitch => 185,
              },
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
      // The other jack sweeps its own controls, and may sweep none.
      _selected = null;
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
      // Every type keeps its own assignments, so this selects nothing: the
      // expression panel opens on its own first row.
      _selected = null;
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
