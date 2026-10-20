import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The two independently paged sources of the performance Mixer.
enum FootMixerDomain {
  /// Recorded track playback.
  tracks,

  /// Hardware input live monitoring.
  inputs,
}

/// The complete accepted Mixer action vocabulary, shared by display/dispatch.
enum FootMixerAction {
  /// Advance recording on the normal transport cursor.
  recordPlay,

  /// Stop recorded tracks.
  stop,

  /// Return to normal Tracks.
  exit,

  /// Select the current page's physical channel slot.
  selectChannel,

  /// Toggle the current page's physical channel mute.
  toggleMute,

  /// Reduce selected physical gain by five percentage points.
  decrease,

  /// Increase selected physical gain by five percentage points.
  increase,

  /// Restore selected gain to unity.
  reset,

  /// Advance the local four-channel page.
  nextPage,

  /// Switch Tracks/Inputs.
  switchDomain,
}

/// One physical pedal's semantics; Control alone supplies gesture timing.
class FootMixerPedal {
  /// Creates one static role in the accepted ten-pedal layout.
  const FootMixerPedal(
    this.press, {
    this.hold,
    this.slot,
    this.immediate = false,
  });

  /// Short action, either at contact or matching release.
  final FootMixerAction press;

  /// Configured-threshold action, consuming the later short release.
  final FootMixerAction? hold;

  /// Visible channel slot, resolved when the action fires.
  final int? slot;

  /// Whether the short action fires immediately on contact.
  final bool immediate;
}

/// Transient selection only; gain and mute remain owned by the repositories.
class FootMixerSelection extends Equatable {
  /// Creates the local Mixer selection.
  const FootMixerSelection({
    this.domain = FootMixerDomain.tracks,
    this.page = 0,
    this.channel,
  });

  /// Current source domain.
  final FootMixerDomain domain;

  /// Local four-channel page, independent of the normal track bank.
  final int page;

  /// Selected hardware/track channel, or null on an empty page.
  final int? channel;

  @override
  List<Object?> get props => [domain, page, channel];
}

/// One visible physical channel slot, including disabled empty tracks.
class FootMixerChannel extends Equatable {
  /// Creates a channel reading from current repository facts.
  const FootMixerChannel({
    required this.channel,
    required this.available,
    required this.gain,
    required this.muted,
    this.monitorMode,
    this.live = false,
  });

  /// Absolute zero-based channel.
  final int channel;

  /// Whether selecting/editing this slot is allowed.
  final bool available;

  /// Confirmed physical gain (Tracks 0–2, Inputs 0–1).
  final double gain;

  /// Accepted mute intent; independent of gain and monitor mode.
  final bool muted;

  /// Live-monitor intent for Inputs; null for Tracks.
  final MonitorMode? monitorMode;

  /// Whether Auto/On currently opens the live-monitor gate, before mute.
  final bool live;

  @override
  List<Object?> get props => [
    channel,
    available,
    gain,
    muted,
    monitorMode,
    live,
  ];
}

/// Shared semantic read model for captions, touch and physical pedal feedback.
class FootMixerProjection extends Equatable {
  /// Creates a complete projection.
  const FootMixerProjection({
    required this.selection,
    required this.channels,
    required this.channelCount,
  });

  /// Selection normalized against the current source inventory.
  final FootMixerSelection selection;

  /// Exactly four slots; channels beyond inventory are disabled.
  final List<FootMixerChannel> channels;

  /// Actual source inventory size, not the configured-monitor map size.
  final int channelCount;

  /// One role table drives captions, dispatch and physical selection LEDs.
  static const pedalRoles = <PedalButton, FootMixerPedal>{
    PedalButton.recPlay: FootMixerPedal(
      FootMixerAction.recordPlay,
      immediate: true,
    ),
    PedalButton.stop: FootMixerPedal(
      FootMixerAction.stop,
      immediate: true,
    ),
    PedalButton.mode: FootMixerPedal(
      FootMixerAction.exit,
      immediate: true,
    ),
    PedalButton.undo: FootMixerPedal(
      FootMixerAction.decrease,
      hold: FootMixerAction.reset,
    ),
    PedalButton.clear: FootMixerPedal(
      FootMixerAction.increase,
      hold: FootMixerAction.reset,
    ),
    PedalButton.bank: FootMixerPedal(
      FootMixerAction.nextPage,
      hold: FootMixerAction.switchDomain,
    ),
    PedalButton.track1: FootMixerPedal(
      FootMixerAction.selectChannel,
      hold: FootMixerAction.toggleMute,
      slot: 0,
    ),
    PedalButton.track2: FootMixerPedal(
      FootMixerAction.selectChannel,
      hold: FootMixerAction.toggleMute,
      slot: 1,
    ),
    PedalButton.track3: FootMixerPedal(
      FootMixerAction.selectChannel,
      hold: FootMixerAction.toggleMute,
      slot: 2,
    ),
    PedalButton.track4: FootMixerPedal(
      FootMixerAction.selectChannel,
      hold: FootMixerAction.toggleMute,
      slot: 3,
    ),
  };

  /// Number of local pages (an empty source retains one disabled page).
  int get pageCount => ((channelCount + 3) ~/ 4).clamp(1, 8);

  /// The selected available channel, when any exists on this page.
  FootMixerChannel? get selected => channels
      .where((slot) => slot.available && slot.channel == selection.channel)
      .firstOrNull;

  /// Domain gain ceiling in physical units.
  double get maximumGain => selection.domain == FootMixerDomain.tracks ? 2 : 1;

  /// Whether one complete upward 5% step fits; off-grid values stay off-grid.
  bool get canIncrease =>
      selected != null && selected!.gain + .05 <= maximumGain + 1e-9;

  /// Whether one complete downward 5% step fits.
  bool get canDecrease => selected != null && selected!.gain - .05 >= -1e-9;

  @override
  List<Object?> get props => [selection, channels, channelCount];
}

/// Projects only control facts; meter/transport position never enters equality.
FootMixerProjection projectFootMixer(
  LooperState looper,
  FootMixerSelection selection, {
  required Map<int, InputMonitor> monitors,
}) {
  final inputs = selection.domain == FootMixerDomain.inputs;
  final count = inputs ? looper.status.inputChannels.clamp(0, 32) : 8;
  final pages = ((count + 3) ~/ 4).clamp(1, 8);
  final page = selection.page.clamp(0, pages - 1);
  final slots = <FootMixerChannel>[];
  for (var index = 0; index < 4; index++) {
    final channel = page * 4 + index;
    if (inputs) {
      final monitor = monitors[channel] ?? InputMonitor(input: channel);
      final live = switch (monitor.mode) {
        MonitorMode.off => false,
        MonitorMode.on => true,
        MonitorMode.auto => looper.tracks.any(
          (track) =>
              (track.pending || track.isCapturing) &&
              track.lanes.any((lane) => lane.inputChannel == channel),
        ),
      };
      slots.add(
        FootMixerChannel(
          channel: channel,
          available:
              channel < count &&
              (looper.status.excludedInputMask & (1 << channel)) == 0,
          gain: monitor.volume,
          muted: monitor.muted,
          monitorMode: monitor.mode,
          live: live,
        ),
      );
    } else {
      final track = looper.tracks
          .where((track) => track.channel == channel)
          .firstOrNull;
      slots.add(
        FootMixerChannel(
          channel: channel,
          available: track?.hasContent ?? false,
          gain: track?.volume ?? 1,
          muted: track?.muted ?? false,
        ),
      );
    }
  }
  final selected =
      slots
          .where((slot) => slot.available && slot.channel == selection.channel)
          .firstOrNull ??
      slots.where((slot) => slot.available).firstOrNull;
  return FootMixerProjection(
    selection: FootMixerSelection(
      domain: selection.domain,
      page: page,
      channel: selected?.channel,
    ),
    channels: List.unmodifiable(slots),
    channelCount: count,
  );
}
