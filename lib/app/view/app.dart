import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:instrument_repository/instrument_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/app/application/app_runtime.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/app/view/encoder_navigation.dart';
import 'package:segno/app/view/standing_notices.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/appliance/idle_dim_host.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/appliance/power_off/power_host.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/appliance/wifi_reconnect_hold_host.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/backing/cubit/backing_cubit.dart';
import 'package:segno/backing/cubit/backing_mix_cubit.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/update/appliance/appliance_env.dart';
import 'package:segno/update/appliance/system_appliance_env.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/application/waveform_display_controller.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';
import 'package:update_repository/update_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// The root application widget.
class App extends StatefulWidget {
  /// Creates an [App] driven by the injected repositories.
  ///
  /// The repositories and [waveformWindow] are injected so tests can supply
  /// fakes / a no-op window service instead of the native device and the
  /// link to the Track display.
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
    required this.backingRepository,
    this.instrumentRepository,
    this.pedalRepository,
    this.audioRecoveryConfig,
    this.updates = const UpdateRepository(
      backend: UnsupportedPlatformBackend(),
    ),
    this.wifi = const WifiRepository(client: UnsupportedWifiClient()),
    this.brightness = const UnsupportedBrightnessClient(),
    this.displayOutputs = const UnknownDisplayOutputs(),
    this.touchCalibration = const UnsupportedTouchCalibrationClient(),
    this.consoleFacts = const UnsupportedConsoleFactsClient(),
    this.cpuLoad = const CpuLoadRepository.unsupported(),
    this.removableVolumes = const InternalOnlyVolumes(),
    this.storage,
    this.powerKeySource,
    this.powerOff,
    this.reboot,
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

  /// Reads and sets each panel's touch calibration. Defaults unsupported,
  /// which leaves Calibrate touch off the Displays page.
  final TouchCalibrationClient touchCalibration;

  /// Reads what the appliance knows about itself — the disk, the box, and
  /// where it can export to. Defaults to the client that answers "unknown",
  /// which is what every non-appliance build gets.
  final ConsoleFactsClient consoleFacts;

  /// The console's CPU load for the stage top bar (#1307). Defaults to the
  /// unsupported repository, which hides the readout; the entrypoint injects
  /// the `/proc/stat` one.
  final CpuLoadRepository cpuLoad;

  /// The removable drives the Library browses and copies to. Defaults to
  /// [InternalOnlyVolumes] (no drive, every removable write refused) until
  /// the storage service (#1177) stands behind the port.
  final RemovableVolumes removableVolumes;

  /// Where a write may go: Internal and the USB volumes. Null (the default)
  /// builds one over no USB at all, measuring Internal through
  /// [performanceRepository]; the entrypoint injects the appliance's.
  /// Restart and shutdown refuse while it holds a lease and wait for leases
  /// taken after the save.
  final StorageRepository? storage;

  /// Injected power-button source. Null (the default) starts an evdev
  /// listener on Linux when `segno-update-ctl` exists, and nothing elsewhere.
  final PowerKeySource? powerKeySource;

  /// Injected halt. Null (the default) runs `segno-update-ctl poweroff`.
  final Future<void> Function()? powerOff;

  /// Injected reboot. Null (the default) runs `segno-update-ctl reboot`,
  /// which boots a staged update slot when one is staged.
  final Future<void> Function()? reboot;

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

  /// The shared session repository (save/load + export), sharing the engine.
  final SessionRepository sessionRepository;

  /// The shared performance-recording repository, sharing the engine.
  final PerformanceRepository performanceRepository;

  /// The backing player's repository and managed store (#1200), sharing the
  /// engine.
  final BackingRepository backingRepository;

  /// The instruments' engine side (#1197), sharing the engine; null runs
  /// the app without instruments (tests that do not need them).
  final InstrumentRepository? instrumentRepository;

  @override
  State<App> createState() => _AppState();
}

/// Resolves the optional pedal pair once so a replacement [App] keeps
/// [ControlCubit], [PedalCubit], and dialog routes on one repository.
class _AppState extends State<App> {
  StreamSubscription<PowerState>? _powerNoticeSubscription;
  late final PedalRepository _pedal;
  late final StorageRepository _storage;
  late final AppRuntime _runtime;
  late final RecordOptionsCubit _recordView;
  StreamSubscription<MixSettingsOutcome>? _mixFailureSubscription;
  PowerKeySource? _powerKeySource;

  /// The app's one notice centre (#1562), held while the Power screen is up.
  final _notices = NoticesCubit();
  late final TempoCubit _tempoView;
  final _ownerSubscriptions = <StreamSubscription<void>>[];
  StreamSubscription<int>? _recordingInputRequiredSubscription;
  StreamSubscription<int>? _recordRefusedSubscription;
  StreamSubscription<int>? _fxTakeHeldSubscription;
  StreamSubscription<int>? _overdubRefusedSubscription;
  StreamSubscription<int>? _lengthHistoryRefusedSubscription;
  late final PlaybackOptionsCubit _playbackView;
  late final RecordTimingCubit _timingView;

  @override
  void initState() {
    super.initState();
    _pedal = widget.pedalRepository ?? PedalRepository(NoopPedalLink());
    _storage =
        widget.storage ??
        StorageRepository(
          client: const UnsupportedUsbStorageClient(),
          exportsRoot: widget.performanceRepository.exportsRoot,
          volumeSpace: widget.performanceRepository.volumeSpace,
          guards: widget.guards,
        );
    _runtime = AppRuntime(
      repository: widget.repository,
      settings: widget.settings,
      mix: widget.mixSettings,
      controllers: widget.controllerRepository,
      midiDevices: widget.midiDeviceRepository,
      pedal: _pedal,
      performance: widget.performanceRepository,
      sessions: widget.sessionRepository,
      storage: _storage,
      backing: widget.backingRepository,
      instruments: widget.instrumentRepository,
      powerOff: widget.powerOff ?? const SystemApplianceEnv().powerOff,
      reboot: widget.reboot ?? const SystemApplianceEnv().reboot,
      // RAUC's own state, asked again before the goodbye face (#1498).
      updateInstalling: widget.updates.installInProgress,
      storageSettled: _storage.settled,
      guards: widget.guards,
    );
    _powerNoticeSubscription = _runtime.power.stream.listen(
      (state) => _notices.setHeld(held: state.isUiUp),
    );
    _mixFailureSubscription = _runtime.mix.failures.listen(_showMixFailure);
    _tempoView = TempoCubit(settings: _runtime.tempo);
    for (final owner in _runtime.owners.all) {
      _ownerSubscriptions.addAll([
        owner.failures.listen((outcome) => _showOwnedFailure(owner, outcome)),
        // A restart replay can resolve an owed value without Retry.
        owner.recovered.listen(
          (_) => _notices.clear(_ownedNotice(owner.key).id),
        ),
      ]);
    }
    _recordingInputRequiredSubscription = widget
        .repository
        .recordingInputRequired
        .listen(_showRecordingInputRequired);
    _fxTakeHeldSubscription = widget.repository.fxTakeHeld.listen(
      _showFxTakeHeld,
    );
    _recordRefusedSubscription = widget.repository.recordRefusals.listen(
      (channel) => _showTrackRefused(channel, _recordRefused),
    );
    _overdubRefusedSubscription = widget.repository.overdubRefusals.listen(
      (channel) => _showTrackRefused(channel, _overdubRefused),
    );
    // An Undo or Redo of a length edit that did nothing (#1168): refused at
    // the tap or after it was posted, or queued taps that stopped at the
    // edit. From any surface, so a tap that did nothing is never silent.
    _lengthHistoryRefusedSubscription = widget.repository.lengthHistoryRefusals
        .listen((channel) => _showTrackRefused(channel, _lengthHistoryRefused));
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
    unawaited(_fxTakeHeldSubscription?.cancel());
    unawaited(_overdubRefusedSubscription?.cancel());
    unawaited(_lengthHistoryRefusedSubscription?.cancel());
    unawaited(_notices.close());
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
      // Only the repository this widget built; an injected one is its
      // owner's.
      if (widget.storage == null) closed.then((_) => _storage.dispose()),
      _timingView.close(),
      _recordView.close(),
      _playbackView.close(),
      _tempoView.close(),
      closed,
    ]);
  }

  /// A settings owner's failure (#1562): a value it owes is a must-act
  /// message with Retry until the owner is ready again; a change it refused
  /// passes by, and is dropped while that recovery stands (one cause, one
  /// notice).
  void _showOwnedFailure(
    SettingsOwner<Object, Object?> owner,
    SettingOutcome outcome,
  ) {
    if (!mounted || outcome.status == SettingStatus.superseded) return;
    final notice = _ownedNotice(owner.key);
    AppLog.error(
      '${owner.key.name}: ${outcome.status.name} ${outcome.error ?? ''}',
    );
    if (outcome.status == SettingStatus.recoveryRequired) {
      _notices.raise(
        Notice(
          id: notice.id,
          tone: NoticeTone.warning,
          title: notice.recovery,
          action: retryNoticeAction(
            _notices,
            notice.id,
            () async => (await owner.recover()).isOk,
          ),
        ),
      );
      return;
    }
    // A recovery resolved without its Retry no longer stands.
    if (owner.ready) _notices.clear(notice.id);
    _notices.show(
      Notice(id: notice.id, tone: NoticeTone.warning, title: notice.refused),
    );
  }

  static ({String id, NoticeText recovery, NoticeText refused}) _ownedNotice(
    OwnedSetting key,
  ) => switch (key) {
    OwnedSetting.clickVolume => (
      id: AppNoticeId.clickSettings,
      recovery: (l10n) => l10n.clickSettingsRecoveryTitle,
      refused: (l10n) => l10n.clickSettingsRefusedTitle,
    ),
    OwnedSetting.hearClick => (
      id: AppNoticeId.clickModeSettings,
      recovery: (l10n) => l10n.clickModeSettingsRecoveryTitle,
      refused: (l10n) => l10n.clickModeSettingsRefusedTitle,
    ),
    OwnedSetting.recordStart => (
      id: AppNoticeId.recordStartSettings,
      recovery: (l10n) => l10n.recordStartSettingsRecoveryTitle,
      refused: (l10n) => l10n.recordStartSettingsRefusedTitle,
    ),
    OwnedSetting.decay => (
      id: AppNoticeId.decaySettings,
      recovery: (l10n) => l10n.decaySettingsRecoveryTitle,
      refused: (l10n) => l10n.decaySettingsRefusedTitle,
    ),
    OwnedSetting.oneShot => (
      id: AppNoticeId.oneShotSettings,
      recovery: (l10n) => l10n.oneShotSettingsRecoveryTitle,
      refused: (l10n) => l10n.oneShotSettingsRefusedTitle,
    ),
    OwnedSetting.recordLength => (
      id: AppNoticeId.recordLengthSettings,
      recovery: (l10n) => l10n.recordLengthSettingsRecoveryTitle,
      refused: (l10n) => l10n.recordLengthSettingsRefusedTitle,
    ),
    OwnedSetting.recordTiming => (
      id: AppNoticeId.recordTimingSettings,
      recovery: (l10n) => l10n.recordTimingSettingsRecoveryTitle,
      refused: (l10n) => l10n.recordTimingSettingsRefusedTitle,
    ),
    OwnedSetting.fade => (
      id: AppNoticeId.fadeSettings,
      recovery: (l10n) => l10n.fadeSettingsRecoveryTitle,
      refused: (l10n) => l10n.fadeSettingsRefusedTitle,
    ),
    OwnedSetting.backingMix => (
      id: AppNoticeId.backingMixSettings,
      recovery: (l10n) => l10n.backingMixSettingsRecoveryTitle,
      refused: (l10n) => l10n.backingMixSettingsRefusedTitle,
    ),
    OwnedSetting.clickPan => (
      id: AppNoticeId.clickPanSettings,
      recovery: (l10n) => l10n.clickPanSettingsRecoveryTitle,
      refused: (l10n) => l10n.clickPanSettingsRefusedTitle,
    ),
    OwnedSetting.followTempo => (
      id: AppNoticeId.followTempoSettings,
      recovery: (l10n) => l10n.followTempoSettingsRecoveryTitle,
      refused: (l10n) => l10n.followTempoSettingsRefusedTitle,
    ),
    OwnedSetting.pitchMode => (
      id: AppNoticeId.pitchModeSettings,
      recovery: (l10n) => l10n.pitchModeSettingsRecoveryTitle,
      refused: (l10n) => l10n.pitchModeSettingsRefusedTitle,
    ),
    OwnedSetting.instruments => (
      id: AppNoticeId.instrumentsSettings,
      recovery: (l10n) => l10n.instrumentsSettingsRecoveryTitle,
      refused: (l10n) => l10n.instrumentsSettingsRefusedTitle,
    ),
  };

  /// A take whose inherited effects did not fit came in with them switched
  /// off (#1515, the owner's R1). The take sounds dry until the player makes
  /// room, which matters little in the moment: a message on its track. While
  /// the standing effects-off message is up the repository adds the take to
  /// it instead.
  void _showFxTakeHeld(int channel) {
    if (!mounted) return;
    _notices.showOnTrack(
      channel,
      Notice(
        id: AppNoticeId.fxTakeHeld,
        tone: NoticeTone.warning,
        overline: (l10n) => l10n.noticeEffectsOff,
        title: (l10n) => l10n.fxTakeHeldToast,
        body: (l10n) => l10n.fxTakeHeldBody,
      ),
    );
  }

  /// A Record press on a track with no recording input: said on its track.
  void _showRecordingInputRequired(int channel) {
    if (!mounted) return;
    _notices.showOnTrack(
      channel,
      Notice(
        id: AppNoticeId.recordingInputRequired,
        tone: NoticeTone.warning,
        overline: (l10n) => l10n.noticeNoInput,
        title: (l10n) => l10n.recordingInputRequiredTitle,
      ),
    );
  }

  /// A press the engine refused on a track: a fresh capture refused twice
  /// (#1146), an overdub on a reversed track, or a length Undo or Redo that
  /// did nothing (#1168). The press is lost, so its track says why.
  void _showTrackRefused(int channel, Notice notice) {
    if (!mounted) return;
    _notices.showOnTrack(channel, notice);
  }

  static final _recordRefused = Notice(
    id: AppNoticeId.recordRefused,
    tone: NoticeTone.warning,
    overline: (l10n) => l10n.noticeRecRefused,
    title: (l10n) => l10n.recordRefusedTitle,
    body: (l10n) => l10n.recordRefusedBody,
  );

  static final _overdubRefused = Notice(
    id: AppNoticeId.overdubRefused,
    tone: NoticeTone.warning,
    overline: (l10n) => l10n.noticeOverdubRefused,
    title: (l10n) => l10n.footReverseOverdubRefused,
  );

  static final _lengthHistoryRefused = Notice(
    id: AppNoticeId.lengthHistoryRefused,
    tone: NoticeTone.warning,
    overline: (l10n) => l10n.noticeLengthUnchanged,
    title: (l10n) => l10n.lengthHistoryRefused,
    body: (l10n) => l10n.lengthHistoryRefusedBody,
  );

  /// The mix owner's failure: a recovery is must-act (critical when audio
  /// was stopped to protect the settings), a refused change passes by.
  void _showMixFailure(MixSettingsOutcome outcome) {
    if (!mounted || outcome.status == MixSettingsStatus.superseded) return;
    AppLog.error('Mix settings: ${outcome.status.name} ${outcome.error ?? ''}');
    final mix = _runtime.mix;
    if (outcome.status == MixSettingsStatus.recoveryRequired) {
      final stopped = mix.stoppedForRecovery;
      _notices.raise(
        Notice(
          id: AppNoticeId.mixSettings,
          tone: stopped ? NoticeTone.critical : NoticeTone.warning,
          title: (l10n) => l10n.mixSettingsRecoveryTitle,
          body: stopped ? (l10n) => l10n.mixSettingsStoppedBody : null,
          action: retryNoticeAction(
            _notices,
            AppNoticeId.mixSettings,
            () async => (await mix.recover()).isOk,
          ),
        ),
      );
      return;
    }
    if (!mix.recoveryRequired) _notices.clear(AppNoticeId.mixSettings);
    final notSaved = outcome.status == MixSettingsStatus.storageFailed;
    _notices.show(
      Notice(
        id: AppNoticeId.mixSettings,
        tone: NoticeTone.warning,
        title: (l10n) =>
            notSaved ? l10n.mixSettingsNotSaved : l10n.mixSettingsNotApplied,
      ),
    );
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
        RepositoryProvider.value(value: _runtime.backingSettings),
        RepositoryProvider.value(value: _runtime.backingPlayer),
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
        RepositoryProvider.value(value: widget.touchCalibration),
        RepositoryProvider.value(value: widget.waveformWindow),
        RepositoryProvider.value(value: widget.consoleFacts),
        RepositoryProvider.value(value: widget.cpuLoad),
        RepositoryProvider<RemovableVolumes>.value(
          value: widget.removableVolumes,
        ),
        RepositoryProvider.value(value: _storage),
        // The one guard table (#1198), for the owners the views build: the
        // Library's exports and backups enter transfer guards on what
        // they read.
        RepositoryProvider<GuardRegistry>.value(value: widget.guards),
        if (_powerKeySource != null)
          RepositoryProvider<PowerKeySource>.value(value: _powerKeySource!),
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
          BlocProvider<NoticesCubit>.value(value: _notices),
          BlocProvider<LooperBloc>.value(value: _runtime.looper),
          BlocProvider<SessionCubit>.value(value: _runtime.session),
          BlocProvider<BackingCubit>.value(value: _runtime.backingView),
          BlocProvider<BackingMixCubit>.value(value: _runtime.backingMixView),
          BlocProvider<TracksCubit>.value(value: _runtime.tracks),
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
          // The stage footer's `OUT` readout, refreshed four times a second
          // rather than on every 16 ms engine poll (#1301).
          BlocProvider(
            create: (context) => OutputLevelCubit(
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
          BlocProvider<StorageCubit>.value(value: _runtime.storage),
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
          // Eager (not lazy): it follows the boot's audio warm-up to its end,
          // so a player's config the device refused is told (#1533).
          BlocProvider(
            lazy: false,
            create: (context) => AudioSetupCubit(
              repository: context.read<LooperRepository>(),
              settings: context.read<SettingsRepository>(),
              guards: widget.guards,
              backing: widget.backingRepository,
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
          // Eager (not lazy): every start the console makes on its own is an
          // audio warm-up, and this opens the player's config once the
          // console has settled (#1533). It watches from the first frame on.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = AudioWarmUpCubit(
                looper: context.read<LooperRepository>(),
                guards: widget.guards,
                ready: () =>
                    WidgetsBinding.instance.waitUntilFirstFrameRasterized,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Eager (not lazy): the boot-time silent salvage (D-SALVAGE, #679)
          // must start the moment the app composes, not whenever a widget
          // first reads this cubit — a crashed capture recovers in the
          // background whether or not the tracks view ever mounts.
          // The recorder's Save to (#1177): read by the recorder at each arm.
          BlocProvider(
            create: (_) => RecordingDestinationCubit(
              repository: _storage,
              sampleRate: () => widget.repository.state.status.sampleRate,
            ),
          ),
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PerformanceRecorderCubit(
                performance: context.read<PerformanceRepository>(),
                // The runtime's lock, which also holds during an audio
                // warm-up (#1533).
                takeLocked: () => _runtime.takeLocked,
                storage: _storage,
                destination: () =>
                    context.read<RecordingDestinationCubit>().state.destination,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
        ],
        child: _AppView(waveformWindow: widget.waveformWindow),
      ),
    );
  }
}

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for tracks mode.
class _AppView extends StatefulWidget {
  const _AppView({required this.waveformWindow});

  final WaveformWindowService waveformWindow;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  late final WaveformDisplayController _display;
  StreamSubscription<WaveformDisplayFailure>? _displayFailures;
  StreamSubscription<RecoveryRefusal>? _recoverySub;
  bool _restoreNoticeScheduled = false;

  /// "Not now" on the power-cycle message holds until the next boot.
  bool _powerCycleDismissed = false;

  /// The weak-charger message is said once per boot.
  bool _weakChargerShown = false;

  NoticesCubit get _notices => context.read<NoticesCubit>();

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
    );
    _displayFailures = _display.failures.listen((failure) {
      if (!mounted) return;
      switch (failure) {
        case WaveformDisplayFailure.openFailed:
          context.read<WaveformWindowCubit>().reportOpenFailed();
          _showWaveformWindowFailed();
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
    _notices.show(
      Notice(
        id: AppNoticeId.bluetoothRetired,
        explains: true,
        icon: LucideIcons.bluetoothOff,
        title: (l10n) => l10n.bluetoothRetiredTitle,
        body: (l10n) => l10n.bluetoothRetiredNotice(count),
      ),
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
        _notices.clear(AppNoticeId.sessionBootRecovery);
      } else if (session.state.status == SessionStatus.failure) {
        // The loaded session is stopped until its settings are confirmed:
        // critical, with Retry.
        _notices.raise(
          Notice(
            id: AppNoticeId.sessionBootRecovery,
            tone: NoticeTone.critical,
            title: (l10n) => l10n.sessionBootRecoveryTitle,
            body: (l10n) => l10n.sessionBootRecoveryBody,
            action: retryNoticeAction(
              _notices,
              AppNoticeId.sessionBootRecovery,
              () async {
                await session.retryLoadedSession();
                return !session.isClosed && !session.state.bootRecoveryRequired;
              },
            ),
          ),
        );
      }
      bool needsMonitorRecovery() =>
          !monitor.isClosed &&
          monitor.state.restoreFailed &&
          !persistence.sessionTransitionActive &&
          !session.state.bootRecoveryRequired;
      if (!needsMonitorRecovery()) {
        _notices.clear(AppNoticeId.monitorRestore);
        return;
      }
      _notices.raise(
        Notice(
          id: AppNoticeId.monitorRestore,
          tone: NoticeTone.warning,
          title: (l10n) => l10n.monitorRestoreFailedTitle,
          action: retryNoticeAction(
            _notices,
            AppNoticeId.monitorRestore,
            () async {
              await monitor.load();
              return !monitor.isClosed && !monitor.state.restoreFailed;
            },
          ),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  WaveformDisplayContext _displayContext() {
    final control = context.read<ControlCubit>().state;
    final power = context.read<PowerCubit>().state;
    final name = context.read<TracksCubit>().state.nameOf(control.cursor);
    return WaveformDisplayContext(
      cursor: control.cursor,
      name: name,
      defaultName: name == storedDefaultTrackName(control.cursor),
      mode: control.mode.token,
      bank: control.activeBank,
      notice: _readoutNotice(),
      goodbye: readoutGoodbyeOf(
        power,
        installsUpdate:
            stagedUpdateVersion(context.read<UpdateCubit>().state) != null,
      ),
      savingStep: power.step,
      savingProgress: power.progress,
      brightness: context.read<DisplayBrightnessCubit>().state.softwareOf(
        DisplayRole.track,
      ),
    );
  }

  /// What the readout's band says (#1562): what a top bar with no track
  /// cards says, in the same order; a track's message says the track's name
  /// first.
  ReadoutNotice? _readoutNotice() {
    final notices = context.read<NoticesCubit>().state;
    final l10n = _l10n;
    final passing = notices.passing();
    final channel = passing?.channel;
    final shown = passing?.shown ?? notices.banner;
    if (shown == null) return null;
    final notice = shown.notice;
    return ReadoutNotice(
      title: notice.title(l10n),
      body: notice.body?.call(l10n),
      tone: notice.tone,
      track: channel == null
          ? null
          : l10n.trackName(context.read<TracksCubit>().state.names, channel),
    );
  }

  void _updateDisplayContext() => _display.updateContext(_displayContext());

  Future<void> _bootstrapWindow() async {
    await context.read<WaveformWindowCubit>().load();
    if (!mounted) return;
    _display.start(
      enabled: context.read<WaveformWindowCubit>().state.enabled,
    );
  }

  void _syncWindow() => _display.setEnabled(
    enabled: context.read<WaveformWindowCubit>().state.enabled,
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
    super.dispose();
  }

  /// An Undo or Redo the recovery path refused: said for a while, since it
  /// tells the player what to change first.
  void _showRecoveryRefusal(RecoveryRefusal refusal) {
    if (!mounted) return;
    final pending = refusal.result == EngineResult.notReady;
    _notices.show(
      Notice(
        id: AppNoticeId.recoveryRefused,
        tone: NoticeTone.warning,
        explains: true,
        title: (l10n) =>
            pending ? l10n.recoveryWaitTitle : l10n.recoveryModeTitle,
        body: (l10n) => pending
            ? l10n.recoveryWaitBody
            : switch (refusal.action) {
                RecoveryAction.undo => l10n.recoveryModeUndoBody,
                RecoveryAction.redo => l10n.recoveryModeRedoBody,
              },
      ),
    );
  }

  /// The pinned audio interface came back: a confirmation.
  ///
  /// The loss itself is a must-act message (`StandingNotices`). A return
  /// that dropped some tracks (#1140: a Clear/Undo/Redo/cancel on them was
  /// still unapplied at the loss) is the same event with one fact added, so
  /// it is one warning naming those tracks; the rig plays on. A return that
  /// cleared every loop stands as must-act, never here (#860: one notice per
  /// cause).
  void _showDeviceRestored(AudioSetupState state) {
    final device = state.connectivityDeviceName;
    String name(AppLocalizations l10n) =>
        device.isEmpty ? l10n.audioDeviceFallbackName : device;
    switch (state.deviceConnectivity) {
      case DeviceConnectivity.restored:
        _notices.show(
          Notice(
            id: AppNoticeId.deviceRestored,
            tone: NoticeTone.success,
            title: (l10n) => l10n.deviceReconnectedSnackbar(name(l10n)),
          ),
        );
      case DeviceConnectivity.restoredPartial:
        final dropped = state.engineStatus.reopen?.droppedChannels ?? const [];
        _notices.show(
          Notice(
            id: AppNoticeId.deviceRestoredPartial,
            tone: NoticeTone.warning,
            explains: true,
            title: (l10n) => l10n.deviceReconnectedSnackbar(name(l10n)),
            body: (l10n) => l10n.deviceRestoredPartialToastBody(
              dropped.length,
              dropped.map((channel) => '${channel + 1}').join(', '),
            ),
          ),
        );
      case DeviceConnectivity.none:
      case DeviceConnectivity.lost:
      case DeviceConnectivity.waiting:
      case DeviceConnectivity.restoredCleared:
        return;
    }
  }

  /// The MIDI controller's connectivity, as passing messages: losing it
  /// leaves the loops playing and only the mappings idle, so it is a
  /// warning that goes by itself (#453); its return is a confirmation that
  /// takes the warning's place.
  void _showMidiConnectivity(MidiSetupState state) {
    final connection = state.connection;
    switch (connection.connectivity) {
      case MidiConnectivity.lost:
        _notices.show(
          Notice(
            id: AppNoticeId.midiLost,
            tone: NoticeTone.warning,
            title: (l10n) => l10n.midiLostToastTitle,
            body: (l10n) => l10n.midiLostToastBody,
          ),
        );
      case MidiConnectivity.restored:
        final name = connection.connectivityDeviceName.isEmpty
            ? connection.selectedName
            : connection.connectivityDeviceName;
        _notices
          ..clear(AppNoticeId.midiLost)
          ..show(
            Notice(
              id: AppNoticeId.midiRestored,
              tone: NoticeTone.success,
              title: (l10n) => l10n.midiReconnectedSnackbar(name),
            ),
          );
      case MidiConnectivity.none:
        _notices.clear(AppNoticeId.midiLost);
    }
  }

  /// The USB-C contract predates the console profile, so the console runs on
  /// less than the charger offers until it is unplugged and plugged back in
  /// (#1352). A must-act message in the warning tone with Power off…, which
  /// opens the Power options, whose Safe to switch off face says to unplug;
  /// "Not now" puts it off until the next boot, and it clears itself once
  /// the new contract is in.
  void _showPowerCycle(PedalPowerSupply? supply) {
    if (supply == null || !supply.needsPowerCycle || _powerCycleDismissed) {
      _notices.clear(AppNoticeId.powerCycle);
      return;
    }
    final offered = wattsText(supply.offeredWatts);
    _notices.raise(
      Notice(
        id: AppNoticeId.powerCycle,
        tone: NoticeTone.warning,
        icon: LucideIcons.plugZap,
        title: (l10n) => l10n.powerCycleBannerTitle(offered),
        action: NoticeAction(
          key: const Key(AppNoticeId.powerCyclePowerOff),
          label: (l10n) => l10n.powerCycleBannerPowerOff,
          onPressed: () {
            if (mounted) requestPower(context);
          },
        ),
        secondary: NoticeAction(
          key: const Key(AppNoticeId.powerCycleDismiss),
          label: (l10n) => l10n.powerCycleBannerDismiss,
          onPressed: () {
            _powerCycleDismissed = true;
            _notices.clear(AppNoticeId.powerCycle);
          },
        ),
      ),
    );
  }

  /// The charger itself offers too little for the console at full load.
  /// Said once per boot and never in the way: the console runs, and may
  /// only brown out at full brightness.
  void _showWeakCharger(PedalPowerSupply? supply) {
    if (supply == null || _weakChargerShown || !chargerIsWeak(supply)) return;
    _weakChargerShown = true;
    final offered = wattsText(supply.offeredWatts);
    _notices.show(
      Notice(
        id: AppNoticeId.weakCharger,
        tone: NoticeTone.warning,
        title: (l10n) => l10n.weakChargerToast(offered),
        body: (l10n) => l10n.weakChargerBody,
      ),
    );
  }

  /// A newer build is available: said for a while at startup with Update…,
  /// which opens the Updates page. The page keeps the offer; nothing here
  /// needs a touch. Not said while Updates is already open.
  void _showUpdate(BuildContext context, UpdateState state) {
    final manifest = state.available;
    if (!state.shouldNotify || manifest == null || isSegnoUpdatesSettingsOpen) {
      _notices.clear(AppNoticeId.update);
      return;
    }
    final version = '${manifest.version}';
    _notices.show(
      Notice(
        id: AppNoticeId.update,
        explains: true,
        icon: LucideIcons.download,
        title: (l10n) => l10n.updateBannerTitle(version),
        action: NoticeAction(
          key: const Key(AppNoticeId.updateAction),
          label: (l10n) => l10n.updateBannerUpdateAction,
          onPressed: () {
            _notices.clear(AppNoticeId.update);
            unawaited(openUpdateSettings());
          },
        ),
      ),
    );
  }

  /// The second screen's window failed to open. The Displays page holds the
  /// standing state with its Try again; this says it when it happens.
  void _showWaveformWindowFailed() {
    _notices.show(
      Notice(
        id: AppNoticeId.waveformFailed,
        tone: NoticeTone.warning,
        title: (l10n) => l10n.waveformWindowFailedBanner,
      ),
    );
  }

  /// FX mode's Stop no longer switches every track's effects off, and MODE
  /// there now leaves FX (#1229, D13); said once, together, at the first FX
  /// entry after the update.
  void _showFxStopChanged() {
    _notices.show(
      Notice(
        id: AppNoticeId.fxStopChanged,
        explains: true,
        icon: LucideIcons.info,
        title: (l10n) => l10n.footFxStopChanged,
        body: (l10n) => l10n.footFxModeChanged,
      ),
    );
  }

  /// The drive chosen in Save to went: the next take goes to Internal, and
  /// the player is told rather than finding out afterwards.
  void _showSaveToFellBack(String label) {
    _notices.show(
      Notice(
        id: AppNoticeId.saveToFellBack,
        tone: NoticeTone.warning,
        title: (l10n) =>
            l10n.saveToFellBack(label.isEmpty ? l10n.storageUsbUnnamed : label),
        body: (l10n) => l10n.saveToFellBackBody,
      ),
    );
  }

  /// The console now always starts in Record; said once to an install whose
  /// retired boot default was Mute.
  void _showBootModeRetired() {
    _notices.show(
      Notice(
        id: AppNoticeId.bootModeRetired,
        explains: true,
        icon: LucideIcons.info,
        title: (l10n) => l10n.bootModeRetiredNotice,
        body: (l10n) => l10n.bootModeRetiredBody,
      ),
    );
  }

  /// Where the Tuner went once the tray stopped carrying it (#1229, D11):
  /// said once, the boot `Hold · Tuner` was added to Custom pedal 2.
  void _showTunerSeeded() {
    _notices.show(
      Notice(
        id: AppNoticeId.tunerSeeded,
        explains: true,
        icon: LucideIcons.info,
        title: (l10n) => l10n.footTunerSeeded,
        body: (l10n) => l10n.footTunerSeededBody,
      ),
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
      home: const LooperPage(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        // Console only: the appliance has no input method (ivi-homescreen
        // brings no text-input panel and the image ships no IME), so without
        // this every TextField on it is dead — including the Wi-Fi password
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
              child: IdleDimHost(
                child: WifiReconnectHoldHost(child: typed),
              ),
            );
            return BlocBuilder<PowerCubit, PowerState>(
              buildWhen: (previous, current) => previous != current,
              builder: (context, power) {
                // Always the Stack: moving the app in and out of one
                // would remount it, routes and all, as power-off begins.
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    dimmed,
                    PowerGoodbye(
                      state: power,
                      stagedUpdate: context.select<UpdateCubit, String?>(
                        (update) => stagedUpdateVersion(update.state),
                      ),
                      unplugToApply: context.select<PedalCubit, bool>(
                        (pedal) =>
                            pedal.state.powerSupply?.needsPowerCycle ?? false,
                      ),
                    ),
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
        BlocListener<NoticesCubit, NoticesState>(
          listener: (_, _) => _updateDisplayContext(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listenWhen: (previous, current) =>
              previous.retiredBootMode == null &&
              current.retiredBootMode != null,
          listener: (_, _) => _showBootModeRetired(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listenWhen: (previous, current) =>
              !previous.tunerDefaultSeeded && current.tunerDefaultSeeded,
          listener: (_, _) => _showTunerSeeded(),
        ),
        BlocListener<ControlCubit, ControlState>(
          listenWhen: (previous, current) =>
              !previous.fxStopChangeNotice && current.fxStopChangeNotice,
          listener: (_, _) => _showFxStopChanged(),
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
          // The readout's line also names the device.
          listenWhen: (previous, current) =>
              previous.deviceConnectivity != current.deviceConnectivity ||
              previous.connectivityDeviceName != current.connectivityDeviceName,
          listener: (_, state) {
            _updateDisplayContext();
            _showDeviceRestored(state);
          },
        ),
        BlocListener<MidiSetupCubit, MidiSetupState>(
          listenWhen: (previous, current) =>
              previous.connection.connectivity !=
              current.connection.connectivity,
          listener: (_, state) => _showMidiConnectivity(state),
        ),
        BlocListener<AudioRecoveryCubit, AudioRecoveryState>(
          listenWhen: (previous, current) => previous.status != current.status,
          // The stage's strip says it, not a toast (#1270 Part 5).
          listener: (context, state) =>
              context.read<AudioSetupCubit>().setWaitingForDevice(
                waiting: state.status == AudioRecoveryStatus.waitingForDevice,
              ),
        ),
        // The drive chosen in Save to went: the next take goes to Internal,
        // and the player is told rather than finding out afterwards.
        BlocListener<RecordingDestinationCubit, RecordingDestinationState>(
          listenWhen: (previous, current) =>
              current.fellBackFrom != null &&
              previous.fellBackFrom != current.fellBackFrom,
          listener: (_, state) => _showSaveToFellBack(state.fellBackFrom!),
        ),
        BlocListener<PedalCubit, PedalState>(
          listenWhen: (previous, current) =>
              previous.powerSupply != current.powerSupply,
          listener: (_, state) {
            _showPowerCycle(state.powerSupply);
            _showWeakCharger(state.powerSupply);
          },
        ),
        BlocListener<UpdateCubit, UpdateState>(
          listenWhen: (previous, current) =>
              previous.shouldNotify != current.shouldNotify ||
              previous.available?.version != current.available?.version,
          listener: _showUpdate,
        ),
        // The readout's Restarting face follows whether an update installs.
        BlocListener<UpdateCubit, UpdateState>(
          listenWhen: (previous, current) =>
              stagedUpdateVersion(previous) != stagedUpdateVersion(current),
          listener: (_, _) => _updateDisplayContext(),
        ),
      ],
      child: StandingNotices(child: rooted),
    );
  }
}
