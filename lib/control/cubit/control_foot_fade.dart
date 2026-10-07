part of 'control_cubit.dart';

extension _FootFadeControl on ControlCubit {
  bool get _fadeEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.fade &&
      !_fxPersistence.sessionTransitionActive;

  void _onFadePress(PedalButton button) {
    final role = FootFadeProjection.pedalRoles[button]!;
    if (role.press == FootFadeAction.exit) {
      _dispatchFadeAction(role.press, role.slot);
      return;
    }
    if (!_fadeEditable) return;
    if (role.immediate) {
      if (_dispatchFadeAction(role.press, role.slot)) {
        _acceptedContacts.add(button);
      }
      return;
    }
    // A pending track hold follows a bank change until it fires: the slot
    // resolves against the bank current at activation, never at contact.
    // _armGesture already retires the gesture on a Session change.
    void dispatch(FootFadeAction action) {
      if (_fadeEditable) _dispatchFadeAction(action, role.slot);
    }

    _armGesture(
      _systemGesture(button) ??
          _trackHoldGestures.putIfAbsent(button, _HoldGesture.new),
      onTap: () => dispatch(role.press),
      onHold: () => dispatch(role.hold!),
    );
  }

  bool _dispatchFadeAction(FootFadeAction action, int? slot) {
    switch (action) {
      case FootFadeAction.exit:
        setMode(InteractionMode.record);
      case FootFadeAction.recordPlay:
        return _recAdvance(state.cursor);
      case FootFadeAction.stop:
        return _parkAllAccepted();
      case FootFadeAction.toggleTrack:
        unawaited(toggleFootFadeTrack(slot!));
      case FootFadeAction.selectTrackTime:
        selectFootFadeTrackTime(slot!);
      case FootFadeAction.shorten:
        unawaited(stepFootFadeTime(-1));
      case FootFadeAction.lengthen:
        unawaited(stepFootFadeTime(1));
      case FootFadeAction.resetTime:
        unawaited(resetFootFadeTime());
      case FootFadeAction.nextBank:
        browseBank(1 - state.activeBank);
      case FootFadeAction.selectDefault:
        selectFootFadeDefault();
    }
    return true;
  }

  /// Reports a refused gesture once, unless the flow it belonged to ended.
  void _reportFadeFailure(Object visit, int session) {
    if (isClosed ||
        !identical(visit, _surfaceVisit) ||
        state.mode != InteractionMode.fade ||
        _looper.sessionRevision != session) {
      return;
    }
    emit(
      state.copyWith(
        footFadeFailure: state.footFadeFailure + 1,
        footFadeRefusedEmpty: 0,
      ),
    );
  }
}
