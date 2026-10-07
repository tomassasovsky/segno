import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/session_repository.dart';

import 'helpers/fake_session_engine.dart';

/// Real bundles written by each schema's own save path (#1196); see
/// `fixtures/generators/` for the code and commit that wrote each one.
const _fixtures = 'test/fixtures/sessions';

/// The player's settings at open time: what a conversion keeps for the
/// settings master held as global preferences.
const _live = SessionSettings(
  syncTempo: false,
  recDub: true,
  autoRecord: true,
  defaultMultiple: 4,
  recordTiming: RecordTiming.loopStart,
  trackRecordTimingOverrides: {3: RecordTiming.bar},
  defaultFollowTempo: false,
  trackFollowTempoOverrides: {2: true},
  defaultPitchMode: PitchMode.followsSpeed,
  trackPitchModeOverrides: {4: PitchMode.unchanged},
);

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('segno_convert'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  SessionRepository repo() => SessionRepository(
    guards: GuardRegistry(),
    engine: FakeSessionEngine(),
    clearPollInterval: Duration.zero,
    clearPollAttempts: 4,
  );

  /// Copies fixture [name] into a fresh bundle directory.
  String copyFixture(String name) {
    final to = Directory('${tempDir.path}/$name')..createSync();
    for (final file in Directory('$_fixtures/$name').listSync()) {
      (file as File).copySync('${to.path}/${file.uri.pathSegments.last}');
    }
    return to.path;
  }

  /// Every file of [dir] by name, byte for byte.
  Map<String, List<int>> snapshotOf(String dir) => {
    for (final file in Directory(dir).listSync().whereType<File>())
      file.uri.pathSegments.last: file.readAsBytesSync(),
  };

  Map<String, dynamic> manifestOf(String dir) =>
      jsonDecode(File('$dir/${Session.manifestName}').readAsStringSync())
          as Map<String, dynamic>;

  test('every schema from the oldest convertible one has exactly one step '
      'up to the current schema', () {
    // A schema bump adds its step to `sessionMigrationSteps`
    // (lib/src/session_migration.dart); this fails until it does.
    for (
      var version = oldestConvertibleSessionVersion;
      version < Session.formatVersion;
      version++
    ) {
      expect(
        sessionMigrationSteps,
        contains(version),
        reason: 'no conversion step from schema $version to ${version + 1}',
      );
    }
    expect(
      sessionMigrationSteps.keys.toSet(),
      {
        for (
          var version = oldestConvertibleSessionVersion;
          version < Session.formatVersion;
          version++
        )
          version,
      },
    );
  });

  group('a schema-7 bundle written by master', () {
    test(
      'opens with its tracks, layers, mix, FX, tempo and settings',
      () async {
        final dir = copyFixture('v7_master_full');
        final original = manifestOf(dir);

        final (:bundle, :conversion) = await repo().open(
          dir,
          liveSettings: () => _live,
        );
        final session = bundle.session;

        // Audio: every lane's layer stack, untouched.
        expect(session.baseLengthFrames, 2400);
        expect(session.tracks.map((t) => t.channel), [0, 1, 2]);
        expect(session.tracks.map((t) => t.multiple), [1, 2, 1]);
        expect(session.tracks.map((t) => t.fadeAmount), [1, 1, 1]);
        final lane01 = session.tracks[0].lanes[1];
        expect(lane01.volume, 1.5);
        expect(lane01.outputMask, 0x1);
        expect(lane01.inputChannel, 1);
        expect(lane01.undoCount, 2);
        expect(lane01.layers, hasLength(3));
        expect(lane01.pan, 0);
        expect(lane01.balance, 1);
        final lane10 = session.tracks[1].lanes.single;
        expect(lane10.volume, 0.5);
        expect(lane10.muted, isTrue);
        final lane20 = session.tracks[2].lanes.single;
        expect((lane20.undoCount, lane20.redoCount), (2, 1));
        expect(bundle.laneStems[(2, 0)], hasLength(4));
        expect(bundle.laneStems[(0, 1)]![2], hasLength(2400));

        // FX: every chain string verbatim; the Master insert, which ran on the
        // summed tracks before monitoring joined, is the All tracks chain.
        expect(
          session.laneChains.map((c) => c.encoded),
          (original['laneChains'] as List).map((c) => (c as Map)['encoded']),
        );
        expect(
          session.trackChains.single.encoded,
          _first(original['trackChains'])['encoded'],
        );
        expect(session.allTracksChain, original['masterChain']);
        expect(session.outputChains, isEmpty);
        expect(session.monitors.map((m) => m.mode), ['auto', 'on']);
        expect(session.monitors.map((m) => m.volume), [1, 0.75]);
        expect(session.monitors[1].muted, isTrue);
        // The pedal bound to the Master chain follows it to All tracks.
        expect(_bindingTargets(session.pedalBindings), [
          {'stage': 'loop', 'index': 0, 'lane': 0},
          {'stage': 'allTracks', 'index': 0},
        ]);
        expect(conversion!.changes, {
          SessionConversionChange.masterEffectsMoved,
          SessionConversionChange.monitorLevelLowered,
        });

        // Tempo and grid as saved.
        expect(session.tempoBpm, 100);
        expect(session.tempoSource, TempoSource.manual);
        expect((session.tsNum, session.tsDen), (3, 4));
        expect(session.quantizeDiv, GridDivision.bar);
        expect(session.clickMode, ClickMode.rec);
        expect(session.clickOutputMask, 0x2);
        expect(session.clickVolume, closeTo(0.8, 1e-6));
        expect(session.countInBars, 2);
        expect(session.looperMode, LooperMode.sync);
        expect(session.loopBars, 0);

        // Settings: One Shot channels are explicit Once choices; what master
        // kept global keeps the player's live value; the rest reproduce
        // master (no decay, Loop and Auto defaults, unity Fade).
        expect(session.trackOneShotOverrides, {2: true, 5: true});
        expect(session.defaultOneShot, isFalse);
        expect(session.trackLengthPresetOverrides, isEmpty);
        expect(session.defaultLengthPresetBars, 0);
        expect(session.syncTempo, isFalse);
        expect(session.recDub, isTrue);
        expect(session.autoRecord, isTrue);
        expect(session.defaultMultiple, 4);
        expect(session.recordTiming, RecordTiming.loopStart);
        // Master had no per-track timing; the live session's does not leak.
        expect(session.trackRecordTimingOverrides, isEmpty);
        expect(session.overdubDecay, 0);
        expect(session.trackOverdubDecayOverrides, isEmpty);
        expect(session.defaultFadeDurationMs, 4000);
        expect(session.trackFadeDurationOverrides, isEmpty);
        expect(session.trackLevels, isEmpty);
        expect(session.trackPans, isEmpty);
        expect(session.inputSetup, const SessionInputSetup());
        expect(session.outputSetup, const SessionOutputSetup());

        expect(conversion.fromVersion, 7);
        expect(
          conversion.notes,
          containsAll([
            'masterChain: moved to allTracksChain',
            'trackOneShotOverrides: moved from the One Shot channels',
            'recDub: taken from the live setting',
            'monitors[0].volume: 1.5 lowered to the live-input ceiling of 1',
            'tracks[2].fadeAmount: defaulted to 1',
            'defaultFadeDurationMs: defaulted',
          ]),
        );
      },
    );

    test('opens without live settings at the current defaults', () async {
      final session = await repo().read(copyFixture('v7_master_full'));
      expect(session.session.recDub, const SessionSettings().recDub);
      expect(session.session.syncTempo, const SessionSettings().syncTempo);
    });

    test(
      'a settings-only bundle opens with its chains and Once tracks',
      () async {
        final (:bundle, :conversion) = await repo().open(
          copyFixture('v7_master_empty'),
        );
        expect(bundle.session.tracks, isEmpty);
        expect(bundle.session.laneChains.single.channel, 3);
        expect(bundle.session.monitors.single.mode, 'on');
        expect(bundle.session.trackOneShotOverrides, {4: true});
        expect(bundle.session.allTracksChain, '');
        expect(conversion!.notes, contains('allTracksChain: defaulted'));
      },
    );
  });

  group('each intermediate schema written by its own commit', () {
    // Schemas 8 and 9 were written by two histories, the September slices
    // and the October 1 reconstruction; each has its own fixture.
    for (final (name, version, outputBus) in const [
      ('v8_slices_be987759d', 8, 0),
      ('v8_trunk_a0a54e57e', 8, 0),
      ('v9_slices_95dcea0d8', 9, 1),
      ('v9_trunk_623a5a7ba', 9, 1),
      ('v10_trunk_a921bd9a9', 10, 1),
      ('v11_trunk_5c163d11f', 11, 1),
      ('v12_peel_097e1ef68', 12, 1),
    ]) {
      test('$name opens with its saved values', () async {
        final dir = copyFixture(name);
        final original = manifestOf(dir);
        final (:bundle, :conversion) = await repo().open(
          dir,
          liveSettings: () => _live,
        );
        final session = bundle.session;
        expect(conversion!.fromVersion, version);
        // Schema 12's fixture adds a fourth track holding a Peel entry.
        expect(session.tracks.map((t) => t.multiple).take(3), [1, 2, 1]);
        expect(session.tracks[1].lanes[1].pan, 0.5);
        expect(session.tracks[1].lanes[1].balance, 0.75);
        expect(session.tracks[2].lanes.single.redoCount, 1);
        expect(session.trackPans, {1: -0.25});
        expect(session.trackLengthPresetOverrides, {1: 2});
        expect(session.trackOneShotOverrides, {2: true, 5: true});
        expect(session.defaultLengthPresetBars, 4);
        expect(session.inputSetup.trimDb, {0: -3});
        expect(session.outputSetup.mono, {1: true});
        expect(session.tempoBpm, 100);
        expect(session.tsNum, 3);
        expect(session.primaryTrack, 0);
        // The saved bus chain lands on its destination: the schema-8 Master
        // insert was output bus 0's chain.
        expect(session.outputChains.single.bus, outputBus);
        expect(
          session.outputChains.single.encoded,
          original['masterChain'] ??
              _first(original['outputChains'])['encoded'],
        );
        expect(session.monitors.map((m) => m.mode), ['auto', 'on']);
        expect(session.monitors[0].volume, lessThanOrEqualTo(1));
        // In schemas 8 and 9 the Master stage was output bus 0, and so its
        // pedal. From 10 on a Master binding was already inert as written.
        expect(_bindingTargets(session.pedalBindings).last, {
          'stage': version <= 9 ? 'output' : 'master',
          'index': 0,
        });
        expect(session.defaultFadeDurationMs, version >= 10 ? 6000 : 4000);
        // No schema before 13 saved a direction: every track comes back
        // forward, as it always recalled.
        expect(session.tracks.map((t) => t.reversed), everyElement(isFalse));
        expect(
          conversion.notes,
          contains('tracks[0].reversed: defaulted to forward'),
        );
        expect(
          session.tracks[0].lanes.single.history.entries.map((e) => e.kind),
          [HistoryKind.layer, HistoryKind.layer],
        );
        if (!name.contains('slices')) {
          // Saved explicitly from schema 8 on; the slices kept them global.
          expect(session.recDub, isTrue);
          expect(session.syncTempo, isFalse);
          expect(session.overdubDecay, 20);
        } else {
          // The slices saved record timing but kept the rest global.
          expect(session.recordTiming, RecordTiming.immediately);
          expect(session.recDub, _live.recDub);
          expect(session.defaultMultiple, _live.defaultMultiple);
        }
      });
    }

    test('v13_reverse_576826cfa keeps its directions and takes the live '
        'Audio & tempo settings (#1179)', () async {
      final dir = copyFixture('v13_reverse_576826cfa');
      final (:bundle, :conversion) = await repo().open(
        dir,
        liveSettings: () => _live,
      );
      final session = bundle.session;
      expect(conversion!.fromVersion, 13);
      expect(session.tracks.map((t) => t.reversed), [
        false,
        true,
        false,
        false,
      ]);
      // Global preferences before this schema: opening kept the live ones.
      expect(session.defaultFollowTempo, isFalse);
      expect(session.trackFollowTempoOverrides, {2: true});
      expect(session.defaultPitchMode, PitchMode.followsSpeed);
      expect(session.trackPitchModeOverrides, {4: PitchMode.unchanged});
      expect(
        conversion.notes,
        containsAll([
          'defaultFollowTempo: taken from the live setting',
          'trackPitchModeOverrides: taken from the live setting',
        ]),
      );
    });

    test('the current schema opens with no conversion', () async {
      final dir = copyFixture('v14_audio_tempo_4b');
      final before = snapshotOf(dir);
      final (:bundle, :conversion) = await repo().open(dir);
      expect(conversion, isNull);
      expect(
        bundle.session,
        Session.fromJson(manifestOf(dir)),
      );
      expect(bundle.session.tracks.map((t) => t.reversed), [
        false,
        true,
        false,
        false,
      ]);
      expect(bundle.session.defaultFollowTempo, isFalse);
      expect(snapshotOf(dir), before);
    });

    test('the current schema stays strict: a track without a direction is '
        'refused, not defaulted', () {
      for (final key in ['reversed']) {
        final manifest = manifestOf(copyFixture('v14_audio_tempo_4b'));
        ((manifest['tracks'] as List)[1] as Map).remove(key);
        expect(
          () => decodeSessionManifest(jsonEncode(manifest)),
          throwsFormatException,
          reason: key,
        );
      }
      for (final key in ['defaultFollowTempo', 'trackPitchModeOverrides']) {
        final manifest = manifestOf(copyFixture('v14_audio_tempo_4b'))
          ..remove(key);
        expect(
          () => decodeSessionManifest(jsonEncode(manifest)),
          throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
          reason: key,
        );
      }
    });
  });

  group('commitConversion', () {
    test('keeps the original beside the converted manifest, and the converted '
        'bundle reads back as the current schema', () async {
      final dir = copyFixture('v7_master_full');
      final original = File('$dir/${Session.manifestName}').readAsBytesSync();
      final repository = repo();
      final opened = await repository.open(dir, liveSettings: () => _live);

      await repository.commitConversion(dir, opened.conversion!);

      expect(File('$dir/session.v7.json').readAsBytesSync(), original);
      expect(manifestOf(dir)['version'], Session.formatVersion);
      final reopened = await repository.open(dir);
      expect(reopened.conversion, isNull);
      expect(reopened.bundle.session, opened.bundle.session);
      expect(
        Directory(dir).listSync().map((f) => f.uri.pathSegments.last),
        isNot(contains(endsWith('.tmp'))),
      );
    });

    test('never overwrites an existing backup', () async {
      final dir = copyFixture('v7_master_full');
      File('$dir/session.v7.json').writeAsStringSync('someone else');
      final repository = repo();
      final original = File('$dir/${Session.manifestName}').readAsStringSync();

      await repository.commitConversion(
        dir,
        (await repository.open(dir)).conversion!,
      );

      expect(File('$dir/session.v7.json').readAsStringSync(), 'someone else');
      expect(File('$dir/session.v7.2.json').readAsStringSync(), original);
    });

    test('reuses a backup that already holds the original', () async {
      final dir = copyFixture('v7_master_full');
      final original = File('$dir/${Session.manifestName}').readAsStringSync();
      File('$dir/session.v7.json').writeAsStringSync(original);
      final repository = repo();

      await repository.commitConversion(
        dir,
        (await repository.open(dir)).conversion!,
      );

      expect(File('$dir/session.v7.2.json').existsSync(), isFalse);
      expect(manifestOf(dir)['version'], Session.formatVersion);
    });

    test('writes nothing when the manifest changed after opening', () async {
      final dir = copyFixture('v7_master_full');
      final repository = repo();
      final conversion = (await repository.open(dir)).conversion!;
      File('$dir/${Session.manifestName}').writeAsStringSync('{"version": 7}');
      final before = snapshotOf(dir);

      await repository.commitConversion(dir, conversion);

      expect(snapshotOf(dir), before);
    });
  });

  group('a refused bundle is left byte-identical', () {
    Future<void> expectRefused(
      String dir,
      Matcher matcher, {
      FakeSessionEngine? engine,
    }) async {
      final before = snapshotOf(dir);
      final repository = SessionRepository(
        guards: GuardRegistry(),
        engine: engine ?? FakeSessionEngine(),
      );
      await expectLater(
        repository.open(dir, liveSettings: () => _live),
        throwsA(matcher),
      );
      expect(snapshotOf(dir), before);
    }

    void rewrite(String dir, void Function(Map<String, dynamic>) edit) {
      final manifest = manifestOf(dir);
      edit(manifest);
      File(
        '$dir/${Session.manifestName}',
      ).writeAsStringSync(jsonEncode(manifest));
    }

    test('newer than this build', () async {
      final dir = copyFixture('v13_reverse_576826cfa');
      rewrite(dir, (m) => m['version'] = Session.formatVersion + 1);
      await expectRefused(dir, isA<SessionUnsupportedVersion>());
    });

    test('older than the oldest convertible schema', () async {
      final dir = copyFixture('v7_master_full');
      rewrite(dir, (m) => m['version'] = 0);
      await expectRefused(
        dir,
        isA<SessionUnconvertible>().having((e) => e.version, 'version', 0),
      );
    });

    test('a step that cannot convert it', () async {
      final dir = copyFixture('v7_master_full');
      rewrite(dir, (m) => m['oneShotChannels'] = 'every');
      await expectRefused(dir, isA<SessionUnconvertible>());
    });

    test('a conversion the current schema refuses', () async {
      final dir = copyFixture('v7_master_full');
      rewrite(dir, (m) => m['countInBars'] = 3);
      await expectRefused(dir, isA<SessionUnconvertible>());
    });

    test('a converted tempo the current schema refuses', () async {
      final dir = copyFixture('v7_master_full');
      rewrite(dir, (m) => m['tempoBpm'] = 400);
      await expectRefused(dir, isA<SessionUnconvertible>());
    });

    test('recorded at another sample rate', () async {
      await expectRefused(
        copyFixture('v7_master_full'),
        isA<SessionSampleRateMismatch>(),
        engine: FakeSessionEngine(sampleRate: 44100),
      );
    });
  });

  group('the original survives saving the converted session', () {
    /// An engine holding different audio under the same layer names.
    FakeSessionEngine newTake() =>
        FakeSessionEngine()
          ..seedTrack(0, Float32List.fromList(List.filled(2400, -0.5)));

    Future<void> expectOriginalOpens(String backup, String fixture) async {
      final opened = await repo().open(backup);
      expect(opened.conversion, isNotNull);
      for (final name in snapshotOf('$_fixtures/$fixture').keys) {
        if (name == Session.manifestName || name == 'mixdown.wav') continue;
        expect(
          File('$backup/$name').readAsBytesSync(),
          File('$_fixtures/$fixture/$name').readAsBytesSync(),
          reason: name,
        );
      }
    }

    test('after the conversion was written back', () async {
      final dir = copyFixture('v7_master_full');
      final repository = repo();
      await repository.commitConversion(
        dir,
        (await repository.open(dir)).conversion!,
      );

      await SessionRepository(
        guards: GuardRegistry(),
        engine: newTake(),
      ).save(dir, settings: const SessionSettings());

      expect(File('$dir/session.v7.json').existsSync(), isFalse);
      await expectOriginalOpens('$dir/session.v7', 'v7_master_full');
      expect(manifestOf(dir)['version'], Session.formatVersion);
      // A second save keeps the backup folder as it is.
      await SessionRepository(
        guards: GuardRegistry(),
        engine: newTake(),
      ).save(dir, settings: const SessionSettings());
      await expectOriginalOpens('$dir/session.v7', 'v7_master_full');
    });

    test('when the write-back never happened', () async {
      final dir = copyFixture('v7_master_full');

      await SessionRepository(
        guards: GuardRegistry(),
        engine: newTake(),
      ).save(dir, settings: const SessionSettings());

      await expectOriginalOpens('$dir/session.v7', 'v7_master_full');
      expect(manifestOf(dir)['version'], Session.formatVersion);
    });

    test('for a schema-1 bundle, whose stems are not layer files', () async {
      final dir = copyFixture('v1_loopy_8547affe7');

      await SessionRepository(
        guards: GuardRegistry(),
        engine: newTake(),
      ).save(dir, settings: const SessionSettings());

      await expectOriginalOpens('$dir/session.v1', 'v1_loopy_8547affe7');
      expect(File('$dir/track1.wav').existsSync(), isFalse);
    });

    group('when the save is cut off after its swap', () {
      late String root;
      late String bundle;

      setUp(() async {
        root = '${tempDir.path}/root';
        Directory(root).createSync();
        bundle = '$root/s-old';
        Directory(copyFixture('v7_master_full')).renameSync(bundle);
        final repository = repo();
        await repository.commitConversion(
          bundle,
          (await repository.open(bundle)).conversion!,
        );
      });

      SessionRepository catalog() => SessionRepository(
        guards: GuardRegistry(),
        engine: FakeSessionEngine(),
        sessionsRoot: () async => root,
      );

      test('the next catalog read finishes keeping the original', () async {
        // The state a power cut between the swap and the move leaves: the
        // new save in place and the previous bundle still beside it.
        Directory(bundle).renameSync('$bundle.old');
        await SessionRepository(
          guards: GuardRegistry(),
          engine: newTake(),
        ).save(bundle, settings: const SessionSettings());

        await catalog().listSessions();

        expect(Directory('$bundle.old').existsSync(), isFalse);
        await expectOriginalOpens('$bundle/session.v7', 'v7_master_full');
      });

      test('a move cut off part-way resumes into the same folder', () async {
        var cut = true;
        SessionRepository.debugOnKeepOriginal = (_) {
          if (cut) {
            cut = false;
            throw const FileSystemException('power cut');
          }
        };
        addTearDown(() => SessionRepository.debugOnKeepOriginal = null);

        await SessionRepository(
          guards: GuardRegistry(),
          engine: newTake(),
        ).save(bundle, settings: const SessionSettings());
        expect(Directory('$bundle.old/session.v7').existsSync(), isTrue);

        await catalog().listSessions();

        expect(Directory('$bundle.old').existsSync(), isFalse);
        expect(Directory('$bundle/session.v7.2').existsSync(), isFalse);
        await expectOriginalOpens('$bundle/session.v7', 'v7_master_full');
      });
    });

    test('a failed save leaves the original bundle as it was', () async {
      final dir = copyFixture('v7_master_full');
      final before = snapshotOf(dir);
      SessionRepository.debugOnSaveWrite = (path) {
        if (path.endsWith(Session.manifestName)) {
          throw const FileSystemException('disk full');
        }
      };
      addTearDown(() => SessionRepository.debugOnSaveWrite = null);

      await expectLater(
        SessionRepository(
          guards: GuardRegistry(),
          engine: newTake(),
        ).save(dir, settings: const SessionSettings()),
        throwsA(isA<FileSystemException>()),
      );

      expect(snapshotOf(dir), before);
    });
  });

  group('commitConversion order', () {
    test(
      'a backup that cannot be kept leaves the manifest unchanged',
      () async {
        final dir = copyFixture('v7_master_full');
        final repository = repo();
        final conversion = (await repository.open(dir)).conversion!;
        // A directory where the backup goes makes keeping it fail.
        Directory('$dir/session.v7.json').createSync();
        final before = File('$dir/${Session.manifestName}').readAsBytesSync();

        await expectLater(
          repository.commitConversion(dir, conversion),
          throwsA(isA<FileSystemException>()),
        );

        expect(File('$dir/${Session.manifestName}').readAsBytesSync(), before);
      },
    );

    test('a failed rename removes its temporary manifest', () async {
      final dir = copyFixture('v7_master_full');
      final repository = repo();
      final conversion = (await repository.open(dir)).conversion!;
      final before = File('$dir/${Session.manifestName}').readAsBytesSync();
      SessionRepository.debugOnReplaceManifest = (_) =>
          throw const FileSystemException('rename refused');
      addTearDown(() => SessionRepository.debugOnReplaceManifest = null);

      await expectLater(
        repository.commitConversion(dir, conversion),
        throwsA(isA<FileSystemException>()),
      );

      expect(File('$dir/${Session.manifestName}.tmp').existsSync(), isFalse);
      expect(File('$dir/${Session.manifestName}').readAsBytesSync(), before);
    });

    test('reports nothing written when the manifest changed', () async {
      final dir = copyFixture('v7_master_full');
      final repository = repo();
      final conversion = (await repository.open(dir)).conversion!;
      File('$dir/${Session.manifestName}').writeAsStringSync('{}');

      expect(await repository.commitConversion(dir, conversion), isFalse);
    });

    test(
      'the manifest is replaced by a rename, not rewritten in place',
      () async {
        final dir = copyFixture('v7_master_full');
        final repository = repo();
        final conversion = (await repository.open(dir)).conversion!;
        // A read-only manifest cannot be rewritten, only replaced.
        await Process.run('chmod', ['444', '$dir/${Session.manifestName}']);

        await repository.commitConversion(dir, conversion);

        expect(manifestOf(dir)['version'], Session.formatVersion);
        expect(File('$dir/${Session.manifestName}.tmp').existsSync(), isFalse);
      },
    );
  });

  test('a converted bundle with a broken layer stack reports it', () async {
    final dir = copyFixture('v7_master_full');
    final manifest = manifestOf(dir);
    final lane = (_first(manifest['tracks'])['lanes'] as List).first as Map;
    (lane['layers'] as List).removeLast();
    File(
      '$dir/${Session.manifestName}',
    ).writeAsStringSync(jsonEncode(manifest));

    await expectLater(
      repo().open(dir),
      throwsA(isA<SessionCorruptLayers>()),
    );
  });

  group('a schema older than 7 written by its own commit', () {
    test('1: the saved transport settings, and each stem as lane 0', () async {
      final (:bundle, :conversion) = await repo().open(
        copyFixture('v1_loopy_8547affe7'),
        liveSettings: () => _live,
      );
      final session = bundle.session;
      expect(conversion!.fromVersion, 1);
      expect(session.tempoBpm, 96);
      expect(session.tempoSource, TempoSource.manual);
      expect((session.tsNum, session.tsDen), (4, 4));
      expect(session.syncTempo, isTrue);
      expect(session.recordTiming, RecordTiming.quarter);
      expect(session.quantizeDiv, GridDivision.quarter);
      expect(session.clickMode, ClickMode.playRec);
      expect(session.countInBars, 1);
      expect(session.laneChains, isEmpty);
      expect(session.monitors, isEmpty);
      final lane = session.tracks[1].lanes.single;
      expect(lane.layers.single.file, 'track1.wav');
      expect((lane.volume, lane.muted, lane.outputMask), (0.5, true, 0x3));
      expect(lane.inputChannel, -1);
      expect(bundle.laneStems[(1, 0)]!.single, hasLength(4800));
    });

    for (final (name, version) in const [
      ('v2_loopy_93f2f0cb5', 2),
      ('v3_loopy_319a7dc9d', 3),
    ]) {
      test('$version: a tempo derived from the loop', () async {
        final (:bundle, :conversion) = await repo().open(
          copyFixture(name),
          liveSettings: () => _live,
        );
        final session = bundle.session;
        expect(conversion!.fromVersion, version);
        // 2400 frames at 48 kHz is shorter than one 4/4 bar at 300 bpm, so
        // the engine's rule takes one bar at 300.
        expect(session.tempoBpm, 300);
        expect(session.tempoSource, TempoSource.derived);
        expect(session.loopBars, 1);
        expect(
          conversion.changes,
          contains(SessionConversionChange.tempoFromLoop),
        );
        // Bare-array chains of these schemas are kept as written.
        expect(session.laneChains.single.encoded, startsWith('['));
        expect(session.monitors.single.mode, 'on');
        expect(session.monitors.single.volume, 1);
        expect(session.trackChains, isEmpty);
        expect(session.allTracksChain, '');
        expect(session.syncTempo, _live.syncTempo);
      });
    }

    test('a loop of whole bars derives the tempo nearest 120', () {
      final manifest = manifestOf(copyFixture('v3_loopy_319a7dc9d'))
        ..['baseLengthFrames'] = 96000;
      final session = decodeSessionManifest(jsonEncode(manifest)).session;
      // 2 s at 48 kHz: one 4/4 bar is 120 bpm.
      expect((session.tempoBpm, session.loopBars), (120, 1));
    });

    for (final (name, version) in const [
      ('v4_loopy_fb8d7cc2b', 4),
      ('v5_loopy_b52c3d276', 5),
      ('v6_loopy_4dc33ac10', 6),
    ]) {
      test('$version: its saved grid, Once tracks and chains', () async {
        final dir = copyFixture(name);
        final original = manifestOf(dir);
        final (:bundle, :conversion) = await repo().open(dir);
        final session = bundle.session;
        expect(conversion!.fromVersion, version);
        expect(session.tempoBpm, 110);
        expect(session.tempoSource, TempoSource.manual);
        expect(session.tsNum, 3);
        expect(session.looperMode, LooperMode.sync);
        expect(session.trackOneShotOverrides, {1: true});
        expect(session.tracks[0].lanes.single.undoCount, 1);
        expect(
          session.allTracksChain,
          version >= 5 ? original['masterChain'] : '',
        );
        expect(session.trackChains, hasLength(version >= 5 ? 1 : 0));
        expect(
          _bindingTargets(session.pedalBindings),
          version == 6 ? hasLength(2) : isEmpty,
        );
      });
    }
  });

  group('steps', () {
    Map<String, dynamic> v7() => manifestOf(copyFixture('v7_master_full'));

    Session convert(Map<String, dynamic> manifest) =>
        decodeSessionManifest(jsonEncode(manifest)).session;

    test('a master track length preset becomes the track setting', () {
      final manifest = v7();
      ((manifest['tracks'] as List)[1] as Map)['lengthPresetBars'] = 2;
      expect(convert(manifest).trackLengthPresetOverrides, {1: 2});
    });

    test('a per-track One Shot flag becomes the track setting', () {
      final manifest = v7()..['oneShotChannels'] = <int>[];
      expect(convert(manifest).trackOneShotOverrides, {2: true});
    });

    test('a monitor without a gate name follows its enabled flag', () {
      final manifest = v7();
      for (final (i, enabled) in [(0, false), (1, true)]) {
        ((manifest['monitors'] as List)[i] as Map)
          ..remove('mode')
          ..['enabled'] = enabled;
      }
      expect(convert(manifest).monitors.map((m) => m.mode), ['off', 'on']);
    });

    test("the slices' Once default becomes the session default", () {
      final manifest = manifestOf(copyFixture('v8_slices_be987759d'))
        ..['defaultOnce'] = true;
      expect(convert(manifest).defaultOneShot, isTrue);
    });

    test('a schema-9 Master insert becomes output bus 0', () {
      final manifest = manifestOf(copyFixture('v9_trunk_623a5a7ba'));
      final chain = _first(manifest['outputChains'])['encoded'];
      (manifest['outputChains'] as List).removeAt(0);
      manifest['masterChain'] = chain;
      expect(
        convert(manifest).outputChains.single,
        SessionOutputChain(bus: 0, encoded: chain as String),
      );
    });

    test('a Master insert beside an output bus 0 chain cannot convert', () {
      final manifest = manifestOf(copyFixture('v9_trunk_623a5a7ba'));
      _first(manifest['outputChains'])['bus'] = 0;
      manifest['masterChain'] = '{"entries":[]}';
      expect(
        () => convert(manifest),
        throwsA(isA<SessionUnconvertible>()),
      );
    });

    test('the strict decoder still reads only the current schema', () {
      expect(
        () => Session.fromJson(v7()),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });
  });
}

/// The decoded target of every pedal binding in a session blob.
List<Map<String, dynamic>> _bindingTargets(String blob) => blob.isEmpty
    ? const []
    : [
        for (final binding in jsonDecode(blob) as List<dynamic>)
          jsonDecode((binding as Map<String, dynamic>)['target'] as String)
              as Map<String, dynamic>,
      ];

Map<String, dynamic> _first(Object? list) =>
    (list! as List<dynamic>).first as Map<String, dynamic>;
