import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the running rig's transaction actors and their disposal order.
///
/// Widgets borrow these actors. Startup is explicit so presentation can attach
/// failure listeners before independent settings loads begin.
class AppRuntime {
  /// Builds one set of owners over the application's injected repositories.
  AppRuntime({
    required LooperRepository repository,
    required SettingsRepository settings,
    required this.mix,
    required ControllerRepository controllers,
    required MidiDeviceRepository midiDevices,
    required PedalRepository pedal,
    required PerformanceRepository performance,
    required SessionRepository sessions,
    required Future<String> Function() exportDirectory,
    required Future<void> Function() powerOff,
  }) {
    fxPersistence = FxChainPersistence(looper: repository);
    mixPersistence = SettingsMixPersistence(settings);
    tempo = TempoSettings(repository: repository, settings: settings);
    owners = SettingsOwners(tempo.owners);
    playback = PlaybackSettings(repository: repository, settings: settings);
    record = RecordSettings(repository: repository, settings: settings);
    timing = RecordTimingSettings(repository: repository, settings: settings);
    fade = FadeSettings(
      settings: settings,
      blocked: () => takeLocked,
      sessionBlocked: () => fxPersistence.sessionTransitionActive,
    );
    power = PowerOffCubit(
      flush: prepareShutdown,
      pedalGoodbye: pedal.goodbye,
      powerOff: powerOff,
    );
    looper = LooperBloc(
      repository: repository,
      settings: settings,
      mixSettings: mix,
      fxPersistence: fxPersistence,
      decayControl: playback,
      oneShotControl: playback,
      recordLengthControl: record,
      recordTimingControl: timing,
      takeLocked: () => takeLocked,
    );
    control = ControlCubit(
      looper: repository,
      settings: settings,
      mixSettings: mix,
      fxPersistence: fxPersistence,
      decayControl: playback,
      oneShotControl: playback,
      recordLengthControl: record,
      recordTimingControl: timing,
      clickVolumeControl: tempo.clickVolumeControl,
      clickModeControl: tempo.clickModeControl,
      recordStartControl: tempo.recordStartControl,
      fadeSettings: fade,
      pedal: pedal,
      performance: performance,
      controller: controllers,
      midiDevices: midiDevices,
      takeLocked: () => takeLocked,
    );
    session = SessionCubit(
      repository: sessions,
      looper: repository,
      performance: performance,
      settings: settings,
      mixSettings: mix,
      mixPersistence: mixPersistence,
      fxPersistence: fxPersistence,
      captureSettings: SessionSettingsCoordinator(
        looper: repository,
        mix: mix,
        fx: fxPersistence,
        owners: owners,
        tempo: tempo,
        playback: playback,
        record: record,
        timing: timing,
        fade: fade,
      ),
      exportDirectory: exportDirectory,
      currentPedalBindings: () => control.state.bindings.encode(),
      onPedalBindings: (encoded) =>
          control.applySessionBindings(PedalBindingSet.decode(encoded)),
      releaseHeldBindings: control.releaseAllMomentary,
    );
  }

  /// Shared durable mix owner supplied by bootstrap.
  final MixSettingsCoordinator mix;

  /// Settings store adapter shared by session capture and mix transactions.
  late final MixSettingsPersistence mixPersistence;

  /// Application-owned FX save queue.
  late final FxChainPersistence fxPersistence;

  /// Application transaction owners, borrowed by presentation adapters.
  late final TempoSettings tempo;
  late final PlaybackSettings playback;
  late final RecordSettings record;
  late final RecordTimingSettings timing;
  late final FadeSettings fade;

  /// The owned settings that run on the shared owner, in their fixed order.
  late final SettingsOwners owners;

  /// Single transport, controller, session and shutdown actors.
  late final LooperBloc looper;
  late final ControlCubit control;
  late final SessionCubit session;
  late final PowerOffCubit power;

  bool _closing = false;
  Future<void>? _startFuture;
  Future<void>? _closeFuture;

  /// Prevents new takes during shutdown, session transitions and disposal.
  bool get takeLocked =>
      _closing || power.state.isUiUp || fxPersistence.sessionTransitionActive;

  /// Starts independent restores together; callers can observe load failures.
  Future<void> start() {
    if (_closing) return Future<void>.value();
    return _startFuture ??= Future.wait<void>([
      tempo.load(),
      playback.load(),
      record.load(),
      timing.load(),
      fade.load(),
      control.load(),
    ]).then((_) {});
  }

  /// Retires controls, recovers on explicit retry, and confirms durable writes.
  Future<void> prepareShutdown({required bool retry}) async {
    if (retry) {
      if (fxPersistence.sessionBootRecoveryRequired) {
        await session.retryLoadedSession();
        if (fxPersistence.sessionBootRecoveryRequired) {
          throw StateError('Session boot settings still need recovery');
        }
      }
    }
    final controllers = control.flushMidiConfiguration(
      retireControls: true,
    );
    try {
      await controllers;
    } on ControlCleanupPending {
      // Retry repairs the owner before the owed release below.
      // Initial shutdown must remain blocked.
      if (!retry) rethrow;
    }
    if (retry) {
      if (!await fade.recover()) {
        throw StateError('Fade duration settings still need recovery');
      }
      final mixResult = await mix.recover();
      if (!mixResult.isOk) throw MixSettingsRecoveryException(mixResult);
      if (await owners.recover() case final failure?) {
        throw StateError('${failure.key.name} still needs recovery');
      }
      final decay = await playback.recoverDecay();
      if (!decay.isOk) {
        throw StateError('Decay settings still need recovery');
      }
      final once = await playback.recoverOneShot();
      if (!once.isOk) {
        throw StateError('Playback settings still need recovery');
      }
      final length = await record.recoverRecordLength();
      if (!length.isOk) {
        throw StateError('Record length still needs recovery');
      }
      final timingResult = await timing.recoverRecordTiming();
      if (!timingResult.isOk) {
        throw StateError('Record timing still needs recovery');
      }
      await control.flushMidiConfiguration(
        retireControls: true,
      );
    }
    await fade.flush();
    await fxPersistence.flush();
    final receipt = Completer<void>();
    looper.add(LooperPersistFlush(receipt: receipt));
    await receipt.future;
    final mixResult = await mix.flush();
    if (!mixResult.isOk) throw MixSettingsRecoveryException(mixResult);
    if (await owners.flush() case final failure?) {
      throw StateError('${failure.key.name} was not confirmed');
    }
    final decay = await playback.flushDecay();
    if (!decay.isOk) {
      throw StateError('Decay settings were not confirmed');
    }
    final once = await playback.flushOneShot();
    if (!once.isOk) {
      throw StateError('Playback settings were not confirmed');
    }
    final length = await record.flushRecordLength();
    if (!length.isOk) {
      throw StateError('Record length was not confirmed');
    }
    final timingResult = await timing.flushRecordTiming();
    if (!timingResult.isOk) {
      throw StateError('Record timing was not confirmed');
    }
  }

  /// Stops ingress immediately, then disposes owners in dependency order.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    control.retireInput();
    // Cancel delayed halt immediately; Session still needs the live controls.
    final powerClosed = power.close();
    final sessionClosed = session.close();
    return _closeFuture = _close(powerClosed, sessionClosed);
  }

  Future<void> _close(
    Future<void> powerClosed,
    Future<void> sessionClosed,
  ) async {
    Object? firstError;
    StackTrace? firstStack;
    // Always dispose the remaining owners even if one reports a failure.
    for (final dispose in [
      () => powerClosed,
      () => sessionClosed,
      control.close,
      looper.close,
      // UI teardown starts debounced saves; confirm them while their owners
      // and the repository still live. A failure must not skip disposal.
      fxPersistence.flush,
      fade.close,
      timing.close,
      record.close,
      playback.close,
      tempo.close,
      mix.close,
      fxPersistence.close,
    ]) {
      try {
        await dispose();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}
