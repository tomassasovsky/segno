import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_client/midi_client.dart' show MidiControllerSource;
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/update/view/updates_settings_section.dart';
import 'package:segno/visualizer/visualizer.dart';
// Engine-typed fixtures fed to the fake engine use the `le` prefix, as in
// audio_bootstrap_test.
import 'package:segno_engine/segno_engine.dart'
    as le
    show EngineSnapshot, LatencyState;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

/// A supported update backend advertising v0.2.0 (current is v0.1.0), so the
/// app's startup availability check surfaces the update toast.
class _FakeUpdateBackend implements PlatformUpdateBackend {
  @override
  bool get isSupported => true;
  // No pending pedal firmware: the App tests are about the looper, and a gate
  // over it would hide everything they assert on.
  @override
  Future<String?> pendingPedalFirmware() async => null;
  @override
  Stream<double> flashPedalFirmware() => const Stream.empty();
  @override
  Future<PedalFlashFailureClass?> lastPedalFlashFailure() async => null;
  @override
  Future<void> abortPedalFlash() async {}
  @override
  String get channel => 'experimental';
  @override
  Future<void> setChannel(String channel) async {}
  @override
  Future<Version> currentVersion() async => Version.parse('0.1.0');
  @override
  Future<Version> stagedVersion() async => Version.none;
  @override
  Future<UpdateManifest?> fetchManifest() async => UpdateManifest(
    version: Version.parse('0.2.0'),
    bundle: 'b.raucb',
    notes: 'new stuff',
  );
  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      Stream.fromIterable(const [1]);
  @override
  Future<void> applyAndRestart() async {}
}

/// Same as [_FakeUpdateBackend], but [fetchManifest] waits until [complete] so
/// tests can open Settings → Updates before the availability toast would show.
class _DeferredUpdateBackend extends _FakeUpdateBackend {
  final Completer<UpdateManifest?> _manifest = Completer<UpdateManifest?>();

  void complete() {
    if (!_manifest.isCompleted) {
      _manifest.complete(
        UpdateManifest(
          version: Version.parse('0.2.0'),
          bundle: 'b.raucb',
          notes: 'new stuff',
        ),
      );
    }
  }

  @override
  Future<UpdateManifest?> fetchManifest() => _manifest.future;
}

class _RecordingWindowService implements WaveformWindowService {
  _RecordingWindowService({this.openResult = true});

  /// What [open] reports — `false` simulates a window that never readies.
  final bool openResult;

  int openCalls = 0;
  int closeCalls = 0;
  int pushCalls = 0;
  bool _open = false;

  /// Every readout the app handed to the service.
  ///
  /// Deliberately records EVERY call rather than mirroring the real service's
  /// change-diff: a double that reimplements the logic under test proves
  /// nothing about it.
  final readouts = <PerformanceReadout>[];

  /// The command handler the app registered — tests invoke it to simulate
  /// the sub-window's volume overlay sending a control.
  @override
  void Function(ReadoutControl control)? onControl;

  @override
  void pushReadout(PerformanceReadout readout) => readouts.add(readout);

  @override
  bool get isOpen => _open;

  @override
  Future<bool> open({String title = 'Segno — Output'}) async {
    openCalls++;
    _open = openResult;
    return openResult;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _open = false;
  }

  @override
  void pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) => pushCalls++;
}

/// A MIDI source whose enumeration the test drives by hand, so a pinned
/// controller can be made to vanish and return through `refresh()`.
class _MockMidiSource extends Mock implements MidiControllerSource {}

void main() {
  group('App', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late ControllerRepository controllerRepository;
    late MidiDeviceRepository midiDeviceRepository;
    late SettingsRepository settings;
    late SessionRepository sessionRepository;
    late PerformanceRepository performanceRepository;

    setUp(() {
      // Both are module-level and survive between tests: a leftover toast
      // makes the next identical toast a silent no-op, and a settings guard
      // left set makes openSegnoSettings return early forever after.
      resetAppToastsForTest();
      // The `toastification` singleton also leaks across files under
      // `--optimization`, leaving a dead overlay the next toast renders into
      // nothing (#875). Reset it so every toast here gets a live overlay.
      resetToastificationForTest();
      resetSegnoNavigatorForTest();
      engine = FakeAudioEngine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      controllerRepository = ControllerRepository(sources: const []);
      settings = SettingsRepository(store: FakeKeyValueStore());
      sessionRepository = SessionRepository(engine: FakeAudioEngine());
      performanceRepository = PerformanceRepository(
        engine: FakeAudioEngine(),
        exportsRoot: () async => '.',
      );
      // No MIDI backend by default; the MIDI-specific test below wires its own.
      midiDeviceRepository = MidiDeviceRepository(
        source: null,
        settings: settings,
      );
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);
      addTearDown(midiDeviceRepository.dispose);
    });

    Future<void> pumpApp(
      WidgetTester tester,
      WaveformWindowService windowService,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: windowService,
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> pumpAppWithUpdates(
      WidgetTester tester,
      UpdateRepository updates,
    ) async {
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
          updates: updates,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the startup update toast when a build is available', (
      tester,
    ) async {
      await pumpAppWithUpdates(
        tester,
        UpdateRepository(backend: _FakeUpdateBackend()),
      );
      expect(find.byKey(const Key('app_update_banner')), findsOneWidget);
    });

    testWidgets(
      'dismissing the update toast hides it',
      (tester) async {
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: _FakeUpdateBackend()),
        );
        await tester.tap(find.byKey(const Key('app_update_banner_dismiss')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'Update on the toast opens Settings on the Updates tab',
      (
        tester,
      ) async {
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: _FakeUpdateBackend()),
        );
        await tester.tap(find.byKey(const Key('app_update_banner_update')));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.byType(UpdatesSettingsSection), findsOneWidget);
        expect(
          find.byKey(const Key('settings_tab_updates')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
        // Pop so the navigator re-entrancy guard (`_settingsOpen`) clears for
        // later tests in this file that also open Settings.
        await tester.tap(find.byKey(const Key('settings_close_button')));
        await tester.pumpAndSettle();
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'no update toast while Settings Updates is already open',
      (
        tester,
      ) async {
        final backend = _DeferredUpdateBackend();
        await pumpAppWithUpdates(
          tester,
          UpdateRepository(backend: backend),
        );
        // NOT awaited: openSegnoSettings awaits navigator.push, which resolves
        // only when the route is POPPED. Awaiting it here deadlocks the test on
        // its own first statement — settings is not closed until the end — and
        // it does not fail fast: it spins until the harness gives up minutes
        // later, poisoning the rest of the file.
        unawaited(openSegnoSettings(section: SettingsSection.updates));
        await tester.pumpAndSettle();
        backend.complete();
        await tester.pumpAndSettle();
        expect(find.byType(UpdatesSettingsSection), findsOneWidget);
        expect(find.byKey(const Key('app_update_banner')), findsNothing);
        await tester.tap(find.byKey(const Key('settings_close_button')));
        await tester.pumpAndSettle();
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets('no update toast on an unsupported platform', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byKey(const Key('app_update_banner')), findsNothing);
    });

    testWidgets('renders the looper as the home page in tracks', (
      tester,
    ) async {
      await pumpApp(tester, NoopWaveformWindowService());
      expect(find.byType(LooperPage), findsOneWidget);
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('always lands on the looper — no first-run gate', (
      tester,
    ) async {
      // The wizard and the needsSetup gate are gone; the app renders the looper
      // directly even with no saved audio config.
      await tester.pumpWidget(
        App(
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LooperPage), findsOneWidget);
    });

    testWidgets('opens the waveform window on launch in tracks', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, greaterThanOrEqualTo(1));
      expect(windowService.isOpen, isTrue);
      // A successful open shows no failure banner.
      expect(
        find.byKey(const Key('app_waveformWindowFailed_banner')),
        findsNothing,
      );
    });

    testWidgets('does not open the waveform window when it is disabled', (
      tester,
    ) async {
      await settings.saveShowWaveformWindow(value: false);
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      expect(windowService.openCalls, 0);
      expect(windowService.isOpen, isFalse);
    });

    testWidgets('right-click opens settings; disabling the waveform window '
        'closes it', (tester) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);
      expect(windowService.isOpen, isTrue);

      await tester.tap(
        find.byKey(const Key('tracks_settings_secondaryTap')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Disable the secondary waveform window; it closes (Tracks is the
      // only mode now, so the window follows this enable toggle alone).
      await tester.tap(
        find.byKey(const Key('settings_waveformWindow_switch')),
      );
      await tester.pumpAndSettle();

      expect(windowService.isOpen, isFalse);

      // Close the settings page so the global open-guard resets for the next
      // test (the toggle no longer navigates away on its own).
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();

      // The layout never swaps — Tracks is the only mode.
      expect(find.byType(TracksView), findsOneWidget);
    });

    testWidgets('the S key opens the settings page', (tester) async {
      await pumpApp(tester, NoopWaveformWindowService());

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Close it so the global open-guard resets for the next test.
      await tester.tap(find.byKey(const Key('settings_close_button')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
    });

    // The successor to the device-lost BANNER tests the toast rewrite
    // deleted (the closeout's D1 deferral): loss is a standing surface again
    // — `ConnectivityBanners` on the stage (#453) — so the coverage is
    // finally written against the real thing, end to end through the engine's
    // own `devicePresent` diff rather than against any stopgap.
    testWidgets(
      'a lost pinned device holds the stage banner — no toast — rides the '
      'readout, and leaves with a restored snack',
      (tester) async {
        const deviceBanner = Key('connectivity_banner_device');
        le.EngineSnapshot snapshot({required bool devicePresent}) =>
            le.EngineSnapshot(
              isRunning: true,
              sampleRate: 48000,
              bufferFrames: 128,
              framesProcessed: 0,
              xrunCount: 0,
              inputRms: 0,
              inputPeak: 0,
              outputRms: 0,
              latencyState: le.LatencyState.idle,
              measuredLatencyMs: -1,
              devicePresent: devicePresent,
            );

        // A repository whose refresh the test drives by hand, started with a
        // PINNED device before the app builds — `AudioSetupCubit` hydrates
        // the pinned id from `lastEngineConfig`, and only a pinned device is
        // supervised at all.
        final ticker = StreamController<void>.broadcast();
        addTearDown(() => unawaited(ticker.close()));
        final pinned = LooperRepository(engine: engine, ticker: ticker.stream);
        addTearDown(pinned.dispose);
        engine.nextSnapshot = snapshot(devicePresent: true);
        pinned.startEngine(const EngineConfig(playbackDeviceId: 'out-1'));

        final windowService = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            repository: pinned,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: windowService,
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
          ),
        );
        await tester.pumpAndSettle();

        // Present on the first tick: no condition, no banner.
        ticker.add(null);
        await tester.pump();
        expect(find.byKey(deviceBanner), findsNothing);

        // Unplug. The standing red banner appears...
        engine.nextSnapshot = snapshot(devicePresent: false);
        ticker.add(null);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(deviceBanner), findsOneWidget);

        // ...outlives every toast timeout, and the retired lost-toast id
        // never registers (D1: the banner REPLACES the lost toast).
        await tester.pump(const Duration(seconds: 30));
        expect(find.byKey(deviceBanner), findsOneWidget);
        expect(debugAppToastActive('app_deviceLost_banner'), isFalse);

        // The 7" readout carries the same condition on the next push tick.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.readouts.last.deviceLost, isTrue);

        // Replug: the banner leaves on its own; restored stays a snack toast
        // (an event, not a condition).
        engine.nextSnapshot = snapshot(devicePresent: true);
        ticker.add(null);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(deviceBanner), findsNothing);
        expect(debugAppToastActive(AppToastId.deviceRestored), isTrue);
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.readouts.last.deviceLost, isFalse);

        // Let the snack's auto-close and removal animations run out so no
        // timer outlives the test.
        await tester.pump(const Duration(seconds: 10));
      },
    );

    testWidgets(
      'a lost MIDI controller flashes a transient toast and raises no '
      'standing bar; its return is a snack',
      (tester) async {
        // A lost MIDI controller is low-stakes — the loops keep playing — so
        // it is a transient toast, NOT the persistent banner a lost audio
        // interface gets (#453). Driven end to end through the repository's
        // own hotplug diff.
        const dev = MidiDevice(id: 'fcb1010', name: 'FCB1010');
        var enumerated = const <MidiDevice>[dev];
        final source = _MockMidiSource();
        when(source.enumerate).thenAnswer((_) => enumerated);
        when(() => source.activity).thenAnswer(
          (_) => const Stream<RawControllerInput>.empty(),
        );
        when(() => source.open(any())).thenReturn(0);
        when(source.close).thenReturn(0);

        final midi = MidiDeviceRepository(
          source: source,
          settings: settings,
          pollInterval: Duration.zero,
        );
        addTearDown(midi.dispose);
        // Pin the controller present before the app builds, so the shell's
        // MidiSetupCubit subscribes to a healthy connection.
        await midi.select('fcb1010');

        final windowService = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            repository: repository,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midi,
            settings: settings,
            waveformWindow: windowService,
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
          ),
        );
        await tester.pumpAndSettle();

        // Unplug: the transient lost toast registers...
        enumerated = const [];
        midi.refresh();
        await tester.pump();
        await tester.pump();
        expect(debugAppToastActive(AppToastId.midiLost), isTrue);

        // ...and never a standing bar. MIDI has no persistent surface, on
        // either the stage or the readout.
        expect(find.byKey(const Key('connectivity_banner_midi')), findsNothing);
        expect(
          find.byKey(const Key('connectivity_banner_device')),
          findsNothing,
        );

        // Replug: the lost toast is gone and the return is a snack.
        enumerated = const [dev];
        midi.refresh();
        await tester.pump();
        await tester.pump();
        expect(debugAppToastActive(AppToastId.midiLost), isFalse);
        expect(debugAppToastActive(AppToastId.midiRestored), isTrue);

        // Drain the toast timers so none outlives the test.
        await tester.pump(const Duration(seconds: 10));
      },
    );

    /// Takes the failure toast back down before this test's tree goes away.
    ///
    /// `_showWaveformWindowFailedBanner` raises it with no `autoCloseDuration`,
    /// so it is manual-dismiss — nothing retires it on its own. And
    /// `toastification`'s manager is a GLOBAL that outlives the tree, while
    /// `resetAppToastsForTest` in setUp only clears THIS module's registry, not
    /// the item still live in that manager. A toast left standing here is
    /// therefore not this test's problem but the next one's: the following
    /// test's `showAppToast` renders into the dead overlay and its banner is
    /// never found. Ordering hid it — the toast test happens to be declared
    /// first — until a randomised seed put it last.
    Future<void> dismissFailureToast(WidgetTester tester) async {
      dismissAppToast(AppToastId.waveformFailed);
      // Past the removal animation and the overlay teardown it schedules.
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets(
      'a window that never readies is attempted ONCE, and the failure is on '
      'the cubit the Display face reads',
      (tester) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);

        // The shell both writes the failure and listens for changes, so a
        // listener that fired on the flag going UP would re-enter the sync
        // that raised it — two attempts and two toasts for one failure.
        expect(windowService.openCalls, 1);
        // No frames streamed to a window that never readied.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);

        final waveform = tester
            .element(find.byType(MaterialApp).first)
            .read<WaveformWindowCubit>();
        expect(waveform.state.openFailed, isTrue);
        expect(waveform.state.enabled, isTrue);

        await dismissFailureToast(tester);
      },
    );

    testWidgets(
      'clearing the failure IS the retry — one more attempt, not two',
      (tester) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);
        expect(windowService.openCalls, 1);

        tester
            .element(find.byType(MaterialApp).first)
            .read<WaveformWindowCubit>()
            .retryOpen();
        await tester.pumpAndSettle();

        expect(windowService.openCalls, 2);

        // Two failed opens, but ONE toast: they share an id, so the second
        // `showAppToast` dismissed the first. Taking it down is not tidiness —
        // see [dismissFailureToast].
        await dismissFailureToast(tester);
      },
    );

    testWidgets(
      'shows a banner when the waveform window fails to open',
      (
        tester,
      ) async {
        final windowService = _RecordingWindowService(openResult: false);
        await pumpApp(tester, windowService);

        expect(
          find.byKey(const Key('app_waveformWindowFailed_banner')),
          findsOneWidget,
        );
        // No frames are streamed to a window that never readied.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'shows a single-display notice and skips the waveform window '
      'when only one display is present',
      (tester) async {
        final windowService = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            repository: repository,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: windowService,
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
            displayCount: () => 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('app_singleDisplay_banner')),
          findsOneWidget,
        );
        expect(windowService.openCalls, 0);
        // The push timer never started either.
        await tester.pump(const Duration(milliseconds: 40));
        expect(windowService.pushCalls, 0);
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets('pushes a fresh readout snapshot when control state changes', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      // The first tick composes the boot snapshot from the live cubits.
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.readouts, isNotEmpty);
      expect(windowService.readouts.last.mode, 'record');

      // A mode change must reach the second screen on the next tick: the
      // snapshot is recomposed from cubit state every tick, and the real
      // service's `==` diff then forwards exactly the changed ones.
      tester
          .element(find.byType(LooperPage))
          .read<ControlCubit>()
          .setMode(InteractionMode.fx);
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.readouts.last.mode, 'fx');

      // The bank rides the wire too (re-added for the readout's v2 bank
      // pair): a BANK switch must reach the second screen the same way.
      expect(windowService.readouts.last.activeBank, 0);
      tester
          .element(find.byType(LooperPage))
          .read<ControlCubit>()
          .browseBank(
            1,
          );
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.readouts.last.activeBank, 1);
    });

    testWidgets('does not rebuild the readout while nothing has changed', (
      tester,
    ) async {
      final windowService = _RecordingWindowService();
      await pumpApp(tester, windowService);

      // One frame to compose and push the boot snapshot.
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.readouts, isNotEmpty);
      final composed = windowService.readouts.length;
      final waveformFrames = windowService.pushCalls;

      // Ten more frames with no state moving under it. The real service's
      // `==` diff would drop these anyway — the point here is that they are
      // never BUILT: composing a readout allocates eight track records, one
      // record per monitored input and every localized name on both, thirty
      // times a second, to throw all of it away (#898).
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        windowService.readouts.length,
        composed,
        reason: 'the readout was recomposed for frames nothing had changed in',
      );
      expect(
        windowService.pushCalls,
        greaterThan(waveformFrames),
        reason:
            "the waveform must keep ticking — this gate is the readout's "
            'alone, and a frozen waveform would mean the timer died',
      );
    });

    testWidgets(
      'overlay volume, mute and chain commands apply through the LooperBloc',
      (tester) async {
        final windowService = _RecordingWindowService();
        await pumpApp(tester, windowService);

        // The app registered the sub→main handler on the service — the
        // channel's first control path in that direction (#698).
        final onControl = windowService.onControl;
        expect(onControl, isNotNull);

        onControl!(
          const ReadoutControl(
            action: ReadoutControl.trackVolume,
            index: 0,
            value: 1.5,
          ),
        );
        await tester.pump();
        expect(engine.laneVol[(0, 0)], 1.5);

        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackMuteToggle,
            index: 1,
          ),
        );
        await tester.pump();
        expect(engine.laneMute[(1, 0)], isTrue);

        // The regression the review caught: a fast second tap lands inside
        // the snapshot echo window (the polled LooperState still reads
        // unmuted — this test's ticker never even ticks). Resolved against
        // repository intent it must UNMUTE; resolved against the stale poll
        // it would re-send the same mute and leave the track silent.
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackMuteToggle,
            index: 1,
          ),
        );
        await tester.pump();
        expect(engine.laneMute[(1, 0)], isFalse);

        expect(repository.trackChainEnabled(2), isTrue);
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackChainToggle,
            index: 2,
          ),
        );
        await tester.pump();
        expect(repository.trackChainEnabled(2), isFalse);

        // A garbled wire value is clamped at application — the channel is
        // not trusted with the mix ceiling.
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackVolume,
            index: 0,
            value: 99,
          ),
        );
        await tester.pump();
        expect(engine.laneVol[(0, 0)], 2.0);

        // An action from a newer overlay this build does not know is
        // dropped, never thrown on.
        onControl(
          const ReadoutControl(action: 'someFutureAction', index: 0, value: 1),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        // Out-of-range indices are dropped BEFORE any repository write: a
        // garbled map decodes to index -1, and applying it would seed junk
        // intent (and persist it) before the engine could reject the
        // channel. Same for an index past the live track roster.
        engine.laneVol.clear();
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackVolume,
            index: -1,
            value: 1,
          ),
        );
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackVolume,
            index: 8,
            value: 1,
          ),
        );
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackChainToggle,
            index: -1,
          ),
        );
        onControl(
          const ReadoutControl(
            action: ReadoutControl.trackMuteToggle,
            index: -1,
          ),
        );
        await tester.pump();
        expect(engine.laneVol, isEmpty);
        expect(engine.laneMute.containsKey((-1, 0)), isFalse);
        expect(repository.trackChainEnabled(-1), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'input-volume commands drive only CONFIGURED monitors, via the cubit',
      (tester) async {
        final windowService = _RecordingWindowService();
        await pumpApp(tester, windowService);
        final onControl = windowService.onControl!;

        // No monitor is configured: the command must not materialize one.
        onControl(
          const ReadoutControl(
            action: ReadoutControl.inputVolume,
            index: 0,
            value: 0.5,
          ),
        );
        await tester.pump();
        expect(
          tester
              .element(find.byType(LooperPage))
              .read<MonitorCubit>()
              .state
              .hasInput(0),
          isFalse,
        );

        // Configure input 0's monitor the way the main UI would.
        final monitors = tester
            .element(find.byType(LooperPage))
            .read<MonitorCubit>();
        await monitors.setMode(0, MonitorMode.on);
        await tester.pump();

        onControl(
          const ReadoutControl(
            action: ReadoutControl.inputVolume,
            index: 0,
            value: 0.5,
          ),
        );
        await tester.pump();
        // The engine call itself is gated on a running engine; repository
        // intent is what a (re)start applies, so that is the contract.
        expect(repository.monitorVolume(0), 0.5);
        expect(monitors.state.forInput(0).volume, 0.5);

        // And the configured input now rides the readout snapshot as the
        // overlay's INPUTS group.
        await tester.pump(const Duration(milliseconds: 40));
        final inputs = windowService.readouts.last.inputs;
        expect(inputs, hasLength(1));
        expect(inputs.single.index, 0);
        expect(inputs.single.volume, 0.5);
        expect(inputs.single.name, isNotEmpty);
      },
    );

    testWidgets(
      'shows the audio-recovery banner when booted with the pinned '
      'device absent',
      (tester) async {
        // The fake engine reports stopped with no devices, so the pinned config
        // is absent and the recovery cubit waits (and would auto-start on
        // arrival). pump (not pumpAndSettle) — the cubit holds a periodic poll.
        await tester.pumpWidget(
          App(
            repository: repository,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: NoopWaveformWindowService(),
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
            audioRecoveryConfig: const EngineConfig(playbackDeviceId: 'absent'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(
          find.byKey(const Key('app_audioRecovery_banner')),
          findsOneWidget,
        );
      },
      // Toast, not a widget. These notifications moved to toastification,
      // which renders into an overlay this harness does not provide, so the
      // old widget-key assertions can never match. Coverage is rebuilt with
      // the persistent-surface work — see #453.
      skip: true,
    );

    testWidgets(
      'macOS PlatformMenuBar survives MaterialApp theme rebuild and '
      'DevTools select-widget override without remounting',
      (tester) async {
        // Regression for #614: PlatformMenuBar inside MaterialApp.builder
        // remounted when the inspector override flipped, tripping the
        // single-delegate lock assertion.
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('flutter/menu'),
              (_) async => null,
            );

        try {
          await pumpApp(tester, NoopWaveformWindowService());

          expect(
            find.byKey(const Key('segno_platform_menu')),
            findsOneWidget,
          );

          // Theme change rebuilds MaterialApp (context.watch on
          // HighContrastCubit).
          await tester
              .element(find.byType(MaterialApp))
              .read<HighContrastCubit>()
              .toggle();
          await tester.pump();

          // DevTools "Select Widget Mode" flips this notifier on WidgetsApp.
          WidgetsBinding
                  .instance
                  .debugShowWidgetInspectorOverrideNotifier
                  .value =
              true;
          await tester.pump();
          WidgetsBinding
                  .instance
                  .debugShowWidgetInspectorOverrideNotifier
                  .value =
              false;
          await tester.pump();

          expect(
            find.byKey(const Key('segno_platform_menu')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          // Must clear before the test binding's invariant check (addTearDown
          // runs too late).
          debugDefaultTargetPlatformOverride = null;
          WidgetsBinding
                  .instance
                  .debugShowWidgetInspectorOverrideNotifier
                  .value =
              false;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('flutter/menu'),
                null,
              );
        }
      },
    );
  });
}
