import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:settings_repository/settings_repository.dart';

class _InMemoryStore implements KeyValueStore {
  final Map<String, Object> values = {};
  String? failNextKey;
  String? failNextReadKey;
  String? failAfterWriteKey;
  String? failOnSetValue;
  String? discardNextWriteKey;
  String? discardNextRemovalKey;
  String? failAfterRemovalKey;
  Completer<void>? boolWrite;
  final boolEntered = Completer<void>();

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<String?> getString(String key) async {
    if (failNextReadKey == key) {
      failNextReadKey = null;
      throw StateError('storage read failed');
    }
    return values[key] as String?;
  }

  @override
  Future<void> setString(String key, String value) async {
    if (discardNextWriteKey == key) {
      discardNextWriteKey = null;
      return;
    }
    if (value == failOnSetValue) {
      throw StateError('checkpoint restoration refused');
    }
    if (failNextKey == key) {
      failNextKey = null;
      throw StateError('storage write failed');
    }
    values[key] = value;
    if (failAfterWriteKey == key) {
      failAfterWriteKey = null;
      throw StateError('storage reported failure after writing');
    }
  }

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (!boolEntered.isCompleted) boolEntered.complete();
    await boolWrite?.future;
    if (discardNextWriteKey == key) {
      discardNextWriteKey = null;
      return;
    }
    values[key] = value;
    if (failAfterWriteKey == key) {
      failAfterWriteKey = null;
      throw StateError('scalar wrote then failed');
    }
  }

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async {
    if (discardNextWriteKey == key) {
      discardNextWriteKey = null;
      return;
    }
    if (failNextKey == key) {
      failNextKey = null;
      throw StateError('scalar write failed');
    }
    values[key] = value;
    if (failAfterWriteKey == key) {
      failAfterWriteKey = null;
      throw StateError('scalar wrote then failed');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (discardNextRemovalKey == key) {
      discardNextRemovalKey = null;
      return;
    }
    if (failNextKey == key) {
      failNextKey = null;
      throw StateError('storage write failed');
    }
    values.remove(key);
    if (failAfterRemovalKey == key) {
      failAfterRemovalKey = null;
      throw StateError('storage reported failure after removing');
    }
  }

  @override
  Future<void> clear() async => values.clear();
}

void main() {
  late _InMemoryStore store;
  late SettingsRepository repository;

  setUp(() {
    store = _InMemoryStore();
    repository = SettingsRepository(store: store);
  });

  group('Fade duration record', () {
    test(
      'orders after other scalar writes and restores exact bytes or absence',
      () async {
        expect(await repository.readFadeDurationsCheckpoint(), isNull);
        store.boolWrite = Completer<void>();
        final mute = repository.saveLaneMute(0, 0, muted: true);
        await store.boolEntered.future;
        final fade = repository.saveFadeDurations(
          FadeDurations(overrides: const {0: 4000}),
        );
        final read = repository.readFadeDurationsCheckpoint();
        store.boolWrite!.complete();
        await Future.wait([mute, fade]);
        expect(await read, '{"defaultMs":4000,"overrides":{"0":4000}}');
        const original = '{ "overrides": {}, "defaultMs":500 }';
        await repository.restoreFadeDurationsCheckpoint(original);
        expect(await repository.readFadeDurationsCheckpoint(), original);
        await repository.restoreFadeDurationsCheckpoint(null);
        expect(await repository.readFadeDurationsCheckpoint(), isNull);
      },
    );

    test('reports a lost write without poisoning the shared tail', () async {
      store.discardNextWriteKey = 'looper.fade_durations';
      await expectLater(
        repository.saveFadeDurations(FadeDurations.defaults),
        throwsStateError,
      );
      await repository.saveFadeDurations(FadeDurations(defaultMs: 30000));
      expect(
        await repository.readFadeDurationsCheckpoint(),
        '{"defaultMs":30000,"overrides":{}}',
      );
    });
  });

  group('instruments record', () {
    test('restores exact bytes or absence', () async {
      expect(await repository.readInstrumentsCheckpoint(), isNull);
      const record = '{"version":1,"instruments":[]}';
      await repository.restoreInstrumentsCheckpoint(record);
      expect(await repository.readInstrumentsCheckpoint(), record);
      await repository.restoreInstrumentsCheckpoint(null);
      expect(await repository.readInstrumentsCheckpoint(), isNull);
    });

    test('reports a lost write', () async {
      store.discardNextWriteKey = 'instruments.working_copy';
      await expectLater(
        repository.restoreInstrumentsCheckpoint('{}'),
        throwsStateError,
      );
      expect(await repository.readInstrumentsCheckpoint(), isNull);
    });
  });

  group('lane mute scalar', () {
    test(
      'orders a rapid pair of writes and reads behind blocked storage',
      () async {
        store.boolWrite = Completer<void>();
        final first = repository.saveLaneMute(0, 0, muted: true);
        await store.boolEntered.future;
        final second = repository.saveLaneMute(0, 0, muted: false);
        final read = repository.loadLaneMute(0, 0);
        store.boolWrite!.complete();
        await Future.wait([first, second]);
        expect(await read, isFalse);
      },
    );

    test('refuses silent storage loss and permits deliberate retry', () async {
      store.discardNextWriteKey = 'lane_mute.0.0';
      await expectLater(
        repository.saveLaneMute(0, 0, muted: true),
        throwsStateError,
      );
      expect(await repository.loadLaneMute(0, 0), isNull);
      await repository.saveLaneMute(0, 0, muted: true);
      expect(await repository.loadLaneMute(0, 0), isTrue);
    });

    test(
      'mutation then error fails the write '
      'without pretending bytes rolled back',
      () async {
        store.failAfterWriteKey = 'lane_mute.0.0';
        await expectLater(
          repository.saveLaneMute(0, 0, muted: true),
          throwsStateError,
        );
        expect(await repository.loadLaneMute(0, 0), isTrue);
        await repository.saveLaneMute(0, 0, muted: false);
        expect(await repository.loadLaneMute(0, 0), isFalse);
      },
    );
  });

  group('live-input gain admission', () {
    for (final raw in ['-0.1', '2.5', '1e999']) {
      test(
        'rejects saved monitor gain $raw without changing saved bytes',
        () async {
          final checkpoint =
              '{"trackLevels":{"0":1.5},"monitorLevels":{"0":0.5,"1":$raw}}';
          store.values['mix_settings'] = checkpoint;
          await expectLater(
            repository.loadMixSettings('device'),
            throwsFormatException,
          );
          await expectLater(
            repository.loadMonitorVolume(0),
            throwsFormatException,
          );
          expect(store.values, {'mix_settings': checkpoint});
        },
      );
    }
    for (final raw in ['1.01', '2']) {
      test(
        'reads legacy monitor gain $raw as unity and writes it back once',
        () async {
          store.values['mix_settings'] =
              '{"trackLevels":{"0":1.5},"monitorLevels":{"0":0.5,"1":$raw}}';
          final loaded = await repository.loadMixSettings('device');
          expect(loaded.monitorLevels[0], 0.5);
          expect(loaded.monitorLevels[1] ?? 1, 1);
          expect(loaded.trackLevels[0], 1.5, reason: 'track gain untouched');
          final stored =
              jsonDecode(store.values['mix_settings']! as String)
                  as Map<String, dynamic>;
          final monitors = stored['monitorLevels'] as Map<String, dynamic>;
          expect(
            monitors.values.every((gain) => (gain as num) <= 1),
            isTrue,
            reason: 'storage no longer carries a gain above unity',
          );
          expect(await repository.loadMonitorVolume(1), 1);
        },
      );
    }
    test('a failing legacy write-back still loads the repaired gain', () async {
      store
        ..values['mix_settings'] = '{"monitorLevels":{"1":1.5}}'
        ..failNextKey = 'mix_settings';
      final loaded = await repository.loadMixSettings('device');
      expect(loaded.monitorLevels[1] ?? 1, 1);
    });

    test('writes accept unity and refuse invalid monitor gain', () async {
      await repository.saveMonitorVolume(0, 0.5);
      final before = Map<String, Object>.of(store.values);
      for (final value in [-0.1, 1.01, double.nan, double.infinity]) {
        await expectLater(
          repository.saveMonitorVolume(0, value),
          throwsArgumentError,
        );
        expect(store.values, before);
      }
      await repository.saveMonitorVolume(0, 1);
      expect(await repository.loadMonitorVolume(0), isNull);
    });
  });

  group('Click scalar checkpoint', () {
    test(
      'absence and explicit unity remain distinct after restoration',
      () async {
        expect(await repository.readClickVolumeCheckpoint(), isNull);
        await repository.restoreClickVolumeCheckpoint(1.5);
        await repository.restoreClickVolumeCheckpoint(null);
        expect(store.values.containsKey('tempo.click_volume'), isFalse);
        await repository.restoreClickVolumeCheckpoint(1);
        final checkpoint = await repository.readClickVolumeCheckpoint();
        await repository.restoreClickVolumeCheckpoint(.25);
        await repository.restoreClickVolumeCheckpoint(checkpoint);
        expect(store.values['tempo.click_volume'], 1);
      },
    );
    test(
      'unconfirmed scalar write is rejected and next write still works',
      () async {
        await repository.restoreClickVolumeCheckpoint(.5);
        store.discardNextWriteKey = 'tempo.click_volume';
        await expectLater(
          repository.restoreClickVolumeCheckpoint(1.5),
          throwsStateError,
        );
        expect(await repository.readClickVolumeCheckpoint(), .5);
        await repository.restoreClickVolumeCheckpoint(.25);
        expect(await repository.readClickVolumeCheckpoint(), .25);
      },
    );
    test(
      'write-then-failure checkpoint can restore exact prior scalar',
      () async {
        await repository.restoreClickVolumeCheckpoint(.5);
        final checkpoint = await repository.readClickVolumeCheckpoint();
        store.failAfterWriteKey = 'tempo.click_volume';
        await expectLater(
          repository.restoreClickVolumeCheckpoint(1.5),
          throwsStateError,
        );
        expect(store.values['tempo.click_volume'], 1.5);
        await repository.restoreClickVolumeCheckpoint(checkpoint);
        expect(await repository.readClickVolumeCheckpoint(), .5);
      },
    );
    test('failed restoration is not reported as confirmed', () async {
      store.failNextKey = 'tempo.click_volume';
      await expectLater(
        repository.restoreClickVolumeCheckpoint(1),
        throwsStateError,
      );
      expect(store.values.containsKey('tempo.click_volume'), isFalse);
    });
  });

  group('latency offset', () {
    test('returns null when nothing is stored', () async {
      final value = await repository.loadLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
      );
      expect(value, isNull);
    });

    test('round-trips a saved value for a device profile', () async {
      await repository.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        frames: 480,
      );

      expect(
        await repository.loadLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
        ),
        480,
      );
    });

    test(
      'keys are distinct per device, sample rate, and buffer size',
      () async {
        await repository.saveLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 48000,
          bufferFrames: 128,
          frames: 480,
        );

        // Same device, different buffer size -> independent value.
        expect(
          await repository.loadLatencyOffsetFrames(
            device: 'Scarlett',
            sampleRate: 48000,
            bufferFrames: 256,
          ),
          isNull,
        );
        // Different device -> independent value.
        expect(
          await repository.loadLatencyOffsetFrames(
            device: 'BlackHole',
            sampleRate: 48000,
            bufferFrames: 128,
          ),
          isNull,
        );

        expect(store.values, hasLength(1));
      },
    );

    test('without alsaPeriods the key keeps its historical shape', () async {
      // Pins the exact stored key: every pre-existing desktop calibration
      // lives under this shape, and folding the ALSA period count into the
      // key (#809) must not disturb it when the knob is not engaged.
      await repository.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 48000,
        bufferFrames: 128,
        frames: 480,
      );

      expect(store.values, {'latency_offset.Scarlett.48000.128': 480});
    });

    test('with alsaPeriods the key carries the period count', () async {
      final appliance = SettingsRepository(store: store, alsaPeriods: 8);
      await appliance.saveLatencyOffsetFrames(
        device: 'Scarlett',
        sampleRate: 96000,
        bufferFrames: 64,
        frames: 240,
      );

      expect(store.values, {'latency_offset.Scarlett.96000.64.p8': 240});
    });

    test(
      'a period-qualified offset is invisible to the legacy key',
      () async {
        // The period count moves the playback start threshold (#809), so an
        // offset calibrated under a period count must not leak into the
        // legacy (period-less) profile.
        final appliance = SettingsRepository(store: store, alsaPeriods: 8);
        await appliance.saveLatencyOffsetFrames(
          device: 'Scarlett',
          sampleRate: 96000,
          bufferFrames: 64,
          frames: 240,
        );
        expect(
          await repository.loadLatencyOffsetFrames(
            device: 'Scarlett',
            sampleRate: 96000,
            bufferFrames: 64,
          ),
          isNull,
        );
      },
    );
  });

  group('latency offset migration (legacy -> period-qualified)', () {
    // #809 shifts real output latency by exactly the start-threshold delta:
    // max(0, bufferFrames * periods ~/ 2 - 2 * bufferFrames). A pre-#809
    // calibration is therefore not discarded (nothing re-measures on the
    // appliance) but shifted by that delta and persisted under the qualified
    // key on first read.
    Future<int?> load(SettingsRepository repo) => repo.loadLatencyOffsetFrames(
      device: 'Scarlett',
      sampleRate: 96000,
      bufferFrames: 64,
    );

    test(
      'legacy present and p8 absent returns legacy + delta and persists it',
      () async {
        // p8 @ 64 frames: halfRing 256 - legacy threshold 128 = 128 frames.
        store.values['latency_offset.Scarlett.96000.64'] = 480;

        final appliance = SettingsRepository(store: store, alsaPeriods: 8);
        expect(await load(appliance), 608);
        expect(store.values, {
          // Downgrade path: the legacy entry is untouched, so a pre-#809
          // build still finds the value that is correct for it.
          'latency_offset.Scarlett.96000.64': 480,
          'latency_offset.Scarlett.96000.64.p8': 608,
        });

        // The qualified key now exists, so later reads use it verbatim.
        expect(await load(appliance), 608);
      },
    );

    test('an existing period-qualified value wins over legacy', () async {
      store.values['latency_offset.Scarlett.96000.64'] = 480;
      store.values['latency_offset.Scarlett.96000.64.p8'] = 240;

      final appliance = SettingsRepository(store: store, alsaPeriods: 8);
      expect(await load(appliance), 240);
      expect(store.values['latency_offset.Scarlett.96000.64'], 480);
    });

    test('legacy absent returns null and persists nothing', () async {
      final appliance = SettingsRepository(store: store, alsaPeriods: 8);
      expect(await load(appliance), isNull);
      expect(store.values, isEmpty);
    });

    test('desktop (no alsaPeriods) never migrates', () async {
      store.values['latency_offset.Scarlett.96000.64'] = 480;

      expect(await load(repository), 480);
      // No qualified key materialised, and the value is unshifted.
      expect(store.values, {'latency_offset.Scarlett.96000.64': 480});
    });

    test('delta tracks the start-threshold change per period count', () async {
      // threshold = max(2 * period, period * periods ~/ 2); legacy = 2 *
      // period. At 64-frame periods: p8 -> +128, p6 -> +64, and p4 / p2 sit
      // on the two-period floor -> +0.
      store.values['latency_offset.Scarlett.96000.64'] = 480;
      const expected = {8: 608, 6: 544, 4: 480, 2: 480};

      for (final MapEntry(key: periods, value: migrated) in expected.entries) {
        final appliance = SettingsRepository(
          store: store,
          alsaPeriods: periods,
        );
        expect(await load(appliance), migrated, reason: 'p$periods');
        expect(
          store.values['latency_offset.Scarlett.96000.64.p$periods'],
          migrated,
          reason: 'p$periods persists under its own key',
        );
      }
      expect(store.values['latency_offset.Scarlett.96000.64'], 480);
    });

    test(
      'a delta-0 migration still materialises the qualified key',
      () async {
        // At periods <= 4 the shift is 0 (#809 is a no-op there), but the
        // qualified key must still be written: subsequent saves then land on
        // the p4 key instead of overwriting the legacy entry, which stays a
        // pristine pre-#809 baseline for any later period-count migration.
        store.values['latency_offset.Scarlett.96000.64'] = 480;

        final appliance = SettingsRepository(store: store, alsaPeriods: 4);
        expect(await load(appliance), 480);
        expect(store.values, {
          'latency_offset.Scarlett.96000.64': 480,
          'latency_offset.Scarlett.96000.64.p4': 480,
        });
      },
    );
  });

  group('alsaPeriodsFromEnvironment', () {
    test('unset or empty means the knob is not engaged', () {
      expect(SettingsRepository.alsaPeriodsFromEnvironment(null), isNull);
      expect(SettingsRepository.alsaPeriodsFromEnvironment(''), isNull);
    });

    test('in-range values pass through', () {
      expect(SettingsRepository.alsaPeriodsFromEnvironment('2'), 2);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('5'), 5);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('8'), 8);
    });

    test('out-of-range values clamp to [2, 8], mirroring the engine', () {
      expect(SettingsRepository.alsaPeriodsFromEnvironment('0'), 2);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('1'), 2);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('-3'), 2);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('9'), 8);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('12'), 8);
      expect(
        SettingsRepository.alsaPeriodsFromEnvironment('99999999999999999999'),
        8,
      );
      expect(
        SettingsRepository.alsaPeriodsFromEnvironment('-99999999999999999999'),
        2,
      );
    });

    test('non-numeric input parses like strtol: no digits reads as 0', () {
      // strtol("abc") is 0, which the engine clamps to 2; "6junk" parses its
      // leading digits. The key must record what the engine actually uses.
      expect(SettingsRepository.alsaPeriodsFromEnvironment('abc'), 2);
      expect(SettingsRepository.alsaPeriodsFromEnvironment('6junk'), 6);
      expect(SettingsRepository.alsaPeriodsFromEnvironment(' 7'), 7);
    });
  });

  group('track names', () {
    test('round-trips a saved name', () async {
      await repository.saveTrackName(2, 'VOX');
      expect(await repository.loadTrackName(2), 'VOX');
      expect(await repository.loadTrackName(0), isNull);
    });
  });

  group('input names', () {
    test('round-trips a saved name', () async {
      await repository.saveInputName(device: 'Scarlett', input: 1, name: 'mic');
      expect(
        await repository.loadInputName(device: 'Scarlett', input: 1),
        'mic',
      );
      expect(
        await repository.loadInputName(device: 'Scarlett', input: 0),
        isNull,
      );
      // A different interface's socket 1 is a different jack.
      expect(
        await repository.loadInputName(device: 'Built-in', input: 1),
        isNull,
      );
    });

    test('clearing REMOVES the key, never stores an empty name', () async {
      // An input's fallback is not a name it was given, so a stored `''` would
      // be a name every later reader has to know to ignore. A track has no
      // equivalent — its fallback IS a name.
      await repository.saveInputName(
        device: 'Scarlett',
        input: 2,
        name: 'guitar',
      );
      await repository.clearInputName(device: 'Scarlett', input: 2);
      expect(
        await repository.loadInputName(device: 'Scarlett', input: 2),
        isNull,
      );
    });

    test('a name is kept per SOCKET, independent of the track keys', () async {
      await repository.saveInputName(device: 'Scarlett', input: 0, name: 'mic');
      await repository.saveTrackName(0, 'DRUMS');
      expect(
        await repository.loadInputName(device: 'Scarlett', input: 0),
        'mic',
      );
      expect(await repository.loadTrackName(0), 'DRUMS');
    });
  });

  group('output names', () {
    test('round-trips a saved name, keyed per device', () async {
      await repository.saveOutputName(
        device: 'Scarlett',
        bus: 1,
        name: 'monitors',
      );
      expect(
        await repository.loadOutputName(device: 'Scarlett', bus: 1),
        'monitors',
      );
      expect(await repository.loadOutputName(device: 'Scarlett', bus: 0), null);
      expect(await repository.loadOutputName(device: 'Built-in', bus: 1), null);
    });

    test('the unit is the DESTINATION, not the jack', () async {
      // Bus 1 is outputs 3 and 4. Its name must not collide with bus 3's, and
      // it must not collide with the per-jack output GATE either: a name and a
      // gate are different facts about different units.
      await repository.saveOutputName(
        device: 'Scarlett',
        bus: 1,
        name: 'monitors',
      );
      await repository.saveOutputEnabled(
        device: 'Scarlett',
        output: 1,
        enabled: false,
      );
      expect(await repository.loadOutputName(device: 'Scarlett', bus: 3), null);
      expect(
        await repository.loadOutputName(device: 'Scarlett', bus: 1),
        'monitors',
      );
      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 1),
        isFalse,
      );
    });

    test('clearing REMOVES the key, never stores an empty name', () async {
      await repository.saveOutputName(
        device: 'Scarlett',
        bus: 2,
        name: 'wedge',
      );
      await repository.clearOutputName(device: 'Scarlett', bus: 2);
      expect(await repository.loadOutputName(device: 'Scarlett', bus: 2), null);
    });
  });

  group('canonical lane routing', () {
    test(
      'one saved mix retains source, destination and count facts together',
      () async {
        await repository.replaceMixSettings(
          device: 'test',
          mix: (
            trackLevels: const {},
            trackPans: const {},
            laneLevels: const {(1, 0): 0.6},
            monitorLevels: const {},
            laneInputs: const {(1, 0): 2},
            laneOutputs: const {(1, 0): 0x5, (1, 7): 0x5},
            laneCounts: const {1: 2},
            inputSetup: const (trimDb: {}, pan: {}, pairs: {}),
            outputSetup: const (level: {}, muted: {}, mono: {}, balance: {}),
          ),
        );
        final loaded = await repository.loadMixSettings('test');
        expect(loaded.laneInputs, {(1, 0): 2});
        expect(loaded.laneOutputs, {(1, 0): 0x5, (1, 7): 0x5});
        expect(loaded.laneCounts, {1: 2});
        expect(loaded.laneLevels[(1, 0)], closeTo(0.6, 1e-6));
        expect(
          (await repository.loadMixSettings('other')).laneOutputs,
          loaded.laneOutputs,
        );
      },
    );
  });

  group('lane effects', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadLaneEffects(0, 0), isNull);
    });

    test('round-trips an encoded chain per (channel, lane)', () async {
      await repository.saveLaneEffects(1, 0, '[{"type":3}]');
      expect(await repository.loadLaneEffects(1, 0), '[{"type":3}]');
      expect(await repository.loadLaneEffects(1, 1), isNull);
      expect(await repository.loadLaneEffects(0, 0), isNull);
    });

    test(
      'removing a chain reads back as unset, not as the old value',
      () async {
        await repository.saveLaneEffects(1, 0, '[{"type":3}]');
        await repository.saveLaneEffects(1, 1, '[{"type":4}]');

        await repository.clearLaneEffects(1, 0);

        expect(await repository.loadLaneEffects(1, 0), isNull);
        // Only the named lane is cleared.
        expect(await repository.loadLaneEffects(1, 1), '[{"type":4}]');
      },
    );

    test('clearing a lane that was never stored is a no-op', () async {
      await repository.clearLaneEffects(3, 2);
      expect(await repository.loadLaneEffects(3, 2), isNull);
    });
  });

  group('track/master fx chains (FX v3)', () {
    test('track chain returns null when nothing is stored', () async {
      expect(await repository.loadTrackFxChain(0), isNull);
    });

    test('round-trips an encoded track chain envelope per channel', () async {
      await repository.saveTrackFxChain(1, '{"chainEnabled":false}');
      expect(await repository.loadTrackFxChain(1), '{"chainEnabled":false}');
      expect(await repository.loadTrackFxChain(0), isNull);
    });

    test('round-trips the master chain envelope', () async {
      expect(await repository.loadOutputFxChain(0), isNull);
      await repository.saveOutputFxChain(0, '{"chainEnabled":true}');
      expect(await repository.loadOutputFxChain(0), '{"chainEnabled":true}');
    });

    test('clearing a track chain reads back as unset, not as the old '
        'value', () async {
      await repository.saveTrackFxChain(0, '{"chainEnabled":true}');
      await repository.saveTrackFxChain(1, '{"chainEnabled":false}');

      await repository.clearTrackFxChain(0);

      expect(await repository.loadTrackFxChain(0), isNull);
      // Only the named channel is cleared.
      expect(await repository.loadTrackFxChain(1), '{"chainEnabled":false}');
    });

    test('clearing a track chain that was never stored is a no-op', () async {
      await repository.clearTrackFxChain(2);
      expect(await repository.loadTrackFxChain(2), isNull);
    });
  });

  group('monitor (single chain)', () {
    test('per-input mode defaults to null and round-trips', () async {
      expect(await repository.loadMonitorInputMode(0), isNull);
      await repository.saveMonitorInputMode(0, mode: 'on');
      expect(await repository.loadMonitorInputMode(0), 'on');
      expect(await repository.loadMonitorInputMode(1), isNull);
    });

    test('the middle mode round-trips by name, not by truthiness', () async {
      await repository.saveMonitorInputMode(3, mode: 'auto');
      expect(await repository.loadMonitorInputMode(3), 'auto');
    });

    test('output mask defaults to null and round-trips per input', () async {
      expect(await repository.loadMonitorOutput(0), isNull);
      await repository.saveMonitorOutput(0, 0x2);
      expect(await repository.loadMonitorOutput(0), 0x2);
      expect(await repository.loadMonitorOutput(1), isNull);
    });

    test('volume round-trips per input', () async {
      expect(await repository.loadMonitorVolume(0), isNull);
      await repository.saveMonitorVolume(0, 0.5);
      expect(await repository.loadMonitorVolume(0), 0.5);
    });

    test('mute round-trips per input', () async {
      expect(await repository.loadMonitorMute(0), isNull);
      await repository.saveMonitorMute(0, muted: true);
      expect(await repository.loadMonitorMute(0), isTrue);
    });

    test('effects round-trip the encoded chain per input', () async {
      expect(await repository.loadMonitorEffects(0), isNull);
      await repository.saveMonitorEffects(0, '[{"type":1}]');
      expect(await repository.loadMonitorEffects(0), '[{"type":1}]');
      expect(await repository.loadMonitorEffects(1), isNull);
    });

    test('the v2 migration flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV2(), isFalse);
      await repository.saveMonitorMigratedV2();
      expect(await repository.loadMonitorMigratedV2(), isTrue);
    });

    test('the v3 migration flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV3(), isFalse);
      await repository.saveMonitorMigratedV3();
      expect(await repository.loadMonitorMigratedV3(), isTrue);
    });
  });

  group('output gate', () {
    test('absence means enabled; only off entries are written', () async {
      // Default-on: no key => null (the caller reads as enabled).
      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 0),
        isNull,
      );

      // Disabling writes false.
      await repository.saveOutputEnabled(
        device: 'Scarlett',
        output: 0,
        enabled: false,
      );
      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 0),
        isFalse,
      );

      // Re-enabling REMOVES the key (self-cleaning, absence == enabled).
      await repository.saveOutputEnabled(
        device: 'Scarlett',
        output: 0,
        enabled: true,
      );
      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 0),
        isNull,
      );
    });

    test('the gate is a fact about the device, not about "output N"', () async {
      // Out 3/4 disabled as one interface's phones pair (#569)...
      await repository.saveOutputEnabled(
        device: 'Scarlett',
        output: 3,
        enabled: false,
      );

      // ...says nothing about another interface's Out 3/4 feeding the PA.
      expect(
        await repository.loadOutputEnabled(device: 'UMC1820', output: 3),
        isNull,
      );
      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 3),
        isFalse,
      );
    });

    test(
      'a legacy global key is adopted by the first device to read it', //
      () async {
        // The pre-#569 shape: keyed by output alone.
        store.values['output_enabled.2'] = false;

        // First read on the open device adopts the value...
        expect(
          await repository.loadOutputEnabled(device: 'Scarlett', output: 2),
          isFalse,
        );
        // ...re-keys it under that device, and removes the legacy key.
        expect(store.values['output_enabled.Scarlett.2'], isFalse);
        expect(store.values.containsKey('output_enabled.2'), isFalse);

        // One-way and once: another device does NOT inherit the migrated flag.
        expect(
          await repository.loadOutputEnabled(device: 'UMC1820', output: 2),
          isNull,
        );
        // And the adopting device keeps it on a later read.
        expect(
          await repository.loadOutputEnabled(device: 'Scarlett', output: 2),
          isFalse,
        );
      },
    );

    test('a device-keyed value wins over a lingering legacy key', () async {
      store.values['output_enabled.Scarlett.1'] = false;
      store.values['output_enabled.1'] = false;

      expect(
        await repository.loadOutputEnabled(device: 'Scarlett', output: 1),
        isFalse,
      );
      // The migration did not run: the device key already existed.
      expect(store.values.containsKey('output_enabled.1'), isTrue);
    });

    test('clearMonitorLaneKeys removes the prior multi-lane keys', () async {
      await repository.saveMonitorLaneCount(0, 2);
      await repository.saveMonitorLaneOutput(0, 0, 0x1);
      await repository.saveMonitorLaneOutput(0, 1, 0x2);

      await repository.clearMonitorLaneKeys(0, 2);

      expect(await repository.loadMonitorLaneCount(0), isNull);
      expect(await repository.loadMonitorLaneOutput(0, 0), isNull);
      expect(await repository.loadMonitorLaneOutput(0, 1), isNull);
    });
  });

  group('legacy monitor keys (migration only)', () {
    test('legacy single-route routing round-trips', () async {
      expect(await repository.loadMonitorInput(0), isNull);
      await repository.saveMonitorInput(0, enabled: true, outputMask: 0x2);
      expect(await repository.loadMonitorInput(0), (true, 0x2));
    });

    test('clearLegacyMonitorInput removes the four legacy keys', () async {
      await repository.saveMonitorInput(0, enabled: true, outputMask: 0x2);
      await repository.clearLegacyMonitorInput(0);
      expect(await repository.loadMonitorInput(0), isNull);
      expect(await repository.loadMonitorInputDry(0), 0);
      expect(await repository.loadMonitorInputVolume(0), isNull);
      expect(await repository.loadMonitorInputEffects(0), isNull);
    });
  });

  group('audio config', () {
    test('returns null on a first run (nothing saved)', () async {
      expect(await repository.loadAudioConfig(), isNull);
    });

    test('round-trips a saved config', () async {
      const config = StoredAudioConfig(
        sampleRate: 96000,
        bufferFrames: 256,
      );
      await repository.saveAudioConfig(config);
      expect(await repository.loadAudioConfig(), config);
    });

    test('does not write the removed legacy audio.monitor_input key', () async {
      // Monitoring is now the per-input routing graph; saving an audio config
      // must never resurrect the legacy global flag.
      await repository.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      expect(store.values.containsKey('audio.monitor_input'), isFalse);
    });

    test('round-trips requested channel counts', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 4,
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.inputChannels, 2);
      expect(loaded?.outputChannels, 4);
    });

    test('defaults channel counts to 0 (device default) when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.inputChannels, 0);
      expect(loaded?.outputChannels, 0);
    });

    test('round-trips pinned device ids', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'out-device-1',
        captureDeviceId: 'in-device-2',
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.playbackDeviceId, 'out-device-1');
      expect(loaded?.captureDeviceId, 'in-device-2');
    });

    test('defaults device ids to empty (system default) when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.playbackDeviceId, '');
      expect(loaded?.captureDeviceId, '');
    });

    test('does not write the removed audio.exclusive key', () async {
      // OS-exclusive mode is gone (Windows is ASIO-only); saving must never
      // resurrect the legacy key.
      await repository.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      expect(store.values.containsKey('audio.exclusive'), isFalse);
    });

    test('round-trips the backend and ASIO driver', () async {
      const config = StoredAudioConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        backend: AudioBackend.asio,
        asioDriver: 'Focusrite USB ASIO',
      );
      await repository.saveAudioConfig(config);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.asio);
      expect(loaded?.asioDriver, 'Focusrite USB ASIO');
    });

    test('defaults backend to miniaudio and driver empty when unset', () async {
      await store.setInt('audio.sample_rate', 44100);
      await store.setInt('audio.buffer_frames', 64);
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.miniaudio);
      expect(loaded?.asioDriver, '');
    });

    test('resolves an unknown stored backend name to miniaudio', () async {
      // Forward-compat: a newer build may write a backend name this build does
      // not know. It must resolve to miniaudio rather than throwing.
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      await store.setString('audio.backend', 'some_future_backend');
      final loaded = await repository.loadAudioConfig();
      expect(loaded?.backend, AudioBackend.miniaudio);
    });

    test(
      'ignores legacy audio.merge_to_mono / monitor_input keys on load',
      () async {
        // Both features were removed; an old store may still carry the keys.
        // Loading must succeed and read neither into the stored config.
        await store.setInt('audio.sample_rate', 48000);
        await store.setInt('audio.buffer_frames', 128);
        await store.setBool('audio.monitor_input', value: true);
        await store.setBool('audio.merge_to_mono', value: true);
        expect(
          await repository.loadAudioConfig(),
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
      },
    );

    test('a stale ui_mode key does not break config load', () async {
      // The UI-mode feature was removed; an old store may still carry the key.
      // Loading the audio config must succeed and never read it.
      await store.setString('ui_mode', 'desktop');
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      expect(
        await repository.loadAudioConfig(),
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
    });
  });

  group('legacy monitor migration accessors', () {
    test(
      'loadLegacyMonitorInput reads the legacy audio.monitor_input key',
      () async {
        // loadAudioConfig no longer reads this key; only the migration does.
        expect(await repository.loadLegacyMonitorInput(), isNull);
        await store.setBool('audio.monitor_input', value: false);
        expect(await repository.loadLegacyMonitorInput(), isFalse);
        await store.setBool('audio.monitor_input', value: true);
        expect(await repository.loadLegacyMonitorInput(), isTrue);
      },
    );

    test('monitor-migrated flag defaults to false and round-trips', () async {
      expect(await repository.loadMonitorMigratedV1(), isFalse);
      await repository.saveMonitorMigratedV1();
      expect(await repository.loadMonitorMigratedV1(), isTrue);
    });
  });

  group('midi device', () {
    test('returns null when nothing is stored', () async {
      expect(await repository.loadMidiDevice(), isNull);
    });

    test('round-trips a saved id + name', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      final loaded = await repository.loadMidiDevice();
      expect(loaded?.id, '12345');
      expect(loaded?.name, 'FCB1010');
    });

    test('saves the id and name in one record', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      expect(store.values.keys, contains('midi.input_device'));
      expect(store.values.length, 1);
      expect(
        store.values['midi.input_device'],
        '{"id":"12345","name":"FCB1010"}',
      );
    });

    test('rejects an empty id without saving', () async {
      await expectLater(
        repository.saveMidiDevice(id: '', name: ''),
        throwsArgumentError,
      );
      expect(store.values, isEmpty);
    });

    test(
      'rejects malformed saved records rather than selecting a device',
      () async {
        for (final raw in [
          'not json',
          '{"id":"port-1"}',
          '{"id":"","name":"Pedal"}',
          '{"id":"port-1","name":3}',
          '{"id":"port-1","name":"Pedal","extra":true}',
        ]) {
          store.values['midi.input_device'] = raw;
          await expectLater(repository.loadMidiDevice(), throwsFormatException);
        }
      },
    );

    test('dropped save is not reported as durable', () async {
      store.discardNextWriteKey = 'midi.input_device';
      await expectLater(
        repository.saveMidiDevice(id: 'port-1', name: 'Pedal'),
        throwsStateError,
      );
      expect(await repository.loadMidiDevice(), isNull);
    });

    test('a write that mutates then throws leaves a coherent pair', () async {
      store.failAfterWriteKey = 'midi.input_device';
      await expectLater(
        repository.saveMidiDevice(id: 'port-1', name: 'Pedal'),
        throwsStateError,
      );
      expect(await repository.loadMidiDevice(), (id: 'port-1', name: 'Pedal'));
    });

    test('clearMidiDevice removes the one record', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      await repository.clearMidiDevice();
      expect(await repository.loadMidiDevice(), isNull);
      expect(store.values.containsKey('midi.input_device'), isFalse);
    });

    test('dropped clear is not reported as durable', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      store.discardNextRemovalKey = 'midi.input_device';
      await expectLater(repository.clearMidiDevice(), throwsStateError);
      expect(await repository.loadMidiDevice(), (id: '12345', name: 'FCB1010'));
    });

    test('a clear that mutates then throws remains uncertain', () async {
      await repository.saveMidiDevice(id: '12345', name: 'FCB1010');
      store.failAfterRemovalKey = 'midi.input_device';
      await expectLater(repository.clearMidiDevice(), throwsStateError);
      expect(await repository.loadMidiDevice(), isNull);
    });
  });

  group('MIDI configuration', () {
    test('is absent until explicitly saved', () async {
      expect(await repository.loadMidiConfiguration(), isNull);
    });

    test('round-trips the opaque current setup', () async {
      const encoded = '{"modePress":"mute","recordHold":"none"}';
      await repository.saveMidiConfiguration(encoded);
      expect(await repository.loadMidiConfiguration(), encoded);
    });

    test(
      'before-write refusal preserves checkpoint and permits same-value repair',
      () async {
        const prior = '{"version":1,"enabled":true,"mappings":[]}';
        await repository.saveMidiConfiguration(prior);
        store.failNextKey = 'midi.configuration';
        await expectLater(
          repository.saveMidiConfiguration(prior),
          throwsA(
            isA<MidiSettingsSaveException>().having(
              (e) => e.checkpointRestored,
              'restored',
              isTrue,
            ),
          ),
        );
        expect(await repository.loadMidiConfiguration(), prior);
        await repository.saveMidiConfiguration(prior);
        expect(await repository.loadMidiConfiguration(), prior);
      },
    );

    test('silent dropped write cannot report confirmed success', () async {
      const prior = '{"version":1,"enabled":true,"mappings":[]}';
      await repository.saveMidiConfiguration(prior);
      store.discardNextWriteKey = 'midi.configuration';
      await expectLater(
        repository.saveMidiConfiguration(
          '{"version":1,"enabled":false,"mappings":[]}',
        ),
        throwsA(
          isA<MidiSettingsSaveException>().having(
            (e) => e.checkpointRestored,
            'restored',
            isTrue,
          ),
        ),
      );
      expect(await repository.loadMidiConfiguration(), prior);
    });

    test('write-then-throw restores the exact prior setup', () async {
      const prior = '{"custom":"prior bytes"}';
      await repository.saveMidiConfiguration(prior);
      store.failAfterWriteKey = 'midi.configuration';

      await expectLater(
        repository.saveMidiConfiguration('{"modePress":"fx"}'),
        throwsA(
          isA<MidiSettingsSaveException>()
              .having((error) => error.cause, 'cause', isA<StateError>())
              .having((error) => error.checkpointRestored, 'restored', isTrue),
        ),
      );
      expect(await repository.loadMidiConfiguration(), prior);
    });

    test('write-then-throw preserves an absent setup key', () async {
      store.failAfterWriteKey = 'midi.configuration';

      await expectLater(
        repository.saveMidiConfiguration('{"modePress":"fx"}'),
        throwsA(
          isA<MidiSettingsSaveException>().having(
            (error) => error.checkpointRestored,
            'restored',
            isTrue,
          ),
        ),
      );
      expect(await repository.loadMidiConfiguration(), isNull);
      expect(store.values.containsKey('midi.configuration'), isFalse);
    });

    test('checkpoint read refusal does not attempt a setup write', () async {
      const prior = '{"custom":"prior bytes"}';
      await repository.saveMidiConfiguration(prior);
      store.failNextReadKey = 'midi.configuration';

      await expectLater(
        repository.saveMidiConfiguration('{"modePress":"fx"}'),
        throwsA(
          isA<MidiSettingsSaveException>()
              .having((error) => error.cause, 'cause', isA<StateError>())
              .having(
                (error) => error.checkpointRestored,
                'checkpoint confirmed',
                isFalse,
              ),
        ),
      );
      expect(await repository.loadMidiConfiguration(), prior);
    });

    test(
      'rollback refusal reports the original and recovery failures',
      () async {
        const prior = '{"custom":"prior bytes"}';
        await repository.saveMidiConfiguration(prior);
        store
          ..failAfterWriteKey = 'midi.configuration'
          ..failOnSetValue = prior;

        await expectLater(
          repository.saveMidiConfiguration('{"modePress":"fx"}'),
          throwsA(
            isA<MidiSettingsSaveException>()
                .having((error) => error.cause, 'cause', isA<StateError>())
                .having(
                  (error) => error.restoreFailure,
                  'restore failure',
                  isA<StateError>(),
                )
                .having(
                  (error) => error.checkpointRestored,
                  'restored',
                  isFalse,
                ),
          ),
        );
      },
    );
  });

  group('pedal setup', () {
    test('is absent until explicitly saved', () async {
      expect(await repository.loadPedalSetup(), isNull);
    });

    test('round-trips the opaque current setup', () async {
      const encoded = '{"modePress":"mute","recordHold":"none"}';
      await repository.savePedalSetup(encoded);
      expect(await repository.loadPedalSetup(), encoded);
    });

    test('write-then-throw restores the exact prior setup', () async {
      const prior = '{"custom":"prior bytes"}';
      await repository.savePedalSetup(prior);
      store.failAfterWriteKey = 'pedal.setup';

      await expectLater(
        repository.savePedalSetup('{"modePress":"fx"}'),
        throwsA(
          isA<PedalSetupSaveException>()
              .having((error) => error.cause, 'cause', isA<StateError>())
              .having((error) => error.checkpointRestored, 'restored', isTrue),
        ),
      );
      expect(await repository.loadPedalSetup(), prior);
    });

    test('write-then-throw preserves an absent setup key', () async {
      store.failAfterWriteKey = 'pedal.setup';

      await expectLater(
        repository.savePedalSetup('{"modePress":"fx"}'),
        throwsA(
          isA<PedalSetupSaveException>().having(
            (error) => error.checkpointRestored,
            'restored',
            isTrue,
          ),
        ),
      );
      expect(await repository.loadPedalSetup(), isNull);
      expect(store.values.containsKey('pedal.setup'), isFalse);
    });

    test('checkpoint read refusal does not attempt a setup write', () async {
      const prior = '{"custom":"prior bytes"}';
      await repository.savePedalSetup(prior);
      store.failNextReadKey = 'pedal.setup';

      await expectLater(
        repository.savePedalSetup('{"modePress":"fx"}'),
        throwsA(
          isA<PedalSetupSaveException>()
              .having((error) => error.cause, 'cause', isA<StateError>())
              .having(
                (error) => error.checkpointRestored,
                'checkpoint confirmed',
                isFalse,
              ),
        ),
      );
      expect(await repository.loadPedalSetup(), prior);
    });

    test(
      'rollback refusal reports the original and recovery failures',
      () async {
        const prior = '{"custom":"prior bytes"}';
        await repository.savePedalSetup(prior);
        store
          ..failAfterWriteKey = 'pedal.setup'
          ..failOnSetValue = prior;

        await expectLater(
          repository.savePedalSetup('{"modePress":"fx"}'),
          throwsA(
            isA<PedalSetupSaveException>()
                .having((error) => error.cause, 'cause', isA<StateError>())
                .having(
                  (error) => error.restoreFailure,
                  'restore failure',
                  isA<StateError>(),
                )
                .having(
                  (error) => error.checkpointRestored,
                  'restored',
                  isFalse,
                ),
          ),
        );
      },
    );
  });

  group('tuner preferences (#1229)', () {
    test('the Hold · Tuner default is unattempted until marked', () async {
      expect(await repository.loadTunerDefaultSeeded(), isFalse);
      await repository.saveTunerDefaultSeeded();
      expect(await repository.loadTunerDefaultSeeded(), isTrue);
    });

    test('the A4 reference defaults to 440 Hz, round-trips and clamps to '
        '420-460', () async {
      expect(await repository.loadTunerReferenceHz(), 440);
      await repository.saveTunerReferenceHz(432);
      expect(await repository.loadTunerReferenceHz(), 432);
      await repository.saveTunerReferenceHz(500);
      expect(await repository.loadTunerReferenceHz(), 460);
      await repository.saveTunerReferenceHz(300);
      expect(await repository.loadTunerReferenceHz(), 420);
    });

    test('a stored reference outside the range reads clamped', () async {
      await store.setInt('tuner.reference_hz', 1000);
      expect(await repository.loadTunerReferenceHz(), 460);
    });

    test(
      'the input defaults to the first available (-1) and round-trips',
      () async {
        expect(await repository.loadTunerInput(), -1);
        await repository.saveTunerInput(3);
        expect(await repository.loadTunerInput(), 3);
        await repository.saveTunerInput(-7);
        expect(await repository.loadTunerInput(), -1);
        await store.setInt('tuner.input', -4);
        expect(await repository.loadTunerInput(), -1);
      },
    );
  });

  group('pedal timing', () {
    test('long-press defaults to 800 ms and round-trips', () async {
      expect(await repository.loadPedalLongPressMs(), 800);
      await repository.savePedalLongPressMs(750);
      expect(await repository.loadPedalLongPressMs(), 750);
    });

    test(
      'clear-fade defaults to 1000 ms and round-trips (0 disables)',
      () async {
        expect(await repository.loadPedalClearFadeMs(), 1000);
        await repository.savePedalClearFadeMs(0);
        expect(await repository.loadPedalClearFadeMs(), 0);
      },
    );
  });

  group('waveform window', () {
    test('defaults to enabled when unset', () async {
      expect(await repository.loadShowWaveformWindow(), isTrue);
    });

    test('round-trips a saved preference', () async {
      await repository.saveShowWaveformWindow(value: false);
      expect(await repository.loadShowWaveformWindow(), isFalse);
    });
  });

  group('high contrast', () {
    test('defaults to off when unset', () async {
      expect(await repository.loadHighContrast(), isFalse);
    });

    test('round-trips a saved preference', () async {
      await repository.saveHighContrast(value: true);
      expect(await repository.loadHighContrast(), isTrue);
    });
  });

  group('display brightness', () {
    test('defaults to 80% on each panel when nothing was ever set', () async {
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 0.8);
      expect(await repository.loadDisplayBrightness(DisplayRole.main), 0.8);
    });

    test('a panel never set starts from the one older brightness', () async {
      await store.setDouble('ui.brightness', 0.6);
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 0.6);
      expect(await repository.loadDisplayBrightness(DisplayRole.main), 0.6);
    });

    test('an older brightness below the range lands on its floor', () async {
      await store.setDouble('ui.brightness', 0.1);
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 0.2);
      expect(await repository.loadDisplayBrightness(DisplayRole.main), 0.2);
    });

    test('each panel keeps its own; the older key is left in place for a '
        'downgrade', () async {
      await store.setDouble('ui.brightness', 0.6);
      await repository.saveDisplayBrightness(DisplayRole.main, 0.5);
      expect(await repository.loadDisplayBrightness(DisplayRole.main), 0.5);
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 0.6);
      expect(await store.getDouble('ui.brightness'), 0.6);
      expect(await store.getDouble('ui.brightness.main'), 0.5);
    });

    test('saves clamped into the range', () async {
      await repository.saveDisplayBrightness(DisplayRole.track, 2);
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 1);
      await repository.saveDisplayBrightness(DisplayRole.track, 0);
      expect(await repository.loadDisplayBrightness(DisplayRole.track), 0.2);
    });
  });

  group('idle dimming', () {
    test('defaults to never', () async {
      expect(await repository.loadIdleDimSeconds(), 0);
    });

    test('round-trips each choice', () async {
      for (final seconds in SettingsRepository.idleDimChoices) {
        await repository.saveIdleDimSeconds(seconds);
        expect(await repository.loadIdleDimSeconds(), seconds);
      }
    });

    test('an unknown stored value reads as never', () async {
      await store.setInt('ui.idle_dim_seconds', 45);
      expect(await repository.loadIdleDimSeconds(), 0);
    });

    test('refuses a value that is not a choice', () {
      expect(() => repository.saveIdleDimSeconds(45), throwsArgumentError);
    });
  });

  group('saved FX presets', () {
    test('reads null when nothing has been saved', () async {
      expect(await repository.loadFxUserPresets(), isNull);
    });

    test('round-trips the encoded list', () async {
      await repository.saveFxUserPresets('[{"id":"1","name":"Verse"}]');
      expect(
        await repository.loadFxUserPresets(),
        '[{"id":"1","name":"Verse"}]',
      );
    });
  });

  group('retired default interaction mode', () {
    test('is null when no build stored one', () async {
      expect(await repository.takeRetiredDefaultInteractionMode(), isNull);
    });

    test('returns the stored token once, then forgets it', () async {
      await store.setString('looper.default_mode', 'mute');
      expect(await repository.takeRetiredDefaultInteractionMode(), 'mute');
      expect(await store.getString('looper.default_mode'), isNull);
      expect(await repository.takeRetiredDefaultInteractionMode(), isNull);
    });
  });

  group('Bluetooth retirement notice', () {
    test('is not shown until recorded, then stays shown', () async {
      expect(await repository.loadBluetoothRetiredNoticeShown(), isFalse);
      await repository.saveBluetoothRetiredNoticeShown();
      expect(await repository.loadBluetoothRetiredNoticeShown(), isTrue);
    });
  });

  group('refresh rate', () {
    test('defaults to 60 Hz when unset', () async {
      expect(await repository.loadRefreshHz(), 60);
    });

    test('round-trips a saved rate', () async {
      await repository.saveRefreshHz(120);
      expect(await repository.loadRefreshHz(), 120);
    });
  });

  group('record options', () {
    test('rec/dub default and exact Sound membership round-trip', () async {
      expect(await repository.loadRecDub(), isFalse);
      expect((await repository.readRecordStartCheckpoint()).soundStart, isNull);
      await repository.saveRecDub(value: true);
      await repository.saveRecordStartSettings(
        countInBars: 0,
        soundStart: true,
      );
      expect(await repository.loadRecDub(), isTrue);
      expect((await repository.readRecordStartCheckpoint()).soundStart, isTrue);
    });
  });

  group('track multiple', () {
    test('defaults to 0 (auto) and round-trips a fixed value', () async {
      expect(await repository.loadTrackMultiple(0), 0);
      await repository.saveTrackMultiple(0, 3);
      expect(await repository.loadTrackMultiple(0), 3);
    });
  });

  group('default multiple', () {
    test('defaults to 0 (auto) and round-trips a fixed value', () async {
      expect(await repository.loadDefaultMultiple(), 0);
      await repository.saveDefaultMultiple(2);
      expect(await repository.loadDefaultMultiple(), 2);
    });
  });

  group('track record timing override', () {
    test('defaults to null (follow the default) when unset', () async {
      expect(
        (await repository.readRecordTimingCheckpoint()).trackOverrides[0],
        isNull,
      );
    });

    test('round-trips a code and the follow-the-default value', () async {
      await repository.restoreRecordTimingCheckpoint((
        quantize: null,
        division: null,
        trackOverrides: {0: 4, 1: 0},
      ));
      expect(
        (await repository.readRecordTimingCheckpoint()).trackOverrides[0],
        4,
      );
      expect(
        (await repository.readRecordTimingCheckpoint()).trackOverrides[1],
        0,
      );

      await repository.restoreRecordTimingCheckpoint((
        quantize: null,
        division: null,
        trackOverrides: {1: 0},
      ));
      expect(
        (await repository.readRecordTimingCheckpoint()).trackOverrides[0],
        isNull,
      );
    });
  });

  group('length defaults and overrides', () {
    test('the default length preset round-trips', () async {
      expect(await repository.loadDefaultLengthPreset(), 0);
      await repository.saveDefaultLengthPreset(8);
      expect(await repository.loadDefaultLengthPreset(), 8);
    });

    test(
      'a length override distinguishes inheritance, Auto and bars',
      () async {
        expect(await repository.loadTrackLengthPreset(0), isNull);
        await repository.saveTrackLengthPreset(0, 0);
        await repository.saveTrackLengthPreset(1, 16);
        expect(await repository.loadTrackLengthPreset(0), 0);
        expect(await repository.loadTrackLengthPreset(1), 16);
        await repository.saveTrackLengthPreset(0, null);
        expect(await repository.loadTrackLengthPreset(0), isNull);
      },
    );
  });

  group('canonical mix settings', () {
    const scarlett = 'Scarlett';
    const builtIn = 'Built-in';

    StoredMixSettings mix({
      Map<int, double> trackLevels = const {},
      Map<int, double> pans = const {},
      Map<(int, int), double> levels = const {},
      Map<int, double> monitors = const {},
      StoredInputSetup input = const (trimDb: {}, pan: {}, pairs: {}),
      StoredOutputSetup output = const (
        level: {},
        muted: {},
        mono: {},
        balance: {},
      ),
    }) => (
      trackLevels: trackLevels,
      trackPans: pans,
      laneLevels: levels,
      monitorLevels: monitors,
      laneInputs: const {},
      laneOutputs: const {},
      laneCounts: const {},
      inputSetup: input,
      outputSetup: output,
    );

    test(
      'one value preserves the complete mix and another device setup',
      () async {
        await repository.replaceMixSettings(
          device: builtIn,
          mix: mix(input: (trimDb: {0: -3}, pan: {}, pairs: {})),
        );
        await repository.replaceMixSettings(
          device: scarlett,
          mix: mix(
            trackLevels: {0: .8, 7: 1.5},
            pans: {0: -0.5},
            levels: {(0, 1): 0.4},
            monitors: {2: 0.7},
            input: (trimDb: {1: -6}, pan: {1: 0.25}, pairs: {0: 0}),
          ),
        );
        expect(
          store.values.keys.where((key) => key == 'mix_settings'),
          hasLength(1),
        );
        expect(store.values.containsKey('mixer_settings'), isFalse);
        expect(store.values.containsKey('monitor_vol.2'), isFalse);
        expect(store.values.containsKey('input_setup.Scarlett'), isFalse);
        final loaded = await repository.loadMixSettings(scarlett);
        expect(loaded.trackLevels, {0: .8, 7: 1.5});
        expect(loaded.trackPans, {0: -0.5});
        expect(loaded.laneLevels, {(0, 1): 0.4});
        expect(loaded.monitorLevels, {2: 0.7});
        expect(loaded.inputSetup.trimDb, {1: -6});
        expect(loaded.inputSetup.pan, {1: 0.25});
        expect(loaded.inputSetup.pairs, {0: 0});
        expect((await repository.loadMixSettings(builtIn)).inputSetup.trimDb, {
          0: -3,
        });
      },
    );

    test(
      'failed full write and exact checkpoint restore keep prior mix',
      () async {
        await repository.replaceMixSettings(
          device: scarlett,
          mix: mix(
            trackLevels: {7: .75},
            pans: {0: .5},
            levels: {(0, 0): .25},
            monitors: {1: .6},
            input: (trimDb: {0: -6}, pan: {1: -.5}, pairs: {2: 0}),
          ),
        );
        final checkpoint = await repository.readMixSettingsCheckpoint();
        store.failNextKey = 'mix_settings';
        await expectLater(
          repository.replaceMixSettings(device: scarlett, mix: mix()),
          throwsStateError,
        );
        expect(await repository.readMixSettingsCheckpoint(), checkpoint);
        expect((await repository.loadMixSettings(scarlett)).trackLevels, {
          7: .75,
        });
        await repository.replaceMixSettings(device: scarlett, mix: mix());
        await repository.restoreMixSettingsCheckpoint(checkpoint);
        expect(await repository.readMixSettingsCheckpoint(), checkpoint);
        expect((await repository.loadMixSettings(scarlett)).inputSetup.pairs, {
          2: 0,
        });
      },
    );

    test(
      'an empty track keeps its gain through sparse value removal',
      () async {
        expect(await repository.readMixSettingsCheckpoint(), isNull);
        await repository.replaceMixSettings(
          device: scarlett,
          mix: mix(trackLevels: {7: .65}),
        );
        final checkpoint = await repository.readMixSettingsCheckpoint();
        expect(checkpoint, isNotNull);
        expect((await repository.loadMixSettings(scarlett)).trackLevels, {
          7: .65,
        });

        await repository.replaceMixSettings(device: scarlett, mix: mix());
        expect(await repository.readMixSettingsCheckpoint(), isNull);
        await repository.restoreMixSettingsCheckpoint(checkpoint);
        expect(await repository.readMixSettingsCheckpoint(), checkpoint);
        expect((await repository.loadMixSettings(scarlett)).trackLevels, {
          7: .65,
        });
      },
    );

    test(
      'output facts share the mix checkpoint and remain device scoped',
      () async {
        await repository.replaceMixSettings(
          device: builtIn,
          mix: mix(
            output: (
              level: {0: .4},
              muted: {},
              mono: {},
              balance: {},
            ),
          ),
        );
        await repository.replaceMixSettings(
          device: scarlett,
          mix: mix(
            output: (
              level: {1: .5},
              muted: {1: true},
              mono: {0: true},
              balance: {0: -.25},
            ),
          ),
        );
        final checkpoint = await repository.readMixSettingsCheckpoint();
        expect(
          store.values.keys.where((key) => key.startsWith('output_')),
          isEmpty,
        );
        final setup = (await repository.loadMixSettings(scarlett)).outputSetup;
        expect(setup.level, {1: .5});
        expect(setup.muted, {1: true});
        expect(setup.mono, {0: true});
        expect(setup.balance, {0: -.25});
        expect((await repository.loadMixSettings(builtIn)).outputSetup.level, {
          0: .4,
        });
        await repository.replaceMixSettings(device: scarlett, mix: mix());
        await repository.restoreMixSettingsCheckpoint(checkpoint);
        expect((await repository.loadMixSettings(scarlett)).outputSetup.muted, {
          1: true,
        });
        expect((await repository.loadMixSettings(builtIn)).outputSetup.level, {
          0: .4,
        });
      },
    );

    test(
      'whole candidate validation refuses nonfinite and odd pairs',
      () async {
        final checkpoint = await repository.readMixSettingsCheckpoint();
        await expectLater(
          repository.replaceMixSettings(
            device: scarlett,
            mix: mix(pans: {0: double.nan}),
          ),
          throwsArgumentError,
        );
        await expectLater(
          repository.replaceMixSettings(
            device: scarlett,
            mix: mix(input: (trimDb: {}, pan: {}, pairs: {1: 0})),
          ),
          throwsArgumentError,
        );
        expect(await repository.readMixSettingsCheckpoint(), checkpoint);
      },
    );
  });

  group('overdub decay', () {
    test('retains an explicit value equal to the default', () async {
      await repository.restoreDecayCheckpoint(channel: null, percent: 25);
      await repository.restoreDecayCheckpoint(channel: 0, percent: 25);
      await repository.restoreDecayCheckpoint(channel: 1, percent: 0);
      await repository.restoreDecayCheckpoint(channel: null, percent: 70);
      expect(await repository.readDecayCheckpoint(channel: 0), 25);
      expect(await repository.readDecayCheckpoint(channel: 1), 0);
      expect(await repository.readDecayCheckpoint(channel: 2), isNull);
    });
  });

  group('playback choice', () {
    test(
      'preserves explicit Loop and Once independently of the default',
      () async {
        await repository.restoreOneShotCheckpoint(channel: 0, oneShot: false);
        await repository.restoreOneShotCheckpoint(channel: 1, oneShot: true);
        await repository.restoreOneShotCheckpoint(channel: null, oneShot: true);
        expect(await repository.readOneShotCheckpoint(channel: null), isTrue);
        expect(await repository.readOneShotCheckpoint(channel: 0), isFalse);
        expect(await repository.readOneShotCheckpoint(channel: 1), isTrue);
        expect(await repository.readOneShotCheckpoint(channel: 2), isNull);

        await repository.restoreOneShotCheckpoint(
          channel: null,
          oneShot: false,
        );
        expect(await repository.readOneShotCheckpoint(channel: null), isFalse);
        expect(await repository.readOneShotCheckpoint(channel: 1), isTrue);
      },
    );

    test('Use default removes either explicit playback choice', () async {
      for (final oneShot in [false, true]) {
        await repository.restoreOneShotCheckpoint(channel: 0, oneShot: oneShot);
        await repository.restoreOneShotCheckpoint(channel: 0, oneShot: null);
        expect(await repository.readOneShotCheckpoint(channel: 0), isNull);
      }
    });
  });

  group('tempo bpm', () {
    test('defaults to 0 (never set) when unset', () async {
      expect(await repository.loadTempoBpm(), 0);
    });

    test('round-trips a saved tempo', () async {
      await repository.saveTempoBpm(128.5);
      expect(await repository.loadTempoBpm(), 128.5);
    });
  });

  group('time signature', () {
    test('defaults to 4/4 when unset', () async {
      expect(await repository.loadTimeSignature(), (4, 4));
    });

    test('round-trips a saved signature', () async {
      await repository.saveTimeSignature(7, 8);
      expect(await repository.loadTimeSignature(), (7, 8));
    });
  });

  group('click mode', () {
    test('preserves absence for the owner to apply First recording', () async {
      expect(await repository.readClickModeCheckpoint(), isNull);
    });

    test('round-trips a saved enum code', () async {
      await repository.restoreClickModeCheckpoint(2);
      expect(await repository.readClickModeCheckpoint(), 2);
    });
  });

  group('click output mask', () {
    test('defaults to 0 (no outputs) when unset', () async {
      expect(await repository.loadClickOutputMask(), 0);
    });

    test('round-trips a saved mask', () async {
      await repository.saveClickOutputMask(0x3);
      expect(await repository.loadClickOutputMask(), 0x3);
    });
  });

  group('click volume', () {
    test('reads absence as absence', () async {
      expect(await repository.readClickVolumeCheckpoint(), isNull);
    });

    test('round-trips a saved volume', () async {
      await repository.restoreClickVolumeCheckpoint(0.5);
      expect(await repository.readClickVolumeCheckpoint(), 0.5);
    });
  });

  group('count-in bars', () {
    test(
      'leaves absent Count-in undecoded for the application default',
      () async {
        expect(
          (await repository.readRecordStartCheckpoint()).countInBars,
          isNull,
        );
      },
    );

    test('round-trips a saved bar count', () async {
      await repository.saveRecordStartSettings(
        countInBars: 2,
        soundStart: false,
      );
      expect((await repository.readRecordStartCheckpoint()).countInBars, 2);
    });
  });

  group('looper mode', () {
    test('defaults to 0 (multi) when unset', () async {
      expect(await repository.loadLooperMode(), 0);
    });

    test('round-trips a saved enum code', () async {
      await repository.saveLooperMode(3);
      expect(await repository.loadLooperMode(), 3);
    });
  });

  group('track length preset', () {
    test('defaults to null (follow the default) and round-trips a fixed '
        'value', () async {
      expect(await repository.loadTrackLengthPreset(0), isNull);
      await repository.saveTrackLengthPreset(0, 8);
      expect(await repository.loadTrackLengthPreset(0), 8);
    });

    test('is independent per track', () async {
      await repository.saveTrackLengthPreset(0, 4);
      await repository.saveTrackLengthPreset(1, 16);
      expect(await repository.loadTrackLengthPreset(0), 4);
      expect(await repository.loadTrackLengthPreset(1), 16);
      expect(await repository.loadTrackLengthPreset(2), isNull);
    });
  });

  group('StoredAudioConfig.maxLoopMinutes', () {
    test(
      'defaults to 0 (engine default) and round-trips a saved value',
      () async {
        const config = StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          maxLoopMinutes: 5,
        );
        await repository.saveAudioConfig(config);
        expect((await repository.loadAudioConfig())?.maxLoopMinutes, 5);
      },
    );

    test('defaults to 0 when only rate/buffer are set', () async {
      await store.setInt('audio.sample_rate', 48000);
      await store.setInt('audio.buffer_frames', 128);
      expect((await repository.loadAudioConfig())?.maxLoopMinutes, 0);
    });
  });

  group('update auto-check', () {
    test('defaults to true when unset', () async {
      expect(await repository.loadUpdateAutoCheck(), isTrue);
    });

    test('round-trips a saved value', () async {
      await repository.saveUpdateAutoCheck(value: false);
      expect(await repository.loadUpdateAutoCheck(), isFalse);
      expect(store.values['updates.auto_check'], isFalse);
    });
  });

  group('update channel', () {
    test('returns null when unset', () async {
      expect(await repository.loadUpdateChannel(), isNull);
    });

    test('round-trips experimental', () async {
      await repository.saveUpdateChannel('experimental');
      expect(await repository.loadUpdateChannel(), 'experimental');
      expect(store.values['updates.channel'], 'experimental');
    });
  });

  group('update rollback', () {
    test('defaults to none', () async {
      expect(await repository.loadUpdateRollback(), isNull);
    });

    test('round-trips the pair, and clearing forgets it', () async {
      await repository.saveUpdateRollback(
        attempted: Version.parse('1.1.0'),
        restored: Version.parse('1.0.0'),
      );
      expect(store.values['updates.rollback'], '1.1.0,1.0.0');
      expect(
        await repository.loadUpdateRollback(),
        (attempted: Version.parse('1.1.0'), restored: Version.parse('1.0.0')),
      );

      await repository.clearUpdateRollback();
      expect(await repository.loadUpdateRollback(), isNull);
    });

    test('reads an unparseable value as none', () async {
      await store.setString('updates.rollback', '1.1.0');
      expect(await repository.loadUpdateRollback(), isNull);
      await store.setString('updates.rollback', 'x,1.0.0');
      expect(await repository.loadUpdateRollback(), isNull);
    });
  });

  group('dismissed update versions', () {
    test('defaults to an empty set', () async {
      expect(await repository.loadDismissedUpdateVersions(), isEmpty);
    });

    test('round-trips as a sorted CSV string', () async {
      await repository.saveDismissedUpdateVersions({
        Version.parse('0.3.0'),
        Version.parse('0.1.0'),
        Version.parse('0.2.0'),
      });
      expect(store.values['updates.dismissed'], '0.1.0,0.2.0,0.3.0');
      expect(await repository.loadDismissedUpdateVersions(), {
        Version.parse('0.1.0'),
        Version.parse('0.2.0'),
        Version.parse('0.3.0'),
      });
    });

    test('reads an empty stored value as an empty set', () async {
      await store.setString('updates.dismissed', '');
      expect(await repository.loadDismissedUpdateVersions(), isEmpty);
    });

    test('ignores unparseable entries', () async {
      await store.setString('updates.dismissed', '0.1.0,,not-semver,0.4.0');
      expect(await repository.loadDismissedUpdateVersions(), {
        Version.parse('0.1.0'),
        Version.parse('0.4.0'),
      });
    });
  });

  group('input conditioning (#697)', () {
    test('every field is null when nothing is stored', () async {
      expect(await repository.loadInputConditioningEnabled(1), isNull);
      expect(await repository.loadInputConditioningHpfHz(1), isNull);
      expect(await repository.loadInputConditioningHumHz(1), isNull);
      expect(await repository.loadInputConditioningHumHarmonics(1), isNull);
      expect(await repository.loadInputConditioningExpThresholdDb(1), isNull);
      expect(await repository.loadInputConditioningExpRatio(1), isNull);
      expect(await repository.loadInputConditioningExpReleaseMs(1), isNull);
    });

    test('round-trips every conditioning field for an input', () async {
      await repository.saveInputConditioningEnabled(2, enabled: true);
      await repository.saveInputConditioningHpfHz(2, 80);
      await repository.saveInputConditioningHumHz(2, 60);
      await repository.saveInputConditioningHumHarmonics(2, 6);
      await repository.saveInputConditioningExpThresholdDb(2, -48);
      await repository.saveInputConditioningExpRatio(2, 3);
      await repository.saveInputConditioningExpReleaseMs(2, 220);

      expect(await repository.loadInputConditioningEnabled(2), isTrue);
      expect(await repository.loadInputConditioningHpfHz(2), 80);
      expect(await repository.loadInputConditioningHumHz(2), 60);
      expect(await repository.loadInputConditioningHumHarmonics(2), 6);
      expect(await repository.loadInputConditioningExpThresholdDb(2), -48);
      expect(await repository.loadInputConditioningExpRatio(2), 3);
      expect(await repository.loadInputConditioningExpReleaseMs(2), 220);
    });

    test('keys are isolated per input', () async {
      await repository.saveInputConditioningEnabled(0, enabled: true);
      await repository.saveInputConditioningHpfHz(0, 100);

      expect(await repository.loadInputConditioningEnabled(0), isTrue);
      expect(await repository.loadInputConditioningEnabled(1), isNull);
      expect(await repository.loadInputConditioningHpfHz(0), 100);
      expect(await repository.loadInputConditioningHpfHz(1), isNull);
    });

    test('uses the documented key names', () async {
      await repository.saveInputConditioningEnabled(3, enabled: true);
      await repository.saveInputConditioningHpfHz(3, 40);
      await repository.saveInputConditioningHumHz(3, 50);
      await repository.saveInputConditioningHumHarmonics(3, 4);
      await repository.saveInputConditioningExpThresholdDb(3, -55);
      await repository.saveInputConditioningExpRatio(3, 2);
      await repository.saveInputConditioningExpReleaseMs(3, 150);

      expect(store.values['input_cond.3'], true);
      expect(store.values['input_cond_hpf.3'], 40);
      expect(store.values['input_cond_hum.3'], 50);
      expect(store.values['input_cond_hum_harmonics.3'], 4);
      expect(store.values['input_cond_exp_thresh.3'], -55);
      expect(store.values['input_cond_exp_ratio.3'], 2);
      expect(store.values['input_cond_exp_release.3'], 150);
    });
  });

  group('input restoration opt-in (#697)', () {
    test('is null when nothing is stored', () async {
      expect(await repository.loadInputRestore(1), isNull);
    });

    test('round-trips a flag bitmask under input_restore.N', () async {
      await repository.saveInputRestore(2, 3);
      expect(await repository.loadInputRestore(2), 3);
      expect(store.values['input_restore.2'], 3);
    });

    test('is isolated per input', () async {
      await repository.saveInputRestore(0, 2);
      expect(await repository.loadInputRestore(0), 2);
      expect(await repository.loadInputRestore(1), isNull);
    });
  });
}
