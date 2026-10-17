part of 'wifi_cubit.dart';

/// State for [WifiCubit].
class WifiState extends Equatable {
  /// Creates a [WifiState].
  const WifiState({
    this.supported = false,
    this.status = WifiStatus.unsupported,
    this.networks = const [],
    this.scanning = false,
    this.busy = false,
    this.connectingSsid,
    this.retrying = false,
    this.disconnecting = false,
    this.errorMessage,
    this.errorKind,
    this.failedSsid,
    this.leftSsid,
    this.internet,
  });

  /// Whether the appliance WiFi helper is available.
  final bool supported;

  /// Latest association status.
  final WifiStatus status;

  /// Last scan results.
  final List<WifiNetwork> networks;

  /// True while a scan is in flight.
  final bool scanning;

  /// True while connect/disconnect/forget/load/radio is in flight.
  final bool busy;

  /// SSID currently being joined, if any.
  final String? connectingSsid;

  /// True while [connectingSsid] is a bounded re-activation after a
  /// backend/transient failure, so the page can say "retrying" instead of
  /// pretending this is a first attempt (#829).
  final bool retrying;

  /// True while disconnect (or forget-of-active) is in flight.
  final bool disconnecting;

  /// Last error message, if any.
  final String? errorMessage;

  /// How the failure behind [errorMessage] classified — credentials versus
  /// backend/transient — so the UI never presents an iwd race as a wrong
  /// password (#824, #829). Null for non-join errors; cleared with the
  /// message.
  final WifiJoinErrorKind? errorKind;

  /// The SSID [errorMessage] is about.
  ///
  /// Tied to the error rather than kept beside it, so a stale SSID can never
  /// outlive the message that named it — a failure naming the wrong network
  /// is worse than none.
  final String? failedSsid;

  /// The network the musician left on purpose (Disconnect, or the radio
  /// switch), which is therefore not [lostSsid]. Cleared by any connection.
  final String? leftSsid;

  /// The last internet check: the connection it was made over and whether the
  /// internet answered. Null until one has run.
  final ({String ssid, bool online})? internet;

  /// The network the console dropped without being asked to: the saved
  /// network that was active last, while the radio is on and nothing is
  /// associated or joining. Null otherwise.
  String? get lostSsid {
    final last = status.lastSsid;
    if (!supported || !status.enabled || status.connected) return null;
    if (connectingSsid != null || last.isEmpty || last == leftSsid) {
      return null;
    }
    return status.autoConnect.containsKey(last) ? last : null;
  }

  /// Whether the connection is up but the last check of it found no internet.
  bool get noInternet {
    final check = internet;
    return status.connected &&
        check != null &&
        check.ssid == status.ssid &&
        !check.online;
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// A status that is connected clears [leftSsid]: once the console is on a
  /// network again, the next drop is a loss whatever came before.
  WifiState copyWith({
    bool? supported,
    WifiStatus? status,
    List<WifiNetwork>? networks,
    bool? scanning,
    bool? busy,
    String? connectingSsid,
    bool? retrying,
    bool? disconnecting,
    String? errorMessage,
    WifiJoinErrorKind? errorKind,
    String? failedSsid,
    String? leftSsid,
    ({String ssid, bool online})? internet,
    bool clearError = false,
    bool clearConnectingSsid = false,
  }) {
    final nextStatus = status ?? this.status;
    return WifiState(
      supported: supported ?? this.supported,
      status: nextStatus,
      networks: networks ?? this.networks,
      scanning: scanning ?? this.scanning,
      busy: busy ?? this.busy,
      connectingSsid: clearConnectingSsid
          ? null
          : (connectingSsid ?? this.connectingSsid),
      // Retrying describes an in-flight join; it cannot outlive the marker.
      retrying: !clearConnectingSsid && (retrying ?? this.retrying),
      disconnecting: disconnecting ?? this.disconnecting,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      errorKind: clearError ? null : (errorKind ?? this.errorKind),
      failedSsid: clearError ? null : (failedSsid ?? this.failedSsid),
      leftSsid: nextStatus.connected ? null : (leftSsid ?? this.leftSsid),
      internet: internet ?? this.internet,
    );
  }

  @override
  List<Object?> get props => [
    supported,
    status,
    networks,
    scanning,
    busy,
    connectingSsid,
    retrying,
    disconnecting,
    errorMessage,
    errorKind,
    failedSsid,
    leftSsid,
    internet,
  ];
}
