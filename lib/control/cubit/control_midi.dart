part of 'control_cubit.dart';

/// MIDI configuration, capture and admission use the same control owner.
extension MidiControlEditing on ControlCubit {
  /// Waits for in-flight confirmed configuration before an orderly halt.
  Future<void> flushMidiConfiguration() async {
    await _midiWrites;
    await _externalTail;
    await _fxPersistence.flush();
    await _mixSettings.flush();
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
    if (_closing || isClosed || message.session != _midiDevices?.session) {
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
    unawaited(
      _queueMidi(() async {
        if (revision != _midiIngressRevision ||
            session != _looper.sessionRevision ||
            message.session != _midiDevices?.session ||
            !_midiCanDispatch(device)) {
          return;
        }
        for (final event in readings) {
          await _applyMidiProposals(_midiEngine.prepare(event));
        }
      }),
    );
  }

  bool _midiCanDispatch(String device) =>
      !_closing &&
      !isClosed &&
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
    if (value != null) return _looper.readValueTarget(value);
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
    if (target is FxParamTarget) {
      final divisions = _midiParamDivisions(target);
      if (divisions != null && divisions > 0) return 1 / divisions;
    }
    return 0.01;
  }

  Future<void> _applyMidiProposals(List<MidiProposal> proposals) async {
    final session = _looper.sessionRevision;
    for (final proposal in proposals) {
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
              final target = ending
                  ? _midiTargets[row]
                  : ControlValueTarget.tryParse(op.key) ??
                        FxBindingTarget.tryParse(op.key);
              final holder = _midiHolderKeys[row];
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
                if (!_looper.valueTargetResolves(target)) {
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
                  (_parameterHolders[target] ??= {})[holder] = (
                    value: values[target]!,
                    order: ++_activationOrder,
                  );
              }
            }
          }
          _syncMidiDurableFx();
        }

        bool cancelled() => session != _looper.sessionRevision || isClosed;
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
        for (final entry in rows.entries) {
          if (accepted.contains(entry.key) || entry.value.value == null) {
            continue;
          }
          final target = entry.value.target;
          final value = values[target];
          if (value == null) continue;
          switch (target) {
            case TrackVolumeTarget(:final channel):
              final op = proposal.operations.firstWhere(
                (op) => op.controlIndex == entry.key,
              );
              final rowKey = (
                proposal.mappingId,
                proposal.generation,
                entry.key,
              );
              final released = op is MidiParameterWrite && op.held == true
                  ? _midiReleasedFor(proposal, op.controlIndex)
                  : _survivingMidiReleased(
                      target,
                      excluding: _midiHolderKeys[rowKey],
                    );
              final result = await _mixSettings.setMidiTrackVolume(
                value,
                channel: channel,
                releasedValue: released,
              );
              if (cancelled()) return;
              if (result.isOk) accepted.add(entry.key);
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
          looper: _looper,
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

  void _onOrdinaryTrackLevel(int channel, double value) =>
      _onOrdinaryFxWrite(TrackVolumeTarget(channel), value);
}
