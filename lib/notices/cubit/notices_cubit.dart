import 'dart:async';

import 'package:bloc/bloc.dart';
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
/// While the Power screen is up ([setHeld]) passing messages are dropped and
/// the must-act ones wait behind it.
class NoticesCubit extends Cubit<NoticesState> {
  /// Creates a [NoticesCubit] with nothing on screen. [stopwatch] times
  /// each message's age; a test passes one on its fake clock.
  NoticesCubit({Stopwatch Function()? stopwatch})
    : _stopwatch = stopwatch ?? Stopwatch.new,
      super(const NoticesState());

  final Stopwatch Function() _stopwatch;

  int _serial = 0;
  Timer? _messageTimer;
  final _trackTimers = <int, Timer>{};

  ShownNotice _shown(Notice notice) => ShownNotice(
    notice: notice,
    serial: ++_serial,
    age: _stopwatch()..start(),
  );

  /// Shows [notice] in the top bar for its [Notice.duration].
  ///
  /// The same id again restarts the time in place.
  void show(Notice notice) {
    assert(
      notice.tone != NoticeTone.critical,
      'A message that goes by itself is never critical; raise it instead.',
    );
    if (_dropped(notice)) return;
    final shown = _shown(notice);
    _messageTimer?.cancel();
    _messageTimer = Timer(notice.duration, () {
      if (state.message?.serial == shown.serial) {
        emit(state._copyWith(message: () => null));
      }
    });
    emit(state._copyWith(message: () => shown));
  }

  /// Shows [notice] on [channel]'s card for its [Notice.duration].
  void showOnTrack(int channel, Notice notice) {
    assert(
      notice.tone != NoticeTone.critical,
      'A message that goes by itself is never critical; raise it instead.',
    );
    if (_dropped(notice)) return;
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
  }

  /// Ends every notice with [id]: a must-act message whose condition is
  /// over, or a passing message that no longer applies.
  void clear(String id) {
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
  }

  /// Holds every notice while the Power screen is up, and lets the must-act
  /// messages back when it goes.
  void setHeld({required bool held}) {
    if (state.held == held) return;
    if (held) {
      _messageTimer?.cancel();
      for (final timer in _trackTimers.values) {
        timer.cancel();
      }
      _trackTimers.clear();
      emit(state._copyWith(message: () => null, tracks: const {}, held: true));
      return;
    }
    emit(state._copyWith(held: false));
  }

  bool _dropped(Notice notice) =>
      state.held ||
      state.banners.any((banner) => banner.notice.id == notice.id);

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
