import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/logging/app_log.dart';
import 'package:wifi_repository/wifi_repository.dart';

part 'wifi_state.dart';

/// Drives the Network page: status, scan, join, disconnect, forget, radio,
/// Connect automatically, password changes and the internet check.
///
/// Lives as long as the page does, so nothing here runs while it is shut.
/// While it is open ([start]) it follows the console the way a phone's Wi-Fi
/// settings do: the connection state live from the helper's monitor, a quiet
/// scan every [scanInterval], and the internet every [connectivityInterval].
class WifiCubit extends Cubit<WifiState> {
  /// Creates a [WifiCubit] over [_repository].
  ///
  /// [_retryDelays] is the backoff schedule for re-activating after a failed
  /// connection — one entry per automatic retry. Injectable so tests do not
  /// sit through real seconds. [_clock] times the internet check's
  /// [connectivityInterval].
  new({
    required this._repository,
    this._retryDelays = const [Duration(seconds: 2), Duration(seconds: 5)],
    this._clock = DateTime.now,
  }) : super(const WifiState());

  /// How often the open page scans, as Android's and iOS's Wi-Fi settings
  /// do, so the list follows what is in range without a tap on Scan.
  static const scanInterval = Duration(seconds: 10);

  /// How long the state is left to settle after a change the monitor
  /// reported before it is read: a join is a burst of device states.
  static const changeSettle = Duration(milliseconds: 300);

  /// How long a monitor that ended waits before it is started again. It
  /// doubles with each monitor that ends without an event, up to
  /// [monitorRestartMax], so a helper that cannot monitor is not respawned
  /// every few seconds.
  static const monitorRestart = Duration(seconds: 5);

  /// The longest wait before a monitor is started again.
  static const monitorRestartMax = Duration(minutes: 1);

  /// How often the open page looks at the internet (#1270 D14): one HEAD
  /// request to the update host per period, for one connection.
  static const connectivityInterval = Duration(seconds: 30);

  /// How much sooner than [connectivityInterval] a check may follow the last
  /// one. The page's timer ticks every [connectivityInterval], but each check
  /// is timed after a status read of varying length; without this, a tick a
  /// little quicker than the last lands a hair inside the interval, is
  /// skipped, and the page checks every minute instead.
  static const connectivitySlack = Duration(seconds: 5);

  final WifiRepository _repository;
  final List<Duration> _retryDelays;
  final DateTime Function() _clock;

  /// The last internet check: which connection, and when.
  ({String ssid, DateTime at})? _lastCheck;

  /// Generation stamp for [connect]. Each new join (and each cancel) bumps
  /// it; a loop that wakes from an await holding a stale stamp is abandoned —
  /// it must neither re-activate nor emit. Without this, cancelling and
  /// re-tapping the *same* SSID inside the backoff window would leave two
  /// live retry loops racing each other's activations and terminal emits.
  int _connectGen = 0;

  /// The helper join in flight, if any. Joins run one at a time: a second
  /// helper call would race the first for the one radio. Completes once the
  /// call has returned and, for a join cancelled meanwhile, once the console
  /// is back where it started.
  Future<void>? _join;

  /// The [_connectGen] of the join whose helper call [_join] is.
  int _joinGen = -1;

  /// Whether the join behind [_join] was cancelled while its call ran.
  bool _joinCancelled = false;

  /// The last join that failed for a reason other than its key, with the key
  /// it was given, for [retry]. A profile made for a new network is removed
  /// when its join fails, so the key is kept here rather than in it. In
  /// memory only, for as long as the page is open, and never in [state].
  ({String ssid, String? psk})? _failedJoin;

  /// The scan in flight, shared by [scan] and the periodic one.
  Future<Object?>? _scan;

  StreamSubscription<void>? _changes;
  Timer? _settleTimer;
  Timer? _monitorRestart;
  Timer? _scanTimer;
  Timer? _connectivityTimer;

  /// Monitors that ended in a row without an event.
  int _monitorFailures = 0;

  /// Bumped by every emit that changes the status, so a read that started
  /// before a fresher one landed is dropped rather than shown.
  int _statusEpoch = 0;

  /// A change the monitor reported while an action was busy; read once the
  /// action ends.
  bool _changedWhileBusy = false;

  /// Loads the state, then follows it while the page is open: the monitor's
  /// changes, a scan every [scanInterval] and the internet every
  /// [connectivityInterval]. All of it stops when the cubit closes.
  Future<void> start() async {
    await load();
    if (isClosed || !state.supported) return;
    _watch();
    _scanTimer = Timer.periodic(scanInterval, (_) => unawaited(_scanQuietly()));
    _connectivityTimer = Timer.periodic(
      connectivityInterval,
      (_) => unawaited(checkConnectivity()),
    );
    if (state.status.enabled) await scan();
  }

  /// Listens to the monitor. [restarted]: an earlier one ended, and what
  /// changed while none ran is read at once.
  void _watch({bool restarted = false}) {
    if (restarted) _changed();
    _changes = _repository.changes().listen(
      (_) {
        _monitorFailures = 0;
        _changed();
      },
      onError: (Object error) => AppLog.warn('wifi: monitor: $error'),
      onDone: () {
        _changes = null;
        if (isClosed) return;
        final wait = monitorRestart * (1 << _monitorFailures.clamp(0, 4));
        _monitorFailures++;
        AppLog.warn('wifi: monitor ended; starting it again in $wait');
        _monitorRestart = Timer(
          wait > monitorRestartMax ? monitorRestartMax : wait,
          () {
            if (!isClosed) _watch(restarted: true);
          },
        );
      },
    );
  }

  void _changed() {
    _settleTimer?.cancel();
    _settleTimer = Timer(changeSettle, () => unawaited(_follow()));
  }

  /// Reads the status after a change the monitor reported. Quiet: no busy
  /// state, and a failed read keeps what is on screen. An action in flight
  /// reads the status itself when it ends, and a change during it is read
  /// after it, so this never races one.
  Future<void> _follow() async {
    if (isClosed || !state.supported) return;
    if (state.busy) {
      _changedWhileBusy = true;
      return;
    }
    final epoch = _statusEpoch;
    final WifiStatus status;
    try {
      status = await _repository.status();
    } on Object {
      return;
    }
    if (isClosed) return;
    // Another read landed while this one ran, and it may have started
    // earlier: read again rather than trust either.
    if (epoch != _statusEpoch) return _changed();
    final cameOn = !state.status.enabled && status.enabled;
    emit(_live(status));
    // Switched on from elsewhere: look for networks at once.
    if (cameOn) unawaited(_scanQuietly());
  }

  /// [state] with [status] read while nothing was running. A connection
  /// that came up since clears a failed join's message: it was about an
  /// earlier attempt, and under the new connection it would read as a fault
  /// of that one.
  WifiState _live(WifiStatus status) {
    final now = state.status;
    final newLink =
        status.connected && (!now.connected || now.ssid != status.ssid);
    return state.copyWith(
      status: status,
      clearError: newLink && state.joinError != null,
    );
  }

  @override
  void onChange(Change<WifiState> change) {
    super.onChange(change);
    final error = change.nextState.errorMessage;
    if (error != null && error != change.currentState.errorMessage) {
      // The helper's own words, for the bench; the page shows its own.
      AppLog.warn('wifi: $error');
    }
    if (change.currentState.status != change.nextState.status) _statusEpoch++;
    if (_changedWhileBusy &&
        change.currentState.busy &&
        !change.nextState.busy) {
      _changedWhileBusy = false;
      _changed();
    }
  }

  @override
  Future<void> close() async {
    _settleTimer?.cancel();
    _monitorRestart?.cancel();
    _scanTimer?.cancel();
    _connectivityTimer?.cancel();
    await _changes?.cancel();
    await super.close();
  }

  /// Loads status (and whether the stack is supported).
  Future<void> load() async {
    emit(
      state.copyWith(
        busy: true,
        clearConnectingSsid: true,
        disconnecting: false,
        clearError: true,
      ),
    );
    try {
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(
          supported: status.supported && _repository.isSupported,
          status: status,
          busy: false,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Scans for nearby networks, showing that it is scanning. A scan already
  /// in flight (the periodic one) is joined rather than doubled.
  Future<void> scan() async {
    if (!state.supported) return;
    emit(state.copyWith(scanning: true, clearError: true));
    final error = await (_scan ?? _startScan());
    if (isClosed) return;
    emit(
      state.copyWith(
        scanning: false,
        errorMessage: error == null ? null : '$error',
      ),
    );
  }

  /// The periodic scan: shows nothing while it runs and keeps any message on
  /// screen. Skipped while the radio is off, while anything is joining (a
  /// scan takes the radio off-channel mid-association) and while another
  /// action or scan runs.
  Future<void> _scanQuietly() async {
    final status = state.status;
    if (isClosed ||
        !state.supported ||
        !status.enabled ||
        status.connecting ||
        state.busy ||
        state.connectingSsid != null ||
        _scan != null) {
      return;
    }
    await _startScan();
  }

  /// Starts [_scanOnce] as [_scan], which it stays until it ends. Cleared
  /// here rather than inside it: a scan that fails before its first await
  /// ends before it could be assigned.
  Future<Object?> _startScan() {
    final scan = _scan = _scanOnce();
    unawaited(
      scan.whenComplete(() {
        if (identical(_scan, scan)) _scan = null;
      }),
    );
    return scan;
  }

  /// One scan and the status after it; the error, or null.
  Future<Object?> _scanOnce() async {
    try {
      final networks = await _repository.scan();
      final epoch = _statusEpoch;
      final status = await _repository.status();
      if (isClosed) return null;
      // One row per name, the strongest: the list keys its rows by name.
      final bySsid = <String, WifiNetwork>{};
      for (final n in networks) {
        if (n.ssid.isEmpty) continue;
        final seen = bySsid[n.ssid];
        if (seen == null || n.signal > seen.signal) bySsid[n.ssid] = n;
      }
      final next = epoch == _statusEpoch ? _live(status) : state;
      emit(next.copyWith(networks: bySsid.values.toList()));
      return null;
    } on Object catch (e) {
      return e;
    }
  }

  /// Joins [ssid] with optional [psk].
  ///
  /// A failed connection ([WifiJoinError.noConnection]) is retried here with
  /// backoff — bounded by the cubit's retry schedule, never forever — because
  /// a #824-shaped race is fixed by a second activation, not by a new
  /// password. The helper says why a join failed (#1817); only a key the
  /// access point refused reads as a wrong password.
  Future<void> connect(String ssid, {String? psk}) async {
    if (!state.supported) return;
    _failedJoin = null;
    // This call owns the join until a newer connect (or a cancel) bumps the
    // generation. Every await below re-checks it: a stale loop must neither
    // re-activate nor emit — even for the same SSID, where the old
    // marker-based check could not tell the two joins apart.
    final gen = ++_connectGen;
    bool abandoned() => isClosed || gen != _connectGen;
    emit(
      state.copyWith(
        busy: true,
        connectingSsid: ssid,
        retrying: false,
        disconnecting: false,
        clearError: true,
      ),
    );
    // One helper join at a time. A join tapped while a cancelled one is
    // still running waits for it — and for it to put the console back —
    // rather than racing it for the radio. A scan in flight is waited for
    // too: it holds the radio off-channel, and a join beside it fails.
    while (_join != null || _scan != null) {
      await (_join ?? _scan);
      if (abandoned()) return;
    }
    final before = state.status;
    final previous = before.connected ? before.ssid : '';
    final wasSaved =
        before.autoConnect.containsKey(ssid) ||
        state.networks.any((n) => n.ssid == ssid && n.saved);
    var attempt = 0;
    while (true) {
      final error = await _helperJoin(
        ssid,
        psk: psk,
        gen: gen,
        previous: previous,
        wasSaved: wasSaved,
      );
      // A join cancelled while the helper call was in flight ends here, and
      // must end silently: the call has already put the console back.
      if (abandoned()) return;
      if (error == null) {
        try {
          final status = await _repository.status();
          if (abandoned()) return;
          emit(
            state.copyWith(
              status: status,
              busy: false,
              clearConnectingSsid: true,
              disconnecting: false,
            ),
          );
        } on Object catch (e) {
          if (abandoned()) return;
          emit(
            state.copyWith(
              busy: false,
              clearConnectingSsid: true,
              errorMessage: '$e',
            ),
          );
        }
        return;
      }
      final kind = error is WifiHelperException
          ? error.join ?? WifiJoinError.noConnection
          : WifiJoinError.noConnection;
      // A failed join on a console that was on another network has brought
      // that network back (#1270 D13). Retrying would drop it again for a
      // join that already failed once.
      final restored = error is WifiHelperException && error.restored != null;
      final retryable = !restored && kind == WifiJoinError.noConnection;
      if (retryable && attempt < _retryDelays.length) {
        emit(state.copyWith(retrying: true));
        await Future<void>.delayed(_retryDelays[attempt]);
        // The marker check still matters alongside the generation: another
        // action (load, forget, radio) may have cleared the join without
        // starting a new one.
        if (abandoned() || state.connectingSsid != ssid) return;
        attempt++;
        continue;
      }
      var status = state.status;
      try {
        status = await _repository.status();
      } on Object {
        // Keep the last known status if refresh fails.
      }
      // Guarded here: the refresh above is itself an await, so it re-opens
      // the race.
      if (abandoned()) return;
      if (kind != WifiJoinError.wrongPassword) {
        _failedJoin = (ssid: ssid, psk: psk);
      }
      emit(
        state.copyWith(
          status: status,
          busy: false,
          clearConnectingSsid: true,
          disconnecting: false,
          errorMessage: '$error',
          joinError: kind,
          failedSsid: ssid,
        ),
      );
      return;
    }
  }

  /// Joins the network whose join failed last again, with the key it was
  /// given: the card's Try again. A wrong password is not retried; it goes
  /// back to the password sheet.
  Future<void> retry() async {
    final failed = _failedJoin;
    if (failed == null || state.failedSsid != failed.ssid) return;
    await connect(failed.ssid, psk: failed.psk);
  }

  /// One helper join for the [connect] of generation [gen]: the error it
  /// failed with, or null. Held in [_join] while it runs, and, if
  /// [cancelConnect] cancels it meanwhile, it puts the console back before it
  /// lets go.
  Future<Object?> _helperJoin(
    String ssid, {
    required String? psk,
    required int gen,
    required String previous,
    required bool wasSaved,
  }) async {
    final done = Completer<void>();
    _join = done.future;
    _joinGen = gen;
    _joinCancelled = false;
    Object? error;
    try {
      await _repository.connect(ssid, psk: psk);
    } on Object catch (e) {
      error = e;
    }
    try {
      if (_joinCancelled) {
        await _putBack(
          ssid,
          joined: error == null,
          previous: previous,
          wasSaved: wasSaved,
        );
      }
    } finally {
      _join = null;
      done.complete();
    }
    return error;
  }

  /// Leaves the console where a cancelled join of [ssid] found it, whatever
  /// the helper got to before Cancel landed. A join that went through anyway
  /// ([joined]) is undone — a network saved by it is forgotten — and the
  /// network that was up before ([previous]) is brought back unless it already
  /// is: Cancel's disconnect can land while the helper is bringing it back.
  /// Best effort: the console is no worse off for a step that fails.
  Future<void> _putBack(
    String ssid, {
    required bool joined,
    required String previous,
    required bool wasSaved,
  }) async {
    try {
      if (joined && !wasSaved) await _repository.forget(ssid);
      final now = await _repository.status();
      if (previous.isNotEmpty) {
        if (!now.connected || now.ssid != previous) {
          await _repository.connect(previous);
        }
      } else if (joined && now.connected) {
        await _repository.disconnect();
      }
    } on Object {
      // Best effort; the status below shows where it ended.
    }
    // A newer join, waiting on this one, owns the page from here.
    if (isClosed || state.connectingSsid != null) return;
    await _settle();
  }

  /// Re-reads the status after the musician ended something on purpose, so
  /// the network that was up last is not then called lost.
  Future<void> _settle() async {
    try {
      final status = await _repository.status();
      if (isClosed) return;
      emit(state.copyWith(status: status, leftSsid: _last(status)));
    } on Object {
      return;
    }
  }

  /// [status]'s last network, or null when there is none.
  static String? _last(WifiStatus status) =>
      status.lastSsid.isEmpty ? null : status.lastSsid;

  /// Abandons a join.
  ///
  /// While its helper call is in flight, takes the link down, which ends the
  /// helper's activation; the helper then brings back the network that was
  /// up before (#1270 D13), and the cancelled call puts back whatever it
  /// could not (see [_putBack]), so cancelling leaves the console where it
  /// started. In the retry backoff no helper is running and the previous
  /// network is already back, so the link is left alone: taking it down then
  /// would drop that network, and `device disconnect` keeps NetworkManager
  /// from bringing it back on its own.
  Future<void> cancelConnect() async {
    if (state.connectingSsid == null) return;
    final running = _join != null && _joinGen == _connectGen;
    // Abandon the join's loop wherever it is — mid-helper-call, mid-backoff
    // or waiting for an earlier join — so it can never re-activate or emit
    // over whatever comes next.
    _connectGen++;
    emit(state.copyWith(clearConnectingSsid: true, clearError: true));
    if (running) {
      _joinCancelled = true;
      await _dropLink(left: false);
    } else {
      emit(state.copyWith(busy: false));
      await _settle();
    }
  }

  /// Disconnects the current association. The network is left on purpose, so
  /// the page does not then call it lost.
  Future<void> disconnect() => _dropLink(left: true);

  /// Takes the link down. [left]: the musician left the network that was up;
  /// otherwise a join was cancelled, and the network that was up last is not
  /// lost either.
  Future<void> _dropLink({required bool left}) async {
    if (!state.supported) return;
    final ssid = state.status.ssid;
    emit(
      state.copyWith(
        busy: true,
        disconnecting: true,
        clearConnectingSsid: true,
        clearError: true,
      ),
    );
    try {
      await _repository.disconnect();
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: status,
          busy: false,
          disconnecting: false,
          leftSsid: left ? (ssid.isNotEmpty ? ssid : null) : _last(status),
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(busy: false, disconnecting: false, errorMessage: '$e'),
      );
    }
  }

  /// Forgets a saved [ssid] and disconnects if it was the active one. The
  /// network that was up last before it is not then called lost: forgetting
  /// is on purpose.
  Future<void> forget(String ssid) async {
    if (!state.supported) return;
    // A scan in flight lands first, so it cannot put the network back.
    await _scan;
    if (isClosed) return;
    final forgettingActive =
        state.status.connected && state.status.ssid == ssid;
    emit(
      state.copyWith(
        busy: true,
        disconnecting: forgettingActive,
        clearConnectingSsid: true,
        clearError: true,
      ),
    );
    try {
      await _repository.forget(ssid);
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: status,
          networks: [
            for (final n in state.networks)
              if (n.ssid != ssid) n,
          ],
          busy: false,
          disconnecting: false,
          leftSsid: _last(status),
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(busy: false, disconnecting: false, errorMessage: '$e'),
      );
    }
  }

  /// Radio on/off.
  ///
  /// Switching the radio is deliberate, so the network it was on is not
  /// called lost while NetworkManager brings it back on its own.
  Future<void> setEnabled({required bool enabled}) async {
    if (!state.supported) return;
    emit(
      state.copyWith(
        busy: true,
        clearConnectingSsid: true,
        disconnecting: false,
        clearError: true,
      ),
    );
    try {
      await _repository.setEnabled(enabled: enabled);
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(status: status, busy: false, leftSsid: _last(status)),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Whether the saved network [ssid] is joined on its own.
  Future<void> setAutoConnect(String ssid, {required bool enabled}) async {
    if (!state.supported) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _repository.setAutoConnect(ssid, enabled: enabled);
      final status = await _repository.status();
      if (isClosed) return;
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Gives the saved network [ssid] the key [psk].
  ///
  /// A network the last scan saw is joined with the new key, so it is tested
  /// before it replaces the old one: the helper stores a key only once it
  /// works, and a failure keeps the old key and brings back the previous
  /// connection. A network out of range cannot be tested, so the key
  /// is only stored.
  Future<void> changePassword(String ssid, String psk) async {
    if (!state.supported) return;
    final inRange = state.networks.any((n) => n.ssid == ssid && n.inRange);
    if (inRange) return await connect(ssid, psk: psk);
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _repository.changePassword(ssid, psk);
      final status = await _repository.status();
      if (isClosed) return;
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Asks whether the internet answers over the current connection, at most
  /// once per [connectivityInterval] (less [connectivitySlack]) for one
  /// connection (#1270 D14). A new connection is checked at once. A failed
  /// check leaves the answer unknown rather than claiming no internet.
  Future<void> checkConnectivity() async {
    final status = state.status;
    if (isClosed || !state.supported || !status.connected) return;
    final ssid = status.ssid;
    final now = _clock();
    final last = _lastCheck;
    if (last != null &&
        last.ssid == ssid &&
        now.difference(last.at) < connectivityInterval - connectivitySlack) {
      return;
    }
    _lastCheck = (ssid: ssid, at: now);
    try {
      final online = await _repository.checkConnectivity();
      if (isClosed) return;
      emit(state.copyWith(internet: (ssid: ssid, online: online)));
    } on Object {
      return;
    }
  }
}
