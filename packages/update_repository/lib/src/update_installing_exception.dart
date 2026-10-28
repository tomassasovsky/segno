/// Thrown by the appliance's reboot and halt when RAUC reports an install in
/// progress (#1498): a reset then leaves the inactive slot half written. The
/// helper refused before doing anything, so the console is still running.
class UpdateInstallingException implements Exception {
  /// Creates an [UpdateInstallingException] carrying the helper's [detail].
  const UpdateInstallingException(this.detail);

  /// What the helper logged, for diagnostics.
  final String detail;

  @override
  String toString() => 'UpdateInstallingException: $detail';
}
