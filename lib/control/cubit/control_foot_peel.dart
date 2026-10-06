part of 'control_cubit.dart';

extension _FootPeelControl on ControlCubit {
  bool get _peelEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.peel &&
      !_fxPersistence.sessionTransitionActive;

  /// Every Peel role fires on contact; there are no holds to arm.
  void _onPeelPress(PedalButton button) {
    final role = FootPeelProjection.pedalRoles[button]!;
    if (role.press == FootPeelAction.exit) {
      _dispatchPeelAction(role.press, role.slot);
      return;
    }
    if (!_peelEditable) return;
    if (_dispatchPeelAction(role.press, role.slot)) {
      _acceptedContacts.add(button);
    }
  }

  bool _dispatchPeelAction(FootPeelAction action, int? slot) {
    switch (action) {
      case FootPeelAction.exit:
        setMode(InteractionMode.record);
      case FootPeelAction.recordPlay:
        return _recAdvance(state.cursor);
      case FootPeelAction.stop:
        return _parkAllAccepted();
      case FootPeelAction.peelTrack:
        peelFootPeelTrack(slot!);
      case FootPeelAction.nextBank:
        browseBank(1 - state.activeBank);
      case FootPeelAction.none:
        return false;
    }
    return true;
  }

  /// Reports one refused Peel press with its reason. Peel completes on the
  /// control thread, so the report belongs to the press that caused it.
  void _reportPeelRefusal(FootPeelRefusal refusal) {
    if (isClosed) return;
    emit(
      state.copyWith(
        footPeelFailure: state.footPeelFailure + 1,
        footPeelRefusal: refusal,
      ),
    );
  }
}
