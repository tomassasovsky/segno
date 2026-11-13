import 'package:daw_export/src/device_chain.dart';
import 'package:meta/meta.dart';

/// A DAW project ready to be rendered to an Ableton Live 12 `.als` set
/// (`buildAls`, `als_builder.dart`).
///
/// This is `daw_export`'s own input model. A test fixture builds it directly,
/// or `DawManifestReader` (`manifest_reader.dart`) builds it from a finished
/// capture's `performance.json`
/// (`docs/formats/performance-manifest-format.md`). The package depends on
/// neither `performance_repository` nor `segno_engine`, so it runs against
/// the documented file formats alone.
@immutable
class DawProject {
  /// Creates a [DawProject].
  ///
  /// A non-positive [tempoBpm] (a session manifest's "0 = unset") becomes
  /// [kFallbackTempoBpm], so the beat arithmetic in `als_builder.dart`
  /// never divides by or multiplies with zero.
  const new({required this.tracks, double tempoBpm = kFallbackTempoBpm})
    : tempoBpm = tempoBpm > 0 ? tempoBpm : kFallbackTempoBpm;

  /// One entry per recorded channel. A channel with nothing recorded is left
  /// out by whoever builds the project.
  final List<DawTrack> tracks;

  /// The set's tempo in BPM. A capture plays at one tempo from start to
  /// finish, so the set has no tempo changes.
  final double tempoBpm;
}

/// The tempo used when a capture has none: a session without a tempo, or
/// content recorded with the grid off.
const double kFallbackTempoBpm = 120;

/// What a [DawTrack] holds.
enum DawTrackKind {
  /// A looper track: its wet stem and its lane loops, or its dry stem when
  /// no wet stem stands for it. One per recorded looper track.
  loop,

  /// A looper track before its effects: its dry stem, played through the
  /// effects as plugins when the take recorded them.
  dry,

  /// A captured input, as its monitor played it.
  input,

  /// The captured output.
  master,
}

/// One Live audio track: what it plays in the Arrangement and the Session,
/// whether it plays at all, its volume automation, and its info text.
@immutable
class DawTrack {
  /// Creates a [DawTrack].
  const new({
    required this.name,
    this.kind = DawTrackKind.loop,
    this.active = true,
    this.arrangementClips = const [],
    this.sessionClips = const [],
    this.volume,
    this.devices = const [],
    this.info = '',
  });

  /// The track's name in Live.
  final String name;

  /// What the track holds.
  final DawTrackKind kind;

  /// Whether the track's activator is on. A reference track (a dry stem, a
  /// raw input, the master as heard) is off, so the set does not play the
  /// same audio twice; switching it on in Live plays it.
  final bool active;

  /// The track's clips in the Arrangement, in timeline order. A long
  /// recording held in several files has one clip per file.
  final List<DawClip> arrangementClips;

  /// One Session clip per lane that exported a loop.
  final List<DawSessionClip> sessionClips;

  /// The track's volume automation, or `null` when it has none.
  final AutomationLane? volume;

  /// The track's devices, in order: Segno's plugins and racks of them.
  final List<DawDevice> devices;

  /// The track's info text in Live (the Info View), for example the effect
  /// chains the take was played through. Empty for none.
  final String info;
}

/// A WAV file a clip plays, as the set references it.
@immutable
class DawAudioFile {
  /// Creates a [DawAudioFile].
  const new({
    required this.fileRef,
    required this.sampleRate,
    required this.frames,
  });

  /// The file's path relative to the `.als` file's own directory. Never
  /// absolute, so moving the capture folder keeps every reference working.
  final String fileRef;

  /// The file's sample rate in Hz.
  final int sampleRate;

  /// The file's length in sample frames.
  final int frames;

  /// The file's length in seconds.
  double get seconds => frames / sampleRate;
}

/// A track's volume envelope.
@immutable
class AutomationLane {
  /// Creates an [AutomationLane].
  const new({required this.initialValue, required this.breakpoints});

  /// The volume when the capture starts, before the first breakpoint, as a
  /// linear gain.
  final double initialValue;

  /// Ordered by [AutomationBreakpoint.beat], ascending. Never empty. Two
  /// breakpoints at one beat make a step.
  final List<AutomationBreakpoint> breakpoints;
}

/// One point on an [AutomationLane]'s envelope.
@immutable
class AutomationBreakpoint {
  /// Creates an [AutomationBreakpoint].
  const new({required this.beat, required this.value});

  /// Position on the Arrangement timeline, in beats.
  final double beat;

  /// The volume at [beat], as a linear gain.
  final double value;
}

/// An Arrangement clip: [audio] placed at [startSeconds], playing its whole
/// length unwarped, so it sounds exactly as captured at any set tempo.
@immutable
class DawClip {
  /// Creates a [DawClip].
  const new({required this.audio, required this.startSeconds});

  /// The file the clip plays.
  final DawAudioFile audio;

  /// The clip's start on the Arrangement timeline, in seconds.
  final double startSeconds;
}

/// A Session clip: one lane's loop, in the clip slot of scene [laneIndex].
@immutable
class DawSessionClip {
  /// Creates a [DawSessionClip].
  const new({required this.laneIndex, required this.audio});

  /// The lane the loop belongs to (0-based), which is also the scene its
  /// clip sits in.
  final int laneIndex;

  /// The loop's file. The clip loops over the whole file.
  final DawAudioFile audio;
}
