import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/session_repository.dart';
import 'package:wav_codec/wav_codec.dart';

import 'helpers/fake_session_engine.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('segno_session');
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  SessionRepository repoFor(AudioEngine engine) => SessionRepository(
    engine: engine,
    clearPollInterval: Duration.zero,
    clearPollAttempts: 4,
  );

  test(
    'read rejects older and missing schema before inspecting stems',
    () async {
      final dir = '${tempDir.path}/obsolete';
      Directory(dir).createSync();
      final manifest = const Session(
        sampleRate: 48000,
        channels: 1,
        baseLengthFrames: 4,
        tracks: [
          SessionTrack(
            channel: 0,
            multiple: 1,
            lengthFrames: 4,
            lanes: [
              SessionLane(
                lane: 0,
                volume: 1,
                muted: false,
                outputMask: 3,
                inputChannel: 0,
                layers: [SessionLayer(file: 'missing.wav')],
              ),
            ],
          ),
        ],
      ).toJson();
      final file = File('$dir/${Session.manifestName}');
      await file.writeAsString(jsonEncode(manifest..['version'] = 7));
      await expectLater(
        repoFor(FakeSessionEngine()).read(dir),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
      manifest.remove('version');
      await file.writeAsString(jsonEncode(manifest));
      await expectLater(
        repoFor(FakeSessionEngine()).read(dir),
        throwsFormatException,
      );
    },
  );

  test('save writes the manifest, a stem per track, and a mixdown', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(
        1,
        Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
        multiple: 2,
      );
    final dir = '${tempDir.path}/sess';

    final session = await repoFor(
      engine,
    ).save(dir, settings: const SessionSettings());

    expect(File('$dir/${Session.manifestName}').existsSync(), isTrue);
    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track1_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/${SessionRepository.mixdownName}').existsSync(), isTrue);
    expect(session.baseLengthFrames, 4);
    expect(session.tracks, hasLength(2));
    expect(session.tracks[1].multiple, 2);
  });

  test(
    'empty-track gain, pan and input setup survive a session save and read',
    () async {
      final engine = FakeSessionEngine();
      final directory = '${tempDir.path}/empty-mix';
      const settings = SessionSettings(
        trackLevels: {7: .65},
        trackPans: {7: 0.75},
        inputSetup: SessionInputSetup(
          trimDb: {0: -6},
          pan: {1: -0.5},
          pairs: {2: 0.25},
        ),
      );

      final saved = await repoFor(engine).save(directory, settings: settings);
      final loaded = (await repoFor(engine).read(directory)).session;
      expect(saved.tracks, isEmpty);
      expect(loaded.tracks, isEmpty);
      expect(loaded.trackLevels, {7: .65});
      expect(loaded.trackPans, {7: 0.75});
      expect(loaded.inputSetup.trimDb, {0: -6});
      expect(loaded.inputSetup.pan, {1: -0.5});
      expect(loaded.inputSetup.pairs, {2: 0.25});
    },
  );

  test('save waits out an in-flight overdub layer before capturing', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..layerInFlightPolls = 2; // the punch-tail/drain window, then settled
    final dir = '${tempDir.path}/sess';

    final session = await repoFor(
      engine,
    ).save(dir, settings: const SessionSettings());

    expect(session.tracks, hasLength(1)); // captured AFTER the settle
    expect(engine.layerInFlightPolls, 0); // the wait actually consumed polls
  });

  test(
    'save freezes caller overrides before waiting for audio to settle',
    () async {
      final engine = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
        ..layerInFlightPolls = 1;
      final timings = {0: RecordTiming.bar};
      final decays = {0: 25};
      final playback = {0: false};
      final presets = {0: 4};
      final pans = {6: -0.6};
      final gains = {6: .7};
      final trims = {2: 3.0};
      final dir = '${tempDir.path}/detached';
      final pending = repoFor(engine).save(
        dir,
        settings: SessionSettings(
          trackRecordTimingOverrides: timings,
          trackOverdubDecayOverrides: decays,
          trackOneShotOverrides: playback,
          trackLengthPresetOverrides: presets,
          trackPans: pans,
          trackLevels: gains,
          inputSetup: SessionInputSetup(trimDb: trims),
        ),
      );
      // The save is waiting for the in-flight layer; these edits belong to the
      // caller's next save, not the request already accepted above.
      expect(engine.layerInFlightPolls, 0);
      timings[0] = RecordTiming.sixteenth;
      decays.clear();
      playback[0] = true;
      presets[0] = 8;
      pans[6] = 0.4;
      gains[6] = 1.2;
      trims.clear();
      final saved = await pending;
      final read = (await repoFor(engine).read(dir)).session;
      for (final session in [saved, read]) {
        expect(session.trackRecordTimingOverrides, {0: RecordTiming.bar});
        expect(session.trackOverdubDecayOverrides, {0: 25});
        expect(session.trackOneShotOverrides, {0: false});
        expect(session.trackLengthPresetOverrides, {0: 4});
        expect(session.trackLevels, {6: .7});
        expect(session.trackPans, {6: -0.6});
        expect(session.inputSetup.trimDb, {2: 3});
      }
      expect(
        () => saved.trackOneShotOverrides[0] = true,
        throwsUnsupportedError,
      );
      expect(() => saved.trackPans[6] = 0, throwsUnsupportedError);
    },
  );

  test(
    'save waits for commands and captures one newer tempo-grid report',
    () async {
      final engine = _CommandSettlementEngine()
        ..pendingCommands = true
        ..tempoBpm = 90
        ..tempoSource = TempoSource.manual
        ..reportedLoopBars = 2
        ..seedTrack(0, Float32List.fromList([1, 2, 3, 4]));
      final dir = '${tempDir.path}/queued';
      final pending = repoFor(engine).save(
        dir,
        settings: const SessionSettings(
          tempoBpm: 120,
          tempoSource: TempoSource.derived,
          loopBars: 4,
          looperMode: LooperMode.song,
          primaryTrack: 1,
          trackOneShotOverrides: {0: false},
        ),
      );
      expect(engine.commandChecks, 1);
      expect(engine.snapshotTempos, [90]);
      expect(engine.exports, 0);
      expect(Directory(dir).existsSync(), isFalse);
      // A callback has now applied the queued command and published its report.
      engine
        ..tempoBpm = 156
        ..tempoSource = TempoSource.tapped
        ..reportedLoopBars = 7
        ..tsNum = 7
        ..tsDen = 8
        ..looperMode = LooperMode.sync
        ..primaryTrack = 0
        ..pendingCommands = false;
      final saved = await pending;
      expect(engine.commandChecks, 2);
      expect(engine.snapshotTempos, [90, 156, 156]);
      expect(engine.exports, greaterThan(0));
      final read = (await repoFor(engine).read(dir)).session;
      for (final session in [saved, read]) {
        expect(session.tempoBpm, 156);
        expect(session.tempoSource, TempoSource.tapped);
        expect(session.loopBars, 7);
        expect(session.tsNum, 7);
        expect(session.tsDen, 8);
        expect(session.looperMode, LooperMode.sync);
        expect(session.primaryTrack, 0);
        expect(session.trackOneShotOverrides, {0: false});
      }
    },
  );

  test('save waits for a layer published by the settling command', () async {
    final engine = _LayerAtSettlementEngine()
      ..seedTrack(0, Float32List.fromList([1, 2, 3, 4]));
    final saved = await repoFor(engine).save(
      '${tempDir.path}/settled-layer',
      settings: const SessionSettings(),
    );
    expect(saved.tracks, hasLength(1));
    expect(engine.commandChecks, 2);
    expect(engine.capturedInFlight, isFalse);
  });

  test('device lifetime change during settlement writes no bundle', () async {
    final engine = _CommandSettlementEngine()
      ..pendingCommands = true
      ..seedTrack(0, Float32List.fromList([1, 2, 3, 4]));
    final dir = '${tempDir.path}/restarted';
    var generation = 0;
    final acceptedGeneration = generation;
    final pending = repoFor(engine).save(
      dir,
      settings: const SessionSettings(trackPans: {0: .7}),
      captureStillValid: () => generation == acceptedGeneration,
    );
    expect(engine.commandChecks, 1);
    generation++;
    engine.pendingCommands = false;

    await expectLater(pending, throwsStateError);
    expect(engine.exports, 0);
    expect(Directory(dir).existsSync(), isFalse);
  });

  test('save times out without writing when commands never settle', () async {
    final engine = _CommandSettlementEngine()
      ..pendingCommands = true
      ..seedTrack(0, Float32List.fromList([1, 2, 3, 4]));
    final dir = '${tempDir.path}/unsettled';
    await expectLater(
      repoFor(engine).save(dir, settings: const SessionSettings()),
      throwsStateError,
    );
    expect(engine.commandChecks, 4);
    expect(engine.exports, 0);
    expect(Directory(dir).existsSync(), isFalse);
  });

  test(
    'offline save bypasses command settlement and retains the intended grid',
    () async {
      final engine = _CommandSettlementEngine()
        ..reportsRunning = false
        ..pendingCommands = true
        ..tempoBpm = 90
        ..tempoSource = TempoSource.tapped
        ..reportedLoopBars = 7;
      final dir = '${tempDir.path}/offline';
      final saved = await repoFor(engine).save(
        dir,
        settings: const SessionSettings(
          tempoBpm: 128,
          tempoSource: TempoSource.manual,
          loopBars: 3,
        ),
      );
      expect(engine.commandChecks, 1);
      expect(saved.tempoBpm, 128);
      expect(saved.tempoSource, TempoSource.manual);
      expect(saved.loopBars, 3);
      expect((await repoFor(engine).read(dir)).session, saved);
    },
  );

  test('save throws when an overdub layer never settles', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..layerInFlightPolls = 1 << 30; // never settles within the attempts
    final dir = '${tempDir.path}/sess';

    await expectLater(
      repoFor(engine).save(dir, settings: const SessionSettings()),
      throwsStateError,
    );
  });

  test(
    'saving an all-empty looper persists no ghost grid — an empty session '
    'reads back with no master to establish',
    () async {
      // The engine keeps the master grid after the last track is undone to
      // empty (redo needs it live) — but a zero-track session must not carry
      // that ghost tempo to disk.
      final engine = FakeSessionEngine()..masterLength = 48000;
      final dir = '${tempDir.path}/sess';

      final session = await repoFor(
        engine,
      ).save(dir, settings: const SessionSettings());
      expect(session.baseLengthFrames, 0);
      expect(session.tracks, isEmpty);

      // Reading it back carries no grid: the apply path (looper repository)
      // leaves the cleared engine free to define a fresh loop length.
      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.baseLengthFrames, 0);
      expect(bundle.laneStems, isEmpty);
    },
  );

  test(
    'save persists the lane chains and monitors, read returns them',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/fx';

      const chains = SessionChains(
        laneChains: [
          SessionLaneChain(channel: 0, lane: 0, encoded: '[{"t":1}]'),
        ],
        monitors: [
          SessionMonitor(
            input: 2,
            mode: 'on',
            outputMask: 0x1,
            volume: 0.6,
            muted: true,
            encoded: '[{"t":7}]',
          ),
        ],
      );
      final session = await repoFor(
        source,
      ).save(dir, settings: const SessionSettings(), chains: chains);
      expect(session.laneChains, chains.laneChains);
      expect(session.monitors, chains.monitors);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.laneChains, chains.laneChains);
      expect(bundle.session.monitors, chains.monitors);
    },
  );

  test(
    'save persists the two BUS stages (Track + Master, schema v5), read '
    'returns them byte-intact',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/bus-fx';

      const chains = SessionChains(
        trackChains: [
          SessionTrackChain(
            channel: 0,
            // A chain-DISABLED Track stage: the flag rides inside the opaque
            // envelope, so persisting it needs no manifest field of its own.
            encoded: '{"chainEnabled":false,"entries":[{"t":1}]}',
          ),
        ],
        masterChain: '{"chainEnabled":true,"entries":[{"t":7}]}',
      );
      final session = await repoFor(
        source,
      ).save(dir, settings: const SessionSettings(), chains: chains);
      expect(session.trackChains, chains.trackChains);
      expect(session.masterChain, chains.masterChain);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.trackChains, chains.trackChains);
      expect(bundle.session.masterChain, chains.masterChain);
    },
  );

  test(
    'save without bus-stage chains writes both stages empty (never null)',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/no-bus-fx';

      await repoFor(source).save(dir, settings: const SessionSettings());

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.trackChains, isEmpty);
      expect(bundle.session.masterChain, '');
    },
  );

  test(
    'save -> read round-trips the pedal remap blob BYTE-IDENTICALLY (schema '
    'v6) — the control layer compares these strings for equality, so any '
    'drift through the manifest would read as an edit the user never made',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/pedal-bindings';
      // Opaque to this package: a canonical-JSON target nested inside the
      // binding array, quotes and all.
      const encoded =
          '[{"button":"track1","bank":0,'
          r'"target":"{\"stage\":\"track\",\"index\":5}",'
          '"behavior":"momentary"}]';

      final session = await repoFor(
        source,
      ).save(dir, settings: const SessionSettings(), pedalBindings: encoded);
      expect(session.pedalBindings, encoded);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.pedalBindings, encoded);
    },
  );

  test(
    'save without a remap writes the empty blob, so the loaded session '
    'defers to the global set (A12)',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/no-pedal-bindings';

      await repoFor(source).save(dir, settings: const SessionSettings());

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.pedalBindings, '');
    },
  );

  test(
    'save reads desired musical settings independently of audio capture',
    () async {
      final source = _CommandSettlementEngine()
        ..tempoBpm = 96
        ..tempoSource = TempoSource.tapped
        ..reportedLoopBars = 5
        ..tsNum = 7
        ..tsDen = 8
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      const settings = SessionSettings(
        tempoBpm: 110,
        tempoSource: TempoSource.manual,
        tsNum: 3,
        syncTempo: false,
        quantizeDiv: GridDivision.quarter,
        loopBars: 2,
        recordTiming: RecordTiming.quarter,
        overdubDecay: 25,
        defaultOneShot: true,
        trackRecordTimingOverrides: {
          0: RecordTiming.eighth,
          2: RecordTiming.quarter,
        },
        trackOverdubDecayOverrides: {0: 40, 2: 25},
        trackOneShotOverrides: {0: true, 2: false},
        trackLengthPresetOverrides: {0: 4, 2: 8},
        clickMode: ClickMode.playRec,
        clickMask: 0x1,
        clickVolume: 0.4,
        countInBars: 3,
        recDub: true,
        defaultMultiple: 2,
      );
      final dir = '${tempDir.path}/tempo';
      final session = await repoFor(source).save(dir, settings: settings);
      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session, session);
      expect(session.recordTiming, RecordTiming.quarter);
      expect(session.overdubDecay, 25);
      expect(session.defaultOneShot, isTrue);
      expect(session.trackRecordTimingOverrides, {
        0: RecordTiming.eighth,
        2: RecordTiming.quarter,
      });
      expect(session.trackOverdubDecayOverrides, {0: 40, 2: 25});
      expect(session.trackOneShotOverrides, {0: true, 2: false});
      expect(session.trackLengthPresetOverrides, {0: 4, 2: 8});
      expect(session.tracks.single.channel, 0);
      expect(session.tempoBpm, 96);
      expect(session.tempoSource, TempoSource.tapped);
      expect(session.tsNum, 7);
      expect(session.tsDen, 8);
      expect(session.syncTempo, isFalse);
      expect(session.quantizeDiv, GridDivision.quarter);
      expect(session.loopBars, 5);
      expect(session.clickMode, ClickMode.playRec);
      expect(session.clickOutputMask, 0x1);
      expect(session.clickVolume, 0.4);
      expect(session.countInBars, 3);
      expect(session.recDub, isTrue);
      expect(session.autoRecord, isFalse);
      expect(session.defaultMultiple, 2);
    },
  );

  test(
    'stopped capture retains desired settings and empty-track overrides',
    () async {
      final engine = MockAudioEngine();
      expect(engine.snapshot().isRunning, isFalse);
      const settings = SessionSettings(
        tempoBpm: 123,
        tempoSource: TempoSource.manual,
        tsNum: 3,
        tsDen: 8,
        quantizeDiv: GridDivision.sixteenth,
        recordTiming: RecordTiming.bar,
        overdubDecay: 50,
        defaultOneShot: true,
        trackRecordTimingOverrides: {1: RecordTiming.bar},
        trackOverdubDecayOverrides: {1: 50, 2: 0},
        trackOneShotOverrides: {1: false, 2: true},
        trackLengthPresetOverrides: {1: 8},
        autoRecord: true,
        looperMode: LooperMode.free,
      );
      final dir = '${tempDir.path}/stopped';
      final saved = await repoFor(engine).save(dir, settings: settings);
      final read = (await repoFor(engine).read(dir)).session;
      expect(read, saved);
      expect(read.tracks, isEmpty);
      expect(read.tempoBpm, 123);
      expect(read.tempoSource, TempoSource.manual);
      expect(read.tsNum, 3);
      expect(read.tsDen, 8);
      expect(read.quantizeDiv, GridDivision.sixteenth);
      expect(read.recordTiming, RecordTiming.bar);
      expect(read.overdubDecay, 50);
      expect(read.defaultOneShot, isTrue);
      expect(read.trackRecordTimingOverrides, {1: RecordTiming.bar});
      expect(read.trackOverdubDecayOverrides, {1: 50, 2: 0});
      expect(read.trackOneShotOverrides, {1: false, 2: true});
      expect(read.trackLengthPresetOverrides, {1: 8});
      expect(read.autoRecord, isTrue);
      expect(read.looperMode, LooperMode.free);
      final otherRate = repoFor(FakeSessionEngine(sampleRate: 44100));
      expect((await otherRate.read(dir)).session, saved);
    },
  );

  test(
    'saving Use default removes previously saved explicit overrides',
    () async {
      final engine = FakeSessionEngine();
      final repo = repoFor(engine);
      final dir = '${tempDir.path}/inherit';
      await repo.save(
        dir,
        settings: const SessionSettings(
          trackRecordTimingOverrides: {0: RecordTiming.immediately},
          trackOverdubDecayOverrides: {0: 0},
          trackOneShotOverrides: {0: false},
          trackLengthPresetOverrides: {0: 4},
        ),
      );
      final explicit = (await repo.read(dir)).session;
      expect(explicit.trackRecordTimingOverrides, {
        0: RecordTiming.immediately,
      });
      expect(explicit.trackOverdubDecayOverrides, {0: 0});
      expect(explicit.trackOneShotOverrides, {0: false});
      expect(explicit.trackLengthPresetOverrides, {0: 4});

      await repo.save(dir, settings: const SessionSettings());
      final inherited = (await repo.read(dir)).session;
      expect(inherited.trackRecordTimingOverrides, isEmpty);
      expect(inherited.trackOverdubDecayOverrides, isEmpty);
      expect(inherited.trackOneShotOverrides, isEmpty);
      expect(inherited.trackLengthPresetOverrides, isEmpty);
    },
  );

  test(
    'a derived tempo persists in the manifest even when saved with zero '
    'tracks (D6: clearing all tracks offers a tempo reset, never forces it)',
    () async {
      // Unlike baseLengthFrames (zeroed for a zero-track save, see the
      // "persists no ghost grid" test above), tempo/signature/click/
      // count-in are session-level settings, not derived-from-content
      // state — the engine's "grid survives a clear" behavior must round
      // -trip through a save exactly as the live engine reports it.
      final engine = FakeSessionEngine()
        ..tempoBpm = 140.0
        ..tempoSource = TempoSource.derived;
      final dir = '${tempDir.path}/dead-tempo';

      final session = await repoFor(engine).save(
        dir,
        settings: const SessionSettings(
          tempoBpm: 140,
          tempoSource: TempoSource.derived,
        ),
      );
      expect(session.tracks, isEmpty);
      expect(session.baseLengthFrames, 0);
      expect(session.tempoBpm, 140.0);
      expect(session.tempoSource, TempoSource.derived);
    },
  );

  test(
    'save without chains writes an empty (but present) v2 chain list',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/nofx';

      final session = await repoFor(
        source,
      ).save(dir, settings: const SessionSettings());
      expect(session.laneChains, isEmpty);
      expect(session.monitors, isEmpty);
    },
  );

  test('save then read returns the manifest and every decoded stem', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(
        1,
        Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
        multiple: 2,
        volume: 0.5,
        muted: true,
      );
    final dir = '${tempDir.path}/s';
    await repoFor(source).save(dir, settings: const SessionSettings());

    final bundle = await repoFor(FakeSessionEngine()).read(dir);

    expect(bundle.session.baseLengthFrames, 4);
    expect(bundle.session.tracks, hasLength(2));
    expect(bundle.session.tracks[1].multiple, 2);
    expect(bundle.session.tracks[1].lanes.single.muted, isTrue);
    expect(bundle.session.tracks[1].lanes.single.volume, 0.5);
    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([1, 1, 1, 1]),
    ]);
    expect(bundle.laneStems[(1, 0)], [
      Float32List.fromList([2, 2, 2, 2, 3, 3, 3, 3]),
    ]);
  });

  test('save then read round-trips a multi-lane track per lane', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(
        0,
        1,
        Float32List.fromList([2, 2, 2, 2]),
        volume: 0.5,
        muted: true,
        outputMask: 0x2,
        inputChannel: 1,
      );
    final dir = '${tempDir.path}/multilane';
    await repoFor(source).save(dir, settings: const SessionSettings());

    final bundle = await repoFor(FakeSessionEngine()).read(dir);
    final track = bundle.session.tracks.single;
    expect(track.lanes, hasLength(2));
    expect(track.lanes[1].volume, 0.5);
    expect(track.lanes[1].muted, isTrue);
    expect(track.lanes[1].outputMask, 0x2);
    expect(track.lanes[1].inputChannel, 1);
    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([1, 1, 1, 1]),
    ]);
    expect(bundle.laneStems[(0, 1)], [
      Float32List.fromList([2, 2, 2, 2]),
    ]);
  });

  test(
    'save then read round-trips an 8-track Free-mode session with '
    'independent per-track lengths (B5c)',
    () async {
      // Mutually distinct lengths, none a multiple of another — proves each
      // track's own length round-trips independently rather than being
      // forced to a shared base/multiple relationship (Free mode's whole
      // point: "four un-synced, independently playing, free-form tracks",
      // extended to segno's 8).
      const lengths = [5, 7, 9, 11, 13, 17, 19, 23];
      final source = FakeSessionEngine()..looperMode = LooperMode.free;
      for (final (channel, length) in lengths.indexed) {
        source.seedTrack(
          channel,
          Float32List.fromList(List.filled(length, channel + 1.0)),
        );
      }
      final dir = '${tempDir.path}/free8';
      await repoFor(
        source,
      ).save(dir, settings: const SessionSettings(looperMode: LooperMode.free));

      final bundle = await repoFor(FakeSessionEngine()).read(dir);

      expect(bundle.session.looperMode, LooperMode.free);
      expect(bundle.session.tracks, hasLength(8));
      for (final (channel, length) in lengths.indexed) {
        final track = bundle.session.tracks.firstWhere(
          (t) => t.channel == channel,
        );
        expect(track.lengthFrames, length, reason: 'track $channel');
        expect(
          bundle.laneStems[(channel, 0)]!.single,
          Float32List.fromList(List.filled(length, channel + 1.0)),
          reason: 'track $channel PCM',
        );
      }
    },
  );

  test(
    'save preserves mode, crown, and playback choices for every track',
    () async {
      final source = FakeSessionEngine()
        ..looperMode = LooperMode.sync
        ..primaryTrack = 1
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
        ..seedTrack(1, Float32List.fromList([2, 2, 2, 2]));
      final dir = '${tempDir.path}/mode';
      await repoFor(source).save(
        dir,
        settings: const SessionSettings(
          looperMode: LooperMode.sync,
          primaryTrack: 1,
          defaultOneShot: true,
          trackOneShotOverrides: {0: true, 1: false, 2: false},
        ),
      );
      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      expect(bundle.session.looperMode, LooperMode.sync);
      expect(bundle.session.primaryTrack, 1);
      expect(bundle.session.defaultOneShot, isTrue);
      expect(bundle.session.trackOneShotOverrides, {
        0: true,
        1: false,
        2: false,
      });
      expect(bundle.session.tracks.map((track) => track.channel), [0, 1]);
    },
  );

  test(
    'a tempo-bearing session preserves an intentionally absent grid',
    () async {
      final engine = FakeSessionEngine()
        ..tempoBpm = 120
        ..tempoSource = TempoSource.manual
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/no-musical-grid';
      await repoFor(engine).save(
        dir,
        settings: const SessionSettings(
          tempoBpm: 120,
          tempoSource: TempoSource.manual,
          syncTempo: false,
        ),
      );
      final session = (await repoFor(engine).read(dir)).session;
      expect(session.baseLengthFrames, 4);
      expect(session.tempoBpm, 120);
      expect(session.loopBars, 0);
      expect(session.syncTempo, isFalse);
    },
  );

  test(
    'default musical choices round-trip for a plain Multi session',
    () async {
      final source = FakeSessionEngine()
        ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
      final dir = '${tempDir.path}/plain';
      await repoFor(source).save(dir, settings: const SessionSettings());
      final session = (await repoFor(source).read(dir)).session;
      expect(session.looperMode, LooperMode.multi);
      expect(session.primaryTrack, -1);
      expect(session.defaultOneShot, isFalse);
      expect(session.trackOneShotOverrides, isEmpty);
      expect(session.trackRecordTimingOverrides, isEmpty);
      expect(session.trackOverdubDecayOverrides, isEmpty);
      expect(session.trackLengthPresetOverrides, isEmpty);
    },
  );

  test(
    "save then read round-trips a lane's full overdub layer stack",
    () async {
      final undo0 = Float32List.fromList([1, 1, 1, 1]);
      final live = Float32List.fromList([2, 2, 2, 2]);
      final redo0 = Float32List.fromList([3, 3, 3, 3]);
      final source = FakeSessionEngine()
        ..seedLayers(0, [undo0, live, redo0], undoDepth: 1, redoDepth: 1);
      final dir = '${tempDir.path}/layers';
      await repoFor(source).save(dir, settings: const SessionSettings());

      // One WAV per layer.
      expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
      expect(File('$dir/track0_lane0_L1.wav').existsSync(), isTrue);
      expect(File('$dir/track0_lane0_L2.wav').existsSync(), isTrue);

      final bundle = await repoFor(FakeSessionEngine()).read(dir);
      final lane = bundle.session.tracks.single.lanes.single;
      expect(lane.undoCount, 1);
      expect(lane.redoCount, 1);
      expect(lane.liveIndex, 1);
      // The layers round-trip in ordinal order (undo → live → redo).
      expect(bundle.laneStems[(0, 0)], [undo0, live, redo0]);
    },
  );

  test('re-saving with fewer layers prunes the orphaned layer WAVs', () async {
    final dir = '${tempDir.path}/prune';
    // First save: a 3-layer history.
    await repoFor(
      FakeSessionEngine()..seedLayers(
        0,
        [
          Float32List.fromList([1, 1, 1, 1]),
          Float32List.fromList([2, 2, 2, 2]),
          Float32List.fromList([3, 3, 3, 3]),
        ],
        undoDepth: 1,
        redoDepth: 1,
      ),
    ).save(dir, settings: const SessionSettings());
    expect(File('$dir/track0_lane0_L2.wav').existsSync(), isTrue);

    // Re-save the same bundle with a single-layer (no-history) track.
    await repoFor(
      FakeSessionEngine()..seedTrack(0, Float32List.fromList([9, 9, 9, 9])),
    ).save(dir, settings: const SessionSettings());

    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track0_lane0_L1.wav').existsSync(), isFalse);
    expect(File('$dir/track0_lane0_L2.wav').existsSync(), isFalse);
  });

  test(
    'save and live export apply track gain once after unequal part levels',
    () async {
      final engine = FakeSessionEngine()
        ..seedTrack(
          0,
          Float32List.fromList([.2, .2, .2, .2]),
          volume: .25,
          trackVolume: .5,
        )
        ..seedLane(0, 1, Float32List.fromList([.1, .1, .1, .1]), volume: 1.5);
      final repository = repoFor(engine);
      final directory = '${tempDir.path}/separate_gains';
      final saved = await repository.save(
        directory,
        settings: const SessionSettings(
          trackLevels: {0: .5},
          laneMix: {
            (0, 0): (level: .25, imagePan: 0, balance: 1),
            (0, 1): (level: 1.5, imagePan: 0, balance: 1),
          },
        ),
      );
      final livePath = '${tempDir.path}/live.wav';
      await repository.exportMixdown(livePath);
      // (.2 * .25 + .1 * 1.5) * .5 = .1. Applying the fader to
      // lane zero only, deriving it from that lane, or applying twice differs.
      for (final path in [
        '$directory/${SessionRepository.mixdownName}',
        livePath,
      ]) {
        final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());
        expect(wav.samples, everyElement(closeTo(.1, 1e-6)));
      }
      expect(saved.trackLevels, {0: .5});
      expect(saved.tracks.single.lanes.map((lane) => lane.volume), [.25, 1.5]);
      final original0 = WavCodec.decodeFloat32(
        File('$directory/track0_lane0_L0.wav').readAsBytesSync(),
      );
      final original1 = WavCodec.decodeFloat32(
        File('$directory/track0_lane1_L0.wav').readAsBytesSync(),
      );
      expect(original0.samples, everyElement(closeTo(.2, 1e-6)));
      expect(original1.samples, everyElement(closeTo(.1, 1e-6)));
    },
  );

  test('mixdown sums unmuted tracks over the LCM period', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1])) // base 2
      ..seedTrack(
        1,
        Float32List.fromList([0.5, 0.5, 0.5, 0.5]),
        multiple: 2,
      ); // length 4, base 2
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    expect(wav.frames, 4); // lcm(2, 4)
    for (final sample in wav.samples) {
      expect(sample, closeTo(1.5, 1e-6));
    }
  });

  test('mixdown sums both lanes of a multi-lane track', () async {
    // Two lanes on ONE track must both contribute — summed, never merged.
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(0, 1, Float32List.fromList([0.25, 0.25, 0.25, 0.25]));
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    expect(wav.frames, 4);
    for (final sample in wav.samples) {
      expect(sample, closeTo(1.25, 1e-6)); // 1.0 (lane 0) + 0.25 (lane 1)
    }
  });

  test('the saved mixdown plays a lane at its level times its balance, the '
      'gain the engine held', () async {
    final engine = FakeSessionEngine()
      // The engine's own gain (0.25) is what the level times the balance
      // came to; the save reads the two factors and multiplies them back.
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]), volume: 0.25);
    final dir = '${tempDir.path}/mix_gain';

    await repoFor(engine).save(
      dir,
      settings: const SessionSettings(
        laneMix: {
          (0, 0): (level: 0.5, imagePan: 0, balance: 0.5),
        },
      ),
    );
    final wav = WavCodec.decodeFloat32(
      File('$dir/${SessionRepository.mixdownName}').readAsBytesSync(),
    );

    expect(wav.frames, 4);
    for (final sample in wav.samples) {
      expect(sample, closeTo(0.25, 1e-6));
    }
  });

  test('mixdown excludes a muted lane of a multi-lane track', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedLane(0, 1, Float32List.fromList([9, 9, 9, 9]), muted: true);
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    for (final sample in wav.samples) {
      expect(sample, closeTo(1, 1e-6)); // only lane 0 contributes
    }
  });

  test('mixdown excludes muted tracks', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]))
      ..seedTrack(1, Float32List.fromList([9, 9, 9, 9]), muted: true);
    final path = '${tempDir.path}/mix.wav';

    await repoFor(engine).exportMixdown(path);
    final wav = WavCodec.decodeFloat32(File(path).readAsBytesSync());

    for (final sample in wav.samples) {
      expect(sample, closeTo(1, 1e-6));
    }
  });

  test('exportStems writes one WAV per non-empty track', () async {
    final engine = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    final dir = '${tempDir.path}/stems';

    await repoFor(engine).exportStems(dir);

    expect(File('$dir/track0_lane0_L0.wav').existsSync(), isTrue);
    expect(File('$dir/track1_lane0_L0.wav').existsSync(), isFalse);
  });

  test('read rejects an invalid restored bar grid', () async {
    final dir = '${tempDir.path}/invalid-grid';
    Directory(dir).createSync();
    for (final bars in [-1, 0x7fffffff]) {
      final manifest = Session(
        sampleRate: 48000,
        channels: 1,
        baseLengthFrames: 0,
        tracks: const [],
        loopBars: bars,
      );
      File(
        '$dir/${Session.manifestName}',
      ).writeAsStringSync(jsonEncode(manifest.toJson()));
      await expectLater(
        repoFor(FakeSessionEngine()).read(dir),
        throwsFormatException,
      );
    }
  });

  test(
    'read rejects invalid or unsupported tempo before returning a rig',
    () async {
      final dir = '${tempDir.path}/invalid-tempo';
      Directory(dir).createSync();
      final file = File('$dir/${Session.manifestName}');
      for (final (bpm, source) in [
        (120.0, TempoSource.none),
        (0.0, TempoSource.manual),
        (29.0, TempoSource.tapped),
        (301.0, TempoSource.derived),
        (120.0, TempoSource.external),
      ]) {
        final manifest = Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 0,
          tracks: const [],
          tempoBpm: bpm,
          tempoSource: source,
        );
        file.writeAsStringSync(jsonEncode(manifest.toJson()));
        await expectLater(
          repoFor(FakeSessionEngine()).read(dir),
          throwsFormatException,
          reason: '$bpm / $source',
        );
      }
    },
  );

  test('read throws when the bundle is missing', () async {
    final engine = FakeSessionEngine();
    await expectLater(
      repoFor(engine).read('${tempDir.path}/does_not_exist'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('read refuses a session saved at a different sample rate', () async {
    final source = FakeSessionEngine(sampleRate: 44100)
      ..seedTrack(0, Float32List.fromList([1, 1, 1, 1]));
    final dir = '${tempDir.path}/sr';
    await repoFor(source).save(dir, settings: const SessionSettings());

    final target = FakeSessionEngine(); // 48000 Hz
    await expectLater(
      repoFor(target).read(dir),
      throwsA(isA<SessionSampleRateMismatch>()),
    );
  });

  test('save then read round-trips a single mono stem exactly', () async {
    final source = FakeSessionEngine()
      ..seedTrack(0, Float32List.fromList([0.1, -0.2, 0.3, -0.4]));
    final dir = '${tempDir.path}/mono';
    await repoFor(source).save(dir, settings: const SessionSettings());

    final bundle = await repoFor(FakeSessionEngine()).read(dir);

    expect(bundle.laneStems[(0, 0)], [
      Float32List.fromList([0.1, -0.2, 0.3, -0.4]),
    ]);
  });
}

class _CommandSettlementEngine extends FakeSessionEngine {
  bool pendingCommands = false;
  bool reportsRunning = true;
  int reportedLoopBars = 0;
  int commandChecks = 0;
  int exports = 0;
  final List<double> snapshotTempos = [];

  @override
  bool get commandsSettled {
    commandChecks++;
    return !pendingCommands;
  }

  @override
  EngineSnapshot snapshot() {
    final source = super.snapshot();
    snapshotTempos.add(source.tempoBpm);
    return EngineSnapshot(
      isRunning: reportsRunning,
      sampleRate: source.sampleRate,
      bufferFrames: source.bufferFrames,
      framesProcessed: source.framesProcessed,
      xrunCount: source.xrunCount,
      inputRms: source.inputRms,
      inputPeak: source.inputPeak,
      outputRms: source.outputRms,
      latencyState: source.latencyState,
      measuredLatencyMs: source.measuredLatencyMs,
      masterLengthFrames: source.masterLengthFrames,
      tracks: source.tracks,
      tempoBpm: source.tempoBpm,
      tempoSource: source.tempoSource,
      tsNum: source.tsNum,
      tsDen: source.tsDen,
      loopBars: reportedLoopBars,
      looperMode: source.looperMode,
      primaryTrack: source.primaryTrack,
    );
  }

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    exports++;
    return super.exportLayer(channel, lane, ordinal);
  }
}

class _LayerAtSettlementEngine extends FakeSessionEngine {
  int commandChecks = 0;
  bool capturedInFlight = false;
  bool _lastLayerInFlight = false;

  @override
  bool get commandsSettled {
    commandChecks++;
    if (commandChecks == 1) layerInFlightPolls = 1;
    return true;
  }

  @override
  EngineSnapshot snapshot() {
    final value = super.snapshot();
    _lastLayerInFlight = value.tracks.first.layerInFlight;
    return value;
  }

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    capturedInFlight |= _lastLayerInFlight;
    return super.exportLayer(channel, lane, ordinal);
  }
}
