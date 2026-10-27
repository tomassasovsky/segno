import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/update/usb/usb_update_package.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:update_repository/update_repository.dart';

part 'usb_update_state.dart';

/// Room kept on Internal beyond the package itself for the install.
const int kUsbUpdateSpareBytes = 64 * 1024 * 1024;

/// Updates > Load from USB (#1270 Part 8, pen 33): the packages on the
/// drives that are plugged in, and the install of one.
///
/// Choosing a package refuses during a take (D3), checks Internal has room
/// for it, copies it into staging under a read hold on the drive (eject is
/// refused meanwhile, and a read-only drive serves it), and hands it to the
/// helper, which verifies and stages it exactly as an online update. It then
/// waits in Ready to install like one.
class UsbUpdateCubit extends Cubit<UsbUpdateState> {
  /// Creates a [UsbUpdateCubit]. [takeRunning] says whether a take is
  /// recording, overdubbing, waiting or counting in; [onlineBusy] whether an
  /// online update is downloading; [onWorking] hears when a copy or an
  /// install starts and ends, so the online flow and restart hold off; and
  /// [onStaged] runs once a package is staged, even if this cubit has closed.
  UsbUpdateCubit({
    required StorageRepository storage,
    required UpdateRepository updates,
    required bool Function() takeRunning,
    required bool Function() onlineBusy,
    required void Function({required bool working}) onWorking,
    required void Function() onStaged,
  }) : _storage = storage,
       _updates = updates,
       _takeRunning = takeRunning,
       _onlineBusy = onlineBusy,
       _onWorking = onWorking,
       _onStaged = onStaged,
       super(const UsbUpdateState());

  final StorageRepository _storage;
  final UpdateRepository _updates;
  final bool Function() _takeRunning;
  final bool Function() _onlineBusy;
  final void Function({required bool working}) _onWorking;
  final void Function() _onStaged;

  /// Set from the press until the run ends, so a second press cannot start
  /// a second copy.
  bool _running = false;

  /// Numbers the listings, so a slow one never replaces a newer one.
  int _listing = 0;

  StreamSubscription<List<RemovableVolume>>? _volumes;
  bool _cancelled = false;

  /// Load from USB: lists what the plugged-in drives hold, and follows them
  /// while the list is open.
  void open() {
    if (state.phase != UsbUpdatePhase.closed) return;
    emit(const UsbUpdateState(phase: UsbUpdatePhase.reading));
    _volumes = _storage.volumes.listen((volumes) => unawaited(_list(volumes)));
  }

  /// Closes the list. Not during a copy or an install.
  void closePanel() {
    if (_working) return;
    unawaited(_volumes?.cancel());
    _volumes = null;
    emit(const UsbUpdateState());
  }

  /// Back to the list from a failure.
  void back() {
    if (state.phase != UsbUpdatePhase.failed) return;
    emit(state.copyWith(phase: UsbUpdatePhase.reading, clearError: true));
    unawaited(_list(_storage.current));
  }

  /// Copies [package] off its drive and installs it.
  void choose(UsbUpdatePackage package) {
    if (state.phase != UsbUpdatePhase.list || _running) return;
    _running = true;
    _onWorking(working: true);
    unawaited(
      _run(package).whenComplete(() {
        _running = false;
        _onWorking(working: false);
        // A cancelled run went back to reading: list the drives as they are
        // now.
        if (!isClosed && state.phase == UsbUpdatePhase.reading) {
          unawaited(_list(_storage.current));
        }
      }),
    );
  }

  /// Stops the copy. The install that follows it cannot be stopped: RAUC is
  /// writing the slot.
  void cancel() {
    if (state.phase != UsbUpdatePhase.copying) return;
    _cancelled = true;
  }

  bool get _working =>
      _running ||
      state.phase == UsbUpdatePhase.copying ||
      state.phase == UsbUpdatePhase.installing;

  Future<void> _list(List<RemovableVolume> volumes) async {
    if (isClosed || _working || state.phase == UsbUpdatePhase.closed) return;
    final listing = ++_listing;
    final readable = [
      for (final volume in volumes)
        if (volume.readable) volume,
    ];
    if (readable.isEmpty) {
      emit(const UsbUpdateState(phase: UsbUpdatePhase.noDrive));
      return;
    }
    final label = readable.first.label;
    if (state.phase == UsbUpdatePhase.noDrive) {
      emit(UsbUpdateState(phase: UsbUpdatePhase.reading, driveLabel: label));
    }
    final packages = await listUsbUpdatePackages(readable);
    if (isClosed || _working || state.phase == UsbUpdatePhase.closed) return;
    if (listing != _listing) return;
    if (state.phase == UsbUpdatePhase.failed) return;
    emit(
      UsbUpdateState(
        phase: packages.isEmpty ? UsbUpdatePhase.empty : UsbUpdatePhase.list,
        driveLabel: label,
        packages: packages,
      ),
    );
  }

  Future<void> _run(UsbUpdatePackage package) async {
    if (_takeRunning()) {
      return _fail(UsbUpdateError.busy, busyKind: 'capture');
    }
    if (_onlineBusy()) {
      return _fail(UsbUpdateError.busy, busyKind: 'other');
    }
    final needed = package.sizeBytes + kUsbUpdateSpareBytes;
    final space = await _storage.space(const StorageDestination.internal());
    if (isClosed) return;
    if (space != null && space.freeBytes < needed) {
      return _fail(UsbUpdateError.noSpace, neededBytes: needed);
    }
    _cancelled = false;
    emit(state.copyWith(phase: UsbUpdatePhase.copying, progress: 0));
    final String staged;
    try {
      staged = await _storage.copyUpdatePackage(
        generation: package.generation,
        sourcePath: package.path,
        stagingDirectory: _updates.stagingDirectory,
        cancelled: () => _cancelled,
      );
    } on StorageFailure catch (failure) {
      if (isClosed) return;
      if (_cancelled) return _relist();
      return switch (failure) {
        StorageVolumeLost() => _fail(UsbUpdateError.removed),
        StorageFull() => _fail(UsbUpdateError.noSpace, neededBytes: needed),
        StorageBusy(:final kind) => _fail(
          UsbUpdateError.busy,
          busyKind: kind.name,
        ),
        _ => _fail(UsbUpdateError.failed),
      };
    } on Object {
      return _fail(UsbUpdateError.failed);
    }
    if (_cancelled) {
      // Copied just as Cancel (or a closed page) came: the helper never sees
      // it, and the copy goes rather than waiting for the next start.
      _discard(staged);
      if (!isClosed) _relist();
      return;
    }
    emit(state.copyWith(phase: UsbUpdatePhase.installing, progress: 0));
    try {
      await for (final progress in _updates.installPackage(staged)) {
        if (!isClosed) {
          emit(state.copyWith(progress: progress.clamp(0.0, 1.0)));
        }
      }
    } on UpdatePackageRefused catch (refused) {
      final version = refused.version;
      if (refused.refusal != UpdatePackageRefusal.notNewer || version == null) {
        return _fail(UsbUpdateError.unverified);
      }
      final current = await _updates.currentVersion();
      return _fail(
        UsbUpdateError.notNewer,
        refusedVersion: version,
        installedVersion: current,
      );
    } on BootPartitionReadOnlyException {
      return _fail(UsbUpdateError.bootReadOnly);
    } on Object {
      return _fail(UsbUpdateError.failed);
    }
    // Staged is the app's to know whether this page is still open: Ready to
    // install and the power dialog's staged line read it.
    _onStaged();
    if (isClosed) return;
    unawaited(_volumes?.cancel());
    _volumes = null;
    emit(const UsbUpdateState());
  }

  /// Back to the list, read again once the run has ended: the drives may
  /// have changed meanwhile.
  void _relist() => emit(state.copyWith(phase: UsbUpdatePhase.reading));

  static void _discard(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Gone already, or the next start's sweep takes it.
    }
  }

  void _fail(
    UsbUpdateError error, {
    String? busyKind,
    int? neededBytes,
    Version? refusedVersion,
    Version? installedVersion,
  }) {
    if (isClosed) return;
    emit(
      state.copyWith(
        phase: UsbUpdatePhase.failed,
        error: error,
        busyKind: busyKind,
        neededBytes: neededBytes,
        refusedVersion: refusedVersion,
        installedVersion: installedVersion,
      ),
    );
  }

  /// A package being installed is RAUC's to finish: the helper is not
  /// killed for a page that closed.
  @override
  Future<void> close() async {
    // A copy in flight stops; an install is RAUC's to finish.
    _cancelled = true;
    await _volumes?.cancel();
    return super.close();
  }
}
