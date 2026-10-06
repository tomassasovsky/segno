/// The one owner of where a write may go on the Segno appliance (#1177).
///
/// Internal storage and removable USB volumes, their capacity, who is writing
/// (leases), whether a drive may be ejected, and a copy that leaves existing
/// content intact on every failure. The Storage page, the Library, the
/// recorder, export and backup consume this; none of them talks to the USB
/// helper or measures a filesystem itself.
library;

export 'package:segno_engine/segno_engine.dart' show VolumeSpace;

export 'src/models/conflict_policy.dart' show ConflictPolicy, NameConflict;
export 'src/models/eject_outcome.dart'
    show
        EjectCancelled,
        EjectFailed,
        EjectOutcome,
        EjectPhase,
        EjectRefused,
        EjectSafeToRemove;
export 'src/models/removable_volume.dart'
    show RemovableVolume, RemovableVolumeStatus;
export 'src/models/storage_destination.dart'
    show InternalDestination, RemovableDestination, StorageDestination;
export 'src/models/storage_failure.dart'
    show
        StorageFailure,
        StorageFull,
        StorageIo,
        StorageReadOnly,
        StorageUnsupported,
        StorageVolumeLost;
export 'src/storage_repository.dart'
    show CopyBytes, SourceReadFailure, StorageRepository;
export 'src/write_lease.dart' show HeldLease, WriteLease;
