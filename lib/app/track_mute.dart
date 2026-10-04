import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:settings_repository/settings_repository.dart';

/// Admits ordinary track/lane mute and saves actual accepted lane intent.
///
/// The result reports native admission only. Later storage failures are
/// observed
/// through [onError] and retained by [persistence] for flush/retry.
EngineResult applyTrackMute({
  required LooperRepository looper,
  required SettingsRepository? settings,
  required FxChainPersistence persistence,
  required void Function(Object, StackTrace) onError,
  required int channel,
  required bool muted,
  int? lane,
}) {
  if (channel < 0 ||
      channel >= 8 ||
      (lane != null && (lane < 0 || lane >= kMaxLanes)) ||
      persistence.sessionTransitionActive) {
    onError(StateError('track mute was refused'), StackTrace.current);
    return EngineResult.invalid;
  }
  final result = lane == null
      ? looper.setMute(channel: channel, muted: muted)
      : looper.setLaneMute(channel: channel, lane: lane, muted: muted);
  if (settings != null) {
    // Whole-track admission can be partial. Save each actual accepted value,
    // including the unchanged prior value of a lane that refused.
    final first = lane ?? 0;
    final end = lane == null ? looper.laneCount(channel) : lane + 1;
    for (var index = first; index < end; index++) {
      unawaited(
        persistence
            .saveConfirmed(
              FxAddress(stage: FxStage.loop, index: channel, lane: index),
              settings,
            )
            .catchError(onError),
      );
    }
  }
  if (!result.isOk) {
    onError(
      StateError('track mute was refused: ${result.name}'),
      StackTrace.current,
    );
  }
  return result;
}
