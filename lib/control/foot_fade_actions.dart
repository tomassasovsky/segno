import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:settings_repository/settings_repository.dart';

/// Stateless Fade semantics over the envelope and duration owners.
/// Control owns contacts and selection; this component caches nothing.
class FootFadeActions {
  /// Connects the already shared owners without introducing a new lifetime.
  const FootFadeActions({required this.repository, required this.settings});

  /// Callback-owned envelopes.
  final LooperRepository repository;

  /// Sole owner of next-gesture durations.
  final FadeSettings settings;

  /// Confirmed durations, or null while settings need recovery.
  FadeDurations? get durations =>
      settings.needsRecovery ? null : settings.confirmed;

  /// Reads the same projection used by the screen, without retaining it.
  FootFadeProjection project(
    FootFadeSelection selection, {
    required int bank,
    LooperState? looper,
  }) => projectFootFade(
    looper ?? repository.state,
    selection,
    bank: bank,
    durations: durations,
  );

  /// Selects one recorded track's duration, resolved at dispatch time
  /// against the current bank.
  FootFadeSelection selectTrackTime(
    FootFadeSelection selection,
    int slot, {
    required int bank,
  }) {
    final current = project(selection, bank: bank);
    if (slot < 0 || slot >= 4 || !current.trackAt(slot).available) {
      return current.selection;
    }
    return FootFadeSelection(timeChannel: current.channelAt(slot));
  }

  /// Fades one recorded track toward the opposite end at its effective
  /// duration. Refuses an empty track or unconfirmed settings. Shared by the
  /// Fade surface and assigned Fade actions.
  Future<EngineResult> toggle(int channel) {
    final durations = this.durations;
    final track = repository.state.tracks
        .where((track) => track.channel == channel)
        .firstOrNull;
    if (durations == null || track == null || !track.hasContent) {
      return Future.value(EngineResult.invalid);
    }
    return repository.toggleFade(
      channel: channel,
      seconds: durations.effectiveMs(channel) / 1000,
    );
  }

  /// One step shorter or longer; an edge step is a no-op. Editing an
  /// inherited track time creates its override. Control keeps the selection
  /// normalized, so only the durations are read here.
  Future<void> step(FootFadeSelection selection, int direction) async {
    final durations = this.durations;
    if (durations == null) return;
    final channel = selection.timeChannel;
    final milliseconds = channel == null
        ? durations.defaultMs
        : durations.effectiveMs(channel);
    final next = (milliseconds + direction * FootFadeProjection.stepMs).clamp(
      FootFadeProjection.minimumMs,
      FootFadeProjection.maximumMs,
    );
    if (next == milliseconds) return;
    if (channel == null) {
      await settings.setDefault(next);
    } else {
      await settings.setOverride(channel, next);
    }
  }

  /// A track inherits Default again; Default returns to four seconds.
  Future<void> reset(FootFadeSelection selection) async {
    if (durations == null) return;
    final channel = selection.timeChannel;
    if (channel == null) {
      await settings.setDefault(FootFadeProjection.defaultMs);
    } else {
      await settings.setOverride(channel, null);
    }
  }
}
