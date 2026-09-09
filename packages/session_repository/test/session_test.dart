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
        lengthPresetOverride: 4,
        onceOverride: true,
        recordTiming: RecordTiming.bar,
        overdubDecay: 30,
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
        // An explicit Auto and an explicit Loop: both differ from "follows
        // the default" (null) and must survive as written.
        lengthPresetOverride: 0,
        onceOverride: false,
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
        enabled: true,
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
    recordTiming: RecordTiming.eighth,
    overdubDecay: 25,
    defaultLengthPresetBars: 2,
    defaultOnce: true,
    clickMode: ClickMode.rec,
    clickOutputMask: 0x3,
    clickVolume: 0.75,
    countInBars: 2,
    looperMode: LooperMode.band,
    primaryTrack: 1,
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

    test('serializes the manifest version (v7)', () {
      final json = session.toJson();
      expect(json['version'], Session.formatVersion);
      expect(json['version'], 7);
      expect(json['baseLengthFrames'], 96000);
    });

    group('monitor gate (schema v7)', () {
      test('a named gate round-trips', () {
        const monitor = SessionMonitor(
          input: 2,
          enabled: true,
          mode: 'auto',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );

        expect(monitor.toJson()['mode'], 'auto');
        expect(SessionMonitor.fromJson(monitor.toJson()), monitor);
      });

      test('a v6 monitor keeps the key out of the manifest entirely', () {
        const monitor = SessionMonitor(
          input: 2,
          enabled: true,
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );

        // Presence-keyed, like every rung before it: absent means "this
        // manifest did not say", which is a different thing from a monitor
        // whose gate happens to be named the empty string.
        expect(monitor.toJson().containsKey('mode'), isFalse);
        expect(SessionMonitor.fromJson(monitor.toJson()).mode, isEmpty);
      });

      test('participates in equality — two monitors differing only in their '
          'gate are different monitors', () {
        const on = SessionMonitor(
          input: 0,
          enabled: true,
          mode: 'on',
          outputMask: 0x3,
          volume: 1,
          muted: false,
          encoded: '',
        );
        const auto = SessionMonitor(
          input: 0,
          enabled: true,
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

    group('pedal remap blob (schema v6)', () {
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

      test('a v5-or-earlier manifest loads with no session remap, so the '
          'global set applies (A12)', () {
        final json = session.toJson()..remove('pedalBindings');
        expect(Session.fromJson(json).pedalBindings, isEmpty);
      });

      test('participates in equality — two sessions differing only in their '
          'remap are not the same session', () {
        final json = session.toJson()..['pedalBindings'] = '[]';
        expect(Session.fromJson(json), isNot(session));
      });
    });

    test('serializes the schema-v5 bus stages (Track + Master)', () {
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

    test('v5 round-trips the bus stages, chain strings byte-intact', () {
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
      'save -> load -> save is byte-idempotent at v5 (the manifest a load '
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

    test(
      'a v4 manifest (no bus stages, bare-array chain strings) loads with '
      'both bus stages EMPTY and its chain content byte-identical — the '
      'presence-keyed v4 -> v5 migration, zero data loss',
      () {
        final v4 = {
          'version': 4,
          'sampleRate': 48000,
          'channels': 1,
          'baseLengthFrames': 96000,
          'tracks': [
            {
              'channel': 0,
              'multiple': 1,
              'lengthFrames': 96000,
              'lanes': [
                {
                  'lane': 0,
                  'volume': 0.8,
                  'muted': false,
                  'outputMask': 0x3,
                  'inputChannel': 0,
                  'layers': [
                    {'file': 'track0_lane0_L0.wav'},
                  ],
                },
              ],
            },
          ],
          // Pre-envelope wire format: the bare entries array. It stays opaque
          // here; the looper domain's decoder defaults every level to enabled.
          'laneChains': [
            {'channel': 0, 'lane': 0, 'encoded': '[{"t":1}]'},
          ],
          'monitors': [
            {
              'input': 0,
              'enabled': true,
              'outputMask': 0x3,
              'volume': 0.9,
              'muted': false,
              'encoded': '[{"t":2}]',
            },
          ],
          'tempoBpm': 128.5,
          'looperMode': 'band',
        };

        final loaded = Session.fromJson(v4);

        expect(loaded.trackChains, isEmpty);
        expect(loaded.masterChain, '');
        // Everything v4 DID describe survives untouched.
        expect(loaded.laneChains.single.encoded, '[{"t":1}]');
        expect(loaded.monitors.single.encoded, '[{"t":2}]');
        expect(loaded.tempoBpm, 128.5);
        expect(loaded.looperMode, LooperMode.band);
        expect(loaded.tracks.single.lanes.single.volume, 0.8);
        // And re-saving stamps the CURRENT version without inventing
        // bus-stage content (or a remap the v4 bundle never carried).
        final resaved = loaded.toJson();
        expect(resaved['version'], Session.formatVersion);
        expect(resaved['trackChains'], isEmpty);
        expect(resaved['masterChain'], '');
        expect(resaved['pedalBindings'], '');
      },
    );

    test('serializes every schema-v4 tempo/click/count-in field', () {
      final json = session.toJson();
      expect(json['tempoBpm'], 128.5);
      expect(json['tempoSource'], 'manual');
      expect(json['tsNum'], 6);
      expect(json['tsDen'], 8);
      expect(json['quantizeDiv'], 'eighth');
      expect(json['clickMode'], 'rec');
      expect(json['clickOutputMask'], 0x3);
      expect(json['clickVolume'], 0.75);
      expect(json['countInBars'], 2);
      expect(json['looperMode'], 'band');
      expect(json['primaryTrack'], 1);
      expect(json['defaultLengthPresetBars'], 2);
      expect(json['defaultOnce'], isTrue);
      final tracks = json['tracks'] as List;
      final track0 = tracks[0] as Map<String, dynamic>;
      expect(track0['lengthPresetOverride'], 4);
      expect(track0['onceOverride'], isTrue);
      final track1 = tracks[1] as Map<String, dynamic>;
      expect(track1['lengthPresetOverride'], 0);
      expect(track1['onceOverride'], isFalse);
    });

    test(
      'a track that follows the defaults serializes neither override key, '
      'and reads back with both overrides null',
      () {
        const following = SessionTrack(
          channel: 0,
          multiple: 1,
          lengthFrames: 4,
          lanes: [],
        );
        final json = following.toJson();
        expect(json.containsKey('lengthPresetOverride'), isFalse);
        expect(json.containsKey('onceOverride'), isFalse);
        final loaded = SessionTrack.fromJson(
          jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
        );
        expect(loaded.lengthPresetOverride, isNull);
        expect(loaded.onceOverride, isNull);
        expect(loaded, following);
      },
    );

    test(
      'v4 round-trips every new field (tempo/signature/quantize/click/ '
      'count-in, looperMode/primaryTrack, the loop-setting defaults, and '
      'the per-track lengthPresetOverride/onceOverride)',
      () {
        final json = jsonDecode(jsonEncode(session.toJson()));
        final loaded = Session.fromJson(json as Map<String, dynamic>);
        expect(loaded.tempoBpm, 128.5);
        expect(loaded.tempoSource, TempoSource.manual);
        expect(loaded.tsNum, 6);
        expect(loaded.tsDen, 8);
        expect(loaded.quantizeDiv, GridDivision.eighth);
        expect(loaded.clickMode, ClickMode.rec);
        expect(loaded.clickOutputMask, 0x3);
        expect(loaded.clickVolume, 0.75);
        expect(loaded.countInBars, 2);
        expect(loaded.looperMode, LooperMode.band);
        expect(loaded.primaryTrack, 1);
        expect(loaded.defaultLengthPresetBars, 2);
        expect(loaded.defaultOnce, isTrue);
        expect(loaded.tracks[0].lengthPresetOverride, 4);
        expect(loaded.tracks[0].onceOverride, isTrue);
        // An explicit Auto (0) and an explicit Loop (false) round-trip as
        // themselves, not as "follows the default".
        expect(loaded.tracks[1].lengthPresetOverride, 0);
        expect(loaded.tracks[1].onceOverride, isFalse);
        expect(loaded, session);
      },
    );

    test(
      'a v3 manifest (no tempo grid fields at all) loads with every new '
      'field at its grid-off default — zero data loss',
      () {
        final v3 = {
          'version': 3,
          'sampleRate': 48000,
          'channels': 1,
          'baseLengthFrames': 96000,
          'tracks': [
            {
              'channel': 0,
              'multiple': 1,
              'lengthFrames': 96000,
              'lanes': [
                {
                  'lane': 0,
                  'volume': 1.0,
                  'muted': false,
                  'outputMask': 0x3,
                  'inputChannel': 0,
                  'layers': [
                    {'file': 'track0_lane0_L0.wav'},
                  ],
                },
              ],
            },
          ],
          'laneChains': <dynamic>[],
          'monitors': <dynamic>[],
        };
        final loaded = Session.fromJson(v3);
        expect(loaded.tempoBpm, 0);
        expect(loaded.tempoSource, TempoSource.none);
        expect(loaded.tsNum, 4);
        expect(loaded.tsDen, 4);
        expect(loaded.quantizeDiv, GridDivision.off);
        expect(loaded.clickMode, ClickMode.off);
        expect(loaded.clickOutputMask, 0);
        expect(loaded.clickVolume, 1);
        expect(loaded.countInBars, 0);
        expect(loaded.defaultLengthPresetBars, 0);
        expect(loaded.defaultOnce, isFalse);
        expect(loaded.tracks.single.lengthPresetOverride, isNull);
        expect(loaded.tracks.single.onceOverride, isNull);
        // The rest of the v3 manifest still loads intact.
        expect(loaded.baseLengthFrames, 96000);
        expect(loaded.tracks.single.lanes.single.volume, 1.0);
      },
    );

    test(
      'a v4 manifest missing later-phase (C/D) fields still loads — the '
      'loader only reads the fields it knows about',
      () {
        final json = session.toJson();
        // Simulate a build that hasn't shipped Phase C/D yet reading a file
        // written by a build that HAS: extra top-level and per-track fields
        // this code has never heard of (session_repository.dart:8-9 doesn't
        // read any of these keys, so they should simply be ignored). B5c
        // (looperMode/primaryTrack) is EXCLUDED from this list — this
        // code understands those now, see the test below.
        json['clockMode'] = 'send';
        json['syncAudioToTempo'] = true;
        final track0 = (json['tracks'] as List).first as Map<String, dynamic>;
        track0['freeLengthFrames'] = 48000;
        track0['originalTempoBpm'] = 90.0;

        final loaded = Session.fromJson(json);
        expect(loaded, session);
      },
    );

    test(
      'reads looperMode and primaryTrack when present (B5c) — unlike the '
      'still-future C/D fields above, these ARE understood by this code',
      () {
        final json = session.toJson();
        json['looperMode'] = 'sync';
        json['primaryTrack'] = 0;

        final loaded = Session.fromJson(json);
        expect(loaded.looperMode, LooperMode.sync);
        expect(loaded.primaryTrack, 0);
      },
    );

    test(
      'ignores the pre-slice-2c keys (per-track effective '
      'lengthPresetBars/oneShot and the session-level oneShotChannels set): '
      'they are not migrated into overrides',
      () {
        final json = session.toJson()..['oneShotChannels'] = [0, 3];
        ((json['tracks'] as List).first as Map<String, dynamic>)
          ..remove('lengthPresetOverride')
          ..remove('onceOverride')
          ..['lengthPresetBars'] = 4
          ..['oneShot'] = true;

        final loaded = Session.fromJson(json);
        expect(loaded.tracks[0].lengthPresetOverride, isNull);
        expect(loaded.tracks[0].onceOverride, isNull);
        expect(loaded.toJson().containsKey('oneShotChannels'), isFalse);
      },
    );

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

    test('a v1 manifest (single stem, no chains) migrates to one lane', () {
      // A legacy bundle: one `stem` per track, track-level mix, no lanes/chains.
      final v1 = {
        'version': 1,
        'sampleRate': 48000,
        'channels': 1,
        'baseLengthFrames': 96000,
        'tracks': [
          {
            'channel': 0,
            'volume': 0.8,
            'muted': false,
            'multiple': 1,
            'lengthFrames': 96000,
            'stem': 'track0.wav',
          },
        ],
      };
      final loaded = Session.fromJson(v1);
      expect(loaded.laneChains, isEmpty);
      expect(loaded.monitors, isEmpty);
      expect(loaded.tracks, hasLength(1));
      final track = loaded.tracks.single;
      expect(track.lanes, hasLength(1));
      final lane = track.lanes.single;
      expect(lane.lane, 0);
      expect(lane.volume, 0.8);
      expect(lane.muted, isFalse);
      expect(lane.inputChannel, -1);
      expect(lane.undoCount, 0);
      expect(lane.layers, [const SessionLayer(file: 'track0.wav')]);
    });

    test('a v2 manifest (single stem + chains) migrates to one lane', () {
      final v2 = {
        'version': 2,
        'sampleRate': 48000,
        'channels': 1,
        'baseLengthFrames': 96000,
        'tracks': [
          {
            'channel': 0,
            'volume': 0.5,
            'muted': true,
            'multiple': 2,
            'lengthFrames': 192000,
            'stem': 'track0.wav',
          },
        ],
        'laneChains': [
          {'channel': 0, 'lane': 0, 'encoded': '[{"t":1}]'},
        ],
        'monitors': <dynamic>[],
      };
      final loaded = Session.fromJson(v2);
      expect(loaded.laneChains, hasLength(1));
      expect(loaded.tracks.single.lanes, hasLength(1));
      final lane = loaded.tracks.single.lanes.single;
      expect(lane.volume, 0.5);
      expect(lane.muted, isTrue);
      expect(lane.layers.single.file, 'track0.wav');
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
      'rejects a hypothetical v8 manifest (an extra unknown field does not '
      'change the outcome) via the existing version-gate check',
      () {
        final json = session.toJson()
          ..['version'] = 8
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
                .having((e) => e.version, 'version', 8)
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
