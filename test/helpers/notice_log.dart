import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/notices.dart';

/// Every notice a [NoticesCubit] put on screen during a test, in order.
///
/// A passing message goes by itself, and a settle runs its time out, so a
/// test that settles after the press asks the log what was said rather than
/// the screen.
class NoticeLog {
  /// Starts recording [notices].
  ///
  /// What is up already counts as shown.
  NoticeLog(this.notices) {
    _record(notices.state);
    _subscription = notices.stream.listen(_record);
  }

  /// The notice centre being recorded.
  final NoticesCubit notices;

  final _serials = <int>{};

  /// Each notice shown, oldest first.
  final List<Notice> shown = [];

  /// The track each notice in [shown] was shown on, or null for the top
  /// bar.
  final List<int?> channels = [];

  late final StreamSubscription<NoticesState> _subscription;

  void _record(NoticesState state) {
    void add(ShownNotice shown, int? channel) {
      if (!_serials.add(shown.serial)) return;
      this.shown.add(shown.notice);
      channels.add(channel);
    }

    if (state.message case final message?) add(message, null);
    for (final banner in state.banners) {
      add(banner, null);
    }
    for (final MapEntry(key: channel, value: shown) in state.tracks.entries) {
      add(shown, channel);
    }
  }

  /// The tracks a notice with [id] was shown on.
  List<int> tracksOf(String id) => [
    for (var i = 0; i < shown.length; i++)
      if (shown[i].id == id && channels[i] != null) channels[i]!,
  ];

  /// Whether a notice with [id] was shown.
  bool said(String id) => shown.any((notice) => notice.id == id);

  /// The titles shown, in English.
  List<String> get titles {
    final l10n = lookupAppLocalizations(const Locale('en'));
    return [for (final notice in shown) notice.title(l10n)];
  }

  /// Stops recording.
  Future<void> close() => _subscription.cancel();
}
