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

  /// The shortest time between two internet checks of one connection
  /// (#1270 D14): one HEAD request to the update host, at most this often.
  static const connectivityInterval = Duration(seconds: 30);

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
    var attempt = 0;
    while (true) {
      try {
        await _repository.connect(ssid, psk: psk);
        if (abandoned()) return;
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
        return;
      } on Object catch (e) {
        // The throw came out of an await too: a join cancelled while the
        // helper call was in flight ends here, and must end silently.
        if (abandoned()) return;
        final kind = classifyWifiJoinFailure(
          raw: '$e',
          interactive: interactive,
        );
        final retryable =
            kind == WifiJoinErrorKind.transient ||
            kind == WifiJoinErrorKind.timeout;
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
        // Guarded here rather than at the top of the catch: the refresh above
        // is itself an await, so it re-opens the race.
        if (abandoned()) return;
        emit(
          state.copyWith(
            status: status,
            busy: false,
            clearConnectingSsid: true,
            disconnecting: false,
            errorMessage: '$e',
            errorKind: kind,
            failedSsid: ssid,
          ),
        );
        return;
      }
    }
  }

  /// Abandons an in-flight join.
  ///
  /// Drops the in-flight marker and takes the link down, which ends the
  /// helper's activation. The helper call itself cannot be recalled once
  /// issued; failing, it brings back the network that was up before the join
  /// (#1270 D13), so cancelling leaves the console where it started.
  Future<void> cancelConnect() async {
    if (state.connectingSsid == null) return;
    // Abandon the join's loop wherever it is — mid-helper-call or mid-backoff
    // — so it can never re-activate or emit over whatever comes next.
    _connectGen++;
    emit(state.copyWith(clearConnectingSsid: true, clearError: true));
    await _dropLink(left: false);
  }

  /// Disconnects the current association. The network is left on purpose, so
  /// the page does not then call it lost.
  Future<void> disconnect() => _dropLink(left: true);

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
          leftSsid: left && ssid.isNotEmpty ? ssid : null,
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

  /// Forgets a saved [ssid] and disconnects if it was the active one.
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
          leftSsid: status.lastSsid.isEmpty ? null : status.lastSsid,
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
  /// once per [connectivityInterval] for one connection (#1270 D14). A new
  /// connection is checked at once. A failed check leaves the answer unknown
  /// rather than claiming no internet.
  Future<void> checkConnectivity() async {
    final status = state.status;
    if (isClosed || !state.supported || !status.connected) return;
    final ssid = status.ssid;
    final now = _clock();
    final last = _lastCheck;
    if (last != null &&
        last.ssid == ssid &&
        now.difference(last.at) < connectivityInterval) {
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
