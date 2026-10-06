import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/backing/model/backing_state.dart';
import 'package:segno/looper/application/backing_settings.dart';
import 'package:session_repository/session_repository.dart';

/// What `Use as backing` did.
enum UseAsBackingOutcome {
  /// The file is prepared, selected and loaded, stopped.
  loaded,

  /// Another file is playing: nothing changed until the performer confirms.
  needsConfirm,

  /// The load was refused; the reason is in [BackingState.failure].
  refused,
}

/// The backing player's one owner (#1200 Part 5, plan D4 and D9): the
/// prepared order, the one selection every surface shares, the Play rules,
/// the automatic Next staging, and the Session's share of the backing.
///
/// The repository drives the voice and knows nothing about the order; this
/// owner decides which file is loaded and which one is staged after it.
class BackingPlayer {
  /// Creates the owner over [repository] (and its store) and the backing
  /// mix owner in [settings], whose End decides the staging.
  BackingPlayer({
    required BackingRepository repository,
    required BackingSettings settings,
  }) : _repository = repository,
       _settings = settings;

  final BackingRepository _repository;
  final BackingSettings _settings;
  final _states = StreamController<BackingState>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<Object?>>[];
  BackingState _state = const BackingState();
  int _endCount = 0;
  String? _staging;
  final Map<String, BackingFailure> _stageFailures = {};
  bool _closed = false;

  /// The player now.
  BackingState get state => _state;

  /// Every change of [state].
  Stream<BackingState> get states => _states.stream;

  /// Starts following the repository and the End setting, and reads which
  /// prepared files exist.
  Future<void> start() async {
    _endCount = _repository.state.endCount;
    _subscriptions.addAll([
      _repository.states.listen(_onPlayer),
      _repository.failures.listen(_onFailure),
      _repository.notices.listen(
        (notice) => _emit(
          _state.copyWith(notice: notice, noticeCount: _state.noticeCount + 1),
        ),
      ),
      _settings.mixOwner.changes.listen((_) => unawaited(_restage())),
    ]);
    _onPlayer(_repository.state);
    await _refreshMissing();
  }

  // ---- the prepared list ----

  /// Adds [asset] to the end of the prepared list; already prepared, it
  /// stays where it is. Selects it.
  Future<void> addToPrepared(BackingAsset asset) async {
    final item = BackingItem(digest: asset.digest, name: asset.name);
    final prepared = _state.prepared.any((i) => i.digest == asset.digest)
        ? _state.prepared
        : [..._state.prepared, item];
    _emit(_state.copyWith(prepared: prepared, selected: asset.digest));
    await _refreshMissing();
    await _restage();
  }

  /// Removes [digest] from the prepared list only: the file and any playing
  /// audio stay. The selection moves to the neighbour that takes its place.
  Future<void> remove(String digest) async {
    final index = _indexOf(digest);
    if (index < 0) return;
    final prepared = [..._state.prepared]..removeAt(index);
    var selected = _state.selected;
    if (selected == digest) {
      selected = prepared.isEmpty
          ? null
          : prepared[index < prepared.length ? index : prepared.length - 1]
                .digest;
    }
    _emit(
      _state.copyWith(
        prepared: prepared,
        selected: selected,
        clearSelected: selected == null,
      ),
    );
    await _restage();
  }

  /// Moves [digest] one place up; the selection stays on the same file.
  Future<void> moveUp(String digest) => _move(digest, -1);

  /// Moves [digest] one place down; the selection stays on the same file.
  Future<void> moveDown(String digest) => _move(digest, 1);

  Future<void> _move(String digest, int by) async {
    final from = _indexOf(digest);
    final to = from + by;
    if (from < 0 || to < 0 || to >= _state.prepared.length) return;
    final prepared = [..._state.prepared];
    final item = prepared.removeAt(from);
    prepared.insert(to, item);
    _emit(_state.copyWith(prepared: prepared));
    await _restage();
  }

  /// Selects [digest]; the loaded file keeps playing until Play.
  void select(String digest) {
    if (_indexOf(digest) < 0) return;
    _emit(_state.copyWith(selected: digest));
  }

  // ---- transport ----

  /// Play: on the loaded file, toggles Pause; on another selection, decodes
  /// it while the loaded one keeps playing, then switches to it, playing.
  Future<void> play() async {
    final selected = _state.selectedItem;
    if (selected == null) return;
    if (_state.selectionIsLoaded) {
      if (_repository.state.playing) {
        _repository.pause();
      } else {
        _repository.play();
      }
      return;
    }
    await _load(selected, play: true);
  }

  /// Pauses, keeping the position.
  void pause() => _repository.pause();

  /// Stops and rewinds; a `Play selected` decode in progress is dropped.
  void stop() => _repository.stop();

  /// Seeks the loaded file, playing or paused as it was.
  void seek(Duration position) => _repository.seek(position);

  /// Clear backing: unloads; the prepared list stays. The confirmation is
  /// the surface's.
  void clear() {
    _repository.clear();
    _emit(_state.copyWith(clearLoaded: true));
  }

  /// Use as backing: prepares [asset] and loads it, stopped. While another
  /// file plays it does nothing until called again with [confirmed].
  Future<UseAsBackingOutcome> useAsBacking(
    BackingAsset asset, {
    bool confirmed = false,
  }) async {
    final other =
        _repository.state.playing && _state.loaded?.digest != asset.digest;
    if (other && !confirmed) return UseAsBackingOutcome.needsConfirm;
    await addToPrepared(asset);
    final ok = await _load(
      BackingItem(digest: asset.digest, name: asset.name),
      play: false,
    );
    return ok ? UseAsBackingOutcome.loaded : UseAsBackingOutcome.refused;
  }

  Future<bool> _load(BackingItem item, {required bool play}) async {
    // The staged Next belongs to the outgoing file: release it before the
    // decode, so at most the loaded file and the new one are resident.
    if (_repository.state.staged != null || _staging != null) {
      _staging = null;
      await _repository.stageNext(null);
    }
    final ok = await _repository.load(item.digest, play: play, name: item.name);
    if (ok) _emit(_state.copyWith(loaded: item));
    await _restage();
    return ok;
  }

  // ---- automatic Next ----

  /// The prepared item after the loaded one, while End is Next and the
  /// loaded file is prepared; never wraps.
  BackingItem? get _following {
    final loaded = _state.loaded;
    if (_settings.mix.end != BackingEnd.next || loaded == null) return null;
    final index = _indexOf(loaded.digest);
    if (index < 0 || index + 1 >= _state.prepared.length) return null;
    return _state.prepared[index + 1];
  }

  /// Stages the following item, or clears a stage nothing follows.
  Future<void> _restage() async {
    if (_closed) return;
    final want = _following;
    final staged = _repository.state.staged;
    if (want?.digest == (_staging ?? staged)) return;
    if (want == null) {
      _staging = null;
      if (staged != null) await _repository.stageNext(null);
      return;
    }
    _staging = want.digest;
    _stageFailures.remove(want.digest);
    final ok = await _repository.stageNext(want.digest, name: want.name);
    if (_staging == want.digest) _staging = null;
    if (!ok && _repository.state.staged == null) {
      // Remembered for the end of the loaded file, which is when the
      // performer hears it and is told.
      _stageFailures.putIfAbsent(
        want.digest,
        () => BackingFailure(
          BackingFailureReason.busy,
          name: want.name,
          digest: want.digest,
        ),
      );
    }
  }

  void _onPlayer(BackingPlayerState player) {
    if (_closed) return;
    final ended = player.endCount != _endCount;
    _endCount = player.endCount;
    var next = _state.copyWith(player: player);
    if (player.loaded == null && _state.loaded != null && !_loadPending) {
      next = next.copyWith(clearLoaded: true);
    }
    if (ended && player.lastEnd == BackingEndEvent.advanced) {
      final before = _state.loaded;
      final now = _itemOf(player.loaded);
      next = next.copyWith(
        loaded: now,
        clearLoaded: now == null,
        // The selection follows the file only when it was following it.
        selected: before != null && _state.selected == before.digest
            ? now?.digest
            : null,
      );
      _emit(next);
      unawaited(_restage());
      return;
    }
    if (ended && player.lastEnd == BackingEndEvent.nextMissing) {
      final missed = _following;
      _emit(next);
      if (missed != null) {
        _onFailure(
          _stageFailures[missed.digest] ??
              BackingFailure(
                _state.missing.contains(missed.digest)
                    ? BackingFailureReason.missing
                    : BackingFailureReason.busy,
                name: missed.name,
                digest: missed.digest,
              ),
        );
      }
      return;
    }
    _emit(next);
  }

  bool get _loadPending => _repository.state.loading != null;

  void _onFailure(BackingFailure failure) {
    if (failure.digest != null && failure.digest == _staging) {
      _stageFailures[failure.digest!] = failure;
      return;
    }
    _emit(
      _state.copyWith(
        failure: failure,
        failureCount: _state.failureCount + 1,
      ),
    );
  }

  // ---- the Session ----

  /// The Session's share of the backing: the prepared order, the loaded
  /// item and the durable [mix].
  SessionBacking capture(BackingMix mix) => SessionBacking(
    prepared: [
      for (final item in _state.prepared)
        SessionBackingItem(digest: item.digest, name: item.name),
    ],
    loaded: _state.loaded == null
        ? null
        : SessionBackingItem(
            digest: _state.loaded!.digest,
            name: _state.loaded!.name,
          ),
    endMode: mix.end,
    level: mix.level,
    pan: mix.pan,
    outputMask: mix.outputMask,
  );

  /// Recalls a Session's prepared setup: the order, the loaded item loaded
  /// again stopped at 0 (D9), the selection on it. An item with no file
  /// stays listed as Missing and is never matched by name.
  Future<void> recall(SessionBacking backing) async {
    _repository.stop();
    final prepared = [
      for (final item in backing.prepared)
        BackingItem(digest: item.digest, name: item.name),
    ];
    final loaded = backing.loaded == null
        ? null
        : BackingItem(
            digest: backing.loaded!.digest,
            name: backing.loaded!.name,
          );
    final selected =
        loaded?.digest ?? (prepared.isEmpty ? null : prepared.first.digest);
    _emit(
      _state.copyWith(
        prepared: prepared,
        selected: selected,
        clearSelected: selected == null,
      ),
    );
    await _refreshMissing(also: loaded);
    if (loaded == null) {
      clear();
    } else if (_repository.state.loaded == loaded.digest) {
      _emit(_state.copyWith(loaded: loaded));
      await _restage();
    } else if (!await _load(loaded, play: false)) {
      clear();
    }
  }

  // ---- helpers ----

  int _indexOf(String digest) =>
      _state.prepared.indexWhere((item) => item.digest == digest);

  BackingItem? _itemOf(String? digest) {
    if (digest == null) return null;
    for (final item in [?_state.loaded, ..._state.prepared]) {
      if (item.digest == digest) return item;
    }
    return BackingItem(digest: digest, name: '');
  }

  /// Marks every prepared item (and [also]) whose asset is absent or
  /// unusable as Missing.
  Future<void> _refreshMissing({BackingItem? also}) async {
    List<BackingAsset> assets;
    try {
      assets = await _repository.store.list();
    } on Object {
      return; // An unreadable store leaves the marks as they were.
    }
    final usable = {
      for (final asset in assets)
        if (asset.available) asset.digest,
    };
    _emit(
      _state.copyWith(
        missing: {
          for (final item in [?also, ..._state.prepared])
            if (!usable.contains(item.digest)) item.digest,
        },
      ),
    );
  }

  void _emit(BackingState next) {
    if (_closed || next == _state) return;
    _state = next;
    _states.add(next);
  }

  /// Stops following; the repository and the voice stay as they are.
  Future<void> close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
  }
}
