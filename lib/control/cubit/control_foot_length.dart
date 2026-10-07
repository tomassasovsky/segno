part of 'control_cubit.dart';

extension _FootLengthControl on ControlCubit {
  bool get _lengthEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode.isLength &&
      !_fxPersistence.sessionTransitionActive;

  FootLengthProjection _lengthProjection() => _footLengthActions.project(
    bank: state.activeBank,
    cursor: state.cursor,
  );

  /// The role [button] plays on the current length surface.
  FootLengthPedal _lengthRole(PedalButton button) =>
      FootLengthProjection.rolesFor(state.mode)[button]!;

  /// Multiply / Divide pedals (pen 16). Every role fires on contact except
  /// Divide's First half, which fires on a release before the hold threshold
  /// and gives way to Undo on a hold. Undo in Multiply is the Tracks Undo
  /// gesture itself (tap Undo, hold Redo).
  void _onLengthPress(PedalButton button) {
    final role = _lengthRole(button);
    if (role.press == FootLengthAction.exit) {
      _dispatchLengthAction(role.press, role.slot);
      return;
    }
    if (!_lengthEditable) return;
    if (role.press == FootLengthAction.undo) {
      _armUndo();
      _acceptedContacts.add(button);
      return;
    }
    final hold = role.hold;
    if (hold != null) {
      // The selected track is latched at contact, as the Tracks Undo does,
      // so a selection made during the hold cannot redirect it.
      final channel = state.cursor;
      _armGesture(
        _systemGesture(button)!,
        cue: button,
        onTap: () {
          if (_lengthEditable) _editSelectedLength(role.press, channel);
        },
        onHold: () {
          if (_lengthEditable) _undoLength(channel);
        },
      );
      _acceptedContacts.add(button);
      return;
    }
    if (_dispatchLengthAction(role.press, role.slot)) {
      _acceptedContacts.add(button);
    }
  }

  bool _dispatchLengthAction(FootLengthAction action, int? slot) {
    switch (action) {
      case FootLengthAction.exit:
        setMode(InteractionMode.record);
      case FootLengthAction.recordPlay:
        return _recAdvance(state.cursor);
      case FootLengthAction.undo:
        _undoLength(state.cursor);
      case FootLengthAction.redo:
        _log('redo ch=${state.cursor}  (length surface)');
        redo(state.cursor);
      case FootLengthAction.stop:
        return _parkAllAccepted();
      case FootLengthAction.nextBank:
        browseBank(1 - state.activeBank);
      case FootLengthAction.selectTrack:
        return _selectLengthChannel(state.activeBank * 4 + slot!);
      case FootLengthAction.doubleTrack:
      case FootLengthAction.firstHalf:
      case FootLengthAction.lastHalf:
        return _editSelectedLength(action, state.cursor);
    }
    return true;
  }

  /// Undoes [channel]'s latest change, as the Tracks Undo tap does.
  void _undoLength(int channel) {
    _log('undo ch=$channel  (length surface)');
    undo(channel);
  }

  /// Applies the edit [action] makes to the selected [channel]. An empty
  /// track has nothing to double or halve: its edit pedals read "Select a
  /// track" and the stomp is silent.
  bool _editSelectedLength(FootLengthAction action, int channel) {
    final track = _lengthProjection().tracks[channel];
    if (!track.hasContent) return false;
    unawaited(
      _editLengthChannel(channel, FootLengthProjection.editOf(action)!, track),
    );
    return true;
  }

  /// Selects a recorded track; an empty one is dimmed and silent.
  bool _selectLengthChannel(int channel) {
    if (channel < 0 || channel >= 8) return false;
    if (!_lengthProjection().tracks[channel].hasContent) return false;
    selectTrack(channel);
    return true;
  }

  /// Applies [edit] to the recorded [channel], read as [before] at the
  /// press, from the surface. An accepted edit becomes the length panel's
  /// outcome; a press that changes nothing says why, unless the visit it
  /// belonged to ended first.
  Future<void> _editLengthChannel(
    int channel,
    LengthEdit edit,
    FootLengthTrack before,
  ) async {
    final visit = _surfaceVisit;
    final session = _looper.sessionRevision;
    final refusal = await _footLengthActions.edit(channel, edit);
    if (refusal == FootLengthRefusal.empty) return;
    if (isClosed || !identical(visit, _surfaceVisit) || !state.mode.isLength) {
      return;
    }
    if (refusal == null) {
      emit(
        state.copyWith(
          footLengthOutcome: FootLengthOutcome(
            channel: channel,
            edit: edit,
            fromFrames: before.lengthFrames,
            fromUndoDepth: before.undoDepth,
          ).bindTo(_lengthProjection().tracks[channel]),
        ),
      );
      return;
    }
    _reportLengthRefusal(refusal, session);
  }

  /// Binds the pending outcome's result once [looper] publishes it: the
  /// track's length and undo depth have both moved off their values before
  /// the edit (in either order of publication).
  void _bindLengthOutcome(LooperState looper) {
    final outcome = state.footLengthOutcome;
    if (outcome.bound || outcome.channel < 0 || isClosed) return;
    final bound = outcome.bindTo(readFootLengthTrack(looper, outcome.channel));
    if (bound.bound) emit(state.copyWith(footLengthOutcome: bound));
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
