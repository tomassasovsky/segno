import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:segno_engine/segno_engine.dart' show VolumeSpace;
import 'package:storage_repository/src/models/conflict_policy.dart';
import 'package:storage_repository/src/models/eject_outcome.dart';
import 'package:storage_repository/src/models/removable_volume.dart';
import 'package:storage_repository/src/models/storage_destination.dart';
import 'package:storage_repository/src/models/storage_failure.dart';
import 'package:storage_repository/src/write_lease.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// Copies [source] into [part] (created or truncated) and fsyncs it, so the
/// bytes are on the device before the rename publishes the file. Polls
/// [shouldAbort] between writes and throws a [FileSystemException] when it
/// returns true. Injected by tests to fail a copy midway.
typedef CopyBytes =
    Future<void> Function(
      File source,
      File part,
      bool Function() shouldAbort,
    );

/// The one owner of where a write may go: Internal and removable volumes,
/// their capacity, who is writing, whether a drive may be ejected, and a copy
/// that leaves existing content intact on every failure (#1177).
///
/// Nothing here forks the app (#806): volumes come from the USB client's
/// inotify watch, capacity from the engine's `statvfs`, eject from a request
/// file the image's helper serves.
class StorageRepository {
  /// Creates a [StorageRepository].
  ///
  /// [exportsRoot] is the resolver the performance repository is wired with:
  /// Internal is measured there and Internal copies land under it.
  /// [volumeSpace] is the engine's `statvfs` (synchronous, microseconds on a
  /// local volume; null when the path cannot be measured).
  StorageRepository({
    required UsbStorageClient client,
    required Future<String> Function() exportsRoot,
    required VolumeSpace? Function(String path) volumeSpace,
    this.ejectTimeout = const Duration(seconds: 20),
    this.volumeLossGrace = const Duration(seconds: 2),
    @visibleForTesting CopyBytes? copyBytes,
  }) : _client = client,
       _exportsRoot = exportsRoot,
       _volumeSpace = volumeSpace,
       _copyBytes = copyBytes ?? _copyChunks {
    _subscription = _client.volumes.listen(_onRecords);
  }

  /// Space kept free on Internal so the system, the session store and Undo
  /// audio never run out behind a recording (accepted behaviour §6.7; the
  /// Storage page's "Internal storage · 1.0 GB reserved").
  static const int internalReserveBytes = 1 << 30;

  /// How long an eject request may go unanswered before it is withdrawn and
  /// reported as `EjectOutcome.failed('timeout')`.
  final Duration ejectTimeout;

  /// How long a copy that failed the way a pulled drive fails (EIO, ENOENT,
  /// ENODEV, ENXIO) waits for the drive's record to disappear before calling
  /// it an I/O error rather than a lost volume. The write fails the moment
  /// the drive goes; the helper's record goes a moment later.
  final Duration volumeLossGrace;

  final UsbStorageClient _client;
  final Future<String> Function() _exportsRoot;
  final VolumeSpace? Function(String path) _volumeSpace;
  final CopyBytes _copyBytes;

  late final StreamSubscription<List<RemovableVolumeRecord>> _subscription;
  final _volumeListeners = <StreamController<List<RemovableVolume>>>{};
  final _phaseListeners = <StreamController<EjectPhase>>{};
  final _leases = <WriteLease>[];
  Map<int, RemovableVolumeRecord> _records = const {};
  _Eject? _eject;

  /// Whether this build can see removable volumes at all (the appliance image
  /// with the helper). When false, [volumes] stays empty and the UI says "USB
  /// unavailable" rather than "no drive".
  bool get isRemovableSupported => _client.isSupported;

  // ---- volumes -------------------------------------------------------------

  /// The removable volumes: the current list for each new listener, then
  /// every change (a plug, an unplug, a probe landing, an eject served).
  /// Sorted by generation. An ejected volume stays listed until it is pulled,
  /// so "Safe to remove" can be drawn.
  Stream<List<RemovableVolume>> get volumes =>
      _replaying(_volumeListeners, () => current);

  /// The volumes as of the last change.
  List<RemovableVolume> get current => [
    for (final record in _records.values)
      RemovableVolume.fromRecord(
        record,
        ejecting: _eject?.generation == record.generation,
      ),
  ];

  /// Whether an eject is in flight: the current phase for each new listener,
  /// then every change.
  Stream<EjectPhase> get ejectPhase => _replaying(_phaseListeners, _phase);

  EjectPhase _phase() => _eject == null ? EjectPhase.idle : EjectPhase.ejecting;

  // One controller per listener, seeded inside onListen: nothing that
  // happens between subscribing and the first event can be missed.
  static Stream<T> _replaying<T>(
    Set<StreamController<T>> listeners,
    T Function() now,
  ) {
    late final StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        listeners.add(controller);
        controller.add(now());
      },
      onCancel: () {
        listeners.remove(controller);
      },
    );
    return controller.stream;
  }

  void _onRecords(List<RemovableVolumeRecord> records) {
    final next = {for (final record in records) record.generation: record};
    for (final lease in List.of(_leases)) {
      final target = lease.target;
      if (target is RemovableDestination &&
          !next.containsKey(target.generation)) {
        lease.markLost(StorageFailure.volumeLost(target.generation));
      }
    }
    _records = next;
    _settleEject();
    _publishVolumes();
  }

  void _publishVolumes() {
    final list = current;
    for (final listener in _volumeListeners) {
      listener.add(list);
    }
  }

  void _publishPhase() {
    final phase = _phase();
    for (final listener in _phaseListeners) {
      listener.add(phase);
    }
  }

  // ---- leases --------------------------------------------------------------

  /// The leases currently held, in the order they were taken.
  List<WriteLease> get leases => List.unmodifiable(_leases);

  /// The leases held on [destination].
  List<WriteLease> leasesOn(StorageDestination destination) => [
    for (final lease in _leases)
      if (lease.target == destination) lease,
  ];

  /// Whether a write or an eject is in progress (shutdown's guard, §7.8).
  bool get transferInFlight => _leases.isNotEmpty || _eject != null;

  /// Takes a hold on [destination] for [purpose]. Throws the
  /// [StorageFailure] a write there would meet: `readOnly`, `unsupported`, or
  /// `volumeLost` for a generation that is not present, is being ejected or
  /// has been ejected.
  WriteLease acquire(StorageDestination destination, String purpose) {
    if (destination is RemovableDestination) {
      _checkWritable(destination.generation);
    }
    final lease = WriteLease(
      target: destination,
      purpose: purpose,
      onRelease: _leases.remove,
    );
    _leases.add(lease);
    return lease;
  }

  /// Runs [body] under a lease on [target] for [purpose], with the
  /// destination's root (the exports root for Internal, the mount point for a
  /// volume), and releases the lease afterwards. Completes with
  /// [StorageFailure.volumeLost] as soon as the volume goes away, even if
  /// [body] is still running; [body]'s own writes then fail on their own.
  Future<T> withWriteLease<T>(
    StorageDestination target,
    String purpose,
    Future<T> Function(String root) body,
  ) async {
    final lease = acquire(target, purpose);
    try {
      final root = await _writeRoot(target);
      return await Future.any([
        body(root),
        lease.lost.then<T>((failure) => throw failure),
      ]);
    } finally {
      lease.release();
    }
  }

  void _checkWritable(int generation) {
    final record = _records[generation];
    if (record == null || _eject?.generation == generation) {
      throw StorageFailure.volumeLost(generation);
    }
    switch (record.status) {
      case RemovableVolumeRecordStatus.mounted:
        if (record.mountPoint != null) return;
        throw const StorageFailure.unsupported();
      case RemovableVolumeRecordStatus.readOnly:
        throw const StorageFailure.readOnly();
      case RemovableVolumeRecordStatus.unsupported:
      case RemovableVolumeRecordStatus.mountFailed:
        throw const StorageFailure.unsupported();
      case RemovableVolumeRecordStatus.ejected:
        throw StorageFailure.volumeLost(generation);
    }
  }

  /// Where writes to [destination] go; only called once a lease holds it.
  Future<String> _writeRoot(StorageDestination destination) async {
    return switch (destination) {
      InternalDestination() => await _exportsRoot(),
      RemovableDestination(:final generation) =>
        _records[generation]!.mountPoint!,
    };
  }

  // ---- eject ---------------------------------------------------------------

  /// Ejects [generation].
  ///
  /// Refused with [EjectRefused] while any lease holds the volume, before any
  /// request is written, and with a [StateError] while another eject is in
  /// flight. Otherwise files the request, reports [EjectPhase.ejecting], and
  /// completes with the outcome: safe to remove once the helper reports the
  /// volume ejected; failed with the helper's reason (`busy`, `error`), with
  /// `removed` if the drive is pulled first, or with `timeout` after
  /// [ejectTimeout], in which case the request is withdrawn; cancelled
  /// through [cancelEject].
  Future<EjectOutcome> eject(int generation) async {
    final holders = leasesOn(StorageDestination.removable(generation));
    if (holders.isNotEmpty) throw EjectRefused(holders);
    if (_eject != null) throw StateError('an eject is already in flight');
    if (!_records.containsKey(generation)) {
      return const EjectOutcome.failed('removed');
    }
    final eject = _Eject(generation, _client.requestEject(generation));
    _eject = eject;
    _publishPhase();
    _publishVolumes();
    try {
      eject.requestId = await eject.request;
      _settleEject();
      return await eject.outcome.future.timeout(
        ejectTimeout,
        onTimeout: () async {
          await _client.cancelEject(eject.requestId!);
          return const EjectOutcome.failed('timeout');
        },
      );
    } finally {
      _eject = null;
      _publishPhase();
      _publishVolumes();
    }
  }

  /// Withdraws the eject in flight if the helper has not served it yet; the
  /// eject then completes cancelled. A no-op when nothing is in flight. A
  /// request the helper already served cannot be withdrawn: the volume's
  /// status then says what happened.
  Future<void> cancelEject() async {
    final eject = _eject;
    if (eject == null) return;
    await _client.cancelEject(await eject.request);
    if (!eject.outcome.isCompleted) {
      eject.outcome.complete(const EjectOutcome.cancelled());
    }
  }

  void _settleEject() {
    final eject = _eject;
    if (eject == null || eject.requestId == null) return;
    if (eject.outcome.isCompleted) return;
    final record = _records[eject.generation];
    if (record == null) {
      eject.outcome.complete(const EjectOutcome.failed('removed'));
      return;
    }
    final answer = record.eject;
    if (answer == null || answer.request != eject.requestId) return;
    eject.outcome.complete(
      answer.ok
          ? const EjectOutcome.safeToRemove()
          : EjectOutcome.failed(answer.reason ?? 'error'),
    );
  }

  // ---- capacity ------------------------------------------------------------

  /// Total and free bytes of [destination]'s volume, or null when it cannot
  /// be measured: a removable volume that is not mounted (absent, ejected,
  /// unsupported) or a path the engine cannot answer for. No reserve is
  /// applied here.
  Future<VolumeSpace?> space(StorageDestination destination) async {
    final path = switch (destination) {
      InternalDestination() => _nearestExisting(await _exportsRoot()),
      RemovableDestination(:final generation) => _mountedPath(generation),
    };
    return path == null ? null : _volumeSpace(path);
  }

  /// How long a recording at [bytesPerSecond] fits on [destination]: free
  /// space less [internalReserveBytes] on Internal, free space as is on a
  /// removable volume, never below zero. Null when the space is unknown:
  /// unknown capacity cannot claim available time (§6.7).
  Future<Duration?> recordingTimeRemaining(
    StorageDestination destination,
    int bytesPerSecond,
  ) async {
    if (bytesPerSecond <= 0) {
      throw ArgumentError.value(bytesPerSecond, 'bytesPerSecond');
    }
    final measured = await space(destination);
    if (measured == null) return null;
    final reserve = destination is InternalDestination
        ? internalReserveBytes
        : 0;
    final usable = measured.freeBytes - reserve;
    return Duration(seconds: usable < 0 ? 0 : usable ~/ bytesPerSecond);
  }

  /// Whether Internal has less free space than [internalReserveBytes]. False
  /// when Internal cannot be measured: unknown is not full.
  Future<bool> lowInternalSpace() async {
    final measured = await space(const StorageDestination.internal());
    return measured != null && measured.freeBytes < internalReserveBytes;
  }

  String? _mountedPath(int generation) {
    final record = _records[generation];
    return switch (record?.status) {
      RemovableVolumeRecordStatus.mounted ||
      RemovableVolumeRecordStatus.readOnly => record!.mountPoint,
      _ => null,
    };
  }

  // statvfs needs a path that exists, and the exports root does not exist
  // before the first capture; the volume is the same one level up.
  static String _nearestExisting(String path) {
    var dir = Directory(path);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return dir.path;
  }

  // ---- copy ----------------------------------------------------------------

  /// Copies the file at [sourcePath] to `<root>/<relativePath>` on
  /// [destination], where the root is the exports root for Internal and the
  /// mount point for a removable volume, and returns the path written.
  ///
  /// The bytes go to `<name>.part`, are fsynced, and only then renamed to the
  /// final name, so the destination never holds a half-written file under
  /// that name; on any failure the part is deleted and the source is not
  /// touched. A name already there is handled per [onConflict]: `ask` throws
  /// [NameConflict] before writing anything, `keepBoth` writes `name (2).ext`
  /// (then ` (3)`, ...), `replace` renames over it. Failures are typed
  /// [StorageFailure]s: `full` (ENOSPC), `readOnly` (EROFS, or a read-only
  /// volume), `volumeLost` when the volume goes away before or during the
  /// copy, `unsupported` for a volume that cannot be written, `io` for the
  /// rest. A lease with purpose `copy` is held throughout, so eject and
  /// shutdown wait for it.
  ///
  /// [relativePath] must stay inside the root: not empty, not absolute, and
  /// with no empty, `.` or `..` segment.
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  }) async {
    final segments = relativePath.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'must be a relative path inside the destination',
      );
    }
    final lease = acquire(destination, 'copy');
    try {
      final target = _resolveTarget(
        '${await _writeRoot(destination)}/$relativePath',
        onConflict,
      );
      final part = File('$target.part');
      try {
        part.parent.createSync(recursive: true);
        await _copyBytes(File(sourcePath), part, () => lease.isLost);
        if (lease.isLost) throw const FileSystemException('volume lost');
        part.renameSync(target);
        return target;
      } on FileSystemException catch (e) {
        _discard(part);
        throw await _classify(e, destination, lease);
      }
    } finally {
      lease.release();
    }
  }

  static String _resolveTarget(String path, ConflictPolicy onConflict) {
    if (!File(path).existsSync()) return path;
    switch (onConflict) {
      case ConflictPolicy.ask:
        throw NameConflict(path);
      case ConflictPolicy.replace:
        return path;
      case ConflictPolicy.keepBoth:
        final slash = path.lastIndexOf('/');
        final dot = path.lastIndexOf('.');
        // `.hidden` and `name` have no extension; `take.wav` does.
        final split = dot > slash + 1 ? dot : path.length;
        final stem = path.substring(0, split);
        final extension = path.substring(split);
        for (var n = 2; ; n++) {
          final candidate = '$stem ($n)$extension';
          if (!File(candidate).existsSync()) return candidate;
        }
    }
  }

  // The errors a write meets when the drive under it is pulled.
  static const _pulledDriveErrors = {
    2, // ENOENT: the mount point is gone
    5, // EIO
    6, // ENXIO
    19, // ENODEV
  };

  Future<StorageFailure> _classify(
    FileSystemException e,
    StorageDestination destination,
    WriteLease lease,
  ) async {
    final code = e.osError?.errorCode;
    if (destination is RemovableDestination &&
        (lease.isLost ||
            (_pulledDriveErrors.contains(code) && await _lostSoon(lease)))) {
      return StorageFailure.volumeLost(destination.generation);
    }
    return switch (code) {
      28 => const StorageFailure.full(), // ENOSPC
      30 => const StorageFailure.readOnly(), // EROFS
      _ => StorageFailure.io(e.osError?.message ?? e.message),
    };
  }

  Future<bool> _lostSoon(WriteLease lease) => lease.lost
      .then((_) => true)
      .timeout(volumeLossGrace, onTimeout: () => false);

  static void _discard(File part) {
    try {
      part.deleteSync();
    } on FileSystemException {
      // Never created, or gone with the drive: nothing partial is left.
    }
  }

  static Future<void> _copyChunks(
    File source,
    File part,
    bool Function() shouldAbort,
  ) async {
    final out = await part.open(mode: FileMode.write);
    try {
      await for (final chunk in source.openRead()) {
        if (shouldAbort()) throw const FileSystemException('volume lost');
        await out.writeFrom(chunk);
      }
      await out.flush();
    } finally {
      await out.close();
    }
  }

  // ---- lifetime ------------------------------------------------------------

  /// Stops listening to the client and ends every stream. Held leases are
  /// left to their holders.
  Future<void> dispose() async {
    await _subscription.cancel();
    for (final listener in [..._volumeListeners, ..._phaseListeners]) {
      await listener.close();
    }
  }
}

/// One eject in flight.
class _Eject {
  _Eject(this.generation, this.request);

  final int generation;

  /// The request being filed; its id, once known, is [requestId].
  final Future<String> request;
  String? requestId;
  final outcome = Completer<EjectOutcome>();
}
