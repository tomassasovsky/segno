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
  final version = ByteData(4)..setUint32(0, 1, Endian.little);
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

List<int> _generic(int argI, double argF) {
  final b = ByteData(16)
    ..setInt32(0, argI, Endian.little)
    ..setFloat32(4, argF, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  group('DawManifestReader.read', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('daw_export_manifest_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('returns null when performance.json is missing', () {
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test('returns null when performance.json is corrupt', () {
      File('${dir.path}/performance.json').writeAsStringSync('{not json');
      expect(DawManifestReader.read(dir.path), isNull);
    });

    test(
      'builds one track with an arrangement clip from a wet stem, preferring '
      'it over dry',
      () {
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
        Directory('${dir.path}/stems/dry').createSync(recursive: true);
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync(_wav(48000));
        File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {'lane': 0, 'deferred': false, 'pcmRef': 'ignored.wav'},
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path);
        expect(project, isNotNull);
        expect(project!.tracks, hasLength(1));
        expect(
          project.tracks.single.arrangementClip!.audio.fileRef,
          'stems/wet/track0.wav',
        );
        expect(project.tracks.single.arrangementClip!.audio.seconds, 1.0);
      },
    );

    test('falls back to a dry stem when no wet stem exists', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {'channel': 0, 'lanes': <dynamic>[]},
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      expect(
        project!.tracks.single.arrangementClip!.audio.fileRef,
        'stems/dry/track0.wav',
      );
    });

    test('includes one session clip per lane that has a loop export, and no '
        'arrangement clip when no channel-level stem exists', () {
      Directory('${dir.path}/loops').createSync(recursive: true);
      File('${dir.path}/loops/track0-lane0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/loops/track0-lane1.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'loops/track0-lane0.wav',
                  },
                  {
                    'lane': 1,
                    'deferred': false,
                    'pcmRef': 'loops/track0-lane1.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      final track = project!.tracks.single;
      expect(track.sessionClips, hasLength(2));
      // The only behavior unique to this fixture (no stems/wet or
      // stems/dry file for channel 0 at all) is that the track has no
      // arrangement clip — asserted explicitly rather than left to
      // whatever `sessionClips` happens to check.
      expect(track.arrangementClip, isNull);
      // A loop is as long as its own file.
      expect(track.sessionClips.first.audio.seconds, 1.0);
    });

    group('clip lengths', () {
      void manifest(List<Map<String, dynamic>> lanes) =>
          File('${dir.path}/performance.json').writeAsStringSync(
            jsonEncode({
              'sample_rate': 48000,
              'capture_frames': 48000 * 4,
              'armSnapshot': {
                'tracks': [
                  {'channel': 0, 'lanes': lanes},
                ],
              },
              'disarmSnapshot': {'tracks': <dynamic>[]},
              'layers': <dynamic>[],
            }),
          );

      Map<String, dynamic> lane(int index, String ref, [int? lenFrames]) => {
        'lane': index,
        'deferred': false,
        'pcmRef': ref,
        'lenFrames': ?lenFrames,
      };

      setUp(() {
        Directory('${dir.path}/loops').createSync();
        Directory('${dir.path}/stems/wet').createSync(recursive: true);
      });

      test('a stem and a loop take their rate and length from their own '
          'WAV headers', () {
        File('${dir.path}/stems/wet/track0.wav')
            .writeAsBytesSync(_wav(96000 * 3, sampleRate: 96000));
        File('${dir.path}/loops/a.wav')
            .writeAsBytesSync(_wav(96000, sampleRate: 96000));
        manifest([lane(0, 'loops/a.wav', 12345)]);

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        final stem = track.arrangementClip!.audio;
        expect((stem.sampleRate, stem.frames), (96000, 96000 * 3));
        expect(track.arrangementClip!.startSeconds, 0);
        final loop = track.sessionClips.single.audio;
        expect((loop.sampleRate, loop.frames), (96000, 96000));
      });

      test('a file whose header does not read falls back to the manifest: '
          "the capture's length for a stem, the lane's for a loop", () {
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync([1, 2]);
        File('${dir.path}/loops/a.wav').writeAsBytesSync([1, 2]);
        manifest([lane(0, 'loops/a.wav', 24000)]);

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        expect(track.arrangementClip!.audio.frames, 48000 * 4);
        expect(track.arrangementClip!.audio.sampleRate, 48000);
        expect(track.sessionClips.single.audio.frames, 24000);
      });

      test('a loop that does not read and has no lane length is left out', () {
        File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync(_wav(10));
        File('${dir.path}/loops/a.wav').writeAsBytesSync([1, 2]);
        manifest([lane(0, 'loops/a.wav')]);

        final track = DawManifestReader.read(dir.path)!.tracks.single;
        expect(track.sessionClips, isEmpty);
        expect(track.arrangementClip, isNotNull);
      });
    });

    test("a dry clip's volume lane starts from the arm-time track gain "
        "times lane 0's level, and lane 0's mute silences it from the "
        'start', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'volume': 0.5,
                'lanes': [
                  {'lane': 0, 'volume': 0.8, 'muted': true, 'deferred': false},
                  {'lane': 1, 'volume': 0.1},
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (24000, codeSetVolume, _generic(0, 1)),
      ]);

      final lanes = DawManifestReader.read(dir.path)!
          .tracks
          .single
          .automationLanes;
      final volume = lanes.firstWhere(
        (l) => l.target == AutomationTarget.volume,
      );
      expect(volume.initialValue, closeTo(0.4, 1e-9));
      expect(volume.breakpoints.single.value, closeTo(0.8, 1e-6));
      final activator = lanes.firstWhere(
        (l) => l.target == AutomationTarget.activator,
      );
      expect(activator.initialValue, 0);
    });

    test('reads a lane pcmRef verbatim rather than reconstructing a '
        'conventional filename', () {
      Directory('${dir.path}/captured').createSync(recursive: true);
      File('${dir.path}/captured/unconventional-name.wav')
          .writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'captured/unconventional-name.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      expect(
        project!.tracks.single.sessionClips.single.audio.fileRef,
        'captured/unconventional-name.wav',
      );
    });

    test(
      "a take's session clip is its heard image where it has one (#1713)",
      () {
        Directory('${dir.path}/loops').createSync(recursive: true);
        for (final name in [
          'track0-lane0',
          'track0-lane0-heard',
          'track1-lane0',
        ]) {
          File('${dir.path}/loops/$name.wav').writeAsBytesSync(_wav(48000));
        }
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
                  'channel': 0,
                  'lanes': [
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'loops/track0-lane0.wav',
                      'heardPcmRef': 'loops/track0-lane0-heard.wav',
                    },
                  ],
                },
                {
                  'channel': 1,
                  'lanes': [
                    {
                      'lane': 0,
                      'deferred': false,
                      'pcmRef': 'loops/track1-lane0.wav',
                    },
                  ],
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        final project = DawManifestReader.read(dir.path)!;
        expect(
          [for (final t in project.tracks) t.sessionClips.single.audio.fileRef],
          ['loops/track0-lane0-heard.wav', 'loops/track1-lane0.wav'],
        );
      },
    );

    for (final (name, source, heardOnDisk) in [
      ('a lane that played clean', 'clean', true),
      ('a missing heard image', null, false),
    ]) {
      test('$name keeps its clean loop as its session clip (#1713)', () {
        Directory('${dir.path}/loops').createSync(recursive: true);
        File('${dir.path}/loops/track0-lane0.wav')
            .writeAsBytesSync(_wav(48000));
        if (heardOnDisk) {
          File('${dir.path}/loops/track0-lane0-heard.wav')
              .writeAsBytesSync(_wav(48000));
        }
        File('${dir.path}/performance.json').writeAsStringSync(
          jsonEncode({
            'sample_rate': 48000,
            'capture_frames': 48000,
            'armSnapshot': {
              'tracks': [
                {
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
                },
              ],
            },
            'disarmSnapshot': {'tracks': <dynamic>[]},
            'layers': <dynamic>[],
          }),
        );

        expect(
          DawManifestReader.read(dir.path)!
              .tracks
              .single
              .sessionClips
              .single
              .audio
              .fileRef,
          'loops/track0-lane0.wav',
        );
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

        final project = DawManifestReader.read(dir.path);
        expect(
          project!.tracks.single.sessionClips.single.audio.fileRef,
          'loops/fresh.wav',
        );
      },
    );

    test('excludes a channel with no arrangement stem and no lane exports', () {
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {'lane': 0, 'deferred': true},
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      expect(project!.tracks, isEmpty);
    });

    test('builds a volume automation lane from events.log for a track that '
        'also has an arrangement clip', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/dry/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0.5)),
        (48000, codeSetVolume, _generic(0, 0.9)),
      ]);

      final project = DawManifestReader.read(dir.path);
      final lanes = project!.tracks.single.automationLanes;
      expect(lanes, hasLength(1));
      expect(lanes.single.target, AutomationTarget.volume);
      expect(lanes.single.breakpoints, hasLength(2));
      expect(lanes.single.breakpoints.first.beat, 0.0);
      expect(lanes.single.breakpoints.last.beat, 2.0); // 1s at 120bpm
    });

    test('builds an activator (mute) automation lane from events.log, '
        'independent of whether a volume lane exists', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/dry/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetMute = 8;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetMute, _generic(0, 1)), // muted
        (48000, codeSetMute, _generic(0, 0)), // unmuted
      ]);

      final project = DawManifestReader.read(dir.path);
      final lanes = project!.tracks.single.automationLanes;
      expect(lanes, hasLength(1));
      expect(lanes.single.target, AutomationTarget.activator);
      expect(lanes.single.breakpoints, hasLength(2));
      expect(lanes.single.breakpoints.first.value, 0.0); // muted -> off
      expect(lanes.single.breakpoints.last.value, 1.0); // unmuted -> on
    });

    test("seeds the activator lane from the arm snapshot's muted/solo flags: "
        "a track muted at arm stays off through another track's solo, and a "
        'track soloed at arm silences the rest until that solo clears', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      for (final channel in [0, 1, 2]) {
        File('${dir.path}/stems/dry/track$channel.wav')
            .writeAsBytesSync(_wav(48000));
      }
      Map<String, dynamic> track(
        int channel, {
        bool muted = false,
        bool solo = false,
      }) => {
        'channel': channel,
        'muted': muted,
        'solo': solo,
        'lanes': [
          {
            'lane': 0,
            'deferred': false,
            'pcmRef': 'stems/dry/track$channel.wav',
          },
        ],
      };
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 96000,
          'armSnapshot': {
            'tracks': [track(0), track(1, muted: true), track(2, solo: true)],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetTrackSolo = 63;
      _writeLog('${dir.path}/events.log', 48000, [
        (48000, codeSetTrackSolo, _generic(2, 0)), // solo cleared at 1s
      ]);

      final project = DawManifestReader.read(dir.path);
      final tracks = project!.tracks;
      expect(tracks, hasLength(3));

      // Track 0: silenced by track 2's solo from arm (off at the start),
      // audible once it clears.
      final lane0 = tracks[0].automationLanes.single;
      expect(lane0.target, AutomationTarget.activator);
      expect(lane0.initialValue, 0);
      expect(lane0.breakpoints.single.beat, 2.0);
      expect(lane0.breakpoints.single.value, 1.0);
      // Track 1: muted at arm, off from the start; the solo clear changes
      // nothing, so its one breakpoint holds it off.
      final lane1 = tracks[1].automationLanes.single;
      expect(lane1.initialValue, 0);
      expect(lane1.breakpoints.single.beat, 0);
      expect(lane1.breakpoints.single.value, 0);
      // Track 2: the soloed track itself was audible throughout.
      expect(tracks[2].automationLanes, isEmpty);
    });

    test('a wet arrangement clip gets no volume or activator automation: the '
        'wet render already applies those gestures', () {
      Directory('${dir.path}/stems/wet').createSync(recursive: true);
      File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/wet/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      const codeSetVolume = 7;
      _writeLog('${dir.path}/events.log', 48000, [
        (0, codeSetVolume, _generic(0, 0.5)),
        (48000, codeSetVolume, _generic(0, 0.9)),
      ]);

      final track = DawManifestReader.read(dir.path)!.tracks.single;
      expect(track.arrangementClip!.audio.fileRef, 'stems/wet/track0.wav');
      expect(track.automationLanes, isEmpty);
    });

    test('a channel with an effects chain still exports the wet stem: the '
        'effects reach Live only as audio', () {
      Directory('${dir.path}/stems/wet').createSync(recursive: true);
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/wet/track0.wav',
                    'effects': [
                      {
                        'type': 3,
                        'params': [0.35, 0.35, 0.35, 0.0],
                      },
                    ],
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );

      final project = DawManifestReader.read(dir.path);
      final track = project!.tracks.single;
      expect(track.arrangementClip!.audio.fileRef, 'stems/wet/track0.wav');
    });

    test('threads a real, explicit tempoBpm through to the returned DawProject '
        '(and into beat-unit automation conversion)', () {
      Directory('${dir.path}/stems/dry').createSync(recursive: true);
      File('${dir.path}/stems/dry/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/dry/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
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
      final lanes = project.tracks.single.automationLanes;
      expect(lanes.single.breakpoints.last.beat, closeTo(140 / 60, 1e-9));
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

    test('a track with no logged gestures gets no automation lanes', () {
      Directory('${dir.path}/stems/wet').createSync(recursive: true);
      File('${dir.path}/stems/wet/track0.wav').writeAsBytesSync(_wav(48000));
      File('${dir.path}/performance.json').writeAsStringSync(
        jsonEncode({
          'sample_rate': 48000,
          'capture_frames': 48000,
          'armSnapshot': {
            'tracks': [
              {
                'channel': 0,
                'lanes': [
                  {
                    'lane': 0,
                    'deferred': false,
                    'pcmRef': 'stems/wet/track0.wav',
                  },
                ],
              },
            ],
          },
          'disarmSnapshot': {'tracks': <dynamic>[]},
          'layers': <dynamic>[],
        }),
      );
      // No events.log at all.
      final project = DawManifestReader.read(dir.path);
      expect(project!.tracks.single.automationLanes, isEmpty);
    });
  });
}
