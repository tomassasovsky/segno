import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
);

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('segno_convert'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  SessionRepository repo() => SessionRepository(
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
        expect(session.pedalBindings, original['pedalBindings']);

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
        expect(session.trackRecordTimingOverrides, {3: RecordTiming.bar});
        expect(session.overdubDecay, 0);
        expect(session.trackOverdubDecayOverrides, isEmpty);
        expect(session.defaultFadeDurationMs, 4000);
        expect(session.trackFadeDurationOverrides, isEmpty);
        expect(session.trackLevels, isEmpty);
        expect(session.trackPans, isEmpty);
        expect(session.inputSetup, const SessionInputSetup());
        expect(session.outputSetup, const SessionOutputSetup());

        expect(conversion!.fromVersion, 7);
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
        expect(session.tracks.map((t) => t.multiple), [1, 2, 1]);
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
        expect(session.pedalBindings, original['pedalBindings']);
        expect(session.defaultFadeDurationMs, version == 10 ? 6000 : 4000);
        if (name.contains('trunk')) {
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

    test('the current schema opens with no conversion', () async {
      final dir = copyFixture('v11_trunk_5c163d11f');
      final before = snapshotOf(dir);
      final (:bundle, :conversion) = await repo().open(dir);
      expect(conversion, isNull);
      expect(
        bundle.session,
        Session.fromJson(manifestOf(dir)),
      );
      expect(snapshotOf(dir), before);
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
      final dir = copyFixture('v11_trunk_5c163d11f');
      rewrite(dir, (m) => m['version'] = Session.formatVersion + 1);
      await expectRefused(dir, isA<SessionUnsupportedVersion>());
    });

    test('older than the oldest convertible schema', () async {
      final dir = copyFixture('v7_master_full');
      rewrite(dir, (m) => m['version'] = 6);
      await expectRefused(
        dir,
        isA<SessionUnconvertible>().having((e) => e.version, 'version', 6),
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

  test('saving over an older manifest keeps it as the backup', () async {
    final dir = copyFixture('v7_master_full');
    final original = File('$dir/${Session.manifestName}').readAsBytesSync();

    await repo().save(dir, settings: const SessionSettings());

    expect(File('$dir/session.v7.json').readAsBytesSync(), original);
    expect(manifestOf(dir)['version'], Session.formatVersion);
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

Map<String, dynamic> _first(Object? list) =>
    (list! as List<dynamic>).first as Map<String, dynamic>;
