part of 'notices_cubit.dart';

/// A notice as it is on screen: the [notice] and the [serial] of the show,
/// which is new each time it is shown, so a repeat restarts its time.
class ShownNotice extends Equatable {
  /// Creates a [ShownNotice].
  const ShownNotice({required this.notice, required this.serial});

  /// What it says.
  final Notice notice;

  /// Which show this is: higher is newer.
  final int serial;

  @override
  List<Object?> get props => [serial];
}

/// Everything the notice surfaces draw (#1562).
class NoticesState extends Equatable {
  /// Creates a [NoticesState].
  const NoticesState({
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
      (best, next) => _rank(next) > _rank(best) ? next : best,
    );
  }

  /// [channel]'s passing message, null while [held].
  ShownNotice? trackMessage(int channel) => held ? null : tracks[channel];

  /// The newest passing message a track caused, for surfaces that show no
  /// track cards; null while [held].
  ({int channel, ShownNotice shown})? get latestTrackMessage {
    if (held || tracks.isEmpty) return null;
    final newest = tracks.entries.reduce(
      (best, next) => next.value.serial > best.value.serial ? next : best,
    );
    return (channel: newest.key, shown: newest.value);
  }

  static int _rank(ShownNotice shown) =>
      shown.notice.tone.index * 1000000000 + shown.serial;

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
