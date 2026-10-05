part of 'control_cubit.dart';

/// Accepted controls still owe a release that their owner has not confirmed.
final class ControlCleanupPending implements Exception {
  /// Creates a retryable retirement failure without dropping the held claims.
  const ControlCleanupPending();

  @override
  String toString() => 'Controller release is not yet confirmed';
}

/// MIDI configuration, capture and admission use the same control owner.
extension MidiControlEditing on ControlCubit {
  /// Waits for in-flight confirmed configuration before an orderly halt.
  Future<void> flushMidiConfiguration({bool retireControls = false}) async {
    if (retireControls) {
      _haltInputSuspended = true;
      _retireMidi();
      _retireAllExternal();
      // A previous source retirement can already owe cleanup before this
      // first halt. Retry it once at this explicit flush boundary as well.
      unawaited(
        _queueMidi(() => _applyMidiProposals(_midiEngine.retryCleanup())),
      );
    }
    await _midiWrites;
    await _externalTail;
    if (retireControls) {
      // A device/editor retirement may predate this first halt. Retry only
      // after queued work drains, so an old input queue cannot hide its debt.
      _externalReleaseEligibility = null;
      _retryExternalReleases();
      await _externalTail;
    }
    await _fxPersistence.flush();
    await _mixSettings.flush();
    if (retireControls &&
        (_midiEngine.retryCleanup().any((p) => p.operations.isNotEmpty) ||
            _externalNumericReleases.values.any((v) => v.isNotEmpty) ||
            _externalPowerReleases.values.any((v) => v.isNotEmpty))) {
      throw const ControlCleanupPending();
    }
  }

  Future<void> _loadMidiConfiguration() async {
    try {
      final raw = await _settings.loadMidiConfiguration();
      var mappings = MidiMappingSet.empty;
      var enabled = true;
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is! Map<String, dynamic> ||
            json['version'] != 1 ||
            json['enabled'] is! bool ||
            !json.containsKey('mappings')) {
          throw const FormatException('Invalid MIDI configuration');
        }
        mappings = MidiMappingSet.fromJson(json['mappings']);
        enabled = json['enabled'] as bool;
      }
      if (_closing || isClosed) return;
      _midiEngine.setMappings(mappings);
      _publishMidi(
        state.copyWith(
          midiMappings: mappings,
          midiLoaded: true,
          midiControlEnabled: enabled,
          midiRemotePaused: !enabled,
        ),
      );
    } on Object catch (error, trace) {
      _publishMidi(
        state.copyWith(
          midiLoaded: true,
          midiUnavailable: true,
          midiRemotePaused: true,
          midiSaveError: '$error',
        ),
      );
      _reportMidiError(error, trace);
    }
  }

  Future<MidiSaveResult> _serializeMidi(
    Future<MidiSaveResult> Function() operation,
  ) {
    final next = _midiWrites.then((_) async {
      await load();
      if (_closing || isClosed) return const MidiSaveResult.refused('closed');
      return operation();
    });
    _midiWrites = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<MidiSaveResult> _saveMidiConfiguration(
    MidiMappingSet mappings,
    bool enabled, {
    String? mappingId,
    bool resume = false,
  }) async {
    try {
      await _settings.saveMidiConfiguration(
        jsonEncode({
          'version': 1,
          'enabled': enabled,
          'mappings': mappings.toJson(),
        }),
      );
    } on Object catch (error, trace) {
      _publishMidi(
        state.copyWith(
          midiSaveError: '$error',
          midiPersistenceUncertain:
              state.midiPersistenceUncertain ||
              error is! MidiSettingsSaveException ||
              !error.checkpointRestored,
        ),
      );
      _reportMidiError(error, trace);
      return MidiSaveResult.refused('$error');
    }
    if (_closing || isClosed) return const MidiSaveResult.refused('closed');
    ++_midiIngressRevision;
    _resetMidiDecoders();
    await _queueMidi(() async {
      await _applyMidiProposals(_midiEngine.setMappings(mappings));
    });
    _publishMidi(
      state.copyWith(
        midiMappings: mappings,
        midiControlEnabled: enabled,
        midiUnavailable: false,
        midiPersistenceUncertain: false,
        clearMidiSaveError: true,
        midiRemotePaused: resume ? !enabled : state.midiRemotePaused,
      ),
    );
    return MidiSaveResult.saved(mappingId: mappingId);
  }

  /// Deliberately replaces unreadable settings only after durable confirmation.
  Future<MidiSaveResult> resetMidiConfiguration() => _serializeMidi(
    () => _saveMidiConfiguration(MidiMappingSet.empty, true, resume: true),
  );

  /// Saves only this still-current draft, allocating new IDs within the queue.
  Future<MidiSaveResult> saveMidiMapping(
    MidiMapping mapping, {
    required Object owner,
    bool create = false,
    MidiMapping? expected,
  }) => _serializeMidi(() async {
    if (!identical(state.midiEdit?.owner, owner)) {
      return const MidiSaveResult.refused('staleEditor');
    }
    final existing = state.midiMappings.byId(mapping.id);
    if (!create && (existing == null || existing != expected)) {
      return const MidiSaveResult.refused('staleMapping');
    }
    var saved = mapping;
    if (create) {
      String id;
      do {
        id = 'midi-${_nextMidiId++}';
      } while (state.midiMappings.byId(id) != null);
      saved = MidiMapping(
        id: id,
        source: mapping.source,
        behavior: mapping.behavior,
        controls: mapping.controls,
        enabled: mapping.enabled,
      );
    } else {
      saved = mapping.copyWith(enabled: existing!.enabled);
    }
    if (state.midiMappings.conflictWith(saved.source, exceptId: saved.id) !=
        null) {
      return const MidiSaveResult.refused('sourceConflict');
    }
    return _saveMidiConfiguration(
      state.midiMappings.withMapping(saved),
      state.midiControlEnabled,
      mappingId: saved.id,
    );
  });

  /// Deletes the requested saved row without resurrecting a stale draft.
  Future<MidiSaveResult> deleteMidiMapping(
    String id, {
    Object? owner,
    MidiMapping? expected,
  }) => _serializeMidi(() async {
    if (owner != null && !identical(state.midiEdit?.owner, owner)) {
      return const MidiSaveResult.refused('staleEditor');
    }
    final existing = state.midiMappings.byId(id);
    if (existing == null || (expected != null && expected != existing)) {
      return const MidiSaveResult.refused('staleMapping');
    }
    return _saveMidiConfiguration(
      state.midiMappings.withoutMapping(id),
      state.midiControlEnabled,
    );
  });

  /// Confirms a mapping's enabled state while retaining its source reservation.
  Future<MidiSaveResult> setMidiMappingEnabled(
    String id, {
    required bool enabled,
  }) => _serializeMidi(() async {
    final current = state.midiMappings.byId(id);
    if (current == null) return const MidiSaveResult.refused('staleMapping');
    return _saveMidiConfiguration(
      state.midiMappings.withMapping(current.copyWith(enabled: enabled)),
      state.midiControlEnabled,
    );
  });

  /// Off pauses immediately. A refused disable stays paused until explicit
  /// retry.
  Future<MidiSaveResult> setMidiControlEnabled({required bool enabled}) {
    if (!enabled) {
      _publishMidi(state.copyWith(midiRemotePaused: true));
      _retireMidi();
    }
    return _serializeMidi(
      () => _saveMidiConfiguration(
        state.midiMappings,
        enabled,
        resume: true,
      ),
    );
  }

  /// Pauses only the edited device, owned by one route/draft identity.
  void beginMidiEdit({required String device, required Object owner}) {
    _midiLearnTimer?.cancel();
    _retireMidi(device: device);
    _publishMidi(
      state.copyWith(
        midiEdit: MidiEdit(device: device, owner: owner),
      ),
    );
  }

  /// An old page cannot resume or cancel a newer editor.
  void endMidiEdit(Object owner) {
    if (!identical(state.midiEdit?.owner, owner)) return;
    _midiLearnTimer?.cancel();
    ++_midiIngressRevision;
    _resetMidiDecoders();
    _publishMidi(state.copyWith(clearMidiEdit: true));
  }

  /// Starts selected-device Learn in an explicit format and wire channel.
  void startMidiLearn(
    MidiProtocol protocol, {
    required Object owner,
    int? channel,
  }) {
    final edit = state.midiEdit;
    if (edit == null ||
        !identical(edit.owner, owner) ||
        edit.device != _midiDevices?.session?.device ||
        (channel != null && (channel < 0 || channel > 15))) {
      return;
    }
    _midiLearnTimer?.cancel();
    _midiLearnDecoder.reset(edit.device);
    final token = Object();
    _publishMidi(
      state.copyWith(
        midiEdit: edit.withLearn(
          MidiLearn(
            protocol: protocol,
            token: token,
            channel: channel,
          ),
        ),
      ),
    );
    _midiLearnTimer = Timer(_learnTimeout, () {
      final current = state.midiEdit;
      if (current == null ||
          !identical(current.owner, owner) ||
          !identical(current.learn?.token, token)) {
        return;
      }
      _midiLearnDecoder.reset(current.device);
      _publishMidi(
        state.copyWith(midiEdit: current.withLearn(null, timedOut: true)),
      );
    });
  }

  /// Cancels only Learn belonging to this editor.
  void cancelMidiLearn(Object owner) {
    final edit = state.midiEdit;
    if (edit == null || !identical(edit.owner, owner)) return;
    _midiLearnTimer?.cancel();
    _midiLearnDecoder.reset(edit.device);
    _publishMidi(state.copyWith(midiEdit: edit.withLearn(null)));
  }

  void _resetMidiDecoders() {
    final devices = {
      if (_midiCapture != null) _midiCapture!.device,
      for (final row in state.midiMappings.mappings) row.source.device,
      if (state.midiEdit != null) state.midiEdit!.device,
    };
    for (final device in devices) {
      _midiDecoder.reset(device);
      _midiLearnDecoder.reset(device);
      _midiSignalDecoder.reset(device);
    }
    _midiLevels = {};
    _midiLevelTimer?.cancel();
    _midiLevelTimer = null;
    _publishMidi(state.copyWith(midiLevels: const {}));
  }

  void _onMidiConnection(MidiConnection _) {
    final capture = _midiDevices?.session;
    if (capture == _midiCapture) return;
    final previous = _midiCapture;
    if (previous != null) _retireMidi(device: previous.device);
    _midiCapture = capture;
    ++_midiIngressRevision;
    _resetMidiDecoders();
    final edit = state.midiEdit;
    if (edit != null) cancelMidiLearn(edit.owner);
  }

  void _onMidiInput(MidiInputMessage message) {
    if (_inputRetired ||
        _closing ||
        isClosed ||
        message.session != _midiDevices?.session) {
      return;
    }
    _midiReadTime = message.timestampMicros == null
        ? (_midiClock?.call() ?? _midiStopwatch.elapsed)
        : Duration(microseconds: message.timestampMicros!);
    final device = message.session.device;
    final input = message.input;
    final edit = state.midiEdit;
    final learn = edit?.learn;
    if (edit?.device == device &&
        learn != null &&
        learn.isListening &&
        (learn.channel == null || learn.channel == input.midiChannel)) {
      final reading = _midiLearnDecoder.feed(device, input, learn.protocol);
      if (reading != null &&
          reading.delta != 0 &&
          !(reading.source.kind == ControllerSourceKind.midiNote &&
              reading.value == 0)) {
        _midiLearnTimer?.cancel();
        _publishMidi(
          state.copyWith(
            midiEdit: edit!.withLearn(
              MidiLearn(
                protocol: learn.protocol,
                token: learn.token,
                channel: learn.channel,
                reading: reading,
              ),
            ),
          ),
        );
      }
    }
    final protocols = {
      for (final row in state.midiMappings.mappings)
        if (row.source.device == device) row.source.protocol,
    };
    for (final protocol in protocols) {
      final reading = _midiSignalDecoder.feed(device, input, protocol);
      if (reading == null) continue;
      for (final row in state.midiMappings.mappings) {
        if (row.source.sameAs(reading.source)) {
          _midiLevels[row.source] = reading;
        }
      }
    }
    _midiLevelTimer ??= Timer(const Duration(milliseconds: 33), () {
      _midiLevelTimer = null;
      _publishMidi(state.copyWith(midiLevels: Map.unmodifiable(_midiLevels)));
    });
    if (!_midiCanDispatch(device)) return;
    final readings = [
      for (final protocol in protocols)
        ?_midiDecoder.feed(device, input, protocol),
    ];
    if (readings.isEmpty) return;
    final revision = _midiIngressRevision;
    final session = _looper.sessionRevision;
    final origins = {
      for (final event in readings)
        event: _mixOrigins([
          for (final mapping in state.midiMappings.mappings)
            if (mapping.source.sameAs(event.source))
              for (final control in mapping.controls)
                ?ControlValueTarget.tryParse(control.key),
        ]),
    };
    unawaited(
      _queueMidi(() async {
        if (revision != _midiIngressRevision ||
            session != _looper.sessionRevision ||
            message.session != _midiDevices?.session ||
            !_midiCanDispatch(device)) {
          return;
        }
        for (final event in readings) {
          if (!_mixOriginsCurrent(origins[event]!)) continue;
          await _applyMidiProposals(
            _midiEngine.prepare(event),
            decayOrigins: origins[event]!.decay,
            oneShotOrigins: origins[event]!.oneShot,
            recordLengthOrigins: origins[event]!.recordLength,
            recordTimingOrigins: origins[event]!.recordTiming,
            clickModeOrigins: origins[event]!.clickMode,
            recordStartOrigins: origins[event]!.recordStart,
          );
        }
      }),
    );
  }

  bool _midiCanDispatch(String device) =>
      !_inputRetired &&
      !_closing &&
      !isClosed &&
      !_controlInputSuspended &&
      state.midiLoaded &&
      !state.midiUnavailable &&
      state.midiControlEnabled &&
      !state.midiRemotePaused &&
      state.midiEdit?.device != device;

  Future<void> _queueMidi(Future<void> Function() operation) {
    final next = _externalTail.then((_) => operation());
    return _externalTail = next.catchError(_reportMidiError);
  }

  void _retireMidi({String? device}) {
    ++_midiIngressRevision;
    _resetMidiDecoders();
    unawaited(
      _queueMidi(() => _applyMidiProposals(_midiEngine.retire(device: device))),
    );
  }

  void _checkMidiSessionAndCleanup() {
    final session = _looper.sessionRevision;
    if (_midiSession != session) {
      _midiSession = session;
      ++_midiIngressRevision;
      _midiEngine.reset();
      for (final holders in _activationHolders.values) {
        holders.removeWhere(
          (key, _) =>
              key is ((String, int, int), int) ||
              key is (Symbol, Object) &&
                  (key.$1 == #ordinary || key.$1 == #retained),
        );
      }
      for (final holders in _parameterHolders.values) {
        holders.removeWhere(
          (key, _) =>
              key is ((String, int, int), int) ||
              key is (Symbol, Object) &&
                  (key.$1 == #ordinary || key.$1 == #retained),
        );
      }
      _midiTargets.clear();
      _midiActions.clear();
      _midiHolderKeys.clear();
      _midiReleasedValues.clear();
      _syncMidiDurableFx();
      _resetMidiDecoders();
    }
    final eligibility = _releaseEligibility;
    if (_midiRetryEligibility == eligibility ||
        !_looper.mixSettingsSettled ||
        !_looper.fxRecipesSettled) {
      return;
    }
    _midiRetryEligibility = eligibility;
    unawaited(
      _queueMidi(() => _applyMidiProposals(_midiEngine.retryCleanup())),
    );
  }

  double? _readMidiValue(String key) {
    final value = ControlValueTarget.tryParse(key);
    if (value != null) return _readControlValue(value);
    final activation = FxBindingTarget.tryParse(key);
    final enabled = activation == null
        ? null
        : _looper.bindingEnabled(activation);
    return enabled == null
        ? null
        : enabled
        ? 1
        : 0;
  }

  double _midiStep(String key) {
    final target = ControlValueTarget.tryParse(key);
    // Master uses the hardware encoder's established 1/64 normalized step.
    if (target is MasterGainTarget) return ControlCubit._encoderStep;
    if (target is MixValueTarget) return target.relativeStep;
    if (target is ClickVolumeTarget) return target.relativeStep;
    if (target is DecayValueTarget) return target.relativeStep;
    if (target is OneShotValueTarget) return target.relativeStep;
    if (target is RecordLengthValueTarget) return target.relativeStep;
    if (target is RecordTimingValueTarget) return target.relativeStep;
    if (target is ClickModeValueTarget) return target.relativeStep;
    if (target is CountInValueTarget) return target.relativeStep;
    if (target is FxParamTarget) {
      final divisions = _midiParamDivisions(target);
      if (divisions != null && divisions > 0) return 1 / divisions;
    }
    return 0.01;
  }

  Future<void> _applyMidiProposals(
    List<MidiProposal> proposals, {
    Map<DecayValueTarget, _DecayOrigin>? decayOrigins,
    Map<OneShotValueTarget, _OneShotOrigin>? oneShotOrigins,
    Map<RecordLengthValueTarget, _RecordLengthOrigin>? recordLengthOrigins,
    Map<RecordTimingValueTarget, _RecordTimingOrigin>? recordTimingOrigins,
    Map<ClickModeValueTarget, _ClickModeOrigin>? clickModeOrigins,
    Map<CountInValueTarget, _RecordStartOrigin>? recordStartOrigins,
  }) async {
    final session = _looper.sessionRevision;
    for (final proposal in proposals) {
      final captured = _mixOrigins([
        for (final operation in proposal.operations)
          ?ControlValueTarget.tryParse(operation.key),
      ]);
      final origins = (
        mix: captured.mix,
        click: captured.click,
        decay: decayOrigins ?? captured.decay,
        oneShot: oneShotOrigins ?? captured.oneShot,
        recordLength: recordLengthOrigins ?? captured.recordLength,
        recordTiming: recordTimingOrigins ?? captured.recordTiming,
        clickMode: clickModeOrigins ?? captured.clickMode,
        recordStart: recordStartOrigins ?? captured.recordStart,
      );
      if (session != _looper.sessionRevision || isClosed) return;
      Object? pending;
      final appliedOwners = <FxAddress>{};
      try {
        final accepted = <int>{};
        final powers = <FxBindingTarget, bool>{};
        final values = <ControlValueTarget, double>{};
        final rows =
            <
              int,
              ({Object target, Object? holder, bool ending, double? value})
            >{};
        for (final op in proposal.operations) {
          final row = (
            proposal.mappingId,
            proposal.generation,
            op.controlIndex,
          );
          switch (op) {
            case MidiActionRun(:final key, :final expectsEnd):
              if (_takeLocked()) continue;
              final action = ControlAction.tryParse(key);
              if (action == null) continue;
              final channels = List<int>.unmodifiable(
                _channelsForAction(action),
              );
              final applied = await _runAction(action, channels);
              if (session != _looper.sessionRevision || isClosed) return;
              if (applied) {
                accepted.add(op.controlIndex);
                if (expectsEnd) {
                  _midiActions[row] = (action: action, channels: channels);
                }
              }
            case MidiActionEnd():
              // Supported catalogue actions are immediate. Still retire their
              // exact accepted identity here; unavailable future held actions
              // cannot enter the catalogue through an opaque key.
              _midiActions.remove(row);
              accepted.add(op.controlIndex);
            case MidiParameterWrite() || MidiParameterEnd():
              final ending =
                  op is MidiParameterEnd ||
                  (op is MidiParameterWrite && op.cleanup);
              if (!ending && _takeLocked()) continue;
              final target = ending
                  ? _midiTargets[row]
                  : ControlValueTarget.tryParse(op.key) ??
                        FxBindingTarget.tryParse(op.key);
              final holder = _midiHolderKeys[row];
              if (target is DecayValueTarget &&
                  !_decayOriginCurrent(target, origins.decay[target])) {
                continue;
              }
              if (target is OneShotValueTarget &&
                  !_oneShotOriginCurrent(target, origins.oneShot[target])) {
                continue;
              }
              if (target is RecordLengthValueTarget &&
                  !_recordLengthOriginCurrent(
                    target,
                    origins.recordLength[target],
                  )) {
                continue;
              }
              if (target is RecordTimingValueTarget &&
                  !_recordTimingOriginCurrent(
                    target,
                    origins.recordTiming[target],
                  )) {
                continue;
              }
              if (target is ClickModeValueTarget &&
                  !_clickModeOriginCurrent(
                    target,
                    origins.clickMode[target],
                  )) {
                continue;
              }
              if (target is CountInValueTarget &&
                  !_recordStartOriginCurrent(
                    target,
                    origins.recordStart[target],
                  )) {
                continue;
              }
              if (target == null) {
                if (ending) accepted.add(op.controlIndex);
                continue;
              }
              if (op is MidiParameterEnd) {
                // A continuous/toggle contribution keeps its accepted sound,
                // without acquiring new retirement priority or source lifetime.
                final base = (#retained, target);
                if (target is FxBindingTarget) {
                  final holders = _activationHolders[target];
                  final value = holders?[holder];
                  if (value != null &&
                      value.order > (holders?[base]?.order ?? -1)) {
                    holders![base] = value;
                  }
                } else if (target is ControlValueTarget) {
                  final holders = _parameterHolders[target];
                  final value = holders?[holder];
                  if (value != null &&
                      value.order > (holders?[base]?.order ?? -1)) {
                    holders![base] = value;
                  }
                }
                _dropMidiHolder(row, target, holder);
                accepted.add(op.controlIndex);
                continue;
              }
              final literal = op is MidiParameterWrite ? op.value : null;
              var value = literal;
              if (target is FxBindingTarget) {
                final current = _looper.bindingEnabled(target);
                if (current == null) {
                  if (ending) {
                    _dropMidiHolder(row, target, holder);
                    accepted.add(op.controlIndex);
                  }
                  continue;
                }
                if (ending) {
                  final survivor = _survivingActivation(
                    target,
                    excluding: holder,
                  );
                  value = survivor == null
                      ? literal
                      : survivor
                      ? 1
                      : 0;
                }
                if (value != null) powers[target] = value >= 0.5;
              } else if (target is ControlValueTarget) {
                if (!_controlValueResolves(target, cleanup: ending)) {
                  if (ending) {
                    _dropMidiHolder(row, target, holder);
                    accepted.add(op.controlIndex);
                  }
                  continue;
                }
                if (ending) {
                  value =
                      _survivingParameter(target, excluding: holder) ?? literal;
                }
                if (value != null) {
                  values[target] = ending
                      ? value
                      : _coerceMidiValue(target, value);
                }
              }
              rows[op.controlIndex] = (
                target: target,
                holder: holder,
                ending: ending,
                value: value,
              );
              if (ending && value == null) {
                _dropMidiHolder(row, target, holder);
                accepted.add(op.controlIndex);
              }
          }
        }
        final recorded = <int>{};
        void recordAccepted() {
          for (final index
              in accepted
                  .where((index) => !recorded.contains(index))
                  .toList()) {
            recorded.add(index);
            final record = rows[index];
            if (record == null) continue;
            if (record.target case final DecayValueTarget target) {
              if (!_decayOriginCurrent(target, origins.decay[target])) {
                accepted.remove(index);
                continue;
              }
            }
            if (record.target case final OneShotValueTarget target) {
              if (!_oneShotOriginCurrent(target, origins.oneShot[target])) {
                accepted.remove(index);
                continue;
              }
            }
            if (record.target case final RecordLengthValueTarget target) {
              if (!_recordLengthOriginCurrent(
                target,
                origins.recordLength[target],
              )) {
                accepted.remove(index);
                continue;
              }
            }
            if (record.target case final RecordTimingValueTarget target) {
              if (!_recordTimingOriginCurrent(
                target,
                origins.recordTiming[target],
              )) {
                accepted.remove(index);
                continue;
              }
            }
            if (record.target case final ClickModeValueTarget target) {
              if (!_clickModeOriginCurrent(
                target,
                origins.clickMode[target],
              )) {
                accepted.remove(index);
                continue;
              }
            }
            if (record.target case final CountInValueTarget target) {
              if (!_recordStartOriginCurrent(
                target,
                origins.recordStart[target],
              )) {
                accepted.remove(index);
                continue;
              }
            }
            final row = (proposal.mappingId, proposal.generation, index);
            if (record.ending) {
              _dropMidiHolder(row, record.target, record.holder);
            } else {
              // An accepted intent supersedes only its own older claim.
              // A refused attempt leaves the old ticket and priority untouched.
              _dropMidiHolder(row, record.target, record.holder);
              final holder = (row, ++_midiIntentSequence);
              _midiHolderKeys[row] = holder;
              _midiTargets[row] = record.target;
              final operation = proposal.operations.firstWhere(
                (op) => op.controlIndex == index,
              );
              if (operation is MidiParameterWrite && operation.held == true) {
                final released = _midiReleasedFor(proposal, index);
                if (released != null) _midiReleasedValues[holder] = released;
              }
              switch (record.target) {
                case final FxBindingTarget target:
                  (_activationHolders[target] ??= {})[holder] = (
                    value: powers[target]!,
                    order: ++_activationOrder,
                  );
                case final ControlValueTarget target:
                  if (target is MixValueTarget ||
                      target is ClickVolumeTarget ||
                      target is DecayValueTarget ||
                      target is OneShotValueTarget ||
                      target is RecordLengthValueTarget ||
                      target is RecordTimingValueTarget ||
                      target is ClickModeValueTarget ||
                      target is CountInValueTarget) {
                    _retireMixBaseline(target);
                  }
                  (_parameterHolders[target] ??= {})[holder] = (
                    value: values[target]!,
                    order: ++_activationOrder,
                  );
              }
            }
          }
          _syncMidiDurableFx();
        }

        bool cancelled() =>
            session != _looper.sessionRevision ||
            !_mixOriginsCurrent(origins) ||
            isClosed;
        if (cancelled()) return;
        final fx = <FxParamTarget, double>{
          for (final e in values.entries)
            if (e.key is FxParamTarget) e.key as FxParamTarget: e.value,
        };
        final admitted = _looper.writeExternalFx(
          activations: powers,
          parameters: fx,
        );
        if (admitted.isNotEmpty) {
          pending = _fxPersistence.beginPending();
          final receipt = await _looper.settleFxRecipes(
            waitForCallback: true,
            cancelled: cancelled,
          );
          if (cancelled()) return;
          if (receipt.isOk) {
            appliedOwners.addAll(admitted);
            for (final entry in rows.entries) {
              final target = entry.value.target;
              final address = switch (target) {
                FxBindingTarget() => target.address,
                FxParamTarget() => target.address,
                _ => null,
              };
              if (address != null && admitted.contains(address)) {
                accepted.add(entry.key);
              }
            }
          }
        }
        // Publish FX ownership before waiting on the independent mix owner.
        // Session save holds the mix fence and may await this FX barrier.
        recordAccepted();
        final settledIndices = Set<int>.of(accepted);
        _midiEngine.settle(proposal, settledIndices);
        if (pending != null) {
          _fxPersistence.finishPending(pending);
          pending = null;
        }
        final mixValues = <MixValueTarget, double>{};
        final mixReleased = <MixValueTarget, double>{};
        final mixIndices = <int>{};
        for (final entry in rows.entries) {
          final target = entry.value.target;
          if (accepted.contains(entry.key) || target is! MixValueTarget) {
            continue;
          }
          final value = values[target];
          if (value == null) continue;
          final op = proposal.operations.firstWhere(
            (op) => op.controlIndex == entry.key,
          );
          final rowKey = (proposal.mappingId, proposal.generation, entry.key);
          // Only cleanup inherits a surviving hold. A new non-held intent
          // becomes durable itself once its write is confirmed.
          final released = op is MidiParameterWrite && op.held == true
              ? _midiReleasedFor(proposal, op.controlIndex)
              : entry.value.ending
              ? _survivingMidiReleased(
                  target,
                  excluding: _midiHolderKeys[rowKey],
                )
              : null;
          mixValues[target] = value;
          if (released != null) mixReleased[target] = released;
          mixIndices.add(entry.key);
        }
        if (mixValues.isNotEmpty) {
          final result = await _mixSettings.setControllerValues(
            mixValues,
            releasedValues: mixReleased,
          );
          if (cancelled()) return;
          if (result.isOk) accepted.addAll(mixIndices);
        }
        for (final entry in rows.entries) {
          if (accepted.contains(entry.key) || entry.value.value == null) {
            continue;
          }
          final target = entry.value.target;
          final value = values[target];
          if (value == null) continue;
          switch (target) {
            case MixValueTarget():
              break;
            case ClickVolumeTarget():
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _clickVolume.setControllerClickVolume(
                target.toDomain(value),
                lifetime: origins.click ?? _clickVolume.clickVolumeLifetime,
                releasedVolume: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk) accepted.add(entry.key);
            case DecayValueTarget():
              final origin = origins.decay[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_decayOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _decay.setControllerDecay(
                target.address,
                target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedPercent: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _decayOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case OneShotValueTarget():
              final origin = origins.oneShot[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_oneShotOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _oneShot.setControllerOneShot(
                target.address,
                oneShot: target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedOneShot: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _oneShotOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case RecordLengthValueTarget():
              final origin = origins.recordLength[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_recordLengthOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _recordLength.setControllerRecordLength(
                target.address,
                target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedBars: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _recordLengthOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case RecordTimingValueTarget():
              final origin = origins.recordTiming[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_recordTimingOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _recordTiming.setControllerTiming(
                target.address,
                target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedTiming: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _recordTimingOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case ClickModeValueTarget():
              final origin = origins.clickMode[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_clickModeOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _clickMode.setControllerClickMode(
                target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedMode: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _clickModeOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case CountInValueTarget():
              final origin = origins.recordStart[target];
              if (origin == null ||
                  !value.isFinite ||
                  !_recordStartOriginCurrent(target, origin)) {
                continue;
              }
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, entry.key)
                  : entry.value.ending
                  ? _survivingMidiReleased(
                      target,
                      excluding: entry.value.holder,
                    )
                  : null;
              final outcome = await _recordStart.setControllerCountIn(
                target.toDomain(value),
                lifetime: origin.lifetime,
                revision: origin.revision,
                releasedBars: released == null
                    ? null
                    : target.toDomain(released),
              );
              if (cancelled()) return;
              if (outcome.isOk && _recordStartOriginCurrent(target, origin)) {
                accepted.add(entry.key);
              }
            case MasterGainTarget():
              if (_looper.setMasterGain(value).isOk) {
                _masterGain = value;
                accepted.add(entry.key);
              }
          }
        }
        if (cancelled()) return;
        recordAccepted();
        _syncMidiDurableFx();
        _midiEngine.settle(proposal, accepted.difference(settledIndices));
        _midiRetryEligibility = _releaseEligibility;
        _pushProjected();
      } finally {
        if (pending != null) _fxPersistence.finishPending(pending);
      }
      for (final address in appliedOwners) {
        if (session != _looper.sessionRevision || isClosed) break;
        await saveFxOwner(
          settings: _settings,
          projection: _fxPersistence,
          address: address,
        );
      }
    }
  }

  void _dropMidiHolder((String, int, int) row, Object target, Object? holder) {
    // A captured cleanup can never retire a later accepted intent.
    if (_midiHolderKeys[row] != holder) return;
    if (target is FxBindingTarget) {
      _activationHolders[target]?.remove(holder);
      if (_activationHolders[target]?.isEmpty ?? true) {
        _activationBase.remove(target);
      }
    } else if (target is ControlValueTarget) {
      _parameterHolders[target]?.remove(holder);
    }
    _midiReleasedValues.remove(holder);
    _midiHolderKeys.remove(row);
    _midiTargets.remove(row);
  }

  double _coerceMidiValue(ControlValueTarget target, double value) {
    if (target is DecayValueTarget) {
      return value.isFinite ? target.fromDomain(target.toDomain(value)) : value;
    }
    if (target is OneShotValueTarget) {
      return value.isFinite
          ? target.fromDomain(oneShot: target.toDomain(value))
          : value;
    }
    if (target is RecordLengthValueTarget) {
      return value.isFinite ? target.fromDomain(target.toDomain(value)) : value;
    }
    if (target is RecordTimingValueTarget) {
      return value.isFinite ? target.fromDomain(target.toDomain(value)) : value;
    }
    if (target is ClickModeValueTarget) {
      return value.isFinite ? target.fromDomain(target.toDomain(value)) : value;
    }
    if (target is CountInValueTarget) {
      return value.isFinite ? target.fromDomain(target.toDomain(value)) : value;
    }
    final clamped = value.clamp(0.0, 1.0);
    if (target is FxParamTarget) {
      final divisions = _midiParamDivisions(target);
      if (divisions != null && divisions > 0) {
        return (clamped * divisions).round() / divisions;
      }
    }
    return clamped;
  }

  int? _midiParamDivisions(FxParamTarget target) {
    for (final effect
        in _looper.chainEntriesAt(target.address) ?? <TrackEffect>[]) {
      if (effect.slotId == target.slotId &&
          effect is BuiltInEffect &&
          target.param >= 0 &&
          target.param < effect.type.params.length) {
        return effect.type.params[target.param].divisions;
      }
    }
    return null;
  }

  double? _midiReleasedFor(MidiProposal proposal, int index) {
    final mapping = state.midiMappings.byId(proposal.mappingId);
    if (mapping == null || index >= mapping.controls.length) return null;
    final control = mapping.controls[index];
    if (control is! MidiParameterControl) return null;
    final target = ControlValueTarget.tryParse(control.key);
    return target == null ? control.low : _coerceMidiValue(target, control.low);
  }

  double? _survivingMidiReleased(
    ControlValueTarget target, {
    Object? excluding,
  }) {
    Object? winner;
    var order = -1;
    for (final entry in (_parameterHolders[target] ?? {}).entries) {
      if (entry.key != excluding && entry.value.order > order) {
        winner = entry.key;
        order = entry.value.order;
      }
    }
    if (winner is MappingTrigger) {
      return _externalMixReleased[_externalInput(winner)]?[target];
    }
    return _midiReleasedValues[winner];
  }

  void _syncMidiDurableFx() {
    final powers = <FxBindingTarget, bool>{};
    final parameters = <FxParamTarget, double>{};
    for (final entry in _activationHolders.entries) {
      Object? winner;
      var order = -1;
      for (final holder in entry.value.entries) {
        if (holder.value.order > order) {
          winner = holder.key;
          order = holder.value.order;
        }
      }
      final released = _midiReleasedValues[winner];
      if (released != null) powers[entry.key] = released >= 0.5;
    }
    for (final target in _parameterHolders.keys.whereType<FxParamTarget>()) {
      final released = _survivingMidiReleased(target);
      if (released != null) parameters[target] = released;
    }
    _fxPersistence.replace(powers: powers, parameters: parameters);
  }

  void _onOrdinaryFxWrite(Object target, double value) {
    final key = (#ordinary, target);
    if (target is FxBindingTarget) {
      (_activationHolders[target] ??= {})[key] = (
        value: value >= 0.5,
        order: ++_activationOrder,
      );
    } else if (target is ControlValueTarget) {
      (_parameterHolders[target] ??= {})[key] = (
        value: value,
        order: ++_activationOrder,
      );
    }
    _syncMidiDurableFx();
  }

  double? _readControlValue(ControlValueTarget target) =>
      _looper.readValueTarget(
        target,
        clickVolume: _clickVolume.clickVolume,
        decaySnapshot: _decay.decaySnapshot,
        oneShotSnapshot: _oneShot.oneShotSnapshot,
        recordLengthSnapshot: _recordLength.recordLengthSnapshot,
        recordTimingSnapshot: _recordTiming.recordTimingSnapshot,
        clickModeSnapshot: _clickMode.clickModeSnapshot,
        recordStartSnapshot: _recordStart.recordStartSnapshot,
      );

  bool _controlValueResolves(
    ControlValueTarget target, {
    bool cleanup = false,
  }) =>
      // Fixed scopes remain structurally present during owner recovery. Their
      // rejected release stays owed; new acquisitions still need readiness.
      (cleanup &&
          (target is ClickModeValueTarget ||
              target is CountInValueTarget ||
              target is RecordTimingValueTarget && target.address.isValid)) ||
      _looper.valueTargetResolves(
        target,
        clickVolume: _clickVolume.clickVolume,
        decaySnapshot: _decay.decaySnapshot,
        oneShotSnapshot: _oneShot.oneShotSnapshot,
        recordLengthSnapshot: _recordLength.recordLengthSnapshot,
        recordTimingSnapshot: _recordTiming.recordTimingSnapshot,
        clickModeSnapshot: _clickMode.clickModeSnapshot,
        recordStartSnapshot: _recordStart.recordStartSnapshot,
      );

  _ControlOrigins _mixOrigins(
    Iterable<ControlValueTarget> targets,
  ) => (
    mix: _mixSettings.controllerOrigins(targets.whereType<MixValueTarget>()),
    click: targets.any((target) => target is ClickVolumeTarget)
        ? _clickVolume.clickVolumeLifetime
        : null,
    decay: {
      for (final target in targets.whereType<DecayValueTarget>())
        target: (
          lifetime: _decay.decayLifetime,
          revision: _decay.decayRevision(target.address),
        ),
    },
    oneShot: {
      for (final target in targets.whereType<OneShotValueTarget>())
        target: (
          lifetime: _oneShot.oneShotLifetime,
          revision: _oneShot.oneShotRevision(target.address),
        ),
    },
    recordLength: {
      for (final target in targets.whereType<RecordLengthValueTarget>())
        target: (
          lifetime: _recordLength.recordLengthLifetime,
          revision: _recordLength.recordLengthRevision(target.address),
        ),
    },
    recordTiming: {
      for (final target in targets.whereType<RecordTimingValueTarget>())
        target: (
          lifetime: _recordTiming.recordTimingLifetime,
          revision: _recordTiming.recordTimingRevision(target.address),
        ),
    },
    clickMode: {
      for (final target in targets.whereType<ClickModeValueTarget>())
        target: (
          lifetime: _clickMode.clickModeLifetime,
          revision: _clickMode.clickModeRevision,
        ),
    },
    recordStart: {
      for (final target in targets.whereType<CountInValueTarget>())
        target: (
          lifetime: _recordStart.recordStartLifetime,
          revision: _recordStart.recordStartRevision,
        ),
    },
  );

  bool _mixOriginsCurrent(_ControlOrigins origins) =>
      _mixSettings.controllerOriginsCurrent(origins.mix) &&
      (origins.click == null ||
          origins.click == _clickVolume.clickVolumeLifetime);

  bool _decayOriginCurrent(DecayValueTarget target, _DecayOrigin? origin) =>
      origin != null &&
      origin.lifetime == _decay.decayLifetime &&
      origin.revision == _decay.decayRevision(target.address);

  bool _oneShotOriginCurrent(
    OneShotValueTarget target,
    _OneShotOrigin? origin,
  ) =>
      origin != null &&
      origin.lifetime == _oneShot.oneShotLifetime &&
      origin.revision == _oneShot.oneShotRevision(target.address);

  bool _recordLengthOriginCurrent(
    RecordLengthValueTarget target,
    _RecordLengthOrigin? origin,
  ) =>
      origin != null &&
      origin.lifetime == _recordLength.recordLengthLifetime &&
      origin.revision == _recordLength.recordLengthRevision(target.address);

  bool _recordTimingOriginCurrent(
    RecordTimingValueTarget target,
    _RecordTimingOrigin? origin,
  ) =>
      origin != null &&
      origin.lifetime == _recordTiming.recordTimingLifetime &&
      origin.revision == _recordTiming.recordTimingRevision(target.address);

  bool _clickModeOriginCurrent(
    ClickModeValueTarget target,
    _ClickModeOrigin? origin,
  ) =>
      origin != null &&
      origin.lifetime == _clickMode.clickModeLifetime &&
      origin.revision == _clickMode.clickModeRevision;

  bool _recordStartOriginCurrent(
    CountInValueTarget target,
    _RecordStartOrigin? origin,
  ) =>
      origin != null &&
      origin.lifetime == _recordStart.recordStartLifetime &&
      origin.revision == _recordStart.recordStartRevision;

  void _supersedeParameterClaims(ControlValueTarget target) {
    _midiEngine.supersedeParameterClaims({target.canonicalString()});
    for (final entry in _midiTargets.entries.toList()) {
      if (entry.value == target) {
        _dropMidiHolder(entry.key, target, _midiHolderKeys[entry.key]);
      }
    }
    _parameterHolders.remove(target);
    for (final input in PedalCtrlInput.values) {
      (_externalInvalidatedMix[input] ??= {}).add(target);
      _externalMixReleased[input]?.remove(target);
      _externalNumericReleases[input]?.remove(target);
    }
  }

  void _retireMixBaseline(ControlValueTarget target) {
    _parameterHolders[target]?.removeWhere(
      (key, _) =>
          key is (Symbol, Object) &&
          (key.$1 == #ordinary || key.$1 == #retained),
    );
  }

  void _invalidateMixTargets(Set<MixValueTarget> targets) =>
      _invalidateValueTargets(targets);

  void _invalidateValueTargets(Set<ControlValueTarget> targets) {
    _midiEngine.invalidateTargets({
      for (final target in targets) target.canonicalString(),
    });
    for (final entry in _midiTargets.entries.toList()) {
      if (targets.contains(entry.value)) {
        _dropMidiHolder(entry.key, entry.value, _midiHolderKeys[entry.key]);
      }
    }
    targets.forEach(_parameterHolders.remove);
    for (final input in PedalCtrlInput.values) {
      (_externalInvalidatedMix[input] ??= {}).addAll(targets);
      _externalMixReleased[input]?.removeWhere(
        (target, _) => targets.contains(target),
      );
      _externalNumericReleases[input]?.removeWhere(
        (target, _) => targets.contains(target),
      );
    }
    _expressionRaw.clear();
    _resetMidiDecoders();
  }

  void _onOrdinaryMixValues(Map<MixValueTarget, double> values) {
    for (final entry in values.entries) {
      _onOrdinaryFxWrite(entry.key, entry.value);
    }
  }
}
