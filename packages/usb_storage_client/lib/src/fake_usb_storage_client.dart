import 'dart:async';

import 'package:usb_storage_client/src/removable_volume_record.dart';
import 'package:usb_storage_client/src/usb_storage_client.dart';

/// An in-memory [UsbStorageClient] for the desktop build
/// (`--dart-define=SEGNO_FAKE_RADIOS=true`) and for tests.
///
/// Tests and the fake appliance drive it the way the helper would: [attach]
/// a record (a plug), [update] it (the write probe landing), [settleEject] a
/// request (the eject served), [detach] it (the unplug). Request ids are
/// `req-1`, `req-2`, … so a test can name the outcome it settles.
class FakeUsbStorageClient implements UsbStorageClient {
  /// Creates a [FakeUsbStorageClient], optionally with [initial] volumes.
  FakeUsbStorageClient({
    List<RemovableVolumeRecord> initial = const [],
    this.isSupported = true,
  }) {
    for (final record in initial) {
      _volumes[record.generation] = record;
    }
  }

  @override
  final bool isSupported;

  final _volumes = <int, RemovableVolumeRecord>{};
  final _controller = StreamController<List<RemovableVolumeRecord>>.broadcast();
  final _pending = <String, int>{};
  final _taken = <String, int>{};
  var _nextRequest = 0;

  /// Eject requests filed and not yet settled or cancelled, by request id,
  /// to the generation each names.
  Map<String, int> get pendingRequests => Map.unmodifiable(_pending);

  @override
  Stream<List<RemovableVolumeRecord>> get volumes async* {
    yield _snapshot();
    yield* _controller.stream;
  }

  /// A drive was plugged in (or the helper rewrote its record): adds or
  /// replaces the record for its generation.
  void attach(RemovableVolumeRecord record) {
    _volumes[record.generation] = record;
    _emit();
  }

  /// Same as [attach]; reads better at call sites that change an existing
  /// record (the probe landing, a status change).
  void update(RemovableVolumeRecord record) => attach(record);

  /// The drive was unplugged: the helper deleted its file.
  void detach(int generation) {
    _volumes.remove(generation);
    _emit();
  }

  /// The helper took the eject request [requestId] off the queue and is
  /// working on it (syncing, unmounting): it can no longer be withdrawn, and
  /// its answer comes later through [settleEject].
  void take(String requestId) {
    final generation = _pending.remove(requestId);
    if (generation != null) _taken[requestId] = generation;
  }

  /// The helper served the eject request [requestId]: on success the record
  /// reads ejected with the outcome; on failure it keeps its status and
  /// carries the outcome's [reason]. A request for a generation that is gone
  /// is dropped silently, as the helper does.
  void settleEject(String requestId, {required bool ok, String? reason}) {
    final generation = _pending.remove(requestId) ?? _taken.remove(requestId);
    if (generation == null) return;
    final record = _volumes[generation];
    if (record == null) return;
    _volumes[generation] = RemovableVolumeRecord(
      generation: record.generation,
      kname: record.kname,
      fingerprint: record.fingerprint,
      label: record.label,
      fsType: record.fsType,
      mountPoint: record.mountPoint,
      sizeBytes: record.sizeBytes,
      status: ok ? RemovableVolumeRecordStatus.ejected : record.status,
      readOnly: record.readOnly,
      writeBytesPerSecond: record.writeBytesPerSecond,
      failureReason: record.failureReason,
      eject: EjectOutcomeRecord(request: requestId, ok: ok, reason: reason),
    );
    _emit();
  }

  @override
  Future<String> requestEject(int generation) async {
    final id = 'req-${++_nextRequest}';
    _pending[id] = generation;
    return id;
  }

  @override
  Future<bool> cancelEject(String requestId) async =>
      _pending.remove(requestId) != null;

  List<RemovableVolumeRecord> _snapshot() {
    final list = _volumes.values.toList()
      ..sort((a, b) => a.generation.compareTo(b.generation));
    return List.unmodifiable(list);
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(_snapshot());
  }

  /// Closes the stream; the fake is not reusable afterwards.
  Future<void> dispose() => _controller.close();
}
