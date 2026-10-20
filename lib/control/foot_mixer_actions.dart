import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/monitor_mute.dart';
import 'package:segno/app/track_mute.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:settings_repository/settings_repository.dart';

/// Stateless Mixer semantics over the existing gain and mute owners.
/// Control owns contacts and selection; this component owns no cached values.
class FootMixerActions {
  /// Connects the already shared owners without introducing a new lifetime.
  const FootMixerActions({
    required this.repository,
    required this.settings,
    required this.mix,
    required this.persistence,
  });

  /// Current audio facts and admitted mute intent.
  final LooperRepository repository;

  /// Existing scalar persistence.
  final SettingsRepository settings;

  /// Sole gain transaction owner.
  final MixSettingsCoordinator mix;

  /// Existing FX/monitor/lane persistence boundary.
  final FxChainPersistence persistence;

  /// Reads the same projection used by the screen, without retaining it.
  FootMixerProjection project(
    FootMixerSelection selection, {
    LooperState? looper,
  }) => projectFootMixer(
    looper ?? repository.state,
    selection,
    monitors: repository.allMonitors(),
  );

  /// Enters Tracks on the current recorded channel, otherwise its first audio.
  FootMixerSelection enter(int cursor) {
    final tracks = repository.state.tracks.where((track) => track.hasContent);
    final channel =
        tracks.where((track) => track.channel == cursor).firstOrNull?.channel ??
        tracks.firstOrNull?.channel;
    return project(
      FootMixerSelection(
        page: (channel ?? 0) ~/ 4,
        channel: channel,
      ),
    ).selection;
  }

  /// A source change selects its first available channel across all pages.
  FootMixerSelection domain(FootMixerDomain domain) {
    final first = project(FootMixerSelection(domain: domain));
    for (var page = 0; page < first.pageCount; page++) {
      final candidate = project(FootMixerSelection(domain: domain, page: page));
      if (candidate.selected != null) return candidate.selection;
    }
    return first.selection;
  }

  /// Resolves a visible slot at dispatch time, including after a page change.
  FootMixerSelection select(FootMixerSelection selection, int slot) {
    final current = project(selection);
    if (slot < 0 || slot >= 4 || !current.channels[slot].available) {
      return current.selection;
    }
    return FootMixerSelection(
      domain: current.selection.domain,
      page: current.selection.page,
      channel: current.channels[slot].channel,
    );
  }

  /// An empty page stays empty; advancing never changes normal track browsing.
  FootMixerSelection nextPage(FootMixerSelection selection) {
    final current = project(selection);
    return project(
      FootMixerSelection(
        domain: current.selection.domain,
        page: (current.selection.page + 1) % current.pageCount,
      ),
    ).selection;
  }

  /// Adds one physical step at the shared mix owner.
  Future<MixSettingsOutcome> step(FootMixerSelection selection, int direction) {
    final selected = project(selection).selected;
    if (selected == null || persistence.sessionTransitionActive) {
      return Future.value(const MixSettingsOutcome(MixSettingsStatus.rejected));
    }
    return selection.domain == FootMixerDomain.tracks
        ? mix.stepTrackGain(channel: selected.channel, direction: direction)
        : mix.stepMonitorGain(input: selected.channel, direction: direction);
  }

  /// Resets gain alone to unity, including while the channel is muted.
  Future<MixSettingsOutcome> reset(FootMixerSelection selection) {
    final selected = project(selection).selected;
    if (selected == null || persistence.sessionTransitionActive) {
      return Future.value(const MixSettingsOutcome(MixSettingsStatus.rejected));
    }
    return selection.domain == FootMixerDomain.tracks
        ? mix.setTrackVolume(1, channel: selected.channel)
        : mix.setMonitorVolume(input: selected.channel, volume: 1);
  }

  /// Toggles current admitted mute intent, preserving every gain and route.
  Future<void> toggleMute(
    FootMixerSelection selection, {
    required void Function(Object, StackTrace) onError,
    int? slot,
  }) async {
    final projection = project(selection);
    final selected = slot == null
        ? projection.selected
        : slot >= 0 && slot < 4
        ? projection.channels[slot]
        : null;
    if (selected == null || !selected.available) return;
    try {
      if (persistence.sessionTransitionActive) {
        throw StateError('Mixer mute refused during Session replacement');
      }
      if (selection.domain == FootMixerDomain.tracks) {
        applyTrackMute(
          looper: repository,
          settings: settings,
          persistence: persistence,
          channel: selected.channel,
          muted: !repository.trackMuted(selected.channel),
          onError: onError,
        );
      } else {
        await applyMonitorMute(
          repository: repository,
          settings: settings,
          persistence: persistence,
          mixSettings: mix,
          input: selected.channel,
          muted: !repository.monitorMuted(selected.channel),
        );
      }
    } on Object catch (error, stack) {
      onError(error, stack);
    }
  }
}
