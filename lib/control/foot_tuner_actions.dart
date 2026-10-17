import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:settings_repository/settings_repository.dart';

/// Stateless foot Tuner semantics over the engine's tuner and the stored
/// tuner preferences (#1229). Control owns the contacts and the transient
/// [FootTunerSelection]; this caches nothing.
class FootTunerActions {
  /// Connects the shared repository and the tuner preferences.
  const FootTunerActions({required this.repository, required this.settings});

  /// Owner of the engine's tuner.
  final LooperRepository repository;

  /// Owner of the A4 reference and the stored input.
  final TunerSettings settings;

  /// Reads the projection the screen uses, without retaining it.
  FootTunerProjection project(
    FootTunerSelection selection, {
    LooperState? looper,
  }) => projectFootTuner(looper ?? repository.state, selection, settings.live);

  /// Arms the detector on the projection's source, then silences its muted
  /// inputs: `setTunerInput` clears the mute natively, so the mute rides
  /// after it. With nothing tunable the tuner is disarmed instead.
  FootTunerRefusal? arm(FootTunerProjection projection) {
    if (!projection.hasSource) {
      disarm();
      return null;
    }
    if (!repository.setTunerInput(input: projection.source).isOk) {
      return FootTunerRefusal.armFailed;
    }
    if (projection.mutedInputs.isEmpty) return null;
    return repository.setTunerMute(projection.mutedInputs).isOk
        ? null
        : FootTunerRefusal.armFailed;
  }

  /// Disarms the detector, which clears the input mute with it.
  void disarm() => repository.setTunerInput(input: -1);

  /// Re-sends the mute for [projection] without moving the detector.
  FootTunerRefusal? applyMute(FootTunerProjection projection) {
    if (!projection.hasSource) return null;
    return repository.setTunerMute(projection.mutedInputs).isOk
        ? null
        : FootTunerRefusal.armFailed;
  }

  /// Stores [input] as the one to tune.
  Future<FootTunerRefusal?> select(int input) async =>
      await settings.setInput(input) ? null : FootTunerRefusal.saveFailed;

  /// The selection with the tuned input muted or audible flipped.
  FootTunerSelection toggleMute(FootTunerSelection selection) =>
      selection.copyWith(muted: !selection.muted);

  /// Moves the A4 reference by [delta] Hz. Refused at 420 and 460 Hz.
  Future<FootTunerRefusal?> stepReference(int delta) async {
    final live = settings.live;
    if (live.atLimit(delta)) return FootTunerRefusal.limit;
    return await settings.setReference(live.referenceHz + delta)
        ? null
        : FootTunerRefusal.saveFailed;
  }

  /// Puts the A4 reference back to 440 Hz.
  Future<FootTunerRefusal?> resetReference() async =>
      await settings.setReference(SettingsRepository.tunerReferenceDefaultHz)
      ? null
      : FootTunerRefusal.saveFailed;

  /// The next page of inputs, wrapping to the first, and the page's first
  /// input to tune, as the study does; null input when there is one page.
  ({FootTunerSelection selection, int? input}) nextPage(
    FootTunerProjection projection,
    FootTunerSelection selection,
  ) {
    if (projection.pageCount <= 1) return (selection: selection, input: null);
    final page = (projection.page + 1) % projection.pageCount;
    final first = projection.inputs[page * FootTunerProjection.pageSize];
    return (selection: selection.copyWith(page: page), input: first);
  }
}
