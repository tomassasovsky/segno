part of 'control_cubit.dart';

extension _FootLengthControl on ControlCubit {
  bool get _lengthEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.length &&
      !_fxPersistence.sessionTransitionActive;

  FootLengthProjection _lengthProjection() => _footLengthActions.project(
    bank: state.activeBank,
    cursor: state.cursor,
  );

  /// Every Multiply / Divide role fires on contact; there are no holds.
  void _onLengthPress(PedalButton button) {
    final role = FootLengthProjection.pedalRoles[button]!;
    if (role.press == FootLengthAction.exit) {
      _dispatchLengthAction(role.press, role.slot);
      return;
    }
    if (!_lengthEditable) return;
    if (_dispatchLengthAction(role.press, role.slot)) {
      _acceptedContacts.add(button);
    }
  }

  bool _dispatchLengthAction(FootLengthAction action, int? slot) {
    switch (action) {
      case FootLengthAction.exit:
        setMode(InteractionMode.record);
      case FootLengthAction.stop:
        return _parkAllAccepted();
      case FootLengthAction.nextBank:
        browseBank(1 - state.activeBank);
      case FootLengthAction.selectTrack:
        return _selectLengthChannel(state.activeBank * 4 + slot!);
      case FootLengthAction.doubleTrack:
      case FootLengthAction.firstHalf:
      case FootLengthAction.lastHalf:
        // An empty selected track has nothing to double or halve: its edit
        // pedals are dimmed and the stomp is silent.
        final channel = state.cursor;
        if (!_lengthProjection().tracks[channel].hasContent) return false;
        unawaited(
          _editLengthChannel(channel, FootLengthProjection.editOf(action)!),
        );
    }
    return true;
  }

  /// Selects a recorded track; an empty one is dimmed and silent.
  bool _selectLengthChannel(int channel) {
    if (channel < 0 || channel >= 8) return false;
    if (!_lengthProjection().tracks[channel].hasContent) return false;
    selectTrack(channel);
    return true;
  }

  /// Applies [edit] to the recorded [channel] from the surface. A press that
  /// changes nothing says why, unless the visit it belonged to ended first.
  Future<void> _editLengthChannel(int channel, LengthEdit edit) async {
    final visit = _surfaceVisit;
    final session = _looper.sessionRevision;
    final refusal = await _footLengthActions.edit(channel, edit);
    if (refusal == null || refusal == FootLengthRefusal.empty) return;
    if (!identical(visit, _surfaceVisit) ||
        state.mode != InteractionMode.length) {
      return;
    }
    _reportLengthRefusal(refusal, session);
  }

  /// Reports one refused Multiply / Divide with its reason, unless the
  /// Session it was fired in has since been replaced.
  void _reportLengthRefusal(FootLengthRefusal refusal, int session) {
    if (isClosed || _looper.sessionRevision != session) return;
    emit(
      state.copyWith(
        footLengthFailure: state.footLengthFailure + 1,
        footLengthRefusal: refusal,
      ),
    );
  }

  /// An assigned Multiply or Divide (Custom, CTRL, MIDI) on [channel]. A
  /// refusal always says why, in any mode and for an empty track too: the
  /// stomp came from a control away from the track, so silence would read
  /// as a dead pedal.
  Future<bool> _runAssignedLength(int channel, LengthEdit edit) {
    final session = _looper.sessionRevision;
    return _footLengthActions.edit(channel, edit).then((refusal) {
      if (refusal != null) _reportLengthRefusal(refusal, session);
      return refusal == null;
    });
  }
}

/// The length edit each assignable Multiply / Divide operation makes, or
/// null for every other operation.
LengthEdit? _lengthEditOf(TrackOperation operation) => switch (operation) {
  TrackOperation.multiply => LengthEdit.doubled,
  TrackOperation.divideFirstHalf => LengthEdit.firstHalf,
  TrackOperation.divideLastHalf => LengthEdit.lastHalf,
  _ => null,
};
