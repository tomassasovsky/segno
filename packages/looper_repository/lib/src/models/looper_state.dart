import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/output_setup.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:looper_repository/src/models/tuner_reading.dart';

/// The single source of looper truth: transport, the tracks, and engine status,
/// projected from one engine snapshot.
class LooperState extends Equatable {
  /// Creates a [LooperState].
  const LooperState({
    this.transport = const TransportState(),
    this.tracks = const [],
    this.status = const EngineStatus(),
    this.outputEnabledMask = 0xFFFFFFFF,
    this.masterEffects = const [],
    this.masterChainEnabled = true,
    this.tuner = const TunerReading(),
    this.inputSetup = const InputSetup(),
    this.outputSetup = const OutputSetup(),
    this.outputBusCount = 0,
    this.tailResetRev = 0,
    this.inputPeaks = const [],
    this.monitorPeaks = const [],
    this.outputPeaks = const [],
  });

  /// Master loop transport.
  final TransportState transport;

  /// The looper tracks, indexed by channel.
  final List<Track> tracks;

  /// Device + engine health.
  final EngineStatus status;

  /// Structural output gate: bit c set => hardware output c is enabled (a
  /// routing target). A cleared bit removes that output from the mix while its
  /// stored route masks are preserved (re-enabling restores them). All outputs
  /// are enabled by default; only bits in `[0, status.outputChannels)` matter.
  final int outputEnabledMask;

  /// The Master insert chain on the summed track mix, in processing order
  /// (FX v3 part 1b). Empty == bit-identical output.
  final List<TrackEffect> masterEffects;

  /// Whether the Master insert chain is engaged (R15).
  final bool masterChainEnabled;

  /// What the chromatic tuner hears on its armed input. Disarmed by default,
  /// and disarmed costs nothing — the engine gates detection on the arm.
  final TunerReading tuner;

  /// The per-input capture setup (trim, pan, pairs), the repository's own
  /// remembered intent (accepted design, Audio routing).
  final InputSetup inputSetup;

  /// The output setup (level, mute, Stereo/Mono, balance per destination),
  /// the repository's own remembered intent (accepted design, Output setup).
  final OutputSetup outputSetup;

  /// How many output destinations the open device has (one per stereo pair
  /// of its outputs; an odd count leaves a single-jack last one); `0` while
  /// no device is open.
  final int outputBusCount;

  /// Advances once per Cut all sound the engine applied.
  final int tailResetRev;

  /// Each hardware input's raw block peak, `0..1`, one entry per channel the
  /// device has (before conditioning and trim). Live.
  final List<double> inputPeaks;

  /// What each input's monitor sends to the outputs, per channel the device
  /// has (`0` while it is off or muted). Live.
  final List<double> monitorPeaks;

  /// Each hardware output's block peak after the master gain and limiter,
  /// per channel the device has. Live.
  final List<double> outputPeaks;

  /// Whether hardware output [output] is currently enabled (a routing target).
  bool isOutputEnabled(int output) =>
      output < 0 || (outputEnabledMask & (1 << output)) != 0;

  /// The first track (back-compat convenience for single-track callers).
  Track get track => tracks.isNotEmpty ? tracks.first : const Track();

  /// Whether any track holds recorded audio.
  bool get hasContent => tracks.any((t) => t.hasContent);

  /// Whether EVERY track is one-shot — the rig-wide answer the console's
  /// one-shot switch shows.
  ///
  /// Guarded on non-empty deliberately: `every` on an empty list is vacuously
  /// true, so a stopped engine reporting no tracks would otherwise answer
  /// "yes, all of them", which is never what the question means.
  bool get allOneShot => tracks.isNotEmpty && tracks.every((t) => t.oneShot);

  @override
  List<Object?> get props => [
    transport,
    tracks,
    status,
    outputEnabledMask,
    masterEffects,
    masterChainEnabled,
    tuner,
    inputSetup,
    outputSetup,
    outputBusCount,
    tailResetRev,
    inputPeaks,
    monitorPeaks,
    outputPeaks,
  ];
}
