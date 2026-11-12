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

/// One Live audio track: the channel's full-length stem in the Arrangement,
/// one Session clip per lane loop, and the automation reconstructed from the
/// capture's logged gestures.
@immutable
class DawTrack {
  /// Creates a [DawTrack].
  const new({
    required this.name,
    this.arrangementClip,
    this.sessionClips = const [],
    this.automationLanes = const [],
  });

  /// The track's name in Live (for example `Track 0`).
  final String name;

  /// The channel's stem in the Arrangement, or `null` when the channel has
  /// no stem and only its lane loops exist.
  final DawClip? arrangementClip;

  /// One Session clip per lane that exported a loop.
  final List<DawSessionClip> sessionClips;

  /// At most one lane per [AutomationTarget].
  final List<AutomationLane> automationLanes;
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

/// Which Live mixer parameter an [AutomationLane] drives.
enum AutomationTarget {
  /// The track's volume, a linear gain: one breakpoint per logged change,
  /// with Live ramping between them.
  volume,

  /// The track's activator (Live's track on/off switch), which is how a
  /// mute or a solo elsewhere shows: 1 is audible, 0 is silent. Each
  /// breakpoint holds until the next one.
  activator,
}

/// One automation envelope for a track's [AutomationTarget].
@immutable
class AutomationLane {
  /// Creates an [AutomationLane].
  const new({
    required this.target,
    required this.initialValue,
    required this.breakpoints,
  });

  /// Which mixer parameter this envelope drives.
  final AutomationTarget target;

  /// The parameter's value when the capture starts, before the first
  /// breakpoint.
  final double initialValue;

  /// Ordered by [AutomationBreakpoint.beat], ascending. Never empty.
  final List<AutomationBreakpoint> breakpoints;
}

/// One point on an [AutomationLane]'s envelope.
@immutable
class AutomationBreakpoint {
  /// Creates an [AutomationBreakpoint].
  const new({required this.beat, required this.value});

  /// Position on the Arrangement timeline, in beats.
  final double beat;

  /// The parameter's value at [beat]: a linear gain for
  /// [AutomationTarget.volume], `0` or `1` for [AutomationTarget.activator].
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
