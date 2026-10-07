import 'dart:async';

import 'package:brightness_client/brightness_client.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/app/view/control_settings_notices.dart';
import 'package:segno/app/view/encoder_navigation.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/appliance/idle_dim_host.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/update/appliance/appliance_env.dart';
import 'package:segno/update/appliance/system_appliance_env.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/application/waveform_display_controller.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:segno/window/window_chrome.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:toastification/toastification.dart';
import 'package:update_repository/update_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The root application widget.
class App extends StatefulWidget {
  /// Creates an [App] driven by the injected repositories.
  ///
  /// The repositories and [waveformWindow] are injected so tests can supply
  /// fakes / a no-op window service instead of the native device and a real
  /// second OS window. [initialAsioDrivers] is the ASIO driver list enumerated
  /// at startup, cached by the audio-setup cubit for the picker.
  const App({
    required this.repository,
    required this.controllerRepository,
    required this.midiDeviceRepository,
    required this.settings,
    required this.mixSettings,
    required this.waveformWindow,
    required this.sessionRepository,
    required this.performanceRepository,
    required this.guards,
    this.pedalRepository,
    this.displayCount,
    this.waveformWindowOpenDelay = Duration.zero,
    this.audioRecoveryConfig,
    this.initialAsioDrivers = const [],
    this.updates = const UpdateRepository(
      backend: UnsupportedPlatformBackend(),
    ),
    this.wifi = const WifiRepository(client: UnsupportedWifiClient()),
    this.brightness = const UnsupportedBrightnessClient(),
    this.displayOutputs = const UnknownDisplayOutputs(),
    this.consoleFacts = const UnsupportedConsoleFactsClient(),
    this.removableVolumes = const InternalOnlyVolumes(),
    this.powerKeySource,
    this.powerOff,
    this.reboot,
    this.storage,
    super.key,
  });

  /// The software-update repository. Defaults to an inert
  /// (unsupported-platform) instance so the update UI stays hidden; the app
  /// entrypoint injects the platform-appropriate one.
  final UpdateRepository updates;

  /// Appliance WiFi repository (Control Center). Defaults unsupported.
  final WifiRepository wifi;

  /// Appliance brightness client (per-panel DDC/CI). Defaults unsupported.
  final BrightnessClient brightness;

  /// Which connector each window is shown on and whether a panel is plugged
  /// in. Defaults unknown (a desktop).
  final DisplayOutputs displayOutputs;

  /// Reads what the appliance knows about itself — the disk, the box, and
  /// where it can export to. Defaults to the client that answers "unknown",
  /// which is what every non-appliance build gets.
  final ConsoleFactsClient consoleFacts;

  /// The removable drives the Library browses and copies to. Defaults to
  /// [InternalOnlyVolumes] (no drive, every removable write refused) until
  /// the storage service (#1177) stands behind the port.
  final RemovableVolumes removableVolumes;

  /// Injected power-button source. Null (the default) starts an evdev
  /// listener on Linux when `segno-update-ctl` exists, and nothing elsewhere.
  final PowerKeySource? powerKeySource;

  /// Injected halt. Null (the default) runs `segno-update-ctl poweroff`.
  final Future<void> Function()? powerOff;

  /// Injected reboot. Null (the default) runs `segno-update-ctl reboot`,
  /// which boots a staged update slot when one is staged.
  final Future<void> Function()? reboot;

  /// The USB storage service, when this build has one. Restart and shutdown
  /// refuse while it holds a lease and wait for leases taken after the save;
  /// null (the default) means nothing can be held.
  final StorageRepository? storage;

  /// The app's one guard table (accepted behaviour 6.12), shared with the
  /// session and performance repositories it was built with. Required: an
  /// owner checking a private table would refuse nothing.
  final GuardRegistry guards;

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// Owns controller sources and forwards exact console inputs.
  final ControllerRepository controllerRepository;

  /// The MIDI input device repository (owns the foot-controller lifecycle). It
  /// borrows the long-lived native MIDI source from [controllerRepository] and
  /// never disposes it; the [MidiSetupCubit] projects its state.
  final MidiDeviceRepository midiDeviceRepository;

  /// The pedal repository over the console board's link, or `null` when none
  /// was built — an on-screen pedal link is substituted so pedal
  /// cubit always exists and its settings picker shows an empty state. Owned by
  /// the [PedalCubit], which disposes it.
  final PedalRepository? pedalRepository;

  /// Reports the number of connected displays, for the dual-display console's
  /// single-display fallback. `null` (the default) disables the fallback
  /// (assumes the usual multi-window desktop); the Pi entrypoint wires the real
  /// platform display count.
  final int Function()? displayCount;

  /// Startup spacing before the second native view opens under Weston.
  final Duration waveformWindowOpenDelay;

  /// The pinned audio config a boot auto-start could not open, handed to the
  /// [AudioRecoveryCubit] so the engine auto-starts when that device reappears.
  /// `null` (the default) when the engine started or there is no pinned device.
  final EngineConfig? audioRecoveryConfig;

  /// The shared settings repository (persists latency calibration + config).
  final SettingsRepository settings;

  /// The shared mix transaction owner created before audio bootstrap.
  final MixSettingsCoordinator mixSettings;

  /// Manages the secondary output-waveform window.
  final WaveformWindowService waveformWindow;

  /// The ASIO drivers enumerated at startup, cached by the audio-setup cubit so
  /// the picker stays populated even while ASIO holds the device (R1).
  final List<AudioDevice> initialAsioDrivers;

  /// The shared session repository (save/load + export), sharing the engine.
  final SessionRepository sessionRepository;

  /// The shared performance-recording repository, sharing the engine.
  final PerformanceRepository performanceRepository;

  @override
  State<App> createState() => _AppState();
}

/// Resolves the optional pedal pair once so a replacement [App] keeps
/// [ControlCubit], [PedalCubit], and dialog routes on one repository.
class _AppState extends State<App> {
  StreamSubscription<PowerState>? _powerNoticeSubscription;
  late final PedalRepository _pedal;
  late final AppRuntime _runtime;
  late final RecordOptionsCubit _recordView;
  StreamSubscription<MixSettingsOutcome>? _mixFailureSubscription;
  PowerKeySource? _powerKeySource;
  final _controlNotices = ControlSettingsNotices();
  late final TempoCubit _tempoView;
  final _ownerSubscriptions = <StreamSubscription<void>>[];
  StreamSubscription<int>? _recordingInputRequiredSubscription;
  StreamSubscription<int>? _recordRefusedSubscription;
  StreamSubscription<int>? _overdubRefusedSubscription;
  StreamSubscription<int>? _lengthHistoryRefusedSubscription;
  late final PlaybackOptionsCubit _playbackView;
  late final RecordTimingCubit _timingView;

  @override
  void initState() {
    super.initState();
    _pedal = widget.pedalRepository ?? PedalRepository(NoopPedalLink());
    _runtime = AppRuntime(
      repository: widget.repository,
      settings: widget.settings,
      mix: widget.mixSettings,
      controllers: widget.controllerRepository,
      midiDevices: widget.midiDeviceRepository,
      pedal: _pedal,
      performance: widget.performanceRepository,
      sessions: widget.sessionRepository,
      powerOff: widget.powerOff ?? const SystemApplianceEnv().powerOff,
      reboot: widget.reboot ?? const SystemApplianceEnv().reboot,
      storageSettled: widget.storage?.settled ?? () async {},
      guards: widget.guards,
    );
    _powerNoticeSubscription = _runtime.power.stream.listen(
      _syncControlNoticesWithPower,
    );
    _mixFailureSubscription = _runtime.mix.failures.listen(_showMixFailure);
    _tempoView = TempoCubit(settings: _runtime.tempo);
    for (final owner in _runtime.owners.all) {
      _ownerSubscriptions.addAll([
        owner.failures.listen((outcome) => _showOwnedFailure(owner, outcome)),
        // A restart replay can resolve an owed value without Retry.
        owner.recovered.listen(
          (_) => _controlNotices.dismiss(_ownedNotice(owner.key).id),
        ),
      ]);
    }
    _recordingInputRequiredSubscription = widget
        .repository
        .recordingInputRequired
        .listen(_showRecordingInputRequired);
    _recordRefusedSubscription = widget.repository.recordRefusals.listen(
      (channel) =>
          _showRecordRefused(channel, (l10n) => l10n.recordRefusedTitle),
    );
    _overdubRefusedSubscription = widget.repository.overdubRefusals.listen(
      (channel) =>
          _showRecordRefused(channel, (l10n) => l10n.footReverseOverdubRefused),
    );
    // An Undo or Redo of a length edit that did nothing (#1168): refused at
    // the tap or after it was posted, or queued taps that stopped at the
    // edit. From any surface, so a tap that did nothing is never silent.
    _lengthHistoryRefusedSubscription = widget.repository.lengthHistoryRefusals
        .listen(
          (channel) => _showRecordRefused(
            channel,
            (l10n) => l10n.lengthHistoryRefused,
            id: AppToastId.lengthHistoryRefused,
          ),
        );
    _playbackView = PlaybackOptionsCubit(settings: _runtime.playback);
    _recordView = RecordOptionsCubit(settings: _runtime.record);
    _timingView = RecordTimingCubit(settings: _runtime.timing);
    unawaited(
      _runtime.start().catchError((Object error, StackTrace stack) {
        AppLog.error('settings startup failed', error: error, stack: stack);
      }),
    );
    _powerKeySource =
        widget.powerKeySource ??
        openAppliancePowerKeySource(onAppliance: isAppliance());
  }

  @override
  void dispose() {
    unawaited(_powerNoticeSubscription?.cancel());
    unawaited(_powerKeySource?.close());
    unawaited(_mixFailureSubscription?.cancel());
    for (final subscription in _ownerSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_recordingInputRequiredSubscription?.cancel());
    unawaited(_recordRefusedSubscription?.cancel());
    unawaited(_overdubRefusedSubscription?.cancel());
    unawaited(_lengthHistoryRefusedSubscription?.cancel());
    _controlNotices.dispose();
    unawaited(
      _closeControlOwners().catchError((Object error, StackTrace stack) {
        AppLog.error('application teardown failed', error: error, stack: stack);
      }),
    );
    super.dispose();
  }

  Future<void> _closeControlOwners() async {
    // Runtime close stops control ingress synchronously, before adapters close.
    final closed = _runtime.close();
    await Future.wait([
      _timingView.close(),
      _recordView.close(),
      _playbackView.close(),
      _tempoView.close(),
      closed,
    ]);
  }

  void _showOwnedFailure(
    SettingsOwner<Object, Object?> owner,
    SettingOutcome outcome,
  ) {
    if (!mounted || outcome.status == SettingStatus.superseded) return;
    final recovery = outcome.status == SettingStatus.recoveryRequired;
    final notice = _ownedNotice(owner.key);
    AppLog.error(
      '${owner.key.name}: ${outcome.status.name} ${outcome.error ?? ''}',
    );
    _controlNotices.show(
      ControlSettingsNotice(
        id: notice.id,
        title: (context) =>
            Text(recovery ? notice.recovery(context) : notice.refused(context)),
        description: recovery ? (context) => Text(notice.body(context)) : null,
        retry: recovery ? () async => (await owner.recover()).isOk : null,
        needsRecovery: recovery ? () => !owner.ready : null,
      ),
    );
  }

  static ({
    String id,
    String Function(BuildContext) recovery,
    String Function(BuildContext) refused,
    String Function(BuildContext) body,
  })
  _ownedNotice(OwnedSetting key) => switch (key) {
    OwnedSetting.clickVolume => (
      id: AppToastId.clickSettings,
      recovery: (context) => context.l10n.clickSettingsRecoveryTitle,
      refused: (context) => context.l10n.clickSettingsRefusedTitle,
      body: (context) => context.l10n.clickSettingsRecoveryBody,
    ),
    OwnedSetting.hearClick => (
      id: AppToastId.clickModeSettings,
      recovery: (context) => context.l10n.clickModeSettingsRecoveryTitle,
      refused: (context) => context.l10n.clickModeSettingsRefusedTitle,
      body: (context) => context.l10n.clickModeSettingsRecoveryBody,
    ),
    OwnedSetting.recordStart => (
      id: AppToastId.recordStartSettings,
      recovery: (context) => context.l10n.recordStartSettingsRecoveryTitle,
      refused: (context) => context.l10n.recordStartSettingsRefusedTitle,
      body: (context) => context.l10n.recordStartSettingsRecoveryBody,
    ),
    OwnedSetting.decay => (
      id: AppToastId.decaySettings,
      recovery: (context) => context.l10n.decaySettingsRecoveryTitle,
      refused: (context) => context.l10n.decaySettingsRefusedTitle,
      body: (context) => context.l10n.decaySettingsRecoveryBody,
    ),
    OwnedSetting.oneShot => (
      id: AppToastId.oneShotSettings,
      recovery: (context) => context.l10n.oneShotSettingsRecoveryTitle,
      refused: (context) => context.l10n.oneShotSettingsRefusedTitle,
      body: (context) => context.l10n.oneShotSettingsRecoveryBody,
    ),
    OwnedSetting.recordLength => (
      id: AppToastId.recordLengthSettings,
      recovery: (context) => context.l10n.recordLengthSettingsRecoveryTitle,
      refused: (context) => context.l10n.recordLengthSettingsRefusedTitle,
      body: (context) => context.l10n.recordLengthSettingsRecoveryBody,
    ),
    OwnedSetting.recordTiming => (
      id: AppToastId.recordTimingSettings,
      recovery: (context) => context.l10n.recordTimingSettingsRecoveryTitle,
      refused: (context) => context.l10n.recordTimingSettingsRefusedTitle,
      body: (context) => context.l10n.recordTimingSettingsRecoveryBody,
    ),
    OwnedSetting.fade => (
      id: AppToastId.fadeSettings,
      recovery: (context) => context.l10n.fadeSettingsRecoveryTitle,
      refused: (context) => context.l10n.fadeSettingsRefusedTitle,
      body: (context) => context.l10n.fadeSettingsRecoveryBody,
    ),
  };

  void _showRecordingInputRequired(int channel) {
    if (!mounted || _runtime.power.state.isUiUp) return;
    showAppToast(
      id: AppToastId.recordingInputRequired,
      type: ToastificationType.warning,
      autoCloseDuration: const Duration(seconds: 5),
      title: Builder(
        builder: (context) => Text(context.l10n.recordingInputRequiredTitle),
      ),
      description: Builder(
        builder: (context) => Text(
          context.l10n.trackName(
            context.read<TracksCubit>().state.names,
            channel,
          ),
        ),
      ),
    );
  }

  /// A Record press the engine refused: a fresh capture refused twice
  /// (#1146), or an overdub on a reversed track. The press is lost, so say
  /// why. Low stakes — a toast, like the input notice above.
  void _showRecordRefused(
    int channel,
    String Function(AppLocalizations l10n) title, {
    String id = AppToastId.recordRefused,
  }) {
    if (!mounted || _runtime.power.state.isUiUp) return;
    showAppToast(
      id: id,
      type: ToastificationType.warning,
      autoCloseDuration: const Duration(seconds: 5),
      title: Builder(
        builder: (context) => Text(title(context.l10n)),
      ),
      description: Builder(
        builder: (context) => Text(
          context.l10n.trackName(
            context.read<TracksCubit>().state.names,
            channel,
          ),
        ),
      ),
    );
  }

  void _showMixFailure(MixSettingsOutcome outcome) {
    if (!mounted || outcome.status == MixSettingsStatus.superseded) return;
    final recovery = outcome.status == MixSettingsStatus.recoveryRequired;
    AppLog.error('Mix settings: ${outcome.status.name} ${outcome.error ?? ''}');
    _controlNotices.show(
      ControlSettingsNotice(
        id: AppToastId.mixSettings,
        title: (_) => Text(
          recovery
              ? 'Mix settings need recovery'
              : outcome.status == MixSettingsStatus.storageFailed
              ? 'Mix change could not be saved'
              : 'Mix change was not applied',
        ),
        description: recovery
            ? (_) => Text(
                _runtime.mix.stoppedForRecovery
                    ? 'Audio was stopped to protect your settings.'
                    : 'Retry to confirm the mix.',
              )
            : null,
        retry: recovery
            ? () async => (await _runtime.mix.recover()).isOk
            : null,
        needsRecovery: recovery ? () => _runtime.mix.recoveryRequired : null,
      ),
    );
  }

  void _syncControlNoticesWithPower(PowerState state) {
    if (!mounted) return;
    _controlNotices.setPowerVisible(visible: state.isUiUp);
    if (state.isUiUp) dismissAppToast(AppToastId.recordingInputRequired);
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: widget.repository),
        RepositoryProvider.value(value: _runtime.timing),
        RepositoryProvider.value(value: _runtime.fade),
        RepositoryProvider.value(value: _runtime.tuner),
        RepositoryProvider.value(value: _runtime.record),
        RepositoryProvider.value(value: widget.controllerRepository),
        RepositoryProvider.value(value: widget.midiDeviceRepository),
        RepositoryProvider.value(value: widget.settings),
        RepositoryProvider.value(value: _runtime.mix),
        RepositoryProvider.value(value: _runtime.fxPersistence),
        RepositoryProvider.value(value: _runtime.tempo),
        RepositoryProvider.value(value: _runtime.playback),
        RepositoryProvider<MixSettingsPersistence>.value(
          value: _runtime.mixPersistence,
        ),
        RepositoryProvider.value(value: widget.sessionRepository),
        RepositoryProvider.value(value: widget.performanceRepository),
        RepositoryProvider.value(value: _pedal),
        RepositoryProvider.value(value: widget.updates),
        RepositoryProvider.value(value: widget.wifi),
        RepositoryProvider.value(value: widget.brightness),
        RepositoryProvider.value(value: widget.displayOutputs),
        RepositoryProvider.value(value: widget.consoleFacts),
        RepositoryProvider<RemovableVolumes>.value(
          value: widget.removableVolumes,
        ),
        if (_powerKeySource != null)
          RepositoryProvider<PowerKeySource>.value(value: _powerKeySource!),
        if (widget.storage case final storage?)
          RepositoryProvider<StorageRepository>.value(value: storage),
      ],
      child: MultiBlocProvider(
        providers: [
          // Provided app-wide so the startup update banner and the settings
          // Updates section share one cubit. lazy:false so the passive check
          // (when auto-check is on) runs at launch to power the banner.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = UpdateCubit(
                updates: context.read<UpdateRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Each panel's brightness: DDC/CI on a panel that answers it (LG
          // TVs often do not), else a software dim over its window — the
          // main window in [MaterialApp.builder], the Track display window
          // through its readout.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = DisplayBrightnessCubit(
                settings: context.read<SettingsRepository>(),
                client: context.read<BrightnessClient>(),
                outputs: context.read<DisplayOutputs>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Dims both panels after the chosen idle period; IdleDimHost in
          // [MaterialApp.builder] feeds it and carries the dim to the panels.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = IdleDimCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Provided app-wide (not just on the looper page) so the settings
          // route — pushed on the root navigator, above the looper page — can
          // drive routing edits through the bloc, mirroring the in-view routing
          // controls. The TracksCubit below is hoisted for the same reason.
          // Remote and console controls are interpreted by ControlCubit.
          BlocProvider<LooperBloc>.value(value: _runtime.looper),
          BlocProvider<SessionCubit>.value(value: _runtime.session),
          BlocProvider(
            create: (context) {
              final cubit = TracksCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // The player's saved sounds. Three FX surfaces touch the same list —
          // the two editors save into it, the library recalls from it, and My
          // presets renames and deletes in it — so it is owned once, here,
          // rather than per page.
          BlocProvider(
            create: (context) {
              final cubit = FxPresetsCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // The stage status bar's wall-clock transport timer (#678). Eager:
          // its epoch is the transport's FIRST run, not the strip's first
          // build — created lazily it would start counting only when the
          // console face first reads it, missing a run a footswitch started
          // before then. Passive (subscribes, arms nothing), so eager costs
          // one stream listener.
          BlocProvider(
            lazy: false,
            create: (context) => TransportClockCubit(
              repository: context.read<LooperRepository>(),
            ),
          ),
          // Beside the track names and for the same reason: an input is called
          // what the player calls it on every surface that shows one — the
          // Audio face's input list, the Tracks routing summary, and the
          // per-track lane list — so the names load once, here.
          // Eager: the names key off the OPEN DEVICE, so the cubit has to be
          // listening before the engine reports one — created lazily it would
          // miss the boot device entirely and show ordinals until the next
          // reopen.
          BlocProvider(
            lazy: false,
            create: (context) => InputsCubit(
              settings: context.read<SettingsRepository>(),
              repository: context.read<LooperRepository>(),
            ),
          ),
          // Destination names, the output-side twin of the inputs above and
          // eager for the same reason: they key off the OPEN DEVICE.
          BlocProvider(
            lazy: false,
            create: (context) => OutputsCubit(
              settings: context.read<SettingsRepository>(),
              repository: context.read<LooperRepository>(),
            ),
          ),
          // The tuner is lazy on purpose, unlike its neighbours: it subscribes
          // to the looper stream and arms the engine, and a console that never
          // opens the Tuner face should pay for neither.
          BlocProvider(
            create: (context) => TunerCubit(
              repository: context.read<LooperRepository>(),
              settings: context.read<TunerSettings>(),
            ),
          ),
          BlocProvider(
            create: (context) {
              final cubit = HighContrastCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // App-wide, not the face's: the facts are about the BOX, and the
          // About tab must not be the only thing that can ask. Loads on
          // create; the Storage face re-reads on open, because a USB stick may
          // have arrived since.
          //
          // Eager, and that is what makes those two separate reads. Both faces
          // that read this cubit also call `load()` from their own `initState`,
          // so created LAZILY it would be constructed by that very read — the
          // create-load and the face's re-read firing in the same instant, two
          // concurrent disk walks answering one question instead of a boot
          // read the face later refreshes.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = ConsoleFactsCubit(
                client: context.read<ConsoleFactsClient>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = WaveformWindowCubit(
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = RefreshRateCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider<RecordTimingCubit>.value(value: _timingView),
          BlocProvider<TempoCubit>.value(value: _tempoView),
          BlocProvider<PlaybackOptionsCubit>.value(value: _playbackView),
          BlocProvider(
            // Not lazy: the monitor graph page is the only widget that reads
            // this cubit, but the saved per-input monitors must be applied to
            // the engine at startup — otherwise monitoring stays off until the
            // user opens "configure input monitoring".
            lazy: false,
            create: (context) {
              final cubit = MonitorCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
                mixSettings: context.read<MixSettingsCoordinator>(),
                fxPersistence: context.read<FxChainPersistence>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            // Not lazy, for the same reason as MonitorCubit above: the saved
            // per-input conditioning stage must be applied to the engine at
            // startup, not only when a settings surface first reads this cubit.
            lazy: false,
            create: (context) {
              final cubit = InputConditioningCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider.value(value: _recordView),
          // Provided at the shell (not just the setup screen) so the device
          // picker, the persisted selection, and the connect/disconnect banner
          // stay live during normal looping, not only during first-run setup.
          BlocProvider(
            create: (context) => AudioSetupCubit(
              repository: context.read<LooperRepository>(),
              settings: context.read<SettingsRepository>(),
              initialAsioDrivers: widget.initialAsioDrivers,
            ),
          ),
          // Eager (not lazy): the MIDI-setup cubit performs the launch
          // auto-reconnect of the saved foot controller, so it must be created
          // on startup, not only when the settings page first reads it. It
          // holds no audio dependency — switching/losing MIDI never restarts
          // the engine.
          BlocProvider(
            lazy: false,
            create: (context) => MidiSetupCubit(
              repository: context.read<MidiDeviceRepository>(),
            ),
          ),
          BlocProvider<PowerCubit>.value(value: _runtime.power),
          BlocProvider<ControlCubit>.value(value: _runtime.control),
          // Eager (not lazy): the pedal LINK feature owns the repository's
          // lifecycle and mirrors the board's status. It shares the
          // PedalRepository with ControlCubit (status here, events/frames
          // there) — the cubits know nothing of each other.
          BlocProvider(
            lazy: false,
            create: (context) => PedalCubit(
              pedal: context.read<PedalRepository>(),
            ),
          ),
          // Eager (not lazy): the recovery cubit must be watching at boot for a
          // pinned interface that was unplugged when auto-start ran, so it can
          // start audio the moment it reappears. Inert when there is nothing to
          // recover (engine already running / no pinned device).
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = AudioRecoveryCubit(
                looper: context.read<LooperRepository>(),
                recoveryConfig: widget.audioRecoveryConfig,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Eager (not lazy): the boot-time silent salvage (D-SALVAGE, #679)
          // must start the moment the app composes, not whenever a widget
          // first reads this cubit — a crashed capture recovers in the
          // background whether or not the tracks view ever mounts.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PerformanceRecorderCubit(
                performance: context.read<PerformanceRepository>(),
                takeLocked: () =>
                    context.read<PowerCubit>().state.isUiUp ||
                    _runtime.fxPersistence.sessionTransitionActive,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
        ],
        child: _AppView(
          controlNotices: _controlNotices,
          waveformWindow: widget.waveformWindow,
          displayCount: widget.displayCount,
          waveformWindowOpenDelay: widget.waveformWindowOpenDelay,
        ),
      ),
    );
  }
}

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for tracks mode.
class _AppView extends StatefulWidget {
  const _AppView({
    required this.controlNotices,
    required this.waveformWindow,
    required this.waveformWindowOpenDelay,
    this.displayCount,
  });

  final ControlSettingsNotices controlNotices;
  final WaveformWindowService waveformWindow;
  final int Function()? displayCount;
  final Duration waveformWindowOpenDelay;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  late final WaveformDisplayController _display;
  StreamSubscription<WaveformDisplayFailure>? _displayFailures;
  StreamSubscription<RecoveryRefusal>? _recoverySub;
  bool _restoreNoticeScheduled = false;

  /// Resolves localized strings from inside [MaterialApp] when this state
  /// sits above it in the tree.
  AppLocalizations get _l10n {
    final localizedContext = segnoNavigatorKey.currentContext;
    if (localizedContext != null) {
      return localizedContext.l10n;
    }
    return lookupAppLocalizations(PlatformDispatcher.instance.locale);
  }

  @override
  void initState() {
    super.initState();
    _reconcileRestoreNotices();
    _recoverySub = context.read<LooperRepository>().recoveryRefusals.listen(
      _showRecoveryRefusal,
    );
    // A touch on the Track display wakes an idle-dimmed console.
    widget.waveformWindow.onWindowActivity = () {
      if (mounted) context.read<IdleDimCubit>().activity();
    };
    _display = WaveformDisplayController(
      repository: context.read<LooperRepository>(),
      window: widget.waveformWindow,
      context: _displayContext(),
      displayCount: widget.displayCount,
      openDelay: widget.waveformWindowOpenDelay,
    );
    _displayFailures = _display.failures.listen((failure) {
      if (!mounted) return;
      switch (failure) {
        case WaveformDisplayFailure.singleDisplay:
          _showSingleDisplayNotice();
        case WaveformDisplayFailure.openFailed:
          context.read<WaveformWindowCubit>().reportOpenFailed();
          _showWaveformWindowFailedBanner();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrapWindow());
      if (mounted) unawaited(_noticeRetiredBluetooth());
    });
  }

  /// Tells an install that had paired Bluetooth devices, once, that they will
  /// not reconnect: Bluetooth is retired and the image no longer runs BlueZ.
  /// The pairings themselves stay on the data volume, so a fallback to the
  /// previous system still has them.
  Future<void> _noticeRetiredBluetooth() async {
    final settings = context.read<SettingsRepository>();
    final facts = context.read<ConsoleFactsClient>();
    if (await settings.loadBluetoothRetiredNoticeShown()) return;
    final count = await facts.retiredBluetoothPairings();
    if (count == 0 || !mounted) return;
    showAppToast(
      id: AppToastId.bluetoothRetired,
      title: AppText(_l10n.bluetoothRetiredNotice(count)),
      icon: const Icon(Icons.bluetooth_disabled),
    );
    await settings.saveBluetoothRetiredNoticeShown();
  }

  void _reconcileRestoreNotices() {
    if (_restoreNoticeScheduled) return;
    _restoreNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreNoticeScheduled = false;
      if (!mounted) return;
      final monitor = context.read<MonitorCubit>();
      if (monitor.isClosed) return;
      final session = context.read<SessionCubit>();
      final persistence = context.read<FxChainPersistence>();
      bool needsSessionRecovery() =>
          !session.isClosed && session.state.bootRecoveryRequired;
      if (!needsSessionRecovery()) {
        widget.controlNotices.dismiss(AppToastId.sessionBootRecovery);
      } else if (session.state.status == SessionStatus.failure) {
        widget.controlNotices.show(
          ControlSettingsNotice(
            id: AppToastId.sessionBootRecovery,
            title: (context) => Text(context.l10n.sessionBootRecoveryTitle),
            description: (context) =>
                Text(context.l10n.sessionBootRecoveryBody),
            needsRecovery: needsSessionRecovery,
            retry: () async {
              await session.retryLoadedSession();
              return !session.isClosed && !session.state.bootRecoveryRequired;
            },
          ),
        );
      }
      bool needsMonitorRecovery() =>
          !monitor.isClosed &&
          monitor.state.restoreFailed &&
          !persistence.sessionTransitionActive &&
          !session.state.bootRecoveryRequired;
      if (!needsMonitorRecovery()) {
        widget.controlNotices.dismiss(AppToastId.monitorRestore);
        return;
      }
      widget.controlNotices.show(
        ControlSettingsNotice(
          id: AppToastId.monitorRestore,
          title: (context) => Text(context.l10n.monitorRestoreFailedTitle),
          description: (context) => Text(context.l10n.monitorRestoreFailedBody),
          needsRecovery: needsMonitorRecovery,
          retry: () async {
            await monitor.load();
            return !monitor.isClosed && !monitor.state.restoreFailed;
          },
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  WaveformDisplayContext _displayContext() {
    final control = context.read<ControlCubit>().state;
    final name = context.read<TracksCubit>().state.nameOf(control.cursor);
    return WaveformDisplayContext(
      cursor: control.cursor,
      name: name,
      defaultName: name == storedDefaultTrackName(control.cursor),
      mode: control.mode.token,
      bank: control.activeBank,
      deviceLost:
          context.read<AudioSetupCubit>().state.deviceConnectivity ==
          DeviceConnectivity.lost,
      goodbye: readoutGoodbyeOf(context.read<PowerCubit>().state.phase),
      brightness: context.read<DisplayBrightnessCubit>().state.softwareOf(
        DisplayRole.track,
      ),
    );
  }

  void _updateDisplayContext() => _display.updateContext(_displayContext());

  Future<void> _bootstrapWindow() async {
    await context.read<WaveformWindowCubit>().load();
    if (!mounted) return;
    _display.start(
      enabled: context.read<WaveformWindowCubit>().state.enabled,
      title: _l10n.outputWaveformWindowTitle,
    );
  }

  void _syncWindow() => _display.setEnabled(
    enabled: context.read<WaveformWindowCubit>().state.enabled,
    title: _l10n.outputWaveformWindowTitle,
  );

  @override
  void dispose() {
    widget.waveformWindow.onWindowActivity = null;
    unawaited(_displayFailures?.cancel());
    unawaited(
      _display.close().catchError((Object error, StackTrace stack) {
        AppLog.error(
          'waveform display teardown failed',
          error: error,
          stack: stack,
        );
      }),
    );
    unawaited(_recoverySub?.cancel());
    dismissAppToast(AppToastId.recoveryRefused);
    super.dispose();
  }

  void _showRecoveryRefusal(RecoveryRefusal refusal) {
    if (!mounted) return;
    final l10n = _l10n;
    final pending = refusal.result == EngineResult.notReady;
    dismissAppToast(AppToastId.undoClearAll);
    showAppToast(
      id: AppToastId.recoveryRefused,
      autoCloseDuration: const Duration(seconds: 10),
      title: AppText(pending ? l10n.recoveryWaitTitle : l10n.recoveryModeTitle),
      description: AppText(
        pending
            ? l10n.recoveryWaitBody
            : switch (refusal.action) {
                RecoveryAction.undo => l10n.recoveryModeUndoBody,
                RecoveryAction.redo => l10n.recoveryModeRedoBody,
              },
      ),
      icon: Icon(
        refusal.action == RecoveryAction.undo ? Icons.undo : Icons.redo,
      ),
    );
  }

  /// Short "reconnected" snack toast when the pinned audio device returns.
  ///
  /// The *lost* branch is gone (#453): loss is a standing condition, held by
  /// the stage's `ConnectivityBanners` until the hardware returns; a toast is
  /// for the restored *event* only. A return that dropped some tracks (#1140:
  /// a Clear/Undo/Redo/cancel on them was still unapplied at the loss) is the
  /// same event with one fact added, so it is one transient warning toast
  /// naming those tracks — low stakes, the rig plays on — not a second
  /// notice. A return that cleared every loop is a standing condition and is
  /// the stage banner's, never a toast (#860: one notice per cause).
  void _showDeviceRestoredToast(AudioSetupState state) {
    final l10n = _l10n;
    final name = state.connectivityDeviceName.isEmpty
        ? l10n.audioDeviceFallbackName
        : state.connectivityDeviceName;
    switch (state.deviceConnectivity) {
      case DeviceConnectivity.restored:
        showAppSnackToast(
          id: AppToastId.deviceRestored,
          title: AppText(l10n.deviceReconnectedSnackbar(name)),
          icon: const Icon(Icons.check_circle_outline),
        );
      case DeviceConnectivity.restoredPartial:
        final dropped = state.engineStatus.reopen?.droppedChannels ?? const [];
        showAppToast(
          id: AppToastId.deviceRestoredPartial,
          type: ToastificationType.warning,
          title: AppText(l10n.deviceReconnectedSnackbar(name)),
          description: AppText(
            l10n.deviceRestoredPartialToastBody(
              dropped.length,
              dropped.map((channel) => '${channel + 1}').join(', '),
            ),
          ),
          icon: const Icon(Icons.layers_clear_outlined),
          autoCloseDuration: const Duration(seconds: 10),
        );
      case DeviceConnectivity.none:
      case DeviceConnectivity.lost:
      case DeviceConnectivity.restoredCleared:
        return;
    }
  }

  /// The MIDI controller's connectivity, surfaced as a transient toast.
  ///
  /// Unlike a lost audio interface — a standing condition that stops the
  /// engine and holds a persistent banner — a lost MIDI controller is
  /// low-stakes: the loops keep playing, only the mappings go idle. So the
  /// *lost* event flashes an amber toast that auto-dismisses and leaves no
  /// standing bar (#453), and *restored* stays a short snack. Neither is a
  /// persistent surface: `ConnectivityBanners` never mentions MIDI.
  void _showMidiConnectivityToast(MidiSetupState state) {
    final connection = state.connection;
    final l10n = _l10n;
    // The controller returning (or being reselected) retires the lost toast
    // at once rather than leaving it to time out beside the restored snack.
    dismissAppToast(AppToastId.midiLost);
    switch (connection.connectivity) {
      case MidiConnectivity.lost:
        showAppToast(
          id: AppToastId.midiLost,
          type: ToastificationType.warning,
          title: AppText(l10n.midiLostToastTitle),
          description: AppText(l10n.midiLostToastBody),
          icon: const Icon(Icons.piano_off_outlined),
          autoCloseDuration: const Duration(seconds: 6),
        );
      case MidiConnectivity.restored:
        final name = connection.connectivityDeviceName.isEmpty
            ? connection.selectedName
            : connection.connectivityDeviceName;
        showAppSnackToast(
          id: AppToastId.midiRestored,
          title: AppText(l10n.midiReconnectedSnackbar(name)),
          icon: const Icon(Icons.check_circle_outline),
        );
      case MidiConnectivity.none:
        break;
    }
  }

  /// Waiting for the pinned audio interface at boot; clears when recovery
  /// finishes (status returns to idle).
  void _showAudioRecoveryBanner(AudioRecoveryState state) {
    final l10n = _l10n;
    if (state.status != AudioRecoveryStatus.waitingForDevice) {
      dismissAppToast(AppToastId.audioRecovery);
      return;
    }
    showAppToast(
      id: AppToastId.audioRecovery,
      type: ToastificationType.warning,
      title: AppText(l10n.audioRecoveryWaitingBanner),
      icon: const Icon(Icons.usb_off_outlined),
      actions: [
        TextButton(
          onPressed: () => unawaited(openDeviceSettings()),
          child: AppText(l10n.settingsMenuItem),
        ),
      ],
    );
  }

  /// Startup notice that a newer build is available. Skipped when Updates is
  /// already open. "Not now" dismisses that version; "Update…" opens the
  /// Updates settings page.
  void _showUpdateBanner(BuildContext context, UpdateState state) {
    final manifest = state.available;
    if (!state.shouldNotify || manifest == null) {
      dismissAppToast(AppToastId.update);
      return;
    }
    if (isSegnoUpdatesSettingsOpen) {
      dismissAppToast(AppToastId.update);
      return;
    }
    final l10n = _l10n;
    final cubit = context.read<UpdateCubit>();
    showAppToast(
      id: AppToastId.update,
      title: AppText(l10n.updateBannerTitle('${manifest.version}')),
      icon: const Icon(Icons.system_update_outlined),
      actions: [
        TextButton(
          key: const Key(AppToastId.updateDismiss),
          onPressed: () {
            dismissAppToast(AppToastId.update);
            unawaited(cubit.dismiss(manifest.version));
          },
          child: AppText(l10n.updateBannerDismissAction),
        ),
        TextButton(
          key: const Key(AppToastId.updateAction),
          onPressed: () {
            dismissAppToast(AppToastId.update);
            unawaited(openUpdateSettings());
          },
          child: AppText(l10n.updateBannerUpdateAction),
        ),
      ],
    );
  }

  /// Secondary waveform window failed to open.
  void _showWaveformWindowFailedBanner() {
    final l10n = _l10n;
    showAppToast(
      id: AppToastId.waveformFailed,
      type: ToastificationType.error,
      title: AppText(l10n.waveformWindowFailedBanner),
      icon: const Icon(Icons.desktop_access_disabled_outlined),
    );
  }

  /// The console now always starts in Record; said once to an install whose
  /// retired boot default was Mute. Low stakes, nothing to act on: a toast.
  void _showBootModeRetiredNotice() {
    final l10n = _l10n;
    showAppToast(
      id: AppToastId.bootModeRetired,
      title: AppText(l10n.bootModeRetiredNotice),
      icon: const Icon(Icons.info_outline),
    );
  }

  /// Where the Tuner went once the tray stopped carrying it (#1229, D11):
  /// said once, the boot `Hold · Tuner` was added to Custom pedal 2.
  void _showTunerSeededNotice() {
    showAppToast(
      id: AppToastId.tunerSeeded,
      title: AppText(_l10n.footTunerSeeded),
      icon: const Icon(Icons.info_outline),
    );
  }

  /// Only one display on the dual-display console.
  void _showSingleDisplayNotice() {
    final l10n = _l10n;
    showAppToast(
      id: AppToastId.singleDisplay,
      type: ToastificationType.warning,
      title: AppText(l10n.singleDisplayNotice),
      icon: const Icon(Icons.monitor_outlined),
    );
  }

  /// Labels come from [_l10n] (above [MaterialApp]), not a builder context —
  /// the menu bar must not live under [MaterialApp] or DevTools / theme
  /// rebuilds remount it and trip the single-delegate lock assertion.
  List<PlatformMenuItem> get _menus {
    final l10n = _l10n;
    return [
      PlatformMenu(
        label: l10n.appMenuLabel,
        menus: [
          PlatformMenuItem(
            label: l10n.settingsMenuItem,
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              meta: true,
            ),
            onSelected: openSegnoSettings,
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final materialApp = MaterialApp(
      navigatorKey: segnoNavigatorKey,
      // Manual toggle forces high-contrast on every platform;
      // highContrastTheme also honors the OS flag (iOS).
      theme: context.watch<HighContrastCubit>().state
          ? AppTheme.highContrast
          : AppTheme.neon,
      highContrastTheme: AppTheme.highContrast,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          const Widget page = LooperPage();
          if (!segnoUsesFlutterTitleBar && !segnoUsesCursorAutoHide) {
            return page;
          }
          return SegnoWindowChromeShell(
            title: context.l10n.appMenuLabel,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: page,
          );
        },
      ),
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // Console only: weston's kiosk-shell spawns no input panel and the
        // image ships no IME, so without this every TextField on the
        // appliance is dead — including this branch's own Wi-Fi password
        // field. Inside the brightness wrapper so the keys dim with
        // everything else.
        final typed = EncoderNavigation(
          child: OnScreenKeyboardHost(
            child: AppTextDefaults(child: child ?? const SizedBox.shrink()),
          ),
        );
        return BlocBuilder<DisplayBrightnessCubit, DisplayBrightnessState>(
          buildWhen: (previous, current) =>
              previous.softwareOf(DisplayRole.main) !=
              current.softwareOf(DisplayRole.main),
          builder: (context, brightness) {
            final dimmed = SoftwareBrightness(
              brightness: brightness.softwareOf(DisplayRole.main),
              child: IdleDimHost(child: typed),
            );
            return BlocBuilder<PowerCubit, PowerState>(
              buildWhen: (previous, current) => previous != current,
              builder: (context, power) {
                final face = readoutGoodbyeOf(power.phase);
                // Always the Stack: moving the app in and out of one
                // would remount it, routes and all, as power-off begins.
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    dimmed,
                    if (face != ReadoutGoodbye.none)
                      PowerGoodbye(face: face, action: power.action),
                  ],
                );
              },
            );
          },
        );
      },
    );

    // Above MaterialApp so WidgetsApp's inspector wrap / theme animation
    // cannot remount the macOS menu delegate (single-lock assertion).
    final rooted = defaultTargetPlatform == TargetPlatform.macOS
        ? PlatformMenuBar(
            key: const ValueKey<String>('segno_platform_menu'),
            menus: _menus,
            child: materialApp,
          )
        : materialApp;

    return MultiBlocListener(
      listeners: [
        BlocListener<SessionCubit, SessionState>(
          listener: (_, _) => _reconcileRestoreNotices(),
        ),
        BlocListener<MonitorCubit, MonitorState>(
          listenWhen: (previous, current) =>
              previous.restoreFailed != current.restoreFailed,
          listener: (_, _) => _reconcileRestoreNotices(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listener: (_, _) => _updateDisplayContext(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listenWhen: (previous, current) =>
              previous.retiredBootMode == null &&
              current.retiredBootMode != null,
          listener: (_, _) => _showBootModeRetiredNotice(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listenWhen: (previous, current) =>
              !previous.tunerDefaultSeeded && current.tunerDefaultSeeded,
          listener: (_, _) => _showTunerSeededNotice(),
        ),
        BlocListener<TracksCubit, TracksState>(
          listener: (_, _) => _updateDisplayContext(),
        ),
        BlocListener<PowerCubit, PowerState>(
          listener: (_, _) => _updateDisplayContext(),
        ),
        BlocListener<DisplayBrightnessCubit, DisplayBrightnessState>(
          listenWhen: (previous, current) =>
              previous.softwareOf(DisplayRole.track) !=
              current.softwareOf(DisplayRole.track),
          listener: (_, _) => _updateDisplayContext(),
        ),
        BlocListener<WaveformWindowCubit, WaveformWindowState>(
          // Two changes re-sync, and deliberately not a third. The preference
          // flipping opens or closes the window; the failure being CLEARED is
          // the Display face's "Try again", which is why that button needs no
          // second control the shell would have to know about.
          //
          // The failure being RAISED must not, and that is not a nicety:
          // `_syncWindow` is what raises it, so re-entering on it would make
          // every failed open cost two attempts and two toasts.
          listenWhen: (previous, current) =>
              previous.enabled != current.enabled ||
              (previous.openFailed && !current.openFailed),
          listener: (_, _) => _syncWindow(),
        ),
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.deviceConnectivity != current.deviceConnectivity,
          listener: (_, state) {
            _updateDisplayContext();
            _showDeviceRestoredToast(state);
          },
        ),
        BlocListener<MidiSetupCubit, MidiSetupState>(
          listenWhen: (previous, current) =>
              previous.connection.connectivity !=
              current.connection.connectivity,
          listener: (_, state) => _showMidiConnectivityToast(state),
        ),
        BlocListener<AudioRecoveryCubit, AudioRecoveryState>(
          listenWhen: (previous, current) => previous.status != current.status,
          listener: (_, state) => _showAudioRecoveryBanner(state),
        ),
        BlocListener<UpdateCubit, UpdateState>(
          listenWhen: (previous, current) =>
              previous.shouldNotify != current.shouldNotify ||
              previous.available?.version != current.available?.version,
          listener: _showUpdateBanner,
        ),
      ],
      child: ToastificationWrapper(
        config: const ToastificationConfig(
          alignment: Alignment.topCenter,
          itemWidth: 520,
          animationDuration: Duration(milliseconds: 280),
        ),
        child: rooted,
      ),
    );
  }
}
