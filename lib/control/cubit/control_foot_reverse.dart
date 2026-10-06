part of 'control_cubit.dart';

extension _FootReverseControl on ControlCubit {
  bool get _reverseEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.reverse &&
      !_fxPersistence.sessionTransitionActive;

  /// Every Reverse role fires on contact; there are no holds to arm.
  void _onReversePress(PedalButton button) {
    final role = FootReverseProjection.pedalRoles[button]!;
    if (role.press == FootReverseAction.exit) {
      _dispatchReverseAction(role.press, role.slot);
      return;
    }
    if (!_reverseEditable) return;
    if (_dispatchReverseAction(role.press, role.slot)) {
      _acceptedContacts.add(button);
    }
  }

  bool _dispatchReverseAction(FootReverseAction action, int? slot) {
    switch (action) {
      case FootReverseAction.exit:
        setMode(InteractionMode.record);
      case FootReverseAction.recordPlay:
        // A reversed cursor track refuses the overdub; the repository
        // reports it with the record-refusal notice, as in every mode.
        return _recAdvance(state.cursor);
      case FootReverseAction.stop:
        return _parkAllAccepted();
      case FootReverseAction.toggleTrack:
        unawaited(toggleFootReverseTrack(slot!));
      case FootReverseAction.nextBank:
        browseBank(1 - state.activeBank);
      case FootReverseAction.none:
        return false;
    }
    return true;
  }

  /// Reports a refusal once, unless the visit it belonged to ended.
  void _reportReverseFailure(Object visit, int session) {
    if (isClosed ||
        !identical(visit, _surfaceVisit) ||
        state.mode != InteractionMode.reverse ||
        _looper.sessionRevision != session) {
      return;
    }
    emit(state.copyWith(footReverseFailure: state.footReverseFailure + 1));
  }
}
