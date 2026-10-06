import 'dart:async';

import 'package:backing_repository/src/backing_asset_store.dart';
import 'package:backing_repository/src/models/backing_failure.dart';
import 'package:backing_repository/src/models/backing_player_state.dart';
import 'package:segno_engine/segno_engine.dart';

/// Drives the engine's backing voice (#1200 plan, Part 4): loads, staging,
/// transport, mix and End, across engine restarts, without leaking a decoded
/// buffer.
///
/// Owns what the engine cannot: which asset each engine token names, the
/// desired mix and End to replay after a configure or reopen, a load in
/// progress (which a later load, Stop or Clear supersedes, freeing its
/// result), and the one retry a load gets when the engine reads NOT_READY (a
/// replaced buffer still on its way back). Knows nothing about sessions,
/// pedals or the prepared order.
class BackingRepository {
  /// Creates a [BackingRepository] over [engine] (whose rate [metering]
  /// reports: the same engine object in production).
  BackingRepository({
    required BackingControl engine,
    required EngineMetering metering,
    required AudioDecoder decoder,
    required BackingAssetStore store,
    Duration pollInterval = const Duration(milliseconds: 50),
    Duration retryDelay = const Duration(milliseconds: 10),
    int retries = 8,
  }) : _engine = engine,
       _metering = metering,
       _decoder = decoder,
       _store = store,
       _pollInterval = pollInterval,
       _retryDelay = retryDelay,
       _retries = retries {
    _epoch = _engine.backingState().epoch;
    _cachedRate = _metering.snapshot().sampleRate;
  }

  final BackingControl _engine;
  final EngineMetering _metering;
  final AudioDecoder _decoder;
  final BackingAssetStore _store;
  final Duration _pollInterval;
  final Duration _retryDelay;
  final int _retries;

  /// The engine rate, read from a snapshot only when the engine restarts
  /// (an epoch change) or while it reads 0 (not running yet), not on every
  /// refresh (review of P4, L3).
  int _cachedRate = 0;

  final _states = StreamController<BackingPlayerState>.broadcast(sync: true);
  final _failures = StreamController<BackingFailure>.broadcast(sync: true);
  final _notices = StreamController<BackingNotice>.broadcast(sync: true);

  BackingPlayerState _state = const BackingPlayerState();
  int _epoch = 0;
  int _nextToken = 1;
  final Map<int, String> _tokens = {};
  static const int _tokenWindow = 16;
  int _loadGeneration = 0;
  int _stageGeneration = 0;
  Timer? _poll;
  bool _disposed = false;

  // The desired settings, replayed after the engine restarts.
  BackingEnd _end = BackingEnd.stop;
  double _level = 1;
  double _pan = 0;
  int _output = 0;

  /// The player now.
  BackingPlayerState get state => _state;

  /// Every change of [state].
  Stream<BackingPlayerState> get states => _states.stream;

  /// Refused loads and stages, for the UI to explain.
  Stream<BackingFailure> get failures => _failures.stream;

  /// Changes the performer must be told about.
  Stream<BackingNotice> get notices => _notices.stream;

  int get _rate => _cachedRate > 0
      ? _cachedRate
      : (_cachedRate = _metering.snapshot().sampleRate);

  /// Loads the asset [digest] (verified against its bytes), replacing the
  /// loaded file once it has decoded; the old one keeps playing until then.
  /// [play] starts it. Returns whether it loaded; a refusal is also reported
  /// on [failures]. A later [load], [stop] or [clear] supersedes it.
  Future<bool> load(
    String digest, {
    bool play = false,
    String name = '',
  }) async {
    final generation = ++_loadGeneration;
    _emit(_state.copyWith(loading: digest));
    final ok = await _install(
      digest,
      name,
      () => generation == _loadGeneration,
      (audio, token) => _engine.backingLoad(audio, item: token, play: play),
    );
    if (generation == _loadGeneration) {
      _emit(_state.copyWith(clearLoading: true));
    }
    refresh();
    return ok;
  }

  /// Stages the asset [digest] for End = Next; null clears the stage. A
  /// later [stageNext] supersedes it.
  Future<bool> stageNext(String? digest, {String name = ''}) async {
    final generation = ++_stageGeneration;
    if (digest == null) {
      final result = _engine.backingStageNext(null, item: -1);
      refresh();
      return result.isOk;
    }
    final ok = await _install(
      digest,
      name,
      () => generation == _stageGeneration,
      (audio, token) => _engine.backingStageNext(audio, item: token),
    );
    refresh();
    return ok;
  }

  /// Resolves, decodes and hands one asset to the engine through [hand],
  /// retrying a bounded number of times on NOT_READY and re-decoding once
  /// when the engine rate
  /// changed under the decode.
  Future<bool> _install(
    String digest,
    String name,
    bool Function() current,
    EngineResult Function(DecodedAudio audio, int token) hand,
  ) async {
    var label = name;
    try {
      final asset = await _store.resolve(digest, name: name);
      label = asset.name;
      for (var attempt = 0; attempt < 2; attempt++) {
        final rate = _rate;
        if (rate <= 0) {
          throw BackingFailure(
            BackingFailureReason.notRunning,
            name: label,
            digest: digest,
          );
        }
        final audio = await _decoder.decode(asset.path, sampleRate: rate);
        if (!current() || _disposed) {
          audio.dispose();
          return false;
        }
        final token = _nextToken++;
        var result = hand(audio, token);
        // NOT_READY lasts until the callback has applied the previous post
        // and a replaced buffer has finished its fade and come back: up to
        // two device blocks. Retry a bounded number of times rather than
        // once after a guess (review of P4, L1).
        for (
          var retry = 0;
          retry < _retries && result == EngineResult.notReady;
          retry++
        ) {
          await Future<void>.delayed(_retryDelay);
          if (!current() || _disposed) {
            audio.dispose();
            return false;
          }
          result = hand(audio, token);
        }
        if (result.isOk) {
          _tokens[token] = digest;
          return true;
        }
        audio.dispose();
        // The interface changed rate while this decoded: decode again.
        if (result == EngineResult.invalid) {
          // The interface may have changed rate under the decode: read it
          // afresh, and decode again when it did.
          _cachedRate = _metering.snapshot().sampleRate;
          if (audio.sampleRate != _rate) continue;
        }
        // The file decoded cleanly: a hand-over refusal is about the engine,
        // never the file (review of P4, L2).
        throw BackingFailure(
          BackingFailureReason.ofHandover(result),
          name: label,
          digest: digest,
        );
      }
      throw BackingFailure(
        BackingFailureReason.busy,
        name: label,
        digest: digest,
      );
    } on BackingFailure catch (failure) {
      if (current()) _failures.add(failure);
      return false;
    } on EngineException catch (e) {
      if (current()) {
        _failures.add(
          BackingFailure(
            BackingFailureReason.fromEngine(e.result),
            name: label,
            digest: digest,
          ),
        );
      }
      return false;
    }
  }

  /// Plays the loaded file (a resume after a pause).
  void play() => _transport(BackingTransportOp.play);

  /// Pauses, keeping the position.
  void pause() => _transport(BackingTransportOp.pause);

  /// Stops and rewinds; a load in progress is cancelled (its result is
  /// freed, the old file stays loaded).
  void stop() {
    _loadGeneration++;
    _emit(_state.copyWith(clearLoading: true));
    _transport(BackingTransportOp.stop);
  }

  void _transport(BackingTransportOp op) {
    _engine.backingTransport(op);
    refresh();
  }

  /// Unloads the loaded and staged files (cancelling a load in progress).
  void clear() {
    _loadGeneration++;
    _stageGeneration++;
    _emit(_state.copyWith(clearLoading: true));
    _engine.backingClear();
    refresh();
  }

  /// Moves the loaded file to [position], clamped by the engine.
  void seek(Duration position) {
    final rate = _state.sampleRate > 0 ? _state.sampleRate : _rate;
    _engine.backingSeek(
      position.inMicroseconds * rate ~/ Duration.microsecondsPerSecond,
    );
    refresh();
  }

  /// The End setting.
  void setEnd(BackingEnd mode) {
    _end = mode;
    _engine.setBackingEnd(mode);
    refresh();
  }

  /// The backing gain.
  void setLevel(double gain) {
    _level = gain;
    _engine.setBackingLevel(gain);
    refresh();
  }

  /// The backing balance.
  void setPan(double pan) {
    _pan = pan;
    _engine.setBackingPan(pan);
    refresh();
  }

  /// The backing output channel mask.
  void setOutput(int mask) {
    _output = mask;
    _engine.setBackingOutput(mask);
    refresh();
  }

  /// Reads the engine's voice now: maps its tokens back to digests, replays
  /// the settings and reloads after an engine restart, and keeps polling
  /// while anything is playing or loading.
  void refresh() {
    if (_disposed) return;
    final s = _engine.backingState();
    if (s.epoch != _epoch) {
      _epoch = s.epoch;
      _cachedRate = _metering.snapshot().sampleRate;
      _restarted(s);
      return;
    }
    _emit(
      _state.copyWith(
        loaded: _tokens[s.item],
        clearLoaded: !_tokens.containsKey(s.item),
        staged: _tokens[s.nextItem],
        clearStaged: !_tokens.containsKey(s.nextItem),
        transport: s.transport,
        position: s.position,
        frames: s.frames,
        sampleRate: _rate,
        endMode: s.endMode,
        level: s.level,
        pan: s.pan,
        outputMask: s.outputMask,
        lastEnd: s.lastEnd,
        endCount: s.endCount,
      ),
    );
    // A token the engine has not applied yet (still in its command ring) must
    // survive this read, so prune by age, not by what the engine reports:
    // the engine holds at most four buffers, all among the newest tokens.
    _tokens.removeWhere(
      (token, _) =>
          token < _nextToken - _tokenWindow &&
          token != s.item &&
          token != s.nextItem,
    );
    _schedulePoll();
  }

  /// After a configure or reopen: the settings come back, a file the
  /// configure freed is decoded again at the new rate (stopped), and a
  /// performer whose backing was playing is told.
  void _restarted(BackingState s) {
    final wasPlaying = _state.playing;
    final loaded = _state.loaded;
    final staged = _state.staged;
    _engine
      ..setBackingEnd(_end)
      ..setBackingLevel(_level)
      ..setBackingPan(_pan)
      ..setBackingOutput(_output);
    if (wasPlaying) _notices.add(BackingNotice.interfaceChanged);
    final kept = s.item >= 0 && _tokens.containsKey(s.item);
    _emit(_state.copyWith(transport: BackingTransport.stopped, position: 0));
    if (!kept && loaded != null) unawaited(load(loaded));
    if (s.nextItem < 0 && staged != null) unawaited(stageNext(staged));
    refresh();
  }

  void _schedulePoll() {
    final busy = _state.playing || _state.loading != null;
    if (busy && _poll == null) {
      _poll = Timer.periodic(_pollInterval, (_) => refresh());
    } else if (!busy && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  void _emit(BackingPlayerState next) {
    if (_disposed || next == _state) return;
    _state = next;
    _states.add(next);
  }

  /// Stops polling and closes the streams; a load in progress frees its
  /// result when it finishes. What the engine holds stays the engine's.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _loadGeneration++;
    _stageGeneration++;
    _poll?.cancel();
    _poll = null;
    await Future.wait([_states.close(), _failures.close(), _notices.close()]);
  }
}
