/// What a copy does when a file of that name is already at the destination.
enum ConflictPolicy {
  /// Stop before writing and report [NameConflict], so the caller can ask.
  ask,

  /// Keep both: write beside it as `name (2).ext`, then `name (3).ext`, ...
  keepBoth,

  /// Write over it. The replacement is a rename over the old file, so on a
  /// journaled filesystem (Internal's ext4) the old file stays whole until
  /// the new one is complete. On FAT and exFAT, which have no journal, that
  /// holds only while nothing crashes: a drive pulled during the rename can
  /// lose the old file as well. Eject before pulling.
  replace,
}

/// A copy under [ConflictPolicy.ask] found [existingPath] already there.
/// Nothing was written.
class NameConflict implements Exception {
  /// Creates a [NameConflict].
  const NameConflict(this.existingPath);

  /// The file that is already at the destination.
  final String existingPath;

  @override
  String toString() => 'a file already exists at $existingPath';
}
