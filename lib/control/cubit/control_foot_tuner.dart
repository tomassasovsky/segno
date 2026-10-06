part of 'control_cubit.dart';

/// The foot Tuner (#1229): Control arms the detector and mutes the tuned
/// input while the mode is up, and disarms on every way out.
extension _FootTunerControl on ControlCubit {
  bool get _tunerEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.tuner &&
      !_fxPersistence.sessionTransitionActive;

  FootTunerProjection _tunerProjection() =>
      _footTunerActions.project(state.footTuner, looper: _l);

  /// Entering the mode: muted, on the page that holds the source.
  void _enterTuner() {
    final projection = projectFootTuner(
      _l,
      const FootTunerSelection(),
      _tunerSettings.live,
    );
    emit(
      state.copyWith(
        footTuner: FootTunerSelection(
          page: FootTunerProjection.pageOf(
            projection.inputs,
            projection.source,
          ),
        ),
      ),
    );
    _tunerArmed = null;
    _syncTuner();
  }

  /// Leaving the mode (any [setMode], or close): the native disarm clears
  /// the mute with it.
  void _leaveTuner() {
    _footTunerActions.disarm();
    _tunerArmed = null;
  }

  /// Arms the detector on the current source and mute whenever either
  /// changed: a device or input-count change, a new input, a mute toggle.
  void _syncTuner() {
    if (state.mode != InteractionMode.tuner || isClosed) return;
    final projection = _tunerProjection();
    final key = (source: projection.source, muted: projection.mutedInputs);
    final armed = _tunerArmed;
    if (armed != null &&
        armed.source == key.source &&
        armed.muted.length == key.muted.length &&
        armed.muted.containsAll(key.muted)) {
      return;
    }
    final sourceMoved = armed == null || armed.source != key.source;
    final refusal = sourceMoved
        ? _footTunerActions.arm(projection)
        : _footTunerActions.applyMute(projection);
    if (refusal == null) {
      _tunerArmed = key;
      return;
    }
    // The input is reported as audible, because it is.
    _tunerArmed = (source: key.source, muted: const <int>{});
    if (state.footTuner.muted) {
      emit(state.copyWith(footTuner: state.footTuner.copyWith(muted: false)));
    }
    _reportTunerRefusal(refusal);
  }

  void _onTunerPress(PedalButton button) {
    final projection = _tunerProjection();
    final pedal = projection[button];
    if (pedal.role == FootTunerRole.exit) {
      setMode(InteractionMode.record);
      return;
    }
    if (!_tunerEditable || !pedal.available) return;
    switch (pedal.role) {
      case FootTunerRole.referenceDown || FootTunerRole.referenceUp:
        final delta = pedal.role == FootTunerRole.referenceUp ? 1 : -1;
        void act(void Function() run) {
          if (_tunerEditable) run();
        }

        _armGesture(
          _systemGesture(button) ??
              _trackHoldGestures.putIfAbsent(button, _HoldGesture.new),
          onTap: () => act(() => unawaited(_stepTunerReference(delta))),
          onHold: () => act(() => unawaited(_resetTunerReference())),
        );
      case FootTunerRole.input || FootTunerRole.mute || FootTunerRole.nextPage:
        if (_dispatchTunerAction(pedal)) _acceptedContacts.add(button);
      case FootTunerRole.exit || FootTunerRole.none:
        break;
    }
  }

  /// Runs one contact action; true when it was accepted.
  bool _dispatchTunerAction(FootTunerPedal pedal) {
    switch (pedal.role) {
      case FootTunerRole.input:
        unawaited(_selectTunerInput(pedal.input!));
      case FootTunerRole.mute:
        emit(
          state.copyWith(
            footTuner: _footTunerActions.toggleMute(state.footTuner),
          ),
        );
        _syncTuner();
      case FootTunerRole.nextPage:
        final step = _footTunerActions.nextPage(
          _tunerProjection(),
          state.footTuner,
        );
        emit(state.copyWith(footTuner: step.selection));
        if (step.input case final input?) unawaited(_selectTunerInput(input));
      case FootTunerRole.referenceDown ||
          FootTunerRole.referenceUp ||
          FootTunerRole.exit ||
          FootTunerRole.none:
        return false;
    }
    return true;
  }

  Future<void> _selectTunerInput(int input) async {
    final refusal = await _footTunerActions.select(input);
    if (refusal != null) _reportTunerRefusal(refusal);
  }

  Future<void> _stepTunerReference(int delta) async {
    final refusal = await _footTunerActions.stepReference(delta);
    if (refusal != null) _reportTunerRefusal(refusal);
  }

  Future<void> _resetTunerReference() async {
    final refusal = await _footTunerActions.resetReference();
    if (refusal != null) _reportTunerRefusal(refusal);
  }

  /// The stored preferences changed (here or elsewhere): mirror them for
  /// the face, and follow a new source.
  void _onTunerPreferences(TunerPreferences preferences) {
    if (isClosed) return;
    if (state.tunerPreferences != preferences) {
      emit(state.copyWith(tunerPreferences: preferences));
    }
    if (state.mode == InteractionMode.tuner) {
      // A new input keeps the page that shows it.
      final projection = _tunerProjection();
      final page = FootTunerProjection.pageOf(
        projection.inputs,
        projection.source,
      );
      if (page != state.footTuner.page) {
        emit(state.copyWith(footTuner: state.footTuner.copyWith(page: page)));
      }
      _syncTuner();
      _pushProjected();
    }
  }

  /// The switch lights the Tuner face draws, for the LED frame.
  Map<PedalButton, bool> _tunerStates() {
    if (state.mode != InteractionMode.tuner) return const {};
    final projection = _tunerProjection();
    return {
      for (final entry in projection.pedals.entries) entry.key: entry.value.lit,
    };
  }

  /// Reports one refused Tuner press with its reason.
  void _reportTunerRefusal(FootTunerRefusal refusal) {
    if (isClosed) return;
    emit(
      state.copyWith(
        footTunerFailure: state.footTunerFailure + 1,
        footTunerRefusal: refusal,
      ),
    );
  }
}
