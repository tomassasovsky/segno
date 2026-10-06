import 'package:meta/meta.dart';

/// A session's identity: its bundle directory's name under the sessions root
/// (or under one folder of it). Stable for the bundle's whole life; a rename
/// changes the manifest's display name and never this.
typedef SessionId = String;

/// One entry in the session catalog, read from a bundle's directory and a
/// lenient look at its manifest, without decoding any audio.
///
/// Identity ([==] / [hashCode]) is the [id] alone. Everything else describes
/// the bundle at listing time and is not part of equality, so a re-listed
/// catalog compares row for row by identity.
@immutable
class SessionSummary {
  /// Creates a [SessionSummary].
  const SessionSummary({
    required this.id,
    required this.name,
    this.folder,
    this.modifiedAt,
    this.trackCount = 0,
    this.tempoBpm = 0,
    this.tsNum = 4,
    this.tsDen = 4,
    this.fxCount = 0,
    this.unreadable = false,
  });

  /// The bundle directory's name — the session's identity.
  final SessionId id;

  /// The display name: the manifest's `name`, or the [id] for a bundle saved
  /// before names were metadata, or for one whose manifest cannot be read.
  final String name;

  /// The one-level folder the bundle sits in, or `null` when it is directly
  /// under the sessions root ("Unfiled").
  final String? folder;

  /// When the session's manifest was last written, or null when unknown (a
  /// stat failure). The Library's date column reads this.
  final DateTime? modifiedAt;

  /// Tracks holding recorded audio, per the manifest's `tracks` list.
  final int trackCount;

  /// The saved tempo in BPM; 0 when the session has none.
  final double tempoBpm;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// Effect entries across every chain stage the manifest carries.
  final int fxCount;

  /// Whether the manifest could not be decoded as JSON at listing time. The
  /// row still lists (by directory name) so the session is never hidden; the
  /// typed refusal surfaces when it is previewed or opened.
  final bool unreadable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSummary &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SessionSummary($id, "$name")';
}
