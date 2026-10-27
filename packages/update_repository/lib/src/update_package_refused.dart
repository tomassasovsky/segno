import 'package:pub_semver/pub_semver.dart';

/// Why an update package from a USB drive was refused before anything was
/// written (#1270 Part 8).
enum UpdatePackageRefusal {
  /// The bundle's signature or its compatible string did not check out.
  unverified,

  /// The bundle is not newer than the running software.
  notNewer,

  /// The path was not in the staging directory.
  outsideStaging,
}

/// Thrown by `UpdateRepository.installPackage` when the helper refuses the
/// package. Nothing was changed.
class UpdatePackageRefused implements Exception {
  /// Creates an [UpdatePackageRefused].
  const UpdatePackageRefused(this.refusal, {this.version});

  /// Why.
  final UpdatePackageRefusal refusal;

  /// The package's version, for [UpdatePackageRefusal.notNewer].
  final Version? version;

  @override
  String toString() => version == null
      ? 'UpdatePackageRefused(${refusal.name})'
      : 'UpdatePackageRefused(${refusal.name}, $version)';
}
