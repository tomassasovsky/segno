import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/control_value_readout.dart';
import 'package:segno/control/view/pedal_setup/expression_calibration_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_controls_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_position_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_target_picker.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
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
    return FutureBuilder<void>(
      future: _initialLoad,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError) {
          return Scaffold(
            body: LoopSettingsFrame(
              crumb: l10n.pedalSetupCrumb,
              title: l10n.externalPedalsTitle,
              titleLeft: _left,
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
        return _loadedPage(context, l10n, control, setup, jack, main);
      },
    );
  }

  Widget _loadedPage(
    BuildContext context,
    AppLocalizations l10n,
    ControlCubit control,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    bool main,
  ) => PopScope(
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
              _ExternalView.destinations => l10n.expressionChooseDestination,
              _ExternalView.controls => l10n.expressionChooseControl,
            },
            titleLeft: _left,
            onBack: _back,
            onStage: () {
              if (!_saving) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            // Save and Cancel belong to the page's one draft. Subviews are
            // steps inside it; saving mid-choice would commit an unfinished
            // decision.
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
        ),
      ),
    ),
  );

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
                  onSelect: (index) => setState(() {
                    _editGeneration++;
                    _button = index;
                    _buttonControl = null;
                    _buttonPick = null;
                  }),
                  contacts: _contacts(context.watch<PedalCubit>().state),
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
    ],
  };

  // ---------------------------------------------------------------------------
  // The expression pedal
  // ---------------------------------------------------------------------------

  /// Only a live expression tip is a calibration sample.
  int? _rawPosition(PedalState state) {
    if (state.status != PedalLinkStatus.connected) return null;
    final reading = state.ctrl[PedalCtrlInput(_jack, PedalCtrlContact.tip)];
    return reading?.kind == PedalCtrlKind.expression ? reading?.raw : null;
  }

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

  Widget _expressionWorkspace(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
  ) {
    final expression = jack.expression;
    return SizedBox(
      width: 1720,
      height: _expressionHeight,
      child: BlocSelector<PedalCubit, PedalState, int?>(
        key: ValueKey('expression_${_jack.name}'),
        selector: _rawPosition,
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
                  onEndpointCancel: ({required isHeel, required value}) =>
                      _moveEndpoint(
                        setup,
                        jack,
                        isHeel: isHeel,
                        value: value,
                        preserveRaw: true,
                      ),
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
    child: BlocSelector<PedalCubit, PedalState, int?>(
      key: ValueKey('calibration_${_jack.name}'),
      selector: _rawPosition,
      builder: (context, raw) {
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
    final clickVolume = context.watch<TempoCubit>().clickVolume;
    final decaySnapshot = context.watch<PlaybackOptionsCubit>().decaySnapshot;
    final oneShotSnapshot = context
        .watch<PlaybackOptionsCubit>()
        .oneShotSnapshot;
    final recordLengthSnapshot = context
        .watch<RecordOptionsCubit>()
        .recordLengthSnapshot;
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
          available: looper.valueTargetResolves(
            mapping.target,
            clickVolume: clickVolume,
            decaySnapshot: decaySnapshot,
            oneShotSnapshot: oneShotSnapshot,
            recordLengthSnapshot: recordLengthSnapshot,
          ),
          disabledReason: recordLengthDisabledReason(
            l10n,
            mapping.target,
            recordLengthSnapshot,
          ),
          art: expressionTargetArt(looper, mapping.target),
        ),
    ];
  }

  List<ExpressionDestination> _destinations(BuildContext context) {
    final clickVolume = context.watch<TempoCubit>().clickVolume;
    final decaySnapshot = context.watch<PlaybackOptionsCubit>().decaySnapshot;
    final oneShotSnapshot = context
        .watch<PlaybackOptionsCubit>()
        .oneShotSnapshot;
    final recordLengthSnapshot = context
        .watch<RecordOptionsCubit>()
        .recordLengthSnapshot;
    return expressionDestinations(
      context.l10n,
      context.watch<TracksCubit>().state.names,
      context.read<LooperRepository>(),
      clickVolume: clickVolume,
      decaySnapshot: decaySnapshot,
      oneShotSnapshot: oneShotSnapshot,
      recordLengthSnapshot: recordLengthSnapshot,
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
    if (target is ClickVolumeTarget &&
        context.read<TempoCubit>().clickVolume == null) {
      return;
    }
    if (target is DecayValueTarget &&
        context.read<PlaybackOptionsCubit>().decaySnapshot == null) {
      return;
    }
    if (target is OneShotValueTarget &&
        context.read<PlaybackOptionsCubit>().oneShotSnapshot == null) {
      return;
    }
    if (target is RecordLengthValueTarget &&
        context.read<RecordOptionsCubit>().recordLengthSnapshot?.canEdit(
              target.address,
            ) !=
            true) {
      return;
    }
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
    bool preserveRaw = false,
  }) {
    final target = _openTarget(jack.expression);
    if (target == null) return;
    final mapping = jack.expression.mappingFor(target);
    if (mapping == null) return;
    final canonical = !preserveRaw && target is RecordLengthValueTarget
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
        if ((_saved && !dirty && !control.state.pedalSetupRuntimeUnsaved) ||
            control.state.pedalSetupUnavailable ||
            control.state.pedalSetupPersistenceUncertain ||
            control.state.pedalSetupRuntimeUnsaved ||
            _saveFailed)
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: AppText(
              control.state.pedalSetupUnavailable
                  ? l10n.pedalSetupUnavailable
                  : control.state.pedalSetupPersistenceUncertain
                  ? l10n.pedalSetupSaveUncertain
                  : _saveFailed || control.state.pedalSetupRuntimeUnsaved
                  ? l10n.pedalSetupSaveFailed
                  : l10n.pedalSetupSaved,
              key: Key(
                _saveFailed || control.state.pedalSetupRuntimeUnsaved
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
          onTap: dirty && !_saving ? _cancel : null,
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('external_save'),
          width: 106,
          tone: LoopButtonTone.accent,
          label: l10n.pedalSetupSave,
          onTap:
              (dirty ||
                      control.state.pedalSetupRuntimeUnsaved ||
                      control.state.pedalSetupPersistenceUncertain ||
                      control.state.pedalSetupUnavailable) &&
                  !_saving
              ? () => unawaited(_save(control, setup))
              : null,
        ),
      ],
    );
  }

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
    } on Object {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
          for (final (index, value) in PedalCtrlJack.values.indexed) ...[
            if (index > 0) const SizedBox(width: 9),
            LoopChoiceButton(
              key: Key('external_jack_${value.name}'),
              label: switch (value) {
                PedalCtrlJack.ctrl1 => l10n.externalJackCtrl1,
                PedalCtrlJack.ctrl2 => l10n.externalJackCtrl2,
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
    if (_buttonPick != null) return _buttonPicker(context, setup, jack, button);
    if (_showControls) return _controlsPanel(context, setup, jack, button);
    return SizedBox(
      width: 1040,
      height: ExternalPedalArt.penSize.height,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 138,
            width: 1040,
            child: _editorTitle(context),
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
                ? _changeField(context, button)
                : _gestureFields(context, button),
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

  /// The button's name, and the tab between its actions and its controls.
  Widget _editorTitle(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          AppText(
            l10n.externalButton(_button + 1),
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
            selected: !_showControls,
            onTap: () => setState(() => _showControls = false),
            width: 141,
            height: 64,
          ),
          const SizedBox(width: 9),
          LoopChoiceButton(
            key: const Key('external_panel_controls'),
            label: l10n.externalPanelControls,
            selected: _showControls,
            onTap: () => setState(() => _showControls = true),
            width: 152,
            height: 64,
          ),
        ],
      ),
    );
  }

  Widget _controlsPanel(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final clickVolume = context.watch<TempoCubit>().clickVolume;
    final decaySnapshot = context.watch<PlaybackOptionsCubit>().decaySnapshot;
    final oneShotSnapshot = context
        .watch<PlaybackOptionsCubit>()
        .oneShotSnapshot;
    final recordLengthSnapshot = context
        .watch<RecordOptionsCubit>()
        .recordLengthSnapshot;
    final names = context.watch<TracksCubit>().state.names;
    final controls = button.controls;
    final rows = [
      for (final activation in controls.activations)
        ExternalControlRow.activation(
          activation: activation,
          destination: fxStageLabel(l10n, names, activation.target.address),
          name: expressionActivationName(l10n, looper, activation.target),
          available: looper.bindingResolves(activation.target),
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
          available: looper.valueTargetResolves(
            parameter.target,
            clickVolume: clickVolume,
            decaySnapshot: decaySnapshot,
            oneShotSnapshot: oneShotSnapshot,
            recordLengthSnapshot: recordLengthSnapshot,
          ),
          disabledReason: recordLengthDisabledReason(
            l10n,
            parameter.target,
            recordLengthSnapshot,
          ),
          art: expressionTargetArt(looper, parameter.target),
        ),
    ];
    final open = rows.any((row) => row.target == _buttonControl)
        ? _buttonControl
        : rows.isEmpty
        ? null
        : rows.first.target;

    void write(ExternalControls next) =>
        _write(setup, jack, button.copyWith(controls: next));

    return SizedBox(
      width: 1040,
      height: ExternalPedalArt.penSize.height,
      child: Column(
        children: [
          _editorTitle(context),
          const SizedBox(height: 24),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ExternalControlsEditor(
                rows: rows,
                selected: open,
                latching: button.hardware == ExternalSwitchHardware.latching,
                onSelect: (target) => setState(() => _buttonControl = target),
                onAdd: () => setState(() {
                  _replacingButtonControl = null;
                  _buttonPick = _ButtonPick.destinations;
                }),
                onChange: () => setState(() {
                  _replacingButtonControl = open;
                  _buttonPick = _ButtonPick.destinations;
                }),
                onRemove: () {
                  final next = switch (open) {
                    final FxBindingTarget target => controls.withoutActivation(
                      target,
                    ),
                    final ControlValueTarget target =>
                      controls.withoutParameter(target),
                    _ => controls,
                  };
                  setState(() => _buttonControl = null);
                  write(next);
                },
                onCondition: (condition) {
                  if (open is! FxBindingTarget) return;
                  write(
                    controls.withActivation(
                      ExternalActivation(target: open, condition: condition),
                    ),
                  );
                },
                onValueCondition: (condition) {
                  final parameter = _parameterOn(controls, open);
                  if (parameter == null) return;
                  write(
                    controls.withParameter(
                      parameter.copyWith(condition: condition),
                    ),
                  );
                },
                onValue: ({required active, required value}) {
                  final parameter = _parameterOn(controls, open);
                  if (parameter == null) return;
                  write(
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

  ExternalParameter? _parameterOn(ExternalControls controls, Object? target) {
    for (final parameter in controls.parameters) {
      if (parameter.target == target) return parameter;
    }
    return null;
  }

  /// Choosing a button's new control, inside its editor: the switch art stays
  /// beside it, because the performer is still adding to THAT button.
  Widget _buttonPicker(
    BuildContext context,
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
  ) {
    final l10n = context.l10n;
    final clickVolume = context.watch<TempoCubit>().clickVolume;
    final decaySnapshot = context.watch<PlaybackOptionsCubit>().decaySnapshot;
    final oneShotSnapshot = context
        .watch<PlaybackOptionsCubit>()
        .oneShotSnapshot;
    final recordLengthSnapshot = context
        .watch<RecordOptionsCubit>()
        .recordLengthSnapshot;
    final surface = context.surface;
    final destination = _buttonDestination;
    final choosingControl =
        _buttonPick == _ButtonPick.controls && destination != null;
    final controls = button.controls;
    return SizedBox(
      width: 1040,
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
                  onTap: () => setState(() {
                    _buttonPick = null;
                    _replacingButtonControl = null;
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: choosingControl
                ? ExternalControlTargetList(
                    destination: destination,
                    replacing: _replacingButtonControl,
                    taken: {
                      for (final a in controls.activations) a.target,
                      for (final p in controls.parameters) p.target,
                    },
                    onActivation: (activation) => _addButtonControl(
                      setup,
                      jack,
                      button,
                      _replacingButtonControl is FxBindingTarget
                          ? controls.repointActivation(
                              _replacingButtonControl! as FxBindingTarget,
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
                      final acceptedClick = context
                          .read<TempoCubit>()
                          .clickVolume;
                      final acceptedDecay = context
                          .read<PlaybackOptionsCubit>()
                          .decaySnapshot;
                      final acceptedOneShot = context
                          .read<PlaybackOptionsCubit>()
                          .oneShotSnapshot;
                      if (control.target is ClickVolumeTarget &&
                          acceptedClick == null) {
                        return;
                      }
                      if (control.target is DecayValueTarget &&
                          acceptedDecay == null) {
                        return;
                      }
                      if (control.target is OneShotValueTarget &&
                          acceptedOneShot == null) {
                        return;
                      }
                      final acceptedLength = context
                          .read<RecordOptionsCubit>()
                          .recordLengthSnapshot;
                      if (control.target is RecordLengthValueTarget &&
                          acceptedLength?.canEdit(
                                (control.target as RecordLengthValueTarget)
                                    .address,
                              ) !=
                              true) {
                        return;
                      }
                      final now =
                          context.read<LooperRepository>().readValueTarget(
                            control.target,
                            clickVolume: acceptedClick,
                            decaySnapshot: acceptedDecay,
                            oneShotSnapshot: acceptedOneShot,
                            recordLengthSnapshot: acceptedLength,
                          ) ??
                          0;
                      _addButtonControl(
                        setup,
                        jack,
                        button,
                        _replacingButtonControl is ControlValueTarget
                            ? controls.repointParameter(
                                _replacingButtonControl! as ControlValueTarget,
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
                    destinations: expressionDestinations(
                      l10n,
                      context.watch<TracksCubit>().state.names,
                      context.read<LooperRepository>(),
                      withActivations: true,
                      clickVolume: clickVolume,
                      decaySnapshot: decaySnapshot,
                      oneShotSnapshot: oneShotSnapshot,
                      recordLengthSnapshot: recordLengthSnapshot,
                    ),
                    kind: _kind,
                    columns: 1,
                    onKind: (kind) => setState(() => _kind = kind),
                    onOpen: (destination) => setState(() {
                      _buttonDestination = destination;
                      _buttonPick = _ButtonPick.controls;
                    }),
                  ),
          ),
        ],
      ),
    );
  }

  void _addButtonControl(
    ExternalPedalSetup setup,
    ExternalJackSetup jack,
    ExternalSwitchSetup button,
    ExternalControls next,
    Object target,
  ) {
    setState(() {
      _buttonPick = null;
      _replacingButtonControl = null;
      _buttonControl = target;
    });
    _write(setup, jack, button.copyWith(controls: next));
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
                  onTap: () =>
                      _write(setup, jack, button.copyWith(hardware: hardware)),
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
            slot: _ActionSlot.press,
          ),
          const SizedBox(width: 28),
          _field(
            context,
            key: const Key('external_hold'),
            label: l10n.pedalSetupHold,
            action: button.gestures.hold,
            slot: _ActionSlot.hold,
          ),
        ],
      ),
    );
  }

  Widget _changeField(
    BuildContext context,
    ExternalSwitchSetup button,
  ) => SizedBox(
    width: 506,
    height: 129,
    child: _field(
      context,
      key: const Key('external_change'),
      label: context.l10n.externalOnChange,
      action: button.change,
      slot: _ActionSlot.change,
    ),
  );

  /// One gesture's field: its name over the action it carries.
  Widget _field(
    BuildContext context, {
    required Key key,
    required String label,
    required ControlAction? action,
    required _ActionSlot slot,
  }) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    final value = action == null
        ? controlActionNone(l10n)
        : controlActionLabel(l10n, names, action);
    return SizedBox(
      key: key,
      width: 506,
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
            width: 506,
            height: 80,
            fontSize: 28,
            tone: LoopButtonTone.raised,
            label: value,
            semanticLabel: label,
            semanticValue: value,
            onTap: () => unawaited(_pick(label, action, slot)),
          ),
        ],
      ),
    );
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
