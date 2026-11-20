part of 'control_cubit.dart';

/// The Sessions face (#1910): a press on a track switch shows its session
/// in the readout and a Hold opens it (#1921). Control owns the page, the
/// session shown and the pending Open; the session layer owns the sessions
/// and is reached through the injected functions.
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
    if (pedal.role == FootSessionsRole.open) {
      final session = pedal.session;
      if (session == null) return;
      // Nothing to open: the press shows the session, and there is no
      // Hold to arm.
      if (!pedal.opens) {
        _previewSession(session.id);
        return;
      }
      // One hold to open at a time. A second switch going down while one
      // is pending is a foot across two switches: neither opens, and the
      // second does not take the readout.
      final pending = _openFill;
      if (pending != null && pending.button != button) {
        _trackHoldGestures[pending.button]?.cancel();
        return;
      }
      final gesture = _trackHoldGestures.putIfAbsent(button, _HoldGesture.new);
      if (gesture._active) return;
      // The session is asked for again when the hold fires: the catalogue
      // can change while the switch is down (entering the face asks for a
      // fresh one), and the switch must still stand for this session.
      FootSessionsPedal? stillThere() {
        if (!_sessionsEditable) return null;
        final now = _sessionsProjection()[button];
        return now.session?.id == session.id ? now : null;
      }

      // The readout shows the session from the moment the switch goes
      // down, so a hold fills under the name of what it is about to open.
      _previewSession(session.id);
      _armGesture(
        gesture,
        cue: button,
        onSettled: () => _endOpenFill(button),
        onHold: () {
          if (stillThere()?.opens ?? false) _openSessionFromFace(session.id);
        },
      );
      if (gesture._active) {
        _startOpenFill(button, () => stillThere()?.opens ?? false);
      }
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
  /// New loop, Bank's next folder, a track switch's Open).
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
      } else if (pedal.role == FootSessionsRole.open && pedal.opens) {
        _openSessionFromFace(pedal.session!.id);
      }
      return;
    }
    // Clear acts on its Hold only.
    if (pedal.role != FootSessionsRole.newLoop) _dispatchSessionsAction(pedal);
  }

  /// Shows [id]'s preview. Opens nothing.
  void _previewSession(String id) {
    if (state.footSessions.previewId == id) return;
    emit(state.copyWith(footSessions: state.footSessions.previewing(id)));
  }

  /// Asks the session layer to open [id] and waits for the catalogue to
  /// say how it went ([_onSessionCatalogue]).
  void _openSessionFromFace(String id) {
    emit(
      state.copyWith(
        footSessions: state.footSessions.opening(
          id,
          state.sessionCatalogue.failureCount,
        ),
      ),
    );
    _openSession(id);
  }

  /// Starts the left-to-right fill of [button]'s LEDs for its pending Hold
  /// to open (#1921): a frame now and one per [_openFillInterval], each
  /// carrying how far the hold has run, until the gesture settles.
  /// [stillOpens] is asked on every step.
  void _startOpenFill(PedalButton button, bool Function() stillOpens) {
    _openFill = _OpenFill(button: button, fillTime: _longPress);
    _openFillTicker?.cancel();
    _openFillTicker = Timer.periodic(ControlCubit._openFillInterval, (_) {
      // A hold that can no longer open its session (takes locked, the page
      // turned, the session gone) ends here, and its fill with it.
      if (!stillOpens()) {
        _trackHoldGestures[button]?.cancel();
        _endOpenFill(button);
        return;
      }
      _pushProjected();
    });
    _pushProjected();
  }

  /// Ends [button]'s fill: its hold fired, was released or was cancelled.
  void _endOpenFill(PedalButton button) {
    if (_openFill?.button != button) return;
    _openFill = null;
    _openFillTicker?.cancel();
    _openFillTicker = null;
    if (!_closing && !isClosed) _pushProjected();
  }

  /// The held track switches that stand for a session. They read in the
  /// colour of the open session's switch while they are down: it is the
  /// colour a hold fills in, and the one the switch keeps when the hold has
  /// fired, so nothing changes colour between the fill and the Open.
  Set<PedalButton> _sessionsHeld() {
    if (state.mode != InteractionMode.sessions) return const {};
    return {
      for (final pedal in _sessionsProjection().pedals.values)
        if (pedal.role == FootSessionsRole.open &&
            pedal.session != null &&
            _pressedButtons.containsKey(pedal.button))
          pedal.button,
    };
  }

  /// The pending hold to open the frame draws as a fill: its switch and how
  /// far it has run. Only while the switch is down: a release ends the fill
  /// with it.
  ({PedalButton button, int progress})? _sessionsOpenFill() {
    if (state.mode != InteractionMode.sessions) return null;
    final fill = _openFill;
    if (fill == null || !_pressedButtons.containsKey(fill.button)) return null;
    return (
      button: fill.button,
      progress: clearHoldProgress(
        fill.clock.elapsed,
        fill.fillTime,
      ).clamp(0, 254),
    );
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
        // A press shows the session. The Open is the switch's Hold.
        final session = pedal.session;
        if (session != null) _previewSession(session.id);
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
