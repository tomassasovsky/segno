import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/wifi/wifi_join_failure.dart';
import 'package:wifi_repository/wifi_repository.dart';

part 'wifi_state.dart';

/// Drives the console WiFi UI: status, scan, join, disconnect, forget, radio.
class WifiCubit extends Cubit<WifiState> {
  /// Creates a [WifiCubit] over [repository].
  ///
  /// [retryDelays] is the backoff schedule for re-activating after a
  /// backend/transient join failure — one entry per automatic retry.
  /// Injectable so tests do not sit through real seconds.
  WifiCubit({
    required WifiRepository repository,
    List<Duration> retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
  }) : _repository = repository,
       _retryDelays = retryDelays,
       super(const WifiState());

  final WifiRepository _repository;
  final List<Duration> _retryDelays;

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
  /// Drops the in-flight marker and disconnects. The helper call itself cannot
  /// be recalled once issued, so dropping any association it may already have
  /// made is the only thing still true afterwards.
  Future<void> cancelConnect() async {
    if (state.connectingSsid == null) return;
    // Abandon the join's loop wherever it is — mid-helper-call or mid-backoff
    // — so it can never re-activate or emit over whatever comes next.
    _connectGen++;
    emit(state.copyWith(clearConnectingSsid: true, clearError: true));
    await disconnect();
  }

  /// Disconnects the current association.
  Future<void> disconnect() async {
    if (!state.supported) return;
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

  /// Radio on/off — Control Center tile tap.
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
      emit(state.copyWith(status: status, busy: false));
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, errorMessage: '$e'));
    }
  }

  /// Toggles radio enabled.
  Future<void> toggleEnabled() => setEnabled(enabled: !state.status.enabled);
}
