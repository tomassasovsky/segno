import 'package:flutter/foundation.dart';
import 'package:pub_semver/pub_semver.dart';

/// What the previous run left behind for the update flow to report, read
/// once at startup.
///
/// Both are failures the console otherwise hides: a staged build that did
/// not start leaves the console quietly on the old version, and an install
/// cut off by a crash or a power loss leaves nothing staged at all.
@immutable
class UpdateRecovery {
  /// Creates an [UpdateRecovery].
  const UpdateRecovery({this.rolledBack, this.interrupted});

  /// The staged version that was booted into and did not start, so the
  /// console went back to the running one; `null` when none.
  final Version? rolledBack;

  /// The version whose download or install was cut off before it was
  /// staged; `null` when none.
  final Version? interrupted;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateRecovery &&
          rolledBack == other.rolledBack &&
          interrupted == other.interrupted;

  @override
  int get hashCode => Object.hash(rolledBack, interrupted);

  @override
  String toString() =>
      'UpdateRecovery(rolledBack: $rolledBack, interrupted: $interrupted)';
}
