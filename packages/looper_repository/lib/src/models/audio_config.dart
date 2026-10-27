import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

/// Phase of the round-trip latency measurement harness. Domain mirror of the
/// engine's `LatencyState`.
enum LatencyState {
  /// No measurement has been requested.
  idle,

  /// An impulse has been emitted and the engine is waiting for it to return.
  measuring,

  /// A measurement completed; the measured latency is valid.
  done,

  /// No loopback signal was detected within the measurement window.
  timeout,

  /// The measurement was cancelled; the record offset is unchanged.
  cancelled,
}

/// Classification of a cable-free loopback path used to auto-measure latency.
/// Domain mirror of the engine's `LoopbackKind`.
enum LoopbackKind {
  /// No loopback path detected.
  none,

  /// The device backend's built-in output loopback (detected, not auto-routed).
  backendLoopback,

  /// PulseAudio "Monitor of …" source (Linux).
  monitor,

  /// A named virtual audio driver (BlackHole, VB-Cable, …).
  virtualDevice,
}

/// A hardware audio device discovered by the repository. Domain mirror of the
/// engine's `AudioDevice`.
class AudioDevice extends Equatable {
  /// Creates an [AudioDevice].
  const AudioDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.isInput,
    this.inputChannels = 0,
    this.outputChannels = 0,
  });

  /// The backend-specific device id, suitable for pinning via
  /// [EngineConfig.playbackDeviceId] / [EngineConfig.captureDeviceId].
  final String id;

  /// The human-readable device label.
  final String name;

  /// Whether this is the system default device for its direction.
  final bool isDefault;

  /// Whether this is a capture (input) device; `false` for a playback device.
  final bool isInput;

  /// The device's hardware capture channel count, or `0` when unknown.
  final int inputChannels;

  /// The device's hardware playback channel count, or `0` when unknown.
  final int outputChannels;

  @override
  List<Object?> get props => [
    id,
    name,
    isDefault,
    isInput,
    inputChannels,
    outputChannels,
  ];
}

/// Requested audio device configuration. Domain mirror of the engine's
/// `EngineConfig`; any field left at `0`/empty defers to the device default.
class EngineConfig extends Equatable {
  /// Creates an [EngineConfig].
  const EngineConfig({
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopFrames = 0,
    this.useLoopbackCapture = false,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
  });

  /// Requested sample rate in Hz, or `0` for the device default.
  final int sampleRate;

  /// Requested period (buffer) size in frames, or `0` for the device default.
  final int bufferFrames;

  /// Requested hardware capture channel count, or `0` for the device default.
  final int inputChannels;

  /// Requested hardware playback channel count, or `0` for the device default.
  final int outputChannels;

  /// Per-track loop buffer cap in frames, or `0` for the engine default.
  final int maxLoopFrames;

  /// Whether the engine should capture from a detected loopback device.
  final bool useLoopbackCapture;

  /// The id of the playback device to open, or empty for the system default.
  final String playbackDeviceId;

  /// The id of the capture device to open, or empty for the system default.
  final String captureDeviceId;

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopFrames,
    useLoopbackCapture,
    playbackDeviceId,
    captureDeviceId,
  ];
}

/// The result of loopback detection. Domain mirror of the engine's
/// `LoopbackInfo`.
class LoopbackInfo extends Equatable {
  /// Creates a [LoopbackInfo].
  const LoopbackInfo({
    required this.available,
    required this.kind,
    required this.deviceName,
  });

  /// A result indicating no loopback path is available.
  const LoopbackInfo.none()
    : available = false,
      kind = LoopbackKind.none,
      deviceName = '';

  /// Whether a cable-free loopback path was found.
  final bool available;

  /// The kind of loopback detected.
  final LoopbackKind kind;

  /// The capture device to open for an auto-measurement, or empty when the
  /// loopback is the backend's built-in path that is not auto-routed.
  final String deviceName;

  /// Whether the engine can auto-route capture from this loopback.
  bool get isAutoRoutable => available && deviceName.isNotEmpty;

  @override
  List<Object?> get props => [available, kind, deviceName];
}

// --- Boundary mappers (package-internal; not exported from the barrel). ---

/// Maps an engine `LatencyState` to its domain mirror.
LatencyState latencyStateFromEngine(engine.LatencyState state) =>
    switch (state) {
      engine.LatencyState.idle => LatencyState.idle,
      engine.LatencyState.measuring => LatencyState.measuring,
      engine.LatencyState.done => LatencyState.done,
      engine.LatencyState.timeout => LatencyState.timeout,
      engine.LatencyState.cancelled => LatencyState.cancelled,
    };

/// Maps an engine `LoopbackKind` to its domain mirror.
LoopbackKind loopbackKindFromEngine(engine.LoopbackKind kind) => switch (kind) {
  engine.LoopbackKind.none => LoopbackKind.none,
  engine.LoopbackKind.backendLoopback => LoopbackKind.backendLoopback,
  engine.LoopbackKind.monitor => LoopbackKind.monitor,
  engine.LoopbackKind.virtualDevice => LoopbackKind.virtualDevice,
};

/// Maps an engine `AudioDevice` to its domain mirror.
AudioDevice audioDeviceFromEngine(engine.AudioDevice device) => AudioDevice(
  id: device.id,
  name: device.name,
  isDefault: device.isDefault,
  isInput: device.isInput,
  inputChannels: device.inputChannels,
  outputChannels: device.outputChannels,
);

/// Maps an engine `LoopbackInfo` to its domain mirror.
LoopbackInfo loopbackInfoFromEngine(engine.LoopbackInfo info) => LoopbackInfo(
  available: info.available,
  kind: loopbackKindFromEngine(info.kind),
  deviceName: info.deviceName,
);

/// Maps a domain [EngineConfig] to the engine type at the repository boundary.
/// [keepMaterial] asks a reopen to refuse rather than clear the loops.
engine.EngineConfig engineConfigToEngine(
  EngineConfig config, {
  bool keepMaterial = false,
}) => engine.EngineConfig(
  sampleRate: config.sampleRate,
  bufferFrames: config.bufferFrames,
  inputChannels: config.inputChannels,
  outputChannels: config.outputChannels,
  maxLoopFrames: config.maxLoopFrames,
  useLoopbackCapture: config.useLoopbackCapture,
  playbackDeviceId: config.playbackDeviceId,
  captureDeviceId: config.captureDeviceId,
  keepMaterial: keepMaterial,
);
