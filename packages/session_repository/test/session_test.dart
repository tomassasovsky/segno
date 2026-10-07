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
        fadeAmount: 1,
        reversed: false,
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
            history: TrackHistory.none,
          ),
          SessionLane(
            lane: 1,
            volume: 0.6,
            muted: true,
            outputMask: 0x2,
            inputChannel: 1,
            layers: [SessionLayer(file: 'track0_lane1_L0.wav')],
            history: TrackHistory.none,
          ),
        ],
      ),
      SessionTrack(
        fadeAmount: 1,
        reversed: false,
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
            history: TrackHistory.none,
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
    outputChains: [
      SessionOutputChain(
        bus: 0,
        encoded: '{"chainEnabled":true,"entries":[{"t":9}]}',
      ),
    ],
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

  group('SessionTrack Fade amount', () {
    test('strictly preserves stationary endpoints and value identity', () {
      final original = session.tracks.first;
      for (final amount in [0.0, .25, 1.0]) {
        final json = {...original.toJson(), 'fadeAmount': amount};
        final decoded = SessionTrack.fromJson(json);
        expect(decoded.fadeAmount, amount);
        expect(decoded.toJson()['fadeAmount'], amount);
        expect(SessionTrack.fromJson(decoded.toJson()), decoded);
        expect(
          SessionTrack.fromJson(decoded.toJson()).hashCode,
          decoded.hashCode,
        );
        if (amount != original.fadeAmount) {
          expect(decoded, isNot(original));
        }
      }
    });
    test(
      'rejects missing and malformed amounts rather than assuming unity',
      () {
        final json = session.tracks.first.toJson()..remove('fadeAmount');
        expect(() => SessionTrack.fromJson(json), throwsFormatException);
        for (final invalid in [
          null,
          '0.5',
          true,
          -.1,
          1.1,
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          expect(
            () => SessionTrack.fromJson({...json, 'fadeAmount': invalid}),
            throwsFormatException,
          );
        }
      },
    );
  });

  group('SessionTrack playback direction', () {
    test('round-trips and takes part in value identity', () {
      final original = session.tracks.first;
      final json = {...original.toJson(), 'reversed': true};
      final decoded = SessionTrack.fromJson(json);
      expect(decoded.reversed, isTrue);
      expect(decoded.toJson()['reversed'], isTrue);
      expect(SessionTrack.fromJson(decoded.toJson()), decoded);
      expect(decoded, isNot(original));
      expect(decoded.hashCode, isNot(original.hashCode));
    });

    test('rejects a missing or malformed direction rather than assuming '
        'forward', () {
      final json = session.tracks.first.toJson()..remove('reversed');
      expect(() => SessionTrack.fromJson(json), throwsFormatException);
      for (final invalid in [null, 0, 1, 'true', 'reversed']) {
        expect(
          () => SessionTrack.fromJson({...json, 'reversed': invalid}),
          throwsFormatException,
        );
      }
    });

    test('direction is carried since version 13', () {
      expect(Session.formatVersion, greaterThanOrEqualTo(13));
      final json = session.toJson()..['version'] = 11;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });
  });

  group('Session', () {
    test('round-trips through JSON (including jsonEncode/decode)', () {
      final json = jsonDecode(jsonEncode(session.toJson()));
      expect(Session.fromJson(json as Map<String, dynamic>), session);
    });

    test('refuses an unsupported count-in at decode', () {
      for (final bad in <Object?>[3, 5, -1, 1.5, '2', null]) {
        expect(
          () => Session.fromJson({...session.toJson(), 'countInBars': bad}),
          throwsFormatException,
          reason: '$bad',
        );
      }
      for (final good in [0, 1, 2, 4]) {
        expect(
          Session.fromJson({
            ...session.toJson(),
            'countInBars': good,
          }).countInBars,
          good,
        );
      }
    });

    for (final key in [
      'trackRecordTimingOverrides',
      'trackOverdubDecayOverrides',
      'trackOneShotOverrides',
      'trackLengthPresetOverrides',
      'trackPans',
    ]) {
      test('refuses a $key key outside the eight tracks at decode', () {
        final valid = session.toJson()[key] as Map<String, dynamic>? ?? {};
        final value = switch (key) {
          'trackRecordTimingOverrides' => 'bar',
          'trackOneShotOverrides' => true,
          'trackPans' => 0.5,
          _ => 4,
        };
        for (final bad in ['8', '-1']) {
          expect(
            () => Session.fromJson({
              ...session.toJson(),
              key: {...valid, bad: value},
            }),
            throwsFormatException,
            reason: bad,
          );
        }
        expect(
          () => Session.fromJson({
            ...session.toJson(),
            key: {...valid, '7': value},
          }),
          returnsNormally,
        );
      });
    }

    test(
      'Fade duration equality distinguishes Default and Custom membership',
      () {
        final base = session.toJson();
        final changedDefault = Session.fromJson({
          ...base,
          'defaultFadeDurationMs': 8000,
        });
        final explicitDefault = Session.fromJson({
          ...base,
          'trackFadeDurationOverrides': const {'0': 4000},
        });
        expect(changedDefault, isNot(session));
        expect(explicitDefault, isNot(session));
        expect({session, changedDefault, explicitDefault}, hasLength(3));
        final forward = Session.fromJson({
          ...base,
          'trackFadeDurationOverrides': const {'0': 4000, '7': 8000},
        });
        final reversed = Session.fromJson({
          ...base,
          'trackFadeDurationOverrides': const {'7': 8000, '0': 4000},
        });
        expect(forward, reversed);
        expect(forward.hashCode, reversed.hashCode);
        expect({forward, reversed}, hasLength(1));
      },
    );

    test('requires exact Fade fields and preserves Custom membership', () {
      final json = session.toJson()
        ..['defaultFadeDurationMs'] = 8000
        ..['trackFadeDurationOverrides'] = {'0': 8000, '7': 500};
      final decoded = Session.fromJson(json);
      expect(decoded.defaultFadeDurationMs, 8000);
      expect(decoded.trackFadeDurationOverrides, {0: 8000, 7: 500});
      expect(
        Session.fromJson(decoded.toJson()).trackFadeDurationOverrides,
        decoded.trackFadeDurationOverrides,
      );
      for (final field in [
        'defaultFadeDurationMs',
        'trackFadeDurationOverrides',
      ]) {
        expect(
          () => Session.fromJson({...json}..remove(field)),
          throwsFormatException,
        );
      }
      for (final invalid in [0, 499, 501, 30001, 500.0, '500']) {
        expect(
          () => Session.fromJson({...json, 'defaultFadeDurationMs': invalid}),
          throwsFormatException,
        );
        expect(
          () => Session.fromJson({
            ...json,
            'trackFadeDurationOverrides': {'0': invalid},
          }),
          throwsFormatException,
        );
      }
      for (final key in ['8', '-1', '00']) {
        expect(
          () => Session.fromJson({
            ...json,
            'trackFadeDurationOverrides': {key: 500},
          }),
          throwsFormatException,
        );
      }
      expect(
        () => Session.fromJson({...json, 'version': 11}),
        throwsA(isA<SessionUnsupportedVersion>()),
      );
    });

    test('serializes the manifest version (v15) and the grid in beats', () {
      final json = session.toJson();
      expect(json['version'], Session.formatVersion);
      expect(json['version'], 15);
      // Constructed with bars only, the beats are the bars' (#1168).
      expect(json['loopBeats'], session.loopBars * session.tsNum);
      expect(json['baseLengthFrames'], 96000);
    });

    group('backing (schema 15, #1200)', () {
      const a = SessionBackingItem(
        digest:
            'sha256:00112233445566778899aabbccddeeff'
            '00112233445566778899aabbccddeeff',
        name: 'Evening lights.wav',
      );
      const b = SessionBackingItem(
        digest:
            'sha256:ffeeddccbbaa99887766554433221100'
            'ffeeddccbbaa99887766554433221100',
        name: 'Count-in.mp3',
      );
      const backing = SessionBacking(
        prepared: [a, b],
        loaded: b,
        endMode: BackingEnd.next,
        level: 0.5,
        pan: -0.25,
        outputMask: 0xC,
      );
      final withBacking = Session.fromJson({
        ...session.toJson(),
        'backing': backing.toJson(),
        'clickPan': 0.75,
      });

      test('round-trips every field, a loaded item outside the list too', () {
        expect(withBacking.backing, backing);
        expect(withBacking.clickPan, 0.75);
        const outside = SessionBacking(prepared: [a], loaded: b);
        expect(
          Session.fromJson({
            ...session.toJson(),
            'backing': jsonDecode(jsonEncode(outside.toJson())),
          }).backing,
          outside,
        );
        expect(
          Session.fromJson(
            jsonDecode(jsonEncode(withBacking.toJson()))
                as Map<String, dynamic>,
          ),
          withBacking,
        );
      });

      test('the default is an empty, silent backing and a centred click', () {
        final json = session.toJson();
        expect(json['backing'], {
          'prepared': <Object>[],
          'loaded': null,
          'endMode': 'stop',
          'level': 1.0,
          'pan': 0.0,
          'outputMask': 0,
        });
        expect(json['clickPan'], 0.0);
      });

      test('the current schema refuses a missing backing or click pan', () {
        final json = withBacking.toJson()..remove('backing');
        expect(() => Session.fromJson(json), throwsFormatException);
        final noPan = withBacking.toJson()..remove('clickPan');
        expect(() => Session.fromJson(noPan), throwsFormatException);
      });

      test('refuses malformed items and values', () {
        Map<String, dynamic> with_(Map<String, dynamic> edit) => {
          ...withBacking.toJson(),
          'backing': {...backing.toJson(), ...edit},
        };
        for (final bad in <Map<String, dynamic>>[
          {
            'prepared': [
              {'digest': 'sha256:1234', 'name': 'x.wav'},
            ],
          },
          {
            'prepared': [
              {'digest': a.digest.toUpperCase(), 'name': 'x.wav'},
            ],
          },
          {
            'prepared': [
              {'digest': a.digest, 'name': ' '},
            ],
          },
          {
            'prepared': [
              {'digest': a.digest, 'name': 'x.wav', 'extra': 1},
            ],
          },
          {
            'prepared': [a.toJson(), a.toJson()],
          },
          {'loaded': 'sha256:00'},
          {'endMode': 'shuffle'},
          {'level': 2.5},
          {'level': -0.1},
          {'pan': 1.5},
          {'outputMask': -1},
          {'outputMask': 0.5},
          {'surprise': true},
        ]) {
          expect(
            () => Session.fromJson(with_(bad)),
            throwsFormatException,
            reason: '$bad',
          );
        }
        for (final pan in <Object>[1.01, -2, 'centre']) {
          expect(
            () => Session.fromJson({...withBacking.toJson(), 'clickPan': pan}),
            throwsFormatException,
            reason: '$pan',
          );
        }
      });
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

    group('monitor volume', () {
      for (final value in [-0.1, 1.01, double.nan, double.infinity]) {
        test('refuses invalid saved gain $value', () {
          final json = const SessionMonitor(
            input: 0,
            mode: 'on',
            outputMask: 3,
            volume: 1,
            muted: false,
            encoded: '[]',
          ).toJson()..['volume'] = value;
          expect(() => SessionMonitor.fromJson(json), throwsFormatException);
        });
      }
      for (final value in [0.0, 0.5, 1.0]) {
        test('round-trips accepted gain $value', () {
          final monitor = SessionMonitor(
            input: 0,
            mode: 'on',
            outputMask: 3,
            volume: value,
            muted: false,
            encoded: '[]',
          );
          expect(SessionMonitor.fromJson(monitor.toJson()), monitor);
        });
      }
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

    test('rejects malformed and duplicate output destinations', () {
      for (final bus in [-1, 16, 0.5, '1']) {
        final json = session.toJson()
          ..['outputChains'] = [
            {'bus': bus, 'encoded': ''},
          ];
        expect(() => Session.fromJson(json), throwsFormatException);
      }
      final json = session.toJson()
        ..['outputChains'] = [
          {'bus': 1, 'encoded': ''},
          {'bus': 1, 'encoded': ''},
        ];
      expect(() => Session.fromJson(json), throwsFormatException);
    });

    test('serializes the bus stages (Track + outputs)', () {
      final json = session.toJson();
      expect(json['trackChains'], [
        {
          'channel': 0,
          'encoded': '{"chainEnabled":false,"entries":[{"t":3}]}',
        },
        {'channel': 1, 'encoded': '{"chainEnabled":true,"entries":[]}'},
      ]);
      expect(json['outputChains'], [
        {
          'bus': 0,
          'encoded': '{"chainEnabled":true,"entries":[{"t":9}]}',
        },
      ]);
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
      expect(loaded.outputChains.single.bus, 0);
      expect(
        loaded.outputChains.single.encoded,
        '{"chainEnabled":true,"entries":[{"t":9}]}',
      );
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
        'history': <Object>[],
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
        'fadeAmount': 1,
        'reversed': false,
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
        history: TrackHistory([
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.layer),
        ], undoCount: 2),
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

    /// Track 0's lane maps in [json]: both lanes share one history, so a
    /// history edit applies to each.
    List<Map<String, dynamic>> track0Lanes(Map<String, dynamic> json) => [
      for (final lane
          in ((json['tracks'] as List).first as Map<String, dynamic>)['lanes']
              as List)
        lane as Map<String, dynamic>,
    ];

    /// Gives every lane of track 0 [history] (`{kind, skipped}` maps) with
    /// [undoCount] entries on the undo side and [layers] image files.
    Map<String, dynamic> withHistory(
      List<Map<String, Object>> history, {
      required int undoCount,
      required int layers,
    }) {
      final json = session.toJson();
      for (final lane in track0Lanes(json)) {
        lane
          ..['history'] = history
          ..['undoCount'] = undoCount
          ..['redoCount'] = history.length - undoCount
          ..['layers'] = [
            for (var i = 0; i < layers; i++) {'file': 'x$i.wav'},
          ];
      }
      return json;
    }

    test('rejects a lane whose layer count disagrees with its history', () {
      // Two undo entries + live name 3 images but the lane lists 1.
      final json = session.toJson();
      track0Lanes(json).first
        ..['history'] = [
          {'kind': 'layer', 'skipped': 0},
          {'kind': 'layer', 'skipped': 0},
        ]
        ..['undoCount'] = 2
        ..['redoCount'] = 0;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionCorruptLayers>()),
      );
    });

    test('rejects a lane claiming more layers than the pool cap', () {
      final json = withHistory(
        [
          for (var i = 0; i < SessionLane.maxLayers; i++)
            {'kind': 'layer', 'skipped': 0},
        ],
        undoCount: SessionLane.maxLayers,
        layers: SessionLane.maxLayers + 1,
      );
      expect(
        () => Session.fromJson(json),
        throwsA(
          isA<SessionCorruptLayers>().having(
            (e) => e.reason,
            'reason',
            contains('cap'),
          ),
        ),
      );
    });

    test('rejects a lane with a negative undo/redo count', () {
      final json = withHistory(const [], undoCount: 0, layers: 1);
      track0Lanes(json).first
        ..['undoCount'] = -1
        ..['redoCount'] = 1;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<SessionCorruptLayers>()),
      );
    });

    test('accepts a lane at exactly the pool cap', () {
      final json = withHistory(
        [
          for (var i = 0; i < SessionLane.maxLayers - 1; i++)
            {'kind': 'layer', 'skipped': 0},
        ],
        undoCount: SessionLane.maxLayers - 1,
        layers: SessionLane.maxLayers,
      );
      final loaded = Session.fromJson(json);
      expect(loaded.tracks.first.lanes.first.layers, hasLength(256));
    });

    group('history (#1164)', () {
      // Undo side: a restoration, an overdub and a Peel above it. Redo side:
      // the marker of an undone Peel (it re-peels the overdub), a layer, and
      // the Clear point as the deepest entry, so 3 + 1 + 2 images.
      const peelHistory = [
        {'kind': 'processed', 'skipped': 0},
        {'kind': 'layer', 'skipped': 0},
        {'kind': 'peel', 'skipped': 0},
        {'kind': 'peel', 'skipped': 1},
        {'kind': 'layer', 'skipped': 0},
        {'kind': 'clear', 'skipped': 0},
      ];

      test('round-trips every kind, skipped counts and redo markers', () {
        final json = withHistory(peelHistory, undoCount: 3, layers: 6);
        final lane = Session.fromJson(json).tracks.first.lanes.first;
        expect(lane.history.entries, const [
          HistoryEntry(HistoryKind.processed),
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.peel),
          HistoryEntry(HistoryKind.peel, skipped: 1),
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.clear),
        ]);
        expect(lane.undoCount, 3);
        expect(lane.redoCount, 3);
        final again = Session.fromJson(
          jsonDecode(jsonEncode(Session.fromJson(json).toJson()))
              as Map<String, dynamic>,
        );
        expect(again, Session.fromJson(json));
        expect(
          track0Lanes(Session.fromJson(json).toJson()).first['history'],
          peelHistory,
        );
      });

      test('round-trips length edits with their playhead maps (#1168)', () {
        const lengthHistory = [
          {'kind': 'length', 'skipped': 0, 'start': 0},
          {'kind': 'layer', 'skipped': 0},
          {'kind': 'length', 'skipped': 0, 'start': -96000},
        ];
        final json = withHistory(lengthHistory, undoCount: 2, layers: 4);
        final lane = Session.fromJson(json).tracks.first.lanes.first;
        expect(lane.history.entries, const [
          HistoryEntry(HistoryKind.length),
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.length, start: -96000),
        ]);
        // A length edit always writes its map, even zero; others never do.
        expect(
          track0Lanes(Session.fromJson(json).toJson()).first['history'],
          lengthHistory,
        );
      });

      test('a redo marker takes no image; an undo Peel takes one', () {
        // Treating the marker as an image (7 layers) is as corrupt as
        // dropping the undo Peel's image (5).
        for (final layers in [5, 7]) {
          expect(
            () => Session.fromJson(
              withHistory(peelHistory, undoCount: 3, layers: layers),
            ),
            throwsA(isA<SessionCorruptLayers>()),
          );
        }
      });

      test('rejects malformed entries before anything else', () {
        for (final entry in <Object>[
          {'kind': 'overdub', 'skipped': 0},
          {'kind': 'layer'},
          {'kind': 'layer', 'skipped': 0.5},
          {'kind': 1, 'skipped': 0},
          {'kind': 'layer', 'skipped': 0, 'slot': 3},
          {'kind': 'length', 'skipped': 0, 'start': 0.5},
          {'kind': 'length', 'skipped': 0, 'start': 0, 'slot': 3},
          'layer',
        ]) {
          final json = withHistory(
            [
              {'kind': 'layer', 'skipped': 0},
            ],
            undoCount: 1,
            layers: 2,
          );
          for (final lane in track0Lanes(json)) {
            lane['history'] = [entry];
          }
          expect(() => Session.fromJson(json), throwsFormatException);
        }
        final missing = session.toJson();
        track0Lanes(missing).first.remove('history');
        expect(() => Session.fromJson(missing), throwsFormatException);
      });

      test('rejects entries the engine could not rebuild', () {
        final cases = <(List<Map<String, Object>>, int, int)>[
          // A Clear point beneath the live image.
          (
            [
              {'kind': 'clear', 'skipped': 0},
            ],
            1,
            2,
          ),
          // A playhead map on a kind that has none (#1168).
          (
            [
              {'kind': 'layer', 'skipped': 0, 'start': 4},
            ],
            1,
            2,
          ),
          // A skipped count on a kind that has none, and a negative one.
          (
            [
              {'kind': 'layer', 'skipped': 1},
            ],
            1,
            2,
          ),
          (
            [
              {'kind': 'peel', 'skipped': -1},
            ],
            1,
            2,
          ),
        ];
        for (final (history, undoCount, layers) in cases) {
          expect(
            () => Session.fromJson(
              withHistory(history, undoCount: undoCount, layers: layers),
            ),
            throwsA(isA<SessionCorruptLayers>()),
          );
        }
        // Counts that disagree with the entries.
        final json = withHistory(peelHistory, undoCount: 3, layers: 6);
        track0Lanes(json).first['redoCount'] = 2;
        expect(
          () => Session.fromJson(json),
          throwsA(isA<SessionCorruptLayers>()),
        );
      });

      /// Expects the history to be refused with a reason containing [reason].
      void expectRefused(
        List<Map<String, Object>> history, {
        required int undoCount,
        required int layers,
        required String reason,
      }) {
        expect(
          () => Session.fromJson(
            withHistory(history, undoCount: undoCount, layers: layers),
          ),
          throwsA(
            isA<SessionCorruptLayers>().having(
              (e) => e.reason,
              'reason',
              contains(reason),
            ),
          ),
        );
      }

      test('refuses a Clear point that is not the deepest Redo entry', () {
        // Clear drops the Redo branch, so nothing can sit beneath it: a Redo
        // of this Clear would discard the layer below.
        expectRefused(
          const [
            {'kind': 'layer', 'skipped': 0},
            {'kind': 'clear', 'skipped': 0},
            {'kind': 'layer', 'skipped': 0},
          ],
          undoCount: 1,
          layers: 4,
          reason: 'not the deepest',
        );
        expectRefused(
          const [
            {'kind': 'clear', 'skipped': 0},
            {'kind': 'clear', 'skipped': 0},
          ],
          undoCount: 0,
          layers: 3,
          reason: 'not the deepest',
        );
      });

      test('refuses a Redo marker with nothing to peel', () {
        // A restoration on top blocks Peel, and an empty Undo side has
        // nothing beneath the original: Redo would refuse forever and strand
        // the layer below the marker.
        expectRefused(
          const [
            {'kind': 'processed', 'skipped': 0},
            {'kind': 'peel', 'skipped': 0},
            {'kind': 'layer', 'skipped': 0},
          ],
          undoCount: 1,
          layers: 3,
          reason: 'no layer to peel',
        );
        expectRefused(
          const [
            {'kind': 'peel', 'skipped': 0},
          ],
          undoCount: 0,
          layers: 1,
          reason: 'no layer to peel',
        );
        // A marker reached after an earlier Redo re-files a layer is fine.
        final json = withHistory(
          const [
            {'kind': 'processed', 'skipped': 0},
            {'kind': 'layer', 'skipped': 0},
            {'kind': 'peel', 'skipped': 0},
          ],
          undoCount: 1,
          layers: 3,
        );
        expect(Session.fromJson(json).tracks.first.lanes.first.redoCount, 2);
      });

      test('refuses an oversized skipped count', () {
        // Only an overdub sits beneath the Peel, yet it claims to have
        // skipped one Peel entry: Undo would re-insert out of order.
        expectRefused(
          const [
            {'kind': 'layer', 'skipped': 0},
            {'kind': 'layer', 'skipped': 0},
            {'kind': 'peel', 'skipped': 1},
          ],
          undoCount: 3,
          layers: 4,
          reason: 'only 0 sit beneath',
        );
        // No stack holds that many entries.
        expectRefused(
          const [
            {'kind': 'peel', 'skipped': 256},
          ],
          undoCount: 1,
          layers: 2,
          reason: 'invalid skipped count 256',
        );
        // Pool eviction removes the oldest entries, so a run of Peel entries
        // that reaches the bottom may be shorter than a skipped count.
        final evicted = withHistory(
          const [
            {'kind': 'peel', 'skipped': 0},
            {'kind': 'peel', 'skipped': 3},
          ],
          undoCount: 2,
          layers: 3,
        );
        expect(Session.fromJson(evicted).tracks.first.lanes.first.undoCount, 2);
      });

      test('rejects lanes of one track with different histories', () {
        final json = withHistory(
          [
            {'kind': 'layer', 'skipped': 0},
          ],
          undoCount: 1,
          layers: 2,
        );
        track0Lanes(json).last['history'] = [
          {'kind': 'processed', 'skipped': 0},
        ];
        expect(
          () => Session.fromJson(json),
          throwsA(
            isA<SessionCorruptLayers>().having((e) => e.lane, 'lane', 1),
          ),
        );
      });
    });
  });

  group('forNewLoop', () {
    test('drops the tracks, the grid, the crown and the name, and keeps '
        'every other field', () {
      final source = Session.fromJson({
        ...session.toJson(),
        'name': 'Evening loop',
        'loopBars': 4,
        'loopBeats': 24,
        'primaryTrack': 0,
        'tempoBpm': 96,
        'tempoSource': 'manual',
        'countInBars': 2,
        'pedalBindings': 'remap',
      });

      final json = source.toJson()
        ..remove('name')
        ..['tracks'] = <Object?>[]
        ..['baseLengthFrames'] = 0
        ..['loopBars'] = 0
        ..['loopBeats'] = 0
        ..['primaryTrack'] = -1;
      expect(jsonEncode(source.forNewLoop().toJson()), jsonEncode(json));
    });
  });
}
