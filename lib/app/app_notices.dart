import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:midi_device_repository/midi_device_repository.dart'
    show MidiConnection;
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/notices/notices.dart';

/// The ids of the app's notices (#1562): one per cause, so a cause shows one
/// notice and a widget test can ask the notice centre for it.
///
/// A lost audio interface is a standing condition (the engine stops, nothing
/// is heard), so its id is raised and cleared; a lost MIDI controller leaves
/// the loops playing, so it passes by. Both returns are passing
/// confirmations.
abstract final class AppNoticeId {
  static const clickModeSettings = 'clickModeSettings';
  static const recordStartSettings = 'recordStartSettings';
  static const recordingInputRequired = 'recordingInputRequired';
  static const recordRefused = 'recordRefused';
  static const overdubRefused = 'overdubRefused';
  static const deviceLost = 'deviceLost';
  static const deviceMaterialCleared = 'deviceMaterialCleared';
  static const engineStopped = 'engineStopped';
  static const audioStarting = 'audioStarting';
  static const fxHeld = 'fxHeld';
  static const fxHeldOpen = 'fxHeld_open';
  static const fxHeldDismiss = 'fxHeld_dismiss';
  static const outputFxWaiting = 'outputFxWaiting';
  static const outputFxWaitingDismiss = 'outputFxWaiting_dismiss';
  static const deviceRestored = 'deviceRestored';
  static const deviceRestoredPartial = 'deviceRestoredPartial';
  static const midiLost = 'midiLost';
  static const midiRestored = 'midiRestored';
  static const sessionBootRecovery = 'sessionBootRecovery';
  static const monitorRestore = 'monitorRestore';
  static const powerCycle = 'powerCycle';
  static const powerCycleDismiss = 'powerCycle_dismiss';
  static const powerCyclePowerOff = 'powerCycle_powerOff';
  static const weakCharger = 'weakCharger';
  static const update = 'update';
  static const updateAction = 'update_update';
  static const updateNotNow = 'update_notNow';
  static const waveformFailed = 'waveformWindowFailed';
  static const bootModeRetired = 'bootModeRetired';
  static const fxStopChanged = 'fxStopChanged';
  static const fxTakeHeld = 'fxTakeHeld';
  static const saveToFellBack = 'saveToFellBack';
  static const bluetoothRetired = 'bluetoothRetired';
  static const recoveryRefused = 'recoveryRefused';
  static const undoClearAll = 'undoClearAll';
  static const undoClearAllAction = 'undoClearAll_undo';
  static const footMixerFailure = 'footMixerFailure';
  static const footFadeFailure = 'footFadeFailure';
  static const footReverseFailure = 'footReverseFailure';
  static const footPeelRefused = 'footPeelRefused';
  static const assignedActionRefused = 'assignedActionRefused';
  static const footTunerRefused = 'footTunerRefused';
  static const tunerSeeded = 'tunerSeeded';
  static const footFxFailure = 'footFxFailure';
  static const footLengthRefused = 'footLengthRefused';
  static const lengthHistoryRefused = 'lengthHistoryRefused';
  static const mixSettings = 'mixSettings';
  static const retry = 'retry';
  static const clickSettings = 'clickSettings';
  static const decaySettings = 'decaySettings';
  static const oneShotSettings = 'oneShotSettings';
  static const followTempoSettings = 'followTempoSettings';
  static const pitchModeSettings = 'pitchModeSettings';
  static const recordLengthSettings = 'recordLengthSettings';
  static const recordTimingSettings = 'recordTimingSettings';
  static const fadeSettings = 'fadeSettings';
  static const backingMixSettings = 'backingMixSettings';
  static const clickPanSettings = 'clickPanSettings';
  static const instrumentsSettings = 'instrumentsSettings';
  static const session = 'session';
  static const sessionOpenSetup = 'session_openSetup';
  static const performance = 'performance';
  static const looperMode = 'looperMode';
  static const loopSettings = 'loopSettings';
  static const fx = 'fx';
  static const fxPreset = 'fxPreset';
  static const brightnessSave = 'brightnessSave';
  static const idleDimSave = 'idleDimSave';
  static const consoleLedsSave = 'consoleLedsSave';
}

/// Retry on a must-act recovery: runs [recover] and ends the message [id]
/// in [notices] when it says the condition is over. [recover] reads the
/// owner's state after its attempt, so a failure raised while it ran keeps
/// the message, and a success after it clears it.
NoticeAction retryNoticeAction(
  NoticesCubit notices,
  String id,
  Future<bool> Function() recover,
) => NoticeAction(
  key: Key('${id}_${AppNoticeId.retry}'),
  label: (l10n) => l10n.powerRetry,
  onPressed: () => unawaited(
    recover().then((recovered) {
      if (recovered && !notices.isClosed) notices.clear(id);
    }),
  ),
);

/// A write that threw: nothing on the disk changed, so it is a warning
/// that goes by itself.
void showStorageFailed(BuildContext context, String id) =>
    context.read<NoticesCubit>().show(
      Notice(
        id: id,
        tone: NoticeTone.warning,
        title: (l10n) => l10n.storageActionFailed,
      ),
    );

/// Whether a MIDI device's loss or return ([connection]) is the audio
/// interface's own (#860): its own ports go and come back with it, so the
/// interface's message says it once.
///
/// The MIDI device carries the interface's name ("Scarlett 4i4 USB MIDI 1"
/// under "Scarlett 4i4 USB"), and the interface is gone ([audio]) or went
/// or came back moments ago ([audioJustChanged]). Another controller is its
/// own cause whatever the timing, and so is any device while the
/// interface's name is unknown. Only a MIDI device with no name at all is
/// judged by the timing alone.
bool midiIsInterfacesOwn(
  MidiConnection connection,
  AudioSetupState audio, {
  required bool audioJustChanged,
}) {
  // The card's name: a host may add the device's function after a comma.
  final interface = audio.connectivityDeviceName.split(',').first.trim();
  final names = [
    connection.connectivityDeviceName,
    connection.connectivityDeviceId,
  ].where((name) => name.isNotEmpty);
  if (names.isEmpty) return audioJustChanged;
  if (interface.isEmpty) return false;
  if (!names.any((name) => name.startsWith(interface))) return false;
  final gone = switch (audio.deviceConnectivity) {
    DeviceConnectivity.lost || DeviceConnectivity.waiting => true,
    _ => false,
  };
  return gone || audioJustChanged;
}
