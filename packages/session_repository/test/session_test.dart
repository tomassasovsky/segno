import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:session_repository/session_repository.dart';

void main() {
  const session = Session(
    sampleRate: 48000,
    channels: 1,
    baseLengthFrames: 96000,
    tracks: [
      SessionTrack(
        channel: 0,
        multiple: 1,
        lengthFrames: 96000,
        lanes: [
          SessionLane(
            lane: 0,
            volume: 0.8,
            muted: false,
            outputMask: 0x3,
            inputChannel: 0,
            layers: [SessionLayer(file: 'track0_lane0_L0.wav')],
          ),
          SessionLane(
            lane: 1,
            volume: 0.6,
            muted: true,
            outputMask: 0x2,
            inputChannel: 1,
            layers: [SessionLayer(file: 'track0_lane1_L0.wav')],
          ),
        ],
      ),
      SessionTrack(
        channel: 1,
        multiple: 2,
        lengthFrames: 192000,
        lanes: [
          SessionLane(
            lane: 0,
            volume: 0.5,
            muted: true,
            outputMask: 0x3,
            inputChannel: 0,
            layers: [SessionLayer(file: 'track1_lane0_L0.wav')],
          ),
        ],
      ),
    ],
    laneChains: [
      SessionLaneChain(channel: 0, lane: 0, encoded: '[{"t":1}]'),
      SessionLaneChain(channel: 1, lane: 0, encoded: '[{"t":7}]'),
    ],
    monitors: [
      SessionMonitor(
        input: 0,
        mode: 'on',
        outputMask: 0x3,
        volume: 0.9,
        muted: false,
        encoded: '[{"t":2}]',
      ),
    ],
    // The two bus stages (schema v5). Their strings are opaque here, exactly
    // like the lane/monitor ones above — a chain-envelope shape stands in for
    // the real `encodeFxChain` output the app-side mapper produces.
    trackChains: [
      SessionTrackChain(
        channel: 0,
        encoded: '{"chainEnabled":false,"entries":[{"t":3}]}',
      ),
      SessionTrackChain(
        channel: 1,
        encoded: '{"chainEnabled":true,"entries":[]}',
      ),
    ],
    masterChain: '{"chainEnabled":true,"entries":[{"t":9}]}',
    tempoBpm: 128.5,
    tempoSource: TempoSource.manual,
    tsNum: 6,
    tsDen: 8,
    quantizeDiv: GridDivision.eighth,
    loopBars: 5,
    recordTiming: RecordTiming.eighth,
    overdubDecay: 25,
    clickMode: ClickMode.rec,
    clickOutputMask: 0x3,
    clickVolume: 0.75,
    countInBars: 2,
    looperMode: LooperMode.band,
    primaryTrack: 1,
    defaultOneShot: true,
    defaultLengthPresetBars: 8,
    trackOneShotOverrides: {0: true, 2: false},
    trackRecordTimingOverrides: {0: RecordTiming.bar, 2: RecordTiming.eighth},
    trackOverdubDecayOverrides: {0: 30, 2: 25},
    trackLengthPresetOverrides: {0: 4, 2: 8},
    syncTempo: false,
    recDub: true,
    autoRecord: true,
    defaultMultiple: 3,
    // The pedal remap (schema v6) — opaque here exactly like the chain
    // strings above; a binding-set shape stands in for the real
    // `PedalBindingSet.encode()` output the control layer produces.
    pedalBindings:
        r'[{"button":"stop","target":"{\"stage\":\"track\",'
        r'\"index\":5}","behavior":"momentary"}]',
  );

  group('Session', () {
    test('round-trips through JSON (including jsonEncode/decode)', () {
      final json = jsonDecode(jsonEncode(session.toJson()));
      expect(Session.fromJson(json as Map<String, dynamic>), session);
    });

    test('serializes the manifest version (v9)', () {
      final json = session.toJson();
      expect(json['version'], Session.formatVersion);
      expect(json['version'], 9);
      expect(json['baseLengthFrames'], 96000);
    });

    test('schema 9 keeps output setup and all four nullable override maps', () {
      final manifest = session.toJson()
        ..['tracks'] = <Object>[]
        ..['outputSetup'] = {
          'level': {'1': 0.5},
          'muted': {'1': true},
          'mono': {'0': true},
          'balance': {'0': -0.25},
        }
        ..['trackRecordTimingOverrides'] = {'0': 'bar'}
        ..['trackOverdubDecayOverrides'] = {'1': 30}
        ..['trackOneShotOverrides'] = {'2': false}
        ..['trackLengthPresetOverrides'] = {'3': 0};
      final parsed = Session.fromJson(manifest);
      final roundTrip = Session.fromJson(
        jsonDecode(jsonEncode(parsed.toJson())) as Map<String, dynamic>,
      );
      expect(
        roundTrip.outputSetup,
        const SessionOutputSetup(
          level: {1: .5},
          muted: {1: true},
          mono: {0: true},
          balance: {0: -.25},
        ),
      );
      expect(roundTrip.trackRecordTimingOverrides, {0: RecordTiming.bar});
      expect(roundTrip.trackOverdubDecayOverrides, {1: 30});
      expect(roundTrip.trackOneShotOverrides, {2: false});
      expect(roundTrip.trackLengthPresetOverrides, {3: 0});
    });

    test('invalid output facts in schema 9 are rejected', () {
      final manifest = session.toJson();
      expect(
        () => Session.fromJson(
          manifest
            ..['outputSetup'] = {
              'muted': {'0': 'yes'},
            },
        ),
        throwsFormatException,
      );
      expect(
        () => Session.fromJson(
          session.toJson()
            ..['outputSetup'] = {
              'level': {'16': .5},
            },
        ),
        throwsFormatException,
      );
    });

    group('the All tracks chain (schema v9)', () {
      test('round-trips as an opaque envelope string', () {
        const encoded = '{"chainEnabled":true,"entries":[{"type":1}]}';
        final json = Session(
          sampleRate: session.sampleRate,
          channels: session.channels,
          baseLengthFrames: session.baseLengthFrames,
          tracks: session.tracks,
          allTracksChain: encoded,
        ).toJson();
        expect(json['allTracksChain'], encoded);
        expect(Session.fromJson(json).allTracksChain, encoded);
      });

      test('a current manifest requires the All tracks field', () {
        final json = session.toJson()..remove('allTracksChain');
        expect(() => Session.fromJson(json), throwsA(isA<TypeError>()));
      });

      test('schema 8 is not silently upgraded to schema 9', () {
        final json = session.toJson()..['version'] = 8;
        expect(
          () => Session.fromJson(json),
          throwsA(isA<SessionUnsupportedVersion>()),
        );
      });
    });

    group('monitor gate (schema 9)', () {
      test('a named gate round-trips', () {
        const monitor = SessionMonitor(
          input: 2,
          mode: 'auto',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );

        expect(monitor.toJson()['mode'], 'auto');
        expect(SessionMonitor.fromJson(monitor.toJson()), monitor);
      });

      test('a current-schema monitor requires its mode', () {
        final json = const SessionMonitor(
          input: 2,
          mode: 'on',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        ).toJson()..remove('mode');
        expect(() => SessionMonitor.fromJson(json), throwsFormatException);
      });

      test('participates in equality — two monitors differing only in their '
          'gate are different monitors', () {
        const on = SessionMonitor(
          input: 0,
          mode: 'on',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );
        const auto = SessionMonitor(
          input: 0,
          mode: 'auto',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );

        expect(on, isNot(auto));
        expect(on.hashCode, isNot(auto.hashCode));
      });
    });

    group('pedal remap blob (schema 9)', () {
      test('round-trips byte-intact — the control layer compares these '
          'strings for equality, so a single character of drift would look '
          'like an edit', () {
        final json = jsonDecode(jsonEncode(session.toJson()));
        final loaded = Session.fromJson(json as Map<String, dynamic>);
        expect(loaded.pedalBindings, session.pedalBindings);
        expect(loaded, session);
      });

      test('is opaque to this package — a payload it cannot interpret still '
          'survives a round-trip', () {
        const opaque = Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 0,
          tracks: [],
          pedalBindings: 'not-json-at-all',
        );
        final json = jsonDecode(jsonEncode(opaque.toJson()));
        expect(
          Session.fromJson(json as Map<String, dynamic>).pedalBindings,
          'not-json-at-all',
        );
      });

      test('a missing required remap field is corrupt schema 9', () {
        final json = session.toJson()..remove('pedalBindings');
        expect(() => Session.fromJson(json), throwsA(isA<TypeError>()));
      });

      test('participates in equality — two sessions differing only in their '
          'remap are not the same session', () {
        final json = session.toJson()..['pedalBindings'] = '[]';
        expect(Session.fromJson(json), isNot(session));
      });
    });

    test('serializes the bus stages (Track + Master)', () {
      final json = session.toJson();
      expect(json['trackChains'], [
        {
          'channel': 0,
          'encoded': '{"chainEnabled":false,"entries":[{"t":3}]}',
        },
        {'channel': 1, 'encoded': '{"chainEnabled":true,"entries":[]}'},
      ]);
      expect(json['masterChain'], '{"chainEnabled":true,"entries":[{"t":9}]}');
    });

    test('round-trips bus-stage chain strings byte-intact', () {
      final json = jsonDecode(jsonEncode(session.toJson()));
      final loaded = Session.fromJson(json as Map<String, dynamic>);
      expect(loaded.trackChains, hasLength(2));
      expect(loaded.trackChains[0].channel, 0);
      expect(
        loaded.trackChains[0].encoded,
        '{"chainEnabled":false,"entries":[{"t":3}]}',
      );
      // A track whose chain is empty but whose flag is set still round-trips —
      // the flag lives inside the string, so an "empty" chain is not nothing.
      expect(
        loaded.trackChains[1].encoded,
        '{"chainEnabled":true,"entries":[]}',
      );
      expect(loaded.masterChain, '{"chainEnabled":true,"entries":[{"t":9}]}');
      expect(loaded, session);
    });

    test(
      'save -> load -> save is byte-idempotent (the manifest a load '
      're-serializes is the manifest it read; slot ids ride the opaque chain '
      'strings, so nothing is re-minted here)',
      () {
        final written = jsonEncode(session.toJson());
        final reloaded = Session.fromJson(
          jsonDecode(written) as Map<String, dynamic>,
        );
        expect(jsonEncode(reloaded.toJson()), written);
      },
    );

    test('rejects a prior schema even when its fields parse', () {
      final json = session.toJson()..['version'] = 7;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });

    test('serializes every tempo/click/count-in field', () {
      final json = session.toJson();
      expect(json['tempoBpm'], 128.5);
      expect(json['tempoSource'], 'manual');
      expect(json['tsNum'], 6);
      expect(json['tsDen'], 8);
      expect(json['quantizeDiv'], 'eighth');
      expect(json['loopBars'], 5);
      expect(json['clickMode'], 'rec');
      expect(json['clickOutputMask'], 0x3);
      expect(json['clickVolume'], 0.75);
      expect(json['countInBars'], 2);
      expect(json['looperMode'], 'band');
      expect(json['primaryTrack'], 1);
      expect(json['defaultOneShot'], isTrue);
      expect(json['trackOneShotOverrides'], {'0': true, '2': false});
      expect(json['defaultLengthPresetBars'], 8);
      expect(json['trackLengthPresetOverrides'], {'0': 4, '2': 8});
    });

    test('round-trips settings independently of recorded tracks', () {
      final loaded = Session.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(loaded, session);
      expect(loaded.defaultOneShot, isTrue);
      expect(loaded.trackOneShotOverrides, {0: true, 2: false});
      expect(loaded.trackRecordTimingOverrides, {
        0: RecordTiming.bar,
        2: RecordTiming.eighth,
      });
      expect(loaded.trackOverdubDecayOverrides, {0: 30, 2: 25});
      expect(loaded.trackLengthPresetOverrides, {0: 4, 2: 8});
      expect(loaded.defaultLengthPresetBars, 8);
      expect(loaded.trackOneShotOverrides.containsKey(1), isFalse);
      expect(loaded.tracks.map((track) => track.channel), [0, 1]);
      expect(loaded.syncTempo, isFalse);
      expect(loaded.recDub, isTrue);
      expect(loaded.autoRecord, isTrue);
      expect(loaded.defaultMultiple, 3);
    });

    test('rejects invalid whole-track gain facts', () {
      for (final invalid in [
        {'8': .5},
        {'0': -0.1},
        {'0': 2.1},
        {'0': 'unity'},
      ]) {
        expect(
          () => Session.fromJson(session.toJson()..['trackLevels'] = invalid),
          throwsFormatException,
        );
      }
    });

    test('all-empty sessions retain explicit defaults and Use default', () {
      const empty = Session(
        sampleRate: 48000,
        channels: 1,
        baseLengthFrames: 0,
        tracks: [],
        recordTiming: RecordTiming.bar,
        overdubDecay: 25,
        trackRecordTimingOverrides: {0: RecordTiming.bar},
        trackOverdubDecayOverrides: {0: 25, 1: 0},
        trackOneShotOverrides: {0: false, 1: true},
        trackLengthPresetOverrides: {0: 4},
        trackLevels: {7: .65},
      );
      final loaded = Session.fromJson(
        jsonDecode(jsonEncode(empty.toJson())) as Map<String, dynamic>,
      );
      expect(loaded.tracks, isEmpty);
      expect(loaded.trackRecordTimingOverrides, {0: RecordTiming.bar});
      expect(loaded.trackOverdubDecayOverrides, {0: 25, 1: 0});
      expect(loaded.trackOneShotOverrides, {0: false, 1: true});
      expect(loaded.trackLengthPresetOverrides, {0: 4});
      expect(loaded.trackLevels, {7: .65});
      expect(loaded, empty);
      expect(loaded.hashCode, empty.hashCode);
    });

    test('equality distinguishes each setting from its default', () {
      final variants = <String, Object>{
        'loopBars': 0,
        'recordTiming': 'bar',
        'overdubDecay': 60,
        'defaultOneShot': false,
        'syncTempo': true,
        'recDub': false,
        'autoRecord': false,
        'defaultMultiple': 2,
        'trackRecordTimingOverrides': {'0': 'bar'},
        'trackOverdubDecayOverrides': {'0': 30},
        'trackOneShotOverrides': {'0': true},
        'trackLengthPresetOverrides': {'0': 4},
        'trackLevels': {'7': .65},
      };
      for (final entry in variants.entries) {
        final changed = Session.fromJson(
          session.toJson()..[entry.key] = entry.value,
        );
        expect(changed, isNot(session), reason: entry.key);
      }
    });

    test('override map equality and hashing ignore insertion order', () {
      final reordered = Session.fromJson(
        session.toJson()
          ..['trackOneShotOverrides'] = {'2': false, '0': true}
          ..['trackRecordTimingOverrides'] = {'2': 'eighth', '0': 'bar'}
          ..['trackOverdubDecayOverrides'] = {'2': 25, '0': 30}
          ..['trackLengthPresetOverrides'] = {'2': 8, '0': 4},
      );
      expect(reordered, session);
      expect(reordered.hashCode, session.hashCode);
    });

    test('requires an integer version field', () {
      final absent = session.toJson()..remove('version');
      final fractional = session.toJson()..['version'] = 8.5;
      expect(() => Session.fromJson(absent), throwsFormatException);
      expect(() => Session.fromJson(fractional), throwsFormatException);
    });

    test('serializes tracks as per-lane layers', () {
      final json = session.toJson();
      final track0 = (json['tracks'] as List).first as Map<String, dynamic>;
      expect(track0['lanes'], hasLength(2));
      final lane0 = (track0['lanes'] as List).first as Map<String, dynamic>;
      expect(lane0, {
        'lane': 0,
        'volume': 0.8,
        'muted': false,
        'outputMask': 0x3,
        'inputChannel': 0,
        'layers': [
          {'file': 'track0_lane0_L0.wav'},
        ],
        'undoCount': 0,
        'redoCount': 0,
      });
    });

    test('does not migrate a stem-only track into a lane', () {
      final track = {
        'channel': 0,
        'multiple': 1,
        'lengthFrames': 96000,
        'stem': 'track0.wav',
      };
      expect(() => SessionTrack.fromJson(track), throwsA(isA<TypeError>()));
    });

    test('tracks, lanes, layers, chains, and monitors have value equality', () {
      expect(session.tracks.first, isNot(session.tracks[1]));
      expect(session.tracks.first, session.tracks.first);
      expect(
        session.tracks.first.lanes.first,
        isNot(session.tracks.first.lanes[1]),
      );
      expect(
        session.tracks.first.lanes.first,
        session.tracks.first.lanes.first,
      );
      expect(
        const SessionLayer(file: 'a.wav'),
        isNot(const SessionLayer(file: 'b.wav')),
      );
      expect(session.laneChains.first, isNot(session.laneChains[1]));
      expect(session.monitors.first, session.monitors.first);
      expect(session.trackChains.first, isNot(session.trackChains[1]));
      const sameTrackChain = SessionTrackChain(
        channel: 0,
        encoded: '{"chainEnabled":false,"entries":[{"t":3}]}',
      );
      expect(session.trackChains.first, sameTrackChain);
      expect(session.trackChains.first.hashCode, sameTrackChain.hashCode);
    });

    test('liveIndex tracks undoCount', () {
      const lane = SessionLane(
        lane: 0,
        volume: 1,
        muted: false,
        outputMask: 0x3,
        inputChannel: 0,
        undoCount: 2,
        redoCount: 1,
        layers: [
          SessionLayer(file: 'u0.wav'),
          SessionLayer(file: 'u1.wav'),
          SessionLayer(file: 'live.wav'),
          SessionLayer(file: 'r0.wav'),
        ],
      );
      expect(lane.liveIndex, 2);
      expect(lane.layers[lane.liveIndex].file, 'live.wav');
    });

    test('rejects a newer, incompatible manifest version', () {
      final json = session.toJson()..['version'] = Session.formatVersion + 1;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });

    test(
      'rejects a newer manifest (an extra unknown field does not '
      'change the outcome) via the existing version-gate check',
      () {
        final json = session.toJson()
          ..['version'] = Session.formatVersion + 1
          // A field a hypothetical future schema might add — proves the
          // rejection is purely the version-number gate, not incidentally
          // triggered by an unparseable shape.
          ..['bandGroups'] = [
            {'name': 'chorus'},
          ];
        expect(
          () => Session.fromJson(json),
          throwsA(
            isA<SessionUnsupportedVersion>()
                .having((e) => e.version, 'version', Session.formatVersion + 1)
                .having((e) => e.supported, 'supported', Session.formatVersion),
          ),
        );
      },
    );

    test('rejects a lane whose layer count disagrees with its undo/redo', () {
      // undoCount 2 + live + redoCount 0 claims 3 layers but lists 1.
      final json = session.toJson();
      final lane0 =
          ((json['tracks'] as List).first as Map<String, dynamic>)['lanes']
              as List;
      (lane0.first as Map<String, dynamic>)
        ..['undoCount'] = 2
        ..['redoCount'] = 0;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionCorruptLayers>()),
      );
    });

    test('rejects a lane claiming more layers than the pool cap', () {
      final json = session.toJson();
      final lane0 =
          ((json['tracks'] as List).first as Map<String, dynamic>)['lanes']
              as List;
      (lane0.first as Map<String, dynamic>)
        ..['undoCount'] = SessionLane.maxLayers
        ..['redoCount'] = 0
        ..['layers'] = [
          for (var i = 0; i < SessionLane.maxLayers + 1; i++)
            {'file': 'x$i.wav'},
        ];
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionCorruptLayers>()),
      );
    });

    test('rejects a lane with a negative undo/redo count', () {
      final json = session.toJson();
      final lane0 =
          ((json['tracks'] as List).first as Map<String, dynamic>)['lanes']
              as List;
      (lane0.first as Map<String, dynamic>)
        ..['undoCount'] = -1
        ..['redoCount'] = 1
        // length matches undoCount+1+redoCount (== 1) so only the negativity
        // branch can reject this.
        ..['layers'] = [
          {'file': 'x.wav'},
        ];
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionCorruptLayers>()),
      );
    });

    test('accepts a lane at exactly the pool cap', () {
      final json = session.toJson();
      final lane0 =
          ((json['tracks'] as List).first as Map<String, dynamic>)['lanes']
              as List;
      (lane0.first as Map<String, dynamic>)
        ..['undoCount'] = SessionLane.maxLayers - 1
        ..['redoCount'] = 0
        ..['layers'] = [
          for (var i = 0; i < SessionLane.maxLayers; i++) {'file': 'x$i.wav'},
        ];
      final loaded = Session.fromJson(json);
      expect(loaded.tracks.first.lanes.first.layers, hasLength(256));
    });
  });
}
