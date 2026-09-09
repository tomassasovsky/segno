import 'dart:async';
import 'dart:io';

import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_goodbye.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';
import 'package:segno/common/pedal_device.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/flashed_firmware.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/update/appliance/system_appliance_env.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/update/view/pedal_firmware_gate.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:segno/window/window_chrome.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';
import 'package:update_repository/update_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// How often the main window pushes a waveform frame to the second window.
const _waveformFrame = Duration(milliseconds: 33); // ~30 fps

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
    required this.waveformWindow,
    required this.sessionRepository,
    required this.performanceRepository,
    required this.exportDirectory,
    this.simulatedControllerSource,
    this.pedalRepository,
    this.pedalSimulator,
    this.displayCount,
    this.audioRecoveryConfig,
    this.initialAsioDrivers = const [],
    this.updates = const UpdateRepository(
      backend: UnsupportedPlatformBackend(),
    ),
    this.wifi = const WifiRepository(client: UnsupportedWifiClient()),
    this.bluetooth = const BluetoothRepository(
      client: UnsupportedBluetoothClient(),
    ),
    this.brightness = const UnsupportedBrightnessClient(),
    this.consoleFacts = const UnsupportedConsoleFactsClient(),
    this.powerKeySource,
    this.powerOff,
    super.key,
  });

  /// The software-update repository. Defaults to an inert
  /// (unsupported-platform) instance so the update UI stays hidden; the app
  /// entrypoint injects the platform-appropriate one.
  final UpdateRepository updates;

  /// Appliance WiFi repository (Control Center). Defaults unsupported.
  final WifiRepository wifi;

  /// Appliance Bluetooth repository (Control Center). Defaults unsupported.
  final BluetoothRepository bluetooth;

  /// Appliance brightness client (Control Center slider). Defaults unsupported.
  final BrightnessClient brightness;

  /// Reads what the appliance knows about itself — the disk, the box, and
  /// where it can export to. Defaults to the client that answers "unknown",
  /// which is what every non-appliance build gets.
  final ConsoleFactsClient consoleFacts;

  /// Injected power-button source. Null (the default) starts an evdev
  /// listener on Linux when `segno-update-ctl` exists, and nothing elsewhere.
  final PowerKeySource? powerKeySource;

  /// Injected halt. Null (the default) runs `segno-update-ctl poweroff`.
  final Future<void> Function()? powerOff;

  /// The shared looper repository (owns the audio engine).
  final LooperRepository repository;

  /// The shared controller repository (MIDI → looper actions).
  final ControllerRepository controllerRepository;

  /// The push seam behind "Simulate input" (#519), registered in
  /// [controllerRepository]'s sources. Handed to [ControlCubit] so a mapping
  /// can prove itself with no controller attached. `null` (the default) in a
  /// test that wires no simulation — the affordance is then inert.
  final SimulatedControllerSource? simulatedControllerSource;

  /// The MIDI input device repository (owns the foot-controller lifecycle). It
  /// borrows the long-lived native MIDI source from [controllerRepository] and
  /// never disposes it; the [MidiSetupCubit] projects its state.
  final MidiDeviceRepository midiDeviceRepository;

  /// The bidirectional pedal repository (MIDI output + reused input capture),
  /// or `null` when none was built — a no-op transport is substituted so pedal
  /// cubit always exists and its settings picker shows an empty state. Owned by
  /// the [PedalCubit], which disposes it.
  final PedalRepository? pedalRepository;

  /// The on-screen pedal simulator transport that [pedalRepository] is built
  /// over, or `null` when none was built. The fuzz harness injects presses
  /// and reads decoded frames from it. Disposed by the [PedalCubit] (via the
  /// repository), so it is provided by value, not created here.
  final SimulatorPedalTransport? pedalSimulator;

  /// Reports the number of connected displays, for the dual-display console's
  /// single-display fallback. `null` (the default) disables the fallback
  /// (assumes the usual multi-window desktop); the Pi entrypoint wires the real
  /// platform display count.
  final int Function()? displayCount;

  /// The pinned audio config a boot auto-start could not open, handed to the
  /// [AudioRecoveryCubit] so the engine auto-starts when that device reappears.
  /// `null` (the default) when the engine started or there is no pinned device.
  final EngineConfig? audioRecoveryConfig;

  /// The shared settings repository (persists latency calibration + config).
  final SettingsRepository settings;

  /// Manages the secondary output-waveform window.
  final WaveformWindowService waveformWindow;

  /// The ASIO drivers enumerated at startup, cached by the audio-setup cubit so
  /// the picker stays populated even while ASIO holds the device (R1).
  final List<AudioDevice> initialAsioDrivers;

  /// The shared session repository (save/load + export), sharing the engine.
  final SessionRepository sessionRepository;

  /// The shared performance-recording repository, sharing the engine.
  final PerformanceRepository performanceRepository;

  /// Resolves the directory a mixdown / stems export is written to.
  final Future<String> Function() exportDirectory;

  @override
  State<App> createState() => _AppState();
}

/// Resolves the optional pedal pair once so a replacement [App] keeps
/// [ControlCubit], [PedalCubit], and dialog routes on one repository.
class _AppState extends State<App> {
  late final SimulatorPedalTransport _simulator;
  late final PedalRepository _pedal;
  PowerKeySource? _powerKeySource;
  ControlCubit? _control;

  @override
  void initState() {
    super.initState();
    _simulator =
        widget.pedalSimulator ??
        SimulatorPedalTransport(inner: const NoopPedalTransport());
    _pedal = widget.pedalRepository ?? PedalRepository(_simulator);
    _powerKeySource =
        widget.powerKeySource ??
        openAppliancePowerKeySource(
          isLinux: Platform.isLinux,
          helperExists: File('/usr/bin/segno-update-ctl').existsSync(),
        );
  }

  @override
  void dispose() {
    unawaited(_powerKeySource?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: widget.repository),
        RepositoryProvider.value(value: widget.controllerRepository),
        RepositoryProvider.value(value: widget.midiDeviceRepository),
        RepositoryProvider.value(value: widget.settings),
        RepositoryProvider.value(value: widget.sessionRepository),
        RepositoryProvider.value(value: widget.performanceRepository),
        RepositoryProvider.value(value: _simulator),
        RepositoryProvider.value(value: _pedal),
        RepositoryProvider.value(value: widget.updates),
        RepositoryProvider.value(value: widget.wifi),
        RepositoryProvider.value(value: widget.bluetooth),
        RepositoryProvider.value(value: widget.brightness),
        RepositoryProvider.value(value: widget.consoleFacts),
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
          // Runs the pedal flash an OS update left pending, and holds the
          // looper closed while it does. lazy:false so it starts with the app
          // rather than when something first reads it.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PedalFirmwareCubit(
                updates: context.read<UpdateRepository>(),
              );
              unawaited(cubit.run());
              return cubit;
            },
          ),
          // App-wide brightness: software dim in [MaterialApp.builder] + DDC
          // when the host helper supports it (LG TVs often do not).
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = DisplayBrightnessCubit(
                settings: context.read<SettingsRepository>(),
                client: context.read<BrightnessClient>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          // Provided app-wide (not just on the looper page) so the settings
          // route — pushed on the root navigator, above the looper page — can
          // drive routing edits through the bloc, mirroring the in-view routing
          // controls. The TracksCubit below is hoisted for the same reason.
          // No `controller:` — MIDI stays on the page LooperBloc, which
          // injects the power-off take lock. A second subscriber here would
          // fire Clear/Record twice and bypass that lock.
          BlocProvider(
            create: (context) {
              final bloc = LooperBloc(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              // Boot-restore the persisted mode (B5c) — dispatched as an
              // event, not a bloc method (bloc_lint's
              // avoid_public_bloc_methods).
              unawaited(
                restoreLooperMode(bloc, context.read<SettingsRepository>()),
              );
              return bloc;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = TracksCubit(
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
          // The tuner is lazy on purpose, unlike its neighbours: it subscribes
          // to the looper stream and arms the engine, and a console that never
          // opens the Tuner face should pay for neither.
          BlocProvider(
            create: (context) =>
                TunerCubit(repository: context.read<LooperRepository>()),
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
          BlocProvider(
            create: (context) {
              final cubit = RecordTimingCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = TempoCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
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
          BlocProvider(
            create: (context) {
              final cubit = RecordOptionsCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
          BlocProvider(
            create: (context) {
              final cubit = PlaybackOptionsCubit(
                repository: context.read<LooperRepository>(),
                settings: context.read<SettingsRepository>(),
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
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
          // Above ControlCubit so take-start can read isUiUp. flushMappings
          // cannot context.read a descendant — capture the instance below.
          BlocProvider(
            lazy: false,
            create: (context) => PowerOffCubit(
              flush: () {
                try {
                  context.read<MonitorCubit>().flushPersistence();
                } on Object catch (error, stack) {
                  AppLog.error(
                    'power-off monitor flush failed',
                    error: error,
                    stack: stack,
                  );
                }
                try {
                  _control?.flushMappings();
                } on Object catch (error, stack) {
                  AppLog.error(
                    'power-off mappings flush failed',
                    error: error,
                    stack: stack,
                  );
                }
                try {
                  context.read<LooperBloc>().add(const LooperPersistFlush());
                } on Object catch (error, stack) {
                  AppLog.error(
                    'power-off looper flush failed',
                    error: error,
                    stack: stack,
                  );
                }
              },
              pedalGoodbye: () => context.read<PedalRepository>().pushState(
                PedalStateFrame.blank(goodbye: true),
              ),
              powerOff: widget.powerOff ?? SystemApplianceEnv().powerOff,
            ),
          ),
          // Eager (not lazy): the ONE control-surface interpreter and owner
          // of stored user intent (mode / cursor / bank / play intent). The
          // pedal's decoded footswitches reach it through PedalRepository's
          // event stream and its projected LED frames leave through the same
          // repository, so the keyboard, on-screen widgets, and the pedal
          // share one cursor, one mode, one command path — with repositories
          // composed at the bloc level, per the layered architecture.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = ControlCubit(
                looper: context.read<LooperRepository>(),
                pedal: context.read<PedalRepository>(),
                settings: context.read<SettingsRepository>(),
                performance: context.read<PerformanceRepository>(),
                // Both of these were missing, and external MIDI mapping had
                // therefore never worked in a shipped build: without
                // `controller` nothing subscribes to the binding events and
                // `learnControllerBinding` returns on its first line, so Add
                // sweep / Add switch picked a target and then did nothing at
                // all; without `midiDevices` a controller coming back re-armed
                // nothing. Both repositories were already built and provided
                // app-wide — they were simply never handed to the one cubit
                // that owns controller intent.
                controller: context.read<ControllerRepository>(),
                midiDevices: context.read<MidiDeviceRepository>(),
                simulatedSource: widget.simulatedControllerSource,
                takeLocked: () => context.read<PowerOffCubit>().state.isUiUp,
              );
              _control = cubit;
              unawaited(cubit.load()); // boot-default mode restore
              return cubit;
            },
          ),
          // Eager (not lazy): the pedal LINK feature auto-binds the saved
          // output device on launch and keeps it bound across hotplugs. It
          // shares the PedalRepository with ControlCubit (binding here,
          // events/frames there) — the cubits know nothing of each other.
          BlocProvider(
            lazy: false,
            create: (context) {
              final cubit = PedalCubit(
                pedal: context.read<PedalRepository>(),
                settings: context.read<SettingsRepository>(),
                autoBindProductNames: kPedalAutoBindProductNames,
                flashedProtocolVersion: kFlashedPedalProtocolVersionReader,
              );
              unawaited(cubit.load());
              return cubit;
            },
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
                takeLocked: () => context.read<PowerOffCubit>().state.isUiUp,
              );
              unawaited(cubit.load());
              return cubit;
            },
          ),
        ],
        child: _AppView(
          waveformWindow: widget.waveformWindow,
          exportDirectory: widget.exportDirectory,
          displayCount: widget.displayCount,
        ),
      ),
    );
  }
}

/// The inputs [_AppViewState._readoutOf] was last given, remembered so an
/// unchanged frame can be skipped in front of the build instead of after it.
///
/// A record rather than a `List<Object?>`: the fields are compared one by one
/// and each on its own terms (see `_pushReadoutIfChanged`), which a positional
/// list made easy to get quietly wrong.
typedef _ReadoutInputs = ({
  LooperState looper,
  TracksState tracks,
  ControlState control,
  AudioSetupState audio,
  PowerOffPhase powerOff,
});

/// Builds the themed [MaterialApp], wires the macOS system menu, and opens /
/// closes the secondary waveform window for tracks mode.
class _AppView extends StatefulWidget {
  const _AppView({
    required this.waveformWindow,
    required this.exportDirectory,
    this.displayCount,
  });

  final WaveformWindowService waveformWindow;
  final Future<String> Function() exportDirectory;
  final int Function()? displayCount;

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  Timer? _pushTimer;

  /// Drives the waveform frames while the sub-window is open. `null` when it
  /// is closed. See [_requestWaveformFrame] for why the frames follow the poll
  /// rather than [_pushTimer].
  StreamSubscription<LooperState>? _pollSub;

  /// Open between waveform frames — while it runs, a frame is held back
  /// rather than sent, and the last one held is sent when it fires. This is
  /// what paces the second screen at ~[_waveformFrame] whatever the console's
  /// refresh rate is set to, WITHOUT a free-running clock of its own; see
  /// [_requestWaveformFrame].
  Timer? _frameGate;

  /// The newest projection that arrived while [_frameGate] was closed, sent on
  /// the trailing edge. `null` when nothing is waiting.
  LooperState? _pendingFrame;

  /// The label the last waveform frame carried. `null` before the first frame
  /// and after the window closes.
  String? _lastFrameLabel;

  /// The cursor the last waveform frame was sent for, with [_lastFrameLabel]:
  /// two tracks may share a name, so the label alone cannot tell a cursor
  /// move apart from a rig standing still.
  int? _lastFrameCursor;

  /// The projection the last frame SENT carried, so a rejection that lands
  /// late can tell whether it has been superseded. See [_sendWaveformFrame].
  LooperState? _lastSentFrame;

  /// The states [_readoutOf] was last given. `null` before the first push and
  /// after the window closes, so a re-opened window is re-seeded from scratch
  /// — the same discipline `pushReadout` applies to its own last-sent diff.
  _ReadoutInputs? _lastReadoutInputs;
  int _readoutRevision = 0;

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
    widget.waveformWindow.onWindowReady = _onWindowReady;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_bootstrapWindow()),
    );
  }

  /// Waits for the persisted waveform-window preference before opening the
  /// window so a disabled preference does not flash a second OS window on
  /// launch.
  Future<void> _bootstrapWindow() async {
    await context.read<WaveformWindowCubit>().load();
    if (!mounted) return;
    await _syncWindow();
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    _frameGate?.cancel();
    unawaited(_pollSub?.cancel());
    widget.waveformWindow.onWindowReady = null;
    unawaited(widget.waveformWindow.close());
    super.dispose();
  }

  /// A sub-window has announced itself, and therefore holds NOTHING.
  ///
  /// Every diff on this side is a belief about what is already on the second
  /// screen, so all of them are void: the readout gate, and the label the
  /// waveform tick compares against. The service drops its own two on the
  /// same signal, but dropping them is not enough here — the readout is
  /// rebuilt by the next timer tick, while a waveform frame is only produced
  /// by an EVENT, and a rig that is not moving produces none. So one is
  /// requested outright, or a reclaimed window shows an empty waveform beside
  /// a live readout until something happens to change.
  void _onWindowReady() {
    if (!mounted) return;
    _lastReadoutInputs = null;
    _readoutRevision++;
    _lastFrameLabel = null;
    _requestWaveformFrame(context.read<LooperRepository>().lastState);
  }

  /// Whether only one display is connected (the console expects two). `null`
  /// detection (desktop default) is treated as multi-display.
  bool get _isSingleDisplay => (widget.displayCount?.call() ?? 2) < 2;

  /// Opens the secondary waveform window when it is enabled; closes it
  /// otherwise.
  Future<void> _syncWindow() async {
    if (!mounted) return;
    final waveform = context.read<WaveformWindowCubit>();
    if (waveform.state.enabled) {
      // On a single-display console the waveform has nowhere to land: skip the
      // second window and show a notice rather than a half-blank setup.
      if (_isSingleDisplay) {
        _showSingleDisplayNotice();
        return;
      }
      final ready = await widget.waveformWindow.open(
        title: _l10n.outputWaveformWindowTitle,
      );
      if (!mounted) return;
      if (!ready) {
        // The window never readied: surface it and don't stream frames to a
        // dead window (the real service has already set its controller, so
        // pushWaveform would otherwise not no-op).
        //
        // Recorded on the cubit as well as toasted, because the toast is the
        // wrong surface once the tray is open: `SYSTEM / display` puts the
        // failure at the top of the list the setting lives in, with a retry.
        // Both read the one flag, so the two can never disagree.
        waveform.reportOpenFailed();
        _showWaveformWindowFailedBanner();
        return;
      }
      // The waveform follows the POLL, not this timer — see
      // [_requestWaveformFrame].
      _pollSub ??= context.read<LooperRepository>().looperState.listen(
        _requestWaveformFrame,
      );
      _pushTimer ??= Timer.periodic(_waveformFrame, (_) {
        if (!mounted) return;
        final looper = context.read<LooperRepository>();
        final control = context.read<ControlCubit>().state;
        // The readout is what this timer is FOR: its inputs are bloc states
        // with no common stream to listen to, and the facts it draws are ones
        // the performer causes — a footswitch arming a track, the cursor
        // moving, a rename — so it is polled at frame rate and gated on
        // change.
        //
        // The waveform frame is not pushed here as a rule: the poll drives
        // it. This tick covers the one input the poll cannot see — the
        // selected-track LABEL, which is not looper state at all, so on a
        // stopped rig (where the deduped poll emits nothing) moving the
        // cursor would otherwise never reach the second screen. It goes
        // through the same gate as a poll, so it can never jump ahead of one.
        final label = context.read<TracksCubit>().state.nameOf(control.cursor);
        final state = looper.lastState;
        if (label != _lastFrameLabel || control.cursor != _lastFrameCursor) {
          _requestWaveformFrame(state);
        }
        // Same timer, different discipline from the old push: the readout
        // rarely changes, so `pushReadout` already dropped anything equal to
        // what it last sent rather than re-serialising eight track records at
        // frame rate across an engine boundary.
        //
        // That diff was placed for the CHANNEL, not for the CPU: it dropped
        // ~29 of every 30 readouts *after* paying to build them. The gate
        // below moves the same decision in front of the build, so an
        // unchanged frame costs a handful of compares instead of a whole
        // projection (#898).
        _pushReadoutIfChanged(
          state,
          context.read<TracksCubit>().state,
          control,
          context.read<AudioSetupCubit>().state,
          context.read<PowerOffCubit>().state.phase,
        );
      });
    } else {
      _pushTimer?.cancel();
      _pushTimer = null;
      _frameGate?.cancel();
      _frameGate = null;
      _pendingFrame = null;
      unawaited(_pollSub?.cancel());
      _pollSub = null;
      _lastFrameLabel = null;
      _lastFrameCursor = null;
      _lastSentFrame = null;
      _lastReadoutInputs = null;
      _readoutRevision++;
      await widget.waveformWindow.close();
    }
  }

  /// Sends a waveform frame for [state], or holds it until the gate opens.
  ///
  /// Driven by the poll — and by a label change on the tick below — rather
  /// than by a periodic push, because the playhead a frame carries IS the
  /// poll's. A timer of its own period resamples
  /// [LooperRepository.lastState] on a clock that beats against the poll's:
  /// at the 30 Hz refresh setting a 33 ms timer reads a 33.33 ms projection,
  /// so roughly every hundredth frame repeats the playhead and the next skips
  /// two — visible stutter on the second screen and the 7" panel, for a value
  /// that was exact before it was read out of the cache. Sending on the event
  /// that produced the value removes the second clock entirely.
  ///
  /// The gate is a rate limit, NOT a decimator, and the difference matters:
  /// [LooperRepository.looperState] is deduped, so an emit is a CHANGE, not a
  /// tick. Dropping every second one would drop half of the rig's discrete
  /// events outright — a stop, a clear, an undo on a quiet rig emits once and
  /// never again, and there is no following poll to carry it. So a frame that
  /// arrives early is remembered and sent on the trailing edge instead, and
  /// the last state always wins.
  void _requestWaveformFrame(LooperState state) {
    if (!mounted) return;
    if (_frameGate != null) {
      _pendingFrame = state;
      return;
    }
    _sendWaveformFrame(state);
  }

  void _sendWaveformFrame(LooperState state) {
    final looper = context.read<LooperRepository>();
    final cursor = context.read<ControlCubit>().state.cursor;
    final label = context.read<TracksCubit>().state.nameOf(cursor);
    _lastFrameLabel = label;
    _lastFrameCursor = cursor;
    _lastSentFrame = state;
    _pendingFrame = null;
    _armFrameGate();
    // The SELECTED track's own peaks and playhead (the accepted small
    // display), not the mixed output: an empty selected track sends an empty
    // buffer, never a borrowed shape.
    final selected = state.tracks.firstWhere(
      (track) => track.channel == cursor,
      orElse: () => const Track(),
    );
    // One copy per track lives in the repository; this is a lookup unless the
    // shape can still be changing (see `readTrackWaveform`).
    final samples = selected.hasContent
        ? looper.readTrackWaveform(cursor)
        : Float32List(0);
    unawaited(
      widget.waveformWindow
          .pushWaveform(samples, selected.progress, label)
          .catchError((Object _) {
            // It never landed. Nothing else will produce a frame on a rig
            // that is not moving — the poll is deduped and the label has not
            // changed — so the lost frame has to be re-queued here or the
            // second screen keeps whatever it last drew. Re-QUEUED, not
            // re-sent: the gate is what keeps a window that is failing every
            // frame from spinning.
            //
            // Only while this is still the newest frame anyone has sent. A
            // rejection crosses the channel and can land several polls late,
            // and re-sending a superseded one would put an OLDER playhead on
            // screen as the last word — on a rig that then goes quiet, for
            // good. If a newer frame went out it either landed (nothing to
            // heal) or is healing itself through this same path; if one is
            // merely waiting, `??=` leaves it alone.
            if (!mounted || !identical(_lastSentFrame, state)) return;
            _pendingFrame ??= state;
            _armFrameGate();
          }),
    );
  }

  void _armFrameGate() {
    _frameGate ??= Timer(_waveformFrame, _openFrameGate);
  }

  void _openFrameGate() {
    _frameGate = null;
    final pending = _pendingFrame;
    if (pending != null && mounted) _sendWaveformFrame(pending);
  }

  /// Builds and pushes the readout only when a fact it is projected FROM has
  /// actually changed.
  ///
  /// [_readoutOf] is pure over its inputs, so unchanged inputs give an
  /// identical readout and there is nothing to build. The cubit states are
  /// immutable values replaced wholesale on emit, which makes reference
  /// identity a sound test and a very cheap one.
  ///
  /// [LooperState] is the exception, and the whole reason this is not eight
  /// pointer compares: see [_sameReadoutFacts].
  ///
  /// Deliberately NOT a slower timer. The readout draws things the performer
  /// causes — a footswitch arming a track, the cursor moving, a fader dragged
  /// on the sub-window's own volume overlay — and a 1 Hz cadence would make
  /// the second screen visibly lag the gesture that changed it. Gating on
  /// change keeps frame-rate responsiveness and pays frame-rate cost only
  /// when something moved.
  void _pushReadoutIfChanged(
    LooperState looper,
    TracksState tracks,
    ControlState control,
    AudioSetupState audio,
    PowerOffPhase powerOff,
  ) {
    final last = _lastReadoutInputs;
    if (last != null &&
        _sameReadoutFacts(looper, last.looper, control.cursor) &&
        identical(tracks, last.tracks) &&
        identical(control, last.control) &&
        identical(audio, last.audio) &&
        powerOff == last.powerOff) {
      return;
    }
    final revision = ++_readoutRevision;
    _lastReadoutInputs = (
      looper: looper,
      tracks: tracks,
      control: control,
      audio: audio,
      powerOff: powerOff,
    );
    unawaited(
      widget.waveformWindow
          .pushReadout(_readoutOf(looper, tracks, control, audio, powerOff))
          .catchError((Object _) {
            // It never landed, so this gate is now a belief about a readout
            // the second screen does not have. Drop it — the next tick then
            // rebuilds and re-sends rather than suppressing an identical
            // readout forever. Guarded by revision so a failure that
            // completes after a newer readout has already been armed cannot
            // undo it.
            if (_readoutRevision == revision) {
              _lastReadoutInputs = null;
            }
          }),
    );
  }

  /// Whether [a] and [b] agree on every fact [_readoutOf] reads out of the
  /// looper for the track at [cursor].
  ///
  /// **This is the one input the gate cannot compare as a whole**, by identity
  /// or by value. A rig that is merely playing produces a different
  /// `LooperState` on every single poll: the transport position, the output
  /// peak and every track's `peak` and `positionFrames` advance, and all are
  /// part of `LooperState ==`, so `_poll`'s `next == _last` dedupe publishes a
  /// fresh object each tick. A gate written as `identical(looper, previous)`
  /// is therefore a gate that never closes in exactly the case it was written
  /// for — the performing one — and only appears to work on an idle rig.
  ///
  /// The tempting repair is the wrong one: **do not take `peak` (or the
  /// positions) out of equality to make the projection identity-stable.**
  /// The console's meters are fed through that same equality — the repository
  /// publishes nothing when the new projection compares equal to the last —
  /// so a level outside `Track.props` is a level that never reaches any UI.
  /// `Track.props` carries the same warning at the definition.
  ///
  /// So the projection stays complete and the gate narrows instead. The list
  /// below is exactly what [_readoutOf] reads off `looper` — the transport
  /// fields it copies, and the selected track's steady facts — and
  /// deliberately nothing else. A fact added there must be added here; the
  /// readout tests in `app_test.dart` fail if it is not.
  static bool _sameReadoutFacts(LooperState a, LooperState b, int cursor) {
    if (identical(a, b)) return true;
    final ta = a.transport;
    final tb = b.transport;
    if (ta.tempoBpm != tb.tempoBpm ||
        ta.tempoSource != tb.tempoSource ||
        ta.tsNum != tb.tsNum ||
        ta.tsDen != tb.tsDen ||
        ta.loopBars != tb.loopBars ||
        ta.primaryTrack != tb.primaryTrack) {
      return false;
    }
    if (a.tracks.length != b.tracks.length) return false;
    final x = _trackAt(a, cursor);
    final y = _trackAt(b, cursor);
    if (x == null || y == null) return x == y;
    return x.state == y.state &&
        x.muted == y.muted &&
        x.pending == y.pending &&
        x.multiple == y.multiple &&
        x.undoDepth == y.undoDepth &&
        // Content, not length: a take in progress grows `lengthFrames` every
        // tick, and the readout draws neither the length nor the waveform.
        x.hasContent == y.hasContent;
  }

  static Track? _trackAt(LooperState state, int channel) {
    for (final track in state.tracks) {
      if (track.channel == channel) return track;
    }
    return null;
  }

  /// Projects engine + control state onto the 7" readout's value type — the
  /// selected track's facts plus the tempo and the current function/bank,
  /// composed once for the channel.
  ///
  /// Pure and static so it can be tested without a window: what the second
  /// screen shows is a function of state, never of when the timer fired.
  /// Track names stay the STORED ones with a `defaultName` flag, so the
  /// sub-window can localize a default identity itself.
  static PerformanceReadout _readoutOf(
    LooperState looper,
    TracksState tracks,
    ControlState control,
    AudioSetupState audio,
    PowerOffPhase powerOff,
  ) {
    final transport = looper.transport;
    final track = _trackAt(looper, control.cursor);
    return PerformanceReadout(
      selected: track == null
          ? null
          : ReadoutTrack(
              channel: track.channel,
              name: tracks.nameOf(track.channel),
              state: track.state.name,
              muted: track.muted,
              pending: track.pending,
              primary: track.channel == transport.primaryTrack,
              defaultName:
                  tracks.nameOf(track.channel) ==
                  storedDefaultTrackName(track.channel),
              bars: track.hasContent && transport.loopBars > 0
                  ? transport.loopBars * track.multiple
                  : 0,
              layers: track.layers,
            ),
      tempoBpm: transport.tempoBpm,
      hasTempo: transport.tempoSource != TempoSource.none,
      tsNum: transport.tsNum,
      tsDen: transport.tsDen,
      mode: control.mode.token,
      activeBank: control.activeBank,
      // The stage's one standing loss condition, echoed on the 7" readout
      // (`c/device-lost`): the performer is looking down, not at the main
      // screen. A boolean only — the echoed line is the pen's fixed copy, so
      // no name rides the wire. MIDI loss is a transient toast, not a
      // standing condition, so it never rides the readout.
      deviceLost: audio.deviceConnectivity == DeviceConnectivity.lost,
      goodbye: readoutGoodbyeOf(powerOff),
    );
  }

  /// Short "reconnected" snack toast when the pinned audio device returns.
  ///
  /// The *lost* branch is gone (#453): loss is a standing condition, held by
  /// the stage's `ConnectivityBanners` until the hardware returns; a toast is
  /// for the restored *event* only.
  void _showDeviceRestoredToast(AudioSetupState state) {
    if (state.deviceConnectivity != DeviceConnectivity.restored) return;
    final l10n = _l10n;
    final name = state.connectivityDeviceName.isEmpty
        ? l10n.audioDeviceFallbackName
        : state.connectivityDeviceName;
    showAppSnackToast(
      id: AppToastId.deviceRestored,
      title: AppText(l10n.deviceReconnectedSnackbar(name)),
      icon: const Icon(Icons.check_circle_outline),
    );
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
          onPressed: () => unawaited(openSegnoSettings()),
          child: AppText(l10n.settingsMenuItem),
        ),
      ],
    );
  }

  /// Startup notice that a newer build is available. Skipped when Settings →
  /// Updates is already open. "Not now" dismisses that version; "Update…"
  /// opens the Updates section.
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
            unawaited(openSegnoSettings(section: SettingsSection.updates));
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
          final Widget page = PedalFirmwareGate(
            child: LooperPage(exportDirectory: widget.exportDirectory),
          );
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
        final typed = OnScreenKeyboardHost(
          child: AppTextDefaults(child: child ?? const SizedBox.shrink()),
        );
        return BlocBuilder<DisplayBrightnessCubit, double>(
          buildWhen: (previous, current) => previous != current,
          builder: (context, brightness) {
            final dimmed = SoftwareBrightness(
              brightness: brightness,
              child: typed,
            );
            return BlocBuilder<PowerOffCubit, PowerOffState>(
              buildWhen: (previous, current) => previous.phase != current.phase,
              builder: (context, powerOff) {
                final face = readoutGoodbyeOf(powerOff.phase);
                if (face == ReadoutGoodbye.none) return dimmed;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    dimmed,
                    PowerOffGoodbye(face: face),
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
          listener: (_, _) => unawaited(_syncWindow()),
        ),
        BlocListener<AudioSetupCubit, AudioSetupState>(
          listenWhen: (previous, current) =>
              previous.deviceConnectivity != current.deviceConnectivity,
          listener: (_, state) => _showDeviceRestoredToast(state),
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
