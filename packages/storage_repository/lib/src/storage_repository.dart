import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno_engine/segno_engine.dart' show VolumeSpace;
import 'package:segno_engine/segno_engine.dart'
    as engine
    show NativeStorageIo, RenameOutcome, StorageIo;
import 'package:storage_repository/src/models/conflict_policy.dart';
import 'package:storage_repository/src/models/eject_outcome.dart';
import 'package:storage_repository/src/models/removable_volume.dart';
import 'package:storage_repository/src/models/storage_destination.dart';
import 'package:storage_repository/src/models/storage_failure.dart';
import 'package:storage_repository/src/write_lease.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// Copies [source] into [part] (created or truncated) and fsyncs it, so the
/// bytes are on the device before the rename publishes the file. Polls
/// [shouldAbort] before every write and throws a [FileSystemException] when it
/// returns true. A failure to open or read the SOURCE is thrown as a
/// [SourceReadFailure], so it is never blamed on the destination. The default
/// is [StorageRepository.copyChunks]; tests inject failures through it.
typedef CopyBytes =
    Future<void> Function(
      File source,
      File part,
      bool Function() shouldAbort,
    );

/// The source of a copy could not be opened or read. Nothing about the
/// destination is implied: the copy reports it as `StorageFailure.io` at
/// once, without waiting to see whether a drive went away.
class SourceReadFailure implements Exception {
  /// Creates a [SourceReadFailure] for [cause].
  const SourceReadFailure(this.cause);

  /// What the read met.
  final FileSystemException cause;

  @override
  String toString() => 'cannot read the source: ${cause.message}';
}

/// The one owner of where a write may go: Internal and removable volumes,
/// their capacity, who is writing, whether a drive may be ejected, and a copy
/// that leaves existing content intact on every failure (#1177).
///
/// Nothing here forks the app (#806): volumes come from the USB client's
/// inotify watch, capacity from the engine's `statvfs`, eject from a request
/// file the image's helper serves.
///
/// It is one owner of the app's guard table (accepted behaviour 6.12, #1221):
/// [acquire] and [eject] check the table at their commit, and the leases and
/// the eject in flight are reported to it as [activeOperations], so a session
/// apply, a shutdown or a take sees them at its own commit. A `recording`
/// lease is the exception on both counts: the take's commit is the
/// performance repository's `capture` guard, scoped to the same volume, and
/// reporting the lease as well would make the take refuse itself.
class StorageRepository implements ActiveOperationSource {
  /// Creates a [StorageRepository].
  ///
  /// [exportsRoot] is the resolver the performance repository is wired with:
  /// Internal is measured there and Internal copies land under it.
  /// [volumeSpace] is the engine's `statvfs` (synchronous, microseconds on a
  /// local volume; null when the path cannot be measured). [storageIo] is
  /// the engine's durable-publication primitives (#1198): a rename that never
  /// replaces and a directory sync, both things Dart cannot do itself (see
  /// [copyFile]). It defaults to the engine's own, opened on the first copy,
  /// so watching and measuring drives never needs the native library.
  /// [guards] is the app's one guard table; null checks nothing but this
  /// repository's own leases (a build or a test without the table).
  StorageRepository({
    required UsbStorageClient client,
    required Future<String> Function() exportsRoot,
    required VolumeSpace? Function(String path) volumeSpace,
    engine.StorageIo? storageIo,
    GuardRegistry? guards,
    this.ejectTimeout = const Duration(seconds: 20),
    this.ejectServedTimeout = const Duration(minutes: 2),
    this.volumeLossGrace = const Duration(seconds: 10),
    @visibleForTesting CopyBytes? copyBytes,
  }) : _client = client,
       _exportsRoot = exportsRoot,
       _volumeSpace = volumeSpace,
       _storageIo = storageIo,
       _guards = guards,
       _copyBytes = copyBytes ?? copyChunks {
    _subscription = _client.volumes.listen(_onRecords);
  }

  /// Space kept free on Internal so the system, the session store and Undo
  /// audio never run out behind a recording: accepted behaviour §6.7's "1 GB
  /// reserve", and the Storage page's "Internal storage · 1.0 GB reserved".
  /// Decimal, like every figure the page prints: a 1 GiB reserve would read
  /// "1.1 GB reserved", and the pen's 64.0 GB free would not come to its
  /// 60 hr 45 min at 48 kHz 24-bit stereo.
  static const int internalReserveBytes = 1000000000;

  /// How long an eject request may wait for the helper to take it. If it is
  /// still waiting then, it is withdrawn and the eject fails with `timeout`.
  final Duration ejectTimeout;

  /// How long an eject the helper has already taken may take to answer. The
  /// helper syncs and unmounts after it takes a request, and on a slow stick,
  /// or behind another drive's work, that can outlast [ejectTimeout]; the
  /// eject stays in flight (the volume reads `ejecting`) rather than being
  /// reported failed while the drive is about to be ejected anyway.
  final Duration ejectServedTimeout;

  /// How long a copy that failed the way a pulled drive fails (EIO, ENOENT,
  /// ENODEV, ENXIO on the destination) waits for the drive's record to go
  /// before calling it an I/O error rather than a lost volume. The write
  /// fails the moment the drive goes; the helper removes the record when its
  /// detach runs, which can queue behind another drive's attach.
  final Duration volumeLossGrace;

  final UsbStorageClient _client;
  final Future<String> Function() _exportsRoot;
  final VolumeSpace? Function(String path) _volumeSpace;
  engine.StorageIo? _storageIo;
  engine.StorageIo get _io => _storageIo ??= engine.NativeStorageIo();
  final GuardRegistry? _guards;
  final CopyBytes _copyBytes;

  late final StreamSubscription<List<RemovableVolumeRecord>> _subscription;
  final _volumeListeners = <StreamController<List<RemovableVolume>>>{};
  final _phaseListeners = <StreamController<EjectPhase>>{};
  final _leases = <HeldLease>[];
  final _liveParts = <String>{};
  final _sweptDirectories = <String>{};
  final _unanswered = <int, String>{};
  final _random = Random.secure();
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
        ejecting: _ejecting(record.generation),
      ),
  ];

  // In flight now, or taken by the helper and still unanswered after the
  // eject gave up waiting: either way the drive may be unmounting.
  bool _ejecting(int generation) =>
      _eject?.generation == generation || _unanswered.containsKey(generation);

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
    // A lease holds only a volume that can take its writes: one that is gone,
    // and one that has been ejected (its mount point is then a bare directory
    // on the tmpfs until the drive is pulled), both fail it.
    for (final held in List.of(_leases)) {
      final target = held.target;
      if (target is RemovableDestination &&
          next[target.generation]?.status !=
              RemovableVolumeRecordStatus.mounted) {
        held.markLost(StorageFailure.volumeLost(target.generation));
      }
    }
    _records = next;
    // A taken eject that outlived the wait is over once the drive answers
    // (its record names the request, or turns ejected) or goes.
    _unanswered.removeWhere((generation, request) {
      final record = next[generation];
      return record == null ||
          record.eject?.request == request ||
          record.status == RemovableVolumeRecordStatus.ejected;
    });
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
  List<WriteLease> get leases => [for (final held in _leases) held.lease];

  /// The leases held on [destination].
  List<WriteLease> leasesOn(StorageDestination destination) => [
    for (final held in _leases)
      if (held.target == destination) held.lease,
  ];

  /// Whether a write or an eject is in progress (shutdown's guard, §7.8).
  bool get transferInFlight =>
      _leases.isNotEmpty || _eject != null || _unanswered.isNotEmpty;

  /// Takes a hold on [destination] for [purpose]. Throws the
  /// [StorageFailure] a write there would meet: `readOnly`, `unsupported`, or
  /// `volumeLost` for a generation that is not present, is being ejected or
  /// has been ejected; and [GuardRefused] when the guard table forbids a
  /// `transfer` there now (a take on that volume, a shutdown).
  ///
  /// The table is checked here, at the commit, and the lease itself is then
  /// reported through [activeOperations] for as long as it is held. A
  /// `recording` lease is not checked or reported (see the class note).
  HeldLease acquire(StorageDestination destination, WritePurpose purpose) {
    if (destination is RemovableDestination) {
      _checkWritable(destination.generation);
    }
    if (purpose != WritePurpose.recording) {
      _guards
          ?.enter(
            GuardKind.transfer,
            _scopeOf(destination),
            purpose: purpose.name,
          )
          .release();
    }
    final held = HeldLease(
      WriteLease(target: destination, purpose: purpose),
      onRelease: _leases.remove,
    );
    _leases.add(held);
    return held;
  }

  /// Runs [body] under a lease on [target] for [purpose], with the
  /// destination's root (the exports root for Internal, the mount point for a
  /// volume), and releases the lease afterwards. Completes with
  /// [StorageFailure.volumeLost] as soon as the volume goes away, even if
  /// [body] is still running; [body]'s own writes then fail on their own, so
  /// a body must stop at its first failure rather than recreate directories.
  Future<T> withWriteLease<T>(
    StorageDestination target,
    WritePurpose purpose,
    Future<T> Function(String root) body,
  ) async {
    final held = acquire(target, purpose);
    try {
      final root = await _writeRoot(target);
      return await Future.any([
        body(root),
        held.lost.then<T>((failure) => throw failure),
      ]);
    } finally {
      held.release();
    }
  }

  void _checkWritable(int generation) {
    final record = _records[generation];
    if (record == null || _ejecting(generation)) {
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

  bool _writable(int generation) {
    try {
      _checkWritable(generation);
      return true;
    } on StorageFailure {
      return false;
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
  /// `removed` if the drive is pulled first, with `error` if the request
  /// could not be filed, or with `timeout`; cancelled through [cancelEject].
  ///
  /// `timeout` is reported only when nothing is ejecting the drive: after
  /// [ejectTimeout] a request the helper has not taken is withdrawn and the
  /// eject fails. One the helper has taken cannot be withdrawn (it is already
  /// syncing and unmounting), so the eject stays in flight until the helper
  /// answers, for [ejectServedTimeout] at most. Past that it completes
  /// [stillEjecting], and the drive goes on reading `ejecting` (no lease can
  /// start on it, shutdown waits) until the helper answers or the drive is
  /// pulled: the unmount may still finish, and a writer let in meanwhile
  /// would write into the bare mount point. Ejecting it again before then
  /// also answers [stillEjecting].
  ///
  /// Throws [GuardRefused] when the guard table forbids an eject of this
  /// volume now (a take or a copy on it that holds no lease here, a
  /// shutdown); the eject in flight is then reported through
  /// [activeOperations].
  Future<EjectOutcome> eject(int generation) async {
    final holders = leasesOn(StorageDestination.removable(generation));
    if (holders.isNotEmpty) throw EjectRefused(holders);
    if (_eject != null) throw StateError('an eject is already in flight');
    if (!_records.containsKey(generation)) {
      return const EjectOutcome.failed('removed');
    }
    if (_unanswered.containsKey(generation)) {
      return const EjectOutcome.failed(stillEjecting);
    }
    _guards
        ?.enter(
          GuardKind.eject,
          GuardScope.removable(generation),
          purpose: ejectPurpose,
        )
        .release();
    final eject = _Eject(generation, _client.requestEject(generation));
    _eject = eject;
    _publishPhase();
    _publishVolumes();
    try {
      try {
        eject.requestId = await eject.request;
      } on FileSystemException {
        return const EjectOutcome.failed('error');
      }
      _settleEject();
      final answer = eject.outcome.future;
      return await answer.timeout(
        ejectTimeout,
        onTimeout: () async {
          if (await _client.cancelEject(eject.requestId!)) {
            return const EjectOutcome.failed('timeout');
          }
          // Taken: the helper is syncing and unmounting, and its answer is
          // coming. Saying "failed" now would be followed by the drive being
          // ejected anyway.
          return answer.timeout(
            ejectServedTimeout,
            onTimeout: () {
              _unanswered[generation] = eject.requestId!;
              return const EjectOutcome.failed(stillEjecting);
            },
          );
        },
      );
    } finally {
      _eject = null;
      _publishPhase();
      _publishVolumes();
    }
  }

  /// Withdraws the eject in flight if the helper has not taken it yet, and
  /// says whether it did; the eject then completes cancelled. `false` when
  /// nothing is in flight, and when the helper has already taken the request:
  /// it is syncing and unmounting, the eject carries on and completes with
  /// the helper's answer, and a caller should say so rather than look as if
  /// the cancel worked.
  Future<bool> cancelEject() async {
    final eject = _eject;
    if (eject == null) return false;
    final String requestId;
    try {
      requestId = await eject.request;
    } on FileSystemException {
      return false; // never filed: eject() reports that itself
    }
    final withdrawn = await _client.cancelEject(requestId);
    if (withdrawn && !eject.outcome.isCompleted) {
      eject.outcome.complete(const EjectOutcome.cancelled());
    }
    return withdrawn;
  }

  /// The reason an eject fails with when the helper took the request and has
  /// not answered: the drive may still be unmounting.
  static const String stillEjecting = 'stillEjecting';

  /// What an eject is called in the guard table.
  static const String ejectPurpose = 'eject';

  /// The leases (as `transfer`) and the eject in flight or still unanswered
  /// (as `eject`), for the guard table. Recording leases are left out: the
  /// take reports itself as `capture`.
  @override
  Iterable<ActiveOperation> get activeOperations => [
    for (final held in _leases)
      if (held.purpose != WritePurpose.recording)
        ActiveOperation(
          kind: GuardKind.transfer,
          scope: _scopeOf(held.target),
          purpose: held.purpose.name,
        ),
    for (final generation in {?_eject?.generation, ..._unanswered.keys})
      ActiveOperation(
        kind: GuardKind.eject,
        scope: GuardScope.removable(generation),
        purpose: ejectPurpose,
      ),
  ];

  static GuardScope _scopeOf(StorageDestination destination) =>
      switch (destination) {
        InternalDestination() => const GuardScope.internal(),
        RemovableDestination(:final generation) => GuardScope.removable(
          generation,
        ),
      };

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
  /// unsupported) or a path the engine cannot answer for.
  ///
  /// `freeBytes` is the filesystem's available figure, with NO reserve taken
  /// off: the Internal reserve ([internalReserveBytes]) applies only to
  /// [recordingTimeRemaining] and [lowInternalSpace]. (The Library's
  /// `RemovableVolumes` port documents free as "after any reserve the
  /// service keeps"; for a removable volume that is the same figure, and the
  /// port never asks about Internal.)
  Future<VolumeSpace?> space(StorageDestination destination) async {
    final path = switch (destination) {
      InternalDestination() => _nearestExisting(await _exportsRoot()),
      RemovableDestination(:final generation) => _mountedPath(generation),
    };
    return path == null ? null : _volumeSpace(path);
  }

  /// How long a recording at [bytesPerSecond] fits on [destination]: free
  /// space less [internalReserveBytes] on Internal, free space as is on a
  /// removable volume, never below zero. Null when the space is unknown
  /// (unknown capacity cannot claim available time, §6.7), and null for a
  /// removable volume that cannot take a recording (read-only, being
  /// ejected, ejected, unsupported): it has no recording time to offer.
  Future<Duration?> recordingTimeRemaining(
    StorageDestination destination,
    int bytesPerSecond,
  ) async {
    if (bytesPerSecond <= 0) {
      throw ArgumentError.value(bytesPerSecond, 'bytesPerSecond');
    }
    if (destination is RemovableDestination &&
        !_writable(destination.generation)) {
      return null;
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
  Future<bool> lowInternalSpace() async =>
      isLowInternalSpace(await space(const StorageDestination.internal()));

  /// The rule [lowInternalSpace] applies, for a reading of Internal a caller
  /// already holds (the Storage page reads it every few seconds and must not
  /// measure twice, or keep its own copy of the rule).
  static bool isLowInternalSpace(VolumeSpace? internal) =>
      internal != null && internal.freeBytes < internalReserveBytes;

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
  /// The bytes go to a part file of the copy's own (`.<name>.<random>.part`,
  /// hidden, so neither the Library nor a computer lists it, and never shared
  /// with another copy in flight), are fsynced, and are renamed to the final
  /// name; then the directory is synced so the rename itself is durable, and
  /// so is every parent the copy created, bottom up, so a new directory's own
  /// entry survives too. A sync the device refuses fails the copy as `io`:
  /// the file is in place but not known to be durable, and "copied" is not
  /// claimed. The destination never holds a half-written file under its final
  /// name, and on any failure the part is deleted and the source is not
  /// touched. Parts a crash left behind are swept by the first copy into each
  /// directory.
  ///
  /// A name already there (a file or a directory) is handled per
  /// [onConflict]: `ask` throws [NameConflict] before writing anything,
  /// `keepBoth` writes `name (2).ext` (then ` (3)`, ...), `replace` renames
  /// over it. For `ask` and `keepBoth` the part is published with a rename
  /// that never replaces (`renameat2(RENAME_NOREPLACE)` through the engine),
  /// so a file that appears under the name while the bytes are copied is
  /// never overwritten: `ask` then throws [NameConflict] after all, and
  /// `keepBoth` takes the next suffix. Where the filesystem cannot refuse a
  /// replacement, the name is claimed with an exclusive create first and the
  /// part renamed over the empty claim.
  ///
  /// Failures are typed [StorageFailure]s: `full` (ENOSPC), `readOnly` (EROFS,
  /// or a read-only volume), `volumeLost` when the volume goes away before or
  /// during the copy, `unsupported` for a volume that cannot be written, `io`
  /// for the rest, a source that cannot be read included. A lease with
  /// purpose `copy` is held throughout, so eject and shutdown wait for it.
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
    final held = acquire(destination, WritePurpose.copy);
    try {
      final wanted = '${await _writeRoot(destination)}/$relativePath';
      if (onConflict == ConflictPolicy.ask && _taken(wanted)) {
        throw NameConflict(wanted);
      }
      final directory = File(wanted).parent;
      final part = File(
        '${directory.path}/.${segments.last}.${_partId()}.part',
      );
      _liveParts.add(part.path);
      try {
        final created = _createDirectories(directory);
        _sweepStaleParts(directory);
        await _copyBytes(File(sourcePath), part, () => held.isLost);
        if (held.isLost) throw const FileSystemException('volume lost');
        final target = _publish(part, wanted, onConflict);
        try {
          _io.syncDirectory(directory.path);
          for (final made in created) {
            _io.syncDirectory(made.parent.path);
          }
        } on FileSystemException catch (e) {
          // The file is in place and complete; only its durability is in
          // doubt. A pulled drive is still a lost volume (the sync carries
          // the errno); anything else says where the file is.
          final failure = await _classify(e, destination, held);
          throw failure is StorageIo
              ? StorageFailure.io(failure.reason, writtenTo: target)
              : failure;
        }
        return target;
      } on SourceReadFailure catch (e) {
        _discard(part);
        throw StorageFailure.io(e.cause.osError?.message ?? e.cause.message);
      } on NameConflict {
        _discard(part);
        rethrow;
      } on FileSystemException catch (e) {
        _discard(part);
        throw await _classify(e, destination, held);
      } finally {
        _liveParts.remove(part.path);
      }
    } finally {
      held.release();
    }
  }

  /// Whether anything (a file, a directory, a link) is at [path].
  static bool _taken(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  // 64 random bits: two copies in flight never share a part.
  String _partId() => [
    for (var i = 0; i < 8; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static final _partName = RegExp(r'^\..+\.[0-9a-f]{16}\.part$');

  /// Creates [directory] and the parents it lacks, and returns the ones it
  /// created, deepest first.
  static List<Directory> _createDirectories(Directory directory) {
    final missing = <Directory>[];
    for (
      var dir = directory;
      !_taken(dir.path) && dir.parent.path != dir.path;
      dir = dir.parent
    ) {
      missing.add(dir);
    }
    directory.createSync(recursive: true);
    return missing;
  }

  /// Deletes the part files a crash left in [directory]; never one a copy in
  /// flight is writing. Once per directory per run: a crash leaves its parts
  /// before this run starts, and a stick's root can hold thousands of files
  /// to list.
  void _sweepStaleParts(Directory directory) {
    if (!_sweptDirectories.add(directory.path)) return;
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.path.substring(entity.path.lastIndexOf('/') + 1);
      if (entity is File &&
          _partName.hasMatch(name) &&
          !_liveParts.contains(entity.path)) {
        _discard(entity);
      }
    }
  }

  /// Renames [part] to its final name under [onConflict] and returns it.
  String _publish(File part, String wanted, ConflictPolicy onConflict) {
    switch (onConflict) {
      case ConflictPolicy.replace:
        part.renameSync(wanted);
        return wanted;
      case ConflictPolicy.ask:
        if (!_publishWithoutReplacing(part, wanted)) {
          throw NameConflict(wanted);
        }
        return wanted;
      case ConflictPolicy.keepBoth:
        final slash = wanted.lastIndexOf('/');
        final dot = wanted.lastIndexOf('.');
        // `.hidden` and `name` have no extension; `take.wav` does.
        final split = dot > slash + 1 ? dot : wanted.length;
        final stem = wanted.substring(0, split);
        final extension = wanted.substring(split);
        for (var n = 1; ; n++) {
          final candidate = n == 1 ? wanted : '$stem ($n)$extension';
          if (_publishWithoutReplacing(part, candidate)) return candidate;
        }
    }
  }

  /// Renames [part] to [path] unless something is there, and says whether it
  /// did. Through the engine's no-replace rename; where the filesystem cannot
  /// refuse a replacement, through an exclusive-create claim instead.
  bool _publishWithoutReplacing(File part, String path) {
    switch (_io.renameWithoutReplacing(part.path, path)) {
      case engine.RenameOutcome.renamed:
        return true;
      case engine.RenameOutcome.nameTaken:
        return false;
      case engine.RenameOutcome.unsupported:
        if (!_claim(path)) return false;
        _renameOntoClaim(part, path);
        return true;
    }
  }

  /// Takes [path] for this copy by creating it exclusively (O_EXCL), so no
  /// other writer can get it between this check and the rename onto it.
  /// False when something (a file, a directory, a link) is already there:
  /// O_EXCL refuses all three with EEXIST. The fallback for filesystems that
  /// cannot rename without replacing: for the rename's window an empty file
  /// stands at the final name.
  static bool _claim(String path) {
    try {
      File(path).createSync(exclusive: true);
      return true;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == _eexist) return false;
      rethrow;
    }
  }

  static const _eexist = 17;

  /// Renames [part] over the empty file [_claim] made at [path]; if the
  /// rename fails, the claim goes too, so no empty file is left under the
  /// final name.
  static void _renameOntoClaim(File part, String path) {
    try {
      part.renameSync(path);
    } on FileSystemException {
      _discard(File(path));
      rethrow;
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
    HeldLease held,
  ) async {
    final code = e.osError?.errorCode;
    if (destination is RemovableDestination &&
        (held.isLost ||
            (_pulledDriveErrors.contains(code) && await _lostSoon(held)))) {
      return StorageFailure.volumeLost(destination.generation);
    }
    return switch (code) {
      28 => const StorageFailure.full(), // ENOSPC
      30 => const StorageFailure.readOnly(), // EROFS
      _ => StorageFailure.io(e.osError?.message ?? e.message),
    };
  }

  // Waits for the lease to be failed by the volume's record going (or
  // leaving `mounted`), up to [volumeLossGrace]: answered by the record, not
  // by the clock, whenever the record goes in time.
  Future<bool> _lostSoon(HeldLease held) => held.lost
      .then((_) => true)
      .timeout(volumeLossGrace, onTimeout: () => false);

  static void _discard(File part) {
    try {
      part.deleteSync();
    } on FileSystemException {
      // Never created, or gone with the drive: nothing partial is left.
    }
  }

  /// The default [CopyBytes]: [chunkSize] at a time from [source] into
  /// [part], [shouldAbort] polled before every write, then [sync] (fsync(2)
  /// through `RandomAccessFile.flush`) before the part is closed. Source
  /// errors are thrown as [SourceReadFailure].
  @visibleForTesting
  static Future<void> copyChunks(
    File source,
    File part,
    bool Function() shouldAbort, {
    int chunkSize = 1 << 20,
    Future<void> Function(RandomAccessFile file)? sync,
  }) async {
    final input = await _fromSource(source.open);
    try {
      final out = await part.open(mode: FileMode.writeOnly);
      try {
        while (true) {
          final chunk = await _fromSource(() => input.read(chunkSize));
          if (chunk.isEmpty) break;
          if (shouldAbort()) throw const FileSystemException('volume lost');
          await out.writeFrom(chunk);
        }
        await (sync ?? _fsync)(out);
      } finally {
        await out.close();
      }
    } finally {
      await input.close();
    }
  }

  static Future<void> _fsync(RandomAccessFile file) => file.flush();

  // Every operation on the source goes through here, so a source failure is
  // never mistaken for the destination's.
  static Future<T> _fromSource<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FileSystemException catch (e) {
      throw SourceReadFailure(e);
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
