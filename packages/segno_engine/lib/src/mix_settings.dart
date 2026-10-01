import 'dart:math' as math;

/// The lowest capture trim, in dB.
const double kMinInputTrimDb = -24;

/// The highest capture trim, in dB.
const double kMaxInputTrimDb = 12;

/// The trim step, in dB.
const double kInputTrimStepDb = 0.5;

/// The linear capture gain for a trim of [db] decibels.
double inputTrimGainOfDb(double db) => math.pow(10, db / 20).toDouble();

// Derive the boundary using the same conversion as the submitted values.
// A separately rounded decimal can reject the valid +12 dB endpoint before
// FFI rounds it to the engine's Float32 maximum.
final double _maxInputTrimGain = inputTrimGainOfDb(kMaxInputTrimDb);

/// Effective stereo gain and pan at a lane or monitor mix stage.
typedef StereoMix = ({double gain, double pan});

/// The controls of one output destination.
typedef OutputMix = ({double level, bool muted, bool mono, double balance});

/// Bounded compound live mix edit.
class EngineMixSettings {
  /// Creates an immutable edit.
  EngineMixSettings({
    required this.revision,
    Map<(int, int), StereoMix> lanes = const {},
    Map<(int, int), StereoMix> images = const {},
    Map<int, StereoMix> monitors = const {},
    Map<int, double> trims = const {},
    Map<int, bool> solos = const {},
    Map<int, OutputMix> outputs = const {},
    Map<(int, int), int> laneInputs = const {},
    Map<(int, int), int> laneOutputs = const {},
    Map<int, int> laneCounts = const {},
    Set<int> sourceTracks = const {},
  }) : lanes = Map.unmodifiable(lanes),
       images = Map.unmodifiable(images),
       monitors = Map.unmodifiable(monitors),
       trims = Map.unmodifiable(trims),
       solos = Map.unmodifiable(solos),
       outputs = Map.unmodifiable(outputs),
       laneInputs = Map.unmodifiable(laneInputs),
       laneOutputs = Map.unmodifiable(laneOutputs),
       laneCounts = Map.unmodifiable(laneCounts),
       sourceTracks = Set.unmodifiable(sourceTracks);

  /// Nonzero publication identity.
  final int revision;

  /// Track/lane addressed live level and track pan offset.
  final Map<(int, int), StereoMix> lanes;

  /// Recorded source balance (0..1) and pan, separate from live faders.
  final Map<(int, int), StereoMix> images;

  /// Hardware-input addressed live mix.
  final Map<int, StereoMix> monitors;

  /// Hardware-input addressed capture gain.
  final Map<int, double> trims;

  /// Independent track solo flags.
  final Map<int, bool> solos;

  /// Destination controls applied at the same publication boundary.
  final Map<int, OutputMix> outputs;

  /// Future capture sources, including inactive lane slots.
  final Map<(int, int), int> laneInputs;

  /// Playback destinations, retaining unavailable physical identities.
  final Map<(int, int), int> laneOutputs;

  /// Active counts published with their prepared lane buffers.
  final Map<int, int> laneCounts;

  /// Tracks whose capture state must permit the entire source edit.
  final Set<int> sourceTracks;

  /// Whether all addresses and values fit the native bounded payload.
  bool get isValid =>
      revision > 0 &&
      revision <= 0xffffffff &&
      laneInputs.entries.every(
        (e) => _validLane(e.key) && e.value >= -1 && e.value < 32,
      ) &&
      laneOutputs.entries.every(
        (e) => _validLane(e.key) && e.value >= 0 && e.value <= 0xffffffff,
      ) &&
      laneCounts.entries.every(
        (e) => e.key >= 0 && e.key < 8 && e.value >= 1 && e.value <= 8,
      ) &&
      sourceTracks.every((ch) => ch >= 0 && ch < 8) &&
      lanes.entries.every(
        (e) =>
            e.key.$1 >= 0 &&
            e.key.$1 < 8 &&
            e.key.$2 >= 0 &&
            e.key.$2 < 8 &&
            _validMix(e.value),
      ) &&
      images.entries.every(
        (e) =>
            e.key.$1 >= 0 &&
            e.key.$1 < 8 &&
            e.key.$2 >= 0 &&
            e.key.$2 < 8 &&
            _validMix(e.value) &&
            e.value.gain <= 1,
      ) &&
      monitors.entries.every(
        (e) => e.key >= 0 && e.key < 32 && _validMix(e.value),
      ) &&
      trims.entries.every(
        (e) =>
            e.key >= 0 &&
            e.key < 32 &&
            e.value.isFinite &&
            e.value >= 0 &&
            e.value <= _maxInputTrimGain,
      ) &&
      solos.keys.every((k) => k >= 0 && k < 8) &&
      outputs.entries.every(
        (e) =>
            e.key >= 0 &&
            e.key < 16 &&
            e.value.level.isFinite &&
            e.value.level >= 0 &&
            e.value.level <= 1 &&
            e.value.balance.isFinite &&
            e.value.balance >= -1 &&
            e.value.balance <= 1,
      );
}

bool _validLane((int, int) key) =>
    key.$1 >= 0 && key.$1 < 8 && key.$2 >= 0 && key.$2 < 8;

bool _validMix(StereoMix mix) =>
    mix.gain.isFinite &&
    mix.gain >= 0 &&
    mix.gain <= 2 &&
    mix.pan.isFinite &&
    mix.pan >= -1 &&
    mix.pan <= 1;

/// Frozen source balance and pan image for one accepted record/arm request. Applied at
/// actual capture start, and discarded if that request is cancelled.
class RecordImage {
  /// Creates a copied image.
  RecordImage({required this.revision, required Map<int, StereoMix> lanes})
    : lanes = Map.unmodifiable(lanes);

  /// Durable per-track publication identity, including very short takes.
  final int revision;

  /// Only lanes whose image is being established by this take.
  final Map<int, StereoMix> lanes;

  /// Whether this image fits the engine payload.
  bool get isValid =>
      revision > 0 &&
      revision <= 0xffffffff &&
      lanes.entries.every(
        (e) =>
            e.key >= 0 && e.key < 8 && _validMix(e.value) && e.value.gain <= 1,
      );
}
