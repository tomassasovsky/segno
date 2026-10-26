part of 'audio_setup_cubit.dart';

/// A categorized audio-setup failure surfaced in the audio-settings error
/// banner.
enum AudioSetupError {
  /// The engine failed to open or reopen the device.
  openDeviceFailed,
}

/// How the last requested config turned out.
///
/// The Audio face has no Status tab: a figure shown both beside the setting
/// that decides it and on a page of its own is a figure that can disagree with
/// itself. So the Device tab reports the config's own outcome instead.
///
/// **There is no in-flight member, because there is no in-flight state.**
/// `LooperRepository.startEngine` is a synchronous FFI call — the device is
/// open, or it has failed, by the time it returns, and a slow driver blocks the
/// isolate rather than yielding a frame to draw a banner in. A "reopening…"
/// state would be unreachable UI.
enum ConfigPhase {
  /// The rig is running what the rows say.
  settled,

  /// The device is not running what was asked for — it either refused the
  /// config outright, or opened and negotiated something else. The selection
  /// has already moved to what it IS running; this is what says the request
  /// did not survive.
  refused,
}

/// Whether an apply is waiting on "Apply audio settings?" (pen 28/04).
enum ApplyPhase {
  /// Nothing is waiting.
  idle,

  /// Music is playing, so the request waits for "Stop audio and apply" or
  /// Cancel.
  confirming,
}

/// Why the last request was refused before anything changed (#1270 Part 3a).
class ApplyRefusal extends Equatable {
  /// Refused because [busyKind] is in flight: the guard table's name of the
  /// operation a device change must not overlap (`capture` for a take).
  const ApplyRefusal.busy(String this.busyKind)
    : overBudgetRate = null,
      refusedDevice = null,
      settingsRefused = false;

  /// Refused because the effects would not fit at [overBudgetRate] (D19).
  const ApplyRefusal.overBudgetRate(int this.overBudgetRate)
    : busyKind = null,
      refusedDevice = null,
      settingsRefused = false;

  /// Refused by the interface: [refusedDevice] would not open, and the
  /// previous one runs again.
  const ApplyRefusal.deviceRefused(String this.refusedDevice)
    : busyKind = null,
      overBudgetRate = null,
      settingsRefused = false;

  /// Refused by the interface for a change that moved neither the device nor
  /// the rates (a loop cap): the previous settings run again.
  const ApplyRefusal.settingsRefused()
    : busyKind = null,
      overBudgetRate = null,
      refusedDevice = null,
      settingsRefused = true;

  /// The blocking operation's `GuardKind` name, for a busy refusal.
  final String? busyKind;

  /// The sample rate the effects would not fit at.
  final int? overBudgetRate;

  /// The interface that would not open.
  final String? refusedDevice;

  /// Whether the interface refused settings that moved neither the device
  /// nor the rates.
  final bool settingsRefused;

  @override
  List<Object?> get props => [
    busyKind,
    overBudgetRate,
    refusedDevice,
    settingsRefused,
  ];
}

/// Whether the audio device is currently open.
enum AudioSetupStatus {
  /// The engine is stopped; the device is closed.
  stopped,

  /// The engine is running; the device is open.
  running,

  /// The engine failed to start.
  error,
}

/// The most recent pinned-device connectivity transition, used to drive a
/// transient connect/disconnect banner. Derived in the cubit by diffing
/// `EngineStatus.devicePresent`; not a separate stream.
enum DeviceConnectivity {
  /// No transition to report.
  none,

  /// The pinned device just went absent (1→0).
  lost,

  /// The pinned device just came back (0→1) with every loop retained.
  restored,

  /// The pinned device just came back and the loops were retained except
  /// the tracks a still-unapplied Clear/Undo/Redo/cancel had made uncertain
  /// (named by [AudioSetupState.engineStatus]'s `reopen.droppedChannels`).
  /// Low stakes — the rig plays on — so it is a transient toast.
  restoredPartial,

  /// The pinned device just came back at another sample rate (or loop cap)
  /// and every loop was cleared; the saved Session is the way back. The one
  /// standing notice of the return, with the Sessions action, until the user
  /// acts (#1140).
  restoredCleared,

  /// The console booted with its pinned interface absent and waits for it:
  /// audio starts on its own when it appears (`AudioRecoveryCubit`). The
  /// stage holds the same red strip as [lost], with the waiting sentence.
  waiting,
}

/// State for the audio setup feature: the user's requested device options plus
/// the live engine status projected from the repository.
class AudioSetupState extends Equatable {
  /// Creates an [AudioSetupState].
  const AudioSetupState({
    this.sampleRate = 48000,
    this.bufferFrames = 128,
    this.maxLoopMinutes = 0,
    this.status = AudioSetupStatus.stopped,
    this.engineStatus = const EngineStatus(),
    this.loopback = const LoopbackInfo.none(),
    this.devices = const [],
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.backend = AudioBackend.miniaudio,
    this.asioDriver = '',
    this.deviceConnectivity = DeviceConnectivity.none,
    this.connectivityDeviceName = '',
    this.phase = ConfigPhase.settled,
    this.requestedRate = 0,
    this.requestedBuffer = 0,
    this.actualRate = 0,
    this.actualBuffer = 0,
    this.error,
    this.errorDetail,
    this.applyPhase = ApplyPhase.idle,
    this.refusal,
    this.hasContent = false,
  });

  /// Requested sample rate in Hz.
  final int sampleRate;

  /// Requested buffer (period) size in frames.
  final int bufferFrames;

  /// Maximum loop length per track, in whole minutes. `0` defers to the engine
  /// default. Applied on the next start (buffers are allocated at start).
  final int maxLoopMinutes;

  /// High-level lifecycle status.
  final AudioSetupStatus status;

  /// Live engine/device status from the repository.
  final EngineStatus engineStatus;

  /// The detected cable-free loopback path (if any), which capture is routed
  /// to when no capture device is pinned.
  final LoopbackInfo loopback;

  /// The host's enumerated audio devices (playback + capture) for the pickers.
  final List<AudioDevice> devices;

  /// Selected playback device id, or empty for the system default.
  final String playbackDeviceId;

  /// Selected capture device id, or empty for the system default.
  final String captureDeviceId;

  /// The saved backend, carried through to the engine and the saved config
  /// unchanged until those fields go (#1270 Part 2).
  final AudioBackend backend;

  /// The saved ASIO driver id, carried through on the same terms as
  /// [backend].
  final String asioDriver;

  /// What the last requested config is doing — the Device tab's own banner.
  final ConfigPhase phase;

  /// The rate that was ASKED for, kept only while [phase] is not settled.
  ///
  /// The banner names it: "reopening at 96 kHz", and on a refusal "could not
  /// open at 96 kHz". The SELECTION does not hold it — that snaps to whatever
  /// the device gave, so the rows never report a setting the rig is not
  /// running.
  final int requestedRate;

  /// The buffer that was asked for, on the same terms as [requestedRate].
  final int requestedBuffer;

  /// The rate the device is actually clocked at, kept only while [phase] is
  /// not settled.
  ///
  /// Distinct from [sampleRate] because the selection can only ever hold a
  /// value the chooser offers: a device that negotiates a rate outside
  /// [sampleRates] leaves the selection where it was, and this is where
  /// the real figure lives so the banner can still name it.
  final int actualRate;

  /// The period the device is actually running, on the same terms as
  /// [actualRate]. This is the one that drifts in practice — a negotiated
  /// buffer is an ALSA quantum or an ASIO granularity step, rarely one of
  /// [bufferSizes].
  final int actualBuffer;

  /// The most recent pinned-device connectivity transition (drives the banner).
  final DeviceConnectivity deviceConnectivity;

  /// Name of the device involved in the latest [deviceConnectivity] transition.
  final String connectivityDeviceName;

  /// The categorized error when [status] is [AudioSetupStatus.error].
  final AudioSetupError? error;

  /// Engine error detail (e.g. result name) for [error].
  final String? errorDetail;

  /// Whether an apply waits on "Apply audio settings?".
  final ApplyPhase applyPhase;

  /// Why the last request was refused, or `null`; cleared by the next
  /// request that applies.
  final ApplyRefusal? refusal;

  /// Whether any track holds recorded material. While it does, the sample
  /// rate and the maximum loop length are locked: either would clear the
  /// engine (D2, the owner's Q3 answer).
  final bool hasContent;

  /// Playback (output) devices from [devices].
  List<AudioDevice> get playbackDevices =>
      devices.where((d) => !d.isInput).toList();

  /// Capture (input) devices from [devices].
  List<AudioDevice> get captureDevices =>
      devices.where((d) => d.isInput).toList();

  /// Selectable sample rates.
  static const sampleRates = [44100, 48000, 96000];

  /// Selectable buffer sizes.
  static const bufferSizes = [64, 128, 256, 512];

  /// Selectable max-loop-length options, in minutes. `0` is the engine default.
  static const maxLoopMinuteOptions = [0, 1, 2, 5, 10];

  /// The round-trip latency [bufferFrames] costs at [sampleRate], in ms.
  ///
  /// **An estimate, and said to be one**: two buffer periods, one in and one
  /// out. It cannot include the converter's own delay, which no host reports;
  /// only a cable measurement does.
  ///
  /// It exists because `AUDIO / settings-rate` gives **every** buffer option
  /// its own cost, not only the chosen one: a list where the current pick is
  /// the only annotated row cannot be used to choose.
  static double estimatedRoundTripMs(int bufferFrames, int sampleRate) =>
      sampleRate <= 0 || bufferFrames <= 0
      ? 0
      : bufferFrames * 2 * 1000 / sampleRate;

  /// Returns a copy with the given fields replaced.
  AudioSetupState copyWith({
    int? sampleRate,
    int? bufferFrames,
    int? maxLoopMinutes,
    AudioSetupStatus? status,
    EngineStatus? engineStatus,
    LoopbackInfo? loopback,
    List<AudioDevice>? devices,
    String? playbackDeviceId,
    String? captureDeviceId,
    AudioBackend? backend,
    String? asioDriver,
    DeviceConnectivity? deviceConnectivity,
    String? connectivityDeviceName,
    ConfigPhase? phase,
    int? requestedRate,
    int? requestedBuffer,
    int? actualRate,
    int? actualBuffer,
    AudioSetupError? error,
    String? errorDetail,
    bool clearError = false,
    ApplyPhase? applyPhase,
    ApplyRefusal? refusal,
    bool clearRefusal = false,
    bool? hasContent,
  }) {
    return AudioSetupState(
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
      maxLoopMinutes: maxLoopMinutes ?? this.maxLoopMinutes,
      status: status ?? this.status,
      engineStatus: engineStatus ?? this.engineStatus,
      loopback: loopback ?? this.loopback,
      devices: devices ?? this.devices,
      playbackDeviceId: playbackDeviceId ?? this.playbackDeviceId,
      captureDeviceId: captureDeviceId ?? this.captureDeviceId,
      backend: backend ?? this.backend,
      asioDriver: asioDriver ?? this.asioDriver,
      deviceConnectivity: deviceConnectivity ?? this.deviceConnectivity,
      connectivityDeviceName:
          connectivityDeviceName ?? this.connectivityDeviceName,
      phase: phase ?? this.phase,
      requestedRate: requestedRate ?? this.requestedRate,
      requestedBuffer: requestedBuffer ?? this.requestedBuffer,
      actualRate: actualRate ?? this.actualRate,
      actualBuffer: actualBuffer ?? this.actualBuffer,
      // [clearError] resets the error on a successful (re)start, since nullable
      // fields cannot otherwise be cleared through `?? this`.
      error: clearError ? null : (error ?? this.error),
      errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
      applyPhase: applyPhase ?? this.applyPhase,
      refusal: clearRefusal ? null : (refusal ?? this.refusal),
      hasContent: hasContent ?? this.hasContent,
    );
  }

  @override
  List<Object?> get props => [
    sampleRate,
    bufferFrames,
    maxLoopMinutes,
    status,
    engineStatus,
    loopback,
    devices,
    playbackDeviceId,
    captureDeviceId,
    backend,
    asioDriver,
    deviceConnectivity,
    connectivityDeviceName,
    phase,
    requestedRate,
    requestedBuffer,
    actualRate,
    actualBuffer,
    error,
    errorDetail,
    applyPhase,
    refusal,
    hasContent,
  ];
}
