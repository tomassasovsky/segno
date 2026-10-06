import 'package:usb_storage_client/src/removable_volume_record.dart';
import 'package:usb_storage_client/src/usb_storage_client.dart';

/// What a build with no helper answers: no volumes, honestly.
///
/// The correct answer for a desktop build and for an appliance image that
/// predates the helper; the storage repository shows "USB unavailable" for it
/// rather than "no drive".
class UnsupportedUsbStorageClient implements UsbStorageClient {
  /// Creates an [UnsupportedUsbStorageClient].
  const UnsupportedUsbStorageClient();

  @override
  bool get isSupported => false;

  @override
  Stream<List<RemovableVolumeRecord>> get volumes => Stream.value(const []);

  @override
  Future<String> requestEject(int generation) async =>
      throw UnsupportedError('no USB storage helper on this build');

  @override
  Future<void> cancelEject(String requestId) async {}
}
