part of 'control_cubit.dart';

extension _FootMixerControl on ControlCubit {
  bool get _mixerEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.mixer &&
      !_fxPersistence.sessionTransitionActive;

  void _cancelMixerHolds() {
    for (final button in PedalButton.values) {
      _systemGesture(button)?.cancel();
    }
  }

  void _onMixerPress(PedalButton button) {
    final role = FootMixerProjection.pedalRoles[button]!;
    if (role.press == FootMixerAction.exit) {
      _dispatchMixerAction(role.press, role.slot);
      return;
    }
    if (!_mixerEditable) return;
    if (role.immediate) {
      if (_dispatchMixerAction(role.press, role.slot)) {
        _acceptedContacts.add(button);
      }
      return;
    }
    final session = _looper.sessionRevision;
    final generation = _looper.mixGeneration;
    final domain = state.footMixer.domain;
    void dispatch(FootMixerAction action) {
      if (_mixerEditable &&
          _looper.sessionRevision == session &&
          _looper.mixGeneration == generation &&
          state.footMixer.domain == domain) {
        _dispatchMixerAction(action, role.slot);
      }
    }

    _armGesture(
      _systemGesture(button) ??
          _trackHoldGestures.putIfAbsent(button, _HoldGesture.new),
      onTap: () => dispatch(role.press),
      onHold: () => dispatch(role.hold!),
    );
  }

  bool _dispatchMixerAction(FootMixerAction action, int? slot) {
    switch (action) {
      case FootMixerAction.exit:
        setMode(InteractionMode.record);
      case FootMixerAction.recordPlay:
        return _recAdvance(state.cursor);
      case FootMixerAction.stop:
        return _parkAllAccepted();
      case FootMixerAction.decrease:
        unawaited(stepFootMixerGain(-1));
      case FootMixerAction.increase:
        unawaited(stepFootMixerGain(1));
      case FootMixerAction.reset:
        unawaited(resetFootMixerGain());
      case FootMixerAction.nextPage:
        nextFootMixerPage();
      case FootMixerAction.switchDomain:
        selectFootMixerDomain(
          state.footMixer.domain == FootMixerDomain.tracks
              ? FootMixerDomain.inputs
              : FootMixerDomain.tracks,
        );
      case FootMixerAction.selectChannel:
        selectFootMixerSlot(slot!);
      case FootMixerAction.toggleMute:
        unawaited(toggleFootMixerMute(slot));
    }
    return true;
  }
}
