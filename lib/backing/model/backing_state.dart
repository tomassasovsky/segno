import 'package:backing_repository/backing_repository.dart';
import 'package:equatable/equatable.dart';

/// One prepared file as the player lists it: its content identity and its
/// display name (plan D9: a missing item can still be named).
class BackingItem extends Equatable {
  /// Creates a [BackingItem].
  const BackingItem({required this.digest, required this.name});

  /// The asset's `sha256:<64 hex>`.
  final String digest;

  /// The file's display name.
  final String name;

  @override
  List<Object?> get props => [digest, name];
}

/// The backing player as the app presents it (#1200 Part 5): the prepared
/// order, the one selection shared by every surface, which item is loaded,
/// which prepared items have no file, and the voice itself.
class BackingState extends Equatable {
  /// Creates a [BackingState].
  const BackingState({
    this.prepared = const [],
    this.selected,
    this.loaded,
    this.missing = const {},
    this.player = const BackingPlayerState(),
    this.failure,
    this.failureCount = 0,
    this.notice,
    this.noticeCount = 0,
  });

  /// The prepared order.
  final List<BackingItem> prepared;

  /// The selected item's digest, or null.
  final String? selected;

  /// The loaded item, or null. It need not be prepared: Remove keeps the
  /// playing file.
  final BackingItem? loaded;

  /// Digests of prepared items whose file is missing or unusable: the
  /// `Missing` rows, which cannot be loaded and say so.
  final Set<String> missing;

  /// The voice, as the repository reports it.
  final BackingPlayerState player;

  /// The latest refusal to explain ("Couldn't play `name`: `reason`").
  final BackingFailure? failure;

  /// Bumps with every [failure], so the same refusal twice is told twice.
  final int failureCount;

  /// The latest notice (the interface changed while playing).
  final BackingNotice? notice;

  /// Bumps with every [notice].
  final int noticeCount;

  /// The selected item, or null.
  BackingItem? get selectedItem {
    for (final item in prepared) {
      if (item.digest == selected) return item;
    }
    return null;
  }

  /// Whether the selection is the loaded file.
  bool get selectionIsLoaded => selected != null && selected == loaded?.digest;

  /// The name of the file a load is decoding: `Loading <name>…`.
  String? get loadingName {
    final digest = player.loading;
    if (digest == null) return null;
    for (final item in [?loaded, ...prepared]) {
      if (item.digest == digest) return item.name;
    }
    return '';
  }

  /// A copy with the given fields replaced; `clear*` sets a nullable one to
  /// null.
  BackingState copyWith({
    List<BackingItem>? prepared,
    String? selected,
    bool clearSelected = false,
    BackingItem? loaded,
    bool clearLoaded = false,
    Set<String>? missing,
    BackingPlayerState? player,
    BackingFailure? failure,
    int? failureCount,
    BackingNotice? notice,
    int? noticeCount,
  }) => BackingState(
    prepared: prepared ?? this.prepared,
    selected: clearSelected ? null : selected ?? this.selected,
    loaded: clearLoaded ? null : loaded ?? this.loaded,
    missing: missing ?? this.missing,
    player: player ?? this.player,
    failure: failure ?? this.failure,
    failureCount: failureCount ?? this.failureCount,
    notice: notice ?? this.notice,
    noticeCount: noticeCount ?? this.noticeCount,
  );

  @override
  List<Object?> get props => [
    prepared,
    selected,
    loaded,
    missing,
    player,
    failure,
    failureCount,
    notice,
    noticeCount,
  ];
}
