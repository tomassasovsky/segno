import 'package:meta/meta.dart';

/// The kinds of operation that must honour each other at commit
/// (accepted behaviour 6.12, 7.1, 7.2, 7.7, 7.8; plan
/// `docs/plan/2026-10-06-feat-recording-recovery-plan.md` D8).
enum GuardKind {
  /// A performance recording (arm until finalized, discarded or held).
  capture,

  /// Applying a session to the rig: Open, New loop.
  sessionApply,

  /// Writing a session bundle: save, Save as, rename, duplicate, delete,
  /// restore into Internal.
  sessionWrite,

  /// A file copy to or from a removable volume: export, backup, import.
  transfer,

  /// Ejecting a removable volume.
  eject,

  /// Applying an audio interface or format change.
  deviceChange,

  /// Measuring latency, or calibrating a display.
  calibration,

  /// Power off, restart or update install.
  restart,
}

/// What one operation does when it wants to commit while another is active.
enum GuardRule {
  /// Both may run.
  allow,

  /// The newcomer is refused.
  refuse,

  /// Refused when both are on the same volume.
  refuseSameVolume,

  /// Refused when both name the same item (one session bundle).
  refuseSameItem,
}

/// Where an operation acts: Internal storage or one removable volume
/// generation, optionally narrowed to one item on it (a session bundle).
@immutable
class GuardScope {
  /// Internal storage, optionally one [item] on it.
  const GuardScope.internal({this.item}) : generation = null;

  /// The removable volume [generation] (a replug is a new generation),
  /// optionally one [item] on it.
  const GuardScope.removable(int this.generation, {this.item});

  /// The removable volume generation, or null for Internal.
  final int? generation;

  /// The item acted on, such as a bundle path; null for the whole volume.
  final String? item;

  /// Whether this scope is on the same volume as [other].
  bool sameVolume(GuardScope other) => other.generation == generation;

  /// Whether this scope names the same item on the same volume as [other].
  /// A scope without an item covers every item on its volume.
  bool sameItem(GuardScope other) =>
      sameVolume(other) &&
      (item == null || other.item == null || item == other.item);

  @override
  bool operator ==(Object other) =>
      other is GuardScope &&
      other.generation == generation &&
      other.item == item;

  @override
  int get hashCode => Object.hash(generation, item);

  @override
  String toString() => generation == null
      ? 'GuardScope.internal(item: $item)'
      : 'GuardScope.removable($generation, item: $item)';
}

/// An operation in flight, as a guard or as another owner reports it.
@immutable
class ActiveOperation {
  /// Creates an [ActiveOperation].
  const ActiveOperation({
    required this.kind,
    required this.scope,
    required this.purpose,
  });

  /// What the operation is.
  final GuardKind kind;

  /// Where it acts.
  final GuardScope scope;

  /// What it is for, in words a refusal can show (the Storage page shows it
  /// beside a disabled Eject).
  final String purpose;

  @override
  bool operator ==(Object other) =>
      other is ActiveOperation &&
      other.kind == kind &&
      other.scope == scope &&
      other.purpose == purpose;

  @override
  int get hashCode => Object.hash(kind, scope, purpose);

  @override
  String toString() => 'ActiveOperation($kind, $scope, $purpose)';
}

/// An owner that tracks some operations itself and reports them to the
/// registry, so there is one conflict table and no second copy of the
/// owner's state.
///
/// The USB storage service's write leases and eject are reported this way
/// (a lease is a `transfer`, an eject in flight an `eject`), so a lease
/// taken there blocks what the table says it blocks here.
abstract interface class ActiveOperationSource {
  /// The operations this owner has in flight right now.
  Iterable<ActiveOperation> get activeOperations;
}

/// Thrown by [GuardRegistry.enter] when an active operation forbids the
/// commit.
class GuardRefused implements Exception {
  /// Creates a [GuardRefused].
  const GuardRefused({required this.wants, required this.blockers});

  /// The operation that was refused.
  final GuardKind wants;

  /// The active operations that refused it; never empty.
  final List<ActiveOperation> blockers;

  @override
  String toString() => 'GuardRefused($wants, blocked by $blockers)';
}

/// A held guard: its [operation] stays active until [release].
class OperationGuard {
  OperationGuard._(this.operation, this._onRelease);

  /// The operation this guard holds.
  final ActiveOperation operation;

  final void Function(OperationGuard guard) _onRelease;
  bool _held = true;

  /// Whether this guard is still held.
  bool get isHeld => _held;

  /// Ends the operation. Idempotent.
  void release() {
    if (!_held) return;
    _held = false;
    _onRelease(this);
  }
}

/// The one table of which operations may commit while others are active,
/// and the guards currently held.
///
/// Every owner calls [enter] at its commit point and holds the guard until
/// the operation ends. Dart runs these owners on one isolate, so the check
/// and the registration in [enter] are one synchronous step: no other
/// operation can slip in between them.
class GuardRegistry {
  /// Creates a [GuardRegistry] that also consults [sources] (owners that
  /// track their own operations).
  GuardRegistry({Iterable<ActiveOperationSource> sources = const []})
    : _sources = List.of(sources);

  final List<ActiveOperationSource> _sources;
  final List<OperationGuard> _held = [];

  /// The rule for an operation of kind [wants] committing while one of kind
  /// [active] is in flight (plan D8). Callers that "finish the other first"
  /// (power off finalizes a take; Open finalizes it as today) do that before
  /// they enter, so the table only says whether the commit may proceed.
  static GuardRule ruleFor(GuardKind wants, GuardKind active) =>
      _table[wants.index][active.index];

  static const GuardRule _a = GuardRule.allow;
  static const GuardRule _r = GuardRule.refuse;
  static const GuardRule _v = GuardRule.refuseSameVolume;
  static const GuardRule _i = GuardRule.refuseSameItem;

  // Rows: the operation that wants to commit. Columns: the active one, in
  // GuardKind order: capture, sessionApply, sessionWrite, transfer, eject,
  // deviceChange, calibration, restart.
  static const List<List<GuardRule>> _table = [
    // capture: one take at a time; never during an apply, a device change,
    // a calibration or a shutdown; not onto a volume being ejected.
    [_r, _r, _a, _a, _v, _r, _r, _r],
    // sessionApply: a running take is finished first (as today), so capture
    // allows it; never over another apply or a save in flight.
    [_a, _r, _r, _a, _a, _r, _r, _r],
    // sessionWrite: anything but the same bundle or a shutdown.
    [_a, _a, _i, _a, _a, _a, _a, _r],
    // transfer: not onto a volume being ejected, not during shutdown.
    [_a, _a, _a, _a, _v, _a, _a, _r],
    // eject: not while that volume is recorded to or copied to.
    [_v, _a, _a, _v, _r, _a, _a, _r],
    // deviceChange: not under a take, an apply, a calibration or shutdown.
    [_r, _r, _a, _a, _a, _r, _r, _r],
    // calibration: same as a device change.
    [_r, _r, _a, _a, _a, _r, _r, _r],
    // restart: the take is finished first; calibration is cancelled (it
    // keeps its previous result), everything else must end first.
    [_r, _r, _r, _r, _r, _r, _a, _r],
  ];

  /// Every operation in flight: the held guards and what the sources report.
  List<ActiveOperation> get active => [
    for (final guard in _held) guard.operation,
    for (final source in _sources) ...source.activeOperations,
  ];

  /// The active operations that would refuse [kind] at [scope]; empty when
  /// it may commit. For disabling a control with the reason; the commit
  /// itself must still go through [enter].
  List<ActiveOperation> blockers(GuardKind kind, GuardScope scope) => [
    for (final op in active)
      if (_blocks(ruleFor(kind, op.kind), scope, op.scope)) op,
  ];

  /// Registers an operation of [kind] at [scope] for [purpose] and returns
  /// its guard, or throws [GuardRefused] naming what forbids it.
  OperationGuard enter(
    GuardKind kind,
    GuardScope scope, {
    required String purpose,
  }) {
    final refusing = blockers(kind, scope);
    if (refusing.isNotEmpty) {
      throw GuardRefused(wants: kind, blockers: refusing);
    }
    final guard = OperationGuard._(
      ActiveOperation(kind: kind, scope: scope, purpose: purpose),
      _held.remove,
    );
    _held.add(guard);
    return guard;
  }

  static bool _blocks(GuardRule rule, GuardScope wants, GuardScope active) =>
      switch (rule) {
        GuardRule.allow => false,
        GuardRule.refuse => true,
        GuardRule.refuseSameVolume => wants.sameVolume(active),
        GuardRule.refuseSameItem => wants.sameItem(active),
      };
}
