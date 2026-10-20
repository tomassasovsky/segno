import 'package:backing_repository/src/models/backing_failure.dart';
import 'package:equatable/equatable.dart';

/// One file in the managed `Backing tracks` store (plan D7).
///
/// Identified by [digest], the full SHA-256 of the file's bytes as
/// `sha256:<64 hex>`: the identity a session's prepared list stores, so two
/// files with one name stay apart and a copy is recognised whatever it is
/// called. [available] is false when the asset's data cannot be trusted
/// (missing or unreadable `info.json`, a missing file); [problem] says why.
class BackingAsset extends Equatable {
  /// Creates a [BackingAsset].
  const BackingAsset({
    required this.digest,
    required this.name,
    required this.path,
    this.sourceRate = 0,
    this.sourceChannels = 0,
    this.sourceFrames = 0,
    this.peaks = const [],
    this.problem,
  });

  /// `sha256:<64 hex>`.
  final String digest;

  /// The display name: the original file name.
  final String name;

  /// The managed copy's path.
  final String path;

  /// The file's own rate.
  final int sourceRate;

  /// 1 or 2.
  final int sourceChannels;

  /// Its length at [sourceRate].
  final int sourceFrames;

  /// Peaks for the waveform, from the import's probe.
  final List<double> peaks;

  /// Why the asset is unavailable, or null.
  final BackingFailureReason? problem;

  /// Whether it can be loaded.
  bool get available => problem == null;

  /// Its length in seconds.
  double get seconds => sourceRate > 0 ? sourceFrames / sourceRate : 0;

  /// The directory name: the first 16 hex digits of the digest.
  String get id => idOf(digest);

  /// The directory name of [digest].
  static String idOf(String digest) =>
      digest.substring(_prefix.length, _prefix.length + 16);

  /// Whether [digest] is a well-formed `sha256:<64 hex>`.
  static bool isDigest(String digest) => _digest.hasMatch(digest);

  static const _prefix = 'sha256:';
  static final _digest = RegExp(r'^sha256:[0-9a-f]{64}$');

  @override
  List<Object?> get props => [
    digest,
    name,
    path,
    sourceRate,
    sourceChannels,
    sourceFrames,
    peaks,
    problem,
  ];
}
