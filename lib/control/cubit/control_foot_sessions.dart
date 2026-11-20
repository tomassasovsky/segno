part of 'control_cubit.dart';

/// The Sessions face (#1910): the track switches open the sessions drawn
/// above them. Control owns the page and the pending Open; the session
/// layer owns the sessions and is reached through the injected functions.
extension _FootSessionsControl on ControlCubit {
  bool get _sessionsEditable =>
      !isClosed &&
      !_inputRetired &&
      !_takeLocked() &&
      state.mode == InteractionMode.sessions;

  FootSessionsProjection _sessionsProjection() =>
      projectFootSessions(state.sessionCatalogue, state.footSessions);

  /// The mode the face goes back to. Only the modes whose entry does
  /// nothing to the rig: coming back must not cancel an arm or end a take,
  /// as entering FX does.
  InteractionMode _sessionsReturnFor(InteractionMode from) => switch (from) {
    InteractionMode.record ||
    InteractionMode.mute ||
    InteractionMode.custom => from,
    _ => InteractionMode.record,
  };

  /// Entering the mode: on the page that holds the open session, with the
  /// catalogue asked for again, since the copy here is only as new as the
  /// last session action.
  void _enterSessions() {
    final catalogue = state.sessionCatalogue;
    emit(
      state.copyWith(
        footSessions: FootSessionsSelection(
          page: FootSessionsProjection.pageOf(
            orderedSessions(catalogue.sessions),
            catalogue.openId,
          ),
        ),
      ),
    );
    _refreshSessions();
  }

  void _leaveSessions() => setMode(_sessionsReturn);

  void _onSessionsPress(PedalButton button) {
    final pedal = _sessionsProjection()[button];
    if (pedal.role == FootSessionsRole.exit) {
      _leaveSessions();
      return;
    }
    if (!_sessionsEditable || !pedal.available) return;
    if (pedal.role == FootSessionsRole.newLoop) {
      // New loop is a Hold: Clear sits beside Bank, and a press that slips
      // must not start one. The fill is the one every clearing Hold draws.
      _armGesture(
        _systemGesture(button) ??
            _trackHoldGestures.putIfAbsent(button, _HoldGesture.new),
        cue: button,
        clears: () => _sessionsEditable,
        onHold: () {
          if (!_sessionsEditable) return;
          _meetClearFill(button);
          _dispatchSessionsAction(pedal);
        },
      );
      return;
    }
    _dispatchSessionsAction(pedal);
  }

  /// The semantic activation of [button]: its press, or Clear's Hold.
  void _activateSessionsPedal(PedalButton button, {required bool hold}) {
    if (state.mode != InteractionMode.sessions || isClosed) return;
    final pedal = _sessionsProjection()[button];
    if (pedal.role == FootSessionsRole.exit) {
      _leaveSessions();
      return;
    }
    if (!_sessionsEditable || !pedal.available) return;
    // Clear acts on its Hold only; nothing else has one.
    if ((pedal.role == FootSessionsRole.newLoop) != hold) return;
    _dispatchSessionsAction(pedal);
  }

  void _dispatchSessionsAction(FootSessionsPedal pedal) {
    switch (pedal.role) {
      case FootSessionsRole.open:
        final session = pedal.session;
        if (session == null) return;
        // The open session has nothing to open: the press is the way back.
        if (session.id == state.sessionCatalogue.openId) {
          _leaveSessions();
          return;
        }
        emit(
          state.copyWith(
            footSessions: state.footSessions.opening(
              session.id,
              state.sessionCatalogue.failureCount,
            ),
          ),
        );
        _openSession(session.id);
      case FootSessionsRole.save:
        _saveSession();
        _leaveSessions();
      case FootSessionsRole.newLoop:
        _startNewLoop();
        _leaveSessions();
      case FootSessionsRole.nextPage:
        final projection = _sessionsProjection();
        emit(
          state.copyWith(
            footSessions: state.footSessions.onPage(
              (projection.page + 1) % projection.pageCount,
            ),
          ),
        );
      case FootSessionsRole.recordPlay:
        _recAdvance(state.cursor);
      case FootSessionsRole.stop:
        _parkAllAccepted();
      case FootSessionsRole.exit:
        _leaveSessions();
    }
  }

  /// Takes the catalogue the app hands over, and settles an Open asked from
  /// the face: its session being the open one closes the face, and a failed
  /// session action since it was asked gives the switches back.
  void _onSessionCatalogue(FootSessionCatalogue catalogue) {
    if (isClosed || catalogue == state.sessionCatalogue) return;
    var selection = state.footSessions;
    final opening = selection.openingId;
    final opened = opening != null && catalogue.openId == opening;
    if (opening != null &&
        (opened || catalogue.failureCount != selection.failuresAtOpen)) {
      selection = selection.settled();
    }
    emit(state.copyWith(sessionCatalogue: catalogue, footSessions: selection));
    if (state.mode != InteractionMode.sessions) return;
    if (opened) {
      _leaveSessions();
    } else {
      _pushProjected();
    }
  }

  /// The switch lights the Sessions face draws, for the LED frame.
  Map<PedalButton, bool> _sessionsStates() {
    if (state.mode != InteractionMode.sessions) return const {};
    final projection = _sessionsProjection();
    return {
      for (final entry in projection.pedals.entries) entry.key: entry.value.lit,
    };
  }
}
