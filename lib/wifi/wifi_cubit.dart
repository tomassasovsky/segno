import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/wifi/wifi_join_failure.dart';
import 'package:wifi_repository/wifi_repository.dart';

part 'wifi_state.dart';

/// Drives the Network page: status, scan, join, disconnect, forget, radio,
/// Connect automatically, password changes and the internet check.
///
/// Lives as long as the page does, so nothing here runs while it is shut.
class WifiCubit extends Cubit<WifiState> {
  /// Creates a [WifiCubit] over [repository].
  ///
  /// [retryDelays] is the backoff schedule for re-activating after a
  /// backend/transient join failure — one entry per automatic retry.
  /// Injectable so tests do not sit through real seconds. [clock] times the
  /// internet check's [connectivityInterval].
  WifiCubit({
    required WifiRepository repository,
    List<Duration> retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
    DateTime Function() clock = DateTime.now,
  }) : _repository = repository,
       _retryDelays = retryDelays,
       _clock = clock,
       super(const WifiState());

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

  /// Scans for nearby networks.
  Future<void> scan() async {
    if (!state.supported) return;
    emit(state.copyWith(scanning: true, clearError: true));
    try {
      final networks = await _repository.scan();
      // Prefer stronger signal; drop empty SSIDs / de-dupe by name.
      final bySsid = <String, WifiNetwork>{};
      for (final n in networks) {
        if (n.ssid.isEmpty) continue;
        final existing = bySsid[n.ssid];
        if (existing == null || n.signal > existing.signal) {
          bySsid[n.ssid] = n;
        }
      }
      final sorted = bySsid.values.toList()
        ..sort((a, b) => b.signal.compareTo(a.signal));
      final status = await _repository.status();
      if (isClosed) return;
      emit(
        state.copyWith(
          networks: sorted,
          status: status,
          scanning: false,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(scanning: false, errorMessage: '$e'));
    }
  }

  /// Joins [ssid] with optional [psk].
  ///
  /// A backend/transient failure (see [classifyWifiJoinFailure]) is retried
  /// here with backoff — bounded by the cubit's retry schedule, never forever
  /// — because a #824-shaped race is fixed by a second activation, not by a
  /// new password. Only a genuine credential rejection surfaces as one.
  Future<void> connect(String ssid, {String? psk}) async {
    if (!state.supported) return;
    // A password typed moments ago is the context that makes a `no-secrets`
    // failure plausibly about the password (#829).
    final interactive = psk != null && psk.isNotEmpty;
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
    // rather than racing it for the radio.
    while (_join != null) {
      await _join;
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
      final kind = classifyWifiJoinFailure(
        raw: '$error',
        interactive: interactive,
      );
      // A failed join on a console that was on another network has brought
      // that network back (#1270 D13). Retrying would drop it again for a
      // join that already failed once — for a wrong key, twice more.
      final restored = error is WifiHelperException && error.restored != null;
      final retryable =
          !restored &&
          (kind == WifiJoinErrorKind.transient ||
              kind == WifiJoinErrorKind.timeout);
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
      emit(
        state.copyWith(
          status: status,
          busy: false,
          clearConnectingSsid: true,
          disconnecting: false,
          errorMessage: '$error',
          errorKind: kind,
          failedSsid: ssid,
        ),
      );
      return;
    }
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
        state.copyWith(
          busy: false,
          disconnecting: false,
          errorMessage: '$e',
        ),
      );
    }
  }

  /// Forgets a saved [ssid] and disconnects if it was the active one. The
  /// network that was up last before it is not then called lost: forgetting
  /// is on purpose.
  Future<void> forget(String ssid) async {
    if (!state.supported) return;
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
        state.copyWith(
          busy: false,
          disconnecting: false,
          errorMessage: '$e',
        ),
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
        state.copyWith(
          status: status,
          busy: false,
          leftSsid: _last(status),
        ),
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
  /// works, and a failure reads as "Incorrect password" and brings back the
  /// previous connection. A network out of range cannot be tested, so the key
  /// is only stored.
  Future<void> changePassword(String ssid, String psk) async {
    if (!state.supported) return;
    final inRange = state.networks.any((n) => n.ssid == ssid && n.inRange);
    if (inRange) return connect(ssid, psk: psk);
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

  /// Re-reads the association, then checks the internet — the page's
  /// periodic look while it is open. Quiet: it shows no busy state, and a
  /// failed read keeps what is on screen.
  Future<void> refresh() async {
    if (!state.supported || state.busy) return;
    try {
      final status = await _repository.status();
      if (isClosed) return;
      emit(state.copyWith(status: status));
    } on Object {
      return;
    }
    await checkConnectivity();
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
