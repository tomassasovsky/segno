import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/engine_status.dart';
import 'package:looper_repository/src/models/fx_chain_envelope.dart';
import 'package:looper_repository/src/models/input_setup.dart';
import 'package:looper_repository/src/models/output_setup.dart';
import 'package:looper_repository/src/models/track.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:looper_repository/src/models/transport_state.dart';
import 'package:looper_repository/src/models/tuner_reading.dart';
import 'package:segno_engine/segno_engine.dart'
    show LooperMode, PitchMode, SpeedFactor, TempoFollowState, TrackState;

/// The single source of looper truth: transport, the tracks, and engine status,
/// projected from one engine snapshot.
class LooperState extends Equatable {
  /// Creates a [LooperState].
  const LooperState({
    this.transport = const TransportState(),
    this.tracks = const [],
    this.status = const EngineStatus(),
    this.mixGeneration = 0,
    this.outputEnabledMask = 0xFFFFFFFF,
    this.outputChains = const {},
    this.allTracksChain = const FxChainEnvelope(),
    this.tuner = const TunerReading(),
    this.inputSetup = const InputSetup.empty(),
    this.outputSetup = const OutputSetup(),
    this.outputBusCount = 0,
    this.tailResetRev = 0,
    this.laneInputs = const {},
    this.laneOutputs = const {},
    this.laneCounts = const {},
    this.recordingInputLocks = const {},
    this.speed = SpeedFactor.normal,
    this.transposeBypass = false,
    this.recordedTempoBpm = 0,
    this.tempoFollow = TempoFollowState.free,
    this.defaultFollowTempo = false,
    this.defaultPitchMode = PitchMode.unchanged,
  });

  /// Master loop transport.
  final TransportState transport;

  /// The looper tracks, indexed by channel.
  final List<Track> tracks;

  /// Device + engine health.
  final EngineStatus status;

  /// Repository lifetime identity, including same-device reopen and session
  /// replacement. Changes even when the native snapshot otherwise matches.
  final int mixGeneration;

  /// Structural output gate: bit c set => hardware output c is enabled (a
  /// routing target). A cleared bit removes that output from the mix while its
  /// stored route masks are preserved (re-enabling restores them). All outputs
  /// are enabled by default; only bits in `[0, status.outputChannels)` matter.
  final int outputEnabledMask;

  /// Every configured output destination's post-sum chain, keyed by bus
  /// (slice 3f) — each with its entries and its chain-enabled flag (R15).
  /// A destination with no entry has no chain: bit-identical output.
  final Map<int, FxChainEnvelope> outputChains;

  /// The recorded-mix chain over the sum of the tracks.
  final FxChainEnvelope allTracksChain;

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

  /// Confirmed future source choices, including inactive slots.
  final Map<(int, int), int> laneInputs;

  /// Confirmed output routes, including missing destinations and future slots.
  final Map<(int, int), int> laneOutputs;

  /// Confirmed active lane counts for tracks with or without audio.
  final Map<int, int> laneCounts;

  /// Tracks fenced by accepted record requests or active capture.
  final Set<int> recordingInputLocks;

  /// The global Speed every recorded track plays at (#1179), as the engine
  /// published it. [SpeedFactor.normal] until a request lands.
  final SpeedFactor speed;

  /// Whether Transpose is bypassed globally (#1179): every track plays dry,
  /// its stored pitch kept in `Track.transpose`.
  final bool transposeBypass;

  /// The tempo the takes were recorded at (#1179), 0 with no material.
  final double recordedTempoBpm;

  /// What a song-tempo change does now, and why not when it is locked.
  final TempoFollowState tempoFollow;

  /// The Follow tempo default every track inherits (#1179): the
  /// repository's accepted setting, `Track.followTempoOverride` beside it.
  final bool defaultFollowTempo;

  /// The Pitch default every track inherits (#1179).
  final PitchMode defaultPitchMode;

  /// Output destination [bus]'s configured entries.
  List<TrackEffect> outputEffects(int bus) =>
      outputChains[bus]?.entries ?? const [];

  /// Whether output destination [bus]'s chain is engaged.
  bool outputChainEnabled(int bus) => outputChains[bus]?.chainEnabled ?? true;

  /// Whether hardware output [output] is currently enabled (a routing target).
  bool isOutputEnabled(int output) =>
      output < 0 || (outputEnabledMask & (1 << output)) != 0;

  /// The first track (back-compat convenience for single-track callers).
  Track get track => tracks.isNotEmpty ? tracks.first : const Track();

  /// Whether any track holds recorded audio.
  bool get hasContent => tracks.any((t) => t.hasContent);

  /// Whether [channel] is a section that plays one at a time (#1077, #1323):
  /// any Song track, or a Band track other than an established primary (one
  /// that holds a single-loop take, the engine's `le_band_section`).
  bool isSection(int channel) {
    switch (transport.looperMode) {
      case LooperMode.song:
        return true;
      case LooperMode.band:
        final primary = transport.primaryTrack;
        if (primary < 0 || primary >= tracks.length || channel == primary) {
          return false;
        }
        final crown = tracks[primary];
        return crown.lengthFrames > 0 &&
            crown.multiple == 1 &&
            crown.syncDivisor == 0;
      case LooperMode.multi:
      case LooperMode.sync:
      case LooperMode.free:
        return false;
    }
  }

  /// The one section of [candidates] a "start everything" gesture starts in
  /// Song or Band (#1077, #1323): the one sounding now, else the one that
  /// sounded last, else the first; a muted section counts only when every
  /// one is muted. Null with no candidates.
  int? sectionToStart(Iterable<Track> candidates) {
    final content = candidates.where((track) => track.hasContent).toList();
    final audible = content.where((track) => !track.muted);
    final last = transport.songLastSection;
    return (audible
                .where(
                  (track) =>
                      track.state == TrackState.playing ||
                      track.state == TrackState.overdubbing,
                )
                .firstOrNull ??
            audible.where((track) => track.channel == last).firstOrNull ??
            audible.firstOrNull ??
            content.firstOrNull)
        ?.channel;
  }

  /// The Song or Band section waiting for the sounding one's end (#1077,
  /// #1323), or null: only in Song and Band, only on a track that is not
  /// capturing and holds a take, or is empty with a waiting Record. The one
  /// rule the pedal projection and the stage both read.
  int? get songWaitingSection {
    final queued = transport.songQueuedTrack;
    if ((transport.looperMode != LooperMode.song &&
            transport.looperMode != LooperMode.band) ||
        queued < 0 ||
        queued >= tracks.length) {
      return null;
    }
    final track = tracks[queued];
    if (track.isCapturing) return null;
    return track.hasContent || transport.songQueueRecord ? queued : null;
  }

  @override
  List<Object?> get props => [
    transport,
    tracks,
    status,
    mixGeneration,
    outputEnabledMask,
    outputChains,
    allTracksChain,
    tuner,
    inputSetup,
    outputSetup,
    outputBusCount,
    tailResetRev,
    laneInputs,
    laneOutputs,
    laneCounts,
    recordingInputLocks,
    speed,
    transposeBypass,
    recordedTempoBpm,
    tempoFollow,
    defaultFollowTempo,
    defaultPitchMode,
  ];
}
