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

  FootSessionsProjection _sessionsProjection() {
    final from = (state.sessionCatalogue, state.footSessions);
    final cached = _sessionsProjected;
    if (cached != null && _sessionsProjectedFrom == from) return cached;
    _sessionsProjectedFrom = from;
    return _sessionsProjected = projectFootSessions(from.$1, from.$2);
  }

  /// The mode the face goes back to. Only the modes whose entry does
  /// nothing to the rig: coming back must not cancel an arm or end a take,
  /// as entering FX does.
  InteractionMode _sessionsReturnFor(InteractionMode from) => switch (from) {
    InteractionMode.record ||
    InteractionMode.mute ||
    InteractionMode.custom => from,
    _ => InteractionMode.record,
  };

  /// Entering the mode: on the folder and the page that hold the open
  /// session, with the catalogue asked for again, since the copy here is
  /// only as new as the last session action.
  void _enterSessions() {
    final catalogue = state.sessionCatalogue;
    final folder = footSessionsStartFolder(catalogue);
    final inFolder = projectFootSessions(
      catalogue,
      FootSessionsSelection(folder: folder),
    );
    emit(
      state.copyWith(
        footSessions: FootSessionsSelection(
          folder: folder,
          page: FootSessionsProjection.pageOf(
            inFolder.sessions,
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
        // No confirming flash: the session layer has not accepted the New
        // loop yet, and says so itself if it refuses.
        onHold: () {
          if (_sessionsEditable) _dispatchSessionsAction(pedal);
        },
      );
      return;
    }
    if (pedal.role == FootSessionsRole.nextPage &&
        _sessionsProjection().hasOtherFolders) {
      // With another folder to show, Bank has a Hold, so its page turn
      // waits for the release. With one folder it turns on contact.
      _armGesture(
        _systemGesture(button)!,
        cue: button,
        onTap: () {
          if (_sessionsEditable) _dispatchSessionsAction(pedal);
        },
        onHold: () {
          if (_sessionsEditable) _showNextSessionsFolder();
        },
      );
      return;
    }
    _dispatchSessionsAction(pedal);
  }

  /// The semantic activation of [button]: its press, or its Hold (Clear's
  /// New loop, Bank's next folder).
  void _activateSessionsPedal(PedalButton button, {required bool hold}) {
    if (state.mode != InteractionMode.sessions || isClosed) return;
    final pedal = _sessionsProjection()[button];
    if (pedal.role == FootSessionsRole.exit) {
      _leaveSessions();
      return;
    }
    if (!_sessionsEditable || !pedal.available) return;
    if (hold) {
      if (pedal.role == FootSessionsRole.newLoop) {
        _dispatchSessionsAction(pedal);
      } else if (pedal.role == FootSessionsRole.nextPage) {
        _showNextSessionsFolder();
      }
      return;
    }
    // Clear acts on its Hold only.
    if (pedal.role != FootSessionsRole.newLoop) _dispatchSessionsAction(pedal);
  }

  void _showNextSessionsFolder() {
    final projection = _sessionsProjection();
    if (!projection.hasOtherFolders) return;
    emit(
      state.copyWith(
        footSessions: state.footSessions.inFolder(projection.nextFolder),
      ),
    );
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
        if (projection.pageCount < 2) return;
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
    if (opened) {
      selection = selection.settled();
    } else if (opening != null &&
        catalogue.failureCount != selection.failuresAtOpen) {
      // The session's own notice says why; its card says which.
      selection = selection.settled(failed: opening);
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
