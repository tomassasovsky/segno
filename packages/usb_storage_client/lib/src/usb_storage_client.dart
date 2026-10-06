import 'package:usb_storage_client/src/removable_volume_record.dart';

/// What the app can ask about removable USB volumes, and the one thing it can
/// ask for.
///
/// Narrow on purpose: the OS owns detection, mounting and unmounting
/// (`segno-usb-ctl` in the appliance image). This client only reads what the
/// helper wrote and files eject requests for it to serve. Capacity, leases and
/// eject policy live in the storage repository above this.
abstract interface class UsbStorageClient {
  /// Whether this build can see the helper's state at all.
  ///
  /// `false` on a desktop, and on an appliance image that predates the helper:
  /// then [volumes] is one empty list and the storage repository says "USB
  /// unavailable" rather than "no drive".
  bool get isSupported;

  /// The volumes the helper currently describes, replayed to every new
  /// listener and then updated on each change. Sorted by generation. An
  /// unsupported build emits one empty list and completes.
  Stream<List<RemovableVolumeRecord>> get volumes;

  /// Files an eject request for [generation] and returns its id.
  ///
  /// The outcome arrives through [volumes]: the record's
  /// [RemovableVolumeRecord.eject] names this id with `ok` and a reason, and on
  /// success the status reads [RemovableVolumeRecordStatus.ejected].
  Future<String> requestEject(int generation);

  /// Withdraws an eject request that the helper has not served yet. A request
  /// already served (its file gone) is left alone; this never throws for it.
  Future<void> cancelEject(String requestId);
}
