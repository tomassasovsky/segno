/// Thrown by `PlatformUpdateBackend.downloadAndStage` when the appliance's
/// boot partition is mounted read-only, so the update cannot be committed.
///
/// The kernel remounts the FAT boot partition read-only when it finds damage,
/// typically after a power cut. The check that runs at every boot repairs it,
/// so the remedy is a restart, not another download.
class BootPartitionReadOnlyException implements Exception {
  /// Creates a [BootPartitionReadOnlyException] carrying the helper's [detail].
  const BootPartitionReadOnlyException([this.detail = '']);

  /// What the helper logged, for diagnostics.
  final String detail;

  @override
  String toString() => detail.isEmpty
      ? 'BootPartitionReadOnlyException'
      : 'BootPartitionReadOnlyException: $detail';
}
