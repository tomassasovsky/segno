part of 'notices_cubit.dart';

/// A notice as it is on screen: the [notice] and the [serial] of the show,
/// which is new each time it is shown, so a repeat restarts its time.
class ShownNotice extends Equatable {
  /// Creates a [ShownNotice].
  const new({
    required this.notice,
    required this.serial,
    required this.age,
  });

  /// What it says.
  final Notice notice;

  /// Which show this is: higher is newer.
  final int serial;

  /// Running since it went up, so a bar built while it is up shows the time
  /// it has left rather than starting it again. A stopwatch, not two
  /// readings of the wall clock, which the console steps when it first
  /// reaches a time server.
  final Stopwatch age;

  /// The share of its [Notice.duration] still to go, from 1 to 0.
  double get left {
    final total = notice.duration.inMicroseconds;
    return (1 - age.elapsedMicroseconds / total).clamp(0.0, 1.0);
  }

  @override
  List<Object?> get props => [serial];
}

/// Everything the notice surfaces draw (#1562).
class NoticesState extends Equatable {
  /// Creates a [NoticesState].
  const new({
    this.message,
    this.banners = const [],
    this.tracks = const {},
    this.held = false,
  });

  /// The top bar's passing message, in place of the session name.
  final ShownNotice? message;

  /// The must-act messages that stand, oldest first.
  final List<ShownNotice> banners;

  /// Each track's passing message, by channel.
  final Map<int, ShownNotice> tracks;

  /// Whether the Power screen is up: nothing is shown while it is, and the
  /// must-act messages come back after it.
  final bool held;

  /// The must-act message the top bar shows: critical before warning before
  /// the rest, then the newest. Null while [held].
  ShownNotice? get banner {
    if (held || banners.isEmpty) return null;
    return banners.reduce(
      (best, next) => _outranks(next, best) ? next : best,
    );
  }

  /// [channel]'s passing message, null while [held].
  ShownNotice? trackMessage(int channel) => held ? null : tracks[channel];

  /// The passing message a top bar says: its own [message] or a track's,
  /// whichever is newer, with the track's channel when it is a track's.
  ///
  /// A track whose card is on the bar's screen ([onCard]) says its message
  /// on the card, so the bar leaves it out; with no [onCard] the screen has
  /// no track cards and the bar says every track's. Null while [held].
  ({int? channel, ShownNotice shown})? passing({
    bool Function(int channel)? onCard,
  }) {
    if (held) return null;
    ({int? channel, ShownNotice shown})? newest = switch (message) {
      final message? => (channel: null, shown: message),
      null => null,
    };
    for (final MapEntry(key: channel, value: shown) in tracks.entries) {
      if (onCard?.call(channel) ?? false) continue;
      if (newest == null || shown.serial > newest.shown.serial) {
        newest = (channel: channel, shown: shown);
      }
    }
    return newest;
  }

  /// Critical first, then warning, then every other tone alike; the newest
  /// within a rank.
  static (int, int) _rank(ShownNotice shown) => (
    switch (shown.notice.tone) {
      NoticeTone.critical => 2,
      NoticeTone.warning => 1,
      NoticeTone.neutral || NoticeTone.success => 0,
    },
    shown.serial,
  );

  static bool _outranks(ShownNotice a, ShownNotice b) {
    final (rankA, serialA) = _rank(a);
    final (rankB, serialB) = _rank(b);
    return rankA != rankB ? rankA > rankB : serialA > serialB;
  }

  NoticesState _copyWith({
    ShownNotice? Function()? message,
    List<ShownNotice>? banners,
    Map<int, ShownNotice>? tracks,
    bool? held,
  }) => NoticesState(
    message: message == null ? this.message : message(),
    banners: banners ?? this.banners,
    tracks: tracks ?? this.tracks,
    held: held ?? this.held,
  );

  @override
  List<Object?> get props => [message, banners, tracks, held];
}
