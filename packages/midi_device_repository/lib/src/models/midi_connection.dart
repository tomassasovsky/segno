import 'package:equatable/equatable.dart';
import 'package:midi_client/midi_client.dart';

/// Where one MIDI input stands.
enum MidiConnectionStatus {
  /// No device is selected.
  none,

  /// The device is captured and its messages feed learned controls.
  connected,

  /// The device is plugged in, but its port would not open. The repository
  /// retries on every poll.
  error,

  /// The device is not plugged in (unplugged, or absent at launch). Its
  /// mappings are kept; a replug captures it again.
  deviceGone,
}

/// The most recent device connectivity transition, diffed per poll tick.
/// Mirrors the audio seam's `DeviceConnectivity`.
enum MidiConnectivity {
  /// No transition to report.
  none,

  /// A captured device just went absent.
  lost,

  /// A device appeared after launch: plugged back in, or plugged in late.
  restored,
}

/// The domain model for MIDI input: the enumerated devices, which of them are
/// captured, the device the MIDI page shows, and the latest hotplug
/// transition.
///
/// Every plugged-in device is captured at once, so any of them can feed the
/// mappings learned from it. The selection only says which controller the
/// MIDI page lists and adds mappings for.
///
/// This is the repository's projected domain data, not a bloc state — the
/// `MidiSetupCubit` composes it (with the raw activity stream) into its own
/// state. Independent of the audio engine.
class MidiConnection extends Equatable {
  /// Creates a [MidiConnection].
  const new({
    this.devices = const [],
    this.open = const {},
    this.openErrors = const {},
    this.names = const {},
    this.selectedId = '',
    this.selectedName = '',
    this.connectivity = MidiConnectivity.none,
    this.connectivityDeviceId = '',
    this.connectivityDeviceName = '',
    this.errorDetail,
    this.pinUncertain = false,
  });

  /// The host's enumerated MIDI input devices.
  final List<MidiDevice> devices;

  /// The ids of the devices whose capture is open.
  final Set<String> open;

  /// The plugged-in devices whose port would not open, with the native
  /// result code.
  final Map<String, String> openErrors;

  /// The name of every device seen this run, so a device that is unplugged
  /// keeps its name.
  final Map<String, String> names;

  /// The device the MIDI page shows, or empty when none is chosen.
  final String selectedId;

  /// The selected device's name, kept so the page can name the device even
  /// while it is absent from [devices].
  final String selectedName;

  /// The most recent connectivity transition (drives the toast).
  final MidiConnectivity connectivity;

  /// Id of the device involved in the latest [connectivity] transition.
  final String connectivityDeviceId;

  /// Name of the device involved in the latest [connectivity] transition.
  final String connectivityDeviceName;

  /// Storage failure detail when [pinUncertain].
  final String? errorDetail;

  /// The latest selection was not durably saved. Capture does not depend on
  /// it; the page offers a retry.
  final bool pinUncertain;

  /// Whether a device is selected.
  bool get hasSelection => selectedId.isNotEmpty;

  /// Where the device [id] stands.
  MidiConnectionStatus statusOf(String id) {
    if (id.isEmpty) return MidiConnectionStatus.none;
    if (open.contains(id)) return MidiConnectionStatus.connected;
    if (openErrors.containsKey(id)) return MidiConnectionStatus.error;
    return MidiConnectionStatus.deviceGone;
  }

  /// Where the selected device stands.
  MidiConnectionStatus get status => statusOf(selectedId);

  /// Returns a copy with the given fields replaced.
  MidiConnection copyWith({
    List<MidiDevice>? devices,
    Set<String>? open,
    Map<String, String>? openErrors,
    Map<String, String>? names,
    String? selectedId,
    String? selectedName,
    MidiConnectivity? connectivity,
    String? connectivityDeviceId,
    String? connectivityDeviceName,
    String? errorDetail,
    bool clearError = false,
    bool? pinUncertain,
  }) {
    return MidiConnection(
      devices: devices ?? this.devices,
      open: open ?? this.open,
      openErrors: openErrors ?? this.openErrors,
      names: names ?? this.names,
      selectedId: selectedId ?? this.selectedId,
      selectedName: selectedName ?? this.selectedName,
      connectivity: connectivity ?? this.connectivity,
      connectivityDeviceId: connectivityDeviceId ?? this.connectivityDeviceId,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      // [clearError] resets the detail on a confirmed save, since a nullable
      // field cannot otherwise be cleared through `?? this`.
      errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
      pinUncertain: pinUncertain ?? this.pinUncertain,
    );
  }

  @override
  List<Object?> get props => [
    devices,
    open,
    openErrors,
    names,
    selectedId,
    selectedName,
    connectivity,
    connectivityDeviceId,
    connectivityDeviceName,
    errorDetail,
    pinUncertain,
  ];
}
