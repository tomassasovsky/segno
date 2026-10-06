import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/app.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/looper/looper.dart';
// Domain audio-config + effect types come from the looper_repository barrel
// above; the engine-typed fixtures fed to the fake engine use the `le` prefix,
// and settings owns its own AudioBackend via the `persisted` prefix.
import 'package:segno_engine/segno_engine.dart'
    hide
        AudioBackend,
        AudioDevice,
        BuiltInEffect,
        EngineConfig,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        PluginEffect,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        decodeTrackEffects,
        encodeTrackEffects;
import 'package:segno_engine/segno_engine.dart'
    as le
    show AudioDevice, EngineConfig, LatencyState, LoopbackInfo, LoopbackKind;
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;
import 'package:settings_repository/settings_repository.dart'
    as persisted
    show AudioBackend;

import '../helpers/helpers.dart';

// Startup snapshots model the engine's eight fixed physical track slots.
const _emptyTrackSlots = <TrackSnapshot>[
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
  TrackSnapshot.empty(),
];

class _MuteBootEngine extends FakeAudioEngine {
  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) => muted
      ? EngineResult.invalid
      : super.setLaneMute(muted: muted, channel: channel, lane: lane);
}

class _DecayBootEngine extends FakeAudioEngine {
  double? defaultFeedback;
  int? refuseTrack;
  bool refuseDefault = false;

  @override
  EngineResult setOverdubFeedback(double feedback) {
    defaultFeedback = feedback;
    return refuseDefault ? EngineResult.invalid : EngineResult.ok;
  }

  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) => channel == refuseTrack
      ? EngineResult.invalid
      : super.setTrackOverdubFeedback(channel: channel, feedback: feedback);
}

class _LengthBootStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.length_preset.7') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.getInt(key);
  }
}

class _TimingBootStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int?> getInt(String key) async {
    if (key == 'track_record_timing.7') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.getInt(key);
  }
}

class _RecordStartBootStore extends FakeKeyValueStore {
  _RecordStartBootStore(this.blockedKey);

  final String blockedKey;
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> _wait(String key) async {
    if (key == blockedKey) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
  }

  @override
  Future<int?> getInt(String key) async {
    await _wait(key);
    return super.getInt(key);
  }

  @override
  Future<bool?> getBool(String key) async {
    await _wait(key);
    return super.getBool(key);
  }
}

class _ClickModeBootStore extends FakeKeyValueStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.click_mode') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.getInt(key);
  }
}

class _ClickModeBootEngine extends FakeAudioEngine {
  bool refuseMode = false;

  @override
  EngineResult setClickMode(ClickMode mode) =>
      refuseMode ? EngineResult.invalid : super.setClickMode(mode);
}

/// Consumes every Record timing command without applying it: the receipt
/// arrives and the vector does not match.
class _TimingDropEngine extends FakeAudioEngine {
  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) {
    recordTimingRevision = (recordTimingRevision + 2) & 0xffffffff;
    return EngineResult.ok;
  }
}

class _OnceBootEngine extends FakeAudioEngine {
  bool refuseOnce = false;

  /// Admits Once commands without ever publishing them.
  bool dropOnce = false;

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    if (refuseOnce) return EngineResult.invalid;
    if (dropOnce) return EngineResult.ok;
    return super.setOneShotMask(channels: channels, oneShot: oneShot);
  }
}

void main() {
  test('bootstrap stops when saved lane mute is refused', () async {
    final engine = _MuteBootEngine();
    final repository = LooperRepository(
      engine: engine,
      ticker: const Stream<void>.empty(),
    );
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final mix = testMixSettings(repository, settings: settings);
    addTearDown(() async {
      await mix.close();
      await repository.dispose();
    });
    await settings.saveAudioConfig(
      const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
    );
    await settings.saveLaneMute(0, 0, muted: true);
    final result = await tryAutoStartEngine(
      repository: repository,
      settings: settings,
      mixSettings: mix,
    );
    expect(result.started, isFalse);
    expect(repository.laneMuted(0, 0), isFalse);
    expect(engine.laneMute[(0, 0)], isNull);
  });

  group('tryAutoStartEngine', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late SettingsRepository settings;
    late FakeKeyValueStore store;

    setUp(() {
      engine = FakeAudioEngine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      );
      store = FakeKeyValueStore();
      settings = SettingsRepository(store: store);
      addTearDown(repository.dispose);
    });

    Future<void> saveRouting({
      required int channel,
      required int lane,
      int? input,
      int? output,
      int? count,
    }) async {
      final saved = await settings.loadMixSettings('Fake Device');
      final inputs = {...saved.laneInputs};
      final outputs = {...saved.laneOutputs};
      final counts = {...saved.laneCounts};
      if (input != null) {
        inputs[(channel, lane)] = input;
      }
      if (output != null) {
        outputs[(channel, lane)] = output;
      }
      if (count != null) {
        counts[channel] = count;
      }
      await settings.replaceMixSettings(
        device: 'Fake Device',
        mix: (
          trackLevels: saved.trackLevels,
          trackPans: saved.trackPans,
          laneLevels: saved.laneLevels,
          monitorLevels: saved.monitorLevels,
          laneInputs: inputs,
          laneOutputs: outputs,
          laneCounts: counts,
          inputSetup: saved.inputSetup,
          outputSetup: saved.outputSetup,
        ),
      );
    }

    for (final configured in [false, true]) {
      test(
        'invalid saved monitor gain keeps audio stopped; config=$configured',
        () async {
          if (configured) {
            await settings.saveAudioConfig(
              const StoredAudioConfig(
                sampleRate: 48000,
                bufferFrames: 256,
              ),
            );
          }
          const badMix = '{"monitorLevels":{"0":0.5,"1":1.5}}';
          store.values['mix_settings'] = badMix;
          final result = await tryAutoStartEngine(
            repository: repository,
            settings: settings,
            mixSettings: testMixSettings(repository, settings: settings),
          );
          expect(result.started, isFalse);
          expect(repository.state.status.isConnected, isFalse);
          expect(engine.startCalls, 0);
          expect(engine.lastConfig, isNull);
          expect(store.values['mix_settings'], badMix);
          expect(repository.mixSettingsSnapshot.monitorLevels, isEmpty);
        },
      );
    }

    group('confirmed recording-start startup', () {
      for (final hasAudioConfig in [false, true]) {
        for (final (savedCount, savedSound, bars, sound)
            in <(int?, bool?, int, bool)>[
              (null, null, 1, false),
              (0, null, 0, false),
              (null, true, 0, true),
              (null, false, 1, false),
              (0, true, 0, true),
              (2, false, 2, false),
              (4, null, 4, false),
            ]) {
          test(
            'config=$hasAudioConfig count=$savedCount sound=$savedSound',
            () async {
              if (hasAudioConfig) {
                await settings.saveAudioConfig(
                  const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
                );
              }
              if (savedCount != null) {
                store.values['tempo.count_in_bars'] = savedCount;
              }
              if (savedSound != null) {
                store.values['looper.auto_record'] = savedSound;
              }
              final result = await tryAutoStartEngine(
                repository: repository,
                settings: settings,
                mixSettings: testMixSettings(repository, settings: settings),
              );
              expect(result.started, isTrue);
              expect(repository.recordStartSettingsSettled, isTrue);
              expect(repository.recordStartRecoveryRequired, isFalse);
              expect(engine.snapshot().countInBars, bars);
              expect(engine.snapshot().autoRecord, sound);
              expect(repository.sessionTransport.countInBars, bars);
              expect(repository.sessionTransport.autoRecord, sound);
              expect(store.values['tempo.count_in_bars'], savedCount);
              expect(store.values['looper.auto_record'], savedSound);
              expect(
                store.values.containsKey('tempo.count_in_bars'),
                savedCount != null,
              );
              expect(
                store.values.containsKey('looper.auto_record'),
                savedSound != null,
              );
            },
          );
        }

        for (final refused in [false, true]) {
          test('only a refused pair blocks both start paths; '
              'config=$hasAudioConfig refused=$refused', () async {
            if (hasAudioConfig) {
              await settings.saveAudioConfig(
                const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
              );
            }
            engine
              ..recordStartResult = refused
                  ? EngineResult.invalid
                  : EngineResult.ok
              ..publishRecordStartCommands = false;
            store.values['tempo.count_in_bars'] = 4;
            store.values['looper.auto_record'] = false;
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            // A refused admission still fails the start; an unconfirmed
            // replay owes the pair and audio keeps running.
            expect(result.started, !refused);
            expect(engine.startCalls, 1);
            expect(engine.stopCalls, refused ? greaterThan(0) : 0);
            expect(repository.recordStartRecoveryRequired, !refused);
            expect(store.values['tempo.count_in_bars'], 4);
            expect(store.values['looper.auto_record'], isFalse);
          });
        }
      }

      for (final raw in <Map<String, Object>>[
        {'tempo.count_in_bars': 3},
        {'tempo.count_in_bars': 16},
        {'tempo.count_in_bars': '2'},
        {'tempo.count_in_bars': -1},
        {'looper.auto_record': 1},
        {'looper.auto_record': 'true'},
        {'tempo.count_in_bars': 2, 'looper.auto_record': true},
      ]) {
        test(
          'invalid start pair stays intact and audio starts with no wait: '
          '$raw',
          () async {
            store.values.addAll(raw);
            final before = Map<String, Object>.of(store.values);
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            // Only Count-in is unavailable; its owner's Retry repairs it.
            expect(result.started, isTrue);
            expect(engine.startCalls, 1);
            expect(engine.stopCalls, 0);
            expect(
              engine.recordStartRequests.map(
                (r) => (r.countInBars, r.soundStart),
              ),
              [(0, false)],
            );
            for (final key in ['tempo.count_in_bars', 'looper.auto_record']) {
              expect(store.values[key], before[key]);
            }
          },
        );
      }

      for (final key in ['tempo.count_in_bars', 'looper.auto_record']) {
        test('pending start pair read cannot open audio: $key', () async {
          final delayed = _RecordStartBootStore(key);
          final saved = SettingsRepository(store: delayed);
          final starting = tryAutoStartEngine(
            repository: repository,
            settings: saved,
            mixSettings: testMixSettings(repository, settings: saved),
          );
          await delayed.entered.future;
          expect(engine.startCalls, 0);
          expect(engine.recordStartRequests, isEmpty);
          delayed.release.complete();
          expect((await starting).started, isTrue);
          expect(engine.snapshot().countInBars, 1);
          expect(engine.snapshot().autoRecord, isFalse);
        });
      }
    });

    group('confirmed Hear click startup', () {
      for (final hasAudioConfig in [false, true]) {
        for (final stored in <int?>[null, 0, 1, 2, 3]) {
          test('config=$hasAudioConfig stored=$stored', () async {
            if (hasAudioConfig) {
              await settings.saveAudioConfig(
                const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
              );
            }
            if (stored != null) store.values['tempo.click_mode'] = stored;
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            expect(result.started, isTrue);
            expect(repository.clickModeSettled, isTrue);
            expect(repository.clickModeRecoveryRequired, isFalse);
            expect(engine.snapshot().clickMode.code, stored ?? 2);
            expect(repository.sessionTransport.clickMode.code, stored ?? 2);
            expect(store.values['tempo.click_mode'], stored);
            expect(
              store.values.containsKey('tempo.click_mode'),
              stored != null,
            );
          });
        }
      }

      for (final malformed in <Object>['2', 1.5, -1, 4, 9]) {
        test(
          'invalid Hear click $malformed stays intact and audio starts Off',
          () async {
            store.values['tempo.click_mode'] = malformed;
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            // Only Hear click is unavailable; its owner's Retry repairs it.
            expect(result.started, isTrue);
            expect(engine.startCalls, 1);
            expect(engine.stopCalls, 0);
            expect(store.values['tempo.click_mode'], malformed);
            expect(engine.clickModeRequests, [ClickMode.off]);
            expect(repository.sessionTransport.clickMode, ClickMode.off);
          },
        );
      }

      test('pending Hear click read cannot open the audio device', () async {
        final delayed = _ClickModeBootStore();
        delayed.values['tempo.click_mode'] = 0;
        final saved = SettingsRepository(store: delayed);
        final starting = tryAutoStartEngine(
          repository: repository,
          settings: saved,
          mixSettings: testMixSettings(repository, settings: saved),
        );
        await delayed.entered.future;
        expect(engine.startCalls, 0);
        expect(engine.clickModeRequests, isEmpty);
        delayed.release.complete();
        expect((await starting).started, isTrue);
        expect(engine.snapshot().clickMode, ClickMode.off);
      });

      test('a refused Hear click replay admission blocks startup', () async {
        final failed = _ClickModeBootEngine()
          ..refuseMode = true
          ..publishClickModeCommands = false;
        final looper = LooperRepository(
          engine: failed,
          ticker: const Stream<void>.empty(),
        );
        addTearDown(looper.dispose);
        store.values['tempo.click_mode'] = 3;
        final result = await tryAutoStartEngine(
          repository: looper,
          settings: settings,
          mixSettings: testMixSettings(looper, settings: settings),
        );
        expect(result.started, isFalse);
        expect(failed.startCalls, 1);
        expect(failed.stopCalls, greaterThan(0));
        expect(store.values['tempo.click_mode'], 3);
      });

      test('an unconfirmed Hear click replay owes the choice and audio keeps '
          'running', () async {
        final failed = _ClickModeBootEngine()..publishClickModeCommands = false;
        final looper = LooperRepository(
          engine: failed,
          ticker: const Stream<void>.empty(),
        );
        addTearDown(looper.dispose);
        store.values['tempo.click_mode'] = 3;
        final result = await tryAutoStartEngine(
          repository: looper,
          settings: settings,
          mixSettings: testMixSettings(looper, settings: settings),
        );
        expect(result.started, isTrue);
        expect(failed.startCalls, 1);
        expect(failed.stopCalls, 0);
        expect(looper.clickModeRecoveryRequired, isTrue);
        expect(looper.clickModeRestartIntent.code, 3);
        expect(store.values['tempo.click_mode'], 3);
      });
    });

    for (final family in ['length', 'timing']) {
      for (final hasAudioConfig in [false, true]) {
        test('an unconfirmed startup $family replay is owed and audio keeps '
            'running, saved config $hasAudioConfig', () async {
          if (hasAudioConfig) {
            await settings.saveAudioConfig(
              const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
            );
          }
          final unconfirmed = family == 'timing'
              ? _TimingDropEngine()
              : (FakeAudioEngine()..publishLengthCommands = false);
          final looper = LooperRepository(
            engine: unconfirmed,
            ticker: const Stream<void>.empty(),
          );
          addTearDown(looper.dispose);
          if (family == 'timing') {
            store.values.addAll({
              'looper.quantize': true,
              'tempo.quantize_div': 3,
            });
          } else {
            store.values['looper.default_length_bars'] = 4;
          }
          final result = await tryAutoStartEngine(
            repository: looper,
            settings: settings,
            mixSettings: testMixSettings(looper, settings: settings),
          );
          expect(result.started, isTrue);
          expect(unconfirmed.stopCalls, 0);
          if (family == 'timing') {
            expect(looper.recordTimingRecoveryRequired, isTrue);
            expect(
              looper.recordTimingRestartIntent.defaultTiming,
              RecordTiming.quarter,
            );
          } else {
            expect(looper.lengthRecoveryRequired, isTrue);
            expect(looper.lengthRestartIntent.defaultBars, 4);
          }
        });
      }
    }

    group('complete Record timing startup', () {
      for (final hasAudioConfig in [false, true]) {
        test('restores explicit Immediately and remembered division; '
            'config=$hasAudioConfig', () async {
          if (hasAudioConfig) {
            await settings.saveAudioConfig(
              const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
            );
          }
          store.values.addAll({
            'looper.quantize': false,
            'tempo.quantize_div': 3,
            'track_record_timing.0': 0,
            'track_record_timing.7': 5,
          });
          final result = await tryAutoStartEngine(
            repository: repository,
            settings: settings,
            mixSettings: testMixSettings(repository, settings: settings),
          );
          expect(result.started, isTrue);
          expect(repository.defaultRecordTiming, RecordTiming.immediately);
          expect(repository.sessionTransport.quantizeDiv, GridDivision.quarter);
          expect(repository.trackRecordTimingOverrides, {
            0: RecordTiming.immediately,
            7: RecordTiming.eighth,
          });
          expect(engine.snapshot().quantize, isFalse);
          expect(engine.snapshot().quantizeDiv, GridDivision.quarter);
        });
      }

      for (final bad in <Object>['invalid', 1.5, -1, 7]) {
        test(
          'invalid final timing scalar $bad prevents partial startup, '
          'and audio still opens',
          () async {
            repository.setRecordTimingSettings(
              defaultTiming: RecordTiming.half,
              rememberedDivision: GridDivision.half,
              trackOverrides: {1: RecordTiming.immediately},
            );
            store.values.addAll({
              'looper.quantize': true,
              'tempo.quantize_div': 3,
              'track_record_timing.7': bad,
            });
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            // Only Record timing is unavailable; its owner's Retry repairs it.
            expect(result.started, isTrue);
            expect(engine.startCalls, 1);
            expect(engine.stopCalls, 0);
            expect(repository.defaultRecordTiming, RecordTiming.half);
            expect(repository.trackRecordTimingOverrides, {
              1: RecordTiming.immediately,
            });
            expect(store.values['track_record_timing.7'], bad);
          },
        );
      }

      test('the final timing read completes before opening audio', () async {
        final delayed = _TimingBootStore();
        delayed.values.addAll({
          'looper.quantize': true,
          'tempo.quantize_div': 3,
          'track_record_timing.0': 0,
          'track_record_timing.7': 5,
        });
        final saved = SettingsRepository(store: delayed);
        final starting = tryAutoStartEngine(
          repository: repository,
          settings: saved,
          mixSettings: testMixSettings(repository, settings: saved),
        );
        await delayed.entered.future;
        expect(engine.startCalls, 0);
        expect(repository.defaultRecordTiming, RecordTiming.immediately);
        expect(repository.trackRecordTimingOverrides, isEmpty);
        delayed.release.complete();
        expect((await starting).started, isTrue);
        expect(repository.defaultRecordTiming, RecordTiming.quarter);
        expect(repository.trackRecordTimingOverrides, {
          0: RecordTiming.immediately,
          7: RecordTiming.eighth,
        });
      });
    });

    group('saved playback initialization', () {
      for (final hasAudioConfig in [false, true]) {
        for (final defaultOnce in [false, true]) {
          test('restores fixed empty slots and explicit false, config '
              '$hasAudioConfig default $defaultOnce', () async {
            if (hasAudioConfig) {
              await settings.saveAudioConfig(
                const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
              );
            }
            await settings.restoreOneShotCheckpoint(
              channel: null,
              oneShot: defaultOnce,
            );
            await settings.restoreOneShotCheckpoint(channel: 0, oneShot: false);
            await settings.restoreOneShotCheckpoint(channel: 7, oneShot: true);
            final result = await tryAutoStartEngine(
              repository: repository,
              settings: settings,
              mixSettings: testMixSettings(repository, settings: settings),
            );
            expect(result.started, isTrue);
            expect(repository.defaultOneShot, defaultOnce);
            expect(repository.trackOneShotOverrides, {0: false, 7: true});
            expect(repository.oneShotSettingsSettled, isTrue);
            expect(engine.trackOneShot, {
              0: false,
              for (var c = 1; c < 7; c++) c: defaultOnce,
              7: true,
            });
          });
        }
      }
      test(
        'an invalid last slot preserves prior intent and audio still opens',
        () async {
          repository.setOneShotSnapshot(
            defaultOneShot: true,
            trackOverrides: {1: false},
          );
          store.values.addAll({
            'looper.default_one_shot': false,
            'track_one_shot.7': 'invalid',
          });
          final result = await tryAutoStartEngine(
            repository: repository,
            settings: settings,
            mixSettings: testMixSettings(repository, settings: settings),
          );
          // Only Loop/Once is unavailable; its owner's Retry repairs it.
          expect(result.started, isTrue);
          expect(engine.startCalls, 1);
          expect(engine.stopCalls, 0);
          expect(repository.defaultOneShot, isTrue);
          expect(repository.trackOneShotOverrides, {1: false});
          expect(store.values['track_one_shot.7'], 'invalid');
        },
      );
      for (final hasAudioConfig in [false, true]) {
        test('an unconfirmed startup replay owes Loop/Once and audio keeps '
            'running, saved config $hasAudioConfig', () async {
          if (hasAudioConfig) {
            await settings.saveAudioConfig(
              const StoredAudioConfig(sampleRate: 48000, bufferFrames: 256),
            );
          }
          final dropping = _OnceBootEngine()..dropOnce = true;
          final looper = LooperRepository(
            engine: dropping,
            ticker: const Stream<void>.empty(),
          );
          addTearDown(looper.dispose);
          await settings.restoreOneShotCheckpoint(channel: null, oneShot: true);
          final result = await tryAutoStartEngine(
            repository: looper,
            settings: settings,
            mixSettings: testMixSettings(looper, settings: settings),
          );
          expect(result.started, isTrue);
          expect(dropping.stopCalls, 0);
          expect(looper.oneShotRecoveryRequired, isTrue);
          expect(looper.oneShotRestartIntent.defaultOneShot, isTrue);
          expect(store.values['looper.default_one_shot'], true);
        });
      }
      test(
        'refused initial playback command cannot report successful start',
        () async {
          final refusing = _OnceBootEngine()..refuseOnce = true;
          final looper = LooperRepository(
            engine: refusing,
            ticker: const Stream<void>.empty(),
          );
          addTearDown(looper.dispose);
          final result = await tryAutoStartEngine(
            repository: looper,
            settings: settings,
            mixSettings: testMixSettings(looper, settings: settings),
          );
          expect(result.started, isFalse);
          expect(looper.state.status.isConnected, isFalse);
          expect(refusing.stopCalls, greaterThan(0));
        },
      );
    });

    group('saved decay initialization', () {
      for (final hasAudioConfig in [false, true]) {
        test('restores every decay slot before audio opens, saved config '
            '$hasAudioConfig', () async {
          final decayEngine = _DecayBootEngine();
          engine = decayEngine;
          repository = LooperRepository(
            engine: engine,
            ticker: const Stream<void>.empty(),
          );
          addTearDown(repository.dispose);
          if (hasAudioConfig) {
            await settings.saveAudioConfig(
              const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
            );
          }
          await settings.restoreDecayCheckpoint(channel: null, percent: 35);
          await settings.restoreDecayCheckpoint(channel: 0, percent: 0);
          await settings.restoreDecayCheckpoint(channel: 7, percent: 80);
          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );
          expect(result.started, isTrue);
          expect(decayEngine.defaultFeedback, .65);
          expect(decayEngine.trackOverdubFeedback, {
            0: 1.0,
            for (var channel = 1; channel < 7; channel++) channel: null,
            7: closeTo(.2, 1e-9),
          });
          expect(repository.decayRestartIntent.trackOverrides, {0: 0, 7: 80});
        });
      }

      test(
        'an invalid last slot prevents every saved decay write, '
        'and audio still opens',
        () async {
          repository
            ..setOverdubDecay(10)
            ..setTrackOverdubDecay(channel: 7, percent: 20);
          store.values.addAll({
            'looper.overdub_decay': 80,
            'track_overdub_decay.0': 60,
            'track_overdub_decay.7': 101,
          });
          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );
          // Decay's failed restore reports unavailable instead of stopping.
          expect(result.started, isTrue);
          expect(engine.startCalls, 1);
          expect(engine.stopCalls, 0);
          expect(repository.defaultOverdubDecay, 10);
          expect(repository.trackOverdubDecayOverrides, {7: 20});
          expect(store.values['track_overdub_decay.7'], 101);
        },
      );

      for (final refuseDefault in [false, true]) {
        test('native decay refusal leaves startup stopped: default '
            '$refuseDefault', () async {
          engine = _DecayBootEngine()
            ..refuseDefault = refuseDefault
            ..refuseTrack = refuseDefault ? null : 7;
          repository = LooperRepository(
            engine: engine,
            ticker: const Stream<void>.empty(),
          );
          addTearDown(repository.dispose);
          await settings.saveAudioConfig(
            const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
          );
          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );
          expect(result.started, isFalse);
          expect(repository.state.transport.isRunning, isFalse);
        });
      }
    });

    group('first run (no saved config)', () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('macOS/Linux opens the system default and persists it', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

        final result = await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(result.started, isTrue);
        expect(engine.startCalls, 1);
        // A zero-config open (sample rate / buffer left at the device default).
        expect(engine.lastConfig, const le.EngineConfig());
        // Persisted so the next launch takes the saved-config path.
        expect(await settings.loadAudioConfig(), isNotNull);
      });

      test(
        'console first-run auto-pins the first non-default duplex device',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          engine.devices = const [
            le.AudioDevice(
              id: 'hdmi',
              name: 'HDMI',
              isDefault: true,
              isInput: false,
            ),
            le.AudioDevice(
              id: 'hdmi',
              name: 'HDMI',
              isDefault: true,
              isInput: true,
            ),
            le.AudioDevice(
              id: 'scarlett',
              name: 'Scarlett 4i4',
              isDefault: false,
              isInput: false,
            ),
            le.AudioDevice(
              id: 'scarlett',
              name: 'Scarlett 4i4',
              isDefault: false,
              isInput: true,
            ),
          ];

          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );

          expect(result.started, isTrue);
          expect(engine.lastConfig?.playbackDeviceId, 'scarlett');
          expect(engine.lastConfig?.captureDeviceId, 'scarlett');
          final saved = await settings.loadAudioConfig();
          expect(saved?.playbackDeviceId, 'scarlett');
          expect(saved?.captureDeviceId, 'scarlett');
        },
      );

      test(
        'console first-run falls back to system default when pin open fails',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          // Fail the pinned open, succeed on the empty-id fallback.
          engine
            ..devices = const [
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: false,
              ),
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: true,
              ),
            ]
            ..startResults = [EngineResult.device, EngineResult.ok];

          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );

          expect(result.started, isTrue);
          expect(engine.startCalls, 2);
          expect(engine.lastConfig?.playbackDeviceId, '');
          expect(engine.lastConfig?.captureDeviceId, '');
          final saved = await settings.loadAudioConfig();
          expect(saved?.playbackDeviceId, '');
          expect(saved?.captureDeviceId, '');
        },
      );

      test('macOS/Linux lands stopped when the default open fails', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        engine.startResult = EngineResult.device;

        final result = await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(result.started, isFalse);
      });
    });

    group('console empty-id heal (saved config)', () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test(
        'pins a non-default duplex when persisted device ids are empty',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          engine.devices = const [
            le.AudioDevice(
              id: 'scarlett',
              name: 'Scarlett 4i4',
              isDefault: false,
              isInput: false,
            ),
            le.AudioDevice(
              id: 'scarlett',
              name: 'Scarlett 4i4',
              isDefault: false,
              isInput: true,
            ),
          ];
          await settings.saveAudioConfig(
            const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
          );

          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );

          expect(result.started, isTrue);
          expect(engine.lastConfig?.playbackDeviceId, 'scarlett');
          expect(engine.lastConfig?.captureDeviceId, 'scarlett');
          final saved = await settings.loadAudioConfig();
          expect(saved?.playbackDeviceId, 'scarlett');
          expect(saved?.captureDeviceId, 'scarlett');
        },
      );

      test(
        'falls back to system default when heal pin open fails',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          engine
            ..devices = const [
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: false,
              ),
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: true,
              ),
            ]
            ..startResults = [EngineResult.device, EngineResult.ok];
          await settings.saveAudioConfig(
            const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
          );

          final result = await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );

          expect(result.started, isTrue);
          expect(result.recoveryConfig, isNull);
          expect(engine.startCalls, 2);
          expect(engine.lastConfig?.playbackDeviceId, '');
          expect(engine.lastConfig?.captureDeviceId, '');
          final saved = await settings.loadAudioConfig();
          expect(saved?.playbackDeviceId, '');
          expect(saved?.captureDeviceId, '');
        },
      );

      test(
        'healed pin skips loopback auto-measure even when loopback is routable',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          engine
            ..devices = const [
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: false,
              ),
              le.AudioDevice(
                id: 'scarlett',
                name: 'Scarlett 4i4',
                isDefault: false,
                isInput: true,
              ),
            ]
            ..loopback = const le.LoopbackInfo(
              available: true,
              kind: le.LoopbackKind.virtualDevice,
              deviceName: 'Monitor',
            );
          await settings.saveAudioConfig(
            const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
          );

          await tryAutoStartEngine(
            mixSettings: testMixSettings(repository, settings: settings),
            repository: repository,
            settings: settings,
          );

          expect(engine.lastConfig?.useLoopbackCapture, isFalse);
          expect(engine.lastConfig?.captureDeviceId, 'scarlett');
          expect(engine.measureLatencyCalls, 0);
        },
      );
    });

    test('restores saved per-track routing on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Save lane-0 routing for channel 1 only; channel 0 has none (exercises
      // the null-guard skip in the restore loop).
      await saveRouting(channel: 1, lane: 0, input: 1, output: 0x4);
      // The restore loop iterates the engine's reported tracks.
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      // Only channel 1 had saved routing, restored onto lane 0.
      expect(engine.laneInput[(1, 0)], 1);
      expect(engine.laneOutput[(1, 0)], 0x4);
    });

    test(
      'refuses a saved half-pair instead of silently changing sources',
      () async {
        await settings.saveAudioConfig(
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
        await settings.seedInputSetup('Fake Device', (
          trimDb: <int, double>{},
          pan: <int, double>{},
          pairs: {0: 0.2},
        ));
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
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
          tracks: _emptyTrackSlots,
        );

        final started = await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(started.started, isFalse);
        expect(engine.stopCalls, greaterThan(0));
        expect(repository.inputSetup.pairs, isEmpty);
        expect(
          (await settings.loadMixSettings('Fake Device')).inputSetup.pairs,
          {0: 0.2},
        );
      },
    );

    test('restores the saved global default loop multiple on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      // Forced ×1: loops must stay one base loop, not auto-round-up to ×2/×4.
      await settings.saveDefaultMultiple(1);
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.lastDefaultMultiple, 1);
    });

    for (final key in [
      'looper.mode',
      'looper.default_length_bars',
      for (var channel = 0; channel < 8; channel++)
        'tempo.length_preset.$channel',
    ]) {
      test(
        'invalid saved $key stages no length and never rewrites intent; '
        'audio still opens',
        () async {
          store.values['looper.default_length_bars'] = 4;
          store.values[key] = key == 'looper.mode' ? 5 : 65;
          final before = Map<String, Object>.of(store.values);
          final result = await tryAutoStartEngine(
            repository: repository,
            settings: settings,
            mixSettings: testMixSettings(repository, settings: settings),
          );
          // Only Record length is unavailable; its owner's Retry repairs it.
          expect(result.started, isTrue);
          expect(engine.startCalls, 1);
          expect(engine.stopCalls, 0);
          expect(repository.sessionTransport.defaultLengthPresetBars, 0);
          expect(repository.trackLengthPresetOverrides, isEmpty);
          // The stored length keys are untouched; a started first run saves
          // its audio configuration beside them.
          for (final entry in before.entries) {
            expect(store.values[entry.key], entry.value);
          }
        },
      );
    }

    test('startup waits for the eighth fixed-track length read', () async {
      final delayed = _LengthBootStore();
      delayed.values.addAll({
        'looper.mode': LooperMode.free.code,
        'looper.default_length_bars': 4,
        'tempo.length_preset.0': 0,
        'tempo.length_preset.7': 8,
      });
      final saved = SettingsRepository(store: delayed);
      engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
        tracks: _emptyTrackSlots,
      );
      final start = tryAutoStartEngine(
        repository: repository,
        settings: saved,
        mixSettings: testMixSettings(repository, settings: saved),
      );
      await delayed.entered.future;
      expect(engine.startCalls, 0);
      expect(repository.sessionTransport.defaultLengthPresetBars, 0);
      expect(repository.trackLengthPresetOverrides, isEmpty);
      delayed.release.complete();
      expect((await start).started, isTrue);
      expect(repository.sessionTransport.looperMode, LooperMode.free);
      expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      expect(repository.trackLengthPresetOverrides, {0: 0, 7: 8});
      expect(engine.lastModeWithPresets?.$1, LooperMode.free);
      expect(engine.lastModeWithPresets?.$2, [0, 4, 4, 4, 4, 4, 4, 8]);
    });

    test('restores saved per-track length presets on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      // Channel 0 explicitly chooses Auto while channel 1 chooses eight bars.
      // Both are empty tracks, so neither setting may depend on recorded audio.
      await settings.saveDefaultLengthPreset(4);
      await settings.saveTrackLengthPreset(0, 0);
      await settings.saveTrackLengthPreset(1, 8);
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      // One vector carries the default and overrides. Multi applies its
      // shared default to all tracks while keeping the explicit choices.
      expect(repository.state.tracks[1].lengthPresetOverride, 8);
      expect(repository.state.tracks[0].lengthPresetOverride, 0);
      expect(engine.trackLengthPreset[1], 4);
      expect(engine.trackLengthPreset[0], 4);
      expect(engine.lastModeWithPresets?.$1, LooperMode.multi);
      expect(engine.lastModeWithPresets?.$2, [4, 4, 4, 4, 4, 4, 4, 4]);
      repository.setLooperMode(LooperMode.song);
      expect((await repository.settleLengthSettings()).isOk, isTrue);
      expect(engine.trackLengthPreset[1], 8);
      expect(engine.trackLengthPreset[0], 0);
    });

    test(
      'refused saved length vector leaves preferences and engine stopped',
      () async {
        await settings.saveAudioConfig(
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
        await settings.saveDefaultLengthPreset(4);
        engine
          ..modeWithPresetsResult = EngineResult.invalid
          ..nextSnapshot = const EngineSnapshot(
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
            tracks: _emptyTrackSlots,
          );

        final result = await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(result.started, isFalse);
        expect(engine.stopCalls, greaterThan(0));
        expect(await settings.loadDefaultLengthPreset(), 4);
        // The validated offline intent survives for a later device reconnect.
        expect(repository.sessionTransport.defaultLengthPresetBars, 4);
      },
    );

    test(
      'restores default Once and preserves explicit Loop overrides',
      () async {
        await settings.saveAudioConfig(
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
        await settings.restoreOneShotCheckpoint(channel: null, oneShot: true);
        await settings.restoreOneShotCheckpoint(channel: 1, oneShot: false);
        engine.nextSnapshot = const EngineSnapshot(
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
          tracks: _emptyTrackSlots,
        );

        final result = await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(result.started, isTrue);
        expect(repository.defaultOneShot, isTrue);
        expect(repository.state.tracks[0].oneShotOverride, isNull);
        expect(repository.state.tracks[1].oneShotOverride, isFalse);
        expect(engine.trackOneShot, {
          0: true,
          1: false,
          2: true,
          3: true,
          4: true,
          5: true,
          6: true,
          7: true,
        });
      },
    );

    test('restores saved per-lane effects on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Track 0 lane 0 = a two-effect chain (filter, then delay with a feedback
      // override); track 1 has no saved chain (exercises the empty skip).
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([
          BuiltInEffect(type: TrackEffectType.filter),
          BuiltInEffect(
            type: TrackEffectType.delay,
            params: const [0.3, 0.42, 0.5],
          ),
        ]),
      );
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      // Restore submits the ordered chain as one recipe, including params.
      final recipe = engine.fxRecipes[(FxOwner.lane, 0, 0)]!;
      expect(recipe.slots.map((slot) => slot.type.code), [
        TrackEffectType.filter.code,
        TrackEffectType.delay.code,
      ]);
      expect(recipe.slots[1].params[1], 0.42);
    });

    test('a LEGACY restored chain persists its freshly-minted slot ids back '
        '(mint-once, A9)', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Pre-FX-v3 payload: bare array, no slot ids anywhere.
      await settings.saveLaneEffects(
        0,
        0,
        encodeTrackEffects([BuiltInEffect(type: TrackEffectType.filter)]),
      );
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );
      expect(started.started, isTrue);

      // The minted envelope was written back, so the NEXT launch decodes the
      // same ids instead of re-minting different ones.
      final persisted = decodeFxChain(await settings.loadLaneEffects(0, 0));
      final mintedId = persisted.entries.single.slotId;
      expect(mintedId, isNotNull);
      expect(mintedId, repository.laneEffects(0, 0).single.slotId);
    });

    test('restores an ENVELOPE lane chain — flag + inheritance meta ride the '
        'one key (R15) — plus the track/master chains', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      await settings.saveLaneEffects(
        0,
        0,
        encodeFxChain(
          FxChainEnvelope(
            chainEnabled: false,
            meta: const FxChainMeta(inheritedFrom: [2]),
            entries: [BuiltInEffect(type: TrackEffectType.filter)],
          ),
        ),
      );
      await settings.saveTrackFxChain(
        0,
        encodeFxChain(
          FxChainEnvelope(
            chainEnabled: false,
            entries: [BuiltInEffect(type: TrackEffectType.delay)],
          ),
        ),
      );
      await settings.saveOutputFxChain(
        0,
        encodeFxChain(
          FxChainEnvelope(
            entries: [BuiltInEffect(type: TrackEffectType.reverb)],
          ),
        ),
      );
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      // Lane chain + its envelope-borne flag and provenance.
      final lane = engine.fxRecipes[(FxOwner.lane, 0, 0)]!;
      expect(lane.slots.single.type.code, TrackEffectType.filter.code);
      expect(lane.enabled, isFalse);
      expect(repository.laneChainInheritedFrom(0, 0), [2]);
      // Track-stage chain + flag.
      final track = engine.fxRecipes[(FxOwner.track, 0, 0)]!;
      expect(track.slots.single.type.code, TrackEffectType.delay.code);
      expect(track.enabled, isFalse);
      // Master output has an explicitly enabled envelope.
      final output = engine.fxRecipes[(FxOwner.output, 0, 0)]!;
      expect(output.slots.single.type.code, TrackEffectType.reverb.code);
      expect(output.enabled, isTrue);
    });

    test('invalid explicit FX metadata refuses boot and stops audio', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      await settings.saveOutputFxChain(
        0,
        '{"chainEnabled":true,"entries":['
        '{"type":1,"channels":{"input":"sideways"}}]}',
      );
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final result = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(result.started, isFalse);
      expect(engine.stopCalls, greaterThan(0));
      expect(repository.outputEffects(0), isEmpty);
    });

    test('restores a saved multi-lane setup on launch', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Track 0 has two lanes; lane 1 carries its own input, output, mix, and
      // effect chain that must be restored alongside lane 0.
      await saveRouting(channel: 0, lane: 1, count: 2, input: 2, output: 0x2);
      await settings.seedLaneVolume(0, 1, 0.4);
      await settings.saveLaneMute(0, 1, muted: true);
      await settings.saveLaneEffects(
        0,
        1,
        encodeTrackEffects([BuiltInEffect(type: TrackEffectType.tremolo)]),
      );
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.laneCount[0], 2);
      expect(engine.laneInput[(0, 1)], 2);
      expect(engine.laneOutput[(0, 1)], 0x2);
      expect(engine.laneVol[(0, 1)], 0.4);
      expect(engine.laneMute[(0, 1)], isTrue);
      expect(
        engine.fxRecipes[(FxOwner.lane, 0, 1)]!.slots.single.type.code,
        TrackEffectType.tremolo.code,
      );
    });

    test('starts the engine with the saved config', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 96000,
          bufferFrames: 256,
        ),
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.startCalls, 1);
      expect(engine.lastConfig?.sampleRate, 96000);
      expect(engine.lastConfig?.bufferFrames, 256);
      // Channel counts left at 0 (device default) so the interface opens with
      // all its channels; the negotiated counts come back via the snapshot.
      expect(engine.lastConfig?.inputChannels, 0);
      expect(engine.lastConfig?.outputChannels, 0);
    });

    test('relaunches into the saved ASIO backend + driver', () async {
      // The auto-start config assembly is duplicated from the cubit's
      // _engineConfig; this guards against the two diverging on backend/driver.
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          backend: persisted.AudioBackend.asio,
          asioDriver: 'Focusrite USB ASIO',
        ),
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.lastConfig?.backend.name, AudioBackend.asio.name);
      expect(engine.lastConfig?.asioDriver, 'Focusrite USB ASIO');
    });

    test("restores every track pan and the open device's input setup "
        '(slice 3) once the engine is up', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      // Channel 1 is panned; channel 0 is at centre and gets no call.
      await settings.seedTrackPan(1, -0.5);
      // Keyed to the device the running engine reports ('Fake Device'); a
      // setup saved for another interface must not be applied.
      await settings.seedInputSetup('Fake Device', (
        trimDb: {0: -6},
        pan: {2: -0.5},
        pairs: {0: 0.2},
      ));
      await settings.seedInputSetup('Other Box', (
        trimDb: {3: 12},
        pan: {},
        pairs: {},
      ));
      final savedMix = await settings.loadMixSettings('Fake Device');
      await settings.replaceMixSettings(
        device: 'Fake Device',
        mix: (
          trackLevels: savedMix.trackLevels,
          trackPans: savedMix.trackPans,
          laneLevels: savedMix.laneLevels,
          monitorLevels: savedMix.monitorLevels,
          laneInputs: {
            for (var channel = 0; channel < 8; channel++) ...{
              (channel, 0): 0,
              (channel, 1): 1,
            },
          },
          laneOutputs: savedMix.laneOutputs,
          laneCounts: {
            for (var channel = 0; channel < 8; channel++) channel: 2,
          },
          inputSetup: savedMix.inputSetup,
          outputSetup: (
            level: {1: .5},
            muted: {0: true},
            mono: {},
            balance: {1: -.25},
          ),
        ),
      );

      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.lanePan[(1, 0)], -0.5);
      expect(engine.lanePan[(0, 0)], 0);
      expect(repository.state.tracks[1].pan, -0.5);
      expect(
        repository.state.inputSetup,
        InputSetup(
          trimDb: const {0: -6},
          pan: const {2: -0.5},
          pairs: const {0: 0.2},
        ),
      );
      expect(engine.inputTrim[0], closeTo(inputTrimGainOfDb(-6), 1e-9));
      // The whole setup lands as one projection, including unity defaults.
      expect(engine.inputTrim[3], 1);
      expect(engine.monitorPan[2], -0.5);
      // The pair's members sit hard on their sides.
      expect(engine.monitorPan[0], -1);
      expect(engine.monitorPan[1], 1);
      // The output setup: the open device's, as one projection.
      expect(
        repository.outputSetup,
        const OutputSetup(
          buses: {
            1: OutputBus(level: 0.5, balance: -0.25),
            0: OutputBus(muted: true),
          },
        ),
      );
      expect(engine.outputLevel[1], 0.5);
      expect(engine.outputBalance[1], -0.25);
      expect(engine.outputMuted[0], isTrue);
      expect(engine.outputLevel[0], 1);
    });

    test('restores a saved track pan onto every lane the saved lane count '
        'grew, not just lane 0', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      await saveRouting(channel: 0, lane: 1, count: 2);
      await settings.seedTrackPan(0, 0.5);
      engine.nextSnapshot = const EngineSnapshot(
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
        tracks: _emptyTrackSlots,
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(started.started, isTrue);
      expect(engine.laneCount[0], 2);
      expect(engine.lanePan[(0, 0)], 0.5);
      expect(engine.lanePan[(0, 1)], 0.5);
    });

    test('restores the saved latency offset for the device', () async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );
      // Saved under the profile the running engine reports (the fake's default
      // snapshot has sample rate / buffer 0, device 'Fake Device').
      await settings.saveLatencyOffsetFrames(
        device: 'Fake Device',
        sampleRate: 0,
        bufferFrames: 0,
        frames: 720,
      );

      await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );

      expect(engine.lastRecordOffset, 720);
    });

    test(
      'auto-measures when no saved offset and loopback is routable',
      () async {
        engine.loopback = const le.LoopbackInfo(
          available: true,
          kind: le.LoopbackKind.virtualDevice,
          deviceName: 'BlackHole',
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
          ),
        );
        // No saved latency offset for this profile.

        await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(engine.measureLatencyCalls, 1);
        expect(engine.lastRecordOffset, isNull); // restored nothing, measured
      },
    );

    test(
      'a saved capture device wins over loopback auto-routing',
      () async {
        // A routable loopback exists (as on any PipeWire host), but the saved
        // config pins a real input device: capture must not be auto-routed to
        // the loopback, and the loopback-driven auto-measure must be skipped.
        engine.loopback = const le.LoopbackInfo(
          available: true,
          kind: le.LoopbackKind.virtualDevice,
          deviceName: 'BlackHole',
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
            captureDeviceId: 'clarett-in',
          ),
        );

        await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(engine.lastConfig?.useLoopbackCapture, isFalse);
        expect(engine.lastConfig?.captureDeviceId, 'clarett-in');
        expect(engine.measureLatencyCalls, 0);
      },
    );

    test(
      'auto-measures when no saved offset and the device has loopback channels',
      () async {
        // No routable loopback device, but the opened interface reports
        // dedicated loopback channels via the excluded-input mask.
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          excludedInputMask: 0x30,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: _emptyTrackSlots,
        );
        await settings.saveAudioConfig(
          const StoredAudioConfig(
            sampleRate: 48000,
            bufferFrames: 128,
          ),
        );

        await tryAutoStartEngine(
          mixSettings: testMixSettings(repository, settings: settings),
          repository: repository,
          settings: settings,
        );

        expect(engine.measureLatencyCalls, 1);
      },
    );

    test('returns false when the engine fails to start', () async {
      engine.startResult = EngineResult.device;
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
        ),
      );

      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );
      expect(started.started, isFalse);
      // System default (no pinned device) is never auto-recovered.
      expect(started.recoveryConfig, isNull);
    });

    test('arms recovery when a pinned device fails to start', () async {
      engine.startResult = EngineResult.device;
      await settings.saveAudioConfig(
        const StoredAudioConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          playbackDeviceId: 'out-1',
        ),
      );

      final result = await tryAutoStartEngine(
        mixSettings: testMixSettings(repository, settings: settings),
        repository: repository,
        settings: settings,
      );
      expect(result.started, isFalse);
      expect(result.recoveryConfig?.playbackDeviceId, 'out-1');
    });
  });

  // The exit criterion for #389, end to end: stage chains on all four stages,
  // load a session that defines DIFFERENT ones, then cold-boot and assert the
  // LOADED session comes back. `applySession` updates the engine and the
  // re-apply caches but never settings, so before the resync this restored the
  // pre-load Track/Master chains and an EMPTY Loop stage (the load's
  // destructive clear zeroed those keys on the way past).
  group('a session load owns the boot-restore chain keys', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late SettingsRepository settings;
    late LooperBloc bloc;
    late MonitorCubit monitor;
    late FxChainPersistence fxPersistence;

    /// A settled-empty two-track snapshot, so a load's clear-settle wait
    /// passes immediately and the boot restore has tracks to walk.
    EngineSnapshot clearedSnapshot() => const EngineSnapshot(
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
      tracks: _emptyTrackSlots,
    );

    setUp(() async {
      engine = FakeAudioEngine()..nextSnapshot = clearedSnapshot();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      settings = SettingsRepository(store: FakeKeyValueStore());
      fxPersistence = FxChainPersistence(looper: repository);
      final mixSettings = testMixSettings(repository, settings: settings);
      bloc = LooperBloc(
        fxPersistence: fxPersistence,
        mixSettings: mixSettings,
        repository: repository,
        settings: settings,
      );
      monitor = MonitorCubit(
        fxPersistence: fxPersistence,
        mixSettings: mixSettings,
        repository: repository,
        settings: settings,
      );
      addTearDown(() async {
        await bloc.close();
        await monitor.close();
        await repository.dispose();
      });
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
    });

    /// Stages the PRE-LOAD rig through the real edit paths, so every key holds
    /// a live-rig value before the load — the value that must NOT come back.
    ///
    /// Deliberately ONE lane on track 0: the loaded session below grows it to
    /// two, so `lane_count.0` is stale unless the write-back re-persists it —
    /// and a stale count silently caps the boot restore's lane loop, hiding
    /// lane 1's chain no matter how correctly it was written.
    Future<void> stagePreLoadRig() async {
      bloc
        ..add(const LooperLaneEffectAdded(0, 0, type: TrackEffectType.drive))
        ..add(
          LooperTrackEffectsChanged(0, [
            BuiltInEffect(type: TrackEffectType.drive),
          ]),
        )
        ..add(
          LooperOutputEffectsChanged(0, [
            BuiltInEffect(type: TrackEffectType.drive),
          ]),
        );
      await monitor.setMode(0, MonitorMode.on);
      monitor.addEffect(0);
      await pumpEventQueue();
    }

    /// The application's boot image boundary, independent of any widget.
    Future<void> persistLoadedRig() async {
      await fxPersistence.persistLoadedSession(settings);
      fxPersistence.completeSessionBoot();
      monitor.projectFromRepository();
    }

    /// A cold boot: a FRESH engine + repository over the SAME settings store.
    Future<FakeAudioEngine> coldBoot() async {
      final rebootEngine = FakeAudioEngine()..nextSnapshot = clearedSnapshot();
      final rebooted = LooperRepository(
        engine: rebootEngine,
        ticker: const Stream<void>.empty(),
      );
      addTearDown(rebooted.dispose);
      final started = await tryAutoStartEngine(
        mixSettings: testMixSettings(rebooted),
        repository: rebooted,
        settings: settings,
      );
      expect(started.started, isTrue);
      return rebootEngine;
    }

    test('restores the LOADED chains after a cold boot, not the pre-load '
        'ones', () async {
      await stagePreLoadRig();
      fxPersistence.reserveSessionLoad();
      await fxPersistence.beginSessionLoad();

      final pcm = Float32List.fromList([1, 1, 1, 1]);
      await repository.applySession(
        SessionRig(
          baseLengthFrames: 4,
          // TWO lanes, where the pre-load rig had one — so the restore only
          // reaches lane 1 if the write-back re-persisted the lane count.
          tracks: [
            SessionRigTrack(
              fadeAmount: 1,
              channel: 0,
              lanes: [
                SessionRigLane(
                  lane: 0,
                  layers: [pcm],
                  volume: 1,
                  muted: false,
                  outputMask: 0x3,
                  inputChannel: 0,
                ),
                SessionRigLane(
                  lane: 1,
                  layers: [pcm],
                  volume: 1,
                  muted: false,
                  outputMask: 0x3,
                  inputChannel: 0,
                ),
              ],
            ),
          ],
          laneChains: {
            (0, 0): FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.filter)],
            ),
            (0, 1): FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.echo)],
            ),
          },
          trackChains: {
            0: FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.reverb)],
            ),
          },
          outputChains: {
            0: FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
          },
          monitors: [
            SessionRigMonitor(
              input: 0,
              mode: MonitorMode.on,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              effects: [BuiltInEffect(type: TrackEffectType.echo)],
            ),
          ],
        ),
        clearPollInterval: Duration.zero,
      );
      // SessionCubit durably writes the landed rig as one canonical mix. This
      // direct domain load bypasses that cubit, so perform its storage step.
      await SettingsMixPersistence(
        settings,
      ).write('Fake Device', repository.mixSettingsSnapshot);
      await persistLoadedRig();

      final rebooted = await coldBoot();

      // Loop: the loaded filter, not the pre-load drive — and not empty.
      expect(
        rebooted.fxRecipes[(FxOwner.lane, 0, 0)]!.slots.single.type.code,
        TrackEffectType.filter.code,
      );
      // Lane 1 exists only in the LOADED session. It comes back only if the
      // write-back re-persisted `lane_count.0` too — the boot restore bounds
      // its lane loop by that key, so a stale count would drop this chain
      // even though it was written correctly.
      expect(
        (await settings.loadMixSettings('Fake Device')).laneCounts[0],
        2,
      );
      expect(
        rebooted.fxRecipes[(FxOwner.lane, 0, 1)]!.slots.single.type.code,
        TrackEffectType.echo.code,
      );
      // Track + Master: the loaded chains, not the pre-load drive.
      expect(
        rebooted.fxRecipes[(FxOwner.track, 0, 0)]!.slots.single.type.code,
        TrackEffectType.reverb.code,
      );
      expect(
        rebooted.fxRecipes[(FxOwner.output, 0, 0)]!.slots.single.type.code,
        TrackEffectType.delay.code,
      );
      // Input is the stage that was already correct — the regression canary
      // for folding its listener into the shared one. Monitors are restored by
      // MonitorCubit.load(), so assert the key it reads.
      expect(
        decodeFxChain(await settings.loadMonitorEffects(0)).entries.single,
        isA<BuiltInEffect>().having(
          (e) => e.type,
          'type',
          TrackEffectType.echo,
        ),
      );
    });

    test('a shrinking load leaves no stale chain behind', () async {
      await stagePreLoadRig();
      fxPersistence.reserveSessionLoad();
      await fxPersistence.beginSessionLoad();

      // The loaded session defines NO chains at all.
      await repository.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );
      await persistLoadedRig();

      final rebooted = await coldBoot();

      expect(await settings.loadLaneEffects(0, 0), isNull);
      expect(await settings.loadTrackFxChain(0), isNull);
      expect(rebooted.laneFx.containsKey((0, 0, 0)), isFalse);
      expect(rebooted.trackFx.containsKey((0, 0)), isFalse);
      expect(
        decodeFxChain(await settings.loadOutputFxChain(0)).entries,
        isEmpty,
      );
    });
  });
}
