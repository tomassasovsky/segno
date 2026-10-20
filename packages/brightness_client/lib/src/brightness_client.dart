/// I/O boundary for appliance display brightness (`segno-brightness-ctl`).
///
/// Every call names the display by its DRM connector (`HDMI-A-1`), so a
/// change reaches that panel and no other.
abstract class BrightnessClient {
  /// Whether the panel on [connector] takes brightness over DDC/CI.
  Future<bool> isSupported(String connector);

  /// Sets the panel on [connector] to [value] in `0..1` (no-op when
  /// unsupported).
  Future<void> set(String connector, double value);
}

/// No-op client used on desktop / when the helper is absent.
class UnsupportedBrightnessClient implements BrightnessClient {
  /// Creates an [UnsupportedBrightnessClient].
  const UnsupportedBrightnessClient();

  @override
  Future<bool> isSupported(String connector) async => false;

  @override
  Future<void> set(String connector, double value) async {}
}
