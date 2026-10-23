import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:settings_repository/settings_repository.dart';

/// Admits monitor mute before publishing it, then confirms its existing save.
/// The caller observes errors and may publish accepted intent immediately.
Future<void> applyMonitorMute({
  required LooperRepository repository,
  required SettingsRepository settings,
  required FxChainPersistence persistence,
  required MixSettingsCoordinator mixSettings,
  required int input,
  required bool muted,
  void Function()? onAccepted,
}) async {
  if (!mixSettings.acceptingEdits || persistence.sessionTransitionActive) {
    throw StateError('monitor mute refused during restore or recovery');
  }
  final result = repository.setMonitorMute(input: input, muted: muted);
  if (!result.isOk) {
    throw StateError('monitor mute was refused: ${result.name}');
  }
  onAccepted?.call();
  await persistence.saveMonitorMuteConfirmed(input, settings);
}
