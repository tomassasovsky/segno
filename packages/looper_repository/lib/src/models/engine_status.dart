import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/audio_config.dart';

/// Device + engine health, projected from the engine snapshot.
class EngineStatus extends Equatable {
  /// Creates an [EngineStatus].
  const EngineStatus({
    this.deviceName = '',
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.latencyState = LatencyState.idle,
    this.measuredLatencyMs = -1,
    this.xrunCount = 0,
    this.isConnected = false,
    this.devicePresent = false,
    this.excludedInputMask = 0,
    this.inputClipMask = 0,
    this.inputCondMask = 0,
    this.recordOffsetFrames = 0,
    this.fxAddedLatencyFrames = 0,
    this.activeBackend = AudioBackend.miniaudio,
  });

  /// Active device name, or empty when stopped.
  final String deviceName;

  /// Negotiated sample rate in Hz.
  final int sampleRate;

  /// Negotiated buffer (period) size in frames.
  final int bufferFrames;

  /// Negotiated hardware capture channel count.
  final int inputChannels;

  /// Negotiated hardware playback channel count.
  final int outputChannels;

  /// Phase of the latency harness.
  final LatencyState latencyState;

  /// Measured round-trip latency in ms, valid when [latencyState] is
  /// [LatencyState.done].
  final double measuredLatencyMs;

  /// Real device dropouts since the device started, every class summed.
  ///
  /// No longer "reserved": the ALSA backend now reports its `-EPIPE`
  /// underrun/overrun recoveries and its slipped-playback resyncs through this
  /// (native #722), alongside the Windows ASIO overload notification that used
  /// to be its only producer. Still `0` on CoreAudio, which exposes no xrun
  /// signal — read the gap detector in `LooperRepository.callbackTelemetry`
  /// there instead, which also carries the per-class breakdown.
  ///
  /// This one number stays on the status because it moves at human pace (a
  /// dropout is an event, not a tick); the per-callback counters deliberately
  /// do not — see `CallbackTelemetry`.
  final int xrunCount;

  /// Whether the audio device is open and running.
  final bool isConnected;

  /// Whether the pinned (or default) device is currently present.
  ///
  /// Distinct from [isConnected]: a pinned device can be lost (unplugged) while
  /// the engine object still reports running until it is restarted. The
  /// disconnect signal the reconnect supervisor and the banner are driven from.
  final bool devicePresent;

  /// Bitmask of input channels excluded as loopback (never recorded, monitored,
  /// or routable). `0` when nothing is excluded (always so off macOS).
  final int excludedInputMask;

  /// HOT inputs: bit `c` set means a rail-run (4 consecutive raw samples at
  /// `|s| >= 0.999`) was seen on input `c` within the last 1.5 s of processed
  /// audio — the clamp signature of an overdriven ADC, not a loud transient.
  ///
  /// Detected on the RAW device buffer, upstream of the conditioning stage,
  /// so a clipped input reads HOT even when conditioning has reshaped what
  /// records. Loopback-excluded inputs never flag.
  final int inputClipMask;

  /// Conditioning activity: bit `c` set means input `c`'s conditioning stage
  /// is currently active — enabled and not loopback-excluded, i.e. the stage
  /// actually runs on the audio path.
  final int inputCondMask;

  /// Whether input [input] is currently HOT (see [inputClipMask]).
  bool isInputHot(int input) =>
      input >= 0 && input < 32 && (inputClipMask & (1 << input)) != 0;

  /// Whether input [input]'s conditioning stage is currently active (see
  /// [inputCondMask]).
  bool isInputConditioned(int input) =>
      input >= 0 && input < 32 && (inputCondMask & (1 << input)) != 0;

  /// Record-offset latency compensation in frames (auto-set by a measurement).
  final int recordOffsetFrames;

  /// Added latency (frames) of the highest-latency effect engaged in any
  /// audible or monitored lane chain — the maximum across active effects. Today
  /// only the formant-preserving octaver contributes; `0` when no octaver is
  /// engaged. Purely informational (see [fxAddedLatencyMs]); it never feeds
  /// [recordOffsetFrames] or any compensation.
  final int fxAddedLatencyFrames;

  /// [fxAddedLatencyFrames] expressed in milliseconds at the current
  /// [sampleRate]; `0` when no effect adds latency or the rate is unknown.
  double get fxAddedLatencyMs =>
      sampleRate > 0 ? fxAddedLatencyFrames * 1000 / sampleRate : 0;

  /// The device backend actually running (negotiated) — the reality behind the
  /// requested [EngineConfig.backend] intent. On Windows this is always
  /// [AudioBackend.asio]; on macOS/Linux it is [AudioBackend.miniaudio].
  final AudioBackend activeBackend;

  /// Whether a latency measurement has completed.
  bool get hasMeasuredLatency => latencyState == LatencyState.done;

  @override
  List<Object?> get props => [
    deviceName,
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    latencyState,
    measuredLatencyMs,
    xrunCount,
    isConnected,
    devicePresent,
    excludedInputMask,
    inputClipMask,
    inputCondMask,
    recordOffsetFrames,
    fxAddedLatencyFrames,
    activeBackend,
  ];
}
