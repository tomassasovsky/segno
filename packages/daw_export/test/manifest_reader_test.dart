import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

/// Writes a minimal `events.log` fixture — see
/// `event_log_reader_test.dart`'s own copy of this helper for the exact
/// on-disk layout this mirrors; duplicated here (not shared) since test
/// helpers in this package are kept file-local by convention.
void _writeLog(
  String path,
  int sampleRate,
  List<(int frame, int code, List<int> payload)> entries,
) {
  final out = BytesBuilder()..add('PLEV'.codeUnits);
  final version = ByteData(4)..setUint32(0, 17, Endian.little);
  out.add(version.buffer.asUint8List());
  final sr = ByteData(4)..setInt32(0, sampleRate, Endian.little);
  out.add(sr.buffer.asUint8List());

  for (final (frame, code, payload) in entries) {
    final header = ByteData(12)
      ..setUint64(0, frame, Endian.little)
      ..setInt32(8, code, Endian.little);
    out.add(header.buffer.asUint8List());
    final padded = List<int>.filled(16, 0);
    for (var i = 0; i < payload.length && i < 16; i++) {
      padded[i] = payload[i];
    }
    out.add(padded);
  }

  File(path).writeAsBytesSync(out.toBytes());
}

/// A mono 32-bit float WAV of [frames] silent frames at [sampleRate], as
/// `engine_wav.c` writes stems and loops.
Uint8List _wav(int frames, {int sampleRate = 48000}) {
  final header = ByteData(44)
    ..setUint32(0, 0x46464952, Endian.little) // RIFF
    ..setUint32(4, 36 + frames * 4, Endian.little)
    ..setUint32(8, 0x45564157, Endian.little) // WAVE
    ..setUint32(12, 0x20746d66, Endian.little) // fmt
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 3, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 4, Endian.little)
    ..setUint16(32, 4, Endian.little)
    ..setUint16(34, 32, Endian.little)
    ..setUint32(36, 0x61746164, Endian.little) // data
    ..setUint32(40, frames * 4, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(Uint8List(frames * 4)))
      .toBytes();
}

/// Writes a lane stem of [frames] frames for each of [lanes] (channel,
/// lane), as the renderer does (#1824), and `stems/stems.json` listing them;
/// [kinds] picks the dry and wet stems.
void _writeStems(
  String dir,
  List<(int channel, int lane)> lanes, {
  Set<String> kinds = const {'dry', 'wet'},
  int frames = 48000,
}) {
  final listed = <Map<String, dynamic>>[];
  for (final (channel, lane) in lanes) {
    final entry = <String, dynamic>{'channel': channel, 'lane': lane};
    for (final kind in kinds) {
      final file = 'stems/$kind/track$channel-lane$lane.wav';
      (File(
        '$dir/$file',
      )..parent.createSync(recursive: true)).writeAsBytesSync(_wav(frames));
      entry[kind] = file;
    }
    listed.add(entry);
  }
  File('$dir/stems/stems.json')
      .writeAsStringSync(jsonEncode({'version': 1, 'lanes': listed}));
}

List<int> _generic(int argI, double argF) {
  final b = ByteData(16)
    ..setInt32(0, argI, Endian.little)
    ..setFloat32(4, argF, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  _layoutTests();
  group('DawManifestReader.read', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_manifest_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    void manifest(
      Map<String, dynamic> armTrack, {
      int frames = 48000,
      List<Map<String, dynamic>> trackChains = const [],
    }) => File('${dir.path}/performance.json').writeAsStringSync(
      jsonEncode({
        'sample_rate': 48000,
        'capture_frames': frames,
        'armSnapshot': {
          'trackChains': trackChains,
          'tracks': [armTrack],
        },
        'disarmSnapshot': {'tracks': <dynamic>[]},
        'layers': <dynamic>[],
      }),
    );

    test('returns null when performance.json is missing', () {
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test('returns null when performance.json is corrupt', () {
      File('${dir.path}/performance.json').writeAsStringSync('{not json');
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test('a looper track is a Group of its lanes (#1824): each lane plays its '
        'dry stem, with its wet stem beside it, switched off', () {
      _writeStems(dir.path, [(0, 0), (0, 1)]);
      Directory('${dir.path}/loops').createSync();
      for (final name in [
        'track0-lane0',
        'track0-lane1',
        'track0-lane1-heard',
      ]) {
        File('${dir.path}/loops/$name.wav').writeAsBytesSync(_wav(24000));
      }
      manifest(
        {
          'channel': 0,
          'name': 'Rhythm',
          'lanes': [
            {'lane': 0, 'deferred': false, 'pcmRef': 'loops/track0-lane0.wav'},
            {
              'lane': 1,
              'deferred': false,
              'pcmRef': 'loops/track0-lane1.wav',
              'heardPcmRef': 'loops/track0-lane1-heard.wav',
              'effects': [
                {'type': 3, 'params': <double>[]},
              ],
            },
          ],
        },
        trackChains: [
          {
            'channel': 1,
            'effects': [
              {'type': 7, 'params': <double>[]},
            ],
          },
          {
            'channel': 0,
            'effects': [
              {'type': 10, 'params': <double>[]},
            ],
          },
        ],
      );

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(
        [for (final t in tracks) (t.name, t.kind, t.active)],
        [
          ('Rhythm L1', DawTrackKind.lane, true),
          ('Rhythm L1 (as heard)', DawTrackKind.laneHeard, false),
          ('Rhythm L2', DawTrackKind.lane, true),
          ('Rhythm L2 (as heard)', DawTrackKind.laneHeard, false),
        ],
      );
      final group = tracks.first.group!;
      expect(tracks.map((t) => t.group), everyElement(same(group)));
      expect(group.name, 'Rhythm');
      // The Group stands for the Track stage the lanes sum into.
      expect(group.info, 'Effects when the take started:\nCompressor');
      expect(
        [for (final t in tracks) t.arrangementClips.single.audio.fileRef],
        [
          'stems/dry/track0-lane0.wav',
          'stems/wet/track0-lane0.wav',
          'stems/dry/track0-lane1.wav',
          'stems/wet/track0-lane1.wav',
        ],
      );
      expect(tracks.first.arrangementClips.single.audio.seconds, 1.0);
      // Each lane's loop: clean on the lane, as it played on the reference.
      expect(
        [for (final t in tracks) t.loop!.fileRef],
        [
          'loops/track0-lane0.wav',
          'loops/track0-lane0.wav',
          'loops/track0-lane1.wav',
          'loops/track0-lane1-heard.wav',
        ],
      );
      expect(tracks.first.loop!.seconds, 0.5);
      expect(
        [for (final t in tracks) t.info],
        [
          'No effects were recorded when the take started.',
          'No effects were recorded when the take started.',
          'Effects when the take started:\nDelay',
          'Effects when the take started:\nDelay',
        ],
      );
    });

    test('a lane with only a wet stem plays it', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'wet'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});

      final track = DawManifestReader.read(dir.path)!.tracks.single;
      expect(
        (track.name, track.kind, track.active),
        ('Track 1 L1 (as heard)', DawTrackKind.laneHeard, true),
      );
    });

    test('a lane with only a dry stem has no reference beside it', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});

      final track = DawManifestReader.read(dir.path)!.tracks.single;
      expect((track.name, track.kind), ('Track 1 L1', DawTrackKind.lane));
      expect(
        track.arrangementClips.single.audio.fileRef,
        'stems/dry/track0-lane0.wav',
      );
    });

    test('a lane with loops but no rendered stems is one track holding its '
        'loop, and no Arrangement clip', () {
      Directory('${dir.path}/loops').createSync(recursive: true);
      File('${dir.path}/loops/track0-lane0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/loops/track0-lane1.wav').writeAsBytesSync(_wav(48000));
      manifest({
        'channel': 0,
        'lanes': [
          {'lane': 0, 'deferred': false, 'pcmRef': 'loops/track0-lane0.wav'},
          {'lane': 1, 'deferred': false, 'pcmRef': 'loops/track0-lane1.wav'},
        ],
      });

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(tracks.map((t) => t.name), ['Track 1 L1', 'Track 1 L2']);
      for (final t in tracks) {
        expect(t.arrangementClips, isEmpty);
        expect(t.loop!.seconds, 1.0);
        expect(t.active, isTrue);
      }
    });

    test('a stem index that does not read, or lists nothing usable, gives no '
        'stems', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0-lane0.wav')
          .writeAsBytesSync(_wav(48000));
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      final index = File('${dir.path}/stems/stems.json');
      for (final text in [
        '{not json',
        '[1]',
        '{"lanes": 3}',
        '{"lanes": [1, {"channel": 0}, {"channel": 0, "lane": "a"}]}',
      ]) {
        index.writeAsStringSync(text);
        expect(DawManifestReader.read(dir.path)!.tracks, isEmpty, reason: text);
      }
      // A listed lane whose stems are missing, or named by something other
      // than a string, has nothing to play.
      index.writeAsStringSync(
        '{"lanes": [{"channel": 0, "lane": 0, "dry": 3, '
        '"wet": "stems/wet/track0-lane0.wav"}]}',
      );
      expect(DawManifestReader.read(dir.path)!.tracks, isEmpty);
    });

    group('clip lengths', () {
      Map<String, dynamic> lane(int index, String ref, [int? lenFrames]) => {
        'lane': index,
        'deferred': false,
        'pcmRef': ref,
        'lenFrames': ?lenFrames,
      };

      setUp(() {
        Directory('${dir.path}/loops').createSync();
        _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      });

      test('a stem and a loop take their rate and length from their own '
          'WAV headers', () {
        File('${dir.path}/stems/dry/track0-lane0.wav')
            .writeAsBytesSync(_wav(96000 * 3, sampleRate: 96000));
        File('${dir.path}/loops/a.wav')
            .writeAsBytesSync(_wav(96000, sampleRate: 96000));
        manifest({
          'channel': 0,
          'lanes': [lane(0, 'loops/a.wav', 12345)],
        }, frames: 48000 * 4);

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        final stem = track.arrangementClips.single.audio;
        expect((stem.sampleRate, stem.frames), (96000, 96000 * 3));
        expect(track.arrangementClips.single.startSeconds, 0);
        expect((track.loop!.sampleRate, track.loop!.frames), (96000, 96000));
      });

      test('a file whose header does not read falls back to the manifest: '
          "the capture's length for a stem, the lane's for a loop", () {
        File('${dir.path}/stems/dry/track0-lane0.wav').writeAsBytesSync([1, 2]);
        File('${dir.path}/loops/a.wav').writeAsBytesSync([1, 2]);
        manifest({
          'channel': 0,
          'lanes': [lane(0, 'loops/a.wav', 24000)],
        }, frames: 48000 * 4);

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        expect(track.arrangementClips.single.audio.frames, 48000 * 4);
        expect(track.arrangementClips.single.audio.sampleRate, 48000);
        expect(track.loop!.frames, 24000);
      });

      test('a loop that does not read and has no lane length is left out', () {
        File('${dir.path}/loops/a.wav').writeAsBytesSync([1, 2]);
        manifest({
          'channel': 0,
          'lanes': [lane(0, 'loops/a.wav')],
        });

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        expect(track.loop, isNull);
        expect(track.arrangementClips, hasLength(1));
      });
    });

    test("a lane's volume starts from the arm-time track gain times its level "
        'times its audibility: a lane muted at arm holds silent through a '
        'volume change, and each lane follows its own level', () {
      _writeStems(dir.path, [(0, 0), (0, 1)], kinds: {'dry'});
      manifest({
        'channel': 0,
        'volume': 0.5,
        'lanes': [
          {'lane': 0, 'volume': 0.8, 'muted': true, 'deferred': false},
          {'lane': 1, 'volume': 0.25},
        ],
      });
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (24000, codeSetVolume, _generic(0, 1)),
      ]);

      final [lane0, lane1] = DawManifestReader.read(dir.path)!.tracks;
      expect(lane0.volume!.initialValue, 0);
      expect(lane0.volume!.breakpoints.single.beat, 1);
      expect(lane0.volume!.breakpoints.single.value, 0);
      expect(lane1.volume!.initialValue, 0.125);
      expect(lane1.volume!.breakpoints.single.value, 0.25);
    });

    group('arm-time state on a lane', () {
      void armed(Map<String, dynamic> track, {int lanes = 1}) {
        _writeStems(
          dir.path,
          [for (var l = 0; l < lanes; l++) (0, l)],
          kinds: {'dry'},
        );
        manifest({'channel': 0, ...track});
        // A log with no gesture for channel 0.
        _writeLog('${dir.path}/events.log', 48000, const []);
      }

      test('a gain other than unity at arm gets a volume lane with no '
          'gestures, since the dry stem is at unity', () {
        armed({
          'volume': 0.5,
          'lanes': [
            {'lane': 0, 'deferred': false},
          ],
        });
        final lane = DawManifestReader.read(dir.path)!.tracks.single.volume!;
        expect(lane.initialValue, 0.5);
        expect(lane.breakpoints.single.beat, 0);
        expect(lane.breakpoints.single.value, 0.5);
      });

      test("lane 0's mute flag wins over the track's, as the renderer reads "
          'it', () {
        armed({
          'muted': true,
          'lanes': [
            {'lane': 0, 'muted': false, 'deferred': false},
          ],
        });
        expect(DawManifestReader.read(dir.path)!.tracks.single.volume, isNull);
      });

      test("the track's mute applies to lane 0 when lane 0 has no flag, or "
          'is not listed, and to no other lane', () {
        armed({
          'muted': true,
          'lanes': [
            {'lane': 0, 'deferred': false},
            {'lane': 1, 'deferred': false},
          ],
        }, lanes: 2);
        final [lane0, lane1] = DawManifestReader.read(dir.path)!.tracks;
        expect(lane0.volume!.initialValue, 0);
        expect(lane0.volume!.breakpoints.single.value, 0);
        expect(lane1.volume, isNull);

        armed({
          'muted': true,
          'lanes': [
            {'lane': 1, 'deferred': false},
            {'deferred': false},
          ],
        }, lanes: 2);
        final [unlisted, other] = DawManifestReader.read(dir.path)!.tracks;
        expect(unlisted.volume!.initialValue, 0);
        expect(other.volume, isNull);
      });
    });

    test('reads a lane pcmRef verbatim rather than reconstructing a '
        'conventional filename', () {
      Directory('${dir.path}/captured').createSync(recursive: true);
      File('${dir.path}/captured/unconventional-name.wav')
          .writeAsBytesSync(_wav(48000));
      manifest({
        'channel': 0,
        'lanes': [
          {
            'lane': 0,
            'deferred': false,
            'pcmRef': 'captured/unconventional-name.wav',
          },
          {'deferred': false, 'pcmRef': 'captured/no-lane.wav'},
        ],
      });

      expect(
        DawManifestReader.read(dir.path)!.tracks.single.loop!.fileRef,
        'captured/unconventional-name.wav',
      );
    });

    for (final (name, source, heardOnDisk) in [
      ('a lane that played clean', 'clean', true),
      ('a missing heard image', null, false),
    ]) {
      test('$name keeps its clean loop on its reference too (#1713)', () {
        _writeStems(dir.path, [(0, 0)]);
        Directory('${dir.path}/loops').createSync(recursive: true);
        File('${dir.path}/loops/track0-lane0.wav')
            .writeAsBytesSync(_wav(48000));
        if (heardOnDisk) {
          File('${dir.path}/loops/track0-lane0-heard.wav')
              .writeAsBytesSync(_wav(48000));
        }
        manifest({
          'channel': 0,
          'lanes': [
            {
              'lane': 0,
              'deferred': false,
              'pcmRef': 'loops/track0-lane0.wav',
              'heardPcmRef': 'loops/track0-lane0-heard.wav',
              'source': ?source,
            },
          ],
        });

        final [_, heard] = DawManifestReader.read(dir.path)!.tracks;
        expect(heard.loop!.fileRef, 'loops/track0-lane0.wav');
      });
    }

    test(
      'prefers a disarm-time pcmRef over an arm-time one for the same lane',
      () {
        Directory('${dir.path}/loops').createSync(recursive: true);
        File('${dir.path}/loops/stale.wav').writeAsBytesSync(_wav(48000));
        File('${dir.path}/loops/fresh.wav').writeAsBytesSync(_wav(48000));
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'loops/stale.wav'},
                  ],
                },
              ],
            },
            'disarmSnapshot': {
              'tracks': [
                {
                  'lanes': [
                    {'lane': 0, 'pcmRef': 'loops/none.wav'},
                  ],
                },
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'loops/fresh.wav'},
                  ],
                },
              ],
            },
            'layers': <dynamic>[],
          }),
        );

        expect(
          DawManifestReader.read(dir.path)!.tracks.single.loop!.fileRef,
          'loops/fresh.wav',
        );
      },
    );

    test('excludes a channel with no stem and no lane exports', () {
      manifest({
        'channel': 0,
        'lanes': [
          {'lane': 0, 'deferred': true},
        ],
      });

      expect(DawManifestReader.read(dir.path)!.tracks, isEmpty);
    });

    test('builds a volume automation lane from events.log for a lane that '
        'also has an arrangement clip', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0.5)),
        (48000, codeSetVolume, _generic(0, 0.9)),
      ]);

      final lane = DawManifestReader.read(dir.path)!.tracks.single.volume!;
      expect(lane.breakpoints, hasLength(2));
      expect(lane.breakpoints.first.beat, 0.0);
      expect(lane.breakpoints.first.value, closeTo(0.5, 1e-6));
      expect(lane.breakpoints.last.beat, 2.0); // 1s at 120bpm
      expect(lane.breakpoints.last.value, closeTo(0.9, 1e-6));
    });

    test('a mute is a step to silence in the volume and back, two '
        'breakpoints at each toggle', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      const codeSetMute = 8;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetMute, _generic(0, 1)), // muted
        (48000, codeSetMute, _generic(0, 0)), // unmuted
      ]);

      final lane = DawManifestReader.read(dir.path)!.tracks.single.volume!;
      expect(lane.initialValue, 1);
      expect(
        [for (final b in lane.breakpoints) (b.beat, b.value)],
        [
          (0.0, 1.0),
          (0.0, 0.0), // muted
          (2.0, 0.0),
          (2.0, 1.0), // unmuted
        ],
      );
    });

    test("seeds audibility from the arm snapshot's muted/solo flags: a track "
        "muted at arm stays silent through another track's solo, and a track "
        'soloed at arm silences the rest until that solo clears', () {
      _writeStems(dir.path, [(0, 0), (1, 0), (2, 0)], kinds: {'dry'});
      Map<String, dynamic> track(
        int channel, {
        bool muted = false,
        bool solo = false,
      }) => {
        'channel': channel,
        'muted': muted,
        'solo': solo,
        'lanes': [
          {'lane': 0, 'deferred': false},
        ],
      };
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 96000,
          'armSnapshot': {
            'tracks': [
              track(0),
              track(1, muted: true),
              track(2, solo: true),
              {'name': 'no channel'},
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetTrackSolo = 63;
      _writeLog('${dir.path}/events.log', 48000, [
        (48000, codeSetTrackSolo, _generic(2, 0)), // solo cleared at 1s
      ]);

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(tracks, hasLength(3));

      // Track 0: silenced by track 2's solo from arm (off at the start),
      // audible once it clears.
      final lane0 = tracks[0].volume!;
      expect(lane0.initialValue, 0);
      expect(
        [for (final b in lane0.breakpoints) (b.beat, b.value)],
        [(2.0, 0.0), (2.0, 1.0)],
      );
      // Track 1: muted at arm, silent from the start; the solo clear changes
      // nothing, so its one breakpoint holds it silent.
      final lane1 = tracks[1].volume!;
      expect(lane1.initialValue, 0);
      expect(lane1.breakpoints.single.beat, 0);
      expect(lane1.breakpoints.single.value, 0);
      // Track 2: the soloed track itself was audible throughout.
      expect(tracks[2].volume, isNull);
    });

    test('a wet stem gets no volume or activator automation: the wet render '
        'already applies those gestures', () {
      _writeStems(dir.path, [(0, 0)]);
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0.5)),
        (48000, codeSetVolume, _generic(0, 0.9)),
      ]);

      final [dry, wet] = DawManifestReader.read(dir.path)!.tracks;
      expect(dry.volume, isNotNull);
      expect(wet.volume, isNull);
    });

    test('threads a real, explicit tempoBpm through to the returned DawProject '
        '(and into beat-unit automation conversion)', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0.5)),
        (48000, codeSetVolume, _generic(0, 0.9)),
      ]);

      final project = DawManifestReader.read(dir.path, tempoBpm: 140);
      expect(project!.tempoBpm, 140.0);
      // At 140 BPM, 1s == 140/60 beats — distinct from the 120-BPM 2.0
      // beats the earlier test at the same frame offset asserts, proving
      // this reader's own internal beat-time conversion (not just the
      // returned DawProject.tempoBpm) uses the real tempo too.
      final lane = project.tracks.single.volume!;
      expect(lane.breakpoints.last.beat, closeTo(140 / 60, 1e-9));
    });

    test('a non-positive tempoBpm (a legacy v3 session, or v4 grid-off content '
        "reporting Session.tempoBpm's 0 = unset) falls back to 120 BPM, same "
        'as omitting the argument entirely', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {'tracks': <dynamic>[]},
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      expect(DawManifestReader.read(dir.path)!.tempoBpm, 120.0);
      expect(DawManifestReader.read(dir.path, tempoBpm: 0)!.tempoBpm, 120.0);
      expect(DawManifestReader.read(dir.path, tempoBpm: -1)!.tempoBpm, 120.0);
    });

    test("the manifest's own persisted tempo beats the caller's (#281): "
        'disarmSnapshot.tempoBpm is authoritative, armSnapshot.tempoBpm is '
        'the crash-salvage fallback', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          // Arm-over-empty-grid at 96, tempo dialed in to 132 before the
          // first loop: only the disarm-time read saw D6's lock engage.
          'armSnapshot': {'tempoBpm': 96.0, 'tracks': <dynamic>[]},
          'disarmSnapshot': {'tempoBpm': 132.0, 'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      // The caller's live tempo (140) never reaches the export — by
      // re-export time it may have long moved on from this take's.
      expect(DawManifestReader.read(dir.path, tempoBpm: 140)!.tempoBpm, 132.0);
      expect(DawManifestReader.read(dir.path)!.tempoBpm, 132.0);
    });

    test('a crash-salvaged manifest (no disarmSnapshot) falls back to the '
        'arm-time tempo (#281)', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {'tempoBpm': 96.0, 'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      expect(DawManifestReader.read(dir.path, tempoBpm: 140)!.tempoBpm, 96.0);
    });

    test('a manifest with no tempo evidence — snapshots absent, pre-#281 '
        'bundles without the key, or the 0-as-unset sentinel — falls through '
        'to the caller tempo, then 120 (#281)', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          // 0 = unset, stored verbatim by performance_repository: no
          // tempo was ever locked, so it must NOT shadow the fallbacks.
          'armSnapshot': {'tempoBpm': 0.0, 'tracks': <dynamic>[]},
          'disarmSnapshot': {'tempoBpm': 0.0, 'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      expect(DawManifestReader.read(dir.path, tempoBpm: 140)!.tempoBpm, 140.0);
      expect(DawManifestReader.read(dir.path)!.tempoBpm, 120.0);
    });

    test('returns null when performance.json is well-formed JSON but not an '
        'object — never a TypeError escaping to callers guarding only I/O', () {
      File('${dir.path}/performance.json').writeAsStringSync('[1, 2, 3]');
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test('a lane with no logged gestures gets no automation lanes', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      manifest({'channel': 0, 'lanes': <dynamic>[]});
      // No events.log at all.
      expect(DawManifestReader.read(dir.path)!.tracks.single.volume, isNull);
    });
  });
}

void _layoutTests() {
  group('DawManifestReader.read layout (#1799)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('daw_layout_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String file, int frames) => (File(
      '${dir.path}/$file',
    )..parent.createSync(recursive: true)).writeAsBytesSync(_wav(frames));

    void manifest(Map<String, dynamic> fields) =>
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000 * 3,
            'channel_layout': {
              'master_channels': 2,
              'captured_inputs': [1, 0],
            },
            ...fields,
          }),
        );

    test('names the tracks and inputs the player named, and numbers the '
        'rest from 1', () {
      _writeStems(dir.path, [(0, 0), (2, 0)], kinds: {'dry'});
      write('input-0-001.wav', 48000);
      write('input-1-001.wav', 48000);
      manifest({
        'armSnapshot': {
          'tracks': [
            {'channel': 0, 'name': 'Rhythm', 'lanes': <dynamic>[]},
            {'channel': 2, 'lanes': <dynamic>[]},
          ],
          'inputs': [
            {'input': 1, 'name': 'Vocal'},
          ],
        },
        'parts': [
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav', 'frames': 1},
          {'stream': 2, 'index': 1, 'file': 'input-1-001.wav', 'frames': 1},
        ],
      });

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(tracks.map((t) => t.kind), [
        DawTrackKind.lane,
        DawTrackKind.lane,
        DawTrackKind.input,
        DawTrackKind.input,
      ]);
      expect(tracks.map((t) => t.name), [
        'Rhythm L1',
        'Track 3 L1',
        'Input 1',
        'Vocal',
      ]);
      expect(tracks.map((t) => t.group?.name), [
        'Rhythm',
        'Track 3',
        null,
        null,
      ]);
      expect(tracks.map((t) => t.active), everyElement(isTrue));
    });

    test('an input and the master hold their parts end to end, the master '
        'last and switched off', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      write('master-001.wav', 48000 * 2);
      write('master-002.wav', 48000);
      write('input-0-001.wav', 48000 * 2);
      write('input-0-002.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
        },
        'armSnapshot': {
          'tracks': [
            {'channel': 0, 'lanes': <dynamic>[]},
          ],
        },
        'parts': [
          {'stream': 1, 'index': 2, 'file': 'input-0-002.wav', 'frames': 48000},
          {'stream': 0, 'index': 2, 'file': 'master-002.wav', 'frames': 48000},
          {'stream': 0, 'index': 1, 'file': 'master-001.wav', 'frames': 96000},
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav', 'frames': 96000},
        ],
      });

      final [_, input, master] = DawManifestReader.read(dir.path)!.tracks;
      expect(input.active, isTrue);
      expect(master.active, isFalse);
      for (final (track, prefix) in [(input, 'input-0'), (master, 'master')]) {
        expect(track.loop, isNull);
        expect(track.group, isNull);
        expect(track.volume, isNull);
        expect(
          [
            for (final c in track.arrangementClips)
              (c.audio.fileRef, c.startSeconds),
          ],
          [('$prefix-001.wav', 0.0), ('$prefix-002.wav', 2.0)],
        );
      }
      expect(master.name, 'Master (as heard)');
    });

    test('each input recorded raw (#1805) plays its raw recording, named '
        '"<input> raw", with the input as heard beside it, switched off', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      write('input-0-001.wav', 48000);
      write('input-1-001.wav', 48000);
      write('input-raw-0-001.wav', 48000 * 2);
      write('input-raw-0-002.wav', 48000);
      write('input-raw-1-001.wav', 48000);
      write('master-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [1, 0],
          'raw_inputs': [1, 0],
        },
        'armSnapshot': {
          'tracks': [
            {'channel': 0, 'name': 'Rhythm', 'lanes': <dynamic>[]},
          ],
          'inputs': [
            {'input': 1, 'name': 'Vocal'},
          ],
          'monitors': [
            {
              'input': 0,
              'effects': [
                {'type': 14, 'params': <double>[]},
              ],
            },
          ],
        },
        'parts': [
          {'stream': 0, 'index': 1, 'file': 'master-001.wav', 'frames': 1},
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav', 'frames': 1},
          {'stream': 2, 'index': 1, 'file': 'input-1-001.wav', 'frames': 1},
          {'stream': 100, 'index': 2, 'file': 'input-raw-0-002.wav'},
          {'stream': 100, 'index': 1, 'file': 'input-raw-0-001.wav'},
          {'stream': 101, 'index': 1, 'file': 'input-raw-1-001.wav'},
        ],
      });

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(
        [for (final t in tracks) (t.name, t.kind, t.active)],
        [
          ('Rhythm L1', DawTrackKind.lane, true),
          ('Input 1 raw', DawTrackKind.input, true),
          ('Input 1 (as heard)', DawTrackKind.inputHeard, false),
          ('Vocal raw', DawTrackKind.input, true),
          ('Vocal (as heard)', DawTrackKind.inputHeard, false),
          ('Master (as heard)', DawTrackKind.master, false),
        ],
      );
      expect(
        [
          for (final c in tracks[1].arrangementClips)
            (c.audio.fileRef, c.startSeconds),
        ],
        [('input-raw-0-001.wav', 0.0), ('input-raw-0-002.wav', 2.0)],
      );
      expect(
        tracks[2].arrangementClips.single.audio.fileRef,
        'input-0-001.wav',
      );
      expect(
        tracks[3].arrangementClips.single.audio.fileRef,
        'input-raw-1-001.wav',
      );
      expect(
        tracks[4].arrangementClips.single.audio.fileRef,
        'input-1-001.wav',
      );
      expect(
        tracks[1].info,
        [
          'The input as played: before its effects, volume and pan.',
          'Effects when the take started:',
          'Chorus',
        ].join('\n'),
      );
      expect(
        tracks[2].info,
        [
          'The input as heard: after its effects, volume and pan.',
          'Effects when the take started:',
          'Chorus',
        ].join('\n'),
      );
      for (final t in tracks.skip(1)) {
        expect(t.loop, isNull);
        expect(t.volume, isNull);
      }
    });

    test('an input listed raw whose raw parts are missing keeps the input as '
        'heard, playing', () {
      write('input-0-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
          'raw_inputs': [0],
        },
        'parts': [
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav', 'frames': 1},
          {'stream': 100, 'index': 1, 'file': 'input-raw-0-001.wav'},
        ],
      });

      final input = DawManifestReader.read(dir.path)!.tracks.single;
      expect(
        (input.name, input.kind, input.active),
        ('Input 1', DawTrackKind.input, true),
      );
      expect(input.arrangementClips.single.audio.fileRef, 'input-0-001.wav');
    });

    test('an input recorded raw only, never monitored, gets its raw track '
        'alone', () {
      write('input-raw-1-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': <int>[],
          'raw_inputs': [1],
        },
        'parts': [
          {'stream': 101, 'index': 1, 'file': 'input-raw-1-001.wav'},
        ],
      });

      final input = DawManifestReader.read(dir.path)!.tracks.single;
      expect(
        (input.name, input.kind, input.active),
        ('Input 2 raw', DawTrackKind.input, true),
      );
    });

    test('an instrument recorded raw (#1805) is named as an instrument', () {
      write('input-raw-33-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': <int>[],
          'raw_inputs': [33],
        },
        'parts': [
          {'stream': 133, 'index': 1, 'file': 'input-raw-33-001.wav'},
        ],
      });

      final track = DawManifestReader.read(dir.path)!.tracks.single;
      expect(track.name, 'Instrument 2 raw');
    });

    test('an input whose parts as heard are missing keeps its raw track '
        'alone', () {
      write('input-raw-0-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
          'raw_inputs': [0],
        },
        'parts': [
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav'},
          {'stream': 100, 'index': 1, 'file': 'input-raw-0-001.wav'},
        ],
      });

      final input = DawManifestReader.read(dir.path)!.tracks.single;
      expect((input.name, input.active), ('Input 1 raw', true));
    });

    test('a missing part leaves its gap instead of moving the next one '
        'up', () {
      write('master-002.wav', 48000);
      manifest({
        'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
        'parts': [
          {'stream': 0, 'index': 1, 'file': 'master-001.wav', 'frames': 96000},
          {'stream': 0, 'index': 2, 'file': 'master-002.wav', 'frames': 48000},
        ],
      });

      final master = DawManifestReader.read(dir.path)!.tracks.single;
      expect(master.arrangementClips.single.audio.fileRef, 'master-002.wav');
      expect(master.arrangementClips.single.startSeconds, 2);
    });

    test('a missing part of unknown length ends its stream there, since '
        'nothing after it could be placed', () {
      write('master-001.wav', 48000);
      write('master-003.wav', 48000);
      manifest({
        'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
        'parts': [
          {'stream': 0, 'index': 1, 'file': 'master-001.wav', 'frames': 48000},
          {'stream': 0, 'index': 2, 'file': 'master-002.wav'},
          {'stream': 0, 'index': 3, 'file': 'master-003.wav', 'frames': 48000},
        ],
      });

      final master = DawManifestReader.read(dir.path)!.tracks.single;
      expect(master.kind, DawTrackKind.master);
      expect(master.arrangementClips.map((c) => c.audio.fileRef), [
        'master-001.wav',
      ]);
    });

    test('a take from before the parts format reads master.wav and '
        'live-input-<n>.wav', () {
      write('master.wav', 48000);
      write('live-input-0.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0, 1],
        },
      });

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      expect(tracks.map((t) => t.name), ['Input 1', 'Master (as heard)']);
      expect(tracks.map((t) => t.arrangementClips.single.audio.fileRef), [
        'live-input-0.wav',
        'master.wav',
      ]);
    });

    test('each track tells the effects it started with, or that there were '
        'none', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'});
      write('input-0-001.wav', 48000);
      write('master-001.wav', 48000);
      manifest({
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
        },
        'armSnapshot': {
          'tracks': [
            {'channel': 0, 'lanes': <dynamic>[]},
          ],
          'monitors': [
            {
              'input': 0,
              'effects': [
                {'type': 14, 'params': <double>[]},
              ],
            },
          ],
        },
        'parts': [
          {'stream': 0, 'index': 1, 'file': 'master-001.wav', 'frames': 1},
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav', 'frames': 1},
        ],
      });

      final tracks = DawManifestReader.read(dir.path)!.tracks;
      const inputInfo =
          'The input as heard: after its effects, volume and pan.\n'
          'Effects when the take started:\nChorus';
      expect(tracks.map((t) => t.info), [
        'No effects were recorded when the take started.',
        inputInfo,
        'No effects were recorded when the take started.',
      ]);
    });

    test("a mute in the middle of a volume ramp steps from the ramp's value "
        'there', () {
      _writeStems(dir.path, [(0, 0)], kinds: {'dry'}, frames: 48000 * 3);
      manifest({
        'channel_layout': {'master_channels': 2, 'captured_inputs': <int>[]},
        'armSnapshot': {
          'tracks': [
            {'channel': 0, 'lanes': <dynamic>[]},
          ],
        },
      });
      const codeSetVolume = 7;
      const codeSetMute = 8;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0)),
        (96000, codeSetVolume, _generic(0, 1)),
        (48000, codeSetMute, _generic(0, 1)),
      ]);

      final lane = DawManifestReader.read(dir.path)!.tracks.single.volume!;
      expect(
        [for (final b in lane.breakpoints) (b.beat, b.value)],
        [
          (0.0, 0.0),
          (2.0, 0.5), // halfway up the ramp, when the mute lands
          (2.0, 0.0),
          (4.0, 0.0), // the ramp's end, silent
        ],
      );
    });
  });
}
