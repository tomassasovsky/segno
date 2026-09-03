part of 'pedal_cubit.dart';

/// Sentinel for [PedalState.copyWith] so a `null` [PedalState.firmwareVersion]
/// can be set explicitly while omitting it preserves the current value.
const Object _unsetFirmwareVersion = Object();

/// The pedal LINK state: whether the console board is on the other end of the
/// link, and the firmware it announced. Everything else about the pedal —
/// mode, cursor, bank, LEDs — is control state, projected elsewhere.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.status = PedalLinkStatus.disconnected,
    this.firmwareVersion,
  });

  /// Whether the board is talking.
  final PedalLinkStatus status;

  /// The firmware version the board announced (`major.minor`), or `null`
  /// before its first hello.
  final String? firmwareVersion;

  /// Returns a copy with the given fields replaced.
  PedalState copyWith({
    PedalLinkStatus? status,
    Object? firmwareVersion = _unsetFirmwareVersion,
  }) {
    return PedalState(
      status: status ?? this.status,
      firmwareVersion: identical(firmwareVersion, _unsetFirmwareVersion)
          ? this.firmwareVersion
          : firmwareVersion as String?,
    );
  }

  @override
  List<Object?> get props => [status, firmwareVersion];
}
