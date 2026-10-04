import 'package:equatable/equatable.dart';
import 'package:midi_client/midi_client.dart';

/// The MIDI input lifecycle status, owned by the repository.
enum MidiConnectionStatus {
  /// No device is selected; the looper runs without MIDI.
  none,

  /// A device selection is being confirmed, or "None" is being cleared.
  connecting,

  /// The selected device is open and delivering input.
  connected,

  /// Opening the selected device failed, or input was stopped after a failed
  /// setting write. [MidiConnection.pinUncertain] distinguishes a durable
  /// setting failure from a native open failure.
  error,

  /// The selected device is not currently present (unplugged, or absent at
  /// launch). The selection is retained; a later replug auto-reconnects.
  deviceGone,
}

/// The most recent pinned-device connectivity transition, diffed per poll tick.
/// Mirrors the audio seam's `DeviceConnectivity`.
enum MidiConnectivity {
  /// No transition to report.
  none,

  /// The pinned device just went absent.
  lost,

  /// The pinned device just came back.
  restored,
}

/// The domain model for the MIDI input connection: the enumerated input
/// devices, the pinned selection, the live connection status, and the latest
/// hotplug transition.
///
/// This is the repository's projected domain data, not a bloc state — the
/// `MidiSetupCubit` composes it (with the raw activity stream) into its own
/// state. Independent of the audio engine.
class MidiConnection extends Equatable {
  /// Creates a [MidiConnection].
  const MidiConnection({
    this.devices = const [],
    this.selectedId = '',
    this.selectedName = '',
    this.status = MidiConnectionStatus.none,
    this.connectivity = MidiConnectivity.none,
    this.connectivityDeviceName = '',
    this.errorDetail,
    this.pinUncertain = false,
  });

  /// The host's enumerated MIDI input devices, for the picker.
  final List<MidiDevice> devices;

  /// The current intended device id, or empty for "None".
  final String selectedId;

  /// The pinned device name, kept so a "last device not found" status can name
  /// the device even while it is absent from [devices].
  final String selectedName;

  /// High-level lifecycle status.
  final MidiConnectionStatus status;

  /// The most recent pinned-device connectivity transition (drives the banner).
  final MidiConnectivity connectivity;

  /// Name of the device involved in the latest [connectivity] transition.
  final String connectivityDeviceName;

  /// Native or storage failure detail when [status] is
  /// [MidiConnectionStatus.error].
  final String? errorDetail;

  /// The latest device choice was not durably confirmed. Live input remains
  /// stopped until the user retries this choice or selects another one.
  /// Independent of [status], which describes the live port.
  final bool pinUncertain;

  /// Whether a device (not "None") is pinned.
  bool get hasSelection => selectedId.isNotEmpty;

  /// Whether the pinned device is present in the current [devices] enumeration.
  bool get isSelectedPresent =>
      hasSelection && devices.any((d) => d.id == selectedId);

  /// Returns a copy with the given fields replaced.
  MidiConnection copyWith({
    List<MidiDevice>? devices,
    String? selectedId,
    String? selectedName,
    MidiConnectionStatus? status,
    MidiConnectivity? connectivity,
    String? connectivityDeviceName,
    String? errorDetail,
    bool clearError = false,
    bool? pinUncertain,
  }) {
    return MidiConnection(
      devices: devices ?? this.devices,
      selectedId: selectedId ?? this.selectedId,
      selectedName: selectedName ?? this.selectedName,
      status: status ?? this.status,
      connectivity: connectivity ?? this.connectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      // [clearError] resets the detail on a successful open, since a nullable
      // field cannot otherwise be cleared through `?? this`.
      errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
      pinUncertain: pinUncertain ?? this.pinUncertain,
    );
  }

  @override
  List<Object?> get props => [
    devices,
    selectedId,
    selectedName,
    status,
    connectivity,
    connectivityDeviceName,
    errorDetail,
    pinUncertain,
  ];
}
