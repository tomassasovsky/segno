import 'dart:async';
import 'dart:io';

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
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/app.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/view/updates_settings_section.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:segno_engine/segno_engine.dart'
    as le
    show
        AudioDevice,
        EngineSnapshot,
        LaneSnapshot,
        LatencyState,
        TrackSnapshot,
        TrackState;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

/// A supported update backend advertising v0.2.0 (current is v0.1.0), so the
/// app's startup availability check surfaces the update toast.
class _FakeUpdateBackend implements PlatformUpdateBackend {
  @override
  bool get isSupported => true;
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
  bool failClose = false;
  int pushCalls = 0;
  bool _open = false;

  /// Every readout the app handed to the service.
  ///
  /// Deliberately records EVERY call rather than mirroring the real service's
  /// change-diff: a double that reimplements the logic under test proves
  /// nothing about it.
  final readouts = <PerformanceReadout>[];
  final deliveredReadouts = <PerformanceReadout>[];
  int failNextReadoutPushes = 0;
  Duration readoutFailDelay = Duration.zero;

  @override
  void Function()? onWindowReady;

  @override
  Future<void> pushReadout(PerformanceReadout readout) async {
    readouts.add(readout);
    if (failNextReadoutPushes > 0) {
      failNextReadoutPushes--;
      if (readoutFailDelay > Duration.zero) {
        await Future<void>.delayed(readoutFailDelay);
      }
      throw const _WindowGone();
    }
    deliveredReadouts.add(readout);
  }

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
    if (failClose) {
      throw StateError('window enumeration failed during disposal');
    }
  }

  /// Every waveform frame delivered, including a copy of its selected audio.
  final waveforms = <WaveformFrame>[];

  /// How many of the next waveform pushes are lost in flight. The real
  /// service reports that by completing the future with an error.
  int failNextWaveformPushes = 0;

  /// How long a failing push takes to REPORT its failure — a channel
  /// round-trip that rejects several polls late.
  Duration failDelay = Duration.zero;

  @override
  Future<void> pushWaveform(
    Float32List samples,
    double progress,
    String selectedTrack,
  ) async {
    pushCalls++;
    if (failNextWaveformPushes > 0) {
      failNextWaveformPushes--;
      if (failDelay > Duration.zero) await Future<void>.delayed(failDelay);
      throw const _WindowGone();
    }
    waveforms.add((
      samples: Float32List.fromList(samples),
      progress: progress,
      selectedTrack: selectedTrack,
    ));
  }
}

/// What a push into a window that is not there looks like.
class _WindowGone implements Exception {
  const _WindowGone();
}

/// A MIDI source whose enumeration the test drives by hand, so a pinned
/// controller can be made to vanish and return through `refresh()`.
class _MockMidiSource extends Mock implements MidiControllerSource {}

class _TrackFxStore extends FakeKeyValueStore {
  final releaseWrite = Completer<void>();
  bool writeEntered = false;
  bool refuseWrite = false;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'track_fx_chain.0') {
      writeEntered = true;
      await releaseWrite.future;
      if (refuseWrite) {
        throw StateError('FX storage unavailable during disposal');
      }
    }
    await super.setString(key, value);
  }
}

class _ClickStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;

  @override
  Future<void> setDouble(String key, double value) async {
    if (key == 'tempo.click_volume') {
      writeEntered = true;
      await pendingWrite?.future;
    }
    await super.setDouble(key, value);
    if (key == 'tempo.click_volume' && refuseWrite) {
      throw StateError('Click write failed after mutation');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (key == 'tempo.click_volume' && refuseWrite) {
      throw StateError('Click compensation unavailable');
    }
    await super.remove(key);
  }
}

class _RecordStartStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  String blockedKey = 'looper.auto_record';
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseNextRead = false;

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.count_in_bars' && refuseNextRead) {
      refuseNextRead = false;
      throw StateError('Recording start temporarily unreadable');
    }
    return super.getInt(key);
  }

  Future<void> _beforeWrite(String key) async {
    if (key == blockedKey) {
      writeEntered = true;
      await pendingWrite?.future;
    }
  }

  void _afterWrite(String key) {
    if (key == blockedKey && refuseWrite) {
      throw StateError('Recording start write failed after mutation');
    }
  }

  @override
  Future<void> setInt(String key, int value) async {
    await _beforeWrite(key);
    await super.setInt(key, value);
    _afterWrite(key);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await _beforeWrite(key);
    await super.setBool(key, value: value);
    _afterWrite(key);
  }

  @override
  Future<void> remove(String key) async {
    if ((key == 'tempo.count_in_bars' || key == 'looper.auto_record') &&
        refuseWrite) {
      throw StateError('Recording start compensation unavailable');
    }
    await super.remove(key);
  }
}

class _MonitorRestoreStore extends FakeKeyValueStore {
  bool refuseRead = true;
  bool refuseBootWrite = false;
  Completer<void>? readGate;

  @override
  Future<void> setString(String key, String value) async {
    if (refuseBootWrite && key == 'monitor_input_mode.0') {
      throw StateError('monitor boot image unavailable');
    }
    await super.setString(key, value);
  }

  @override
  Future<String?> getString(String key) async {
    if (key == 'monitor_input_mode.0') await readGate?.future;
    if (refuseRead && key == 'monitor_input_mode.0') {
      throw StateError('saved monitor temporarily unreadable');
    }
    return super.getString(key);
  }
}

class _NoticeSessionRepository extends SessionRepository {
  _NoticeSessionRepository() : super(engine: FakeAudioEngine());

  final readEntered = Completer<void>();
  final readRelease = Completer<void>();
  bool refuseRead = false;

  @override
  Future<String> bundlePath(String name) async => name;

  @override
  Future<List<SessionSummary>> listSessions() async => const [
    SessionSummary(name: 'Replacement'),
  ];

  @override
  Future<SessionBundle> read(String directory) async {
    if (!readEntered.isCompleted) readEntered.complete();
    await readRelease.future;
    if (refuseRead) throw StateError('session read unavailable');
    return (
      session: const Session(
        sampleRate: 48000,
        channels: 2,
        baseLengthFrames: 0,
        tracks: [],
        monitors: [
          SessionMonitor(
            input: 0,
            mode: 'on',
            outputMask: 16,
            volume: .65,
            muted: true,
            encoded: '',
          ),
        ],
      ),
      laneStems: <(int, int), List<Float32List>>{},
    );
  }
}

class _ClickModeStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseNextRead = false;

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.click_mode' && refuseNextRead) {
      refuseNextRead = false;
      throw StateError('Hear click temporarily unreadable');
    }
    return super.getInt(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'tempo.click_mode') {
      writeEntered = true;
      await pendingWrite?.future;
    }
    await super.setInt(key, value);
    if (key == 'tempo.click_mode' && refuseWrite) {
      throw StateError('Hear click write failed after mutation');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (key == 'tempo.click_mode' && refuseWrite) {
      throw StateError('Hear click compensation unavailable');
    }
    await super.remove(key);
  }
}

class _RefusingClickModeEngine extends FakeAudioEngine {
  bool refuseMode = false;

  @override
  EngineResult setClickMode(ClickMode mode) =>
      refuseMode ? EngineResult.invalid : super.setClickMode(mode);
}

class _DecayStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseCompensation = true;

  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'looper.overdub_decay' ||
        key.startsWith('track_overdub_decay.')) {
      writeEntered = true;
      await pendingWrite?.future;
      await super.setInt(key, value);
      if (refuseWrite) throw StateError('Decay write failed after mutation');
      return;
    }
    await super.setInt(key, value);
  }

  @override
  Future<void> remove(String key) async {
    if ((key == 'looper.overdub_decay' ||
            key.startsWith('track_overdub_decay.')) &&
        refuseWrite &&
        refuseCompensation) {
      throw StateError('Decay compensation unavailable');
    }
    await super.remove(key);
  }
}

class _OneShotStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseCompensation = true;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == 'looper.default_one_shot' || key.startsWith('track_one_shot.')) {
      writeEntered = true;
      await pendingWrite?.future;
      await super.setBool(key, value: value);
      if (refuseWrite) {
        throw StateError('Playback write failed after mutation');
      }
      return;
    }
    await super.setBool(key, value: value);
  }

  @override
  Future<void> remove(String key) async {
    if ((key == 'looper.default_one_shot' ||
            key.startsWith('track_one_shot.')) &&
        refuseWrite &&
        refuseCompensation) {
      throw StateError('Playback compensation unavailable');
    }
    await super.remove(key);
  }
}

class _LengthStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseNextRead = false;

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.length_preset.7' && refuseNextRead) {
      refuseNextRead = false;
      throw StateError('Record length preference temporarily unavailable');
    }
    return super.getInt(key);
  }

  bool refuseCompensation = true;

  static bool _isLength(String key) =>
      key == 'looper.default_length_bars' ||
      key.startsWith('tempo.length_preset.');

  @override
  Future<void> setInt(String key, int value) async {
    if (_isLength(key)) {
      writeEntered = true;
      await pendingWrite?.future;
      await super.setInt(key, value);
      if (refuseWrite) {
        throw StateError('Record length write failed after mutation');
      }
      return;
    }
    await super.setInt(key, value);
  }

  @override
  Future<void> remove(String key) async {
    if (_isLength(key) && refuseWrite && refuseCompensation) {
      throw StateError('Record length compensation unavailable');
    }
    await super.remove(key);
  }
}

class _TimingStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;
  bool refuseNextRead = false;

  bool _isTiming(String key) =>
      key == 'looper.quantize' ||
      key == 'tempo.quantize_div' ||
      key.startsWith('track_record_timing.');

  @override
  Future<int?> getInt(String key) async {
    if (key == 'track_record_timing.7' && refuseNextRead) {
      refuseNextRead = false;
      throw StateError('Record timing preference temporarily unavailable');
    }
    return super.getInt(key);
  }

  Future<void> _beforeWrite(String key) async {
    if (_isTiming(key)) {
      writeEntered = true;
      await pendingWrite?.future;
    }
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await _beforeWrite(key);
    await super.setBool(key, value: value);
    if (_isTiming(key) && refuseWrite) {
      throw StateError('Record timing write failed after mutation');
    }
  }

  @override
  Future<void> setInt(String key, int value) async {
    await _beforeWrite(key);
    await super.setInt(key, value);
    if (_isTiming(key) && refuseWrite) {
      throw StateError('Record timing write failed after mutation');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (_isTiming(key) && refuseWrite) {
      throw StateError('Record timing compensation unavailable');
    }
    await super.remove(key);
  }
}

class _PowerKey implements PowerKeySource {
  final _presses = StreamController<void>.broadcast();

  @override
  Stream<void> get presses => _presses.stream;

  void press() => _presses.add(null);

  @override
  Future<void> close() => _presses.close();
}

class _ShutdownMidi extends MidiDeviceRepository {
  _ShutdownMidi(SettingsRepository settings)
    : super(source: null, settings: settings, pollInterval: Duration.zero);

  final _inputs = StreamController<MidiInputMessage>.broadcast();

  @override
  MidiInputSession get session => const MidiInputSession('shutdown-test', 1);

  @override
  Stream<MidiInputMessage> get messages => _inputs.stream;

  void push(int value) => _inputs.add(
    MidiInputMessage(
      session,
      RawControllerInput(
        kind: ControllerSourceKind.midiCc,
        id: 21,
        value: value,
      ),
    ),
  );

  @override
  Future<void> dispose() async {
    await _inputs.close();
    await super.dispose();
  }
}

class _RefusingTimingEngine extends FakeAudioEngine {
  bool refuseTiming = false;

  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) => refuseTiming
      ? EngineResult.notReady
      : super.setRecordTimingSettings(
          defaultTiming: defaultTiming,
          rememberedDivision: rememberedDivision,
          trackOverrides: trackOverrides,
          editMask: editMask,
        );
}

/// Distinct track and mixed-output shapes expose a wrong waveform source.
class _WaveformAudioEngine extends FakeAudioEngine {
  final trackSamples = <int, Float32List>{};
  final mixedSamples = Float32List.fromList([0.9, 0.8, 0.7]);

  @override
  Float32List readVisual() => mixedSamples;

  @override
  Float32List readTrackVisual(int channel) {
    trackVisualReads++;
    return trackSamples[channel] ?? Float32List(0);
  }
}

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
      WaveformWindowService windowService, {
      Future<void> Function()? powerOff,
      PowerKeySource? powerKeySource,
      Duration waveformWindowOpenDelay = Duration.zero,
      bool settle = true,
    }) async {
      await tester.pumpWidget(
        App(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: windowService,
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
          powerOff: powerOff,
          powerKeySource: powerKeySource,
          waveformWindowOpenDelay: waveformWindowOpenDelay,
        ),
      );
      if (settle) await tester.pumpAndSettle();
    }

    Future<void> pumpAppWithUpdates(
      WidgetTester tester,
      UpdateRepository updates,
    ) async {
      await tester.pumpWidget(
        App(
          mixSettings: testMixSettings(repository, settings: settings),
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

    testWidgets('disposal logs a window close failure and retires delivery', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final directory = Directory.systemTemp.createTempSync('segno-window-');
        AppLog.close();
        addTearDown(() {
          AppLog.close();
          directory.deleteSync(recursive: true);
        });
        await AppLog.init(directory: directory);
        final window = _RecordingWindowService();
        await pumpApp(tester, window);
        expect(window.openCalls, 1);
        final context = tester.element(find.byType(TracksView));
        final control = context.read<ControlCubit>();
        final looper = context.read<LooperBloc>();
        window.failClose = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpEventQueue();
        expect(window.closeCalls, 1);
        expect(window.onWindowReady, isNull);
        expect(control.isClosed, isTrue);
        expect(looper.isClosed, isTrue);
        expect(tester.takeException(), isNull);
        final log = File(
          '${directory.path}/${AppLog.fileName}',
        ).readAsStringSync();
        expect(
          'waveform display teardown failed'.allMatches(log),
          hasLength(1),
        );
        expect(log, contains('window enumeration failed during disposal'));
        expect(log, contains('_RecordingWindowService.close'));
      });
    });

    testWidgets('disposal logs FX persistence failure after closing owners', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final logDirectory = Directory.systemTemp.createTempSync(
          'segno-dispose-',
        );
        AppLog.close();
        addTearDown(() {
          AppLog.close();
          logDirectory.deleteSync(recursive: true);
        });
        await AppLog.init(directory: logDirectory);
        final store = _TrackFxStore()..refuseWrite = true;
        // Stream cancellation uses a cached real-zone future in this SDK, so
        // the complete disposal journey stays inside runAsync.
        final settings = SettingsRepository(store: store);
        final engine = FakeAudioEngine();
        final repository = LooperRepository(
          engine: engine,
          ticker: const Stream<void>.empty(),
        );
        final controllers = ControllerRepository(sources: const []);
        final midi = MidiDeviceRepository(source: null, settings: settings);
        final performance = PerformanceRepository(
          engine: engine,
          exportsRoot: () async => '.',
        );
        addTearDown(() => unawaited(repository.dispose()));
        addTearDown(() => unawaited(controllers.dispose()));
        addTearDown(() => unawaited(midi.dispose()));
        addTearDown(performance.dispose);
        await tester.pumpWidget(
          App(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            controllerRepository: controllers,
            midiDeviceRepository: midi,
            settings: settings,
            waveformWindow: NoopWaveformWindowService(),
            sessionRepository: SessionRepository(engine: engine),
            performanceRepository: performance,
            exportDirectory: () async => '.',
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(TracksView));
        final looper = context.read<LooperBloc>();
        final control = context.read<ControlCubit>();
        final power = context.read<PowerOffCubit>();
        final closed = <String>{};
        context.read<TempoSettings>().stream.listen(
          (_) {},
          onDone: () => closed.add('tempo'),
        );
        context.read<RecordSettings>().stream.listen(
          (_) {},
          onDone: () => closed.add('record'),
        );
        context.read<RecordTimingSettings>().stream.listen(
          (_) {},
          onDone: () => closed.add('timing'),
        );
        repository.setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
        looper.add(
          const LooperBusEffectParamChanged(
            FxAddress(stage: FxStage.track),
            0,
            1,
            .65,
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(store.writeEntered, isTrue);
        expect(closed, isEmpty);
        store.releaseWrite.complete();
        await pumpEventQueue();
        await tester.pumpAndSettle();
        expect(closed, {'tempo', 'record', 'timing'});
        expect(looper.isClosed, isTrue);
        expect(control.isClosed, isTrue);
        expect(power.isClosed, isTrue);
        expect(tester.takeException(), isNull);
        final log = File(
          '${logDirectory.path}/${AppLog.fileName}',
        ).readAsStringSync();
        expect('application teardown failed'.allMatches(log), hasLength(1));
        expect(log, contains('FX storage unavailable during disposal'));
        expect(log, contains('_TrackFxStore.setString'));
      });
    });

    testWidgets('shutdown flushes the track editor before its debounce', (
      tester,
    ) async {
      final store = _TrackFxStore();
      settings = SettingsRepository(store: store);
      String? savedAtHalt;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async {
          savedAtHalt = await settings.loadTrackFxChain(0);
        },
      );
      final tracksContext = tester.element(find.byType(TracksView));
      final shellContext = tester.element(find.byType(LooperPage));
      final looper = tracksContext.read<LooperBloc>();
      expect(repository.onLaneChainChanged, isNotNull);
      repository.setTrackEffects(
        channel: 0,
        effects: [BuiltInEffect(type: TrackEffectType.delay)],
      );
      looper.add(
        const LooperBusEffectParamChanged(
          FxAddress(stage: FxStage.track),
          0,
          1,
          0.65,
        ),
      );
      await tester.pump();
      expect(await settings.loadTrackFxChain(0), isNull);
      final power = tracksContext.read<PowerOffCubit>()
        ..press(const PowerOffSnapshot());
      await tester.pump();
      // No virtual time has elapsed: shutdown, not the debounce timer,
      // must begin the edit's persistence and await it before goodbye.
      expect(store.writeEntered, isTrue);
      expect(power.state.phase, PowerOffPhase.flushing);
      expect(await settings.loadTrackFxChain(0), isNull);
      store.releaseWrite.complete();
      await tester.pump();
      final saved = await settings.loadTrackFxChain(0);
      expect(saved, isNotNull);
      expect(identical(looper, shellContext.read<LooperBloc>()), isTrue);
      expect(
        (decodeFxChain(saved).entries.single as BuiltInEffect).params[1],
        0.65,
      );
      expect(power.state.isUiUp, isTrue);
      looper
        ..add(const LooperRecordPressed(0))
        ..add(const LooperClearPressed(0));
      await tester.pump();
      expect(engine.recordCalls, 0);
      expect(engine.clearCalls, 0);
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      await tester.pump(const Duration(seconds: 3));
      expect(savedAtHalt, saved);
    });

    for (final recovery in ['Retry', 'Session', 'Power']) {
      testWidgets(
        'Fade startup notice resolves through $recovery',
        (tester) async {
          final store = FakeKeyValueStore()
            ..values['looper.fade_durations'] =
                '{"defaultMs":501,"overrides":{}}';
          settings = SettingsRepository(store: store);
          final bundles = _NoticeSessionRepository();
          sessionRepository = bundles;
          var halted = false;
          await pumpApp(
            tester,
            NoopWaveformWindowService(),
            powerOff: () async => halted = true,
          );
          expect(find.text('Fade duration needs recovery'), findsOneWidget);
          if (recovery == 'Session') {
            final context = tester.element(find.byType(TracksView));
            bundles.readRelease.complete();
            final loading = context.read<SessionCubit>().loadNamed(
              'Replacement',
            );
            await tester.pumpAndSettle();
            await loading;
            expect(
              context.read<SessionCubit>().state.outcome,
              SessionOutcome.loaded,
            );
          } else if (recovery == 'Power') {
            final context = tester.element(find.byType(TracksView));
            final power = context.read<PowerOffCubit>()
              ..press(const PowerOffSnapshot());
            await tester.pumpAndSettle();
            expect(halted, isFalse);
            store.values.remove('looper.fade_durations');
            power.retryPowerOff(const PowerOffSnapshot());
            await tester.pumpAndSettle();
            await tester.pump(const Duration(seconds: 6));
            expect(halted, isTrue);
          } else {
            store.values.remove('looper.fade_durations');
            await tester.tap(
              find.descendant(
                of: find.byKey(const Key(AppToastId.fadeSettings)),
                matching: find.text('Retry'),
              ),
            );
            await tester.pumpAndSettle();
          }
          expect(find.text('Fade duration needs recovery'), findsNothing);
          expect(debugAppToastActive(AppToastId.fadeSettings), isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(debugAppToastActive(AppToastId.fadeSettings), isFalse);
        },
      );
    }

    testWidgets('power off waits for an ordinary Click preference', (
      tester,
    ) async {
      final store = _ClickStore();
      settings = SettingsRepository(store: store);
      var halted = false;
      final window = _RecordingWindowService();
      await pumpApp(tester, window, powerOff: () async => halted = true);
      final context = tester.element(find.byType(TracksView));
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      store.pendingWrite = Completer<void>();
      unawaited(tempo.setClickVolume(1.5));
      await tester.pump();
      expect(store.writeEntered, isTrue);
      power.press(const PowerOffSnapshot());
      await tester.pump(const Duration(milliseconds: 100));
      expect(power.state.phase, PowerOffPhase.flushing);
      expect(halted, isFalse);
      store.pendingWrite!.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(halted, isTrue);
      expect(store.values['tempo.click_volume'], 1.5);
      expect(tempo.state.confirmedClickVolume, 1.5);
    });

    testWidgets('Click refusal prevents halt and visible Retry recovers', (
      tester,
    ) async {
      final store = _ClickStore();
      settings = SettingsRepository(store: store);
      var halted = false;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => halted = true,
      );
      final context = tester.element(find.byType(TracksView));
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      store.refuseWrite = true;
      unawaited(tempo.setClickVolume(1.5));
      await tester.pump();
      // The owed rollback makes Click unavailable until Retry.
      expect(tempo.state.confirmedClickVolume, isNull);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.flushFailed);
      expect(find.text('Settings could not be confirmed'), findsOneWidget);
      expect(find.byKey(const Key('power_off_retry')), findsOneWidget);
      expect(find.byKey(const Key('power_off_discard')), findsNothing);
      expect(halted, isFalse);
      store.refuseWrite = false;
      await tester.tap(find.byKey(const Key('power_off_retry')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(halted, isTrue);
      expect(store.values.containsKey('tempo.click_volume'), isFalse);
    });

    testWidgets('power off retires held Click before refusing later MIDI', (
      tester,
    ) async {
      final store = _ClickStore();
      settings = SettingsRepository(store: store);
      final midi = _ShutdownMidi(settings);
      midiDeviceRepository = midi;
      addTearDown(() => unawaited(midi.dispose()));
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      final context = tester.element(find.byType(TracksView));
      final control = context.read<ControlCubit>();
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      final editor = Object();
      control.beginMidiEdit(device: 'shutdown-test', owner: editor);
      MidiSaveResult? saved;
      unawaited(
        control
            .saveMidiMapping(
              MidiMapping(
                id: 'shutdown-click',
                source: MidiSource(
                  device: 'shutdown-test',
                  kind: ControllerSourceKind.midiCc,
                  number: 21,
                ),
                behavior: MidiBehavior.momentary,
                controls: [
                  MidiParameterControl(
                    key: '{"ctl":"clickVolume"}',
                    low: .125,
                    high: .75,
                  ),
                ],
              ),
              owner: editor,
              create: true,
            )
            .then((result) => saved = result),
      );
      await tester.pumpAndSettle();
      expect(saved?.saved, isTrue);
      control.endMidiEdit(editor);
      midi.push(127);
      await tester.pumpAndSettle();
      expect(tempo.state.confirmedClickVolume, 1.5);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      expect(tempo.state.confirmedClickVolume, .25);
      expect(store.values['tempo.click_volume'], .25);
      expect(haltCalls, 0);

      // A new controller event after the final flush must not start a save.
      store
        ..writeEntered = false
        ..pendingWrite = Completer<void>();
      midi.push(127);
      await tester.pump();
      expect(store.writeEntered, isFalse);
      expect(tempo.state.confirmedClickVolume, .25);
      store.pendingWrite!.complete();
      await tester.pump(const Duration(seconds: 2));
      expect(haltCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    for (final failedRestore in [false, true]) {
      testWidgets('Foot Mixer live input gain; failed restore=$failedRestore', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        settings = SettingsRepository(
          store: _MonitorRestoreStore()..refuseRead = failedRestore,
        );
        engine.nextSnapshot = engine.nextSnapshot.copyWith(inputChannels: 2);
        repository.startEngine(const EngineConfig());
        await pumpApp(tester, NoopWaveformWindowService());
        final context = tester.element(find.byType(TracksView));
        final monitor = context.read<MonitorCubit>();
        final control = context.read<ControlCubit>()
          ..setMode(InteractionMode.mixer)
          ..selectFootMixerDomain(FootMixerDomain.inputs);
        await tester.pumpAndSettle();
        final gain = find.byKey(const Key('foot_mixer_selected_gain'));
        expect(tester.widget<AppText>(gain).data, '100%');
        await tester.tap(find.byKey(const Key('foot_mixer_pedal_undo')));
        await tester.pumpAndSettle();
        expect(repository.monitorVolume(0), closeTo(.95, 1e-9));
        expect(tester.widget<AppText>(gain).data, '95%');
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const Key('foot_mixer_gain_bar')),
              )
              .value,
          closeTo(.95, 1e-9),
        );
        // External/MIDI controllers share this exact transaction owner.
        await context.read<MixSettingsCoordinator>().setControllerValues({
          const MonitorVolumeTarget(0): .4,
        });
        await tester.pumpAndSettle();
        expect(tester.widget<AppText>(gain).data, '40%');
        expect(repository.monitorVolume(0), .4);
        await context.read<MixSettingsCoordinator>().setControllerValues({
          const MonitorVolumeTarget(0): .98,
        });
        await tester.pumpAndSettle();
        expect(tester.widget<AppText>(gain).data, '98%');
        expect(find.text('Limit · Hold reset'), findsOneWidget);
        await tester.tap(find.byKey(const Key('foot_mixer_pedal_clear')));
        await tester.pumpAndSettle();
        expect(repository.monitorVolume(0), .98);
        expect(tester.widget<AppText>(gain).data, '98%');
        expect(control.state.footMixer.domain, FootMixerDomain.inputs);
        expect(monitor.state.restoreFailed, failedRestore);
        if (failedRestore) expect(monitor.state.inputs, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      });
    }

    testWidgets(
      'Foot Mixer mute caption follows admitted input after failed restore',
      (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        settings = SettingsRepository(store: _MonitorRestoreStore());
        engine.nextSnapshot = engine.nextSnapshot.copyWith(inputChannels: 2);
        repository.startEngine(const EngineConfig());
        await pumpApp(tester, NoopWaveformWindowService());
        final context = tester.element(find.byType(TracksView));
        final monitor = context.read<MonitorCubit>();
        context.read<ControlCubit>()
          ..setMode(InteractionMode.mixer)
          ..selectFootMixerDomain(FootMixerDomain.inputs);
        await tester.pumpAndSettle();
        final pedal = find.byKey(const Key('foot_mixer_pedal_track1'));
        final hold = await tester.startGesture(tester.getCenter(pedal));
        await tester.pump(const Duration(milliseconds: 801));
        await hold.up();
        await tester.pumpAndSettle();
        expect(repository.monitorMuted(0), isTrue);
        expect(await settings.loadMonitorMute(0), isTrue);
        expect(monitor.state.restoreFailed, isTrue);
        expect(monitor.state.inputs, isEmpty);
        expect(
          find.descendant(of: pedal, matching: find.text('Hold · Unmute')),
          findsOneWidget,
        );
        expect(find.text('100% · Muted'), findsOneWidget);
        final unmute = await tester.startGesture(tester.getCenter(pedal));
        await tester.pump(const Duration(milliseconds: 801));
        await unmute.up();
        await tester.pumpAndSettle();
        expect(repository.monitorMuted(0), isFalse);
        expect(
          find.descendant(of: pedal, matching: find.text('Hold · Mute')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    for (final cancelLoad in [false, true]) {
      testWidgets(
        'monitor notice yields during Session load; cancel=$cancelLoad',
        (
          tester,
        ) async {
          final store = _MonitorRestoreStore()
            ..refuseRead = false
            ..readGate = Completer<void>();
          settings = SettingsRepository(store: store);
          await settings.saveMonitorInputMode(0, mode: 'on');
          await settings.saveMonitorOutput(0, 8);
          final bundles = _NoticeSessionRepository()..refuseRead = cancelLoad;
          sessionRepository = bundles;
          addTearDown(() {
            if (!bundles.readRelease.isCompleted) {
              bundles.readRelease.complete();
            }
          });
          repository.startEngine(const EngineConfig());
          await pumpApp(tester, NoopWaveformWindowService());
          final context = tester.element(find.byType(TracksView));
          final monitor = context.read<MonitorCubit>();
          final session = context.read<SessionCubit>();
          final load = session.loadNamed('Replacement');
          expect(
            context.read<FxChainPersistence>().sessionTransitionActive,
            isTrue,
          );
          store.readGate!.complete();
          await bundles.readEntered.future;
          await tester.pumpAndSettle();
          expect(monitor.state.restoreFailed, isTrue);
          expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
          expect(find.text('Input monitoring needs recovery'), findsNothing);
          bundles.readRelease.complete();
          await load;
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('tracks_session_snackbar')),
            findsOneWidget,
          );
          if (cancelLoad) {
            expect(session.state.status, SessionStatus.failure);
            expect(monitor.state.restoreFailed, isTrue);
            final retry = find
                .descendant(
                  of: find.byKey(const Key(AppToastId.monitorRestore)),
                  matching: find.text('Retry'),
                )
                .hitTestable();
            expect(retry, findsOneWidget);
            await tester.tap(retry);
            await tester.pumpAndSettle();
            expect(monitor.state.forInput(0).outputMask, 8);
          } else {
            expect(session.state.outcome, SessionOutcome.loaded);
            expect(monitor.state.forInput(0).outputMask, 16);
            expect(monitor.state.forInput(0).volume, .65);
          }
          expect(monitor.state.restoreFailed, isFalse);
          expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    testWidgets('monitor notice yields to actionable Session boot Retry', (
      tester,
    ) async {
      final store = _MonitorRestoreStore();
      settings = SettingsRepository(store: store);
      final bundles = _NoticeSessionRepository();
      bundles.readRelease.complete();
      sessionRepository = bundles;
      repository.startEngine(const EngineConfig());
      await pumpApp(tester, NoopWaveformWindowService());
      final context = tester.element(find.byType(TracksView));
      final monitor = context.read<MonitorCubit>();
      final session = context.read<SessionCubit>();
      expect(debugAppToastActive(AppToastId.monitorRestore), isTrue);
      store
        ..refuseRead = false
        ..refuseBootWrite = true;
      await tester.tap(find.byKey(const Key('stage_library')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
      // Catalog refresh is unrelated work; it must not suppress Monitor Retry.
      expect(debugAppToastActive(AppToastId.monitorRestore), isTrue);
      await tester.tap(find.text('Replacement'));
      await tester.pumpAndSettle();
      expect(session.state.bootRecoveryRequired, isTrue);
      expect(session.state.error, SessionError.bootPersistence);
      expect(engine.snapshot().isRunning, isFalse);
      expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
      expect(monitor.state.inputs, isEmpty);
      expect(debugAppToastActive(AppToastId.sessionBootRecovery), isTrue);
      expect(find.byKey(const Key('tracks_session_snackbar')), findsNothing);
      final retry = find
          .descendant(
            of: find.byKey(const Key(AppToastId.sessionBootRecovery)),
            matching: find.text('Retry'),
          )
          .hitTestable();
      expect(retry, findsOneWidget);
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      final power = context.read<PowerOffCubit>()
        ..press(const PowerOffSnapshot(anyHasContent: true));
      await tester.pumpAndSettle();
      expect(debugAppToastActive(AppToastId.sessionBootRecovery), isFalse);
      expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
      power.keepPlaying();
      await tester.pumpAndSettle();
      expect(retry, findsOneWidget);
      expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(session.state.bootRecoveryRequired, isTrue);
      expect(monitor.state.inputs, isEmpty);
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
      expect(find.byKey(const Key('tracks_session_snackbar')), findsNothing);
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      store.refuseBootWrite = false;
      await tester.tap(find.text('Retry').hitTestable());
      await tester.pumpAndSettle();
      expect(session.state.bootRecoveryRequired, isFalse);
      expect(session.state.outcome, SessionOutcome.loaded);
      expect(monitor.state.restoreFailed, isFalse);
      expect(monitor.state.forInput(0).outputMask, 16);
      expect(monitor.state.forInput(0).volume, .65);
      expect(await settings.loadMonitorOutput(0), 16);
      expect(debugAppToastActive(AppToastId.sessionBootRecovery), isFalse);
      expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
      expect(find.text('Retry').hitTestable(), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('initial monitor restore failure exposes persistent Retry', (
      tester,
    ) async {
      final store = _MonitorRestoreStore();
      settings = SettingsRepository(store: store);
      await settings.saveMonitorInputMode(0, mode: 'on');
      await settings.saveMonitorOutput(0, 8);
      await settings.saveMonitorVolume(0, .35);
      await settings.saveMonitorMute(0, muted: true);
      await pumpApp(tester, NoopWaveformWindowService());
      final monitor = tester
          .element(find.byType(TracksView))
          .read<MonitorCubit>();
      expect(monitor.state.restoreFailed, isTrue);
      expect(find.text('Input monitoring needs recovery'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(monitor.state.restoreFailed, isTrue);
      expect(find.text('Retry'), findsOneWidget);
      store.refuseRead = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(monitor.state.restoreFailed, isFalse);
      expect(monitor.state.forInput(0).mode, MonitorMode.on);
      expect(monitor.state.forInput(0).outputMask, 8);
      expect(find.text('Input monitoring needs recovery'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });

    for (final projectBeforeFrame in [false, true]) {
      testWidgets(
        'idle monitor failure requests frame; projected=$projectBeforeFrame',
        (
          tester,
        ) async {
          final gate = Completer<void>();
          final store = _MonitorRestoreStore()..readGate = gate;
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final monitor = tester
              .element(find.byType(TracksView))
              .read<MonitorCubit>();
          expect(tester.binding.hasScheduledFrame, isFalse);
          final failed = monitor.stream.firstWhere(
            (state) => state.restoreFailed,
          );
          gate.complete();
          await failed;
          // Drain stream listeners without pumping a frame: failure itself must
          // request one, rather than depending on another player interaction.
          await Future<void>.value();
          expect(tester.binding.hasScheduledFrame, isTrue);
          if (projectBeforeFrame) monitor.projectFromRepository();
          await tester.pumpAndSettle();
          expect(
            find.text('Input monitoring needs recovery'),
            projectBeforeFrame ? findsNothing : findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    testWidgets(
      'Session projection retires monitor recovery across Power overlay',
      (
        tester,
      ) async {
        final store = _MonitorRestoreStore();
        settings = SettingsRepository(store: store);
        await pumpApp(tester, NoopWaveformWindowService());
        final monitor = tester
            .element(find.byType(TracksView))
            .read<MonitorCubit>();
        expect(debugAppToastActive(AppToastId.monitorRestore), isTrue);
        final power =
            tester.element(find.byType(TracksView)).read<PowerOffCubit>()
              ..press(const PowerOffSnapshot(anyHasContent: true));
        await tester.pumpAndSettle();
        expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
        power.keepPlaying();
        await tester.pumpAndSettle();
        expect(debugAppToastActive(AppToastId.monitorRestore), isTrue);
        power.press(const PowerOffSnapshot(anyHasContent: true));
        await tester.pumpAndSettle();
        monitor.projectFromRepository();
        await tester.pumpAndSettle();
        power.keepPlaying();
        await tester.pumpAndSettle();
        expect(debugAppToastActive(AppToastId.monitorRestore), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    for (final malformed in [false, true]) {
      testWidgets(
        'Record length startup recovery stays reachable; malformed=$malformed',
        (tester) async {
          final store = _LengthStore()..refuseNextRead = !malformed;
          store.values.addAll({
            'looper.mode': LooperMode.free.code,
            'looper.default_length_bars': 4,
            'tempo.length_preset.7': malformed ? 65 : 0,
          });
          final before = Map<String, Object>.of(store.values);
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final context = tester.element(find.byType(TracksView));
          final length = context.read<RecordOptionsCubit>();
          expect(length.state.options.recordLengthReady, isFalse);
          expect(find.text('Record length needs recovery'), findsOneWidget);
          await tester.pump(const Duration(seconds: 6));
          expect(find.text('Record length needs recovery'), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(length.state.options.recordLengthReady, isTrue);
          expect(find.text('Record length needs recovery'), findsNothing);
          if (malformed) {
            // Retry removes only the unreadable key, then restores the rest.
            expect(
              store.values.containsKey('tempo.length_preset.7'),
              isFalse,
            );
            before.remove('tempo.length_preset.7');
            for (final entry in before.entries) {
              expect(store.values[entry.key], entry.value);
            }
            expect(length.state.options.defaultLengthBars, 4);
            expect(repository.trackLengthPresetOverrides, isEmpty);
          } else {
            expect(store.values, before);
            expect(find.text('Record length needs recovery'), findsNothing);
            expect(length.state.options.defaultLengthBars, 4);
            expect(length.state.options.trackLengthPresetOverrides, {7: 0});
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    for (final malformed in [false, true]) {
      testWidgets(
        'Record timing startup recovery is reachable; malformed=$malformed',
        (tester) async {
          final store = _TimingStore()..refuseNextRead = !malformed;
          store.values.addAll({
            'looper.quantize': true,
            'tempo.quantize_div': 3,
            'track_record_timing.7': malformed ? 7 : 0,
          });
          final before = Map<String, Object>.of(store.values);
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final context = tester.element(find.byType(TracksView));
          final timing = context.read<RecordTimingCubit>();
          expect(timing.state.recordTimingReady, isFalse);
          expect(find.text('Record timing needs recovery'), findsOneWidget);
          await tester.pump(const Duration(seconds: 6));
          expect(find.text('Record timing needs recovery'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(timing.state.recordTimingReady, isTrue);
          expect(find.text('Record timing needs recovery'), findsNothing);
          if (malformed) {
            // Retry removes only the unreadable key; the rest survive.
            expect(
              store.values.containsKey('track_record_timing.7'),
              isFalse,
            );
            before.remove('track_record_timing.7');
            for (final entry in before.entries) {
              expect(store.values[entry.key], entry.value);
            }
            expect(timing.state.defaultTiming, RecordTiming.quarter);
            expect(repository.trackRecordTimingOverrides, isEmpty);
          } else {
            expect(store.values, before);
            expect(find.text('Record timing needs recovery'), findsNothing);
            expect(timing.state.defaultTiming, RecordTiming.quarter);
            expect(timing.state.trackOverrides, {7: RecordTiming.immediately});
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    for (final malformed in [false, true]) {
      testWidgets(
        'recording-start startup recovery remains actionable; '
        'malformed=$malformed',
        (tester) async {
          final store = _RecordStartStore()..refuseNextRead = !malformed;
          store.values['tempo.count_in_bars'] = malformed ? 3 : 4;
          store.values['looper.auto_record'] = false;
          final before = Map<String, Object>.of(store.values);
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final tempo = tester
              .element(find.byType(TracksView))
              .read<TempoCubit>();
          expect(tempo.state.recordStartSnapshot, isNull);
          expect(find.text('Recording start needs recovery'), findsOneWidget);
          await tester.pump(const Duration(seconds: 6));
          expect(find.text('Recording start needs recovery'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          // A transient read reads cleanly on Retry; a pair that stays
          // unreadable is repaired to (0, false).
          expect(tempo.state.recordStartReady, isTrue);
          expect(
            store.values,
            malformed
                ? {'tempo.count_in_bars': 0, 'looper.auto_record': false}
                : before,
          );
          expect(
            tempo.state.recordStartSnapshot?.settings.countInBars,
            malformed ? 0 : 4,
          );
          expect(tempo.state.recordStartSnapshot?.settings.soundStart, isFalse);
          expect(find.text('Recording start needs recovery'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    testWidgets('Hear click Retry preserves independent recording recovery', (
      tester,
    ) async {
      final store = FakeKeyValueStore();
      store.values['tempo.click_mode'] = 4;
      store.values['tempo.count_in_bars'] = 3;
      settings = SettingsRepository(store: store);
      await pumpApp(tester, NoopWaveformWindowService());
      final tempo = tester.element(find.byType(TracksView)).read<TempoCubit>();
      expect(debugAppToastActive(AppToastId.clickModeSettings), isTrue);
      expect(debugAppToastActive(AppToastId.recordStartSettings), isTrue);

      store.values['tempo.click_mode'] = 0;
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key(AppToastId.clickModeSettings)),
          matching: find.text('Retry'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tempo.state.clickModeReady, isTrue);
      expect(tempo.state.recordStartReady, isFalse);
      expect(debugAppToastActive(AppToastId.clickModeSettings), isFalse);
      expect(debugAppToastActive(AppToastId.recordStartSettings), isTrue);
      expect(find.text('Recording start needs recovery'), findsOneWidget);

      store.values['tempo.count_in_bars'] = 2;
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key(AppToastId.recordStartSettings)),
          matching: find.text('Retry'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tempo.state.recordStartReady, isTrue);
      expect(debugAppToastActive(AppToastId.recordStartSettings), isFalse);
    });

    for (final customName in [false, true]) {
      testWidgets(
        'Sound without input identifies its track; named=$customName',
        (
          tester,
        ) async {
          final store = FakeKeyValueStore();
          store.values['tempo.count_in_bars'] = 0;
          store.values['looper.auto_record'] = true;
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final context = tester.element(find.byType(TracksView));
          if (customName) {
            unawaited(context.read<TracksCubit>().rename(3, 'Harmony'));
            await tester.pumpAndSettle();
          }
          expect(
            context.read<TempoCubit>().state.confirmedRecordStart?.soundStart,
            isTrue,
          );
          final initialCalls = engine.recordCalls;
          expect(repository.record(channel: 3), EngineResult.invalid);
          await tester.pumpAndSettle();
          expect(
            debugAppToastActive(AppToastId.recordingInputRequired),
            isTrue,
          );
          final notice = find.byKey(
            const Key(AppToastId.recordingInputRequired),
          );
          expect(
            find.descendant(
              of: notice,
              matching: find.text('Choose recording inputs'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: notice,
              matching: find.text(customName ? 'Harmony' : 'TRACK 4'),
            ),
            findsOneWidget,
          );
          expect(engine.recordCalls, initialCalls);
          expect(engine.lastRecordImage, isNull);
          expect(engine.pendingImages, isEmpty);
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }

    for (final blockedKey in ['tempo.count_in_bars', 'looper.auto_record']) {
      testWidgets('power off waits for complete start pair: $blockedKey', (
        tester,
      ) async {
        final store = _RecordStartStore()..blockedKey = blockedKey;
        settings = SettingsRepository(store: store);
        var haltCalls = 0;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => haltCalls++,
        );
        final context = tester.element(find.byType(TracksView));
        final tempo = context.read<TempoCubit>();
        final power = context.read<PowerOffCubit>();
        expect(tempo.state.confirmedRecordStart?.countInBars, 1);
        expect(tempo.state.confirmedRecordStart?.soundStart, isFalse);
        store.pendingWrite = Completer<void>();
        unawaited(tempo.setSoundStart(enabled: true));
        await tester.pump();
        expect(store.writeEntered, isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pump(const Duration(milliseconds: 100));
        expect(power.state.phase, PowerOffPhase.flushing);
        expect(haltCalls, 0);
        expect(tempo.state.confirmedRecordStart?.countInBars, 1);
        expect(tempo.state.confirmedRecordStart?.soundStart, isFalse);
        store.pendingWrite!.complete();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(haltCalls, 1);
        expect(store.values['tempo.count_in_bars'], 0);
        expect(store.values['looper.auto_record'], isTrue);
        expect(
          context.read<TempoSettings>().recordStartOwner.durable.countInBars,
          0,
        );
        expect(
          context.read<TempoSettings>().recordStartOwner.durable.soundStart,
          isTrue,
        );
      });
    }

    for (final retry in [false, true]) {
      testWidgets('uncertain start pair keeps power on; retry=$retry', (
        tester,
      ) async {
        final store = _RecordStartStore();
        settings = SettingsRepository(store: store);
        var haltCalls = 0;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => haltCalls++,
        );
        final context = tester.element(find.byType(TracksView));
        final tempo = context.read<TempoCubit>();
        final power = context.read<PowerOffCubit>();
        store.refuseWrite = true;
        unawaited(tempo.setSoundStart(enabled: true));
        await tester.pumpAndSettle();
        expect(tempo.state.confirmedRecordStart?.countInBars, 1);
        expect(tempo.state.confirmedRecordStart?.soundStart, isFalse);
        expect(tempo.state.recordStartSnapshot, isNull);
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.flushFailed);
        expect(haltCalls, 0);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(debugAppToastActive(AppToastId.recordStartSettings), isFalse);
        store.refuseWrite = false;
        await tester.tap(
          find.byKey(Key(retry ? 'power_off_retry' : 'power_off_keep_playing')),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(haltCalls, retry ? 1 : 0);
        if (!retry) {
          expect(find.text('Recording start needs recovery'), findsOneWidget);
          expect(tempo.state.recordStartSnapshot, isNull);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Recording start needs recovery'), findsNothing);
        }
        expect(store.values.containsKey('tempo.count_in_bars'), isFalse);
        expect(store.values.containsKey('looper.auto_record'), isFalse);
        expect(
          context.read<TempoSettings>().recordStartOwner.durable.countInBars,
          1,
        );
        expect(
          context.read<TempoSettings>().recordStartOwner.durable.soundStart,
          isFalse,
        );
      });
    }

    testWidgets('compensated start refusal permits normal shutdown', (
      tester,
    ) async {
      final store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      repository.startEngine(const EngineConfig());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(TracksView));
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      engine.recordStartResult = EngineResult.invalid;
      bool? accepted;
      unawaited(
        context
            .read<TempoSettings>()
            .recordStartControl
            .setCountInBars(4)
            .then((v) => accepted = v.isOk),
      );
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(tempo.state.recordStartSnapshot?.settings.countInBars, 1);
      expect(store.values.containsKey('tempo.count_in_bars'), isFalse);
      expect(store.values.containsKey('looper.auto_record'), isFalse);
      expect(repository.recordStartRecoveryRequired, isFalse);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      await tester.pump(const Duration(seconds: 6));
      expect(haltCalls, 1);
    });

    for (final malformed in [false, true]) {
      testWidgets(
        'Hear click startup recovery remains actionable; malformed=$malformed',
        (tester) async {
          final store = _ClickModeStore()..refuseNextRead = !malformed;
          store.values['tempo.click_mode'] = malformed ? 4 : 0;
          final before = Map<String, Object>.of(store.values);
          settings = SettingsRepository(store: store);
          await pumpApp(tester, NoopWaveformWindowService());
          final tempo = tester
              .element(find.byType(TracksView))
              .read<TempoCubit>();
          expect(tempo.state.clickModeSnapshot, isNull);
          expect(find.text('Hear click needs attention'), findsOneWidget);
          await tester.pump(const Duration(seconds: 6));
          expect(find.text('Hear click needs attention'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          // A transient read reads cleanly on Retry; malformed data that
          // stays unreadable is repaired to Off.
          expect(tempo.state.clickModeReady, isTrue);
          expect(store.values, before..['tempo.click_mode'] = 0);
          expect(tempo.state.clickModeSnapshot?.mode, ClickMode.off);
          expect(find.text('Hear click needs attention'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 100));
        },
      );
    }

    testWidgets('power off waits for ordinary Hear click persistence', (
      tester,
    ) async {
      final store = _ClickModeStore();
      settings = SettingsRepository(store: store);
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      final context = tester.element(find.byType(TracksView));
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      expect(tempo.state.clickModeSnapshot?.mode, ClickMode.recFirst);
      store.pendingWrite = Completer<void>();
      unawaited(tempo.setClickMode(ClickMode.playRec));
      await tester.pump();
      expect(store.writeEntered, isTrue);
      power.press(const PowerOffSnapshot());
      await tester.pump(const Duration(milliseconds: 100));
      expect(power.state.phase, PowerOffPhase.flushing);
      expect(haltCalls, 0);
      expect(tempo.state.clickMode, ClickMode.recFirst);
      store.pendingWrite!.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(haltCalls, 1);
      expect(store.values['tempo.click_mode'], 3);
      expect(
        context.read<TempoSettings>().clickModeOwner.durable,
        ClickMode.playRec,
      );
    });

    for (final retry in [false, true]) {
      testWidgets('uncertain Hear click keeps power on; retry=$retry', (
        tester,
      ) async {
        final store = _ClickModeStore();
        settings = SettingsRepository(store: store);
        var haltCalls = 0;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => haltCalls++,
        );
        final context = tester.element(find.byType(TracksView));
        final tempo = context.read<TempoCubit>();
        final power = context.read<PowerOffCubit>();
        store.refuseWrite = true;
        unawaited(tempo.setClickMode(ClickMode.playRec));
        await tester.pumpAndSettle();
        expect(tempo.state.clickMode, ClickMode.recFirst);
        expect(tempo.state.clickModeSnapshot, isNull);
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.flushFailed);
        expect(haltCalls, 0);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(debugAppToastActive(AppToastId.clickModeSettings), isFalse);
        store.refuseWrite = false;
        await tester.tap(
          find.byKey(Key(retry ? 'power_off_retry' : 'power_off_keep_playing')),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(haltCalls, retry ? 1 : 0);
        if (!retry) {
          expect(find.text('Hear click needs attention'), findsOneWidget);
          expect(tempo.state.clickModeSnapshot, isNull);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Hear click needs attention'), findsNothing);
        }
        expect(store.values.containsKey('tempo.click_mode'), isFalse);
        expect(
          context.read<TempoSettings>().clickModeOwner.durable,
          ClickMode.recFirst,
        );
      });
    }

    for (final key in OwnedSetting.values.where(
      (key) => key != OwnedSetting.decay,
    )) {
      testWidgets(
        'a restart that lands the owed value clears its recovery notice; '
        '${key.name}',
        (tester) async {
          settings = SettingsRepository(store: FakeKeyValueStore());
          await pumpApp(tester, NoopWaveformWindowService());
          repository.startEngine(const EngineConfig());
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pumpAndSettle();
          final tempo = tester
              .element(find.byType(TracksView))
              .read<TempoSettings>();
          final playback = tester
              .element(find.byType(TracksView))
              .read<PlaybackSettings>();
          final record = tester
              .element(find.byType(TracksView))
              .read<RecordSettings>();
          final timing = tester
              .element(find.byType(TracksView))
              .read<RecordTimingSettings>();
          final (toast, owner) = switch (key) {
            OwnedSetting.clickVolume => (
              AppToastId.clickSettings,
              tempo.clickVolumeOwner,
            ),
            OwnedSetting.hearClick => (
              AppToastId.clickModeSettings,
              tempo.clickModeOwner,
            ),
            OwnedSetting.recordStart => (
              AppToastId.recordStartSettings,
              tempo.recordStartOwner,
            ),
            OwnedSetting.oneShot => (
              AppToastId.oneShotSettings,
              playback.oneShotOwner,
            ),
            OwnedSetting.recordLength => (
              AppToastId.recordLengthSettings,
              record.owner,
            ),
            OwnedSetting.recordTiming => (
              AppToastId.recordTimingSettings,
              timing.owner,
            ),
            OwnedSetting.decay => throw StateError('Decay has no receipt'),
          };
          engine
            ..publishClickCommands = key != OwnedSetting.clickVolume
            ..publishClickModeCommands = key != OwnedSetting.hearClick
            ..publishRecordStartCommands = key != OwnedSetting.recordStart
            ..commandsAreSettled = false;
          unawaited(switch (key) {
            OwnedSetting.clickVolume => tempo.clickVolumeOwner.set(1.5),
            OwnedSetting.hearClick => tempo.clickModeOwner.set(
              ClickMode.playRec,
            ),
            OwnedSetting.recordStart => tempo.recordStartControl.setCountInBars(
              2,
            ),
            OwnedSetting.oneShot => playback.oneShotControl.setTrackOneShot(
              channel: 2,
              oneShot: true,
            ),
            OwnedSetting.recordLength => record.setDefaultLengthBars(4),
            OwnedSetting.recordTiming => timing.setTiming(RecordTiming.quarter),
            OwnedSetting.decay => throw StateError('Decay has no receipt'),
          });
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump();
          expect(debugAppToastActive(toast), isTrue);
          repository.stopEngine();
          engine
            ..publishClickCommands = true
            ..publishClickModeCommands = true
            ..publishRecordStartCommands = true
            ..commandsAreSettled = true;
          repository.startEngine(const EngineConfig());
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pumpAndSettle();
          expect(owner.ready, isTrue);
          expect(debugAppToastActive(toast), isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 600));
        },
      );
    }

    testWidgets('compensated Hear click refusal permits normal shutdown', (
      tester,
    ) async {
      final rejectingEngine = _RefusingClickModeEngine();
      engine = rejectingEngine;
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      final store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      repository.startEngine(const EngineConfig());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(TracksView));
      final tempo = context.read<TempoCubit>();
      final power = context.read<PowerOffCubit>();
      rejectingEngine.refuseMode = true;
      bool? accepted;
      unawaited(
        context
            .read<TempoSettings>()
            .clickModeOwner
            .set(ClickMode.rec)
            .then((v) => accepted = v.isOk),
      );
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(tempo.state.clickModeSnapshot?.mode, ClickMode.recFirst);
      expect(store.values.containsKey('tempo.click_mode'), isFalse);
      expect(repository.clickModeRecoveryRequired, isFalse);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      await tester.pump(const Duration(seconds: 6));
      expect(haltCalls, 1);
    });

    for (final releasedBeforeShutdown in [false, true]) {
      testWidgets(
        'owed click release blocks power off; prior=$releasedBeforeShutdown',
        (tester) async {
          final rejectingEngine = _RefusingClickModeEngine();
          engine = rejectingEngine;
          repository = LooperRepository(
            engine: engine,
            ticker: const Stream<void>.empty(),
          );
          final store = FakeKeyValueStore();
          settings = SettingsRepository(store: store);
          final midi = _ShutdownMidi(settings);
          midiDeviceRepository = midi;
          addTearDown(() => unawaited(midi.dispose()));
          var haltCalls = 0;
          await pumpApp(
            tester,
            NoopWaveformWindowService(),
            powerOff: () async => haltCalls++,
          );
          repository.startEngine(const EngineConfig());
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(TracksView));
          final control = context.read<ControlCubit>();
          final tempo = context.read<TempoCubit>();
          final power = context.read<PowerOffCubit>();
          final editor = Object();
          control.beginMidiEdit(device: 'shutdown-test', owner: editor);
          MidiSaveResult? saved;
          final beforeSave = engine.clickModeRequests.length;
          unawaited(
            control
                .saveMidiMapping(
                  MidiMapping(
                    id: 'held-click-mode-shutdown',
                    source: MidiSource(
                      device: 'shutdown-test',
                      kind: ControllerSourceKind.midiCc,
                      number: 21,
                    ),
                    behavior: MidiBehavior.momentary,
                    controls: [
                      MidiParameterControl(
                        key: '{"ctl":"clickMode"}',
                        low: 0,
                        high: 1,
                      ),
                    ],
                  ),
                  owner: editor,
                  create: true,
                )
                .then((result) => saved = result),
          );
          await tester.pumpAndSettle();
          expect(saved?.saved, isTrue);
          expect(engine.clickModeRequests.length, beforeSave);
          control.endMidiEdit(editor);
          midi.push(127);
          await tester.pumpAndSettle();
          expect(tempo.state.clickModeSnapshot?.mode, ClickMode.playRec);
          expect(
            context.read<TempoSettings>().clickModeOwner.durable,
            ClickMode.off,
          );
          rejectingEngine.refuseMode = true;
          if (releasedBeforeShutdown) {
            midi.push(0);
            await tester.pumpAndSettle();
            expect(debugAppToastActive(AppToastId.clickModeSettings), isTrue);
            expect(tempo.state.clickMode, ClickMode.playRec);
          }
          final stopCalls = engine.stopCalls;
          power.press(const PowerOffSnapshot());
          await tester.pumpAndSettle();
          expect(power.state.phase, PowerOffPhase.flushFailed);
          expect(haltCalls, 0);
          expect(engine.stopCalls, stopCalls);
          expect(tempo.state.clickMode, ClickMode.playRec);
          expect(store.values['tempo.click_mode'], 0);
          expect(debugAppToastActive(AppToastId.clickModeSettings), isFalse);
          expect(
            find.byKey(const Key('power_off_retry')).hitTestable(),
            findsOneWidget,
          );
          final commandsBeforeLateInput = engine.clickModeRequests.length;
          midi.push(127);
          await tester.pumpAndSettle();
          expect(engine.clickModeRequests.length, commandsBeforeLateInput);
          rejectingEngine.refuseMode = false;
          await tester.tap(find.byKey(const Key('power_off_retry')));
          await tester.pumpAndSettle();
          expect(tempo.state.clickMode, ClickMode.off);
          expect(power.state.phase, PowerOffPhase.goodbye);
          await tester.pump(const Duration(seconds: 6));
          expect(haltCalls, 1);
        },
      );
    }

    for (final channel in <int?>[null, 7]) {
      testWidgets('power off waits for ordinary Record timing at $channel', (
        tester,
      ) async {
        final store = _TimingStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final timing = context.read<RecordTimingCubit>();
        final power = context.read<PowerOffCubit>();
        store.pendingWrite = Completer<void>();
        if (channel == null) {
          unawaited(timing.setTiming(RecordTiming.half));
        } else {
          unawaited(
            timing.setTrackTiming(
              channel: channel,
              timing: RecordTiming.eighth,
            ),
          );
        }
        await tester.pump();
        expect(store.writeEntered, isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pump(const Duration(milliseconds: 100));
        expect(power.state.phase, PowerOffPhase.flushing);
        expect(halted, isFalse);
        store.pendingWrite!.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        if (channel == null) {
          expect(store.values['looper.quantize'], true);
          expect(store.values['tempo.quantize_div'], 2);
        } else {
          expect(store.values['track_record_timing.7'], 5);
        }
      });
    }

    for (final retry in [false, true]) {
      testWidgets('Record timing failure keeps power on; retry=$retry', (
        tester,
      ) async {
        final store = _TimingStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final timing = context.read<RecordTimingCubit>();
        final power = context.read<PowerOffCubit>();
        store.refuseWrite = true;
        unawaited(timing.setTiming(RecordTiming.half));
        await tester.pumpAndSettle();
        expect(timing.state.defaultTiming, RecordTiming.immediately);
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.flushFailed);
        expect(halted, isFalse);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        store.refuseWrite = false;
        await tester.tap(
          find.byKey(
            Key(retry ? 'power_off_retry' : 'power_off_keep_playing'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(halted, retry);
        if (!retry) {
          // Staying on reopens input, but cannot prove a failed rollback.
          expect(find.text('Record timing needs recovery'), findsOneWidget);
          expect(timing.state.recordTimingReady, isFalse);
          unawaited(timing.setTiming(RecordTiming.half));
          await tester.pumpAndSettle();
          expect(timing.state.defaultTiming, RecordTiming.immediately);
          expect(timing.state.recordTimingReady, isFalse);
          // Explicit timing recovery restores the exact absent checkpoint.
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Record timing needs recovery'), findsNothing);
        }
        expect(store.values.containsKey('looper.quantize'), isFalse);
        expect(store.values.containsKey('tempo.quantize_div'), isFalse);
        if (!retry) {
          unawaited(timing.setTiming(RecordTiming.half));
          await tester.pumpAndSettle();
          expect(timing.state.defaultTiming, RecordTiming.half);
          expect(store.values['tempo.quantize_div'], 2);
        }
      });
    }

    for (final channel in <int?>[null, 7]) {
      testWidgets('power off waits for ordinary Decay at $channel', (
        tester,
      ) async {
        final store = _DecayStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final decay = context.read<PlaybackOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        store.pendingWrite = Completer<void>();
        if (channel == null) {
          unawaited(decay.setOverdubDecay(65));
        } else {
          unawaited(decay.setTrackOverdubDecay(channel: channel, percent: 65));
        }
        await tester.pump();
        expect(store.writeEntered, isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pump(const Duration(milliseconds: 100));
        expect(power.state.phase, PowerOffPhase.flushing);
        expect(halted, isFalse);
        store.pendingWrite!.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        final key = channel == null
            ? 'looper.overdub_decay'
            : 'track_overdub_decay.$channel';
        expect(store.values[key], 65);
      });
    }

    for (final retry in [false, true]) {
      testWidgets('Decay refusal stays on; recovery choice retry=$retry', (
        tester,
      ) async {
        final store = _DecayStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final decay = context.read<PlaybackOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        store.refuseWrite = true;
        unawaited(decay.setOverdubDecay(80));
        await tester.pumpAndSettle();
        expect(decay.state.overdubDecay, 0);
        expect(debugAppToastActive(AppToastId.decaySettings), isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.flushFailed);
        expect(debugAppToastActive(AppToastId.decaySettings), isFalse);
        expect(find.text('Settings could not be confirmed'), findsOneWidget);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(halted, isFalse);
        store.refuseWrite = false;
        await tester.tap(
          find.byKey(Key(retry ? 'power_off_retry' : 'power_off_keep_playing')),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(halted, retry);
        if (!retry) {
          // The owed rollback keeps Decay unavailable until its own Retry.
          expect(find.text('Decay settings need recovery'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Decay settings need recovery'), findsNothing);
        }
        expect(store.values.containsKey('looper.overdub_decay'), isFalse);
        if (!retry) {
          unawaited(decay.setOverdubDecay(25));
          await tester.pumpAndSettle();
          expect(decay.state.overdubDecay, 25);
          expect(store.values['looper.overdub_decay'], 25);
        }
      });
    }

    for (final decay in [true, false]) {
      testWidgets('compensated ${decay ? 'Decay' : 'Loop/Once'} refusal '
          'permits normal shutdown', (tester) async {
        final decayStore = _DecayStore()..refuseCompensation = false;
        final onceStore = _OneShotStore()..refuseCompensation = false;
        settings = SettingsRepository(store: decay ? decayStore : onceStore);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final options = context.read<PlaybackOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        decayStore.refuseWrite = true;
        onceStore.refuseWrite = true;
        if (decay) {
          unawaited(options.setOverdubDecay(80));
        } else {
          unawaited(options.setDefaultOneShot(value: true));
        }
        await tester.pumpAndSettle();
        // The write was refused and its rollback landed: nothing is owed.
        expect(options.state.overdubDecay, 0);
        expect(options.state.defaultOneShot, isFalse);
        expect(decayStore.values.containsKey('looper.overdub_decay'), isFalse);
        expect(
          onceStore.values.containsKey('looper.default_one_shot'),
          isFalse,
        );
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.goodbye);
        await tester.pump(const Duration(seconds: 6));
        expect(halted, isTrue);
      });
    }

    testWidgets('power off releases held Decay and rejects later MIDI', (
      tester,
    ) async {
      final store = _DecayStore();
      settings = SettingsRepository(store: store);
      final midi = _ShutdownMidi(settings);
      midiDeviceRepository = midi;
      addTearDown(() => unawaited(midi.dispose()));
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      final context = tester.element(find.byType(TracksView));
      final control = context.read<ControlCubit>();
      final decay = context.read<PlaybackOptionsCubit>();
      final power = context.read<PowerOffCubit>();
      final editor = Object();
      control.beginMidiEdit(device: 'shutdown-test', owner: editor);
      MidiSaveResult? saved;
      unawaited(
        control
            .saveMidiMapping(
              MidiMapping(
                id: 'shutdown-decay',
                source: MidiSource(
                  device: 'shutdown-test',
                  kind: ControllerSourceKind.midiCc,
                  number: 21,
                ),
                behavior: MidiBehavior.momentary,
                controls: [
                  MidiParameterControl(
                    key: '{"ctl":"overdubDecay"}',
                    low: .2,
                    high: .8,
                  ),
                  MidiParameterControl(
                    key: '{"ctl":"trackOverdubDecay","index":7}',
                    low: 0,
                    high: .75,
                  ),
                ],
              ),
              owner: editor,
              create: true,
            )
            .then((result) => saved = result),
      );
      await tester.pumpAndSettle();
      expect(saved?.saved, isTrue);
      control.endMidiEdit(editor);
      midi.push(127);
      await tester.pumpAndSettle();
      expect(decay.state.overdubDecay, 80);
      expect(decay.state.trackOverdubDecayOverrides, {7: 75});
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      expect(decay.state.overdubDecay, 20);
      expect(decay.state.trackOverdubDecayOverrides, {7: 0});
      expect(store.values['looper.overdub_decay'], 20);
      expect(store.values['track_overdub_decay.7'], 0);
      store.writeEntered = false;
      midi.push(127);
      await tester.pump();
      expect(store.writeEntered, isFalse);
      expect(decay.state.overdubDecay, 20);
      expect(decay.state.trackOverdubDecayOverrides, {7: 0});
      await tester.pump(const Duration(seconds: 2));
      expect(haltCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    for (final channel in <int?>[null, 7]) {
      testWidgets('power off waits for ordinary OneShot at $channel', (
        tester,
      ) async {
        final store = _OneShotStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final once = context.read<PlaybackOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        store.pendingWrite = Completer<void>();
        if (channel == null) {
          unawaited(once.setDefaultOneShot(value: true));
        } else {
          unawaited(once.setTrackOneShot(channel: channel, oneShot: true));
        }
        await tester.pump();
        expect(store.writeEntered, isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pump(const Duration(milliseconds: 100));
        expect(power.state.phase, PowerOffPhase.flushing);
        expect(halted, isFalse);
        store.pendingWrite!.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        final key = channel == null
            ? 'looper.default_one_shot'
            : 'track_one_shot.$channel';
        expect(store.values[key], true);
      });
    }

    for (final retry in [false, true]) {
      testWidgets('OneShot refusal stays on; recovery choice retry=$retry', (
        tester,
      ) async {
        final store = _OneShotStore();
        settings = SettingsRepository(store: store);
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final once = context.read<PlaybackOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        store.refuseWrite = true;
        unawaited(once.setDefaultOneShot(value: true));
        await tester.pumpAndSettle();
        expect(once.state.defaultOneShot, isFalse);
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.flushFailed);
        expect(find.text('Settings could not be confirmed'), findsOneWidget);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(halted, isFalse);
        store.refuseWrite = false;
        await tester.tap(
          find.byKey(Key(retry ? 'power_off_retry' : 'power_off_keep_playing')),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(halted, retry);
        if (!retry) {
          // The owed rollback keeps Loop/Once unavailable until its Retry.
          expect(find.text('Playback settings need recovery'), findsOneWidget);
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('Playback settings need recovery'), findsNothing);
        }
        expect(store.values.containsKey('looper.default_one_shot'), isFalse);
        if (!retry) {
          unawaited(once.setDefaultOneShot(value: true));
          await tester.pumpAndSettle();
          expect(once.state.defaultOneShot, isTrue);
          expect(store.values['looper.default_one_shot'], true);
        }
      });
    }

    testWidgets('power off releases held OneShot and rejects later MIDI', (
      tester,
    ) async {
      final store = _OneShotStore();
      settings = SettingsRepository(store: store);
      final midi = _ShutdownMidi(settings);
      midiDeviceRepository = midi;
      addTearDown(() => unawaited(midi.dispose()));
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      final context = tester.element(find.byType(TracksView));
      final control = context.read<ControlCubit>();
      final once = context.read<PlaybackOptionsCubit>();
      final power = context.read<PowerOffCubit>();
      final editor = Object();
      control.beginMidiEdit(device: 'shutdown-test', owner: editor);
      MidiSaveResult? saved;
      unawaited(
        control
            .saveMidiMapping(
              MidiMapping(
                id: 'shutdown-once',
                source: MidiSource(
                  device: 'shutdown-test',
                  kind: ControllerSourceKind.midiCc,
                  number: 21,
                ),
                behavior: MidiBehavior.momentary,
                controls: [
                  MidiParameterControl(
                    key: '{"ctl":"defaultOneShot"}',
                    low: 0,
                    high: 1,
                  ),
                  MidiParameterControl(
                    key: '{"ctl":"trackOneShot","index":7}',
                    low: 0,
                    high: 1,
                  ),
                ],
              ),
              owner: editor,
              create: true,
            )
            .then((result) => saved = result),
      );
      await tester.pumpAndSettle();
      expect(saved?.saved, isTrue);
      control.endMidiEdit(editor);
      midi.push(127);
      await tester.pumpAndSettle();
      expect(once.state.defaultOneShot, isTrue);
      expect(once.state.trackOneShotOverrides, {7: true});
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      expect(once.state.defaultOneShot, isFalse);
      expect(once.state.trackOneShotOverrides, {7: false});
      expect(store.values['looper.default_one_shot'], false);
      expect(store.values['track_one_shot.7'], false);
      store.writeEntered = false;
      midi.push(127);
      await tester.pump();
      expect(store.writeEntered, isFalse);
      expect(once.state.defaultOneShot, isFalse);
      expect(once.state.trackOneShotOverrides, {7: false});
      await tester.pump(const Duration(seconds: 2));
      expect(haltCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    for (final channel in <int?>[null, 7]) {
      testWidgets('power off waits for ordinary Record length at $channel', (
        tester,
      ) async {
        final store = _LengthStore();
        settings = SettingsRepository(store: store);
        store.values['looper.mode'] = LooperMode.free.code;
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => halted = true,
        );
        final context = tester.element(find.byType(TracksView));
        final length = context.read<RecordOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        store.pendingWrite = Completer<void>();
        if (channel == null) {
          unawaited(length.setDefaultLengthBars(4));
        } else {
          unawaited(length.setTrackRecordLength(channel: channel, bars: 4));
        }
        await tester.pump();
        expect(store.writeEntered, isTrue);
        power.press(const PowerOffSnapshot());
        await tester.pump(const Duration(milliseconds: 100));
        expect(power.state.phase, PowerOffPhase.flushing);
        expect(halted, isFalse);
        store.pendingWrite!.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        final key = channel == null
            ? 'looper.default_length_bars'
            : 'tempo.length_preset.$channel';
        expect(store.values[key], 4);
      });
    }

    for (final retry in [false, true]) {
      testWidgets(
        'Record length refusal stays on; recovery choice retry=$retry',
        (
          tester,
        ) async {
          final store = _LengthStore();
          settings = SettingsRepository(store: store);
          store.values['looper.mode'] = LooperMode.free.code;
          var halted = false;
          await pumpApp(
            tester,
            NoopWaveformWindowService(),
            powerOff: () async => halted = true,
          );
          final context = tester.element(find.byType(TracksView));
          final length = context.read<RecordOptionsCubit>();
          final power = context.read<PowerOffCubit>();
          store.refuseWrite = true;
          unawaited(length.setDefaultLengthBars(4));
          await tester.pumpAndSettle();
          expect(length.state.options.defaultLengthBars, 0);
          power.press(const PowerOffSnapshot());
          await tester.pumpAndSettle();
          expect(power.state.phase, PowerOffPhase.flushFailed);
          expect(find.text('Settings could not be confirmed'), findsOneWidget);
          expect(find.byKey(const Key('power_off_discard')), findsNothing);
          expect(halted, isFalse);
          store.refuseWrite = false;
          await tester.tap(
            find.byKey(
              Key(retry ? 'power_off_retry' : 'power_off_keep_playing'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 6));
          expect(halted, retry);
          if (!retry) {
            // The owed rollback keeps Record length unavailable until Retry.
            expect(find.text('Record length needs recovery'), findsOneWidget);
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            expect(find.text('Record length needs recovery'), findsNothing);
          }
          expect(
            store.values.containsKey('looper.default_length_bars'),
            isFalse,
          );
          if (!retry) {
            unawaited(length.setDefaultLengthBars(4));
            await tester.pumpAndSettle();
            expect(length.state.options.defaultLengthBars, 4);
            expect(store.values['looper.default_length_bars'], 4);
          }
        },
      );
    }

    testWidgets('compensated Record length refusal permits normal shutdown', (
      tester,
    ) async {
      final store = _LengthStore()..refuseCompensation = false;
      settings = SettingsRepository(store: store);
      var halted = false;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => halted = true,
      );
      final context = tester.element(find.byType(TracksView));
      final length = context.read<RecordOptionsCubit>();
      final power = context.read<PowerOffCubit>();
      store.refuseWrite = true;
      unawaited(length.setDefaultLengthBars(4));
      await tester.pumpAndSettle();
      // The write was refused and its rollback landed: nothing is owed.
      expect(length.state.options.defaultLengthBars, 0);
      expect(store.values.containsKey('looper.default_length_bars'), isFalse);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      await tester.pump(const Duration(seconds: 6));
      expect(halted, isTrue);
    });

    testWidgets('compensated timing refusal does not block power off', (
      tester,
    ) async {
      final rejectingEngine = _RefusingTimingEngine();
      engine = rejectingEngine;
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      final store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
      var haltCalls = 0;
      await pumpApp(
        tester,
        NoopWaveformWindowService(),
        powerOff: () async => haltCalls++,
      );
      repository.startEngine(const EngineConfig());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(TracksView));
      final timing = context.read<RecordTimingCubit>();
      final power = context.read<PowerOffCubit>();
      rejectingEngine.refuseTiming = true;
      bool? accepted;
      unawaited(
        context
            .read<RecordTimingSettings>()
            .setTiming(RecordTiming.quarter)
            .then((v) => accepted = v.isOk),
      );
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(timing.state.defaultTiming, RecordTiming.immediately);
      expect(timing.state.recordTimingReady, isTrue);
      expect(store.values.containsKey('looper.quantize'), isFalse);
      expect(store.values.containsKey('tempo.quantize_div'), isFalse);
      expect(repository.recordTimingRecoveryRequired, isFalse);
      power.press(const PowerOffSnapshot());
      await tester.pumpAndSettle();
      expect(power.state.phase, PowerOffPhase.goodbye);
      expect(find.byKey(const Key('power_off_retry')), findsNothing);
      // Let both the goodbye and the earlier refusal toast finish.
      await tester.pump(const Duration(seconds: 6));
      expect(haltCalls, 1);
    });

    for (final releasedBeforeShutdown in [false, true]) {
      testWidgets(
        'power off waits for an owed timing release; '
        'releasedBeforeShutdown=$releasedBeforeShutdown',
        (tester) async {
          final rejectingEngine = _RefusingTimingEngine();
          engine = rejectingEngine;
          repository = LooperRepository(
            engine: engine,
            ticker: const Stream<void>.empty(),
          );
          final store = FakeKeyValueStore();
          settings = SettingsRepository(store: store);
          final midi = _ShutdownMidi(settings);
          midiDeviceRepository = midi;
          addTearDown(() => unawaited(midi.dispose()));
          var haltCalls = 0;
          await pumpApp(
            tester,
            NoopWaveformWindowService(),
            powerOff: () async => haltCalls++,
          );
          repository.startEngine(const EngineConfig());
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(TracksView));
          final control = context.read<ControlCubit>();
          final timing = context.read<RecordTimingCubit>();
          final power = context.read<PowerOffCubit>();
          final editor = Object();
          control.beginMidiEdit(device: 'shutdown-test', owner: editor);
          MidiSaveResult? saved;
          unawaited(
            control
                .saveMidiMapping(
                  MidiMapping(
                    id: 'held-timing-shutdown',
                    source: MidiSource(
                      device: 'shutdown-test',
                      kind: ControllerSourceKind.midiCc,
                      number: 21,
                    ),
                    behavior: MidiBehavior.momentary,
                    controls: [
                      MidiParameterControl(
                        key: '{"ctl":"trackRecordTiming","index":0}',
                        low: 0,
                        high: 1,
                      ),
                    ],
                  ),
                  owner: editor,
                  create: true,
                )
                .then((result) => saved = result),
          );
          await tester.pumpAndSettle();
          expect(saved?.saved, isTrue);
          control.endMidiEdit(editor);
          midi.push(127);
          await tester.pumpAndSettle();
          expect(timing.state.trackOverrides[0], RecordTiming.sixteenth);
          expect(
            context
                .read<RecordTimingSettings>()
                .durableRecordTimingSnapshot
                .trackOverrides[0],
            RecordTiming.immediately,
          );
          rejectingEngine.refuseTiming = true;
          if (releasedBeforeShutdown) {
            midi.push(0);
            await tester.pumpAndSettle();
            expect(
              debugAppToastActive(AppToastId.recordTimingSettings),
              isTrue,
            );
            expect(timing.state.trackOverrides[0], RecordTiming.sixteenth);
          }
          final stopCalls = engine.stopCalls;
          power.press(const PowerOffSnapshot());
          await tester.pumpAndSettle();
          expect(power.state.phase, PowerOffPhase.flushFailed);
          expect(find.byKey(const Key('power_off_retry')), findsOneWidget);
          expect(haltCalls, 0);
          expect(engine.stopCalls, stopCalls);
          expect(timing.state.trackOverrides[0], RecordTiming.sixteenth);
          expect(store.values['track_record_timing.0'], 0);
          expect(debugAppToastActive(AppToastId.recordTimingSettings), isFalse);
          expect(
            find.byKey(const Key('power_off_retry')).hitTestable(),
            findsOneWidget,
          );

          rejectingEngine.refuseTiming = false;
          await tester.tap(find.byKey(const Key('power_off_retry')));
          await tester.pumpAndSettle();
          expect(timing.state.trackOverrides[0], RecordTiming.immediately);
          expect(power.state.phase, PowerOffPhase.goodbye);
          await tester.pump(const Duration(seconds: 6));
          expect(haltCalls, 1);
        },
      );
    }

    testWidgets(
      'Record timing held memory survives capture and safe power key',
      (tester) async {
        final ticker = StreamController<void>.broadcast();
        repository = LooperRepository(engine: engine, ticker: ticker.stream);
        addTearDown(repository.dispose);
        addTearDown(() => unawaited(ticker.close()));
        final store = _TimingStore();
        store.values['tempo.quantize_div'] = 3;
        settings = SettingsRepository(store: store);
        final midi = _ShutdownMidi(settings);
        midiDeviceRepository = midi;
        addTearDown(() => unawaited(midi.dispose()));
        final key = _PowerKey();
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerKeySource: key,
          powerOff: () async => halted = true,
        );
        repository.startEngine(const EngineConfig());
        ticker.add(null);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(TracksView));
        final control = context.read<ControlCubit>();
        final timing = context.read<RecordTimingCubit>();
        final power = context.read<PowerOffCubit>();
        final editor = Object();
        control.beginMidiEdit(device: 'shutdown-test', owner: editor);
        MidiSaveResult? saved;
        unawaited(
          control
              .saveMidiMapping(
                MidiMapping(
                  id: 'capture-timing',
                  source: MidiSource(
                    device: 'shutdown-test',
                    kind: ControllerSourceKind.midiCc,
                    number: 21,
                  ),
                  behavior: MidiBehavior.momentary,
                  controls: [
                    MidiParameterControl(
                      key: '{"ctl":"defaultRecordTiming"}',
                      low: 0,
                      high: 1,
                    ),
                  ],
                ),
                owner: editor,
                create: true,
              )
              .then((result) => saved = result),
        );
        await tester.pumpAndSettle();
        expect(saved?.saved, isTrue);
        control.endMidiEdit(editor);
        midi.push(127);
        await tester.pumpAndSettle();
        expect(timing.state.defaultTiming, RecordTiming.sixteenth);
        expect(
          context
              .read<RecordTimingSettings>()
              .durableRecordTimingSnapshot
              .defaultTiming,
          RecordTiming.immediately,
        );
        expect(
          context
              .read<RecordTimingSettings>()
              .durableRecordTimingSnapshot
              .rememberedDivision,
          GridDivision.quarter,
        );

        // Only the engine seam is simulated. The live repository, owner,
        // controller, Bloc, power-key host, gate and dialog are production.
        engine.nextSnapshot = engine.snapshot().copyWith(
          looperMode: LooperMode.multi,
          tracks: [
            const le.TrackSnapshot(
              state: le.TrackState.recording,
              volume: 1,
              muted: false,
              lengthFrames: 1000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
            ),
            for (var i = 1; i < 8; i++) const le.TrackSnapshot.empty(),
          ],
        );
        ticker.add(null);
        await tester.pumpAndSettle();
        expect(timing.state.captureLocked, isTrue);
        midi.push(0);
        await tester.pumpAndSettle();
        expect(timing.state.defaultTiming, RecordTiming.sixteenth);
        expect(
          context
              .read<RecordTimingSettings>()
              .durableRecordTimingSnapshot
              .defaultTiming,
          RecordTiming.immediately,
        );
        expect(
          context
              .read<RecordTimingSettings>()
              .durableRecordTimingSnapshot
              .rememberedDivision,
          GridDivision.quarter,
        );
        final stopCalls = engine.stopCalls;
        key.press();
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.refuse);
        expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(halted, isFalse);
        expect(engine.stopCalls, stopCalls);
        expect(repository.state.tracks.first.isCapturing, isTrue);
        await tester.tap(find.byKey(const Key('power_off_keep_playing')));
        await tester.pumpAndSettle();

        // The player ends capture; the owed release can now retire safely.
        engine.nextSnapshot = engine.snapshot().copyWith(
          tracks: [for (var i = 0; i < 8; i++) const le.TrackSnapshot.empty()],
        );
        ticker.add(null);
        await tester.pumpAndSettle();
        expect(timing.state.defaultTiming, RecordTiming.immediately);
        expect(timing.state.rememberedDivision, GridDivision.quarter);
        expect(engine.stopCalls, stopCalls);
        key.press();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'Record length release during capture keeps actual power key safe',
      (tester) async {
        final ticker = StreamController<void>.broadcast();
        repository = LooperRepository(engine: engine, ticker: ticker.stream);
        addTearDown(repository.dispose);
        addTearDown(() => unawaited(ticker.close()));
        final store = _LengthStore();
        store.values['looper.mode'] = LooperMode.free.code;
        settings = SettingsRepository(store: store);
        final midi = _ShutdownMidi(settings);
        midiDeviceRepository = midi;
        addTearDown(() => unawaited(midi.dispose()));
        final key = _PowerKey();
        var halted = false;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerKeySource: key,
          powerOff: () async => halted = true,
        );
        repository.startEngine(const EngineConfig());
        ticker.add(null);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(TracksView));
        final control = context.read<ControlCubit>();
        final length = context.read<RecordOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        final editor = Object();
        control.beginMidiEdit(device: 'shutdown-test', owner: editor);
        MidiSaveResult? saved;
        unawaited(
          control
              .saveMidiMapping(
                MidiMapping(
                  id: 'capture-length',
                  source: MidiSource(
                    device: 'shutdown-test',
                    kind: ControllerSourceKind.midiCc,
                    number: 21,
                  ),
                  behavior: MidiBehavior.momentary,
                  controls: [
                    MidiParameterControl(
                      key: '{"ctl":"defaultRecordLength"}',
                      low: 0,
                      high: 4 / 64,
                    ),
                  ],
                ),
                owner: editor,
                create: true,
              )
              .then((result) => saved = result),
        );
        await tester.pumpAndSettle();
        expect(saved?.saved, isTrue);
        control.endMidiEdit(editor);
        midi.push(127);
        await tester.pumpAndSettle();
        expect(length.state.options.defaultLengthBars, 4);
        expect(
          context
              .read<RecordSettings>()
              .durableRecordLengthSnapshot
              .defaultBars,
          0,
        );

        // Only the engine seam is simulated. The live repository, owner,
        // controller, Bloc, power-key host, gate and dialog are production.
        engine.nextSnapshot = engine.snapshot().copyWith(
          looperMode: LooperMode.free,
          tracks: [
            const le.TrackSnapshot(
              state: le.TrackState.recording,
              volume: 1,
              muted: false,
              lengthFrames: 1000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
              lengthPresetBars: 4,
            ),
            for (var i = 1; i < 8; i++) const le.TrackSnapshot.empty(),
          ],
        );
        ticker.add(null);
        await tester.pumpAndSettle();
        expect(length.state.options.recordLengthCaptureLocked, isTrue);
        midi.push(0);
        await tester.pumpAndSettle();
        expect(length.state.options.defaultLengthBars, 4);
        expect(
          context
              .read<RecordSettings>()
              .durableRecordLengthSnapshot
              .defaultBars,
          0,
        );
        final stopCalls = engine.stopCalls;
        key.press();
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.refuse);
        expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
        expect(find.byKey(const Key('power_off_discard')), findsNothing);
        expect(halted, isFalse);
        expect(engine.stopCalls, stopCalls);
        expect(repository.state.tracks.first.isCapturing, isTrue);
        await tester.tap(find.byKey(const Key('power_off_keep_playing')));
        await tester.pumpAndSettle();

        // The player ends capture; the owed release can now retire safely.
        engine.nextSnapshot = engine.snapshot().copyWith(
          tracks: [for (var i = 0; i < 8; i++) const le.TrackSnapshot.empty()],
        );
        ticker.add(null);
        await tester.pumpAndSettle();
        expect(length.state.options.defaultLengthBars, 0);
        expect(engine.stopCalls, stopCalls);
        key.press();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        expect(halted, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'power off releases held Record length and rejects later MIDI',
      (
        tester,
      ) async {
        final store = _LengthStore();
        settings = SettingsRepository(store: store);
        store.values['looper.mode'] = LooperMode.free.code;
        final midi = _ShutdownMidi(settings);
        midiDeviceRepository = midi;
        addTearDown(() => unawaited(midi.dispose()));
        var haltCalls = 0;
        await pumpApp(
          tester,
          NoopWaveformWindowService(),
          powerOff: () async => haltCalls++,
        );
        final context = tester.element(find.byType(TracksView));
        final control = context.read<ControlCubit>();
        final length = context.read<RecordOptionsCubit>();
        final power = context.read<PowerOffCubit>();
        final editor = Object();
        control.beginMidiEdit(device: 'shutdown-test', owner: editor);
        MidiSaveResult? saved;
        unawaited(
          control
              .saveMidiMapping(
                MidiMapping(
                  id: 'shutdown-length',
                  source: MidiSource(
                    device: 'shutdown-test',
                    kind: ControllerSourceKind.midiCc,
                    number: 21,
                  ),
                  behavior: MidiBehavior.momentary,
                  controls: [
                    MidiParameterControl(
                      key: '{"ctl":"defaultRecordLength"}',
                      low: 0,
                      high: 4 / 64,
                    ),
                    MidiParameterControl(
                      key: '{"ctl":"trackRecordLength","index":7}',
                      low: 0,
                      high: 4 / 64,
                    ),
                  ],
                ),
                owner: editor,
                create: true,
              )
              .then((result) => saved = result),
        );
        await tester.pumpAndSettle();
        expect(saved?.saved, isTrue);
        control.endMidiEdit(editor);
        midi.push(127);
        await tester.pumpAndSettle();
        expect(length.state.options.defaultLengthBars, 4);
        expect(length.state.options.trackLengthPresetOverrides, {7: 4});
        power.press(const PowerOffSnapshot());
        await tester.pumpAndSettle();
        expect(power.state.phase, PowerOffPhase.goodbye);
        expect(length.state.options.defaultLengthBars, 0);
        expect(length.state.options.trackLengthPresetOverrides, {7: 0});
        expect(store.values['looper.default_length_bars'], 0);
        expect(store.values['tempo.length_preset.7'], 0);
        store.writeEntered = false;
        midi.push(127);
        await tester.pump();
        expect(store.writeEntered, isFalse);
        expect(length.state.options.defaultLengthBars, 0);
        expect(length.state.options.trackLengthPresetOverrides, {7: 0});
        await tester.pump(const Duration(seconds: 2));
        expect(haltCalls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    for (final redo in [false, true]) {
      testWidgets('explains a refused ${redo ? 'redo' : 'undo'} without '
          'leaving Tracks', (tester) async {
        await pumpApp(tester, NoopWaveformWindowService());
        engine.nextHistoryModeGate = EngineResult.modeMismatch;
        final result = redo ? repository.redo() : repository.undo();
        expect(result, EngineResult.modeMismatch);
        await tester.pumpAndSettle();
        expect(find.text('Loop does not fit this mode'), findsOneWidget);
        expect(
          find.text(
            'Choose Free in Loop settings, then try '
            '${redo ? 'Redo' : 'Undo'} again. Your session is unchanged.',
          ),
          findsOneWidget,
        );
        expect(find.byType(TracksView), findsOneWidget);
        expect(engine.historyModeGateCalls.last, (channels: 1, redo: redo));
        // The message can be dismissed; it does not force a mode change.
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key(AppToastId.recoveryRefused)),
            matching: find.byType(IconButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Loop does not fit this mode'), findsNothing);
        expect(repository.settledLooperMode, LooperMode.multi);
      });
    }

    testWidgets('a pending edit asks for a retry, not a different mode', (
      tester,
    ) async {
      await pumpApp(tester, NoopWaveformWindowService());
      engine.nextHistoryModeGate = EngineResult.notReady;
      expect(repository.redo(), EngineResult.notReady);
      await tester.pumpAndSettle();
      expect(find.text('Recovery is not ready yet'), findsOneWidget);
      expect(
        find.text(
          'Let the current change finish, then try again. '
          'Your session is unchanged.',
        ),
        findsOneWidget,
      );
      // A different refusal replaces the message instead of stacking it.
      engine.nextHistoryModeGate = EngineResult.modeMismatch;
      repository.undo();
      await tester.pumpAndSettle();
      expect(find.text('Recovery is not ready yet'), findsNothing);
      expect(find.text('Loop does not fit this mode'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text('Loop does not fit this mode'), findsNothing);
    });

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

    testWidgets('keeps the fallback pedal repository stable across rebuilds', (
      tester,
    ) async {
      App buildApp() => App(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        controllerRepository: controllerRepository,
        midiDeviceRepository: midiDeviceRepository,
        settings: settings,
        waveformWindow: NoopWaveformWindowService(),
        sessionRepository: sessionRepository,
        performanceRepository: performanceRepository,
        exportDirectory: () async => '.',
      );
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      final first = tester
          .element(find.byType(MaterialApp))
          .read<PedalRepository>();

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      final second = tester
          .element(find.byType(MaterialApp))
          .read<PedalRepository>();

      expect(identical(first, second), isTrue);
    });

    testWidgets('provides pedal events to the Sessions manager', (
      tester,
    ) async {
      final sessionsRoot = Directory.systemTemp.createTempSync(
        'segno-app-sessions-',
      );
      addTearDown(() => sessionsRoot.delete(recursive: true));
      sessionRepository = SessionRepository(
        engine: FakeAudioEngine(),
        sessionsRoot: () async => sessionsRoot.path,
      );
      final link = FakePedalLink();
      final pedal = PedalRepository(link);
      link.hello();
      await tester.pumpWidget(
        App(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          controllerRepository: controllerRepository,
          midiDeviceRepository: midiDeviceRepository,
          settings: settings,
          waveformWindow: NoopWaveformWindowService(),
          sessionRepository: sessionRepository,
          performanceRepository: performanceRepository,
          exportDirectory: () async => '.',
          pedalRepository: pedal,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('stage_library')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);

      link.press(PedalButton.clear, down: true);
      await tester.pump();
      link.press(PedalButton.clear, down: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions_manager')), findsNothing);
      expect(find.byType(LooperPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(pedal.helloTimeout);
    });

    testWidgets('always lands on the looper — no first-run gate', (
      tester,
    ) async {
      // The wizard and the needsSetup gate are gone; the app renders the looper
      // directly even with no saved audio config.
      await tester.pumpWidget(
        App(
          mixSettings: testMixSettings(repository, settings: settings),
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

    testWidgets('waits before opening the second native view', (tester) async {
      final window = _RecordingWindowService();
      await pumpApp(
        tester,
        window,
        waveformWindowOpenDelay: const Duration(milliseconds: 750),
        settle: false,
      );
      await tester.pump();
      expect(window.openCalls, 0);
      await tester.pump(const Duration(milliseconds: 749));
      expect(window.openCalls, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(window.openCalls, 1);
    });

    testWidgets('preference changes cannot bypass the startup wait', (
      tester,
    ) async {
      final window = _RecordingWindowService();
      await pumpApp(
        tester,
        window,
        waveformWindowOpenDelay: const Duration(milliseconds: 750),
        settle: false,
      );
      await tester.pump();
      final waveform = tester
          .element(find.byType(LooperPage))
          .read<WaveformWindowCubit>();
      await waveform.setEnabled(value: false);
      await waveform.setEnabled(value: true);
      await tester.pump();
      expect(window.openCalls, 0);
      await waveform.setEnabled(value: false);
      await tester.pump(const Duration(milliseconds: 750));
      expect(window.openCalls, 0);
      await waveform.setEnabled(value: true);
      await tester.pump();
      expect(window.openCalls, 1);
    });

    testWidgets('unmount cancels the delayed window open', (tester) async {
      final window = _RecordingWindowService();
      await pumpApp(
        tester,
        window,
        waveformWindowOpenDelay: const Duration(milliseconds: 750),
        settle: false,
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(window.openCalls, 0);
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
            mixSettings: testMixSettings(pinned),
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
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'a reconnect that dropped a track is one warning toast naming it — '
      'not the restored snack, and never a bar (#1140)',
      (tester) async {
        const deviceBanner = Key('connectivity_banner_device');
        const materialBanner = Key('connectivity_banner_material');
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
              // Every track present, so the startup replays (one-shot, length
              // presets) can confirm against the fake and the supervisor's
              // admission predicate holds the engine open for a reopen.
              tracks: List.generate(8, (_) => const le.TrackSnapshot.empty()),
            );
        final ticker = StreamController<void>.broadcast();
        addTearDown(() => unawaited(ticker.close()));
        final reconnectTicker = StreamController<void>.broadcast();
        addTearDown(() => unawaited(reconnectTicker.close()));
        final pinned = LooperRepository(
          engine: engine,
          ticker: ticker.stream,
          reconnectTicker: reconnectTicker.stream,
        );
        addTearDown(pinned.dispose);
        engine.nextSnapshot = snapshot(devicePresent: true);
        pinned.startEngine(const EngineConfig(playbackDeviceId: 'out-1'));

        await tester.pumpWidget(
          App(
            mixSettings: testMixSettings(pinned),
            repository: pinned,
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
        ticker.add(null);
        await tester.pump();

        // Unplug: the standing banner.
        engine.nextSnapshot = snapshot(devicePresent: false);
        ticker.add(null);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(deviceBanner), findsOneWidget);

        // The device reappears and the engine reopens, keeping every loop but
        // track 3's (an edit on it was still pending at the loss).
        engine
          ..devices = const [
            le.AudioDevice(
              id: 'out-1',
              name: 'Scarlett 2i2',
              isDefault: false,
              isInput: false,
            ),
          ]
          ..reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retainedPartial,
            droppedTracks: 1 << 2,
          );
        reconnectTicker.add(null);
        await tester.pump();
        expect(engine.reopenCalls, 1);
        expect(pinned.state.status.reopen?.droppedChannels, [2]);
        engine.nextSnapshot = snapshot(devicePresent: true);
        ticker.add(null);
        await tester.pump();
        await tester.pump();

        final audioSetup = tester
            .element(find.byType(TracksView))
            .read<AudioSetupCubit>();
        expect(
          audioSetup.state.deviceConnectivity,
          DeviceConnectivity.restoredPartial,
        );
        expect(find.byKey(deviceBanner), findsNothing);
        expect(find.byKey(materialBanner), findsNothing);
        expect(debugAppToastActive(AppToastId.deviceRestoredPartial), isTrue);
        expect(debugAppToastActive(AppToastId.deviceRestored), isFalse);
        // Retire the warning toast before the next episode (its auto-close
        // runs on the overlay the harness does not render), so a re-raise
        // below would register anew.
        dismissAppToast(AppToastId.deviceRestoredPartial, animate: false);
        await tester.pump(const Duration(seconds: 12));
        expect(debugAppToastActive(AppToastId.deviceRestoredPartial), isFalse);

        // A later return the backend produces on its own (present 0 then 1,
        // no reconnect tick, nothing reopened) is a plain restore: the stale
        // "tracks dropped" toast must not come back, and no bar appears
        // (#1167).
        engine.nextSnapshot = snapshot(devicePresent: false);
        ticker.add(null);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(deviceBanner), findsOneWidget);
        engine.nextSnapshot = snapshot(devicePresent: true);
        ticker.add(null);
        await tester.pump();
        await tester.pump();
        expect(engine.reopenCalls, 1);
        expect(find.byKey(deviceBanner), findsNothing);
        expect(find.byKey(materialBanner), findsNothing);
        expect(debugAppToastActive(AppToastId.deviceRestoredPartial), isFalse);
        expect(debugAppToastActive(AppToastId.deviceRestored), isTrue);

        await tester.pump(const Duration(seconds: 12));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
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
        when(() => source.messages).thenAnswer(
          (_) => const Stream<MidiInputMessage>.empty(),
        );
        when(() => source.open(any())).thenReturn(0);
        when(source.close).thenReturn(0);

        final midi = MidiDeviceRepository(
          source: source,
          settings: settings,
          pollInterval: Duration.zero,
        );
        // Pin the controller present before the app builds, so the shell's
        // MidiSetupCubit subscribes to a healthy connection.
        await midi.select('fcb1010');

        final windowService = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            mixSettings: testMixSettings(repository, settings: settings),
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
        // Let the page cancel its subscriptions before the borrowed device
        // repository's teardown waits for its connection stream to close.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await midi.dispose();
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
            mixSettings: testMixSettings(repository, settings: settings),
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

    testWidgets('a shutdown phase change reaches an otherwise idle readout', (
      tester,
    ) async {
      // Construct the writer under the widget clock so startup completes here.
      settings = SettingsRepository(store: FakeKeyValueStore());
      final windowService = _RecordingWindowService();
      var haltCalls = 0;
      await pumpApp(tester, windowService, powerOff: () async => haltCalls++);
      await tester.pump(const Duration(milliseconds: 40));
      expect(windowService.readouts.last.goodbye, ReadoutGoodbye.none);

      final power =
          tester.element(find.byType(LooperPage)).read<PowerOffCubit>()
            ..press(const PowerOffSnapshot());
      await tester.pump(const Duration(milliseconds: 40));
      expect(power.state.phase, PowerOffPhase.goodbye);
      expect(windowService.readouts.last.goodbye, ReadoutGoodbye.mark);
      await tester.pump(const Duration(seconds: 2));
      expect(haltCalls, 1);
    });

    testWidgets('a failed readout is retried while the rig remains idle', (
      tester,
    ) async {
      final window = _RecordingWindowService()..failNextReadoutPushes = 1;
      await pumpApp(tester, window);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(window.readouts.length, greaterThanOrEqualTo(2));
      expect(window.deliveredReadouts, isNotEmpty);
      expect(window.deliveredReadouts.last, window.readouts.first);
    });

    testWidgets('a late failed readout cannot invalidate a newer delivery', (
      tester,
    ) async {
      final window = _RecordingWindowService();
      await pumpApp(tester, window);
      await tester.pump(const Duration(milliseconds: 40));
      final control = tester
          .element(find.byType(LooperPage))
          .read<ControlCubit>();
      window
        ..failNextReadoutPushes = 1
        ..readoutFailDelay = const Duration(milliseconds: 200);
      control.setMode(InteractionMode.fx);
      await tester.pump(const Duration(milliseconds: 40));
      control.setMode(InteractionMode.record);
      await tester.pump(const Duration(milliseconds: 40));
      final composed = window.readouts.length;
      expect(window.deliveredReadouts.last.mode, 'record');
      await tester.pump(const Duration(milliseconds: 300));
      expect(window.readouts, hasLength(composed));
      expect(window.deliveredReadouts.last.mode, 'record');
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
    });

    group('the gate under a PLAYING rig', () {
      // The case that matters, and the one an idle rig cannot show. A loop
      // that is merely playing publishes a NEW `LooperState` on every single
      // poll: the master playhead advances on the transport and every track's
      // `peak` moves, and both are part of `LooperState ==`, so the poll's
      // `next == _last` dedupe never suppresses anything. A gate written as
      // `identical(state, previous)` therefore falls through on every tick
      // and rebuilds the readout 30x/s — in exactly the performing case it
      // was written to spare.
      //
      // The repair is NOT to drop `peak` from `Track`'s equality: the meters
      // are fed through it, and they would all go flat with no error. The
      // gate narrows to what the readout draws instead — which is neither the
      // playhead nor the levels.
      le.EngineSnapshot playing({
        required int position,
        required double peak,
        bool muted = false,
        le.TrackState state = le.TrackState.playing,
        int inputChannel = 0,
        int lengthFrames = 96000,
        int sampleRate = 48000,
        int masterLengthFrames = 96000,
        int loopBars = 0,
        double tempoBpm = 0,
        TempoSource tempoSource = TempoSource.none,
        int tsNum = 4,
        List<le.TrackSnapshot>? tracks,
      }) => le.EngineSnapshot(
        isRunning: true,
        sampleRate: sampleRate,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        devicePresent: true,
        masterLengthFrames: masterLengthFrames,
        masterPositionFrames: position,
        loopBars: loopBars,
        tempoBpm: tempoBpm,
        tempoSource: tempoSource,
        tsNum: tsNum,
        tracks:
            tracks ??
            [
              le.TrackSnapshot(
                state: state,
                volume: 0.8,
                muted: muted,
                lengthFrames: lengthFrames,
                // The selected track's own playhead is what the second screen
                // follows; a plain track's equals the master's.
                positionFrames: position,
                undoDepth: 0,
                rms: peak / 2,
                peak: peak,
                lanes: [
                  le.LaneSnapshot(
                    inputChannel: inputChannel,
                    outputMask: 3,
                    volume: 1,
                    muted: false,
                    lengthFrames: 96000,
                    rms: 0,
                    peak: 0,
                  ),
                ],
              ),
            ],
      );

      /// Boots the app on a repository whose poll the test drives by hand.
      Future<({_RecordingWindowService window, StreamController<void> ticker})>
      pumpPlaying(
        WidgetTester tester, {
        le.EngineSnapshot? snapshot,
      }) async {
        final ticker = StreamController<void>.broadcast();
        addTearDown(() => unawaited(ticker.close()));
        final driven = LooperRepository(engine: engine, ticker: ticker.stream);
        addTearDown(driven.dispose);
        engine.nextSnapshot = snapshot ?? playing(position: 0, peak: 0.1);

        final window = _RecordingWindowService();
        await tester.pumpWidget(
          App(
            mixSettings: testMixSettings(driven),
            repository: driven,
            controllerRepository: controllerRepository,
            midiDeviceRepository: midiDeviceRepository,
            settings: settings,
            waveformWindow: window,
            sessionRepository: sessionRepository,
            performanceRepository: performanceRepository,
            exportDirectory: () async => '.',
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 40));
        return (window: window, ticker: ticker);
      }

      testWidgets('a moving playhead and moving levels compose nothing', (
        tester,
      ) async {
        final rig = await pumpPlaying(tester);
        expect(rig.window.readouts, isNotEmpty);
        final composed = rig.window.readouts.length;

        // Twenty polls of a loop going round: a fresh projection every time,
        // and not one fact the readout draws among the differences.
        for (var i = 1; i <= 20; i++) {
          engine.nextSnapshot = playing(
            position: i * 4000,
            peak: 0.1 + i / 100,
          );
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
        }

        expect(
          rig.window.readouts.length,
          composed,
          reason:
              'the readout was recomposed for a moving playhead and moving '
              'levels — the gate is comparing whole LooperStates again',
        );
      });

      testWidgets('a growing take composes nothing either', (tester) async {
        // While a take records, `lengthFrames` is the write head and grows
        // every poll. The readout draws the state, not the length, so the
        // gate must not reopen on it.
        final rig = await pumpPlaying(tester);
        engine.nextSnapshot = playing(
          position: 0,
          peak: 0.1,
          state: le.TrackState.recording,
          lengthFrames: 4000,
        );
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        final composed = rig.window.readouts.length;
        expect(rig.window.readouts.last.selected!.state, 'recording');

        for (var i = 2; i <= 20; i++) {
          engine.nextSnapshot = playing(
            position: i * 4000,
            peak: 0.2,
            state: le.TrackState.recording,
            lengthFrames: i * 4000,
          );
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(
          rig.window.readouts.length,
          composed,
          reason: 'the readout was recomposed for a growing take',
        );
      });

      testWidgets("the selected track's waveform is copied once per lap, "
          'not once per poll', (tester) async {
        // The repository owns the copy (see `readTrackWaveform`): a merely
        // playing track is re-read at each wrap, not at each frame the
        // second display is sent.
        final rig = await pumpPlaying(tester);
        // Sweep one full lap after the take was first seen at position 0.
        for (var i = 1; i <= 11; i++) {
          engine.nextSnapshot = playing(position: i * 8000, peak: 0.2);
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
        }
        engine.nextSnapshot = playing(position: 4000, peak: 0.2);
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));

        final frames = rig.window.pushCalls;
        final reads = engine.trackVisualReads;
        for (var i = 1; i <= 10; i++) {
          engine.nextSnapshot = playing(position: 4000 + i * 8000, peak: 0.2);
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(rig.window.pushCalls, greaterThan(frames));
        expect(
          engine.trackVisualReads,
          reads,
          reason:
              'a swept, merely playing track was copied out of the engine '
              'again mid-lap',
        );

        // The wrap re-reads: the engine has rewritten the buffer once more.
        engine.nextSnapshot = playing(position: 2000, peak: 0.2);
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        expect(engine.trackVisualReads, reads + 1);
      });

      testWidgets('equal-name selection sends each track waveform and its '
          'own phase; an empty selection sends silence', (tester) async {
        final waveformEngine = _WaveformAudioEngine();
        waveformEngine.trackSamples.addAll({
          0: Float32List.fromList([0.125, 0.5, 0.25]),
          1: Float32List.fromList([0.75, 0.25, 0.625, 0.125]),
        });
        engine = waveformEngine;
        final rig = await pumpPlaying(
          tester,
          snapshot: playing(
            position: 12000, // Master phase 1/8 differs from both tracks.
            peak: 0.1,
            tracks: const [
              le.TrackSnapshot(
                state: le.TrackState.playing,
                volume: 0.8,
                muted: false,
                lengthFrames: 96000,
                positionFrames: 24000,
                undoDepth: 0,
                rms: 0.1,
                peak: 0.2,
              ),
              le.TrackSnapshot(
                state: le.TrackState.playing,
                volume: 0.8,
                muted: false,
                lengthFrames: 192000,
                positionFrames: 144000,
                undoDepth: 0,
                rms: 0.1,
                peak: 0.2,
              ),
              le.TrackSnapshot.empty(),
            ],
          ),
        );
        expect(rig.window.waveforms.last.samples, [0.125, 0.5, 0.25]);
        expect(rig.window.waveforms.last.progress, closeTo(0.25, 1e-9));
        final tracks = tester
            .element(find.byType(LooperPage))
            .read<TracksCubit>();
        await tracks.rename(1, tracks.state.nameOf(0));
        await tester.pump(const Duration(milliseconds: 100));
        final frames = rig.window.pushCalls;

        tester
            .element(find.byType(LooperPage))
            .read<ControlCubit>()
            .selectTrack(1);
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          rig.window.pushCalls,
          greaterThan(frames),
          reason:
              'the label matched, so the cursor move never reached the '
              'second screen',
        );
        expect(rig.window.waveforms.last.selectedTrack, tracks.state.nameOf(0));
        expect(rig.window.waveforms.last.samples, [0.75, 0.25, 0.625, 0.125]);
        expect(rig.window.waveforms.last.progress, closeTo(0.75, 1e-9));

        tester
            .element(find.byType(LooperPage))
            .read<ControlCubit>()
            .selectTrack(2);
        await tester.pump(const Duration(milliseconds: 100));
        expect(rig.window.waveforms.last.selectedTrack, tracks.state.nameOf(2));
        expect(rig.window.waveforms.last.samples, isEmpty);
        expect(rig.window.waveforms.last.progress, 0);
      });

      testWidgets('a fact the readout DOES draw still gets through', (
        tester,
      ) async {
        final rig = await pumpPlaying(tester);
        expect(rig.window.readouts.last.selected!.muted, isFalse);

        // Muted rides the readout, so this must survive the narrowing that
        // drops the playhead and the levels.
        engine.nextSnapshot = playing(position: 8000, peak: 0.9, muted: true);
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));

        expect(
          rig.window.readouts.last.selected!.muted,
          isTrue,
          reason: 'the gate swallowed a fact the second screen draws',
        );
      });

      testWidgets('completed duration and established grid changes refresh '
          'the selected bar count', (tester) async {
        final rig = await pumpPlaying(
          tester,
          snapshot: playing(position: 0, peak: 0.1, loopBars: 1),
        );
        expect(rig.window.readouts.last.selected!.bars, 1);

        // Same state and multiple: only the completed duration changes.
        engine.nextSnapshot = playing(
          position: 0,
          peak: 0.1,
          loopBars: 1,
          lengthFrames: 192000,
        );
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        expect(rig.window.readouts.last.selected!.bars, 2);

        engine.nextSnapshot = playing(
          position: 0,
          peak: 0.1,
          loopBars: 1,
          masterLengthFrames: 192000,
          lengthFrames: 192000,
        );
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        expect(rig.window.readouts.last.selected!.bars, 1);

        engine.nextSnapshot = playing(
          position: 0,
          peak: 0.1,
          loopBars: 3,
          masterLengthFrames: 192000,
          lengthFrames: 192000,
        );
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        expect(rig.window.readouts.last.selected!.bars, 3);
      });

      testWidgets('without a master loop the selected bars follow tempo, '
          'signature and sample rate availability', (tester) async {
        le.EngineSnapshot snapshot({
          double bpm = 120,
          int numerator = 4,
          int sampleRate = 48000,
          TempoSource source = TempoSource.manual,
        }) => playing(
          position: 0,
          peak: 0.1,
          masterLengthFrames: 0,
          tempoBpm: bpm,
          tempoSource: source,
          tsNum: numerator,
          sampleRate: sampleRate,
        );
        final rig = await pumpPlaying(tester, snapshot: snapshot());
        expect(rig.window.readouts.last.selected!.bars, 1);

        Future<void> publish(le.EngineSnapshot next, int bars) async {
          engine.nextSnapshot = next;
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
          expect(rig.window.readouts.last.selected!.bars, bars);
        }

        await publish(snapshot(bpm: 240), 2);
        await publish(snapshot(bpm: 240, numerator: 2), 4);
        await publish(snapshot(bpm: 240, numerator: 2, sampleRate: 96000), 2);
        await publish(
          snapshot(
            bpm: 240,
            numerator: 2,
            sampleRate: 96000,
            source: TempoSource.none,
          ),
          0,
        );
        await publish(snapshot(bpm: 240, numerator: 2, sampleRate: 96000), 2);
        await publish(snapshot(bpm: 240, numerator: 2, sampleRate: 0), 0);
        await publish(snapshot(bpm: 240, numerator: 2, sampleRate: 96000), 2);
      });

      testWidgets('the recording state reaches the readout', (tester) async {
        final rig = await pumpPlaying(tester);
        final before = rig.window.readouts.last;
        engine.nextSnapshot = playing(
          position: 0,
          peak: 0.1,
          state: le.TrackState.recording,
        );
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 40));
        expect(rig.window.readouts.last.selected!.state, 'recording');
        expect(rig.window.readouts.last.mode, before.mode);
      });

      testWidgets('a burst of polls is rate-limited but never DROPPED', (
        tester,
      ) async {
        // The rate limit is not a decimator, and the difference is the whole
        // point: `looperState` is deduped, so an emit is a CHANGE, not a
        // tick. A rig that stops, clears or undoes emits once and then goes
        // quiet — drop that one and the second screen keeps the pre-stop
        // playhead until something else happens to move.
        final rig = await pumpPlaying(tester);
        final frames = rig.window.pushCalls;

        // Two changes inside one frame period: the first opens the frame, the
        // second arrives with the gate shut.
        engine.nextSnapshot = playing(position: 24000, peak: 0.3);
        rig.ticker.add(null);
        await tester.pump();
        engine.nextSnapshot = playing(position: 48000, peak: 0.4);
        rig.ticker.add(null);
        await tester.pump();

        expect(
          rig.window.pushCalls - frames,
          1,
          reason: 'the rate limit let a burst through unthrottled',
        );

        // ...and the held one lands on the trailing edge, carrying the LAST
        // state rather than the one that happened to arrive on an even tick.
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          rig.window.waveforms.last.progress,
          closeTo(0.5, 1e-9),
          reason: 'a change was swallowed instead of held — 48000/96000',
        );
      });

      testWidgets('a cursor move reaches the window on a SILENT rig', (
        tester,
      ) async {
        // Nothing is added to the ticker here on purpose: the poll is deduped
        // and this rig is not moving, so it emits nothing at all. The label
        // is not looper state, so if the timer does not carry it the second
        // screen keeps naming the wrong track indefinitely.
        final rig = await pumpPlaying(tester);
        final before = rig.window.waveforms.last.selectedTrack;

        tester
            .element(find.byType(LooperPage))
            .read<ControlCubit>()
            .selectTrack(1);
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          rig.window.waveforms.last.selectedTrack,
          isNot(before),
          reason: 'the cursor moved and the second screen never heard about it',
        );
      });

      testWidgets('a frame lost in flight is re-sent on a still rig', (
        tester,
      ) async {
        // Frames are produced by events now, not by a timer, so a lost one
        // has nothing behind it: the poll is deduped and this rig stops
        // moving after the single change below. The old unconditional 33 ms
        // push healed this implicitly; the re-queue is what replaces it.
        final rig = await pumpPlaying(tester);
        final frames = rig.window.pushCalls;
        rig.window.failNextWaveformPushes = 1;

        engine.nextSnapshot = playing(position: 24000, peak: 0.3);
        rig.ticker.add(null);
        await tester.pump();
        expect(rig.window.pushCalls - frames, 1);

        await tester.pump(const Duration(milliseconds: 100));
        expect(
          rig.window.pushCalls - frames,
          greaterThan(1),
          reason: 'a dropped frame was never re-sent, and nothing else would',
        );
        expect(
          rig.window.waveforms.last.progress,
          closeTo(0.25, 1e-9),
          reason: 'the re-sent frame carried the wrong state — 24000/96000',
        );
      });

      testWidgets('a late failure never re-sends a superseded frame', (
        tester,
      ) async {
        final rig = await pumpPlaying(tester);
        rig.window
          ..failNextWaveformPushes = 1
          ..failDelay = const Duration(milliseconds: 200);

        // Frame A goes out and will reject long after the fact.
        engine.nextSnapshot = playing(position: 24000, peak: 0.3);
        rig.ticker.add(null);
        await tester.pump();

        // Frame B lands cleanly in the meantime.
        engine.nextSnapshot = playing(position: 72000, peak: 0.5);
        rig.ticker.add(null);
        await tester.pump(const Duration(milliseconds: 60));
        expect(rig.window.waveforms.last.progress, closeTo(0.75, 1e-9));

        // A's rejection arrives. Re-sending it now would put an older
        // playhead on screen as the last word — and this rig has gone quiet,
        // so nothing would ever correct it.
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          rig.window.waveforms.last.progress,
          closeTo(0.75, 1e-9),
          reason: 'a stale frame was re-sent over a newer one that had landed',
        );
      });

      testWidgets('a re-announced window is re-seeded with a frame', (
        tester,
      ) async {
        // The service clears its own send diffs on the ready ping, but a
        // waveform frame is only produced by an EVENT and this rig is not
        // moving — so without an explicit request the reclaimed window shows
        // an empty waveform beside a live readout, indefinitely.
        final rig = await pumpPlaying(tester);
        final frames = rig.window.pushCalls;
        final readouts = rig.window.readouts.length;

        rig.window.onWindowReady!();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          rig.window.pushCalls,
          greaterThan(frames),
          reason: 'a reclaimed window was never sent a waveform frame',
        );
        expect(
          rig.window.readouts.length,
          greaterThan(readouts),
          reason: 'a reclaimed window was never re-sent the readout',
        );
      });

      testWidgets('the waveform keeps following the poll', (tester) async {
        final rig = await pumpPlaying(tester);
        final frames = rig.window.pushCalls;

        for (var i = 1; i <= 10; i++) {
          engine.nextSnapshot = playing(position: i * 4000, peak: 0.2);
          rig.ticker.add(null);
          await tester.pump(const Duration(milliseconds: 40));
        }

        expect(
          rig.window.pushCalls,
          greaterThan(frames),
          reason:
              "the waveform must keep ticking — the gate is the readout's "
              'alone, and a frozen waveform means the playhead died',
        );
      });
    });

    testWidgets(
      'shows the audio-recovery banner when booted with the pinned '
      'device absent',
      (tester) async {
        // The fake engine reports stopped with no devices, so the pinned config
        // is absent and the recovery cubit waits (and would auto-start on
        // arrival). pump (not pumpAndSettle) — the cubit holds a periodic poll.
        await tester.pumpWidget(
          App(
            mixSettings: testMixSettings(repository, settings: settings),
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
