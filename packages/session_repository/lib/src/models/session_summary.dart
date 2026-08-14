import 'package:meta/meta.dart';

/// One entry in the named-session catalog — a bundle under the `sessions/`
/// root, identified by its [name].
///
/// The [name] IS the folder slug (there is no separate persisted display name);
/// it is read straight from the directory listing, so a summary is produced
/// without ever parsing a manifest. Kept name-only on purpose: the picker needs
/// only the name to list, load, rename, and delete; richer metadata would force
/// a manifest read (and a parse-failure mode) per row for no acceptance need.
@immutable
class SessionSummary {
  /// Creates a [SessionSummary].
  const SessionSummary({required this.name, this.modifiedAt});

  /// The session's name — also its folder slug under the sessions root.
  final String name;

  /// When the session's manifest was last written, or null when unknown (a
  /// stat failure, or a summary built without one). The sessions dialog's
  /// date column reads this — "today 14:02", "yesterday", "3 Aug".
  ///
  /// Deliberately NOT part of [==]/[hashCode]: identity is the name, and a
  /// list that compared timestamps would report "changed" after every save
  /// even when the set of sessions did not.
  final DateTime? modifiedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSummary &&
          runtimeType == other.runtimeType &&
          name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SessionSummary($name)';
}
