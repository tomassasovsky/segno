import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_action_labels.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/midi_labels.dart';
import 'package:segno/control/binding/midi_mapping_draft.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/midi_controls/midi_choice_grid.dart';
import 'package:segno/control/view/midi_controls/midi_control_cards.dart';
import 'package:segno/control/view/midi_controls/midi_device_cards.dart';
import 'package:segno/control/view/midi_controls/midi_mapping_rows.dart';
import 'package:segno/control/view/midi_controls/midi_source_panel.dart';
import 'package:segno/control/view/pedal_setup/expression_target_picker.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The accepted MIDI controls page: the controllers, what each of their
/// controls is mapped to, and the editor that maps one.
///
/// The editor keeps its draft on this page, the way the Pedals pages do, and
/// the control interpreter keeps what the editor needs from the rig: the
/// device paused while it is open, and the Learn in progress.
class MidiControlsPage extends StatefulWidget {
  /// Creates a [MidiControlsPage].
  const MidiControlsPage({this.onStage, super.key});

  /// Returns to the hosting Stage when supplied by its route.
  final VoidCallback? onStage;

  @override
  State<MidiControlsPage> createState() => _MidiControlsPageState();
}

/// Which body the page is showing.
///
/// The pickers are whole views, as the accepted design draws them, so Back
/// steps through them rather than leaving, which is what keeps one draft.
enum _MidiView {
  /// The controllers and their mappings.
  list,

  /// One mapping.
  editor,

  /// Where a new control lives.
  destinations,

  /// The controls of one destination.
  parameters,

  /// The channel the mapping receives on.
  channel,

  /// The format the next Learn reads in.
  format,
}

class _MidiControlsPageState extends State<MidiControlsPage> {
  _MidiView _view = _MidiView.list;

  /// The mapping being edited, or `null` on the list.
  MidiMappingDraft? _draft;

  /// The format the next Learn reads in.
  MidiProtocol _protocol = MidiProtocol.standard;

  /// What just happened, or what is in the way, or `null`.
  String? _notice;

  /// Which tab of the destination picker is open, kept across visits.
  ExpressionDestinationKind _kind = ExpressionDestinationKind.liveInput;

  /// The destination whose controls are open.
  ExpressionDestination? _destination;

  /// The parameter being repointed, so choosing a control replaces it in
  /// place instead of adding another.
  String? _replacing;

  /// The cubit, remembered so [dispose] can reach it after the element is
  /// detached.
  ControlCubit? _control;
  Object? _editOwner;
  Object? _learnToken;
  MidiMapping? _expected;
  bool _saving = false;
  int _editGeneration = 0;

  /// The pen's insets inside the 1920 x 984 main area.
  static const double _left = 60;
  static const double _top = 140;
  static const double _width = 1800;
  static const double _rowsTop = 272;
  static const double _editorGap = 60;
  static const double _pickerHeight = 808;

  @override
  void dispose() {
    final owner = _editOwner;
    if (owner != null) _control?.endMidiEdit(owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final control = context.watch<ControlCubit>();
    _control = control;
    final connection = context.select<MidiSetupCubit, MidiConnection>(
      (cubit) => cubit.state.connection,
    );
    final draft = _draft;
    return PopScope(
      canPop: !_saving && _view == _MidiView.list,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _back();
      },
      child: AbsorbPointer(
        absorbing: _saving,
        child: ExcludeFocus(
          excluding: _saving,
          child: Scaffold(
            body: MultiBlocListener(
              listeners: [
                BlocListener<ControlCubit, ControlState>(
                  listenWhen: (previous, current) =>
                      previous.midiEdit?.learn?.reading !=
                          current.midiEdit?.learn?.reading ||
                      previous.midiEdit?.learnTimedOut !=
                          current.midiEdit?.learnTimedOut,
                  listener: _onLearn,
                ),
                BlocListener<MidiSetupCubit, MidiSetupState>(
                  listenWhen: (previous, current) =>
                      previous.connection.selectedId !=
                      current.connection.selectedId,
                  listener: (context, state) =>
                      _selectedDeviceChanged(state.connection.selectedId),
                ),
              ],
              child: LoopSettingsFrame(
                key: const Key('midi_controls_page'),
                crumb: l10n.midiControlsCrumb,
                title: switch (_view) {
                  _MidiView.list => l10n.midiControlsTitle,
                  _MidiView.editor => l10n.midiMappingTitle,
                  _MidiView.destinations => l10n.expressionChooseDestination,
                  _MidiView.parameters =>
                    _destination?.label ?? l10n.expressionChooseControl,
                  _MidiView.channel => l10n.midiReceiveChannelTitle,
                  _MidiView.format => l10n.midiMessageFormat,
                },
                titleLeft: _left,
                onBack: _back,
                onStage: () {
                  if (_saving) return;
                  _closeEditor(control);
                  widget.onStage?.call();
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                actions: switch (_view) {
                  _MidiView.list => _listActions(context, control, connection),
                  _MidiView.editor when draft != null => _editorActions(
                    context,
                    control,
                    draft,
                  ),
                  _MidiView.destinations when _replacing == null =>
                    _destinationActions(context, draft),
                  _ => null,
                },
                children: [
                  if (_view == _MidiView.list)
                    ..._list(context, control, connection)
                  else if (draft != null)
                    ..._editing(context, control, connection, draft),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // The list
  // ---------------------------------------------------------------------------

  Widget _listActions(
    BuildContext context,
    ControlCubit control,
    MidiConnection connection,
  ) {
    final l10n = context.l10n;
    final on = control.state.midiControlEnabled;
    final paused = control.state.midiRemotePaused;
    final unavailable = control.state.midiUnavailable;
    final loaded = control.state.midiLoaded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (unavailable)
          LoopOutlinedButton(
            key: const Key('midi_reset_configuration'),
            width: 260,
            label: l10n.midiResetConfiguration,
            onTap: loaded
                ? () => unawaited(_resetConfiguration(control))
                : null,
          )
        else if (paused && on) ...[
          LoopOutlinedButton(
            key: const Key('midi_retry_off'),
            width: 195,
            label: l10n.midiRetryOff,
            onTap: loaded
                ? () => unawaited(
                    _setControlEnabled(control, enabled: false),
                  )
                : null,
          ),
          const SizedBox(width: 16),
          LoopOutlinedButton(
            key: const Key('midi_resume_on'),
            width: 195,
            label: l10n.midiResumeOn,
            onTap: loaded
                ? () => unawaited(
                    _setControlEnabled(control, enabled: true),
                  )
                : null,
          ),
        ] else
          LoopChoiceButton(
            key: const Key('midi_control_enabled'),
            width: 219,
            height: 64,
            label: on ? l10n.midiControlOn : l10n.midiControlOff,
            selected: on,
            onTap: () {
              if (loaded) {
                unawaited(_setControlEnabled(control, enabled: !on));
              }
            },
          ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('midi_add_mapping'),
          width: 192,
          label: l10n.midiAddMapping,
          onTap:
              control.state.midiLoaded &&
                  !control.state.midiUnavailable &&
                  connection.hasSelection
              ? () => _add(control, connection)
              : null,
        ),
      ],
    );
  }

  List<Widget> _list(
    BuildContext context,
    ControlCubit control,
    MidiConnection connection,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final device = connection.selectedId;
    final connected = connection.status == MidiConnectionStatus.connected;
    final rows = [
      for (final mapping in control.state.midiMappings.mappings)
        if (mapping.source.device == device) _row(context, mapping, connected),
    ];
    return [
      Positioned(
        left: _left,
        top: _top,
        width: _width,
        height: MidiDeviceCards.cardSize.height,
        child: MidiDeviceCards(
          cards: midiDeviceCards(connection),
          onSelect: (id) {
            if (_saving) return;
            _closeEditor(control);
            setState(() => _notice = null);
            unawaited(context.read<MidiSetupCubit>().select(id));
          },
        ),
      ),
      Positioned(
        left: _left,
        top: _rowsTop,
        width: _width,
        bottom: 36,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!control.state.midiLoaded)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(key: Key('midi_loading')),
                ),
              )
            else if (control.state.midiUnavailable)
              Expanded(
                child: Center(
                  child: AppText(
                    l10n.midiConfigurationUnavailable,
                    key: const Key('midi_configuration_unavailable'),
                    style: TextStyle(color: surface.warning, fontSize: 28),
                  ),
                ),
              )
            else if (rows.isEmpty)
              Expanded(
                child: Center(
                  child: AppText(
                    l10n.midiNoMappings,
                    key: const Key('midi_no_mappings'),
                    style: TextStyle(color: surface.textTertiary, fontSize: 32),
                  ),
                ),
              )
            else
              // Loose, so a short list leaves the disconnected notice right
              // under its last row rather than at the foot of the page.
              Flexible(
                child: MidiMappingRows(
                  rows: rows,
                  levels: control.state.midiLevels,
                  onEdit: (mapping) => _edit(control, mapping),
                  onEnabled: (mapping, {required enabled}) => unawaited(
                    _setMappingEnabled(control, mapping, enabled: enabled),
                  ),
                ),
              ),
            // The page's notices sit under the rows, as the accepted design
            // puts them, and are announced when they change.
            if (connection.hasSelection && !connected)
              _Notice(
                l10n.midiControllerDisconnected,
                key: const Key('midi_controller_disconnected'),
              ),
            if (_notice case final notice?)
              _Notice(notice, key: const Key('midi_notice')),
            if (_notice == null &&
                !control.state.midiUnavailable &&
                (control.state.midiPersistenceUncertain ||
                    control.state.midiRemotePaused &&
                        control.state.midiControlEnabled))
              _Notice(
                l10n.midiSaveFailed,
                key: const Key('midi_storage_notice'),
              ),
          ],
        ),
      ),
    ];
  }

  MidiMappingRow _row(
    BuildContext context,
    MidiMapping mapping,
    bool connected,
  ) {
    final l10n = context.l10n;
    final looper = context.read<LooperRepository>();
    final clickVolume = context.watch<TempoCubit>().clickVolume;
    final decaySnapshot = context.watch<PlaybackOptionsCubit>().decaySnapshot;
    final oneShotSnapshot = context
        .watch<PlaybackOptionsCubit>()
        .oneShotSnapshot;
    final missing = mapping.controls.any(
      (control) => switch (control) {
        MidiParameterControl(:final key) => !_resolves(
          looper,
          key,
          clickVolume: clickVolume,
          decaySnapshot: decaySnapshot,
          oneShotSnapshot: oneShotSnapshot,
        ),
        MidiActionControl(:final key) => ControlAction.tryParse(key) == null,
      },
    );
    return MidiMappingRow(
      mapping: mapping,
      name: midiSourceName(l10n, mapping.source),
      targets: [
        for (final control in mapping.controls) _controlLabel(context, control),
      ].join(' · '),
      warning: missing
          ? l10n.midiMissingControl
          : connected
          ? null
          : l10n.midiDeviceDisconnected,
    );
  }

  Future<void> _setControlEnabled(
    ControlCubit control, {
    required bool enabled,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    final result = await control.setMidiControlEnabled(enabled: enabled);
    if (mounted) setState(() => _saving = false);
    // Said on the list it was asked from, or not at all: an editor opened
    // while the write was pending is not where this belongs.
    if (!mounted || _view != _MidiView.list) return;
    final l10n = context.l10n;
    setState(() {
      _notice = !result.saved
          ? l10n.midiControlSettingFailed
          : enabled
          ? l10n.midiControlsEnabled
          : l10n.midiControlsPaused;
    });
  }

  Future<void> _resetConfiguration(ControlCubit control) async {
    if (_saving || !control.state.midiUnavailable) return;
    setState(() => _saving = true);
    final result = await control.resetMidiConfiguration();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _notice = result.saved
          ? context.l10n.pedalSetupSaved
          : context.l10n.midiSaveFailed;
    });
  }

  Future<void> _setMappingEnabled(
    ControlCubit control,
    MidiMapping mapping, {
    required bool enabled,
  }) async {
    setState(() => _notice = null);
    if (_saving) return;
    setState(() => _saving = true);
    final result = await control.setMidiMappingEnabled(
      mapping.id,
      enabled: enabled,
    );
    if (mounted) setState(() => _saving = false);
    if (!mounted || _view != _MidiView.list) return;
    if (result.saved) {
      return;
    }
    setState(() => _notice = context.l10n.midiSaveFailed);
  }

  /// Add mapping: a new draft on the controller in use, listening at once.
  void _add(ControlCubit control, MidiConnection connection) {
    final device = connection.selectedId;
    _closeEditor(control);
    final owner = Object();
    _editOwner = owner;
    _expected = null;
    _editGeneration++;
    control.beginMidiEdit(device: device, owner: owner);
    final draft = MidiMappingDraft(device: device);
    setState(() {
      _draft = draft;
      _view = _MidiView.format;
    });
  }

  void _edit(ControlCubit control, MidiMapping mapping) {
    _closeEditor(control);
    final owner = Object();
    _editOwner = owner;
    _expected = mapping;
    _editGeneration++;
    control.beginMidiEdit(device: mapping.source.device, owner: owner);
    setState(() {
      _draft = MidiMappingDraft.of(mapping);
      _protocol = mapping.source.protocol;
      _view = _MidiView.editor;
      _notice = null;
    });
  }

  // ---------------------------------------------------------------------------
  // The editor and its pickers
  // ---------------------------------------------------------------------------

  Widget _editorActions(
    BuildContext context,
    ControlCubit control,
    MidiMappingDraft draft,
  ) {
    final l10n = context.l10n;
    final state = control.state;
    final listening = state.midiEdit?.learn?.isListening ?? false;
    final canSave =
        !listening && !_saving && draft.canSaveIn(state.midiMappings);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (draft.id != null) ...[
          LoopOutlinedButton(
            key: const Key('midi_delete'),
            width: 120,
            label: l10n.midiDelete,
            onTap: _saving ? null : () => unawaited(_delete(control, draft)),
          ),
          const SizedBox(width: 16),
        ],
        LoopOutlinedButton(
          key: const Key('midi_cancel'),
          width: 125,
          label: l10n.pedalSetupCancel,
          onTap: _saving ? null : () => _leaveEditor(control),
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('midi_save'),
          width: 107,
          tone: LoopButtonTone.accent,
          label: l10n.pedalSetupSave,
          onTap: canSave ? () => unawaited(_save(control, draft)) : null,
        ),
      ],
    );
  }

  Widget? _destinationActions(BuildContext context, MidiMappingDraft? draft) {
    if (draft == null) return null;
    final l10n = context.l10n;
    final carries = MidiMappingDraft.carriesActions(
      draft.source?.protocol ?? _protocol,
    );
    return LoopOutlinedButton(
      key: const Key('midi_performance_actions'),
      width: carries ? 280 : 460,
      label: carries
          ? l10n.midiPerformanceActions
          : l10n.midiPerformanceActionsNeedButton,
      onTap: carries ? () => unawaited(_pickAction(context)) : null,
    );
  }

  List<Widget> _editing(
    BuildContext context,
    ControlCubit control,
    MidiConnection connection,
    MidiMappingDraft draft,
  ) {
    final state = control.state;
    final l10n = context.l10n;
    Widget placed(Widget child) => Positioned(
      left: _left,
      top: _top,
      width: _width,
      height: _pickerHeight,
      child: child,
    );
    switch (_view) {
      case _MidiView.list:
        return const [];
      case _MidiView.editor:
        final connected =
            connection.status == MidiConnectionStatus.connected &&
            connection.selectedId == draft.device;
        return [
          Positioned(
            left: _left,
            top: _top,
            child: MidiSourcePanel(
              deviceName: _deviceName(connection, draft.device),
              draft: draft,
              protocol: _protocol,
              learn: state.midiEdit?.learn,
              connected: connected,
              conflicting: draft.conflictIn(state.midiMappings) != null,
              notice: _notice,
              onFormat: () => _openPicker(control, _MidiView.format),
              onChannel: () => _openPicker(control, _MidiView.channel),
              onLearn: () => _learn(control, draft, _protocol),
              onCancelLearn: () {
                if (_editOwner case final owner?) {
                  control.cancelMidiLearn(owner);
                }
              },
              onEditExisting: () => _editExisting(control, draft),
              onBehavior: _behavior,
            ),
          ),
          Positioned(
            left: _left + MidiSourcePanel.penSize.width + _editorGap,
            top: _top,
            child: MidiControlCards(
              cards: [
                for (final control in draft.controls)
                  MidiControlCard(
                    control: control,
                    label: _controlLabel(context, control),
                    activation:
                        control is MidiParameterControl &&
                        _parameterTarget(control.key) is FxBindingTarget,
                    available: switch (control) {
                      MidiActionControl(:final key) =>
                        ControlAction.tryParse(key) != null,
                      MidiParameterControl(:final key) => _resolves(
                        context.read<LooperRepository>(),
                        key,
                        clickVolume: context.watch<TempoCubit>().clickVolume,
                        decaySnapshot: context
                            .watch<PlaybackOptionsCubit>()
                            .decaySnapshot,
                        oneShotSnapshot: context
                            .watch<PlaybackOptionsCubit>()
                            .oneShotSnapshot,
                      ),
                    },
                  ),
              ],
              behavior: draft.behavior,
              program: draft.isProgram,
              onAdd: () => _openPicker(control, _MidiView.destinations),
              onChange: (key) => _changeControl(control, key),
              onRemove: (key) => _write(draft.without(key)),
              onRange: (key, {low, high}) =>
                  _write(draft.withRange(key, low: low, high: high)),
              onTrigger: (key, trigger) =>
                  _write(draft.withTrigger(key, trigger)),
            ),
          ),
        ];
      case _MidiView.destinations:
        return [
          placed(
            ExpressionDestinationPicker(
              destinations: expressionDestinations(
                l10n,
                context.watch<TracksCubit>().state.names,
                context.read<LooperRepository>(),
                withActivations: true,
                clickVolume: context.watch<TempoCubit>().clickVolume,
                decaySnapshot: context
                    .watch<PlaybackOptionsCubit>()
                    .decaySnapshot,
                oneShotSnapshot: context
                    .watch<PlaybackOptionsCubit>()
                    .oneShotSnapshot,
              ),
              kind: _kind,
              onKind: (kind) => setState(() => _kind = kind),
              onOpen: (destination) => setState(() {
                _destination = destination;
                _view = _MidiView.parameters;
              }),
            ),
          ),
        ];
      case _MidiView.parameters:
        final destination = _destination;
        if (destination == null) return const [];
        return [
          placed(
            ExternalControlTargetList(
              destination: destination,
              taken: {
                for (final control in draft.controls)
                  if (control is MidiParameterControl &&
                      control.key != _replacing)
                    ?_parameterTarget(control.key),
              },
              replacing: _replacing == null
                  ? null
                  : _parameterTarget(_replacing!),
              onParameter: (control) =>
                  _pickTarget(context, draft, control.target),
              onActivation: (activation) =>
                  _pickTarget(context, draft, activation.target),
            ),
          ),
        ];
      case _MidiView.channel:
        return [
          placed(
            MidiChoiceGrid<int?>(
              keyPrefix: 'midi_channel',
              selected: draft.source?.channel,
              choices: [
                MidiChoice(
                  value: null,
                  id: 'omni',
                  label: l10n.midiOmniAllChannels,
                ),
                for (var channel = 0; channel < 16; channel++)
                  MidiChoice(
                    value: channel,
                    id: '$channel',
                    label: l10n.midiChannel(channel + 1),
                  ),
              ],
              onPick: (channel) => setState(() {
                _draft = draft.withChannel(channel);
                _view = _MidiView.editor;
              }),
            ),
          ),
        ];
      case _MidiView.format:
        return [
          placed(
            MidiChoiceGrid<MidiProtocol>(
              keyPrefix: 'midi_format',
              selected: _protocol,
              choices: [
                for (final protocol in MidiProtocol.values)
                  MidiChoice(
                    value: protocol,
                    id: protocol.name,
                    label: midiFormatLabel(l10n, protocol),
                    detail: midiFormatDetail(l10n, protocol),
                  ),
              ],
              onPick: (protocol) => _pickFormat(control, draft, protocol),
            ),
          ),
        ];
    }
  }

  /// Applies what Learn heard, and says when it heard nothing.
  void _onLearn(BuildContext context, ControlState state) {
    final edit = state.midiEdit;
    final draft = _draft;
    if (edit == null ||
        draft == null ||
        edit.device != draft.device ||
        !identical(edit.owner, _editOwner)) {
      return;
    }
    if (edit.learn != null && !identical(edit.learn!.token, _learnToken)) {
      return;
    }
    final reading = edit.learn?.reading;
    if (reading != null) {
      setState(() {
        _draft = draft.learned(reading.source);
        _editGeneration++;
      });
      return;
    }
    if (edit.learnTimedOut) {
      final l10n = context.l10n;
      final connection = context.read<MidiSetupCubit>().state.connection;
      final connected =
          connection.status == MidiConnectionStatus.connected &&
          connection.selectedId == draft.device;
      setState(
        () => _notice = connected
            ? l10n.midiLearnTimedOut
            : l10n.midiLearnReconnect,
      );
    }
  }

  void _write(MidiMappingDraft next) {
    if (_saving) return;
    setState(() {
      _draft = next;
      _editGeneration++;
      _notice = null;
    });
  }

  void _behavior(MidiBehavior behavior) {
    final draft = _draft;
    if (draft == null) return;
    if (behavior == MidiBehavior.continuous && draft.drivesActions) {
      setState(() => _notice = context.l10n.midiActionsNeedButton);
      return;
    }
    _write(draft.withBehavior(behavior));
  }

  void _pickFormat(
    ControlCubit control,
    MidiMappingDraft draft,
    MidiProtocol protocol,
  ) => _learn(control, draft, protocol);

  /// Starts Learn in [protocol], back on the editor — unless the draft drives
  /// actions and [protocol] carries no press to run them on, which every
  /// Learn start refuses, so no path can learn a control the draft's actions
  /// could never run from.
  void _learn(
    ControlCubit control,
    MidiMappingDraft draft,
    MidiProtocol protocol,
  ) {
    if (!MidiMappingDraft.carriesActions(protocol) && draft.drivesActions) {
      setState(() {
        _notice = context.l10n.midiRemoveActionsFirst;
        _view = _MidiView.editor;
      });
      return;
    }
    setState(() {
      _protocol = protocol;
      _notice = null;
      _view = _MidiView.editor;
    });
    final owner = _editOwner;
    if (owner == null) return;
    control.startMidiLearn(
      protocol,
      owner: owner,
      channel: draft.source?.channel,
    );
    _learnToken = control.state.midiEdit?.learn?.token;
  }

  /// Opens a picker. A Learn still listening stops first, as it does in the
  /// accepted design: a control moved while the performer is choosing
  /// something else must not become the mapping's source out of sight. A
  /// Learn that already heard its control keeps what it received on show.
  void _openPicker(ControlCubit control, _MidiView view, {String? replacing}) {
    if (_saving) return;
    if (control.state.midiEdit?.learn?.isListening ?? false) {
      if (_editOwner case final owner?) control.cancelMidiLearn(owner);
    }
    setState(() {
      _editGeneration++;
      _replacing = replacing;
      _view = view;
    });
  }

  void _changeControl(ControlCubit control, String key) {
    final draft = _draft;
    if (draft == null || _saving) return;
    final existing = draft.controls.where((row) => row.key == key).firstOrNull;
    if (existing is MidiActionControl) {
      setState(() {
        _replacing = key;
        _editGeneration++;
      });
      unawaited(_pickAction(context));
    } else {
      _openPicker(control, _MidiView.destinations, replacing: key);
    }
  }

  Future<void> _pickAction(BuildContext context) async {
    final owner = _editOwner;
    final generation = _editGeneration;
    final startingDraft = _draft;
    final replacing = _replacing;
    final l10n = context.l10n;
    final chosen = await showControlActionPicker(
      context,
      title: l10n.midiPerformanceActions,
      current: null,
      trackNames: context.read<TracksCubit>().state.names,
    );
    final draft = _draft;
    if (draft == null ||
        !mounted ||
        _saving ||
        !identical(owner, _editOwner) ||
        !identical(
          this.context.read<ControlCubit>().state.midiEdit?.owner,
          owner,
        ) ||
        !identical(startingDraft, draft) ||
        generation != _editGeneration) {
      return;
    }
    if (chosen == null) {
      setState(() {
        _replacing = null;
        _editGeneration++;
      });
      return;
    }
    // None adds nothing, and like any choice it ends the choosing.
    final action = chosen.value;
    setState(() {
      if (action != null) {
        _draft = replacing == null
            ? draft.withControl(MidiActionControl(key: action.key))
            : draft.repointingAction(replacing, action.key);
      }
      _view = _MidiView.editor;
      _replacing = null;
      _editGeneration++;
    });
  }

  void _pickTarget(
    BuildContext context,
    MidiMappingDraft draft,
    Object target,
  ) {
    if (_saving ||
        !identical(draft, _draft) ||
        !identical(
          context.read<ControlCubit>().state.midiEdit?.owner,
          _editOwner,
        )) {
      return;
    }
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
    final key = switch (target) {
      ControlValueTarget() => target.canonicalString(),
      FxBindingTarget() => target.canonicalString(),
      _ => throw ArgumentError.value(target, 'target'),
    };
    final replacing = _replacing;
    // A repair is only kept by Save; the editor says so, since a card that
    // looks whole again reads as already done.
    final repaired =
        replacing != null &&
        !_resolves(
          context.read<LooperRepository>(),
          replacing,
          clickVolume: context.read<TempoCubit>().clickVolume,
          decaySnapshot: context.read<PlaybackOptionsCubit>().decaySnapshot,
          oneShotSnapshot: context.read<PlaybackOptionsCubit>().oneShotSnapshot,
        );
    final l10n = context.l10n;
    setState(() {
      _draft = replacing == null
          ? draft.withControl(MidiParameterControl(key: key, low: 0, high: 1))
          : draft.repointing(replacing, key);
      _notice = repaired ? l10n.midiRepairReady : null;
      _replacing = null;
      _destination = null;
      _view = _MidiView.editor;
      _editGeneration++;
    });
  }

  void _editExisting(ControlCubit control, MidiMappingDraft draft) {
    if (_saving) return;
    final existing = draft.conflictIn(control.state.midiMappings);
    if (existing == null) return;
    _edit(control, existing);
  }

  void _leaveEditor(ControlCubit control, {String? notice}) {
    _closeEditor(control);
    setState(() {
      _draft = null;
      _replacing = null;
      _destination = null;
      _view = _MidiView.list;
      _notice = notice;
    });
  }

  void _closeEditor(ControlCubit control) {
    final owner = _editOwner;
    if (owner != null) control.endMidiEdit(owner);
    _editOwner = null;
    _learnToken = null;
    _expected = null;
    _editGeneration++;
  }

  void _selectedDeviceChanged(String device) {
    final draft = _draft;
    if (draft == null || draft.device == device || _saving) return;
    final control = _control;
    if (control != null) _closeEditor(control);
    setState(() {
      _draft = null;
      _view = _MidiView.list;
      _replacing = null;
      _destination = null;
      _notice = null;
    });
  }

  Future<void> _save(ControlCubit control, MidiMappingDraft draft) async {
    if (_saving) return;
    final l10n = context.l10n;
    // Save is only offered for a draft that can be saved, and nothing else
    // edits the mappings while the editor is open.
    final owner = _editOwner;
    if (owner == null || !draft.canSaveIn(control.state.midiMappings)) return;
    final mapping = draft.toMapping('draft');
    if (mapping == null) return;
    setState(() => _saving = true);
    final result = await control.saveMidiMapping(
      mapping,
      owner: owner,
      create: draft.id == null,
      expected: _expected,
    );
    if (mounted) setState(() => _saving = false);
    // An editor left, or replaced by another, while the write was pending is
    // not this save's to close.
    if (!mounted ||
        !identical(_draft, draft) ||
        !identical(owner, _editOwner)) {
      return;
    }
    // A save that did not land leaves the set as it was: the draft stays open
    // with everything the performer did to it. Whether the mapping is enabled
    // is the power button's, so it is not part of the comparison.
    if (result.saved) {
      _leaveEditor(control, notice: l10n.pedalSetupSaved);
    } else {
      setState(() => _notice = l10n.midiSaveFailed);
    }
  }

  Future<void> _delete(ControlCubit control, MidiMappingDraft draft) async {
    if (_saving) return;
    final id = draft.id;
    if (id == null) return;
    final owner = _editOwner;
    if (owner == null) return;
    final l10n = context.l10n;
    setState(() => _saving = true);
    final result = await control.deleteMidiMapping(
      id,
      owner: owner,
      expected: _expected,
    );
    if (mounted) setState(() => _saving = false);
    if (!mounted ||
        !identical(_draft, draft) ||
        !identical(owner, _editOwner)) {
      return;
    }
    if (result.saved) {
      _leaveEditor(control, notice: l10n.midiMappingRemoved);
    } else {
      setState(() => _notice = l10n.midiSaveFailed);
    }
  }

  /// Back steps out of a picker, then out of the editor, before it leaves.
  void _back() {
    if (_saving) return;
    final control = _control;
    switch (_view) {
      case _MidiView.list:
        Navigator.of(context).maybePop();
      case _MidiView.editor:
        if (control != null) _leaveEditor(control);
      case _MidiView.destinations:
        setState(() {
          _replacing = null;
          _view = _MidiView.editor;
        });
      case _MidiView.parameters:
        setState(() => _view = _MidiView.destinations);
      case _MidiView.channel:
      case _MidiView.format:
        if (_view == _MidiView.format && _draft?.source == null) {
          if (control != null) _leaveEditor(control);
        } else {
          setState(() => _view = _MidiView.editor);
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Names
  // ---------------------------------------------------------------------------

  String _controlLabel(BuildContext context, MidiControl control) {
    final l10n = context.l10n;
    final names = context.watch<TracksCubit>().state.names;
    switch (control) {
      case MidiActionControl(:final key):
        final action = ControlAction.tryParse(key);
        return action == null
            ? l10n.midiUnavailableAction
            : controlActionLabel(l10n, names, action);
      case MidiParameterControl(:final key):
        final looper = context.read<LooperRepository>();
        final target = ControlValueTarget.tryParse(key);
        if (target != null) {
          final name = expressionTargetName(l10n, names, looper, target);
          return '${name.destination} · '
              '${expressionRowName(l10n, names, looper, target)}';
        }
        final activation = FxBindingTarget.tryParse(key);
        if (activation != null) {
          return '${fxStageLabel(l10n, names, activation.address)} · '
              '${expressionActivationName(l10n, looper, activation)}';
        }
        return l10n.midiMissingControl;
    }
  }

  static bool _resolves(
    LooperRepository looper,
    String key, {
    double? clickVolume,
    DecaySnapshot? decaySnapshot,
    OneShotSnapshot? oneShotSnapshot,
  }) {
    final target = ControlValueTarget.tryParse(key);
    if (target != null) {
      return looper.valueTargetResolves(
        target,
        clickVolume: clickVolume,
        decaySnapshot: decaySnapshot,
        oneShotSnapshot: oneShotSnapshot,
      );
    }
    final activation = FxBindingTarget.tryParse(key);
    return activation != null && looper.bindingResolves(activation);
  }

  static Object? _parameterTarget(String key) =>
      ControlValueTarget.tryParse(key) ?? FxBindingTarget.tryParse(key);

  static String _deviceName(MidiConnection connection, String device) {
    for (final card in midiDeviceCards(connection)) {
      if (card.id == device) return card.name;
    }
    return device;
  }
}

/// One line of the list's notices: what just happened, or what is in the way.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Semantics(
      liveRegion: true,
      child: AppText(
        text,
        style: TextStyle(color: context.surface.warning, fontSize: 22),
      ),
    ),
  );
}
