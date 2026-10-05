import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The accepted Fade action vocabulary, shared by display and dispatch.
enum FootFadeAction {
  /// Advance recording on the normal transport cursor.
  recordPlay,

  /// Stop recorded tracks; envelopes are retained.
  stop,

  /// Return to normal Tracks; running fades continue.
  exit,

  /// Fade the slot's track out, or back in.
  toggleTrack,

  /// Select the slot's track duration without fading.
  selectTrackTime,

  /// Shorten the selected duration by one step.
  shorten,

  /// Lengthen the selected duration by one step.
  lengthen,

  /// A track inherits Default again; Default returns to four seconds.
  resetTime,

  /// Show the other four tracks.
  nextBank,

  /// Select the shared Default duration.
  selectDefault,
}

/// One physical pedal's semantics; Control alone supplies gesture timing.
class FootFadePedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootFadePedal(
    this.press, {
    this.hold,
    this.slot,
    this.immediate = false,
  });

  /// Short action, either at contact or matching release.
  final FootFadeAction press;

  /// Configured-threshold action, consuming the later short release.
  final FootFadeAction? hold;

  /// Visible track slot, resolved against the bank when the action fires.
  final int? slot;

  /// Whether the short action fires immediately on contact.
  final bool immediate;
}

/// Transient Fade selection; envelopes and durations live in their owners
/// and the visible bank is the shared rig bank.
class FootFadeSelection extends Equatable {
  /// Creates the local Fade selection.
  const FootFadeSelection({this.timeChannel});

  /// Track whose duration is selected, or null for the shared Default.
  final int? timeChannel;

  @override
  List<Object?> get props => [timeChannel];
}

/// One track's confirmed envelope and effective next-gesture duration.
class FootFadeTrack extends Equatable {
  /// Creates a read of current repository and settings facts.
  const FootFadeTrack({
    required this.channel,
    required this.available,
    required this.amount,
    required this.target,
    this.milliseconds,
    this.custom = false,
  });

  /// Absolute zero-based channel.
  final int channel;

  /// Whether the track holds recorded material.
  final bool available;

  /// Callback-published coefficient, independent of Mixer gain.
  final double amount;

  /// Destination coefficient.
  final double target;

  /// Effective full-travel duration, or null while settings need recovery.
  final int? milliseconds;

  /// Whether this track has an explicit override.
  final bool custom;

  /// Whether the envelope is still moving.
  bool get moving => amount != target;

  /// Fading or faded: what the LED reports. Never claims audibility.
  bool get attenuated => moving || amount < 1;

  @override
  List<Object?> get props => [
    channel,
    available,
    amount,
    target,
    milliseconds,
    custom,
  ];
}

/// Shared semantic read model for captions, touch and physical feedback.
class FootFadeProjection extends Equatable {
  /// Creates a complete projection.
  const FootFadeProjection({
    required this.selection,
    required this.bank,
    required this.tracks,
    this.durations,
  });

  /// Selection normalized against the current tracks.
  final FootFadeSelection selection;

  /// Shared rig bank (0 = tracks 1–4, 1 = tracks 5–8).
  final int bank;

  /// All eight tracks, so the overview spans both banks.
  final List<FootFadeTrack> tracks;

  /// Confirmed durations, or null while settings need recovery.
  final FadeDurations? durations;

  /// The shortest duration, in milliseconds.
  static const minimumMs = 500;

  /// The longest duration, in milliseconds.
  static const maximumMs = 30000;

  /// One duration step, in milliseconds.
  static const stepMs = 500;

  /// The fresh Default, in milliseconds.
  static const defaultMs = 4000;

  /// One role table drives captions, dispatch and physical LEDs.
  static const pedalRoles = <PedalButton, FootFadePedal>{
    PedalButton.recPlay: FootFadePedal(
      FootFadeAction.recordPlay,
      immediate: true,
    ),
    PedalButton.stop: FootFadePedal(FootFadeAction.stop, immediate: true),
    PedalButton.mode: FootFadePedal(FootFadeAction.exit, immediate: true),
    PedalButton.undo: FootFadePedal(
      FootFadeAction.shorten,
      hold: FootFadeAction.resetTime,
    ),
    PedalButton.clear: FootFadePedal(
      FootFadeAction.lengthen,
      hold: FootFadeAction.resetTime,
    ),
    PedalButton.bank: FootFadePedal(
      FootFadeAction.nextBank,
      hold: FootFadeAction.selectDefault,
    ),
    PedalButton.track1: FootFadePedal(
      FootFadeAction.toggleTrack,
      hold: FootFadeAction.selectTrackTime,
      slot: 0,
    ),
    PedalButton.track2: FootFadePedal(
      FootFadeAction.toggleTrack,
      hold: FootFadeAction.selectTrackTime,
      slot: 1,
    ),
    PedalButton.track3: FootFadePedal(
      FootFadeAction.toggleTrack,
      hold: FootFadeAction.selectTrackTime,
      slot: 2,
    ),
    PedalButton.track4: FootFadePedal(
      FootFadeAction.toggleTrack,
      hold: FootFadeAction.selectTrackTime,
      slot: 3,
    ),
  };

  /// The absolute track channel shown in visible [slot].
  int channelAt(int slot) => bank * 4 + slot;

  /// The track shown in visible [slot].
  FootFadeTrack trackAt(int slot) => tracks[channelAt(slot)];

  /// The selected duration, or null while settings need recovery.
  int? get selectedMs {
    final durations = this.durations;
    if (durations == null) return null;
    final channel = selection.timeChannel;
    return channel == null
        ? durations.defaultMs
        : durations.effectiveMs(channel);
  }

  /// Whether one shorter step fits.
  bool get canShorten => (selectedMs ?? minimumMs) > minimumMs;

  /// Whether one longer step fits.
  bool get canLengthen => (selectedMs ?? maximumMs) < maximumMs;

  @override
  List<Object?> get props => [selection, bank, tracks, durations];
}

/// Projects envelope and setup facts; meters never enter equality.
FootFadeProjection projectFootFade(
  LooperState looper,
  FootFadeSelection selection, {
  required int bank,
  FadeDurations? durations,
}) {
  FootFadeTrack read(int channel) {
    final track = looper.tracks
        .where((track) => track.channel == channel)
        .firstOrNull;
    return FootFadeTrack(
      channel: channel,
      available: track?.hasContent ?? false,
      amount: track?.fade.amount ?? 1,
      target: track?.fade.target ?? 1,
      milliseconds: durations?.effectiveMs(channel),
      custom: durations?.overrides.containsKey(channel) ?? false,
    );
  }

  final tracks = [for (var channel = 0; channel < 8; channel++) read(channel)];
  final timeChannel = selection.timeChannel;
  return FootFadeProjection(
    selection: FootFadeSelection(
      timeChannel: timeChannel != null && tracks[timeChannel].available
          ? timeChannel
          : null,
    ),
    bank: bank.clamp(0, 1),
    tracks: List.unmodifiable(tracks),
    durations: durations,
  );
}
