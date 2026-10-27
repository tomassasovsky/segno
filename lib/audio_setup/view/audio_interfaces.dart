import 'package:flutter/foundation.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/l10n/l10n.dart';

/// One interface, both directions.
///
/// The host lists playback and capture separately while one box is both, so
/// the Device page pairs them **by name**: that is the only thing the two
/// halves reliably share, and `18 in · 20 out` is one device's fact, not two
/// devices'.
@immutable
class AudioInterface {
  /// Creates an [AudioInterface].
  const AudioInterface({
    required this.name,
    this.playbackId = '',
    this.captureId = '',
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.absent = false,
  });

  /// The name the host gives it.
  final String name;

  /// The playback half's id (empty when the host lists none).
  final String playbackId;

  /// The capture half's id (empty when the host lists none).
  final String captureId;

  /// Capture channels. `0` means UNKNOWN, never "no channels".
  final int inputChannels;

  /// Playback channels. `0` means UNKNOWN.
  final int outputChannels;

  /// Whether this is the pinned device the host is no longer reporting.
  final bool absent;

  @override
  bool operator ==(Object other) =>
      other is AudioInterface &&
      other.name == name &&
      other.playbackId == playbackId &&
      other.captureId == captureId &&
      other.inputChannels == inputChannels &&
      other.outputChannels == outputChannels &&
      other.absent == absent;

  @override
  int get hashCode => Object.hash(
    name,
    playbackId,
    captureId,
    inputChannels,
    outputChannels,
    absent,
  );
}

/// The host's devices, paired by name, plus the pinned one ([playbackId],
/// [captureId]) it is no longer reporting.
List<AudioInterface> audioInterfacesOf(
  AudioSetupState state, {
  required String playbackId,
  required String captureId,
}) {
  final paired = <String, AudioInterface>{};
  for (final device in state.playbackDevices) {
    // By NAME, which is what makes one interface one row. But a name whose
    // playback slot is already filled belongs to another BOX rather than to
    // this one's other half (two identical interfaces answer to one name), so
    // it is keyed apart instead of overwriting the entry already listed.
    final key = (paired[device.name]?.playbackId.isNotEmpty ?? false)
        ? '${device.name} ${device.id}'
        : device.name;
    final existing = paired[key];
    paired[key] = AudioInterface(
      name: device.name,
      playbackId: device.id,
      captureId: existing?.captureId ?? '',
      inputChannels: existing?.inputChannels ?? 0,
      outputChannels: device.outputChannels,
    );
  }
  for (final device in state.captureDevices) {
    final key = (paired[device.name]?.captureId.isNotEmpty ?? false)
        ? '${device.name} ${device.id}'
        : device.name;
    final existing = paired[key];
    paired[key] = AudioInterface(
      name: device.name,
      playbackId: existing?.playbackId ?? '',
      captureId: device.id,
      inputChannels: device.inputChannels,
      outputChannels: existing?.outputChannels ?? 0,
    );
  }
  final devices = paired.values.toList();
  // Against the host's RAW list rather than the paired one: the pairing above
  // re-keys entries, and asking it whether an id is still there would call a
  // device that is plugged in "unplugged".
  final present = state.devices.any(
    (device) => device.id == playbackId || device.id == captureId,
  );
  // A pinned device the host has stopped reporting stays listed: a pin still
  // points at it, and dropping it would read as a device you never had.
  if (!present && (playbackId.isNotEmpty || captureId.isNotEmpty)) {
    devices.add(
      AudioInterface(
        // The last name it answered to, when it is the running pin: a drafted
        // interface that left never had that name.
        name:
            state.connectivityDeviceName.isNotEmpty &&
                playbackId == state.playbackDeviceId &&
                captureId == state.captureDeviceId
            ? state.connectivityDeviceName
            : (playbackId.isNotEmpty ? playbackId : captureId),
        playbackId: playbackId,
        captureId: captureId,
        absent: true,
      ),
    );
  }
  return devices;
}

/// The listed interface pinned by [playbackId] and [captureId], or null when
/// nothing is pinned.
AudioInterface? pinnedAudioInterface(
  List<AudioInterface> devices, {
  required String playbackId,
  required String captureId,
}) {
  if (playbackId.isEmpty && captureId.isEmpty) return null;
  for (final device in devices) {
    if (device.playbackId == playbackId && device.captureId == captureId) {
      return device;
    }
  }
  return null;
}

/// `18 in · 20 out`, one side of it, or nothing: `0` is UNKNOWN, so it is
/// omitted rather than printed as a claim of no channels.
String? audioChannelCounts(AppLocalizations l10n, AudioInterface device) {
  final inputs = device.inputChannels;
  final outputs = device.outputChannels;
  if (inputs > 0 && outputs > 0) {
    return l10n.audioDeviceChannels(inputs, outputs);
  }
  if (inputs > 0) return l10n.audioDeviceInputsOnly(inputs);
  if (outputs > 0) return l10n.audioDeviceOutputsOnly(outputs);
  return null;
}
