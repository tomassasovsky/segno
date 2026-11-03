import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clock/clock.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/notices/model/notice.dart';

part 'notices_state.dart';

/// The app's one notice centre (#1562): every message the console shows goes
/// through here, so one rule set decides what is on screen.
///
/// - [show]: a whole-rig message that goes by itself. The top bar's centre
///   says it in place of the session name. One at a time: the newest
///   replaces the last.
/// - [showOnTrack]: a message one track caused, on that track's card. One
///   per track, the newest replacing the last.
/// - [raise]: a must-act message. The whole top bar becomes it until
///   [clear] says the condition is over.
///
/// One cause, one notice (#860): a passing message whose id has a standing
/// must-act message is dropped, and raising one ends the passing message with
/// its id. Nothing needs a touch to go away.
///
/// While the Power screen is up ([setHeld]) passing messages are dropped,
/// and the must-act ones and the one-time explanations wait behind it.
class NoticesCubit extends Cubit<NoticesState> {
  /// Creates a [NoticesCubit] with nothing on screen.
  NoticesCubit() : super(const NoticesState());

  int _serial = 0;
  Timer? _messageTimer;

  /// One-time explanations waiting for the one on screen to go by.
  final _waiting = <Notice>[];
  final _trackTimers = <int, Timer>{};

  ShownNotice _shown(Notice notice) =>
      ShownNotice(notice: notice, serial: ++_serial, shownAt: clock.now());

  /// Shows [notice] in the top bar for its [Notice.duration].
  ///
  /// The same id again restarts the time in place. Anything else replaces
  /// whatever is up, except a one-time explanation ([Notice.explains]): each
  /// is said once in the console's life, so none is ever lost. One that
  /// arrives while another is up, or while the Power screen holds the
  /// notices, waits its turn; one that another message replaces is said
  /// again, whole, after it.
  void show(Notice notice) {
    assert(
      notice.tone != NoticeTone.critical,
      'A message that goes by itself is never critical; raise it instead.',
    );
    if (_standing(notice.id)) return;
    if (state.held) {
      if (notice.explains) _wait(notice);
      return;
    }
    final current = state.message?.notice;
    if (current != null && current.explains && current.id != notice.id) {
      if (notice.explains) {
        _wait(notice);
        return;
      }
      _wait(current, first: true);
    }
    _present(notice);
  }

  void _wait(Notice notice, {bool first = false}) {
    _waiting.removeWhere((waiting) => waiting.id == notice.id);
    if (first) {
      _waiting.insert(0, notice);
    } else {
      _waiting.add(notice);
    }
  }

  void _present(Notice notice) {
    final shown = _shown(notice);
    _messageTimer?.cancel();
    _messageTimer = Timer(notice.duration, () {
      if (state.message?.serial != shown.serial) return;
      emit(state._copyWith(message: () => null));
      _presentWaiting();
    });
    emit(state._copyWith(message: () => shown));
  }

  /// Puts the next waiting explanation up once the bar is free.
  void _presentWaiting() {
    if (state.held || state.message != null || _waiting.isEmpty) return;
    _present(_waiting.removeAt(0));
  }

  /// Shows [notice] on [channel]'s card for its [Notice.duration].
  void showOnTrack(int channel, Notice notice) {
    assert(
      notice.tone != NoticeTone.critical,
      'A message that goes by itself is never critical; raise it instead.',
    );
    if (state.held || _standing(notice.id)) return;
    final shown = _shown(notice);
    _trackTimers[channel]?.cancel();
    _trackTimers[channel] = Timer(notice.duration, () {
      if (state.tracks[channel]?.serial != shown.serial) return;
      _trackTimers.remove(channel);
      emit(state._copyWith(tracks: Map.of(state.tracks)..remove(channel)));
    });
    emit(state._copyWith(tracks: {...state.tracks, channel: shown}));
  }

  /// Makes [notice] a must-act message until [clear] is called with its id.
  ///
  /// Raising an id that stands replaces it and makes it the newest.
  void raise(Notice notice) {
    final shown = _shown(notice);
    _waiting.removeWhere((waiting) => waiting.id == notice.id);
    final message = state.message?.notice.id == notice.id
        ? null
        : state.message;
    if (message == null) _messageTimer?.cancel();
    emit(
      state._copyWith(
        message: () => message,
        banners: [
          for (final banner in state.banners)
            if (banner.notice.id != notice.id) banner,
          shown,
        ],
        tracks: _tracksWithout(notice.id),
      ),
    );
    _presentWaiting();
  }

  /// Ends every notice with [id]: a must-act message whose condition is
  /// over, or a passing message that no longer applies.
  void clear(String id) {
    _waiting.removeWhere((waiting) => waiting.id == id);
    final message = state.message?.notice.id == id ? null : state.message;
    if (message == null) _messageTimer?.cancel();
    final banners = [
      for (final banner in state.banners)
        if (banner.notice.id != id) banner,
    ];
    final tracks = _tracksWithout(id);
    if (message == state.message &&
        banners.length == state.banners.length &&
        tracks.length == state.tracks.length) {
      return;
    }
    emit(
      state._copyWith(message: () => message, banners: banners, tracks: tracks),
    );
    _presentWaiting();
  }

  /// Holds every notice while the Power screen is up, and lets the must-act
  /// messages back when it goes.
  void setHeld({required bool held}) {
    if (state.held == held) return;
    if (held) {
      // An explanation cut short is said again, whole, after the hold.
      final current = state.message?.notice;
      if (current != null && current.explains) _wait(current, first: true);
      _messageTimer?.cancel();
      for (final timer in _trackTimers.values) {
        timer.cancel();
      }
      _trackTimers.clear();
      emit(state._copyWith(message: () => null, tracks: const {}, held: true));
      return;
    }
    emit(state._copyWith(held: false));
    _presentWaiting();
  }

  bool _standing(String id) =>
      state.banners.any((banner) => banner.notice.id == id);

  Map<int, ShownNotice> _tracksWithout(String id) {
    final kept = <int, ShownNotice>{};
    for (final entry in state.tracks.entries) {
      if (entry.value.notice.id == id) {
        _trackTimers.remove(entry.key)?.cancel();
      } else {
        kept[entry.key] = entry.value;
      }
    }
    return kept;
  }

  @override
  Future<void> close() {
    _messageTimer?.cancel();
    for (final timer in _trackTimers.values) {
      timer.cancel();
    }
    return super.close();
  }
}
