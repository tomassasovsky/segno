import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/control_availability_view.dart';
import 'package:segno/control/view/pedal_setup/expression_calibration_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_controls_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_position_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_target_picker.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
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

/// Which step of choosing a button's new control is showing.
enum _ButtonPick {
  /// Where the control lives.
  destinations,

  /// The control itself.
  controls,
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

enum _ActionSlot { press, hold, change }

/// The pen's offsets inside the frame's content box, whose full width the
/// page takes.
const double _toolbarTop = 122;
const double _workspaceTop = 214;
const double _editorLeft = 680;

/// The pen's workspace: the pedal art and the button editor (or the
/// expression panels), kept at the pen's 1720 from the content box's left
/// edge. Their controls are laid out to these widths.
const double _workspaceWidth = 1720;

/// The button editor's width, from [_editorLeft] to the workspace's end.
const double _editorWidth = _workspaceWidth - _editorLeft;

/// One of the editor's two gesture fields, the pen's 506.
const double _fieldWidth = 506;

/// The types this screen offers, in the pen's order.
const List<ExternalJackType> _types = [
  ExternalJackType.expression,
  ExternalJackType.singleSwitch,
  ExternalJackType.dualSwitch,
];

/// The pen's expression workspace: a narrow column for the pedal beside a
/// wide one for what it does. Taller in the calibrate view, which has no
/// toolbar above it.
const double _expressionTop = 226;
const double _calibrateTop = 134;
const double _expressionHeight = 710;
const double _calibrateHeight = 802;
const double _columnGap = 90;

/// The pen's picker area: the whole main area under the titlebar.
const double _pickerTop = 122;
const double _pickerHeight = 814;

class _ExternalPedalPageState extends State<ExternalPedalPage> {
  late final Future<void> _initialLoad;

  @override
  void initState() {
    super.initState();
    _initialLoad = context.read<ControlCubit>().load();
  }

  /// The edit in progress, or `null` when nothing has been touched.
  ///
  /// Nullable for the reason the Pedals draft is: the setup arrives from
  /// settings asynchronously, so a draft forked at init would be the defaults
  /// on a rig that has a saved one.
  ExternalPedalSetup? _draft;

  PedalCtrlJack _jack = PedalCtrlJack.ctrl1;
  int _button = 0;
  bool _saved = false;
  bool _saving = false;
  bool _saveFailed = false;
  int _editGeneration = 0;

  _ExternalView _view = _ExternalView.main;

  /// Which tab of the destination picker is open, kept across visits so adding
  /// two controls on one input does not start from the first tab twice.
  ExpressionDestinationKind _kind = ExpressionDestinationKind.liveInput;

  /// The destination whose controls are open.
  ExpressionDestination? _destination;

  /// The mapping whose range is open.
  ControlValueTarget? _selected;

  /// The mapping being repointed, so choosing a control replaces it in place
  /// instead of adding a second row.
  ControlValueTarget? _replacing;

  /// The travel being captured: the raw readings at each end, staged until Use
  /// calibration puts them in the draft.
  int? _captureHeel;
  int? _captureToe;

  /// The cubit, remembered so [dispose] can reach it after the element is
  /// detached — `context.read` is not available by then.
  ControlCubit? _control;
  Object? _calibrationToken;

  /// Whether a button's editor shows its actions or its controls.
  bool _showControls = false;

  /// Where choosing a button's new control has got to: `null` when not
  /// choosing, the destination list, or one destination's controls.
  _ButtonPick? _buttonPick;

  /// The destination whose controls are listed for a button.
  ExpressionDestination? _buttonDestination;

  /// The button control whose rule is open.
  Object? _buttonControl;
  Object? _replacingButtonControl;

  @override
  void dispose() {
    _endCalibration();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    _control = control;
    final setup = _draft ?? control.state.pedalSetup.external;
    final jack = setup.forJack(_jack);
    final main = _view == _ExternalView.main;
    final dirty = _draft != null;
    return FutureBuilder<void>(
      future: _initialLoad,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError) {
          return Scaffold(
            body: LoopSettingsFrame(
              crumb: l10n.pedalSetupCrumb,
              title: l10n.externalPedalsTitle,
              onBack: () => Navigator.of(context).maybePop(),
              onStage: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              children: [
                Positioned.fill(
                  child: Center(
                    child: AppText(
                      snapshot.hasError
                          ? l10n.pedalSetupLoadFailed
                          : l10n.pedalSetupLoading,
                      key: const Key('external_loading'),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return PopScope(
          canPop: !_saving,
          child: AbsorbPointer(
            absorbing: _saving,
            child: ExcludeFocus(
              excluding: _saving,
              child: Scaffold(
                body: LoopSettingsFrame(
                  key: const Key('external_pedal_page'),
                  crumb: l10n.pedalSetupCrumb,
                  title: switch (_view) {
                    _ExternalView.main => l10n.externalPedalsTitle,
                    _ExternalView.calibrate => l10n.expressionCalibrateTitle,
                    _ExternalView.destinations =>
                      l10n.expressionChooseDestination,
                    _ExternalView.controls => l10n.expressionChooseControl,
                  },
                  onBack: _back,
                  onStage: () {
                    if (!_saving) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  },
                  // Save and Cancel belong to the page's one draft. Subviews
                  // are steps inside it; saving mid-choice would commit an
                  // unfinished decision.
                  actions: main
                      ? _SaveActions(
                          state: control.state,
                          dirty: dirty,
                          saved: _saved,
                          saveFailed: _saveFailed,
                          onCancel: dirty && !_saving ? _cancel : null,
                          onSave:
                              (dirty ||
                                      control.state.pedalSetupRuntimeUnsaved ||
                                      control
                                          .state
                                          .pedalSetupPersistenceUncertain ||
                                      control.state.pedalSetupUnavailable) &&
                                  !_saving
                              ? () => unawaited(_save(control, setup))
                              : null,
                        )
                      : null,
                  children: [
                    if (main)
                      Positioned(
                        left: 0,
                        top: _toolbarTop,
                        child: _JackToolbar(
                          jack: _jack,
                          type: jack.type,
                          onJack: _openJack,
                          onType: _setType,
                        ),
                      ),
                    switch (_view) {
                      _ExternalView.main
                          when jack.type == ExternalJackType.expression =>
                        Positioned(
                          left: 0,
                          top: _expressionTop,
                          child: _ExpressionWorkspace(
                            jack: _jack,
                            expression: jack.expression,
                            selected: _openTarget(jack.expression),
                            onCalibrate: () => _openCalibrate(context),
                            onSelect: (target) =>
                                setState(() => _selected = target),
                            onAdd: () => setState(() {
                              _replacing = null;
                              _view = _ExternalView.destinations;
                            }),
                            onChange: () => setState(() {
                              _replacing = _openTarget(jack.expression);
                              _view = _ExternalView.destinations;
                            }),
                            onRemove: () => _removeControl(setup, jack),
                            onEndpoint: ({required isHeel, required value}) =>
                                _moveEndpoint(
                                  setup,
                                  jack,
                                  isHeel: isHeel,
                                  value: value,
                                ),
                            onEndpointCancel:
                                ({required isHeel, required value}) =>
                                    _moveEndpoint(
                                      setup,
                                      jack,
                                      isHeel: isHeel,
                                      value: value,
                                      preserveRaw: true,
                                    ),
                          ),
                        ),
                      _ExternalView.main => Positioned(
                        left: 0,
                        top: _workspaceTop,
                        child: SizedBox(
                          width: _workspaceWidth,
                          height: ExternalPedalArt.penSize.height,
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                top: 0,
                                child: ExternalPedalArt(
                                  type: jack.type,
                                  selected: _button,
                                  onSelect: (index) => setState(() {
                                    _editGeneration++;
                                    _button = index;
                                    _buttonControl = null;
                                    _buttonPick = null;
                                  }),
                                  contacts: _contacts(
                                    context.watch<PedalCubit>().state,
                                  ),
                                ),
                              ),
                              Positioned(
                                left: _editorLeft,
                                top: 0,
                                child: switch (jack.switchAt(_button)) {
                                  null => const SizedBox(
                                    width: _editorWidth,
                                    height: 722,
                                  ),
                                  final button when _buttonPick != null =>
                                    _ButtonPicker(
                                      button: button,
                                      pick: _buttonPick!,
                                      destination: _buttonDestination,
                                      replacing: _replacingButtonControl,
                                      kind: _kind,
                                      onCancel: () => setState(() {
                                        _buttonPick = null;
                                        _replacingButtonControl = null;
                                      }),
                                      onKind: (kind) =>
                                          setState(() => _kind = kind),
                                      onOpen: (destination) => setState(() {
                                        _buttonDestination = destination;
                                        _buttonPick = _ButtonPick.controls;
                                      }),
                                      onAdd: (next, target) =>
                                          _addButtonControl(
                                            setup,
                                            jack,
                                            button,
                                            next,
                                            target,
                                          ),
                                    ),
                                  final button when _showControls =>
                                    _ControlsPanel(
                                      index: _button,
                                      button: button,
                                      open: _buttonControl,
                                      onShowControls: _setShowControls,
                                      onSelect: (target) => setState(
                                        () => _buttonControl = target,
                                      ),
                                      onAdd: () => setState(() {
                                        _replacingButtonControl = null;
                                        _buttonPick = _ButtonPick.destinations;
                                      }),
                                      onChange: (open) => setState(() {
                                        _replacingButtonControl = open;
                                        _buttonPick = _ButtonPick.destinations;
                                      }),
                                      onRemoved: (next) {
                                        setState(() => _buttonControl = null);
                                        _write(
                                          setup,
                                          jack,
                                          button.copyWith(controls: next),
                                        );
                                      },
                                      onWrite: (next) => _write(
                                        setup,
                                        jack,
                                        button.copyWith(controls: next),
                                      ),
                                    ),
                                  final button => _ActionsPanel(
                                    index: _button,
                                    button: button,
                                    onShowControls: _setShowControls,
                                    onHardware: (hardware) => _write(
                                      setup,
                                      jack,
                                      button.copyWith(hardware: hardware),
                                    ),
                                    onPick: (gesture, current, slot) =>
                                        unawaited(
                                          _pick(gesture, current, slot),
                                        ),
                                  ),
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      _ExternalView.calibrate => Positioned(
                        left: 0,
                        top: _calibrateTop,
                        child: _CalibrateWorkspace(
                          jack: _jack,
                          calibration: jack.expression.calibration,
                          heel: _captureHeel,
                          toe: _captureToe,
                          onLinkLost: _dropCaptures,
                          onCapture: ({required isHeel, required raw}) =>
                              setState(() {
                                if (isHeel) {
                                  _captureHeel = raw;
                                } else {
                                  _captureToe = raw;
                                }
                              }),
                          onCancel: _leaveCalibrate,
                          onUse: (travel) =>
                              _useCalibration(setup, jack, travel),
                        ),
                      ),
                      _ExternalView.destinations => Positioned(
                        left: 0,
                        top: _pickerTop,
                        right: 0,
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
                      _ExternalView.controls => Positioned(
                        left: 0,
                        top: _pickerTop,
                        right: 0,
                        height: _pickerHeight,
                        child: ExpressionControlPicker(
                          // An empty destination is still a destination: the
                          // picker says so rather than this page guessing its
                          // way back a view.
                          destination:
                              _destination ??
                              const ExpressionDestination(
                                id: '',
                                kind: ExpressionDestinationKind.liveInput,
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
                    },
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // The expression pedal
  // ---------------------------------------------------------------------------

  Set<int> _contacts(PedalState state) {
    if (state.status != PedalLinkStatus.connected) return const {};
    return {
      for (final (index, contact) in PedalCtrlContact.values.indexed)
        if (state.ctrl[PedalCtrlInput(_jack, contact)] case PedalCtrlReading(
          kind: PedalCtrlKind.switchPedal,
          value: > 0,
        ))
          index,
    };
  }

  /// The link dropped with captures in hand: they were readings from a board
  /// that is no longer there, and the accepted design discards them rather
  /// than letting half of an old travel meet half of a new one.
  void _dropCaptures() {
    if (!mounted) return;
    setState(() {
      _captureHeel = null;
      _captureToe = null;
    });
  }

  /// The mapping whose range is open: the selected one, or the first row when
  /// nothing has been selected yet.
  ControlValueTarget? _openTarget(ExternalExpressionSetup expression) {
    final chosen = _selected;
    if (chosen != null && expression.mappingFor(chosen) != null) return chosen;
    return expression.mappings.isEmpty
        ? null
        : expression.mappings.first.target;
  }

  List<ExpressionDestination> _destinations(BuildContext context) {
    final availability = controlAvailability(context, watch: true);
    return controlDestinations(
      context.l10n,
      context.watch<TracksCubit>().state.names,
      availability,
    );
  }

  void _openCalibrate(BuildContext context) {
    // Told before the view opens, not after: a sweep arriving between the two
    // would be dispatched by a pedal the performer is already teaching.
    _endCalibration();
    final token = Object();
    _calibrationToken = token;
    context.read<ControlCubit>().beginExternalCalibration(
      _jack,
      owner: token,
    );
    setState(() {
      _view = _ExternalView.calibrate;
      _captureHeel = null;
      _captureToe = null;
    });
  }

  void _leaveCalibrate() {
    _endCalibration();
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
    _endCalibration();
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
    if (!controlAvailability(context).canAssign(target)) return;
    final replacing = _replacing;
    final expression = jack.expression;
    if (target == replacing) {
      // The control it already has. Removing and re-adding would send its row
      // to the bottom of the list for a choice that changed nothing.
      setState(() {
        _replacing = null;
        _view = _ExternalView.main;
      });
      return;
    }
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
                  toe: kept?.toe,
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
    bool preserveRaw = false,
  }) {
    final target = _openTarget(jack.expression);
    if (target == null) return;
    final mapping = jack.expression.mappingFor(target);
    if (mapping == null) return;
    final canonical = !preserveRaw && target is RecordLengthValueTarget
        ? target.fromDomain(target.toDomain(value))
        : !preserveRaw && target is RecordTimingValueTarget
        ? target.fromDomain(target.toDomain(value))
        : value;
    final next = jack.expression.withMapping(
      isHeel
          ? mapping.copyWith(heel: canonical)
          : mapping.copyWith(toe: canonical),
    );
    setState(() {
      _draft = setup.withJack(_jack, jack.copyWith(expression: next));
      _saved = false;
    });
  }

  /// Back steps out of a subview before it leaves the page.
  void _back() {
    if (_saving) return;
    switch (_view) {
      case _ExternalView.main when _buttonPick == _ButtonPick.controls:
        setState(() => _buttonPick = _ButtonPick.destinations);
      case _ExternalView.main when _buttonPick != null:
        setState(() => _buttonPick = null);
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

  void _endCalibration() {
    final token = _calibrationToken;
    _calibrationToken = null;
    if (token != null) _control?.endExternalCalibration(token);
  }

  // ---------------------------------------------------------------------------
  // Titlebar
  // ---------------------------------------------------------------------------

  void _cancel() => setState(() {
    _editGeneration++;
    _draft = null;
    _saved = false;
    _saveFailed = false;
  });

  Future<void> _save(ControlCubit control, ExternalPedalSetup setup) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await control.setPedalSetup(
        control.state.pedalSetup.copyWith(
          external: control.state.pedalSetup.external.withConfigurationFrom(
            setup,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        if (_draft == null || identical(_draft, setup)) {
          _draft = null;
          _saved = true;
        }
      });
    } on FxReachOverBudget {
      // Refused, not failed: the draft stays open, and the notice says why
      // (#1723).
      if (mounted) {
        context.read<NoticesCubit>().show(
          Notice(
            id: AppNoticeId.fxBindOverBudget,
            tone: NoticeTone.warning,
            title: (l10n) => l10n.fxBindOverBudget,
          ),
        );
      }
    } on Object {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Which jack, and what is in it
  // ---------------------------------------------------------------------------

  void _openJack(PedalCtrlJack jack) {
    if (jack == _jack) return;
    // The other jack has its own type, which may have fewer switches than the
    // one being left.
    setState(() {
      _editGeneration++;
      _jack = jack;
      _button = 0;
      // The other jack sweeps its own controls, and may sweep none.
      _selected = null;
      // And a control being chosen for a button on the jack being left is
      // not being chosen for the one being opened.
      _buttonControl = null;
      _buttonPick = null;
    });
  }

  void _setType(ExternalJackType type) {
    final setup =
        _draft ?? context.read<ControlCubit>().state.pedalSetup.external;
    final jack = setup.forJack(_jack);
    if (type == jack.type) return;
    setState(() {
      _editGeneration++;
      _draft = setup.withJack(_jack, jack.copyWith(type: type));
      // A type with fewer switches cannot keep the second one selected.
      if (_button >= type.switchCount) _button = 0;
      // Every type keeps its own assignments, so this selects nothing: the
      // expression panel opens on its own first row.
      _selected = null;
      _buttonControl = null;
      _buttonPick = null;
      _saved = false;
    });
  }

  // ---------------------------------------------------------------------------
  // The switch being edited
  // ---------------------------------------------------------------------------

  void _setShowControls(bool show) => setState(() => _showControls = show);

  void _addButtonControl(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
    ExternalControls next,
    Object target,
  ) {
    if (!controlAvailability(context).canAssign(target)) return;
    setState(() {
      _buttonPick = null;
      _replacingButtonControl = null;
      _buttonControl = target;
    });
    _write(setup, jack, button.copyWith(controls: next));
  }

  Future<void> _pick(
    String gesture,
    ControlAction? current,
    _ActionSlot slot,
  ) async {
    final jack = _jack;
    final index = _button;
    final generation = _editGeneration;
    final atOpen =
        (_draft ?? context.read<ControlCubit>().state.pedalSetup.external)
            .forJack(jack);
    final buttonAtOpen = atOpen.switchAt(index);
    final l10n = context.l10n;
    final names = context.read<TracksCubit>().state.names;
    final chosen = await showControlActionPicker(
      context,
      title: l10n.pedalSetupChooser(l10n.externalButton(index + 1), gesture),
      current: current,
      trackNames: names,
    );
    if (chosen == null ||
        !mounted ||
        _saving ||
        _editGeneration != generation ||
        _jack != jack ||
        _button != index ||
        _view != _ExternalView.main) {
      return;
    }
    final setup =
        _draft ?? context.read<ControlCubit>().state.pedalSetup.external;
    final jackSetup = setup.forJack(jack);
    final button = jackSetup.switchAt(index);
    if (jackSetup.type != atOpen.type ||
        button == null ||
        button != buttonAtOpen) {
      return;
    }
    final updated = switch (slot) {
      _ActionSlot.press => button.copyWith(
        gestures: button.gestures.withPress(chosen.value),
      ),
      _ActionSlot.hold => button.copyWith(
        gestures: button.gestures.withHold(chosen.value),
      ),
      _ActionSlot.change => button.copyWith(
        change: chosen.value,
        clearChange: chosen.value == null,
      ),
    };
    setState(() {
      _editGeneration++;
      _draft = setup.withJack(jack, jackSetup.withSwitch(index, updated));
      _saved = false;
    });
  }

  void _write(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) => setState(() {
    _editGeneration++;
    _draft = setup.withJack(_jack, jack.withSwitch(_button, button));
    _saved = false;
  });
}

/// Only a live expression tip on [jack] is a calibration sample.
int? _rawPosition(PedalState state, PedalCtrlJack jack) {
  if (state.status != PedalLinkStatus.connected) return null;
  final reading = state.ctrl[PedalCtrlInput(jack, PedalCtrlContact.tip)];
  return reading?.kind == PedalCtrlKind.expression ? reading?.raw : null;
}

/// The titlebar's save status, Cancel and Save.
class _SaveActions extends StatelessWidget {
  const _SaveActions({
    required this.state,
    required this.dirty,
    required this.saved,
    required this.saveFailed,
    required this.onCancel,
    required this.onSave,
  });

  final ControlState state;

  /// Whether the page holds an unsaved draft.
  final bool dirty;

  /// Whether the last save landed.
  final bool saved;

  /// Whether the last save failed.
  final bool saveFailed;

  /// Discards the draft, or `null` when there is nothing to discard.
  final VoidCallback? onCancel;

  /// Saves the draft, or `null` when there is nothing to save.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if ((saved && !dirty && !state.pedalSetupRuntimeUnsaved) ||
            state.pedalSetupUnavailable ||
            state.pedalSetupPersistenceUncertain ||
            state.pedalSetupRuntimeUnsaved ||
            saveFailed)
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: AppText(
              state.pedalSetupUnavailable
                  ? l10n.pedalSetupUnavailable
                  : state.pedalSetupPersistenceUncertain
                  ? l10n.pedalSetupSaveUncertain
                  : saveFailed || state.pedalSetupRuntimeUnsaved
                  ? l10n.pedalSetupSaveFailed
                  : l10n.pedalSetupSaved,
              key: Key(
                saveFailed || state.pedalSetupRuntimeUnsaved
                    ? 'external_save_failed'
                    : 'external_saved',
              ),
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
          onTap: onCancel,
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('external_save'),
          width: 106,
          tone: LoopButtonTone.accent,
          label: l10n.pedalSetupSave,
          onTap: onSave,
        ),
      ],
    );
  }
}

/// Which jack is open, and what is plugged into it.
class _JackToolbar extends StatelessWidget {
  const _JackToolbar({
    required this.jack,
    required this.type,
    required this.onJack,
    required this.onType,
  });

  /// The jack being edited.
  final PedalCtrlJack jack;

  /// What that jack has in it.
  final ExternalJackType type;

  final ValueChanged<PedalCtrlJack> onJack;
  final ValueChanged<ExternalJackType> onType;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: LoopSettingsFrame.contentWidthOf(context),
      height: 64,
      child: Row(
        children: [
          for (final (index, value) in PedalCtrlJack.values.indexed) ...[
            if (index > 0) SizedBox(width: context.spacing.sm),
            LoopChoiceButton(
              key: Key('external_jack_${value.name}'),
              label: externalJackName(l10n, value),
              selected: value == jack,
              onTap: () => onJack(value),
              width: 144,
              height: 64,
            ),
          ],
          const Spacer(),
          for (final (index, value) in _types.indexed) ...[
            if (index > 0) SizedBox(width: context.spacing.sm),
            LoopChoiceButton(
              key: Key('external_type_${value.name}'),
              label: switch (value) {
                ExternalJackType.expression => l10n.externalTypeExpression,
                ExternalJackType.singleSwitch => l10n.externalTypeSingle,
                ExternalJackType.dualSwitch => l10n.externalTypeDual,
              },
              selected: value == type,
              onTap: () => onType(value),
              width: switch (value) {
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
}

/// An expression pedal's workspace: where the pedal is, beside what it
/// controls and over what range.
class _ExpressionWorkspace extends StatelessWidget {
  const _ExpressionWorkspace({
    required this.jack,
    required this.expression,
    required this.selected,
    required this.onCalibrate,
    required this.onSelect,
    required this.onAdd,
    required this.onChange,
    required this.onRemove,
    required this.onEndpoint,
    required this.onEndpointCancel,
  });

  /// The jack the pedal is plugged into.
  final PedalCtrlJack jack;

  final ExternalExpressionSetup expression;

  /// The mapping whose range is open.
  final ControlValueTarget? selected;

  final VoidCallback onCalibrate;
  final ValueChanged<ControlValueTarget> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onChange;
  final VoidCallback onRemove;
  final void Function({required bool isHeel, required double value}) onEndpoint;
  final void Function({required bool isHeel, required double value})
  onEndpointCancel;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _workspaceWidth,
    height: _expressionHeight,
    child: BlocSelector<PedalCubit, PedalState, int?>(
      key: ValueKey('expression_${jack.name}'),
      selector: (state) => _rawPosition(state, jack),
      builder: (context, raw) {
        final position = raw == null
            ? null
            : expression.calibration?.positionOf(raw);
        return Row(
          children: [
            ExpressionPositionPanel(
              raw: raw,
              calibration: expression.calibration,
              height: _expressionHeight,
              onCalibrate: onCalibrate,
            ),
            const SizedBox(width: _columnGap),
            // The controls take the rest of the workspace.
            Expanded(
              child: SizedBox(
                height: _expressionHeight,
                child: ExpressionControlsPanel(
                  rows: _rows(context),
                  selected: selected,
                  position: position,
                  onSelect: onSelect,
                  onAdd: onAdd,
                  onChange: onChange,
                  onRemove: onRemove,
                  onEndpoint: onEndpoint,
                  onEndpointCancel: onEndpointCancel,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  List<ExpressionRow> _rows(BuildContext context) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final availability = controlAvailability(context, watch: true);
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
          available: availability.resolves(mapping.target),
          disabledReason: controlEditBlockLabel(
            l10n,
            availability.blockedBy(mapping.target),
          ),
          art: expressionTargetArt(looper, mapping.target),
        ),
    ];
  }
}

/// Teaching an expression pedal its travel: where it is, beside the heel and
/// toe captures.
class _CalibrateWorkspace extends StatelessWidget {
  const _CalibrateWorkspace({
    required this.jack,
    required this.calibration,
    required this.heel,
    required this.toe,
    required this.onLinkLost,
    required this.onCapture,
    required this.onCancel,
    required this.onUse,
  });

  /// The jack the pedal is plugged into.
  final PedalCtrlJack jack;

  /// The travel the pedal has now.
  final ExpressionCalibration? calibration;

  /// The raw readings captured at each end so far.
  final int? heel;
  final int? toe;

  /// Drops the captures, after the frame in which the link went away.
  final VoidCallback onLinkLost;

  /// Captures the reading `raw` as the heel or the toe.
  final void Function({required bool isHeel, required int? raw}) onCapture;

  final VoidCallback onCancel;
  final ValueChanged<ExpressionCalibration> onUse;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _workspaceWidth,
    height: _calibrateHeight,
    child: BlocSelector<PedalCubit, PedalState, int?>(
      key: ValueKey('calibration_${jack.name}'),
      selector: (state) => _rawPosition(state, jack),
      builder: (context, raw) {
        // The link dropped with captures in hand: they were readings from a
        // board that is no longer there, and the accepted design discards them
        // rather than letting half of an old travel meet half of a new one.
        if (raw == null && (heel != null || toe != null)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onLinkLost());
        }
        return Row(
          children: [
            ExpressionPositionPanel(
              raw: raw,
              calibration: calibration,
              height: _calibrateHeight,
            ),
            const SizedBox(width: _columnGap),
            Expanded(
              child: SizedBox(
                height: _calibrateHeight,
                child: ExpressionCalibrationPanel(
                  heel: heel,
                  toe: toe,
                  connected: raw != null,
                  onCapture: ({required isHeel}) =>
                      onCapture(isHeel: isHeel, raw: raw),
                  onCancel: onCancel,
                  onUse: onUse,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The button's name, and the tab between its actions and its controls.
class _EditorTitle extends StatelessWidget {
  const _EditorTitle({
    required this.index,
    required this.showControls,
    required this.onShowControls,
  });

  /// The button's index on its pedal.
  final int index;

  /// Whether the controls tab is open rather than the actions tab.
  final bool showControls;

  final ValueChanged<bool> onShowControls;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          AppText(
            l10n.externalButton(index + 1),
            key: const Key('external_selected'),
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 36,
              height: 1,
            ),
          ),
          const Spacer(),
          LoopChoiceButton(
            key: const Key('external_panel_actions'),
            label: l10n.externalPanelActions,
            selected: !showControls,
            onTap: () => onShowControls(false),
            width: 141,
            height: 64,
          ),
          SizedBox(width: context.spacing.sm),
          LoopChoiceButton(
            key: const Key('external_panel_controls'),
            label: l10n.externalPanelControls,
            selected: showControls,
            onTap: () => onShowControls(true),
            width: 152,
            height: 64,
          ),
        ],
      ),
    );
  }
}

/// A button's actions: its switch type and what each gesture does.
class _ActionsPanel extends StatelessWidget {
  const _ActionsPanel({
    required this.index,
    required this.button,
    required this.onShowControls,
    required this.onHardware,
    required this.onPick,
  });

  /// The button's index on its pedal.
  final int index;

  final ExternalSwitchSetup button;
  final ValueChanged<bool> onShowControls;
  final ValueChanged<ExternalSwitchHardware> onHardware;

  /// Opens the action picker for one gesture.
  final _PickAction onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final latching = button.hardware == ExternalSwitchHardware.latching;
    return SizedBox(
      width: _editorWidth,
      height: ExternalPedalArt.penSize.height,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 138,
            width: _editorWidth,
            child: _EditorTitle(
              index: index,
              showControls: false,
              onShowControls: onShowControls,
            ),
          ),
          Positioned(
            left: 0,
            top: 238.41,
            child: _HardwareChoice(
              hardware: button.hardware,
              onSelect: onHardware,
            ),
          ),
          Positioned(
            left: 0,
            top: 386.41,
            child: latching
                ? SizedBox(
                    width: _fieldWidth,
                    height: 129,
                    child: _ActionField(
                      key: const Key('external_change'),
                      label: l10n.externalOnChange,
                      action: button.change,
                      slot: _ActionSlot.change,
                      onPick: onPick,
                    ),
                  )
                : SizedBox(
                    width: _editorWidth,
                    height: 129,
                    child: Row(
                      children: [
                        _ActionField(
                          key: const Key('external_press'),
                          label: l10n.pedalSetupPress,
                          action: button.gestures.press,
                          slot: _ActionSlot.press,
                          onPick: onPick,
                        ),
                        SizedBox(width: context.spacing.xl),
                        _ActionField(
                          key: const Key('external_hold'),
                          label: l10n.pedalSetupHold,
                          action: button.gestures.hold,
                          slot: _ActionSlot.hold,
                          onPick: onPick,
                        ),
                      ],
                    ),
                  ),
          ),
          Positioned(
            left: 0,
            top: 551.41,
            width: _editorWidth,
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
}

/// Opens the action picker for the gesture named [gesture], which carries
/// [current] now.
typedef _PickAction =
    void Function(String gesture, ControlAction? current, _ActionSlot slot);

/// Whether the button is momentary or latching.
class _HardwareChoice extends StatelessWidget {
  const _HardwareChoice({required this.hardware, required this.onSelect});

  final ExternalSwitchHardware hardware;
  final ValueChanged<ExternalSwitchHardware> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      width: _editorWidth,
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
              for (final (index, value)
                  in ExternalSwitchHardware.values.indexed) ...[
                if (index > 0) SizedBox(width: context.spacing.sm),
                LoopChoiceButton(
                  key: Key('external_hardware_${value.name}'),
                  label: switch (value) {
                    ExternalSwitchHardware.momentary =>
                      l10n.externalHardwareMomentary,
                    ExternalSwitchHardware.latching =>
                      l10n.externalHardwareLatching,
                  },
                  selected: value == hardware,
                  onTap: () => onSelect(value),
                  width: value == ExternalSwitchHardware.momentary ? 182 : 153,
                  height: 64,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// One gesture's field: its name over the action it carries.
class _ActionField extends StatelessWidget {
  const _ActionField({
    required this.label,
    required this.action,
    required this.slot,
    required this.onPick,
    super.key,
  });

  /// The gesture's name.
  final String label;

  /// What the gesture does now, or `null` for nothing.
  final ControlAction? action;

  final _ActionSlot slot;
  final _PickAction onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final value = action == null
        ? controlActionNone(l10n)
        : controlActionLabel(l10n, names, action!);
    return SizedBox(
      width: _fieldWidth,
      height: 129,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            label,
            style: TextStyle(
              color: context.surface.textSecondary,
              fontSize: 26,
            ),
          ),
          const Spacer(),
          LoopOutlinedButton(
            width: _fieldWidth,
            height: 80,
            fontSize: 28,
            tone: LoopButtonTone.raised,
            label: value,
            semanticLabel: label,
            semanticValue: value,
            onTap: () => onPick(label, action, slot),
          ),
        ],
      ),
    );
  }
}

/// A button's controls: the effects it switches and the parameters it sets.
class _ControlsPanel extends StatelessWidget {
  const _ControlsPanel({
    required this.index,
    required this.button,
    required this.open,
    required this.onShowControls,
    required this.onSelect,
    required this.onAdd,
    required this.onChange,
    required this.onRemoved,
    required this.onWrite,
  });

  /// The button's index on its pedal.
  final int index;

  final ExternalSwitchSetup button;

  /// The control whose rule was last opened, if it is still on the button.
  final Object? open;

  final ValueChanged<bool> onShowControls;
  final ValueChanged<Object> onSelect;
  final VoidCallback onAdd;

  /// Repoints the open control.
  final ValueChanged<Object?> onChange;

  /// Writes the button's controls after its open one was removed.
  final ValueChanged<ExternalControls> onRemoved;

  /// Writes the button's controls.
  final ValueChanged<ExternalControls> onWrite;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final availability = controlAvailability(context, watch: true);
    final names = context.watch<TracksCubit>().state.names;
    final controls = button.controls;
    final rows = [
      for (final activation in controls.activations)
        ExternalControlRow.activation(
          activation: activation,
          destination: fxStageLabel(l10n, names, activation.target.address),
          name: expressionActivationName(l10n, looper, activation.target),
          available: availability.resolves(activation.target),
          art: expressionTargetArt(looper, activation.target),
        ),
      for (final parameter in controls.parameters)
        ExternalControlRow.parameter(
          parameter: parameter,
          destination: expressionTargetName(
            l10n,
            names,
            looper,
            parameter.target,
          ).destination,
          name: expressionRowName(l10n, names, looper, parameter.target),
          available: availability.resolves(parameter.target),
          disabledReason: controlEditBlockLabel(
            l10n,
            availability.blockedBy(parameter.target),
          ),
          art: expressionTargetArt(looper, parameter.target),
        ),
    ];
    final open = rows.any((row) => row.target == this.open)
        ? this.open
        : rows.isEmpty
        ? null
        : rows.first.target;

    return SizedBox(
      width: _editorWidth,
      height: ExternalPedalArt.penSize.height,
      child: Column(
        children: [
          _EditorTitle(
            index: index,
            showControls: true,
            onShowControls: onShowControls,
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ExternalControlsEditor(
                rows: rows,
                selected: open,
                latching: button.hardware == ExternalSwitchHardware.latching,
                onSelect: onSelect,
                onAdd: onAdd,
                onChange: () => onChange(open),
                onRemove: () => onRemoved(switch (open) {
                  final FxBindingTarget target => controls.withoutActivation(
                    target,
                  ),
                  final ControlValueTarget target => controls.withoutParameter(
                    target,
                  ),
                  _ => controls,
                }),
                onCondition: (condition) {
                  if (open is! FxBindingTarget) return;
                  onWrite(
                    controls.withActivation(
                      ExternalActivation(target: open, condition: condition),
                    ),
                  );
                },
                onValueCondition: (condition) {
                  final parameter = _parameterOn(controls, open);
                  if (parameter == null) return;
                  onWrite(
                    controls.withParameter(
                      parameter.copyWith(condition: condition),
                    ),
                  );
                },
                onValue: ({required active, required value}) {
                  final parameter = _parameterOn(controls, open);
                  if (parameter == null) return;
                  onWrite(
                    controls.withParameter(
                      active
                          ? parameter.copyWith(active: value)
                          : parameter.copyWith(inactive: value),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static ExternalParameter? _parameterOn(
    ExternalControls controls,
    Object? target,
  ) {
    for (final parameter in controls.parameters) {
      if (parameter.target == target) return parameter;
    }
    return null;
  }
}

/// Choosing a button's new control, inside its editor: the switch art stays
/// beside it, because the performer is still adding to THAT button.
class _ButtonPicker extends StatelessWidget {
  const _ButtonPicker({
    required this.button,
    required this.pick,
    required this.destination,
    required this.replacing,
    required this.kind,
    required this.onCancel,
    required this.onKind,
    required this.onOpen,
    required this.onAdd,
  });

  final ExternalSwitchSetup button;

  /// Which step of the choice is showing.
  final _ButtonPick pick;

  /// The destination whose controls are listed.
  final ExpressionDestination? destination;

  /// The control being repointed, or `null` when adding one.
  final Object? replacing;

  /// Which tab of the destination list is open.
  final ExpressionDestinationKind kind;

  final VoidCallback onCancel;
  final ValueChanged<ExpressionDestinationKind> onKind;
  final ValueChanged<ExpressionDestination> onOpen;

  /// Writes `next` as the button's controls, with `target` the one chosen.
  final void Function(ExternalControls next, Object target) onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final availability = controlAvailability(context, watch: true);
    final surface = context.surface;
    final destination = this.destination;
    final choosingControl = pick == _ButtonPick.controls && destination != null;
    final controls = button.controls;
    final replacing = this.replacing;
    return SizedBox(
      width: _editorWidth,
      height: ExternalPedalArt.penSize.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          SizedBox(
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    choosingControl
                        ? destination.label
                        : l10n.expressionChooseDestination,
                    key: const Key('external_pick_title'),
                    maxLines: 1,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 32,
                      height: 1.15,
                    ),
                  ),
                ),
                LoopOutlinedButton(
                  key: const Key('external_pick_cancel'),
                  width: 125,
                  label: l10n.pedalSetupCancel,
                  onTap: onCancel,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: choosingControl
                ? ExternalControlTargetList(
                    destination: destination,
                    replacing: replacing,
                    taken: {
                      for (final a in controls.activations) a.target,
                      for (final p in controls.parameters) p.target,
                    },
                    onActivation: (activation) => onAdd(
                      replacing is FxBindingTarget
                          ? controls.repointActivation(
                              replacing,
                              activation.target,
                            )
                          : controls.withActivation(
                              ExternalActivation(target: activation.target),
                            ),
                      activation.target,
                    ),
                    onParameter: (control) {
                      // Both values start at what the parameter holds NOW, so
                      // adding the mapping invents no sound change.
                      final available = controlAvailability(context);
                      if (!available.canAssign(control.target)) return;
                      final now = available.value(control.target);
                      if (now == null) return;
                      onAdd(
                        replacing is ControlValueTarget
                            ? controls.repointParameter(
                                replacing,
                                control.target,
                              )
                            : controls.withParameter(
                                ExternalParameter(
                                  target: control.target,
                                  active: now,
                                  inactive: now,
                                ),
                              ),
                        control.target,
                      );
                    },
                  )
                : ExpressionDestinationPicker(
                    destinations: controlDestinations(
                      l10n,
                      context.watch<TracksCubit>().state.names,
                      availability,
                      withActivations: true,
                    ),
                    kind: kind,
                    columns: 1,
                    onKind: onKind,
                    onOpen: onOpen,
                  ),
          ),
        ],
      ),
    );
  }
}
