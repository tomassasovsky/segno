import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/track_mute.dart';
import 'package:segno/control/binding/binding_scope.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_control_writer.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/midi_edit.dart';
import 'package:segno/control/binding/midi_learn.dart';
import 'package:segno/control/binding/owned_value_control.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_binding_set.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/control/control_projection.dart';
import 'package:segno/control/foot_fade_actions.dart';
import 'package:segno/control/foot_mixer_actions.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

part 'control_foot_fade.dart';
part 'control_foot_mixer.dart';
part 'control_midi.dart';
part 'control_state.dart';

/// Controller origins captured before work queues: the Mixer's topology
/// revisions and each owned value's lifetime and ordinary revision.
typedef _ControlOrigins = ({
  Map<MixValueTarget, int> mix,
  Map<OwnedValueTarget, Object> owned,
});

/// The press/long-press state machine every gestural footswitch shares.
///
/// [press] arms a hold timer and remembers the tap action; holding past the
/// threshold runs `onHold` and RETIRES that action, so the matching [release]
/// stays silent. Releasing first runs it instead. Both callbacks are built at
/// press time, so anything a gesture must latch (the undo target channel) is
/// simply captured by the closures — a later on-screen change cannot retarget
/// the action the foot already committed to.
///
/// A gesture whose action fires on the press itself (the FX Stop panic) passes
/// no `onTap`: its release then only retires the pending hold, which is what
/// makes a synthetic release — the on-screen plate note-off'ing a held switch
/// as it leaves the tree — harmless.
///
/// The remembered tap action doubles as the armed flag: a release with nothing
/// pending is inert, so an unmatched release can never fire a stale gesture.
class _HoldGesture {
  Timer? _timer;
  void Function()? _onTap;
  bool Function()? _stillValid;
  bool _active = false;

  void press({
    required Duration threshold,
    required void Function() onHold,
    required bool Function() stillValid,
    void Function()? onTap,
  }) {
    if (_active) return;
    _active = true;
    _onTap = onTap;
    _stillValid = stillValid;
    _timer?.cancel();
    _timer = Timer(threshold, () {
      if (!_active || !stillValid()) {
        cancel();
        return;
      }
      _timer = null;
      _onTap = null; // handled as a hold: the release stays silent
      onHold();
    });
  }

  void release() {
    if (!_active) return;
    final valid = _stillValid?.call() ?? false;
    _active = false;
    _timer?.cancel();
    _timer = null;
    final onTap = _onTap;
    _onTap = null;
    _stillValid = null;
    if (valid) onTap?.call();
  }

  /// Drops the pending hold and tap without running either — cubit teardown.
  void cancel() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _onTap = null;
    _stillValid = null;
  }
}

/// The ONE control-surface interpreter and the ONE owner of stored user
/// intent ([ControlState]) — a single business-logic-layer unit, per the
/// layered architecture: repositories are composed at the bloc level, so
/// there is no domain-service orphan between the repositories and the blocs,
/// and no cubit ever depends on another cubit.
///
/// Inputs arrive only through repository streams and its own methods:
/// - `LooperRepository.looperState` drives [_reduce] — the invalidation
///   table every stored bit obeys (cursor clamps; excluded/parkedResume
///   members drop when their track empties) — plus the frame re-projection.
/// - `PedalRepository.events` delivers the decoded footswitches, which call
///   the SAME intent methods the keyboard and on-screen widgets call — the
///   surfaces cannot diverge in the command sequences they issue.
///
/// Outputs leave only through repositories: engine commands via
/// [LooperRepository], and the projected LED frame (`projectFrame`, a pure
/// function of `(LooperState × ControlState)`) diff-pushed via
/// [PedalRepository]. Derived state is never stored, so it can never go
/// stale.
class ControlCubit extends Cubit<ControlState> {
  /// Creates a [ControlCubit] over the shared repositories.
  ///
  /// [performance] backs the MODE-footswitch long-press gesture
  /// (arm/disarm performance recording, D-PEDAL) and the clear-while-armed
  /// persist-before-clear ordering — composed here rather than routed
  /// through `PerformanceRecorderCubit`, since cubits never call cubits;
  /// that cubit observes this repository's own status stream, so it reflects
  /// a pedal-triggered arm/disarm too.
  ///
  /// [currentChains] resolves the live lane/monitor chains + master-limiter
  /// state to stamp into the arm snapshot, read fresh at each arm — the same
  /// narrow function dependency `PerformanceRecorderCubit` takes for the
  /// toolbar path, so both arm gestures record the same rig. It is injected
  /// rather than mapped here: the mapping lives in the session feature, and a
  /// feature never imports another feature. Defaults to the empty snapshot
  /// (what this call site passed before it was wired).
  /// [controller] is the external-MIDI seam (part 7): its resolved binding
  /// events land at the same dispatch point the pedal's do, so a discrete CC
  /// stomps exactly like a footswitch. [midiDevices] supplies the connectivity
  /// this cubit needs to honour the release-all rule when the MIDI source
  /// itself disappears (B1). Both are optional — a build or test with no MIDI
  /// seam simply never receives external control.
  ///
  /// [takeLocked] suppresses Rec / overdub / perf-arm while the power-off
  /// route is up, so a take cannot start behind the dialog. [inputLocked]
  /// holds continuous writes (expression sweeps, External values, MIDI
  /// values) during Session transitions and disposal only; the power-off
  /// route leaves them running until its flush suspends input.
  ControlCubit({
    required LooperRepository looper,
    required PedalRepository pedal,
    required SettingsRepository settings,
    required PerformanceRepository performance,
    required MixSettingsCoordinator mixSettings,
    required FxChainPersistence fxPersistence,
    required OwnedValueControl ownedValues,
    required FadeSettings fadeSettings,
    ControllerRepository? controller,
    MidiDeviceRepository? midiDevices,
    Duration Function()? midiClock,
    Duration learnTimeout = const Duration(seconds: 15),
    PerformanceChains Function() currentChains = _noChains,
    bool Function() takeLocked = _neverLocked,
    bool Function() inputLocked = _neverLocked,
  }) : _looper = looper,
       _pedal = pedal,
       _settings = settings,
       _performance = performance,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _owned = ownedValues,
       _footFadeActions = FootFadeActions(
         repository: looper,
         settings: fadeSettings,
       ),
       _midiDevices = midiDevices,
       _midiClock = midiClock,
       _learnTimeout = learnTimeout,
       _currentChains = currentChains,
       _takeLocked = takeLocked,
       _inputLocked = inputLocked,
       super(const ControlState()) {
    _fxPersistence.onOrdinaryWrite = _onOrdinaryFxWrite;
    _mixSettings.onOrdinaryValues = _onOrdinaryMixValues;
    _mixSettings.onInvalidatedValues = _invalidateMixTargets;
    _ownedLifetimes = _owned.lifetimes;
    _ownedOrdinarySub = _owned.ordinaryChanges.listen((change) {
      if (change.superseded) _supersedeParameterClaims(change.target);
      if (change.value case final value?) {
        _onOrdinaryFxWrite(change.target, value);
      }
    });
    _midiSession = _looper.sessionRevision;
    _midiCapture = midiDevices?.session;
    _looperSub = _looper.looperState.listen(_onLooperState);
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onLinkStatus);
    _perfStatusSub = _performance.captureStatus.listen(_onPerformanceStatus);
    _bindingSub = controller?.bindingEvents.listen(_onControllerBindingEvent);
    _midiSub = midiDevices?.connections.listen(_onMidiConnection);
    _midiMessageSub = midiDevices?.messages.listen(_onMidiInput);
  }

  final MidiDeviceRepository? _midiDevices;
  final Duration Function()? _midiClock;
  final _midiStopwatch = Stopwatch()..start();
  Duration _midiReadTime = Duration.zero;
  late final _midiDecoder = MidiDecoder(
    clock: () => _midiReadTime,
  );
  late final _midiLearnDecoder = MidiDecoder(
    clock: () => _midiReadTime,
  );
  late final _midiSignalDecoder = MidiDecoder(
    clock: () => _midiReadTime,
  );
  late final _midiEngine = MidiMappingEngine(
    read: _readMidiValue,
    step: _midiStep,
  );
  StreamSubscription<MidiInputMessage>? _midiMessageSub;
  MidiInputSession? _midiCapture;
  int _midiIngressRevision = 0;
  int _midiSession = -1;
  int _nextMidiId = 1;
  Timer? _midiLearnTimer;
  Timer? _midiLevelTimer;
  Map<MidiSource, MidiControlEvent> _midiLevels = {};
  Object? _midiRetryEligibility;
  Future<void> _midiWrites = Future<void>.value();
  int _midiIntentSequence = 0;
  final OwnedValueControl _owned;
  late Object _ownedLifetimes;
  late final StreamSubscription<OwnedValueChange> _ownedOrdinarySub;

  final _midiReleasedValues = <Object, double>{};
  final _midiHolderKeys = <(String, int, int), Object>{};
  final _midiTargets = <(String, int, int), Object>{};
  final _midiActions =
      <(String, int, int), ({ControlAction action, List<int> channels})>{};

  void _reportMidiError(Object error, StackTrace trace) =>
      addError(error, trace);

  void _publishMidi(ControlState next) {
    if (!isClosed) emit(next);
  }

  final _externalContacts = <PedalCtrlInput, bool>{};
  final _externalRetiring = <PedalCtrlInput>{};
  final _externalOn = <PedalCtrlInput, bool>{};
  Future<void> _pedalSetupWrites = Future<void>.value();
  final _externalGestures = <PedalCtrlInput, _HoldGesture>{};
  final _externalTokens = <PedalCtrlInput, Object>{};
  final _externalActions = <PedalCtrlInput, Object>{};
  final _activationHolders =
      <FxBindingTarget, Map<Object, ({bool value, int order})>>{};
  final _parameterHolders =
      <ControlValueTarget, Map<Object, ({double value, int order})>>{};
  final _activationBase = <FxBindingTarget, bool>{};
  var _activationOrder = 0;
  Future<void> _externalTail = Future<void>.value();
  final _externalNumericReleases =
      <PedalCtrlInput, Map<ControlValueTarget, double>>{};
  final _externalPowerReleases = <PedalCtrlInput, Map<FxBindingTarget, bool>>{};
  Object? _externalReleaseEligibility;
  final _externalInvalidatedMix = <PedalCtrlInput, Set<ControlValueTarget>>{};
  final _externalMixReleased =
      <PedalCtrlInput, Map<ControlValueTarget, double>>{};
  final _externalHeldSetups = <PedalCtrlInput, ExternalSwitchSetup>{};
  final _externalQueues = <PedalCtrlInput, Future<void>>{};
  final _expressionRaw = <PedalCtrlJack, int>{};
  PedalCtrlJack? _externalCalibrating;
  int? _externalSession;
  Object? _externalCalibrationOwner;

  /// Suspends the measured source synchronously. Capture remains read-only;
  /// leaving the editor never replays its last measured position.
  void beginExternalCalibration(PedalCtrlJack jack, {required Object owner}) {
    _externalCalibrationOwner = owner;
    _setExternalCalibrating(jack);
  }

  /// Ends only the editor lifetime that currently owns measurement.
  void endExternalCalibration(Object token) {
    if (!identical(_externalCalibrationOwner, token)) return;
    _externalCalibrationOwner = null;
    _setExternalCalibrating(null);
  }

  void _setExternalCalibrating(PedalCtrlJack? jack) {
    if (_externalCalibrating == jack) return;
    final old = _externalCalibrating;
    _externalCalibrating = jack;
    for (final input in PedalCtrlInput.values) {
      if (input.jack == old || input.jack == jack) _retireExternal(input);
    }
  }

  MappingTrigger _externalTrigger(PedalCtrlInput input) => MappingTrigger(
    kind: ControllerSourceKind.consoleSwitch,
    id: input.jack.index + (input.contact == PedalCtrlContact.ring ? 2 : 0),
  );

  PedalCtrlInput? _externalInput(MappingTrigger trigger) {
    if (!trigger.kind.isConsoleCtrl || trigger.id < 0 || trigger.id > 3) {
      return null;
    }
    return PedalCtrlInput(
      trigger.id.isEven ? PedalCtrlJack.ctrl1 : PedalCtrlJack.ctrl2,
      trigger.id < 2 ? PedalCtrlContact.tip : PedalCtrlContact.ring,
    );
  }

  void _retireExternal(PedalCtrlInput input, {bool sessionChanged = false}) {
    if (!sessionChanged && !_externalRetiring.add(input)) return;
    final trigger = _externalTrigger(input);
    final pending =
        _externalQueues.containsKey(input) ||
        _activationHolders.values.any(
          (holders) => holders.containsKey(trigger),
        ) ||
        _parameterHolders.values.any((holders) => holders.containsKey(trigger));
    _externalGestures.remove(input)?.cancel();
    _externalTokens.remove(input);
    _externalActions.remove(input);
    final heldSetup = _externalHeldSetups.remove(input);
    if (!sessionChanged && (pending || heldSetup != null)) {
      // Resolve claims when this queued retirement executes: an already
      // admitted recipe may still be waiting for its exact acknowledgment.
      _queueExternalWrite(
        input,
        const {},
        {
          for (final row
              in heldSetup?.controls.parameters ?? <ExternalParameter>[])
            if (row.condition == ExternalValueCondition.heldReleased)
              row.target: row.inactive,
        },
        token: Object(),
        session: _looper.sessionRevision,
        held: false,
        restoring: true,
        retiring: true,
      );
    }
    _expressionRaw.remove(input.jack);
    if (sessionChanged) {
      _externalRetiring.remove(input);
      _externalNumericReleases.remove(input);
      _externalMixReleased.remove(input);
      _externalPowerReleases.remove(input);
      final trigger = _externalTrigger(input);
      for (final holders in _activationHolders.values) {
        holders.remove(trigger);
      }
      for (final holders in _parameterHolders.values) {
        holders.remove(trigger);
      }
    }
  }

  void _retireAllExternal({bool sessionChanged = false}) {
    for (final input in PedalCtrlInput.values) {
      _retireExternal(input, sessionChanged: sessionChanged);
    }
  }

  void _onConsoleEvent(ControllerSourceEvent event) {
    if (_closing || isClosed) return;
    final session = _looper.sessionRevision;
    if (_externalSession != null && _externalSession != session) {
      _retireAllExternal(sessionChanged: true);
    }
    _externalSession = session;
    if (event case ControllerSourceUnavailable(:final trigger)) {
      final input = _externalInput(trigger);
      if (input != null) {
        _retireExternal(input);
        _externalContacts.remove(input);
      }
      return;
    }
    if (_pedal.status != PedalLinkStatus.connected || _controlInputSuspended) {
      return;
    }
    final raw = event as RawControllerInput;
    final input = _externalInput(raw.trigger);
    if (input == null) return;
    _externalRetiring.remove(input);
    if (raw.kind == ControllerSourceKind.consoleExpression) {
      final before = _expressionRaw[input.jack];
      _expressionRaw[input.jack] = raw.value;
      if (_inputLocked() ||
          before == null ||
          before == raw.value ||
          state.pedalSetupUnavailable ||
          _externalCalibrating == input.jack) {
        return;
      }
      final jack = state.pedalSetup.external.forJack(input.jack);
      if (jack.type != ExternalJackType.expression) return;
      final position = jack.expression.calibration?.positionOf(raw.value);
      if (position == null) return;
      final parameters = <ControlValueTarget, double>{
        for (final mapping in jack.expression.mappings)
          mapping.target: mapping.valueAt(position),
      };
      final token = Object();
      _externalTokens[input] = token;
      _queueExternalWrite(
        input,
        const {},
        parameters,
        token: token,
        session: session,
      );
      return;
    }
    final closed = raw.value != 0;
    final previous = _externalContacts[input];
    _externalContacts[input] = closed;
    if (previous == closed) return;
    if (_takeLocked() ||
        state.pedalSetupUnavailable ||
        _externalCalibrating == input.jack) {
      _retireExternal(input);
      return;
    }
    final setup = state.pedalSetup.external.switchFor(input);
    if (setup == null) return;
    if (setup.hardware == ExternalSwitchHardware.latching) {
      // Establish the first physical state without replaying a held latch.
      if (previous == null) return;
      _fireExternal(input, setup, setup.change, on: closed);
      return;
    }
    if (closed) {
      _externalTokens.putIfAbsent(input, Object.new);
      _externalHeldSetups[input] = setup;
      _queueExternalControls(input, setup, held: true);
      if (setup.gestures.hold == null) {
        _fireExternal(input, setup, setup.gestures.press);
      } else {
        _armGesture(
          _externalGestures.putIfAbsent(input, _HoldGesture.new),
          onHold: () {
            final live = state.pedalSetup.external.switchFor(input);
            if (live != null) {
              _fireExternal(input, live, live.gestures.hold, toggle: false);
            }
          },
          onTap: () {
            final live = state.pedalSetup.external.switchFor(input);
            if (live != null) _fireExternal(input, live, live.gestures.press);
          },
        );
      }
    } else {
      _externalGestures[input]?.release();
      final held = _externalHeldSetups.remove(input);
      if (held != null) {
        _queueExternalControls(input, held, held: false, restoring: true);
      }
    }
  }

  void _fireExternal(
    PedalCtrlInput input,
    ExternalSwitchSetup setup,
    ControlAction? action, {
    bool? on,
    bool toggle = true,
  }) {
    if (_takeLocked() || state.pedalSetupUnavailable) return;
    final session = _looper.sessionRevision;
    final token = Object();
    _externalActions[input] = token;
    _externalTokens.putIfAbsent(input, Object.new);
    final result = action == null
        ? true
        : _runAction(action, _channelsForAction(action));
    void finish({required bool accepted}) {
      if (!accepted ||
          _closing ||
          isClosed ||
          _looper.sessionRevision != session ||
          !identical(_externalActions[input], token) ||
          state.pedalSetup.external.switchFor(input) != setup) {
        return;
      }
      if (!toggle && on == null) return;
      _queueExternalControls(
        input,
        setup,
        on: on ?? false,
        toggleLogical: on == null,
        actionAccepted: action != null,
      );
    }

    if (result is Future<bool>) {
      unawaited(
        result.then(
          (accepted) => finish(accepted: accepted),
          onError: addError,
        ),
      );
    } else {
      finish(accepted: result);
    }
  }

  void _queueExternalControls(
    PedalCtrlInput input,
    ExternalSwitchSetup setup, {
    bool? on,
    bool? held,
    bool restoring = false,
    bool toggleLogical = false,
    bool actionAccepted = false,
  }) {
    final activations = <FxBindingTarget, bool>{};
    final parameters = <ControlValueTarget, double>{};
    for (final row in setup.controls.activations) {
      final value = switch (row.condition) {
        ExternalCondition.on => on,
        ExternalCondition.off => on == null ? null : !on,
        ExternalCondition.held => held,
        ExternalCondition.released => held == null ? null : !held,
      };
      if (value != null) activations[row.target] = value;
    }
    for (final row in setup.controls.parameters) {
      final value = row.condition == ExternalValueCondition.onOff ? on : held;
      if (value != null) {
        parameters[row.target] = value ? row.active : row.inactive;
      }
    }
    final token = _externalTokens[input] ?? Object();
    _queueExternalWrite(
      input,
      activations,
      parameters,
      token: token,
      session: _looper.sessionRevision,
      held: held,
      restoring: restoring,
      requestedReleased: {
        if (held == true)
          for (final row in setup.controls.parameters)
            if (row.target is MixValueTarget || row.target is OwnedValueTarget)
              if (row.condition == ExternalValueCondition.heldReleased)
                row.target: row.inactive,
      },
      logicalSetup: on == null ? null : setup,
      logicalOn: on,
      toggleLogical: toggleLogical,
      actionAccepted: actionAccepted,
    );
  }

  bool _externalIsOn(PedalCtrlInput input) =>
      _externalOn[input] ?? state.pedalSetup.external.logicalOn[input] ?? false;

  void _queueExternalWrite(
    PedalCtrlInput input,
    Map<FxBindingTarget, bool> requested,
    Map<ControlValueTarget, double> requestedParameters, {
    required Object token,
    required int session,
    bool? held,
    bool restoring = false,
    bool retiring = false,
    Map<ControlValueTarget, double> requestedReleased = const {},
    ExternalSwitchSetup? logicalSetup,
    bool? logicalOn,
    bool toggleLogical = false,
    bool actionAccepted = false,
  }) {
    final origins = _controlOrigins({
      ...requestedParameters.keys,
      for (final entry in _parameterHolders.entries)
        if (entry.value.containsKey(_externalTrigger(input))) entry.key,
    });
    final before = _externalTail;
    late final Future<void> next;
    next = before
        .then((_) async {
          if (!restoring && held != false && _inputLocked()) return;
          bool cancelled() =>
              (_closing && !restoring) ||
              isClosed ||
              _looper.sessionRevision != session ||
              (!restoring &&
                  (!identical(_externalTokens[input], token) ||
                      _externalCalibrating == input.jack));
          if (cancelled()) return;
          final trigger = _externalTrigger(input);
          final activations = Map<FxBindingTarget, bool>.of(requested);
          final parameters = Map<ControlValueTarget, double>.of(
            requestedParameters,
          );
          final logical = logicalSetup;
          final nextOn = logical == null
              ? null
              : toggleLogical
              ? !_externalIsOn(input)
              : logicalOn;
          if (logical != null && nextOn != null) {
            for (final row in logical.controls.activations) {
              if (!row.condition.readsContact) {
                activations[row.target] = row.condition == ExternalCondition.on
                    ? nextOn
                    : !nextOn;
              }
            }
            for (final row in logical.controls.parameters) {
              if (row.condition == ExternalValueCondition.onOff) {
                parameters[row.target] = nextOn ? row.active : row.inactive;
              }
            }
          }
          var applied = actionAccepted;
          if (held == false) {
            for (final entry
                in (_externalNumericReleases[input] ?? {}).entries) {
              parameters.putIfAbsent(entry.key, () => entry.value);
            }
            for (final entry in (_externalPowerReleases[input] ?? {}).entries) {
              activations.putIfAbsent(entry.key, () => entry.value);
            }
          }
          if (retiring) {
            for (final entry in _activationHolders.entries) {
              if (entry.value.containsKey(trigger)) {
                activations[entry.key] = false;
              }
            }
            for (final entry in _parameterHolders.entries) {
              if (!entry.value.containsKey(trigger)) continue;
              final survivor = _survivingParameter(
                entry.key,
                excluding: trigger,
              );
              if (survivor != null && !parameters.containsKey(entry.key)) {
                parameters[entry.key] =
                    _readControlValue(entry.key) ?? survivor;
              } else if (survivor == null &&
                  !parameters.containsKey(entry.key)) {
                entry.value.remove(trigger);
              }
            }
          }
          if (held == false) {
            parameters.removeWhere(
              (target, _) =>
                  (target is MixValueTarget || target is OwnedValueTarget) &&
                  (_externalInvalidatedMix[input]?.contains(target) ?? false),
            );
            (_externalNumericReleases[input] ??= {}).addAll(parameters);
            (_externalPowerReleases[input] ??= {}).addAll(activations);
          }
          final literalActivations = Map<FxBindingTarget, bool>.of(activations);
          final literalParameters = Map<ControlValueTarget, double>.of(
            parameters,
          );
          void resolveSurvivors() {
            if (held != false) return;
            for (final entry in literalActivations.entries) {
              activations[entry.key] =
                  (!retiring && entry.value) ||
                  (_survivingActivation(entry.key, excluding: trigger) ??
                      entry.value);
            }
            for (final entry in literalParameters.entries) {
              parameters[entry.key] =
                  _survivingParameter(entry.key, excluding: trigger) ??
                  entry.value;
            }
          }

          resolveSurvivors();
          parameters.removeWhere(
            (target, _) =>
                !_controlValueResolves(target, cleanup: held == false) ||
                !_originCurrent(target, origins),
          );
          activations.removeWhere(
            (target, _) => !_looper.bindingResolves(target),
          );
          final fx = <FxParamTarget, double>{
            for (final e in parameters.entries)
              if (e.key is FxParamTarget && _controlValueResolves(e.key))
                e.key as FxParamTarget: e.value,
          };
          final owners = <FxAddress>{
            ...activations.keys.map((t) => t.address),
            ...fx.keys.map((t) => t.address),
          };
          final priorValues = {
            for (final target in activations.keys)
              target: _looper.bindingEnabled(target),
          };
          void recordParameter(ControlValueTarget target) {
            if (!_originCurrent(target, origins)) return;
            if (held == false) {
              _externalMixReleased[input]?.remove(target);
              _parameterHolders[target]?.remove(trigger);
              _externalNumericReleases[input]?.remove(target);
            } else {
              _externalInvalidatedMix[input]?.remove(target);
              if (target is MixValueTarget || target is OwnedValueTarget) {
                _retireMixBaseline(target);
                _externalMixReleased[input]?.remove(target);
                if (requestedReleased[target] case final low?) {
                  (_externalMixReleased[input] ??= {})[target] = low;
                }
              }
              // Only accepted work supersedes an older same-target cleanup.
              // Later queued releases register when their FIFO work executes.
              _externalNumericReleases[input]?.remove(target);
              (_parameterHolders[target] ??= {})[trigger] = (
                value: parameters[target]!,
                order: ++_activationOrder,
              );
            }
            _syncMidiDurableFx();
          }

          void recordAdmission(Set<FxAddress> admitted) {
            if (held != false) {
              for (final target in fx.keys) {
                if (admitted.contains(target.address)) recordParameter(target);
              }
            }
            for (final target in activations.keys) {
              if (!admitted.contains(target.address)) continue;
              if (held != false ||
                  (!retiring && literalActivations[target] == true)) {
                _externalPowerReleases[input]?.remove(target);
                final prior = priorValues[target];
                if (prior != null) {
                  _activationBase.putIfAbsent(target, () => prior);
                }
                (_activationHolders[target] ??= {})[trigger] = (
                  value: activations[target]!,
                  order: ++_activationOrder,
                );
              }
            }
            _syncMidiDurableFx();
          }

          var accepted = _looper.writeExternalFx(
            activations: activations,
            parameters: fx,
          );
          recordAdmission(accepted);
          if (accepted.length < owners.length && !cancelled()) {
            if (held == false && !_looper.mixSettingsSettled) {
              await _looper.settleMixSettings();
            }
            await _looper.settleFxRecipes(
              waitForCallback: true,
              cancelled: cancelled,
            );
            if (cancelled()) return;
            resolveSurvivors();
            for (final target in fx.keys) {
              fx[target] = parameters[target]!;
            }
            final retry = _looper.writeExternalFx(
              activations: {
                for (final e in activations.entries)
                  if (!accepted.contains(e.key.address)) e.key: e.value,
              },
              parameters: {
                for (final e in fx.entries)
                  if (!accepted.contains(e.key.address)) e.key: e.value,
              },
            );
            recordAdmission(retry);
            accepted = {...accepted, ...retry};
          }
          if (accepted.isNotEmpty) {
            final settled = await _looper.settleFxRecipes(
              waitForCallback: true,
              cancelled: cancelled,
            );
            if (!settled.isOk || cancelled()) return;
            if (held == false) {
              for (final target in fx.keys) {
                if (accepted.contains(target.address)) recordParameter(target);
              }
              for (final target in activations.keys) {
                if (!accepted.contains(target.address)) continue;
                final holders = _activationHolders[target] ??= {};
                if (retiring || literalActivations[target] != true) {
                  holders.remove(trigger);
                }
                if (holders.isEmpty) _activationBase.remove(target);
                _externalPowerReleases[input]?.remove(target);
              }
            }
            _syncMidiDurableFx();
            applied = true;
            if (nextOn != null) _externalOn[input] = nextOn;
            for (final address in accepted) {
              if (cancelled()) return;
              await saveFxOwner(
                settings: _settings,
                projection: _fxPersistence,
                address: address,
              );
            }
          }
          if (cancelled()) return;
          final mixValues = <MixValueTarget, double>{
            for (final entry in parameters.entries)
              if (entry.key case final MixValueTarget target)
                if (_originCurrent(target, origins)) target: entry.value,
          };
          if (mixValues.isNotEmpty) {
            Map<MixValueTarget, double> released() => {
              if (held == true)
                for (final target in mixValues.keys)
                  target: ?requestedReleased[target],
              if (held == false)
                for (final target in mixValues.keys)
                  target: ?_survivingMidiReleased(target, excluding: trigger),
            };
            var outcome = await _mixSettings.setControllerValues(
              mixValues,
              releasedValues: released(),
            );
            if (!outcome.isOk && held == false && !cancelled()) {
              await _mixSettings.runExclusive(() async {});
              if (cancelled()) return;
              resolveSurvivors();
              outcome = await _mixSettings.setControllerValues(
                {
                  for (final target in mixValues.keys)
                    target: parameters[target]!,
                },
                releasedValues: released(),
              );
            }
            if (outcome.isOk && !cancelled()) {
              applied = true;
              mixValues.keys.forEach(recordParameter);
            }
          }
          if (cancelled()) return;
          for (final entry in parameters.entries) {
            if (entry.key case final OwnedValueTarget target) {
              final origin = origins.owned[target];
              if (origin == null) continue;
              final released = held == true
                  ? requestedReleased[target]
                  : held == false
                  ? _survivingMidiReleased(target, excluding: trigger)
                  : null;
              final accepted = await _owned.writeController(
                target,
                entry.value,
                origin: origin,
                released: released,
              );
              if (cancelled()) return;
              if (accepted) {
                applied = true;
                recordParameter(target);
              }
            }
            switch (entry.key) {
              case FxParamTarget() || MixValueTarget() || OwnedValueTarget():
                break;
              case MasterGainTarget():
                if (_looper.setMasterGain(entry.value).isOk) {
                  _masterGain = entry.value;
                  applied = true;
                  recordParameter(entry.key);
                }
            }
            if (cancelled()) return;
          }
          if (applied && nextOn != null && !cancelled()) {
            _externalOn[input] = nextOn;
            try {
              await _enqueuePedalSetup(
                () => _withLiveLogicalIntent(state.pedalSetup),
              );
            } on Object catch (error, trace) {
              if (!_closing && !isClosed) {
                emit(state.copyWith(pedalSetupRuntimeUnsaved: true));
                addError(error, trace);
              }
            }
          }
          if (_externalNumericReleases.values.any((v) => v.isNotEmpty) ||
              _externalPowerReleases.values.any((v) => v.isNotEmpty)) {
            _externalReleaseEligibility = _releaseEligibility;
          }
          _syncMidiDurableFx();
          _pushProjected();
        })
        .catchError((Object error, StackTrace trace) {
          if (logicalSetup != null && !_closing && !isClosed) {
            emit(state.copyWith(pedalSetupRuntimeUnsaved: true));
          }
          addError(error, trace);
        })
        .whenComplete(() {
          if (identical(_externalQueues[input], next)) {
            final _ = _externalQueues.remove(input);
          }
        });
    _externalQueues[input] = next;
    _externalTail = next;
  }

  Object get _releaseEligibility => (
    _looper.sessionRevision,
    _looper.mixGeneration,
    _looper.mixSettingsSettled,
    _looper.fxRecipesSettled,
    _owned.eligibilityKey,
    _looper.mixSettingsSnapshot,
  );

  void _retryExternalReleases() {
    if (_externalNumericReleases.values.every((v) => v.isEmpty) &&
        _externalPowerReleases.values.every((v) => v.isEmpty)) {
      return;
    }
    final eligibility = _releaseEligibility;
    if (eligibility == _externalReleaseEligibility) return;
    _externalReleaseEligibility = eligibility;
    if (!_looper.mixSettingsSettled || !_looper.fxRecipesSettled) return;
    for (final input in PedalCtrlInput.values) {
      if (_externalQueues.containsKey(input)) continue;
      final parameters = _externalNumericReleases[input] ?? {};
      final powers = _externalPowerReleases[input] ?? {};
      if (parameters.isEmpty && powers.isEmpty) continue;
      _queueExternalWrite(
        input,
        Map.of(powers),
        Map.of(parameters),
        token: Object(),
        session: _looper.sessionRevision,
        held: false,
        restoring: true,
      );
    }
  }

  bool? _survivingActivation(
    FxBindingTarget target, {
    Object? excluding,
  }) {
    ({bool value, int order})? latest;
    for (final entry in (_activationHolders[target] ?? {}).entries) {
      if (entry.key == excluding) continue;
      if (latest == null || entry.value.order > latest.order) {
        latest = entry.value;
      }
    }
    return latest?.value;
  }

  double? _survivingParameter(
    ControlValueTarget target, {
    Object? excluding,
  }) {
    ({double value, int order})? latest;
    for (final entry in (_parameterHolders[target] ?? {}).entries) {
      if (entry.key == excluding) continue;
      if (latest == null || entry.value.order > latest.order) {
        latest = entry.value;
      }
    }
    return latest?.value;
  }

  /// The default `currentChains`: an empty rig, which is what
  /// [PerformanceRepository.arm] already assumes when given nothing.
  static PerformanceChains _noChains() => const PerformanceChains();

  static bool _neverLocked() => false;

  final LooperRepository _looper;
  final PedalRepository _pedal;
  final SettingsRepository _settings;
  final PerformanceRepository _performance;
  final MixSettingsCoordinator _mixSettings;
  final FxChainPersistence _fxPersistence;
  final Duration _learnTimeout;
  final PerformanceChains Function() _currentChains;
  final bool Function() _takeLocked;

  /// Holds continuous writes (expression, External values, MIDI values)
  /// during Session transitions and disposal. The power-off route does not
  /// hold them: it blocks only takes, through [_takeLocked].
  final bool Function() _inputLocked;
  bool _haltInputSuspended = false;
  bool _inputRetired = false;
  bool get _controlInputSuspended {
    if (!_takeLocked()) _haltInputSuspended = false;
    return _haltInputSuspended;
  }

  late final StreamSubscription<LooperState> _looperSub;
  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  late final StreamSubscription<PerformanceCaptureStatus> _perfStatusSub;

  StreamSubscription<ControllerDispatchEvent>? _bindingSub;
  StreamSubscription<MidiConnection>? _midiSub;

  // Encoder accumulator, kept in step with accepted controller writes.
  // The repository separately retains desired master gain across restarts.
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // One threshold for Undo, Mode, Record/Play, track holds, Stop restore and
  // assigned FX holds. Read at press time; the fresh default is 800 ms.
  Duration _longPress = const Duration(milliseconds: 800);
  Object _surfaceVisit = Object();
  (int, int)? _footMixerSource;
  final FootFadeActions _footFadeActions;
  int _footFadeSession = 0;
  late final _footMixerActions = FootMixerActions(
    repository: _looper,
    settings: _settings,
    mix: _mixSettings,
    persistence: _fxPersistence,
  );

  final _physicalContact = Object();
  final _pressedButtons = <PedalButton, Object>{};
  final _bindingGestures = <PedalButton, _HoldGesture>{};
  // Remembers the completed action identity, not its enabled value. The LED
  // always reads that action's current function state from the rig.
  final _customLastActions =
      <PedalBindingKey, ({ControlAction action, List<int> channels})>{};
  final _customActiveKeys = <PedalButton, PedalBindingKey>{};
  final _customDispatchTokens = <PedalButton, Object>{};
  final _acceptedContacts = <PedalButton>{};
  int _customActionSession = -1;
  final _displayBoundTargets =
      <
        PedalButton,
        ({
          PedalBinding binding,
          FxBindingTarget target,
          BindingBehavior behavior,
          BindingScope scope,
          int cursor,
        })
      >{};

  // Undo: tap = undo, long-press = redo. The target channel is LATCHED at
  // press time (captured by the callbacks) — an on-screen click mid-hold must
  // not retarget the action the foot already committed to.
  final _undoGesture = _HoldGesture();

  // MODE uses the configured Press/Hold pair.
  final _modeGesture = _HoldGesture();
  // Until Custom transport dispatch lands, Bank retains the working
  // alternate performance-recording Hold beside its page-switch tap.
  final _bankGesture = _HoldGesture();
  final _recordHoldGesture = _HoldGesture();
  final _trackHoldGestures = <PedalButton, _HoldGesture>{};

  // The current FX door returns to the mode that entered it. Every entry
  // through setMode updates this latch.
  InteractionMode _fxReturn = InteractionMode.record;

  // The FX-mode Stop long-press (restore every Track chain). The panic half
  // fires on the press, so this one arms no tap action — only the hold.
  final _stopGesture = _HoldGesture();

  // The remap (part 6b) lives in ControlState — it is stored user intent, and
  // the surfaces that render it rebuild on emit. What stays here is only the
  // mid-gesture restore VALUES: the enabled state each held press captured,
  // which no surface renders and which must not survive a hot restart.
  //
  // Keyed by [PedalBindingKey] rather than by target, so two bindings on one
  // target each restore what THEY captured (last writer wins, per
  // [PedalBinding]'s doc). A button can only be held once, so the key is
  // unique for the lifetime of a press. Kept in lockstep with
  // `state.heldMomentary`, which is the same key set.
  final _heldRestore =
      <
        PedalBindingKey,
        ({FxBindingTarget target, bool prior, int session, Object holder})
      >{};
  final _bindingDecisions = <Object, Future<void>>{};
  final _pendingRestore = <PedalBindingKey>{};
  Future<void>? _restoreWait;
  bool _closing = false;

  // Whether the Clear footswitch is currently held down. Lights the Clear
  // LED (the `clearFadeActive` frame bit) for as long as it is pressed.
  bool _clearHeld = false;
  Object? _clearPressToken;

  // Mirrors `PerformanceRepository.captureStatus` so the pedal frame can
  // render the armed LED without re-deriving it from the raw status stream on
  // every projection. Independent of `ControlState` (nothing routes through
  // stored intent), so a status change re-projects directly rather than
  // through `emit`.
  bool _performanceArmed = false;

  // Latest looper snapshot.
  LooperState? _looperState;

  Future<void>? _loadFuture;

  List<Track> get _tracks => _l.tracks;

  /// The looper truth every intent method reads: the last POLLED snapshot —
  /// the SAME one the frame projection and the invariant spec are defined
  /// over. `LooperRepository.state` is a live engine read; deciding intent
  /// from it while projecting from the polled copy let the two skew inside
  /// one emit whenever an engine change landed between polls (e.g. a record
  /// starting right before a mode toggle), tripping the projection-time
  /// invariant assert. Live read only before the first poll arrives.
  LooperState get _l => _looperState ?? _looper.state;

  Track? _trackAt(int channel) =>
      channel >= 0 && channel < _tracks.length ? _tracks[channel] : null;

  /// A track that exists and holds (or is finishing) a loop.
  bool _playable(Track? track) =>
      track != null && (track.hasContent || track.isCapturing);

  /// Content tracks whose playhead is RUNNING (playing or overdubbing),
  /// mute-ignored — what a park must freeze, and what it resumes.
  Set<int> _running() => {
    for (final t in _tracks)
      if (t.hasContent &&
          (t.state == TrackState.playing || t.state == TrackState.overdubbing))
        t.channel,
  };

  /// Restores the persisted boot-default mode (applying it — a `mute`
  /// default runs the same entry side effects as a live toggle) and the
  /// undo long-press threshold.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _longPress = Duration(milliseconds: await _settings.loadPedalLongPressMs());
    final storedBindings = PedalBindingSet.decode(
      await _settings.loadPedalBindings() ?? '',
    );
    // bootDefaultFromToken, not fromToken: a stored `'fx'` (hand-edited or
    // corrupted — no build writes it) falls back to record rather than booting
    // the dead FX surface (R12).
    final defaultMode = InteractionMode.bootDefaultFromToken(
      await _settings.loadDefaultInteractionMode(),
    );
    var setup = state.pedalSetup;
    var setupUnavailable = false;
    try {
      final encodedSetup = await _settings.loadPedalSetup();
      setup = encodedSetup == null
          ? const PedalSetup()
          : PedalSetup.decode(encodedSetup);
    } on FormatException catch (error, stackTrace) {
      // A corrupt explicit action must not become a default live command.
      setupUnavailable = true;
      addError(error, stackTrace);
    }
    if (_inputRetired || _closing || isClosed) return;
    emit(
      state.copyWith(
        defaultMode: defaultMode,
        pedalSetup: setup,
        pedalSetupUnavailable: setupUnavailable,
        globalBindings: storedBindings,
      ),
    );
    await _loadMidiConfiguration();
    if (_inputRetired || _closing || isClosed) return;
    setMode(defaultMode);
  }

  // ---------------------------------------------------------------------------
  // The looper reducer: the stored-intent invalidation table.
  // ---------------------------------------------------------------------------

  void _reduce(LooperState looper, {bool wasParked = false}) {
    var next = state;

    // Cursor: always a valid channel.
    if (looper.tracks.isNotEmpty &&
        (state.cursor < 0 || state.cursor >= looper.tracks.length)) {
      final cursor = state.cursor.clamp(0, looper.tracks.length - 1);
      next = next.copyWith(
        cursor: cursor,
        activeBank: cursor ~/ ControlState.tracksPerBank,
      );
    }

    // Excluded / parkedResume: membership requires a track that still holds
    // (or is finishing) a loop. An emptied track (undo-to-empty, clear,
    // clear-all, session load) drops out, so no stored set can reference a
    // ghost.
    bool playable(int channel) {
      if (channel < 0 || channel >= looper.tracks.length) return false;
      final t = looper.tracks[channel];
      return t.hasContent || t.isCapturing;
    }

    if (state.excluded.any((c) => !playable(c))) {
      next = next.copyWith(excluded: state.excluded.where(playable).toSet());
    }
    // Consumed on the parked -> running transition: the derived armed set
    // carries the resumed members from here. Only the transition: a Stop
    // latches the set while the loop still runs (its stops land a callback
    // later), and a running snapshot in between must not erase that latch.
    final running = looper.tracks.any(
      (t) =>
          t.hasContent &&
          (t.state == TrackState.playing || t.state == TrackState.overdubbing),
    );
    if (wasParked && running && state.parkedResume.isNotEmpty) {
      next = next.copyWith(parkedResume: const <int>{});
    } else if (state.parkedResume.any((c) => !playable(c))) {
      next = next.copyWith(
        parkedResume: state.parkedResume.where(playable).toSet(),
      );
    }

    if (state.mode == InteractionMode.mixer) {
      final source = (_looper.sessionRevision, _looper.mixGeneration);
      if (_footMixerSource != source) {
        _footMixerSource = source;
        _cancelSurfaceHolds();
        next = next.copyWith(
          footMixer: _footMixerActions.domain(state.footMixer.domain),
        );
      } else {
        next = next.copyWith(
          footMixer: _footMixerActions
              .project(state.footMixer, looper: looper)
              .selection,
        );
      }
    }
    // A new Session starts from Default; a time target whose track lost its
    // material falls back to it too. Pending holds already retire on a
    // Session change (_armGesture).
    if (state.mode == InteractionMode.fade) {
      final session = _looper.sessionRevision;
      next = next.copyWith(
        footFade: session != _footFadeSession
            ? const FootFadeSelection()
            : _footFadeActions
                  .project(
                    state.footFade,
                    bank: next.activeBank,
                    looper: looper,
                  )
                  .selection,
      );
      _footFadeSession = session;
    }
    if (next != state) emit(next);
  }

  // ---------------------------------------------------------------------------
  // Mode
  // ---------------------------------------------------------------------------

  /// Cycles Tracks -> Mute -> FX -> Custom -> Tracks for the mode chip.
  ///
  /// Side effects
  /// fire for the LANDED mode only — cycling PAST a mode never runs its entry
  /// work (A5), which falls out of [setMode] being the single entry point.
  ///
  /// This stays independent of the pedal's own configured Press/Hold pair.
  void toggleMode() => setMode(switch (state.mode) {
    InteractionMode.record => InteractionMode.mute,
    InteractionMode.mute => InteractionMode.fx,
    InteractionMode.fx => InteractionMode.custom,
    InteractionMode.custom ||
    InteractionMode.mixer ||
    InteractionMode.fade => InteractionMode.record,
  });

  /// Saves the built-in pedal setup before making it live. A storage refusal
  /// leaves both the current gestures and the confirmed setup untouched.
  Future<void> setPedalSetup(PedalSetup setup) => _enqueuePedalSetup(
    () => _withLiveLogicalIntent(
      setup.copyWith(
        external: state.pedalSetup.external.withConfigurationFrom(
          setup.external,
        ),
      ),
    ),
  );

  PedalSetup _withLiveLogicalIntent(PedalSetup setup) {
    var external = setup.external;
    for (final entry in _externalOn.entries) {
      external = external.withLogicalOn(entry.key, on: entry.value);
    }
    return setup.copyWith(external: external);
  }

  Future<void> _enqueuePedalSetup(PedalSetup Function() latest) {
    final write = _pedalSetupWrites.then((_) async {
      await load();
      if (_closing || isClosed) return;
      await _persistPedalSetup(latest());
    });
    _pedalSetupWrites = write.catchError((Object _, StackTrace _) {});
    return write;
  }

  Future<void> _persistPedalSetup(PedalSetup setup) async {
    // The boot read may already hold an older checkpoint. Settle it first so
    // it cannot publish that checkpoint after this Save completes.
    await load();
    if (isClosed) return;
    if (setup == state.pedalSetup &&
        !state.pedalSetupPersistenceUncertain &&
        !state.pedalSetupUnavailable &&
        !state.pedalSetupRuntimeUnsaved) {
      return;
    }
    try {
      await _settings.savePedalSetup(setup.encode());
    } on PedalSetupSaveException catch (error) {
      if (!isClosed && !error.checkpointRestored) {
        emit(state.copyWith(pedalSetupPersistenceUncertain: true));
      }
      rethrow;
    }
    if (isClosed) return;
    // A hue edit changes the frame but not the action already accepted under
    // a foot. Retire gestures only when their actual dispatch configuration
    // changed, or when recovering from an unavailable stored setup.
    final behaviorChanged =
        state.pedalSetupUnavailable ||
        setup.copyWith(
              palette: state.pedalSetup.palette,
              external: state.pedalSetup.external,
            ) !=
            state.pedalSetup ||
        !setup.external.sameConfigurationAs(state.pedalSetup.external);
    if (behaviorChanged) {
      _retireAllExternal();
      _invalidateGestures();
      _customLastActions.clear();
      _fxReturn = InteractionMode.record;
    }
    emit(
      state.copyWith(
        pedalSetup: setup,
        pedalSetupRuntimeUnsaved: false,
        pedalSetupPersistenceUncertain: false,
        pedalSetupUnavailable: false,
      ),
    );
  }

  /// Applies [next] with its entry side effects; a no-op when already there.
  ///
  /// Entering Mute previews the whole content set: `parkedResume` = every
  /// track holding (or capturing) a loop, so Rec/Play resumes them all and
  /// the parked LEDs show it — including stopped and muted tracks, which
  /// pure `sounding` could never cover. A live capture survives THIS entry:
  /// the mode toggle is a view change, not a transport action.
  ///
  /// Entering FX cancels every PENDING record arm — quantized, sound-armed,
  /// or a Band section toggle. An arm is the one thing that could start a take
  /// the user never sees: it fires on its own, seconds later, in a mode whose
  /// transport controls are all inert. The cancel is unconditional
  /// (`LooperRepository.cancelArm`), so no engine setting can turn it into a
  /// press with different meaning.
  ///
  /// Entering FX then ENDS every live non-defining capture at the entry
  /// gesture (#405, `LooperRepository.finalizeTake`): the engine's immediate
  /// finalize ends the take exactly as a quantize-off record press would —
  /// rounded up to whole base loops, the tail staying silence, never
  /// off-grid — instead of letting a forgotten take grow toward the
  /// recording cap in a mode whose transport controls are all inert. (A
  /// record press could never do this: under quantize it ARMS a loop-top
  /// finalize instead — the withdrawn A5 attempt.) The DEFINING take — the
  /// one establishing the loop length — is the exception: the engine REFUSES
  /// it, because a mode switch must not be the gesture that sets the
  /// session's bar length, and the refusal is silently accepted — that
  /// capture survives into FX exactly as it survives Mute, ending when the
  /// user cycles back to Rec. A count-in in progress is aborted outright
  /// (nothing has been captured yet). Overdubs are out of scope: bounded and
  /// cycling, they ride on under FX exactly as under Mute.
  ///
  /// Any mode entry clears the stored mute-mode intent (the invalidation
  /// table).
  void setMode(InteractionMode next) {
    if (next == state.mode) return;
    _surfaceVisit = Object();
    // Leaving the mode the bindings live in strands any held momentary — the
    // release will arrive with the foot in a mode that no longer dispatches
    // it, or not at all. Restore first (B1), before the emit re-projects.
    _invalidateGestures();
    switch (next) {
      case InteractionMode.record:
        emit(
          state.copyWith(
            mode: InteractionMode.record,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
      case InteractionMode.mute:
        emit(
          state.copyWith(
            mode: InteractionMode.mute,
            excluded: const <int>{},
            parkedResume: {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            },
          ),
        );
      case InteractionMode.fade:
        _footFadeSession = _looper.sessionRevision;
        emit(
          state.copyWith(
            mode: next,
            footFade: const FootFadeSelection(),
            excluded: const {},
            parkedResume: const {},
          ),
        );
      case InteractionMode.mixer:
        _footMixerSource = (_looper.sessionRevision, _looper.mixGeneration);
        emit(
          state.copyWith(
            mode: next,
            footMixer: _footMixerActions.enter(state.cursor),
            excluded: const {},
            parkedResume: const {},
          ),
        );
      case InteractionMode.custom:
        // No entry side effects of its own. Custom mode changes what the
        // SWITCHES mean and nothing else — it arms nothing, cancels nothing
        // and moves no transport, so there is nothing here for a mode
        // change to undo later.
        emit(
          state.copyWith(
            mode: InteractionMode.custom,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
      case InteractionMode.fx:
        // Cancel arms BEFORE the emit so the projection that rides it already
        // describes the post-entry intent (the engine's own state follows one
        // poll later, as it does for every other command).
        //
        // A launch can be queued before either snapshot reports it. Sweep
        // the fixed addresses: cancellation is FIFO and a no-op when empty.
        final looper = _looper.state;
        for (
          var channel = 0;
          channel < ControlState.bankCount * ControlState.tracksPerBank;
          channel++
        ) {
          if (!_looper.cancelArm(channel: channel).isOk) return;
        }
        _fxReturn = state.mode;
        // Then end every live non-defining take at the entry gesture (#405).
        // AFTER the arm sweep by construction: the primitive refuses while a
        // pending arm is live on the channel, and the sweep is what retires
        // them. Refusals are silently accepted — that IS the defining-take
        // fallback (the capture survives, as documented above). RECORDING
        // only: an overdub rides on, exactly as under Mute.
        for (final track in looper.tracks) {
          if (track.state == TrackState.recording) {
            _looper.finalizeTake(channel: track.channel);
          }
        }
        emit(
          state.copyWith(
            mode: InteractionMode.fx,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
    }
  }

  /// Sets and persists the default [mode] the system boots into, applying it
  /// to the live mode now.
  ///
  /// Ignores a mode outside [InteractionMode.bootDefaults] (R12): the settings
  /// picker never offers FX, and a boot into FX with no chains configured is a
  /// dead surface.
  Future<void> setDefaultMode(InteractionMode mode) async {
    // Loud in debug, defensive in release: a caller offering FX here has a
    // bug, but shipping a dead boot surface is the worse outcome.
    assert(
      InteractionMode.bootDefaults.contains(mode),
      '$mode is not a boot-eligible default mode',
    );
    if (!InteractionMode.bootDefaults.contains(mode)) return;
    emit(state.copyWith(defaultMode: mode));
    setMode(mode);
    await _settings.saveDefaultInteractionMode(mode.token);
  }

  // ---------------------------------------------------------------------------
  // Cursor / bank
  // ---------------------------------------------------------------------------

  /// Moves the shared cursor to [channel], following it into its bank (a
  /// cursor can never hide behind the other bank).
  void selectTrack(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    emit(
      state.copyWith(
        cursor: channel,
        activeBank: channel ~/ ControlState.tracksPerBank,
      ),
    );
  }

  /// Reveals [bank] WITHOUT moving the cursor — the browse flow (e.g. arming
  /// the other bank's tracks in mute mode).
  void browseBank(int bank) {
    if (bank < 0 || bank >= ControlState.bankCount) return;
    emit(state.copyWith(activeBank: bank));
  }

  /// Toggles the visible bank, moving the cursor to the new bank's first
  /// track — the pedal BANK footswitch / keyboard `B` semantics.
  void toggleBankWithCursor() =>
      selectTrack((state.activeBank == 0 ? 1 : 0) * ControlState.tracksPerBank);

  // ---------------------------------------------------------------------------
  // Rec/Play
  // ---------------------------------------------------------------------------

  /// The Rec/Play action under the current mode.
  ///
  /// INERT in FX mode (A4): the "act on the focused track" reading was
  /// rejected — focus has no on-pedal indicator, so an invisible target would
  /// be mis-stomped. The switch is reserved for a later part rather than given
  /// a guessable meaning.
  void recPlay() {
    if (_takeLocked()) return;
    switch (state.mode) {
      case InteractionMode.record:
      case InteractionMode.mixer:
      case InteractionMode.fade:
        _recAdvance(state.cursor);
      case InteractionMode.mute:
        _muteRecPlay();
      case InteractionMode.fx:
      case InteractionMode.custom:
        // Inert. In FX the switch is reserved (A4); in custom it runs
        // whatever the setup assigned, dispatched at the press rather than
        // here, so this path must not also act.
        break;
    }
  }

  EngineResult _setTrackMute({required bool muted, required int channel}) =>
      applyTrackMute(
        looper: _looper,
        settings: _settings,
        persistence: _fxPersistence,
        channel: channel,
        muted: muted,
        onError: (error, stack) {
          if (!isClosed) addError(error, stack);
        },
      );

  /// Rec mode: advance the cursor track through record / overdub / play. A
  /// muted track is first unmuted and brought back: overdub if its loop still
  /// runs, plain resume if it was parked (the engine unparks the rest of the
  /// loop with it — starting anything resumes everything).
  bool _recAdvance(int channel) {
    final track = _trackAt(channel);
    if (track != null && track.muted) {
      if (!_setTrackMute(muted: false, channel: channel).isOk) return false;
      if (track.state == TrackState.stopped) {
        return _looper.play(channel: channel).isOk; // parked -> resume
      } else {
        return _recordAccepted(channel);
      }
    }
    // The engine's cycling record() walks empty -> record, capturing -> play
    // (finalize), playing -> overdub.
    return _recordAccepted(channel);
  }

  /// A Record press counts as accepted when the engine took it, or when the
  /// repository still owes it the one retry a fresh capture refused inside the
  /// callback's one-block window gets (#1146): the press is not lost, so its
  /// contact stays lit while it resolves.
  bool _recordAccepted(int channel) {
    final result = _looper.record(channel: channel);
    return result.isOk ||
        (result == EngineResult.notReady &&
            _looper.recordRetryPending(channel));
  }

  /// Mute mode Rec/Play: resume while parked; while running, expand to the
  /// whole content set (a no-op when everything audible is already in).
  bool _muteRecPlay() {
    if (isParked(_l)) {
      final resume = state.parkedResume.isNotEmpty
          ? state.parkedResume
          : {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            };
      if (resume.isEmpty) return false; // nothing recorded yet
      // The engine unparks the ENTIRE loop on the first play (starting
      // anything resumes everything), so a deselected member must be muted
      // BEFORE any play rides the ring: it comes back running-but-silent —
      // exactly what its dark parked LED promised — and stays in phase for a
      // later unmute, instead of staying frozen. A CAPTURING track is not a
      // deselected member — it is a live take (isParked ignores `recording`,
      // so one can be running under a parked transport) and muting it would
      // punch it out; leave it alone.
      var muteAccepted = true;
      for (final track in _tracks) {
        if (_playable(track) &&
            !track.isCapturing &&
            !resume.contains(track.channel) &&
            !track.muted) {
          if (!_setTrackMute(muted: true, channel: track.channel).isOk) {
            muteAccepted = false;
          }
        }
      }
      for (final channel in resume) {
        if (!_setTrackMute(muted: false, channel: channel).isOk) {
          muteAccepted = false;
        }
      }
      // The first play resumes every member. Admit the complete mute plan
      // first, retaining membership for retry if any prerequisite refused.
      if (!muteAccepted) return false;
      var accepted = false;
      for (final channel in resume) {
        accepted = _looper.play(channel: channel).isOk || accepted;
      }
      // Kept until the transport is observed running (the reducer clears it
      // then): with a count-in or quantized launch the plays are deferred, the
      // loop is still parked, and the parked LEDs and a second Rec/Play (which
      // toggles the same members, cancelling the pending launch) must keep
      // using this membership rather than re-deriving every playable track.
      return accepted;
    }
    // Running: expand to every content track unless the full audible set is
    // already in the mix (then the press is a no-op).
    final armed = armedTracks(_l, state);
    final all = {
      for (final track in _tracks)
        if (track.hasContent) track.channel,
    };
    final anyAudible = _tracks.any(
      (t) => armed.contains(t.channel) && !t.muted && isSounding(t),
    );
    if (anyAudible && armed.containsAll(all)) return false;
    var muteAccepted = true;
    for (final channel in all) {
      if (!_setTrackMute(muted: false, channel: channel).isOk) {
        muteAccepted = false;
      }
    }
    if (!muteAccepted) return false;
    var accepted = false;
    for (final channel in all) {
      accepted = _looper.play(channel: channel).isOk || accepted;
    }
    return accepted;
  }

  // ---------------------------------------------------------------------------
  // Stop
  // ---------------------------------------------------------------------------

  /// The Stop action under the current mode (the pedal's Stop TAP; its
  /// long-press is [restoreAllTrackChains], handled at the press/release
  /// layer like undo/redo's).
  void stop() {
    switch (state.mode) {
      case InteractionMode.record:
        _recStop(state.cursor);
      case InteractionMode.mute:
      case InteractionMode.mixer:
      case InteractionMode.fade:
        parkAll();
      case InteractionMode.fx:
        panicTrackChains();
      case InteractionMode.custom:
        // Inert here: the switch runs its assignment at the press.
        break;
    }
  }

  /// Rec mode: mute the cursor track (finalizing a capture first). Muting the
  /// only audible loop parks the whole transport.
  bool _recStop(int channel) {
    final track = _trackAt(channel);
    if (track == null) return false;
    if (!_looper.stopRecordControl(channel: channel).isOk) {
      return false;
    }
    if (!_setTrackMute(muted: true, channel: channel).isOk) return false;
    if (track.state == TrackState.playing && _isLastAudibleTrack(channel)) {
      for (final t in _tracks) {
        _looper.stopTrack(channel: t.channel);
      }
    }
    return true;
  }

  /// Parks the play transport: freezes EVERY running content track (muted
  /// ones too — mute silences, park freezes) and latches what Rec/Play brings
  /// back at INTENT time, before engine truth catches up with the stops.
  void parkAll() {
    _parkAllAccepted();
  }

  bool _parkAllAccepted() {
    if (!_looper.cancelCountIn().isOk) return false;
    final running = _running();
    if (running.isEmpty) return true; // Keep the parked resume set.
    emit(
      state.copyWith(
        parkedResume: {...running}..removeWhere(state.excluded.contains),
      ),
    );
    var accepted = false;
    for (final channel in running) {
      accepted = _looper.stopTrack(channel: channel).isOk || accepted;
    }
    return accepted;
  }

  // ---------------------------------------------------------------------------
  // Track buttons (pedal semantics)
  // ---------------------------------------------------------------------------

  /// A track-button press on [channel] under the current mode — the pedal's
  /// footswitch semantics.
  void trackPressed(int channel) {
    if (state.mode == InteractionMode.record && _takeLocked()) return;
    switch (state.mode) {
      case InteractionMode.record:
        _recTrackPressed(channel);
      case InteractionMode.mute:
        _muteTrackPressed(channel);
      case InteractionMode.fx:
        toggleTrackChain(channel);
      case InteractionMode.mixer:
      case InteractionMode.fade:
        break;
      case InteractionMode.custom:
        // Inert here: the switch runs its assignment at the press. Note the
        // on-screen surfaces still call this — selection happens at their
        // own call sites, so a tile tap in custom mode selects and stops.
        break;
    }
  }

  /// Rec mode: select the track, or hand off a live recording to it.
  void _recTrackPressed(int channel) {
    final capturing = _capturingChannel();
    if (capturing == null) {
      selectTrack(channel);
    } else if (capturing == channel) {
      _looper.record(channel: channel); // finish the loop
    } else {
      _looper
        ..record(channel: capturing) // finalize the running capture
        ..record(channel: channel); // start the pressed one
      selectTrack(channel);
    }
  }

  /// Mute mode: while parked, toggle resume membership (arming a muted track
  /// unmutes it so it reads green). While running, a live track toggles its
  /// mute — muting the last audible one parks everything with an empty
  /// resume set (Rec/Play then brings back ALL content) — and a track out of
  /// the mix joins it (un-exclude, unmute, play).
  void _muteTrackPressed(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    final t = track!;
    if (isParked(_l)) {
      if (!state.parkedResume.contains(channel) && t.muted) {
        if (!_setTrackMute(muted: false, channel: channel).isOk) return;
      }
      final next = {...state.parkedResume};
      if (!next.remove(channel)) next.add(channel);
      emit(state.copyWith(parkedResume: next));
      return;
    }
    final live =
        armedTracks(_l, state).contains(channel) &&
        t.state == TrackState.playing;
    if (live) {
      final muting = !_looper.trackMuted(channel);
      if (!_setTrackMute(muted: muting, channel: channel).isOk) return;
      if (muting && _isLastAudibleArmed(channel)) {
        // Muting the last audible track parks the loop with nothing latched:
        // the next Rec/Play resumes the whole content set.
        for (final c in _running()) {
          _looper.stopTrack(channel: c);
        }
        emit(state.copyWith(parkedResume: const <int>{}));
      }
    } else {
      if (!_setTrackMute(muted: false, channel: channel).isOk) return;
      // Joining is the explicit un-exclude.
      if (state.excluded.contains(channel)) {
        emit(
          state.copyWith(excluded: {...state.excluded}..remove(channel)),
        );
      }
      _looper.play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // FX mode (Track-stage chains)
  // ---------------------------------------------------------------------------

  /// Toggles track [channel]'s Track-stage chain (FX mode's track-button
  /// action, shared with the keyboard's digit keys).
  ///
  /// Per-CHAIN, not per-effect: a stomp is a whole-chain bypass (R15,
  /// "disabled == dry through the bus"); per-effect bits and remapped
  /// bindings are a later part.
  void toggleTrackChain(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    _setTrackChain(channel, enabled: !_looper.trackChainEnabled(channel));
  }

  /// FX panic: every Track-stage chain off in one gesture (Stop in FX mode) —
  /// the eyes-free way out of a chain that has run away mid-song. Restored by
  /// [restoreAllTrackChains] (Stop long-press).
  void panicTrackChains() => _sweepTrackChains(enabled: false);

  /// Puts every Track-stage chain back on (Stop LONG-PRESS in FX mode) — the
  /// undo for [panicTrackChains]. Deliberately "all on" rather than a restore
  /// of the pre-panic pattern: eyes-free on a dark stage, a known end state
  /// beats one the performer has to remember.
  void restoreAllTrackChains() => _sweepTrackChains(enabled: true);

  /// Flips Track-stage chains across every channel, ASYMMETRICALLY on empties.
  ///
  /// Disabling skips a track with no chain: its flag says nothing audible
  /// either way, and writing it would persist a bypass the boot restore
  /// replays forever, silently muting the effects the user adds to that track
  /// later. Skipping also keeps one Stop stomp proportional to the rig — the
  /// repository re-snapshots the engine and re-emits per call, so sweeping all
  /// eight channels cost eight engine snapshots, pedal frames and settings
  /// writes for a rig that usually has one or two chains.
  ///
  /// ENABLING sweeps everything, empties included. Clearing a bypass is always
  /// safe, and a chain-less track can genuinely be carrying a stale one — the
  /// FX dock can disable a chain and then empty it — which is exactly the
  /// silent-dry state this restore exists to undo. A "restore all" that could
  /// not reach it would leave the only pedal-side cure unreachable.
  bool _sweepTrackChains({required bool enabled}) {
    var accepted = false;
    for (var channel = 0; channel < _channelCount; channel++) {
      if (!enabled && _looper.trackEffects(channel).isEmpty) continue;
      accepted = _setTrackChain(channel, enabled: enabled) || accepted;
    }
    return accepted;
  }

  /// Applies explicit Track-chain intent and persists its confirmed envelope.
  ///
  /// Reads the repository's remembered intent rather than the polled
  /// [LooperState]: chain-enabled is set synchronously here (no engine
  /// round-trip), so two fast stomps must not both see the same pre-poll
  /// value. The LEDs still follow the polled snapshot, exactly like mute.
  bool _setTrackChain(int channel, {required bool enabled}) {
    final target = FxChainTarget(
      FxAddress(stage: FxStage.track, index: channel),
    );
    if (_looper.trackChainEnabled(channel) == enabled) {
      final hasHeldIntent =
          (_activationHolders[target]?.keys ?? const <Object>[]).any(
            (key) => key is! (Symbol, Object),
          );
      if (!hasHeldIntent) return false;
    } else if (!_looper
        .setTrackChainEnabled(channel: channel, enabled: enabled)
        .isOk) {
      return false;
    }
    _fxPersistence.ordinaryChain(
      FxAddress(stage: FxStage.track, index: channel),
      enabled: enabled,
    );
    // The same envelope `LooperBloc` writes for the on-screen path — a cubit
    // never calls a bloc, so both call the shared helper instead of one
    // routing through the other.
    persistTrackFxChain(
      settings: _settings,
      projection: _fxPersistence,
      channel: channel,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Clear-all / undo / redo / encoder
  // ---------------------------------------------------------------------------

  /// The whole-rig reset, unified across surfaces: every track holding
  /// content OR a redo history is cleared and re-armed (unmuted, persisted),
  /// and the overlay returns home (record mode, cursor 0). Undone-to-empty
  /// tracks must be included — only clear wipes their resurrect path, and the
  /// master grid resets once everything is empty.
  ///
  /// While performance recording is armed (D-CLEAR), awaits
  /// [PerformanceRepository.persistLiveLanes] first: a track mid-capture is
  /// frozen and erased by the engine clear below (its take stays restorable),
  /// so its performance-recording bundle would otherwise lose that pass
  /// entirely rather than the persisted-then-cleared PCM the repository
  /// itself already knows how to skip.
  Future<void> clearAll() async {
    await _clearAllAccepted();
  }

  Future<bool> _clearAllAccepted() async {
    if (_fxPersistence.sessionTransitionActive) return false;
    if (_performanceArmed) await _performance.persistLiveLanes();
    if (_fxPersistence.sessionTransitionActive) return false;
    // Whether any track we cleared held content: only a content clear leaves a
    // restore point behind (an undone-to-empty redo-only track's does not), so
    // this is the gate on offering whole-rig undo below.
    var restorable = false;
    final cleared = <int>[];
    for (final track in _tracks) {
      if (!track.hasContent && !track.canRedo) continue;
      if (track.hasContent) restorable = true;
      cleared.add(track.channel);
    }
    // One grouped edit (accepted design, slice 2): the repository remembers
    // the group, so the next Undo on any member restores every member.
    if (!_looper.clearAll(cleared).isOk) return false;
    var muteAccepted = true;
    for (final track in _tracks) {
      if (!cleared.contains(track.channel)) continue;
      if (!_setTrackMute(muted: false, channel: track.channel).isOk) {
        muteAccepted = false;
      }
    }
    // The persist above is an await, so the surface may have been torn down
    // while it ran. The engine clear still happens — it is what the user asked
    // for and the looper outlives this cubit — but the overlay state and the
    // LED frame belong to a console that is no longer there.
    if (isClosed) return cleared.isNotEmpty && muteAccepted;
    emit(
      state.copyWith(
        mode: InteractionMode.record,
        cursor: 0,
        activeBank: 0,
        excluded: const <int>{},
        parkedResume: const <int>{},
        // Offer whole-rig undo only when a cleared take can actually come back:
        // bump the pulse so a surface (the tracks view's toast) can react.
        // Derived, not remembered — [undoClearAll] re-reads live `clearRestore`
        // — so the pulse only needs to say "a content clear-all just happened".
        clearAllPulse: restorable ? state.clearAllPulse + 1 : null,
      ),
    );
    // The clear may be a state no-op (already home) while the held-LED bit
    // still needs to reach the wire.
    _pushProjected();
    return cleared.isNotEmpty && muteAccepted;
  }

  /// Whole-rig recovery from a clear-all: undoes every track that still holds
  /// a clear restore point ([Track.clearRestore]), putting its erased take
  /// back — with the layers, FX chains and mutes the repository snapshotted
  /// and re-persists per channel.
  ///
  /// Derived from the live snapshot, never a remembered set: a restore point
  /// the engine has already retired (a fresh take overwrote the cleared slot,
  /// or a take redefined the master grid) is simply not in the set, so this
  /// never resurrects a track the engine let go, and it does the right thing
  /// in the partial case (clear-all, then a new take on one track →
  /// undo-clear-all restores the others and leaves the fresh take alone). A
  /// no-op when nothing is pending — the toast never shows and ⌘⇧C is inert.
  ///
  /// Emits nothing mode-related: unlike [clearAll] it does not re-home the
  /// overlay — the user is recovering the rig they had, cursor and mode
  /// included.
  void undoClearAll() => _looper.undoClearAll();

  /// Undoes the latest overdub pass on [channel] (per-layer all the way
  /// down; past the base recording the track empties, redo-ably).
  void undo(int channel) => _looper.undo(channel: channel);

  /// Redoes the last undone layer on [channel] (including resurrecting an
  /// undone-to-empty track).
  void redo(int channel) => _looper.redo(channel: channel);

  /// Admits a screen contact into the same ledger as physical pedals.
  /// Its originating token also qualifies release and cancellation.
  void footMixerPressed(PedalButton button, Object contact) {
    if (state.mode != InteractionMode.mixer || isClosed) return;
    _handleEvent(ButtonPressed(button), contact: contact);
  }

  /// Only the screen contact that was admitted may complete this gesture.
  void footMixerReleased(PedalButton button, Object contact) =>
      _handleEvent(ButtonReleased(button), contact: contact);

  /// Accessible semantic activation uses the same role as timed contacts.
  void activateFootMixerPedal(PedalButton button, {bool hold = false}) {
    if (!_mixerEditable) return;
    final role = FootMixerProjection.pedalRoles[button]!;
    final action = hold ? role.hold : role.press;
    if (action != null) _dispatchMixerAction(action, role.slot);
  }

  /// Cancels an abandoned screen contact without dispatching its short action.
  void footMixerCancelled(PedalButton button, Object contact) {
    if (isClosed ||
        _inputRetired ||
        !identical(_pressedButtons[button], contact)) {
      return;
    }
    _systemGesture(button)?.cancel();
    _pressedButtons.remove(button);
    _acceptedContacts.remove(button);
    _pushProjected();
  }

  /// Admits a screen contact on the Fade surface into the shared ledger.
  void footFadePressed(PedalButton button, Object contact) {
    if (state.mode != InteractionMode.fade || isClosed) return;
    _handleEvent(ButtonPressed(button), contact: contact);
  }

  /// Only the admitted screen contact may complete its Fade gesture.
  void footFadeReleased(PedalButton button, Object contact) =>
      footMixerReleased(button, contact);

  /// Cancels an abandoned Fade contact without its short action.
  void footFadeCancelled(PedalButton button, Object contact) =>
      footMixerCancelled(button, contact);

  /// Accessible semantic activation uses the same Fade role as contacts.
  void activateFootFadePedal(PedalButton button, {bool hold = false}) {
    if (!_fadeEditable) return;
    final role = FootFadeProjection.pedalRoles[button]!;
    final action = hold ? role.hold : role.press;
    if (action != null) _dispatchFadeAction(action, role.slot);
  }

  /// Fades the recorded track in visible [slot] of the current bank.
  Future<void> toggleFootFadeTrack(int slot) async {
    final fade = _footFadeActions;
    if (!_fadeEditable || slot < 0 || slot >= 4) return;
    // An empty track is unavailable, not a failure: nothing to report.
    final projection = fade.project(state.footFade, bank: state.activeBank);
    if (!projection.trackAt(slot).available) return;
    final visit = _surfaceVisit;
    final session = _looper.sessionRevision;
    final result = await fade.toggle(projection.channelAt(slot));
    if (!result.isOk) _reportFadeFailure(visit, session);
  }

  /// Selects the recorded track in visible [slot] as the time target.
  void selectFootFadeTrackTime(int slot) {
    final fade = _footFadeActions;
    if (!_fadeEditable) return;
    emit(
      state.copyWith(
        footFade: fade.selectTrackTime(
          state.footFade,
          slot,
          bank: state.activeBank,
        ),
      ),
    );
  }

  /// Selects the shared Default as the time target.
  void selectFootFadeDefault() {
    if (!_fadeEditable) return;
    emit(state.copyWith(footFade: const FootFadeSelection()));
  }

  /// Shortens (-1) or lengthens (1) the selected duration by one step.
  Future<void> stepFootFadeTime(int direction) async {
    final fade = _footFadeActions;
    if (!_fadeEditable) return;
    await _footFadeTimeEdit(() => fade.step(state.footFade, direction));
  }

  /// A track inherits Default again; Default returns to four seconds.
  Future<void> resetFootFadeTime() async {
    final fade = _footFadeActions;
    if (!_fadeEditable) return;
    await _footFadeTimeEdit(() => fade.reset(state.footFade));
  }

  // Storage failures already reach the Fade settings notice; this only keeps
  // a refused edit from escaping as an unhandled error.
  Future<void> _footFadeTimeEdit(Future<void> Function() edit) async {
    try {
      await edit();
    } on Object catch (error, stack) {
      if (!isClosed) addError(error, stack);
    }
  }

  /// Selects the Mixer source without changing the transport cursor or bank.
  void selectFootMixerDomain(FootMixerDomain domain) {
    if (!_mixerEditable || domain == state.footMixer.domain) return;
    _cancelSurfaceHolds();
    emit(state.copyWith(footMixer: _footMixerActions.domain(domain)));
  }

  /// Selects one available visible channel; repeated selection is harmless.
  void selectFootMixerSlot(int slot) {
    if (!_mixerEditable || slot < 0 || slot >= 4) return;
    emit(
      state.copyWith(
        footMixer: _footMixerActions.select(state.footMixer, slot),
      ),
    );
  }

  /// Advances the local page, selecting its first available channel.
  void nextFootMixerPage() {
    if (!_mixerEditable) return;
    emit(
      state.copyWith(
        footMixer: _footMixerActions.nextPage(state.footMixer),
      ),
    );
  }

  /// Adds a relative gain step through the shared transaction owner.
  Future<void> stepFootMixerGain(int direction) async {
    if (!_mixerEditable) return;
    await _footMixerActions.step(state.footMixer, direction);
  }

  /// Resets only the selected gain to unity.
  Future<void> resetFootMixerGain() async {
    if (!_mixerEditable) return;
    await _footMixerActions.reset(state.footMixer);
  }

  /// Toggles selected mute, or the slot resolved when a pedal hold fires.
  Future<void> toggleFootMixerMute([int? slot]) async {
    if (!_mixerEditable) return;
    final visit = _surfaceVisit;
    final session = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    await _footMixerActions.toggleMute(
      state.footMixer,
      slot: slot,
      onError: (error, stack) {
        if (isClosed) return;
        addError(error, stack);
        if (identical(visit, _surfaceVisit) &&
            state.mode == InteractionMode.mixer &&
            _looper.sessionRevision == session &&
            _looper.mixGeneration == generation) {
          emit(state.copyWith(footMixerFailure: state.footMixerFailure + 1));
        }
      },
    );
  }

  /// An encoder detent turn: accumulates into the master output gain.
  void encoderTurned(int delta) {
    // A continuous value: it runs behind the power-off dialog, and stops once
    // the flush suspends input.
    if (_inputRetired || _inputLocked() || _controlInputSuspended) return;
    if (state.mode == InteractionMode.mixer) {
      for (var step = 0; step < delta.abs(); step++) {
        unawaited(stepFootMixerGain(delta.sign));
      }
      return;
    }
    final value = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    if (_looper.setMasterGain(value).isOk) {
      _masterGain = value;
      _onOrdinaryFxWrite(const MasterGainTarget(), value);
    }
    // Push a fresh frame so the pedal ring reflects the new gain (the volume
    // meter is driven by the frame value, not a local echo).
    _pushProjected();
  }

  // ---------------------------------------------------------------------------
  // Inbound pedal events -> the same intent methods (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _handleEvent(PedalEvent event, {Object? contact}) {
    if (_inputRetired) return;
    final owner = contact ?? _physicalContact;
    switch (event) {
      case ButtonPressed(:final button):
        _onPress(button, owner);
        _pushProjected();
      case ButtonReleased(:final button):
        if (!identical(_pressedButtons[button], owner)) break;
        _pressedButtons.remove(button);
        _acceptedContacts.remove(button);
        if (button == PedalButton.clear) _clearPressToken = null;
        if (button == PedalButton.clear) _onClearRelease();
        if (_takeLocked()) {
          _systemGesture(button)?.cancel();
          _bindingGestures[button]?.cancel();
        } else {
          _systemGesture(button)?.release();
          _bindingGestures[button]?.release();
        }
        _customActiveKeys.remove(button);
        // Unconditional: a momentary is keyed to the button, so this finds
        // the held one (if any) whatever else that button's release did.
        _releaseBinding(button);
        _pushProjected();
      case EncoderDelta(:final delta):
        _log('encoder $delta');
        encoderTurned(delta);
      case CtrlChanged():
        // The CTRL jacks are assignable controls, not transport: they reach
        // the looper through ControllerRepository's bindings, which
        // ConsoleCtrlSource feeds. Nothing to do on this path.
        break;
    }
  }

  _HoldGesture? _systemGesture(PedalButton button) => switch (button) {
    PedalButton.undo => _undoGesture,
    PedalButton.mode => _modeGesture,
    PedalButton.bank => _bankGesture,
    PedalButton.recPlay => _recordHoldGesture,
    PedalButton.stop => _stopGesture,
    _ => _trackHoldGestures[button],
  };

  void _onPress(PedalButton button, Object owner) {
    if (_takeLocked()) return;
    if (_pendingRestore.any((key) => key.button == button)) return;
    if (_pressedButtons.containsKey(button)) return;
    _pressedButtons[button] = owner;
    _customDispatchTokens.remove(button);
    _log(
      'press ${button.name}  [mode=${state.mode.name} '
      'cursor=${state.cursor}]',
    );
    if (state.mode == InteractionMode.mixer) {
      _onMixerPress(button);
      return;
    }
    if (state.mode == InteractionMode.fade) {
      _onFadePress(button);
      return;
    }
    if (state.mode == InteractionMode.custom) {
      // These two physical exits cannot be assigned. They act on contact,
      // without a second action waiting on the release.
      if (button == PedalButton.mode) {
        setMode(InteractionMode.record);
      } else if (button == PedalButton.bank) {
        toggleBankWithCursor();
      } else {
        _armCustom(button);
      }
      return;
    }
    final fx = state.mode == InteractionMode.fx;
    // A remap overrides its button's contextual DEFAULT, and only in FX mode —
    // the other two modes are transport surfaces a binding must never shadow.
    // MODE and Bank can never appear here: the binding model refuses to hold
    // one (B12), so their handling below is unreachable from a binding.
    if (fx) {
      final binding = state.bindings.lookup(button, bank: state.activeBank);
      if (binding != null) {
        if (binding.hasHold) {
          _armBoundHold(binding);
        } else {
          if (_pressBinding(binding) && button == PedalButton.stop) {
            _acceptedContacts.add(button);
          }
        }
        // Stop keeps its restore-all HOLD even when bound: a remap overrides
        // contextual defaults but never the long-press system gestures, and
        // the panic's only undo must stay reachable from the plate whatever
        // the user mapped onto the tap.
        if (button == PedalButton.stop) _armStopRestore();
        return;
      }
    }
    switch (button) {
      case PedalButton.undo:
        // INERT in FX mode until the #219 toggle-undo contract exists: an
        // undo that silently means "the last overdub" while the foot is in a
        // chain-editing mode is the surprise this matrix exists to prevent.
        if (!fx) {
          _armUndo();
          _acceptedContacts.add(button);
        }
      case PedalButton.recPlay:
        final accepted = switch (state.mode) {
          InteractionMode.record => !_takeLocked() && _recAdvance(state.cursor),
          InteractionMode.mute => !_takeLocked() && _muteRecPlay(),
          InteractionMode.fx ||
          InteractionMode.custom ||
          InteractionMode.mixer ||
          InteractionMode.fade => false,
        };
        if (accepted) _acceptedContacts.add(button);
        _armRecordHold();
      case PedalButton.stop:
        // FX mode splits Stop into tap = panic / long-press = restore, so the
        // action waits for the release; the other modes act on the press, as
        // they always have.
        if (fx) {
          if (_armStop()) _acceptedContacts.add(button);
        } else {
          final accepted = state.mode == InteractionMode.record
              ? _recStop(state.cursor)
              : _parkAllAccepted();
          if (accepted) _acceptedContacts.add(button);
        }
      case PedalButton.mode:
        _armMode();
      case PedalButton.bank:
        _armBank();
      case PedalButton.clear:
        // INERT in FX mode, LED included (A2): clear is the one irreversible
        // stomp on the plate, and a stray one must never erase the set.
        if (!fx) _onClear();
      case PedalButton.track1:
      case PedalButton.track2:
      case PedalButton.track3:
      case PedalButton.track4:
        final channel = state.bankBaseChannel + _trackIndex(button);
        trackPressed(channel);
        _armTrackHold(button);
    }
  }

  /// The gesture shape is fixed on contact; its bank-keyed action and
  /// target are resolved only when the gesture fires.
  void _armCustom(PedalButton button) {
    if (state.pedalSetupUnavailable) return;
    final pair = state.pedalSetup.customFor(button, bank: state.activeBank);
    if (pair.hold == null) {
      _fireCustomAction(button, hold: false);
      return;
    }
    _armGesture(
      _bindingGestures.putIfAbsent(button, _HoldGesture.new),
      onHold: () => _fireCustomAction(button, hold: true),
      onTap: () => _fireCustomAction(button, hold: false),
    );
  }

  void _fireCustomAction(PedalButton button, {required bool hold}) {
    if (state.mode != InteractionMode.custom ||
        state.pedalSetupUnavailable ||
        _takeLocked()) {
      return;
    }
    final bank = state.activeBank;
    final pair = state.pedalSetup.customFor(button, bank: bank);
    final action = hold ? pair.hold : pair.press;
    if (action == null || action is UnavailableAction) return;
    _syncCustomSession();
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    final channels = List<int>.unmodifiable(_channelsForAction(action));
    _log('action ${action.key}');
    final session = _looper.sessionRevision;
    final setup = state.pedalSetup;
    final token = Object();
    _customDispatchTokens[button] = token;
    final admitted = _runAction(action, channels);
    if (admitted is Future<bool>) {
      unawaited(
        admitted.then(
          (accepted) => _completeCustomAction(
            button,
            key,
            action,
            channels,
            session: session,
            setup: setup,
            token: token,
            accepted: accepted,
          ),
          onError: addError,
        ),
      );
    } else {
      _completeCustomAction(
        button,
        key,
        action,
        channels,
        session: session,
        setup: setup,
        token: token,
        accepted: admitted,
      );
    }
  }

  void _completeCustomAction(
    PedalButton button,
    PedalBindingKey key,
    ControlAction action,
    List<int> channels, {
    required int session,
    required PedalSetup setup,
    required Object token,
    required bool accepted,
  }) {
    if (!accepted ||
        isClosed ||
        state.mode != InteractionMode.custom ||
        state.pedalSetupUnavailable ||
        state.pedalSetup.copyWith(palette: setup.palette) != setup ||
        _looper.sessionRevision != session ||
        !identical(_customDispatchTokens[button], token)) {
      return;
    }
    _customLastActions[key] = (action: action, channels: channels);
    if (_pressedButtons.containsKey(button)) _customActiveKeys[button] = key;
    _pushProjected();
  }

  /// Resolves one action's target exactly once at its firing boundary.
  List<int> _channelsForAction(ControlAction action) => switch (action) {
    TrackPedalAction(:final channel) ||
    SelectTrackAction(:final channel) => [channel],
    TrackOperationAction(:final scope) => switch (scope) {
      SelectedTrackScope() => [state.cursor],
      FixedTrackScope(:final channel) => [channel],
      AllTracksScope() => [for (var c = 0; c < _channelCount; c++) c],
    },
    CommandAction(
      command: ControlCommand.recordPlay ||
          ControlCommand.stop ||
          ControlCommand.undo ||
          ControlCommand.redo,
    ) =>
      [state.cursor],
    _ => const [],
  };

  /// One dispatcher for the current supported catalogue actions.
  FutureOr<bool> _runAction(ControlAction action, List<int> channels) {
    switch (action) {
      case UnavailableAction():
        return false;
      case ModeAction(:final mode):
        _enterPedalMode(mode);
        return true;
      case CommandAction(:final command):
        return _runCommand(
          command,
          channels.isEmpty ? state.cursor : channels.first,
        );
      case TrackPedalAction():
        final channel = channels.single;
        selectTrack(channel);
        return _recAdvance(channel);
      case SelectTrackAction():
        selectTrack(channels.single);
        return true;
      case TrackOperationAction(:final operation):
        if (operation == TrackOperation.fade && channels.length > 1) {
          // Each recorded track fades independently; one stomp, every one.
          return Future.wait([
            for (final channel in channels)
              Future.value(_runTrackOperation(operation, channel)),
          ]).then((results) => results.any((accepted) => accepted));
        }
        if (operation == TrackOperation.solo && channels.length > 1) {
          return _mixSettings
              .toggleTrackSolos(channels.toSet())
              .then(
                (outcome) => outcome.isOk,
              );
        }
        var accepted = false;
        for (final channel in channels) {
          final result = _runTrackOperation(operation, channel);
          if (result is Future<bool>) return result;
          accepted = result || accepted;
        }
        return accepted;
    }
  }

  FutureOr<bool> _runCommand(ControlCommand command, int selectedChannel) {
    switch (command) {
      case ControlCommand.tapTempo:
        return _looper.tapTempo().isOk;
      case ControlCommand.recordPlay:
        return _recAdvance(selectedChannel);
      case ControlCommand.stop:
        return _recStop(selectedChannel);
      case ControlCommand.undo:
        return _looper.undo(channel: selectedChannel).isOk;
      case ControlCommand.redo:
        return _looper.redo(channel: selectedChannel).isOk;
      case ControlCommand.clearAll:
        return _clearAllAccepted();
      case ControlCommand.cutSound:
        return _looper.cutSound().isOk;
      case ControlCommand.recordPerformance:
        return _togglePerformanceRecordAccepted();
      case ControlCommand.nextBank:
        toggleBankWithCursor();
        return true;
    }
  }

  FutureOr<bool> _runTrackOperation(TrackOperation operation, int channel) {
    final track = _trackAt(channel);
    switch (operation) {
      case TrackOperation.mute:
        if (track == null) return false;
        return _setTrackMute(
          muted: !_looper.trackMuted(channel),
          channel: channel,
        ).isOk;
      case TrackOperation.solo:
        return _mixSettings
            .toggleTrackSolo(channel: channel)
            .then(
              (outcome) => outcome.isOk,
            );
      case TrackOperation.clear:
        if (_fxPersistence.sessionTransitionActive) return false;
        if (!_looper.clear(channel: channel).isOk) return false;
        return _setTrackMute(muted: false, channel: channel).isOk;
      case TrackOperation.undo:
        return _looper.undo(channel: channel).isOk;
      case TrackOperation.redo:
        return _looper.redo(channel: channel).isOk;
      case TrackOperation.fade:
        if (track == null) return false;
        return _footFadeActions.toggle(channel).then((result) => result.isOk);
    }
  }

  /// Arms a bound switch's press/hold pair.
  ///
  /// Both halves are built at press time and act on the binding the foot
  /// committed to, so an assignment edited mid-gesture cannot retarget it —
  /// the same latching every system gesture uses. The generation is what
  /// makes a configuration change retire this one rather than letting it
  /// land somewhere else.
  void _armBoundHold(PedalBinding binding) {
    _armGesture(
      _bindingGestures.putIfAbsent(binding.key.button, _HoldGesture.new),
      onHold: () {
        if (state.mode == InteractionMode.fx) {
          if (_pressBinding(binding, hold: true) &&
              binding.key.button == PedalButton.stop) {
            _acceptedContacts.add(PedalButton.stop);
            _pushProjected();
          }
        }
      },
      onTap: () {
        if (state.mode == InteractionMode.fx) _pressBinding(binding);
      },
    );
  }

  void _armGesture(
    _HoldGesture gesture, {
    required void Function() onHold,
    void Function()? onTap,
  }) {
    final session = _looper.sessionRevision;
    gesture.press(
      threshold: _longPress,
      stillValid: () =>
          !isClosed && !_takeLocked() && _looper.sessionRevision == session,
      onHold: onHold,
      onTap: onTap,
    );
  }

  void _onClear() {
    final token = Object();
    _clearPressToken = token;
    unawaited(_clearAndLightAcceptedContact(token));
  }

  Future<void> _clearAndLightAcceptedContact(Object token) async {
    try {
      final accepted = await _clearAllAccepted();
      if (!accepted ||
          isClosed ||
          !identical(_clearPressToken, token) ||
          !_pressedButtons.containsKey(PedalButton.clear)) {
        return;
      }
      _clearHeld = true;
      _acceptedContacts.add(PedalButton.clear);
      _pushProjected();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Clear footswitch released: darken the Clear LED (the clear itself
  /// already happened on press — this only ends the held-button light).
  void _onClearRelease() {
    if (!_clearHeld) return;
    _clearHeld = false;
    _pushProjected();
  }

  void _armUndo() {
    final channel = state.cursor; // latched at press by both closures
    _armGesture(
      _undoGesture,
      onHold: () {
        _log('redo ch=$channel  (long-press)');
        if (!_looper.redo(channel: channel).isOk) {
          _acceptedContacts.remove(PedalButton.undo);
          _pushProjected();
        }
      },
      onTap: () {
        _log('undo ch=$channel  (tap)');
        undo(channel);
      },
    );
  }

  /// The FX-mode Stop gesture: the PANIC fires on the press itself, and a
  /// hold past the threshold follows it with the restore.
  ///
  /// Panic-on-press, not on release, for two reasons. A panic is an emergency
  /// control — a performer stomping it wants the chains out now, not when
  /// their foot comes up. And a release is not proof of a gesture: the
  /// on-screen plate injects a synthetic note-off for every held switch when
  /// it leaves the tree (so it never strands a note), which as a
  /// release-triggered action would have bypassed and PERSISTED every chain
  /// for a stomp the user never finished. Acting on the press makes the
  /// release inert, so a synthetic one can do no harm.
  ///
  /// The hold therefore reads as panic-then-restore, which lands on the same
  /// end state the restore promises on its own: every chain on.
  bool _armStop() {
    _log('fx panic (press)');
    final accepted = _sweepTrackChains(enabled: false);
    _armStopRestore();
    return accepted;
  }

  /// Arms the Stop restore-all hold on its own, without the panic.
  ///
  /// Split out because a BOUND Stop runs its binding on the press instead of
  /// the panic, but still owes the performer the restore gesture (B12): the
  /// remap overrides the contextual default, never the long-press system
  /// gesture layered above it.
  void _armStopRestore() {
    // No `onTap`: whatever fired on the press already did, so the release is
    // inert.
    _armGesture(
      _stopGesture,
      onHold: () {
        // Only while the foot is still in the mode it committed to: cycling
        // MODE mid-hold leaves the pedal showing cursor/armed LEDs, where a
        // silent rewrite of every chain would be invisible.
        if (state.mode != InteractionMode.fx) return;
        _log('fx chains restored (long-press)');
        final accepted = _sweepTrackChains(enabled: true);
        if (accepted && _pressedButtons.containsKey(PedalButton.stop)) {
          _acceptedContacts.add(PedalButton.stop);
        } else {
          _acceptedContacts.remove(PedalButton.stop);
        }
        _pushProjected();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Performance recording (D-PEDAL)
  // ---------------------------------------------------------------------------

  /// Arms or disarms performance recording, mirroring the toolbar's own
  /// dispatch (`PerformanceRecorderCubit.toggleArm` calls the same
  /// repository methods, including the guarded `disarm()` — not
  /// `disarmAndFinalize()`, which is reserved for `SessionCubit`'s
  /// unguarded auto-disarm-before-load) — the repository's own double-press
  /// guard covers a rapid re-press identically here, so it is not
  /// duplicated in this cubit.
  void togglePerformanceRecord() {
    unawaited(_togglePerformanceRecordAccepted());
  }

  Future<bool> _togglePerformanceRecordAccepted() async {
    if (_takeLocked()) return false;
    if (_performanceArmed) {
      return (await _performance.disarm()).isOk;
    } else {
      return (await _performance.arm(chains: _currentChains())).isOk;
    }
  }

  void _onPerformanceStatus(PerformanceCaptureStatus status) {
    final armed = status == PerformanceCaptureStatus.armed;
    if (armed == _performanceArmed) return;
    _performanceArmed = armed;
    _pushProjected();
  }

  /// Arms the configured MODE pair. A pair with a Hold defers Press until
  /// release; Hold fires at the common threshold and retires that Press.
  void _armMode() {
    if (state.pedalSetupUnavailable) return;
    final setup = state.pedalSetup;
    final hold = setup.modeHold;
    if (hold == null) {
      _enterPedalMode(setup.modePress);
      return;
    }
    _armGesture(
      _modeGesture,
      onHold: () => _enterPedalMode(hold),
      onTap: () => _enterPedalMode(setup.modePress),
    );
  }

  void _enterPedalMode(InteractionMode mode) => setMode(
    state.mode == mode
        ? mode == InteractionMode.fx
              ? _fxReturn
              : InteractionMode.record
        : mode,
  );

  /// Keeps physical performance arm/disarm reachable while the accepted
  /// Custom Bank action is not yet available. A Hold retires the page tap.
  void _armBank() {
    _armGesture(
      _bankGesture,
      onHold: togglePerformanceRecord,
      onTap: toggleBankWithCursor,
    );
  }

  /// Record/Play keeps its immediate contact action; Hold adds Undo on the
  /// selected channel when the threshold fires.
  void _armRecordHold() {
    if (state.pedalSetupUnavailable ||
        state.mode == InteractionMode.fx ||
        state.pedalSetup.recordHold == RecordHold.none) {
      return;
    }
    _armGesture(
      _recordHoldGesture,
      onHold: () => undo(state.cursor),
    );
  }

  /// Track selection/transport remains immediate; Hold follows the current
  /// bank position until the threshold fires.
  void _armTrackHold(PedalButton button) {
    if (state.pedalSetupUnavailable || state.mode != InteractionMode.record) {
      return;
    }
    final hold = state.pedalSetup.trackHold;
    if (hold == TrackHold.none) return;
    _armGesture(
      _trackHoldGestures.putIfAbsent(button, _HoldGesture.new),
      onHold: () {
        final channel = state.bankBaseChannel + _trackIndex(button);
        switch (hold) {
          case TrackHold.none:
            return;
          case TrackHold.armOverdub:
            // This directional action must use a fresh capture fact. A take
            // can begin in the native callback before the next UI poll.
            final tracks = _looper.state.tracks;
            if (channel >= 0 &&
                channel < tracks.length &&
                tracks[channel].hasContent &&
                !tracks[channel].pending &&
                !tracks[channel].isCapturing) {
              _looper.record(channel: channel);
            }
          case TrackHold.clearTrack:
            _looper.clear(channel: channel);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Pedal remap (part 6b): bindings, momentary hold, release-all
  // ---------------------------------------------------------------------------

  // The remap is READ off `state` (`state.bindings` / `.globalBindings` /
  // `.sessionBindings` / `.stompFor`) — the cubit exposes only the writers
  // below. No pass-through getters: a cubit's public surface is its commands,
  // and the state object is already the read surface every widget watches.

  /// Replaces the global remap and persists it (the assignment screen's edit
  /// path).
  ///
  /// Releases every held momentary FIRST: the binding the foot is holding may
  /// not survive the edit, and a target left enabled with no binding to
  /// release it is exactly the wedge (B1) the release-all rule exists to
  /// prevent.
  Future<void> setGlobalBindings(PedalBindingSet next) async {
    if (next == state.globalBindings) return;
    _invalidateGestures();
    emit(state.copyWith(globalBindings: next));
    await _settings.savePedalBindings(next.encode());
  }

  /// Applies the remap carried by a loaded session (or clears it when the
  /// bundle has none). Called from the session apply seam; releases held
  /// momentaries on the same rule as [setGlobalBindings].
  void applySessionBindings(PedalBindingSet next) {
    _invalidateGestures();
    _customLastActions.clear();
    if (next == state.sessionBindings) return;
    emit(state.copyWith(sessionBindings: next));
  }

  void _invalidateGestures() {
    for (final gesture in _externalGestures.values) {
      gesture.cancel();
    }
    _undoGesture.cancel();
    _modeGesture.cancel();
    _bankGesture.cancel();
    _recordHoldGesture.cancel();
    for (final gesture in _trackHoldGestures.values) {
      gesture.cancel();
    }
    _stopGesture.cancel();
    for (final gesture in _bindingGestures.values) {
      gesture.cancel();
    }
    _customActiveKeys.clear();
    _customDispatchTokens.clear();
    _acceptedContacts.clear();
    _clearHeld = false;
    _clearPressToken = null;
    _displayBoundTargets.clear();
    releaseAllMomentary();
    _pushProjected();
  }

  /// Restores every held momentary to the state its press captured — the ONE
  /// enforcement point (B1).
  ///
  /// Every path that can strand a press without its release funnels here:
  /// mode exit ([setMode]), a binding-set change ([setGlobalBindings] /
  /// [applySessionBindings], which covers the assignment screen's live edits
  /// AND a session load), and pedal disconnect ([_onLinkStatus]). A physical
  /// release goes through [_releaseBinding] instead, which restores just that
  /// one — but both write the captured state, so no target can be left
  /// enabled by a press whose release never arrived.
  void releaseAllMomentary() {
    if (_heldRestore.isEmpty) return;
    for (final key in _heldRestore.keys.toList()) {
      _pendingRestore.add(key);
      _tryRestoreBinding(key);
    }
  }

  void _tryRestoreBinding(PedalBindingKey key) {
    final held = _heldRestore[key];
    if (held == null) return;
    if (_bindingDecisions.containsKey(held.holder)) {
      _pendingRestore.add(key);
      return;
    }
    // A loaded session can reuse the same chain address. Never replay the old
    // session's saved power into it merely because the string still resolves.
    if (held.session != _looper.sessionRevision) {
      _finishBindingRestore(key);
      return;
    }
    final current = _looper.bindingEnabled(held.target);
    if (current == null) {
      // The stable target was removed. There is no effect to restore, and an
      // obligation to it must not block a later binding on this button.
      _finishBindingRestore(key);
      return;
    }
    // Built-in B1 restores captured prior even after another writer. The
    // accepted restore becomes fresh ordinary intent for MIDI cleanup.
    final restored = held.prior;
    if (current != restored &&
        !_looper.setBindingEnabled(held.target, enabled: restored)) {
      _pendingRestore.add(key);
      _waitForRestoreReadiness();
      return;
    }
    _confirmBindingDecision(key, held.holder, restoring: true);
  }

  void _confirmBindingDecision(
    PedalBindingKey key,
    Object holder, {
    required bool restoring,
  }) {
    if (_closing || isClosed) return;
    final held = _heldRestore[key];
    if (held == null || held.holder != holder) return;
    final pending = _fxPersistence.beginPending();
    final decision = () async {
      try {
        final result = await _looper.settleFxRecipes(
          waitForCallback: true,
          cancelled: () =>
              _closing || isClosed || held.session != _looper.sessionRevision,
        );
        if (_closing || isClosed) return;
        if (_heldRestore[key]?.holder != holder) return;
        if (held.session != _looper.sessionRevision || !result.isOk) {
          if (!restoring || held.session != _looper.sessionRevision) {
            _finishBindingRestore(key);
          } else {
            _pendingRestore.add(key);
          }
        } else if (restoring) {
          _onOrdinaryFxWrite(held.target, held.prior ? 1 : 0);
          _finishBindingRestore(key);
        } else {
          (_activationHolders[held.target] ??= {})[holder] = (
            value: true,
            order: ++_activationOrder,
          );
          _syncMidiDurableFx();
        }
      } on Object catch (error, stackTrace) {
        if (!_closing && !isClosed) addError(error, stackTrace);
      } finally {
        unawaited(_bindingDecisions.remove(holder));
        _fxPersistence.finishPending(pending);
      }
      if (!restoring && _pendingRestore.contains(key)) {
        _tryRestoreBinding(key);
      }
    }();
    _bindingDecisions[holder] = decision;
    unawaited(decision);
  }

  void _waitForRestoreReadiness() {
    if (_restoreWait != null || _closing) return;
    final session = _looper.sessionRevision;
    _restoreWait = _retryRestoresAfterFx(session);
  }

  Future<void> _retryRestoresAfterFx(int session) async {
    try {
      await _looper.settleFxRecipes(
        waitForCallback: true,
        cancelled: () =>
            _closing || isClosed || _looper.sessionRevision != session,
      );
      if (_closing || isClosed) return;
      // One readiness wait, one retry. A second refusal remains observable in
      // pendingRestore and waits for another repository change; it never spins.
      _pendingRestore.toList().forEach(_tryRestoreBinding);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    } finally {
      _restoreWait = null;
    }
  }

  void _finishBindingRestore(PedalBindingKey key) {
    _pendingRestore.remove(key);
    final held = _heldRestore.remove(key);
    if (held != null) {
      _activationHolders[held.target]?.remove(held.holder);
      _syncMidiDurableFx();
    }
    emit(state.copyWith(heldMomentary: {...state.heldMomentary}..remove(key)));
  }

  /// Runs [binding] instead of its button's contextual FX-mode default.
  ///
  /// A stale binding — one whose target string no longer parses, or names a
  /// chain/slot the rig no longer has — is a NO-OP (R25). It writes nothing
  /// and lights nothing; the assignment screen is where the user learns it is
  /// broken, not a mid-song stomp that silently bypasses the wrong thing.
  bool _pressBinding(PedalBinding binding, {bool hold = false}) {
    if (_takeLocked()) return false;
    final target = _scoped(
      hold ? binding.decodeHoldTarget() : binding.decodeTarget(),
      hold ? binding.holdScope : binding.scope,
    );
    final prior = target == null ? null : _looper.bindingEnabled(target);
    if (target == null || prior == null) {
      _log('binding on ${binding.key.button.name} is stale — no-op');
      return false;
    }
    switch (hold ? binding.holdBehavior : binding.behavior) {
      case BindingBehavior.toggle:
        _log('binding toggle ${binding.key.button.name} -> ${!prior}');
        if (!_looper.setBindingEnabled(target, enabled: !prior)) return false;
        _fxPersistence.ordinaryTarget(target, enabled: !prior);
      case BindingBehavior.momentary:
        if (_heldRestore.containsKey(binding.key)) return false;
        _log('binding momentary ${binding.key.button.name} (was $prior)');
        // Capture on the FIRST press only. A repeated press with no release
        // between them — a dropped NoteOff, or the on-screen plate re-emitting
        // a down — would otherwise re-capture the state THIS binding just
        // enabled, and the eventual release would restore `true` and strand
        // the target on: the stuck momentary (B1) with no foot on the switch.
        if (!prior && !_looper.setBindingEnabled(target, enabled: true)) {
          return false;
        }
        final holder = Object();
        _heldRestore[binding.key] = (
          holder: holder,
          target: target,
          prior: prior,
          session: _looper.sessionRevision,
        );
        _confirmBindingDecision(binding.key, holder, restoring: false);
        emit(
          state.copyWith(heldMomentary: {...state.heldMomentary, binding.key}),
        );
    }
    _displayBoundTargets[binding.key.button] = (
      binding: binding,
      target: target,
      behavior: hold ? binding.holdBehavior : binding.behavior,
      scope: hold ? binding.holdScope : binding.scope,
      cursor: state.cursor,
    );
    _pushProjected();
    return true;
  }

  FxBindingTarget? _scoped(FxBindingTarget? target, BindingScope scope) {
    if (target == null || scope == BindingScope.fixed) return target;
    final address = resolveBindingAddress(target.address, scope, state.cursor);
    if (address == target.address) return target;
    return switch (target) {
      FxChainTarget() => FxChainTarget(address),
      FxSlotTarget(:final slotId) => FxSlotTarget(
        address: address,
        slotId: slotId,
      ),
    };
  }

  /// Restores the momentary [button] is holding, if any.
  ///
  /// Matched by BUTTON rather than by the live bank's key: the performer can
  /// stomp Bank while a track momentary is down, and the release must still
  /// find the binding that was actually pressed. A button holds at most one
  /// momentary at a time, so the match is unambiguous.
  void _releaseBinding(PedalButton button) {
    for (final key in _heldRestore.keys.toList()) {
      if (key.button != button) continue;
      _pendingRestore.add(key);
      _tryRestoreBinding(key);
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Console capture remains on the shared repository ingress.
  // ---------------------------------------------------------------------------

  void _onControllerBindingEvent(ControllerDispatchEvent event) {
    if (_inputRetired) return;
    if (event is ControllerConsoleEvent) _onConsoleEvent(event.input);
  }

  /// What each BOUND track switch's own target currently reads, by channel.
  ///
  /// Only in FX mode, because that is the only mode a binding overrides — the
  /// other two are transport surfaces a remap must never shadow, and their
  /// LEDs mean something else entirely.
  ///
  /// A present null is a binding that no longer resolves. It stays in the map
  /// rather than being dropped, so the LED can go dark: R25 says a stale
  /// binding writes nothing and lights nothing, and dropping it here would
  /// fall back to this channel's track chain — lighting for a chain the switch
  /// does not drive.
  Map<int, bool?> _boundChains() {
    if (state.mode != InteractionMode.fx) return const {};
    final bound = <int, bool?>{};
    for (final button in const [
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ]) {
      final binding = state.bindings.lookup(button, bank: state.activeBank);
      if (binding == null) continue;
      final ledChannel = state.bankBaseChannel + _trackIndex(button);
      final display = _displayBoundTargets[button];
      if (display != null &&
          display.binding == binding &&
          (display.scope != BindingScope.selected ||
              display.cursor == state.cursor ||
              _pressedButtons.containsKey(button))) {
        bound[ledChannel] = display.behavior == BindingBehavior.momentary
            ? _pressedButtons.containsKey(button) &&
                  _heldRestore.containsKey(binding.key)
            : _looper.bindingEnabled(display.target);
        continue;
      }
      if (binding.behavior == BindingBehavior.momentary) {
        bound[ledChannel] =
            _pressedButtons.containsKey(button) &&
            _heldRestore.containsKey(binding.key);
        continue;
      }
      final target = _scoped(binding.decodeTarget(), binding.scope);
      bound[ledChannel] = target == null
          ? null
          : _looper.bindingEnabled(target);
    }
    return bound;
  }

  int _trackIndex(PedalButton button) => switch (button) {
    PedalButton.track1 => 0,
    PedalButton.track2 => 1,
    PedalButton.track3 => 2,
    PedalButton.track4 => 3,
    _ => throw ArgumentError('not a track button: $button'),
  };

  // ---------------------------------------------------------------------------
  // Outbound frame projection (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    final ownedLifetimes = _owned.lifetimes;
    if (_ownedLifetimes != ownedLifetimes) {
      final changes = _owned.lifetimeChanges(_ownedLifetimes);
      _ownedLifetimes = ownedLifetimes;
      changes.superseded.forEach(_supersedeParameterClaims);
      if (changes.invalidated.isNotEmpty) {
        _invalidateValueTargets(changes.invalidated);
      }
    }
    if (_externalSession != null &&
        _externalSession != _looper.sessionRevision) {
      _retireAllExternal(sessionChanged: true);
      _externalSession = _looper.sessionRevision;
    } else if (_inputLocked()) {
      _retireAllExternal();
    }
    // `_l` falls back to the repository's state before the first event.
    final wasParked = isParked(_l);
    _looperState = looperState;
    _retryExternalReleases();
    _checkMidiSessionAndCleanup();
    _reduce(looperState, wasParked: wasParked);
    _pendingRestore.toList().forEach(_tryRestoreBinding);
    _pushProjected();
  }

  void _onLinkStatus(PedalLinkStatus status) {
    if (isClosed || status == PedalLinkStatus.connected) return;
    // The board went away (or stopped being trusted) mid-hold: the release is
    // never coming, so a held momentary would leave its target enabled
    // forever (B1). Restore now. A reconnect needs nothing from here: the
    // repository answers the board's hello with the current frame.
    _retireAllExternal();
    _externalContacts.clear();
    _pressedButtons.clear();
    _acceptedContacts.clear();
    _clearHeld = false;
    _clearPressToken = null;
    _invalidateGestures();
  }

  /// Projects and pushes the current LED frame. The repository drops a frame
  /// identical to the last one and re-sends that one whenever the board asks,
  /// so this can be called freely.
  void _pushProjected() {
    // Project from `_l` — the last streamed state, or the repository's current
    // snapshot when no LooperState has streamed in yet: an idle engine emits
    // no LooperState, so gating on a null `_looperState` left the LEDs dark
    // until some audio activity happened to push a state.
    final looperState = _l;
    final customFunctions = _customFunctionStates(looperState);
    final frame = projectFrame(
      looperState,
      state,
      clearFadeActive: _clearHeld,
      performanceArmed: _performanceArmed,
      masterGain: _masterGain,
      boundChains: _boundChains(),
      customFunctions: customFunctions,
      physicalCustomStates: _physicalCustomStates(looperState, customFunctions),
      acceptedContacts: _acceptedContacts,
    );
    _pedal.pushState(frame);
  }

  void _syncCustomSession() {
    final session = _looper.sessionRevision;
    if (_customActionSession == session) return;
    _customActionSession = session;
    _customLastActions.clear();
    _customActiveKeys.clear();
    _customDispatchTokens.clear();
  }

  Map<int, bool> _customFunctionStates(LooperState looper) {
    if (state.mode != InteractionMode.custom || state.pedalSetupUnavailable) {
      return const {};
    }
    _syncCustomSession();
    final result = <int, bool>{};
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++) {
      final button = kTrackSwitches[channel % ControlState.tracksPerBank];
      result[channel] = _customFunctionFor(
        button,
        channel ~/ ControlState.tracksPerBank,
        looper,
      );
    }
    return result;
  }

  Map<PedalButton, bool> _physicalCustomStates(
    LooperState looper,
    Map<int, bool> logical,
  ) {
    if (state.mode != InteractionMode.custom || state.pedalSetupUnavailable) {
      return const {};
    }
    return {
      for (final button in PedalButton.values)
        if (button != PedalButton.mode && button != PedalButton.bank)
          button: PedalBindingKey.isBankKeyed(button)
              ? logical[state.bankBaseChannel + _trackIndex(button)] ?? false
              : _customFunctionFor(button, state.activeBank, looper),
    };
  }

  bool _customFunctionFor(PedalButton button, int bank, LooperState looper) {
    final key = PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank : null,
    );
    final pair = state.pedalSetup.customFor(button, bank: bank);
    final last = _customLastActions[key];
    final completed =
        last != null && (last.action == pair.press || last.action == pair.hold);
    final action = completed ? last.action : pair.press ?? pair.hold;
    if (action == null || action is UnavailableAction) return false;
    final contact =
        _customActiveKeys[button] == key && _pressedButtons.containsKey(button);
    // A completed contact retains its fired target. After release,
    // selected-scope feedback follows the cursor the next stomp will use.
    final channels = completed && contact
        ? last.channels
        : _channelsForAction(action);
    return _customActionIsActive(
      action,
      channels,
      looper,
      contact: contact,
    );
  }

  bool _customActionIsActive(
    ControlAction action,
    List<int> channels,
    LooperState looper, {
    required bool contact,
  }) {
    bool everyTrack(bool Function(Track) enabled) =>
        channels.isNotEmpty &&
        channels.every(
          (channel) =>
              channel >= 0 &&
              channel < looper.tracks.length &&
              enabled(looper.tracks[channel]),
        );

    return switch (action) {
      ModeAction(:final mode) => state.mode == mode,
      SelectTrackAction() =>
        channels.isNotEmpty && state.cursor == channels.first,
      TrackPedalAction() => contact,
      TrackOperationAction(operation: TrackOperation.mute) => everyTrack(
        (track) => track.muted,
      ),
      TrackOperationAction(operation: TrackOperation.solo) => everyTrack(
        (track) => track.solo,
      ),
      // Empty tracks cannot fade, so only recorded scope members count; at
      // least one must hold material.
      TrackOperationAction(operation: TrackOperation.fade) => () {
        final recorded = [
          for (final channel in channels)
            if (channel >= 0 &&
                channel < looper.tracks.length &&
                looper.tracks[channel].hasContent)
              looper.tracks[channel],
        ];
        return recorded.isNotEmpty &&
            recorded.every((track) => track.fade.attenuated);
      }(),
      CommandAction(command: ControlCommand.recordPerformance) =>
        _performanceArmed,
      CommandAction(command: ControlCommand.recordPlay) => contact,
      _ => contact,
    };
  }

  // ---------------------------------------------------------------------------
  // Snapshot helpers
  // ---------------------------------------------------------------------------

  int? _capturingChannel() {
    for (final track in _tracks) {
      if (track.isCapturing) return track.channel;
    }
    return null;
  }

  /// Whether muting [channel] would leave no audible armed track.
  bool _isLastAudibleArmed(int channel) {
    final armed = armedTracks(_l, state);
    return !armed.any((c) {
      if (c == channel) return false;
      final track = _trackAt(c);
      return track != null && !track.muted && track.state == TrackState.playing;
    });
  }

  /// Whether muting [channel] would silence every track (the Rec-mode
  /// sole-track case).
  bool _isLastAudibleTrack(int channel) => !_tracks.any(
    (t) =>
        t.channel != channel &&
        !t.muted &&
        t.hasContent &&
        t.state == TrackState.playing,
  );

  int get _channelCount => ControlState.tracksPerBank * ControlState.bankCount;

  void _log(String message) {
    dev.log(message, name: 'control');
    // Skip high-frequency encoder deltas — they would flood the rotating log.
    if (!message.startsWith('encoder ')) {
      AppLog.info('control: $message');
    }
  }

  @override
  void emit(ControlState state) {
    super.emit(state);
    // Every stored-intent change re-projects the pedal frame (the diff in
    // [_pushProjected] keeps the wire quiet when the LEDs are unaffected).
    // After super.emit — onChange fires BEFORE the state field updates, and
    // a projection of the outgoing state trips the invariant assert.
    _pushProjected();
  }

  /// Permanently stops new input while admitted session work can still finish.
  /// The application calls this before draining sessions and disposing owners.
  void retireInput() {
    if (_inputRetired) return;
    _inputRetired = true;
    _invalidateGestures();
    _retireAllExternal();
    _retireMidi();
  }

  Future<void>? _closeFuture;

  @override
  Future<void> close() => _closeFuture ??= _close().then((_) => super.close());

  Future<void> _close() async {
    retireInput();
    _midiLearnTimer?.cancel();
    _midiLevelTimer?.cancel();
    _closing = true;
    _undoGesture.cancel();
    _modeGesture.cancel();
    _bankGesture.cancel();
    _recordHoldGesture.cancel();
    for (final gesture in _trackHoldGestures.values) {
      gesture.cancel();
    }
    _stopGesture.cancel();
    for (final gesture in _bindingGestures.values) {
      gesture.cancel();
    }
    await _looperSub.cancel();
    await _eventsSub.cancel();
    await _statusSub.cancel();
    await _perfStatusSub.cancel();
    await _bindingSub?.cancel();
    await _midiSub?.cancel();
    await _midiMessageSub?.cancel();
    await _midiWrites;
    await _externalTail;
    await _ownedOrdinarySub.cancel();
    await Future.wait(_bindingDecisions.values.toList());
    await _restoreWait;
    _heldRestore.clear();
    _pendingRestore.clear();
    _fxPersistence.onOrdinaryWrite = null;
    _mixSettings.onOrdinaryValues = null;
    _mixSettings.onInvalidatedValues = null;
  }
}
