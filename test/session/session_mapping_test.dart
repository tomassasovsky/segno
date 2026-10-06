import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session_mapping.dart';
// The chains a performance arm records cross the boundary as ENGINE models
// (the manifest embeds them as canonical JSON), so the assertions on them name
// the engine types under an `le` prefix — everything else here is domain.
import 'package:segno_engine/segno_engine.dart'
    as le
    show
        BuiltInEffect,
        LatencyState,
        PluginEffect,
        PluginFormat,
        TrackEffectType;
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, HistoryEntry, HistoryKind, LaneSnapshot, TrackSnapshot;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  test(
    'pair image and untouched fader survive a file save and recall',
    () async {
      final empty = EngineSnapshot(
        isRunning: true,
        devicePresent: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        inputChannels: 2,
        outputChannels: 2,
        tracks: List.generate(8, (_) => const TrackSnapshot.empty()),
      );
      final engine = FakeAudioEngine()..nextSnapshot = empty;
      final ticker = StreamController<void>.broadcast();
      final looper = LooperRepository(engine: engine, ticker: ticker.stream)
        ..startEngine(const EngineConfig(sampleRate: 48000));
      final directory = Directory.systemTemp.createTempSync(
        'session_pair_image',
      );
      addTearDown(ticker.close);
      addTearDown(looper.dispose);
      addTearDown(() => directory.deleteSync(recursive: true));

      expect(looper.setInputPair(input: 0, paired: true), EngineResult.ok);
      expect(looper.setPairBalance(input: 0, balance: 2 / 3), EngineResult.ok);
      expect(looper.record(), EngineResult.ok);
      expect(engine.laneVol[(0, 0)], closeTo(0.5, 1e-6));

      final pcm = Float32List.fromList([0.4, 0.4, 0.4, 0.4]);
      engine.laneExports[(0, 0)] = pcm;
      engine.nextSnapshot = EngineSnapshot(
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
        inputChannels: 2,
        outputChannels: 2,
        masterLengthFrames: 4,
        tracks: [
          const TrackSnapshot(
            state: TrackState.playing,
            volume: 0.5,
            muted: false,
            lengthFrames: 4,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            lanes: [
              LaneSnapshot(
                inputChannel: 0,
                outputMask: 3,
                volume: 0.5,
                muted: false,
                lengthFrames: 4,
                rms: 0,
                peak: 0,
                pan: -1,
              ),
            ],
          ),
          for (var channel = 1; channel < 8; channel++)
            const TrackSnapshot.empty(),
        ],
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      final live = looper.state.tracks.first.lanes.single;
      expect(live.volume, 1);
      expect(live.balance, closeTo(0.5, 1e-6));
      final files = SessionRepository(guards: GuardRegistry(), engine: engine);
      await files.save(
        directory.path,
        chains: chainsFromLooper(
          looper,
          projection: FxChainPersistence(looper: looper),
        ),
        settings: settingsFromLooper(
          looper,
          fade: FadeDurations.defaults,
          recordStart: RecordStartSettings(countInBars: 0, soundStart: false),
          clickMode: looper.sessionTransport.clickMode,
          recordTiming: RecordTimingSnapshot(
            defaultTiming: looper.defaultRecordTiming,
            rememberedDivision: looper.sessionTransport.quantizeDiv,
            trackOverrides: looper.trackRecordTimingOverrides,
            captureLocked: false,
          ),
          recordLength: RecordLengthSnapshot(
            defaultBars: looper.sessionTransport.defaultLengthPresetBars,
            trackOverrides: looper.trackLengthPresetOverrides,
            mode: looper.sessionTransport.looperMode,
            captureLocked: false,
          ),
          clickVolume: 1,
          decay: DecaySnapshot(
            defaultPercent: looper.defaultOverdubDecay,
            trackOverrides: looper.trackOverdubDecayOverrides,
          ),
          oneShot: OneShotSnapshot(
            defaultOneShot: looper.defaultOneShot,
            trackOverrides: looper.trackOneShotOverrides,
          ),
        ),
      );
      final manifest =
          jsonDecode(
                await File(
                  '${directory.path}/${Session.manifestName}',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final track =
          (manifest['tracks'] as List<dynamic>).single as Map<String, dynamic>;
      final savedLane =
          (track['lanes'] as List<dynamic>).single as Map<String, dynamic>;
      expect(savedLane['volume'], 1);
      expect(savedLane['balance'], closeTo(0.5, 1e-6));

      final bundle = await files.read(directory.path);
      expect(bundle.laneStems[(0, 0)]!.single.first, closeTo(0.4, 1e-6));
      final rig = rigFromBundle(bundle);
      final recalledEngine = FakeAudioEngine()..nextSnapshot = empty;
      final recalled = LooperRepository(engine: recalledEngine)
        ..startEngine(const EngineConfig(sampleRate: 48000));
      addTearDown(recalled.dispose);
      await recalled.applySession(rig, clearPollInterval: Duration.zero);
      expect(recalledEngine.laneVol[(0, 0)], closeTo(0.5, 1e-6));
      expect(
        recalledEngine.laneVol[(0, 0)]! *
            recalledEngine.exportLayer(0, 0, 0).first,
        closeTo(0.2, 1e-6),
      );
      // Reopening must clear the previous import before publishing this one.
      await recalled.applySession(rig, clearPollInterval: Duration.zero);
      expect(recalled.state.tracks.first.lengthFrames, 4);
      expect(recalledEngine.exportLayer(0, 0, 0), pcm);
      expect(recalledEngine.laneVol[(0, 0)], closeTo(0.5, 1e-6));
    },
  );

  group('settingsFromLooper', () {
    test('captures the exact published grid relationship', () {
      final looper = _MockLooperRepository();
      when(() => looper.sessionTransport).thenReturn(
        const TransportState(
          tempoBpm: 30,
          tempoSource: TempoSource.derived,
          loopBars: 7,
        ),
      );
      when(
        () => looper.defaultRecordTiming,
      ).thenReturn(RecordTiming.immediately);
      when(() => looper.defaultOverdubDecay).thenReturn(0);
      when(() => looper.defaultOneShot).thenReturn(false);
      when(() => looper.trackRecordTimingOverrides).thenReturn(const {});
      when(() => looper.trackOverdubDecayOverrides).thenReturn(const {});
      when(() => looper.trackOneShotOverrides).thenReturn(const {});
      when(() => looper.trackLengthPresetOverrides).thenReturn(const {});
      when(() => looper.state).thenReturn(const LooperState());
      when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
      expect(
        settingsFromLooper(
          looper,
          fade: FadeDurations.defaults,
          recordStart: RecordStartSettings(countInBars: 0, soundStart: false),
          clickMode: looper.sessionTransport.clickMode,
          recordTiming: RecordTimingSnapshot(
            defaultTiming: looper.defaultRecordTiming,
            rememberedDivision: looper.sessionTransport.quantizeDiv,
            trackOverrides: looper.trackRecordTimingOverrides,
            captureLocked: false,
          ),
          recordLength: RecordLengthSnapshot(
            defaultBars: looper.sessionTransport.defaultLengthPresetBars,
            trackOverrides: looper.trackLengthPresetOverrides,
            mode: looper.sessionTransport.looperMode,
            captureLocked: false,
          ),
          clickVolume: 1,
          decay: DecaySnapshot(
            defaultPercent: looper.defaultOverdubDecay,
            trackOverrides: looper.trackOverdubDecayOverrides,
          ),
          oneShot: OneShotSnapshot(
            defaultOneShot: looper.defaultOneShot,
            trackOverrides: looper.trackOneShotOverrides,
          ),
        ).loopBars,
        7,
      );
    });

    test(
      'stopped desired settings survive save, read, and rig mapping',
      () async {
        final engine = FakeAudioEngine();
        final looper = LooperRepository(engine: engine);
        final directory = Directory.systemTemp.createTempSync(
          'session_settings',
        );
        addTearDown(looper.dispose);
        addTearDown(() => directory.deleteSync(recursive: true));
        looper
          ..setTempo(117)
          ..setTimeSignature(7, 8)
          ..setSyncTempo(on: false)
          ..setRecordTiming(RecordTiming.eighth)
          ..setOverdubDecay(30)
          ..setOneShotSnapshot(
            defaultOneShot: true,
            trackOverrides: {0: false, 1: true},
          )
          ..setDefaultLengthPreset(8)
          ..setDefaultMultiple(multiple: 3)
          ..setRecDub(enabled: true)
          ..setClickMode(ClickMode.rec)
          ..setClickOutput(0x2)
          ..setClickVolume(0.6)
          ..setRecordStartSettings(
            countInBars: 2,
            soundStart: false,
            editKind: RecordStartEditKind.restore,
          )
          ..setLooperMode(LooperMode.free)
          ..setTrackRecordTiming(channel: 0, timing: RecordTiming.eighth)
          ..setTrackOverdubDecay(channel: 0, percent: 30)
          ..setTrackOverdubDecay(channel: 1, percent: 0)
          ..setTrackLengthPreset(channel: 0, bars: 4);
        expect(engine.snapshot().isRunning, isFalse);
        expect(engine.snapshot().tempoBpm, 0);
        final settings = settingsFromLooper(
          looper,
          fade: FadeDurations.defaults,
          recordStart: RecordStartSettings(countInBars: 2, soundStart: false),
          clickMode: looper.sessionTransport.clickMode,
          recordTiming: RecordTimingSnapshot(
            defaultTiming: looper.defaultRecordTiming,
            rememberedDivision: looper.sessionTransport.quantizeDiv,
            trackOverrides: looper.trackRecordTimingOverrides,
            captureLocked: false,
          ),
          recordLength: RecordLengthSnapshot(
            defaultBars: looper.sessionTransport.defaultLengthPresetBars,
            trackOverrides: looper.trackLengthPresetOverrides,
            mode: looper.sessionTransport.looperMode,
            captureLocked: false,
          ),
          clickVolume: .6,
          decay: DecaySnapshot(
            defaultPercent: looper.defaultOverdubDecay,
            trackOverrides: looper.trackOverdubDecayOverrides,
          ),
          oneShot: OneShotSnapshot(
            defaultOneShot: looper.defaultOneShot,
            trackOverrides: looper.trackOneShotOverrides,
          ),
        );
        final repository = SessionRepository(
          guards: GuardRegistry(),
          engine: engine,
        );
        await repository.save(directory.path, settings: settings);
        final rig = rigFromBundle(await repository.read(directory.path));
        expect(rig.tracks, isEmpty);
        expect(rig.tempoBpm, 117);
        expect(rig.tempoSource, TempoSource.manual);
        expect(rig.tsNum, 7);
        expect(rig.tsDen, 8);
        expect(rig.syncTempo, isFalse);
        expect(rig.quantizeDiv, GridDivision.eighth);
        expect(rig.recordTiming, RecordTiming.eighth);
        expect(rig.overdubDecay, 30);
        expect(rig.defaultOneShot, isTrue);
        expect(rig.defaultLengthPresetBars, 8);
        expect(rig.defaultMultiple, 3);
        expect(rig.recDub, isTrue);
        expect(rig.autoRecord, isFalse);
        expect(rig.clickMode, ClickMode.rec);
        expect(rig.clickMask, 0x2);
        expect(rig.clickVolume, 0.6);
        expect(rig.countInBars, 2);
        expect(rig.looperMode, LooperMode.free);
        expect(rig.primaryTrack, -1);
        expect(rig.trackRecordTimingOverrides, {0: RecordTiming.eighth});
        expect(rig.trackOverdubDecayOverrides, {0: 30, 1: 0});
        expect(rig.trackOneShotOverrides, {0: false, 1: true});
        expect(rig.trackLengthPresetOverrides, {0: 4});
        expect(rig.trackPans, isEmpty);

        looper
          ..setTrackRecordTiming(channel: 0, timing: null)
          ..setTrackOverdubDecay(channel: 0, percent: null)
          ..setOneShotSnapshot(defaultOneShot: true, trackOverrides: {1: true})
          ..setTrackLengthPreset(channel: 0, bars: null)
          ..setRecordStartSettings(
            countInBars: 0,
            soundStart: true,
            editKind: RecordStartEditKind.restore,
          );
        final inherited = settingsFromLooper(
          looper,
          fade: FadeDurations.defaults,
          recordStart: RecordStartSettings(countInBars: 0, soundStart: true),
          clickMode: looper.sessionTransport.clickMode,
          recordTiming: RecordTimingSnapshot(
            defaultTiming: looper.defaultRecordTiming,
            rememberedDivision: looper.sessionTransport.quantizeDiv,
            trackOverrides: looper.trackRecordTimingOverrides,
            captureLocked: false,
          ),
          recordLength: RecordLengthSnapshot(
            defaultBars: looper.sessionTransport.defaultLengthPresetBars,
            trackOverrides: looper.trackLengthPresetOverrides,
            mode: looper.sessionTransport.looperMode,
            captureLocked: false,
          ),
          clickVolume: 1,
          decay: DecaySnapshot(
            defaultPercent: looper.defaultOverdubDecay,
            trackOverrides: looper.trackOverdubDecayOverrides,
          ),
          oneShot: OneShotSnapshot(
            defaultOneShot: looper.defaultOneShot,
            trackOverrides: looper.trackOneShotOverrides,
          ),
        );
        expect(inherited.trackRecordTimingOverrides, isEmpty);
        expect(inherited.trackOverdubDecayOverrides, {1: 0});
        expect(inherited.trackOneShotOverrides, {1: true});
        expect(inherited.trackLengthPresetOverrides, isEmpty);
        expect(inherited.autoRecord, isTrue);
        expect(inherited.countInBars, 0);
        // A previously captured payload does not change as the rig is edited.
        expect(settings.trackRecordTimingOverrides, {0: RecordTiming.eighth});
        expect(settings.trackOverdubDecayOverrides, {0: 30, 1: 0});
        expect(settings.trackOneShotOverrides, {0: false, 1: true});
        expect(settings.trackLengthPresetOverrides, {0: 4});
      },
    );
  });

  group('chainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(() => looper.sessionRevision).thenReturn(0);
      when(looper.allLaneChains).thenReturn(const {});
      when(looper.allTrackChains).thenReturn(const {});
      when(looper.allOutputChains).thenReturn(const {});
      when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
      when(looper.allMonitors).thenReturn(const {});
    });

    test('captures an enabled DRY monitor (no FX) as a SessionMonitor', () {
      // The regression: a monitor with no FX chain was dropped on save. It must
      // still be persisted so it round-trips instead of being disabled on load.
      when(looper.allMonitors).thenReturn(const {
        1: InputMonitor(input: 1, mode: MonitorMode.on, outputMask: 0x2),
      });

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      expect(chains.monitors, hasLength(1));
      final monitor = chains.monitors.single;
      expect(monitor.input, 1);
      expect(monitor.mode, 'on');
      expect(monitor.outputMask, 0x2);
      expect(monitor.volume, 1.0);
      expect(monitor.muted, isFalse);
      // A dry monitor encodes to the empty (enabled) envelope.
      expect(decodeFxChain(monitor.encoded), const FxChainEnvelope());
    });

    test('saves the monitor gate by its canonical mode', () {
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, mode: MonitorMode.auto),
        1: InputMonitor(input: 1, mode: MonitorMode.on),
        2: InputMonitor(input: 2),
      });

      final saved = {
        for (final m in chainsFromLooper(
          looper,
          projection: FxChainPersistence(looper: looper),
        ).monitors)
          m.input: m,
      };

      expect(saved[0]!.mode, 'auto');
      expect(saved[1]!.mode, 'on');
      expect(saved[2]!.mode, 'off');
    });

    test('carries a monitor FX chain through the encoding', () {
      when(looper.allMonitors).thenReturn({
        0: InputMonitor(
          input: 0,
          mode: MonitorMode.on,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      final decoded = decodeFxChain(chains.monitors.single.encoded).entries;
      expect((decoded.single as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('writes no monitor pan (slice 3): the load rebuilds it from the '
        'input setup', () {
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, mode: MonitorMode.on, pan: -1),
      });

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      expect(chains.monitors.single.toJson().containsKey('pan'), isFalse);
    });

    test('emits no monitors when none are configured', () {
      expect(
        chainsFromLooper(
          looper,
          projection: FxChainPersistence(looper: looper),
        ).monitors,
        isEmpty,
      );
    });

    test('encodes every stage as the chain ENVELOPE — chain flag, per-slot '
        'enabled bits and inheritance meta all inside the string (R15)', () {
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          chainEnabled: false,
          meta: const FxChainMeta(inheritedFrom: [1, 2]),
          entries: [
            BuiltInEffect(
              type: TrackEffectType.drive,
              enabled: false,
              slotId: 'aa-1',
            ),
          ],
        ),
      });
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, mode: MonitorMode.on, chainEnabled: false),
      });

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      final lane = decodeFxChain(chains.laneChains.single.encoded);
      expect(lane.chainEnabled, isFalse);
      expect(lane.meta?.inheritedFrom, [1, 2]);
      final laneFx = lane.entries.single as BuiltInEffect;
      expect(laneFx.enabled, isFalse);
      expect(laneFx.slotId, 'aa-1');
      // A dry monitor whose chain flag is off still persists that flag — the
      // one place it can live is the envelope (no per-flag settings key).
      expect(decodeFxChain(chains.monitors.single.encoded).chainEnabled, false);
    });

    test('the All tracks chain round-trips as an envelope, and a rig with '
        'none writes the empty-string spelling (slice 3e)', () {
      when(looper.allTracksChainEnvelope).thenReturn(
        FxChainEnvelope(entries: [BuiltInEffect(type: TrackEffectType.reverb)]),
      );

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );
      expect(chains.allTracksChain, isNotEmpty);
      expect(
        decodeFxChain(chains.allTracksChain).entries.single,
        BuiltInEffect(type: TrackEffectType.reverb),
      );

      // A rig with no All tracks state writes the manifest's one way to say
      // "empty", the Master rule exactly.
      when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
      expect(
        chainsFromLooper(
          looper,
          projection: FxChainPersistence(looper: looper),
        ).allTracksChain,
        '',
      );
    });

    test('captures Track and destination output chains as envelopes', () {
      when(looper.allTrackChains).thenReturn({
        1: FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });
      when(looper.allOutputChains).thenReturn({
        0: FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
      });

      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      expect(chains.trackChains.single.channel, 1);
      final track = decodeFxChain(chains.trackChains.single.encoded);
      expect(track.chainEnabled, isFalse);
      expect(
        (track.entries.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
      final output = decodeFxChain(chains.outputChains.single.encoded);
      expect(chains.outputChains.single.bus, 0);
      expect(output.chainEnabled, isTrue);
      expect(
        (output.entries.single as BuiltInEffect).type,
        TrackEffectType.filter,
      );
    });

    test('omits unconfigured output chains from the manifest', () {
      final chains = chainsFromLooper(
        looper,
        projection: FxChainPersistence(looper: looper),
      );

      expect(chains.trackChains, isEmpty);
      expect(chains.outputChains, isEmpty);
    });
  });

  group('performanceChainsFromLooper', () {
    late LooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(looper.allLaneChains).thenReturn(const {});
      when(looper.allTrackChains).thenReturn(const {});
      when(looper.allOutputChains).thenReturn(const {});
      when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
      when(looper.allMonitors).thenReturn(const {});
      when(() => looper.limiterEnabled).thenReturn(true);
      when(() => looper.limiterCeiling).thenReturn(0.99);
    });

    test('maps every lane chain to its (channel, lane) address', () {
      when(looper.allLaneChains).thenReturn({
        (0, 1): FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
        (2, 0): FxChainEnvelope(
          entries: [BuiltInEffect(type: TrackEffectType.delay)],
        ),
      });

      final chains = performanceChainsFromLooper(looper);

      expect(
        chains.laneChains.map((c) => (c.channel, c.lane)),
        containsAll(<(int, int)>[(0, 1), (2, 0)]),
      );
    });

    test('carries built-in effect params across the engine boundary', () {
      // The manifest embeds the ENGINE models as canonical JSON, so the
      // per-effect params must survive the domain → engine conversion intact.
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          entries: [
            BuiltInEffect(
              type: TrackEffectType.octaver,
              params: const [7, 0.5],
            ),
          ],
        ),
      });

      final effects = performanceChainsFromLooper(
        looper,
      ).laneChains.single.effects;

      final effect = effects.single as le.BuiltInEffect;
      expect(effect.type, le.TrackEffectType.octaver);
      expect(effect.params, [7, 0.5]);
    });

    test('carries a plugin entry ref, state and name across the boundary', () {
      when(looper.allLaneChains).thenReturn({
        (1, 0): const FxChainEnvelope(
          entries: [
            PluginEffect(
              ref: PluginRef(
                format: PluginFormat.vst3,
                id: 'com.example.chorus',
                version: 0x00020100,
              ),
              paramValues: {3: 0.25},
              state: 'YmFzZTY0',
              name: 'Chorus',
            ),
          ],
        ),
      });

      final effects = performanceChainsFromLooper(
        looper,
      ).laneChains.single.effects;

      final effect = effects.single as le.PluginEffect;
      expect(effect.ref.format, le.PluginFormat.vst3);
      expect(effect.ref.id, 'com.example.chorus');
      expect(effect.ref.version, 0x00020100);
      expect(effect.paramValues, {3: 0.25});
      expect(effect.state, 'YmFzZTY0');
      expect(effect.name, 'Chorus');
    });

    test('captures a monitor routing/mix and its chain', () {
      when(looper.allMonitors).thenReturn({
        1: InputMonitor(
          input: 1,
          mode: MonitorMode.on,
          outputMask: 0x2,
          volume: 0.75,
          muted: true,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });

      final monitor = performanceChainsFromLooper(looper).monitors.single;

      expect(monitor.input, 1);
      expect(monitor.enabled, isTrue);
      expect(monitor.outputMask, 0x2);
      expect(monitor.volume, 0.75);
      expect(monitor.muted, isTrue);
      expect(
        (monitor.effects.single as le.BuiltInEffect).type,
        le.TrackEffectType.reverb,
      );
    });

    test('captures an enabled DRY monitor (no FX)', () {
      // Same rule as the session save: the capture documents every configured
      // monitor, not just the ones carrying an FX chain.
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, mode: MonitorMode.on),
      });

      final monitor = performanceChainsFromLooper(looper).monitors.single;

      expect(monitor.input, 0);
      expect(monitor.enabled, isTrue);
      expect(monitor.effects, isEmpty);
    });

    test('records the BUS stages and every chain-enabled flag (R20/R3)', () {
      when(looper.allLaneChains).thenReturn({
        (0, 0): FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.drive)],
        ),
      });
      when(looper.allTrackChains).thenReturn({
        1: FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      });
      when(looper.allOutputChains).thenReturn({
        0: FxChainEnvelope(
          chainEnabled: false,
          entries: [
            BuiltInEffect(type: TrackEffectType.filter, enabled: false),
          ],
        ),
      });
      when(looper.allMonitors).thenReturn(const {
        0: InputMonitor(input: 0, mode: MonitorMode.on, chainEnabled: false),
      });

      final chains = performanceChainsFromLooper(looper);

      // A bypassed chain must replay bypassed, so every flag is recorded —
      // the manifest is the only place a replay can learn them from.
      expect(chains.laneChains.single.chainEnabled, isFalse);
      expect(chains.monitors.single.chainEnabled, isFalse);
      expect(chains.trackChains.single.channel, 1);
      expect(chains.trackChains.single.chainEnabled, isFalse);
      expect(
        (chains.trackChains.single.effects.single as le.BuiltInEffect).type,
        le.TrackEffectType.reverb,
      );
    });

    test('reads the real master-limiter state, even for an empty rig', () {
      final chains = performanceChainsFromLooper(looper);

      expect(chains.laneChains, isEmpty);
      expect(chains.monitors, isEmpty);
      // The bug this part fixes: an empty rig is fine, an empty LIMITER is
      // not — the engine cannot report it, so it comes from the repository.
      expect(chains.limiterEnabled, isTrue);
      expect(chains.limiterCeiling, 0.99);
    });
  });

  group('rigFromBundle', () {
    // Direct (always-on) coverage of `rigFromBundle`'s lane/track drop
    // branches — the env-var-gated round-trip test only covers the happy path.
    SessionLane lane(int index, String file) => SessionLane(
      lane: index,
      volume: 1,
      muted: false,
      outputMask: 0x3,
      inputChannel: index,
      layers: [SessionLayer(file: file)],
      history: TrackHistory.none,
    );

    Session sessionWith(List<SessionTrack> tracks) => Session(
      sampleRate: 48000,
      channels: 1,
      baseLengthFrames: 4,
      tracks: tracks,
    );

    test('maps bare-array FX payloads and current chain envelopes', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
      final bare = encodeTrackEffects([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      final envelope = encodeFxChain(
        FxChainEnvelope(
          chainEnabled: false,
          entries: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
      );
      final bundle = (
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          tracks: [
            SessionTrack(
              fadeAmount: 1,
              channel: 0,
              multiple: 1,
              lengthFrames: 4,
              lanes: [lane(0, 'track0_lane0_L0.wav')],
            ),
          ],
          laneChains: [
            SessionLaneChain(channel: 0, lane: 0, encoded: bare),
          ],
          monitors: [
            SessionMonitor(
              input: 0,
              mode: 'on',
              outputMask: 0x3,
              volume: 1,
              muted: false,
              encoded: envelope,
            ),
          ],
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );

      final rig = rigFromBundle(bundle);

      final laneChain = rig.laneChains[(0, 0)]!.entries;
      expect((laneChain.single as BuiltInEffect).type, TrackEffectType.drive);
      final monitorChain = rig.monitors.single.effects;
      expect(
        (monitorChain.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
    });

    test("the session's own defaults reach the rig, not just the per-track "
        'overrides', () {
      // A track whose override is null follows the DEFAULT. Carrying the
      // overrides across a load without the default they override leaves that
      // track on whatever the app was last set to.
      final rig = rigFromBundle((
        session: const Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          tracks: [],
          recordTiming: RecordTiming.quarter,
          overdubDecay: 40,
          loopBars: 7,
        ),
        laneStems: const {},
      ));

      expect(rig.recordTiming, RecordTiming.quarter);
      expect(rig.overdubDecay, 40);
      expect(rig.loopBars, 7);
    });

    test("a manifest that names no defaults still carries the model's own, "
        'so a load RESETS rather than inherits', () {
      // The same posture the FX stages take: a fact the manifest does not
      // describe is reset on apply, never left as whatever the live rig had.
      final rig = rigFromBundle((
        session: const Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          tracks: [],
        ),
        laneStems: const {},
      ));

      expect(rig.recordTiming, RecordTiming.immediately);
      expect(rig.overdubDecay, 0);
    });

    Session sessionWithMonitor(SessionMonitor monitor) => Session(
      sampleRate: 48000,
      channels: 1,
      baseLengthFrames: 4,
      tracks: const [],
      monitors: [monitor],
    );

    test('an AUTO monitor comes back auto, not on', () {
      // The bug: the manifest's gate was a boolean, so `auto` — follow the
      // record arm — saved as "enabled" and reloaded as `on`, monitoring
      // unconditionally. An input the player set to open only while arming
      // came back open all the time.
      final rig = rigFromBundle((
        session: sessionWithMonitor(
          const SessionMonitor(
            input: 0,
            mode: 'auto',
            outputMask: 0x3,
            volume: 1,
            muted: false,
            encoded: '',
          ),
        ),
        laneStems: const {},
      ));

      expect(rig.monitors.single.mode, MonitorMode.auto);
    });

    test('an unknown current-schema monitor mode is rejected', () {
      expect(
        () => rigFromBundle((
          session: sessionWithMonitor(
            const SessionMonitor(
              input: 0,
              mode: 'sidechain-from-2027',
              outputMask: 0x3,
              volume: 1,
              muted: false,
              encoded: '',
            ),
          ),
          laneStems: const {},
        )),
        throwsFormatException,
      );
    });

    test('decodes the v5 BUS stages into the rig, chain flags included', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
      final bundle = (
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          tracks: [
            SessionTrack(
              fadeAmount: 1,
              channel: 0,
              multiple: 1,
              lengthFrames: 4,
              lanes: [lane(0, 'track0_lane0_L0.wav')],
            ),
          ],
          trackChains: [
            SessionTrackChain(
              channel: 0,
              encoded: encodeFxChain(
                FxChainEnvelope(
                  chainEnabled: false,
                  entries: [BuiltInEffect(type: TrackEffectType.reverb)],
                ),
              ),
            ),
          ],
          outputChains: [
            SessionOutputChain(
              bus: 0,
              encoded: encodeFxChain(
                FxChainEnvelope(
                  entries: [BuiltInEffect(type: TrackEffectType.filter)],
                ),
              ),
            ),
          ],
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );

      final rig = rigFromBundle(bundle);

      final track = rig.trackChains[0]!;
      expect(track.chainEnabled, isFalse);
      expect(
        (track.entries.single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
      expect(rig.outputChains[0]!.chainEnabled, isTrue);
      expect(
        (rig.outputChains[0]!.entries.single as BuiltInEffect).type,
        TrackEffectType.filter,
      );
    });

    test(
      'a current Session with omitted bus chains maps empty stages '
      'and FX defaults',
      () {
        final pcm = Float32List.fromList([1, 1, 1, 1]);
        final bundle = (
          session: Session(
            sampleRate: 48000,
            channels: 1,
            baseLengthFrames: 4,
            tracks: [
              SessionTrack(
                fadeAmount: 1,
                channel: 0,
                multiple: 1,
                lengthFrames: 4,
                lanes: [lane(0, 'track0_lane0_L0.wav')],
              ),
            ],
            // The FX decoder handles bare-array payloads independently of
            // the schema-8 manifest reader.
            laneChains: [
              SessionLaneChain(
                channel: 0,
                lane: 0,
                encoded: encodeTrackEffects([
                  BuiltInEffect(type: TrackEffectType.drive),
                ]),
              ),
            ],
          ),
          laneStems: {
            (0, 0): [pcm],
          },
        );

        final rig = rigFromBundle(bundle);

        expect(rig.trackChains, isEmpty);
        expect(rig.outputChains, isEmpty);
        // The lane it DID describe loads enabled at both levels, with no
        // inheritance marker — and no slot ids yet (the repository mints
        // those).
        final loop = rig.laneChains[(0, 0)]!;
        expect(loop.chainEnabled, isTrue);
        expect(loop.meta, isNull);
        final loopFx = loop.entries.single as BuiltInEffect;
        expect(loopFx.enabled, isTrue);
        expect(loopFx.slotId, isNull);
      },
    );

    test('maps every lane that has decoded audio', () {
      final l0 = Float32List.fromList([1, 1, 1, 1]);
      final l1 = Float32List.fromList([2, 2, 2, 2]);
      final bundle = (
        session: sessionWith([
          SessionTrack(
            fadeAmount: 1,
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [
              lane(0, 'track0_lane0_L0.wav'),
              lane(1, 'track0_lane1_L0.wav'),
            ],
          ),
        ]),
        laneStems: {
          (0, 0): [l0],
          (0, 1): [l1],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.lanes, hasLength(2));
      expect(rig.tracks.single.lanes[0].livePcm, l0);
      expect(rig.tracks.single.lanes[1].livePcm, l1);
    });

    test('maps a multi-lane track with per-lane overdub history', () {
      // Two lanes, each a 3-layer stack (undo 1, live, redo 1) — the per-lane
      // layer zip must keep each lane's ordered layers, history and counts.
      const history = TrackHistory([
        HistoryEntry(HistoryKind.processed),
        HistoryEntry(HistoryKind.layer),
      ], undoCount: 1);
      SessionLane historyLane(int index, List<String> files) => SessionLane(
        lane: index,
        volume: 1,
        muted: false,
        outputMask: 0x3,
        inputChannel: index,
        history: history,
        layers: [for (final f in files) SessionLayer(file: f)],
      );
      final l0 = [
        Float32List.fromList([1]),
        Float32List.fromList([2]),
        Float32List.fromList([3]),
      ];
      final l1 = [
        Float32List.fromList([4]),
        Float32List.fromList([5]),
        Float32List.fromList([6]),
      ];
      final bundle = (
        session: sessionWith([
          SessionTrack(
            fadeAmount: 1,
            channel: 0,
            multiple: 1,
            lengthFrames: 1,
            lanes: [
              historyLane(0, ['t0_l0_L0.wav', 't0_l0_L1.wav', 't0_l0_L2.wav']),
              historyLane(1, ['t0_l1_L0.wav', 't0_l1_L1.wav', 't0_l1_L2.wav']),
            ],
          ),
        ]),
        laneStems: {(0, 0): l0, (0, 1): l1},
      );

      final rig = rigFromBundle(bundle);
      final lanes = rig.tracks.single.lanes;
      expect(lanes, hasLength(2));
      expect(lanes[0].layers, l0);
      expect(lanes[0].history, history);
      expect(lanes[0].undoCount, 1);
      expect(lanes[0].redoCount, 1);
      expect(lanes[0].liveIndex, 1);
      expect(lanes[1].layers, l1);
      expect(lanes[1].undoCount, 1);
      expect(lanes[1].livePcm, l1[1]);
    });

    test('keeps settings for recorded, empty, and dropped-audio tracks', () {
      final pcm = Float32List.fromList([1, 1, 1, 1]);
      final bundle = (
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 4,
          looperMode: LooperMode.band,
          primaryTrack: 0,
          recordTiming: RecordTiming.quarter,
          overdubDecay: 30,
          defaultOneShot: true,
          trackRecordTimingOverrides: const {
            0: RecordTiming.quarter,
            2: RecordTiming.bar,
          },
          trackOverdubDecayOverrides: const {0: 30, 2: 0},
          trackOneShotOverrides: const {0: true, 2: false},
          trackLengthPresetOverrides: const {0: 4, 2: 8},
          tracks: [
            SessionTrack(
              fadeAmount: 1,
              channel: 0,
              multiple: 1,
              lengthFrames: 4,
              lanes: [lane(0, 'track0_lane0_L0.wav')],
            ),
            SessionTrack(
              fadeAmount: 1,
              channel: 2,
              multiple: 1,
              lengthFrames: 4,
              lanes: [lane(0, 'track2_lane0_L0.wav')],
            ),
          ],
        ),
        laneStems: {
          (0, 0): [pcm],
        },
      );
      final rig = rigFromBundle(bundle);
      expect(rig.tracks.single.channel, 0);
      expect(rig.looperMode, LooperMode.band);
      expect(rig.primaryTrack, 0);
      expect(rig.defaultOneShot, isTrue);
      expect(rig.trackRecordTimingOverrides, {
        0: RecordTiming.quarter,
        2: RecordTiming.bar,
      });
      expect(rig.trackOverdubDecayOverrides, {0: 30, 2: 0});
      expect(rig.trackOneShotOverrides, {0: true, 2: false});
      expect(rig.trackLengthPresetOverrides, {0: 4, 2: 8});
      expect(rig.trackOneShotOverrides.containsKey(1), isFalse);
    });

    test('drops a lane whose PCM is missing but keeps its siblings', () {
      final l0 = Float32List.fromList([1, 1, 1, 1]);
      final bundle = (
        session: sessionWith([
          SessionTrack(
            fadeAmount: 1,
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [
              lane(0, 'track0_lane0_L0.wav'),
              lane(1, 'track0_lane1_L0.wav'),
            ],
          ),
        ]),
        // Lane 1 has no decoded audio.
        laneStems: {
          (0, 0): [l0],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.lanes, hasLength(1));
      expect(rig.tracks.single.lanes.single.lane, 0);
    });

    test('drops a track whose every lane is missing its PCM', () {
      final bundle = (
        session: sessionWith([
          SessionTrack(
            fadeAmount: 1,
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [lane(0, 'track0_lane0_L0.wav')],
          ),
          SessionTrack(
            fadeAmount: 1,
            channel: 1,
            multiple: 1,
            lengthFrames: 4,
            lanes: [lane(0, 'track1_lane0_L0.wav')],
          ),
        ]),
        // Only track 0's audio decoded.
        laneStems: {
          (0, 0): [
            Float32List.fromList([1, 1, 1, 1]),
          ],
        },
      );

      final rig = rigFromBundle(bundle);
      expect(rig.tracks, hasLength(1));
      expect(rig.tracks.single.channel, 0);
    });
  });
}
