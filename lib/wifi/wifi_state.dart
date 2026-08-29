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
  /// backend/transient failure, so the banner can say "retrying" instead of
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
  /// outlive the message that named it — the failure banner says which network
  /// refused, and a banner naming the wrong one is worse than no banner.
  final String? failedSsid;

  /// Returns a copy with the given fields replaced.
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
    bool clearError = false,
    bool clearConnectingSsid = false,
  }) => WifiState(
    supported: supported ?? this.supported,
    status: status ?? this.status,
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
  );

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
  ];
}
