import 'package:meta/meta.dart';

/// A volume's total size and what is still free on it, in bytes, from
/// `AudioEngine.volumeSpace`.
///
/// Free is the filesystem's *available* figure (`f_bavail`), not
/// total-minus-used: the two disagree by the blocks a filesystem reserves for
/// root, and the number a capture or an export can actually fill is the
/// available one. Total is the whole volume, which is what a Storage page
/// draws next to the free figure as "of N GB".
@immutable
class VolumeSpace {
  /// Creates a [VolumeSpace].
  const VolumeSpace({required this.totalBytes, required this.freeBytes});

  /// The volume's size.
  final int totalBytes;

  /// What is still available on it.
  final int freeBytes;

  @override
  bool operator ==(Object other) =>
      other is VolumeSpace &&
      other.totalBytes == totalBytes &&
      other.freeBytes == freeBytes;

  @override
  int get hashCode => Object.hash(totalBytes, freeBytes);

  @override
  String toString() =>
      'VolumeSpace(totalBytes: $totalBytes, freeBytes: $freeBytes)';
}
