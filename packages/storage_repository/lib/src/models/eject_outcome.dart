import 'package:equatable/equatable.dart';
import 'package:storage_repository/src/write_lease.dart';

/// Whether an eject is in flight.
enum EjectPhase {
  /// No eject in flight.
  idle,

  /// A request has been filed and not yet answered.
  ejecting,
}

/// How an eject ended.
sealed class EjectOutcome extends Equatable {
  const EjectOutcome();

  /// The volume is unmounted; the drive can be pulled.
  const factory EjectOutcome.safeToRemove() = EjectSafeToRemove;

  /// The volume is still there; see [EjectFailed.reason].
  const factory EjectOutcome.failed(String reason) = EjectFailed;

  /// The caller withdrew the request before the helper served it.
  const factory EjectOutcome.cancelled() = EjectCancelled;

  @override
  List<Object?> get props => const [];
}

/// The volume is unmounted; the drive can be pulled.
final class EjectSafeToRemove extends EjectOutcome {
  /// Creates an [EjectSafeToRemove].
  const EjectSafeToRemove();
}

/// The eject did not happen. [reason] is the helper's (`busy` when the
/// kernel refused because something outside the app holds the volume,
/// `error` for any other unmount failure), `timeout` when the helper never
/// took the request (it is withdrawn), `stillEjecting` when the helper took
/// it and has not answered (the drive stays `ejecting` until it does or is
/// pulled), or `removed` when the drive was pulled first.
final class EjectFailed extends EjectOutcome {
  /// Creates an [EjectFailed] with [reason].
  const EjectFailed(this.reason);

  /// Why.
  final String reason;

  @override
  List<Object?> get props => [reason];
}

/// The caller withdrew the request before the helper served it.
final class EjectCancelled extends EjectOutcome {
  /// Creates an [EjectCancelled].
  const EjectCancelled();
}

/// Eject was refused before any request was filed: these leases are still
/// writing to the volume (accepted behaviour §7.7, "Eject is unavailable
/// during USB work").
class EjectRefused implements Exception {
  /// Creates an [EjectRefused] naming the [holders].
  const EjectRefused(this.holders);

  /// The leases holding the volume; each carries the purpose the Storage page
  /// shows next to the disabled Eject.
  final List<WriteLease> holders;

  @override
  String toString() =>
      'EjectRefused(${holders.map((lease) => lease.purpose.name).join(', ')})';
}
