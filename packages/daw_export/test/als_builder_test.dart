import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:daw_export/src/live_set_template.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

XmlDocument _decode(List<int> als) =>
    XmlDocument.parse(utf8.decode(gzip.decode(als)));

/// A reference set Live saved (`test/corpus/README.md`).
XmlDocument _corpus(String name) =>
    _decode(File('test/corpus/$name.als').readAsBytesSync());

XmlElement _liveSet(XmlDocument d) => d.rootElement.getElement('LiveSet')!;

List<XmlElement> _audioTracks(XmlDocument d) =>
    _liveSet(d).getElement('Tracks')!.findElements('AudioTrack').toList();

XmlElement _at(XmlElement e, String path) {
  var node = e;
  for (final name in path.split('/')) {
    node = node.getElement(name)!;
  }
  return node;
}

String _value(XmlElement e, String path) => _at(e, path).getAttribute('Value')!;

double _number(XmlElement e, String path) => double.parse(_value(e, path));

/// The elements Live writes in a `FileRef` only for a file it has read or
/// one from a pack: they describe a particular file, so the builder leaves
/// them out and Live adds them on its next save.
const _perFileRefFields = {
  'LivePackName',
  'LivePackId',
  'OriginalFileSize',
  'OriginalCrc',
};

/// Every distinct element path under [root] with its attribute names: the
/// shape of what Live wrote, without values or repetition.
Set<String> _shape(XmlElement root) {
  final paths = <String>{};
  void walk(XmlElement e, String prefix) {
    if (_perFileRefFields.contains(e.name.local)) return;
    final attributes = e.attributes.map((a) => a.name.local).toList()..sort();
    final path = '$prefix/${e.name.local}';
    paths.add('$path[${attributes.join(',')}]');
    for (final child in e.childElements) {
      walk(child, path);
    }
  }

  walk(root, '');
  return paths;
}

bool _isPointee(String name) =>
    name == 'AutomationTarget' ||
    name == 'Pointee' ||
    name.endsWith('ModulationTarget') ||
    name.startsWith('ControllerTargets.');

const _stem = DawAudioFile(
  fileRef: 'stems/wet/track0.wav',
  sampleRate: 48000,
  frames: 48000 * 10,
);

const _loop = DawAudioFile(
  fileRef: 'loops/track0-lane0.wav',
  sampleRate: 48000,
  frames: 48000 * 2,
);

/// A track with everything a capture can give it, as the template's track
/// holds it: an Arrangement clip, a Session clip and a volume envelope.
DawTrack _fullTrack(String name) => DawTrack(
  name: name,
  arrangementClips: const [DawClip(audio: _stem, startSeconds: 0)],
  sessionClips: const [DawSessionClip(laneIndex: 0, audio: _loop)],
  volume: const AutomationLane(
    initialValue: 1,
    breakpoints: [
      AutomationBreakpoint(beat: 2, value: 1),
      AutomationBreakpoint(beat: 4, value: 0.25),
    ],
  ),
);

/// [shape] without the activator envelope's events: the template track has
/// one, and the builder writes no activator automation.
Set<String> _withoutActivatorEvents(Set<String> shape) => {
  for (final path in shape)
    if (!path.contains('/BoolEvent[')) path,
};

XmlDocument _build(DawProject project) => _decode(buildAls(project));

void main() {
  group('the reference sets', () {
    test('the template is test/corpus/automation.als as Live saved it', () {
      final saved = utf8.decode(
        gzip.decode(File('test/corpus/automation.als').readAsBytesSync()),
      );
      expect(
        liveSetTemplate,
        saved,
        reason: 'run `dart run tool/generate_live_set_template.dart`',
      );
    });

    test('were all saved by the same Live version as the template', () {
      final template = XmlDocument.parse(liveSetTemplate).rootElement;
      for (final name in [
        'empty',
        'audio_clips',
        'tempo',
        'session_loop_warped',
        'vst3',
      ]) {
        final root = _corpus(name).rootElement;
        for (final attribute in ['MajorVersion', 'MinorVersion', 'Creator']) {
          expect(
            root.getAttribute(attribute),
            template.getAttribute(attribute),
            reason: '$name.als $attribute',
          );
        }
      }
    });
  });

  group('buildAls', () {
    test('writes gzipped XML under the root element Live wrote', () {
      final document = _build(DawProject(tracks: [_fullTrack('Track 0')]));
      final reference = _corpus('automation').rootElement;
      expect(document.rootElement.name.local, 'Ableton');
      for (final attribute in reference.attributes) {
        expect(
          document.rootElement.getAttribute(attribute.name.local),
          attribute.value,
        );
      }
      expect(
        _liveSet(document).childElements.map((e) => e.name.local).toList(),
        _liveSet(_corpus('automation')).childElements
            .map((e) => e.name.local)
            .toList(),
      );
    });

    test('an audio track has the shape of the one Live saved', () {
      final track = _audioTracks(
        _build(DawProject(tracks: [_fullTrack('Track 0')])),
      ).single;
      final reference = _audioTracks(_corpus('automation')).single;
      expect(_shape(track), _withoutActivatorEvents(_shape(reference)));
    });

    test('clips and envelopes have the shapes Live wrote', () {
      final track = _audioTracks(
        _build(DawProject(tracks: [_fullTrack('Track 0')])),
      ).single;
      final reference = _audioTracks(_corpus('automation')).single;
      Set<String> shapes(XmlElement t, String name) => {
        for (final e in t.findAllElements(name)) ..._shape(e),
      };
      for (final name in ['AudioClip', 'AutomationEnvelope', 'FloatEvent']) {
        expect(
          shapes(track, name),
          _withoutActivatorEvents(shapes(reference, name)),
          reason: name,
        );
        expect(shapes(track, name), isNotEmpty, reason: name);
      }
    });

    test('every list member has an Id wherever Live gives that element '
        'one', () {
      // Live refuses a set with "Not all list members have Ids" when, for
      // example, an automation event has none.
      String key(XmlElement e) =>
          '${e.parentElement?.name.local}/${e.name.local}';
      final withIds = <String>{};
      for (final name in ['empty', 'audio_clips', 'automation', 'tempo']) {
        for (final e in _corpus(name).descendantElements) {
          if (e.getAttribute('Id') != null) withIds.add(key(e));
        }
      }
      final document = _build(
        DawProject(tracks: [_fullTrack('Track 0'), _fullTrack('Track 1')]),
      );
      final missing = [
        for (final e in document.descendantElements)
          if (withIds.contains(key(e)) && e.getAttribute('Id') == null) key(e),
      ];
      expect(missing, isEmpty);
      expect(
        withIds,
        containsAll([
          'Events/FloatEvent',
          'Events/BoolEvent',
          'Events/AudioClip',
          'Value/AudioClip',
          'WarpMarkers/WarpMarker',
          'ClipSlotList/ClipSlot',
        ]),
      );
    });

    test('pointee ids are unique across the set and below NextPointeeId', () {
      final document = _build(
        DawProject(
          tracks: [for (var i = 0; i < 4; i++) _fullTrack('Track $i')],
        ),
      );
      final ids = [
        for (final e in document.descendantElements)
          if (_isPointee(e.name.local)) int.parse(e.getAttribute('Id')!),
      ];
      expect(ids.toSet(), hasLength(ids.length));
      final next = int.parse(_value(_liveSet(document), 'NextPointeeId'));
      expect(ids.every((id) => id < next), isTrue);
    });

    test('list-local ids are unique within their list, and track ids '
        'across the tracks', () {
      final document = _build(
        DawProject(
          tracks: [for (var i = 0; i < 3; i++) _fullTrack('Track $i')],
        ),
      );
      for (final parent in document.descendantElements) {
        final byName = <String, List<String>>{};
        for (final child in parent.childElements) {
          final id = child.getAttribute('Id');
          if (id == null || _isPointee(child.name.local)) continue;
          byName.putIfAbsent(child.name.local, () => []).add(id);
        }
        for (final MapEntry(:key, :value) in byName.entries) {
          expect(
            value.toSet(),
            hasLength(value.length),
            reason: '${parent.name.local}/$key',
          );
        }
      }
    });

    test("each envelope targets its own track's Volume", () {
      final tracks = _audioTracks(
        _build(
          DawProject(tracks: [_fullTrack('Track 0'), _fullTrack('Track 1')]),
        ),
      );
      for (final track in tracks) {
        final mixer = _at(track, 'DeviceChain/Mixer');
        String target(String parameter) =>
            _at(mixer, '$parameter/AutomationTarget').getAttribute('Id')!;
        final envelopes = _at(
          track,
          'AutomationEnvelopes/Envelopes',
        ).findElements('AutomationEnvelope').toList();
        expect(envelopes.map((e) => _value(e, 'EnvelopeTarget/PointeeId')), [
          target('Volume'),
        ]);
        expect(envelopes.map((e) => e.getAttribute('Id')), ['0']);
      }
    });

    test('names each track and its clips', () {
      final track = _audioTracks(
        _build(DawProject(tracks: [_fullTrack('Track 3')])),
      ).single;
      expect(_value(track, 'Name/EffectiveName'), 'Track 3');
      expect(_value(track, 'Name/UserName'), 'Track 3');
      expect(
        track.findAllElements('AudioClip').map((c) => _value(c, 'Name')),
        unorderedEquals(['Track 3', 'Track 3 / Lane 1']),
      );
    });

    test('escapes a name that is not plain text', () {
      const name = 'A & B <"x">';
      final track = _audioTracks(
        _build(const DawProject(tracks: [DawTrack(name: name)])),
      ).single;
      expect(_value(track, 'Name/EffectiveName'), name);
    });

    group('an Arrangement clip', () {
      XmlElement arrangementClip(XmlElement track) => _at(
        track,
        'DeviceChain/MainSequencer/Sample/ArrangerAutomation/Events',
      ).getElement('AudioClip')!;

      test('is unwarped: beats on the timeline, seconds in the file, as Live '
          'writes an unwarped clip', () {
        // Live's own unwarped clip: CurrentEnd - CurrentStart is the
        // file's length in beats, the loop markers its length in seconds.
        final reference = arrangementClip(
          _audioTracks(_corpus('tempo')).single,
        );
        final referenceTempo = _number(
          _liveSet(_corpus('tempo')),
          'MainTrack/DeviceChain/Mixer/Tempo/Manual',
        );
        expect(_value(reference, 'IsWarped'), 'false');
        expect(
          _number(reference, 'CurrentEnd') - _number(reference, 'CurrentStart'),
          closeTo(
            _number(reference, 'Loop/LoopEnd') * referenceTempo / 60,
            1e-6,
          ),
        );

        const tempo = 93.5;
        final clip = arrangementClip(
          _audioTracks(
            _build(
              const DawProject(
                tempoBpm: tempo,
                tracks: [
                  DawTrack(
                    name: 'Track 0',
                    arrangementClips: [DawClip(audio: _stem, startSeconds: 2)],
                  ),
                ],
              ),
            ),
          ).single,
        );
        const startBeats = 2 * tempo / 60;
        const lengthBeats = 10 * tempo / 60;
        expect(double.parse(clip.getAttribute('Time')!), startBeats);
        expect(_number(clip, 'CurrentStart'), startBeats);
        expect(
          _number(clip, 'CurrentEnd'),
          closeTo(startBeats + lengthBeats, 1e-9),
        );
        expect(_number(clip, 'Loop/LoopStart'), 0);
        expect(_number(clip, 'Loop/LoopEnd'), 10);
        expect(_number(clip, 'Loop/OutMarker'), 10);
        expect(_number(clip, 'Loop/HiddenLoopEnd'), 10);
        expect(_value(clip, 'Loop/LoopOn'), 'false');
        expect(_value(clip, 'IsWarped'), 'false');
        final markers = clip.getElement('WarpMarkers')!.childElements.toList();
        expect(markers.map((m) => m.getAttribute('SecTime')), ['0', '10']);
        expect(
          double.parse(markers.last.getAttribute('BeatTime')!),
          closeTo(lengthBeats, 1e-9),
        );
      });

      test('names its file relative to the set, the way Live writes a file '
          'beside the set', () {
        final clip = arrangementClip(
          _audioTracks(_build(DawProject(tracks: [_fullTrack('Track 0')])))
              .single,
        );
        final sample = clip.getElement('SampleRef')!;
        expect(_value(sample, 'FileRef/RelativePathType'), '1');
        expect(_value(sample, 'FileRef/RelativePath'), 'stems/wet/track0.wav');
        expect(_value(sample, 'FileRef/Path'), 'stems/wet/track0.wav');
        expect(_value(sample, 'FileRef/Type'), '2');
        expect(_value(sample, 'DefaultDuration'), '480000');
        expect(_value(sample, 'DefaultSampleRate'), '48000');
        // The type Live itself gave the reference set's file.
        final reference = arrangementClip(
          _audioTracks(_corpus('audio_clips')).single,
        );
        expect(_value(reference, 'SampleRef/FileRef/Type'), '2');
      });

      for (final path in ['/data/stem.wav', r'C:\stem.wav', r'\\host\a.wav']) {
        test('throws on the absolute path $path', () {
          expect(
            () => buildAls(
              DawProject(
                tracks: [
                  DawTrack(
                    name: 'Track 0',
                    arrangementClips: [
                      DawClip(
                        audio: DawAudioFile(
                          fileRef: path,
                          sampleRate: 48000,
                          frames: 48000,
                        ),
                        startSeconds: 0,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            throwsArgumentError,
          );
        });
      }
    });

    test('a Session clip loops its whole file, warped in Re-Pitch at the '
        "set's tempo", () {
      const tempo = 130.0;
      final track = _audioTracks(
        _build(
          const DawProject(
            tempoBpm: tempo,
            tracks: [
              DawTrack(
                name: 'Track 0',
                sessionClips: [DawSessionClip(laneIndex: 1, audio: _loop)],
              ),
            ],
          ),
        ),
      ).single;
      final slots = _at(
        track,
        'DeviceChain/MainSequencer/ClipSlotList',
      ).findElements('ClipSlot').toList();
      expect(_at(slots[0], 'ClipSlot/Value').childElements, isEmpty);
      final clip = _at(slots[1], 'ClipSlot/Value').getElement('AudioClip')!;
      const beats = 2 * tempo / 60;
      expect(_number(clip, 'CurrentStart'), 0);
      expect(_number(clip, 'CurrentEnd'), closeTo(beats, 1e-9));
      expect(_number(clip, 'Loop/LoopEnd'), closeTo(beats, 1e-9));
      expect(_value(clip, 'Loop/LoopOn'), 'true');
      expect(_value(clip, 'IsWarped'), 'true');
      expect(_value(clip, 'WarpMode'), '3');
      final markers = clip.getElement('WarpMarkers')!.childElements.toList();
      expect(markers.last.getAttribute('SecTime'), '2');
      expect(
        double.parse(markers.last.getAttribute('BeatTime')!),
        closeTo(beats, 1e-9),
      );
      // Nothing in the Arrangement for a track with only loops.
      expect(
        _at(
          track,
          'DeviceChain/MainSequencer/Sample/ArrangerAutomation/Events',
        ).childElements,
        isEmpty,
      );
    });

    test('a Session clip has the shape of the looping, warped one Live '
        'saved', () {
      XmlElement sessionClip(XmlElement track) => track
          .findAllElements('ClipSlotList')
          .first
          .findAllElements('AudioClip')
          .single;
      final reference = sessionClip(
        _audioTracks(_corpus('session_loop_warped')).single,
      );
      expect(_value(reference, 'IsWarped'), 'true');
      expect(_value(reference, 'Loop/LoopOn'), 'true');
      final clip = sessionClip(
        _audioTracks(
          _build(
            const DawProject(
              tracks: [
                DawTrack(
                  name: 'Track 0',
                  sessionClips: [DawSessionClip(laneIndex: 0, audio: _loop)],
                ),
              ],
            ),
          ),
        ).single,
      );
      expect(_shape(clip), _shape(reference));
    });

    test('every track has one clip slot per scene, and a lane past the '
        "template's scenes adds scenes", () {
      final templateScenes = _liveSet(_corpus('automation'))
          .getElement('Scenes')!
          .childElements
          .length;
      final lane = templateScenes + 2;
      final document = _build(
        DawProject(
          tracks: [
            DawTrack(
              name: 'Track 0',
              sessionClips: [DawSessionClip(laneIndex: lane, audio: _loop)],
            ),
            _fullTrack('Track 1'),
          ],
        ),
      );
      final scenes = _liveSet(document)
          .getElement('Scenes')!
          .findElements('Scene')
          .toList();
      expect(scenes, hasLength(lane + 1));
      expect(scenes.map((s) => s.getAttribute('Id')), [
        for (var i = 0; i <= lane; i++) '$i',
      ]);
      for (final track in _audioTracks(document)) {
        for (final sequencer in ['MainSequencer', 'FreezeSequencer']) {
          final slots = _at(
            track,
            'DeviceChain/$sequencer/ClipSlotList',
          ).findElements('ClipSlot');
          expect(slots, hasLength(lane + 1));
          expect(slots.map((s) => s.getAttribute('Id')), [
            for (var i = 0; i <= lane; i++) '$i',
          ]);
        }
      }
    });

    test('writes the tempo where Live keeps it: the main track and its '
        'tempo envelope', () {
      final reference = _liveSet(_corpus('tempo'));
      final tempo = _number(
        reference,
        'MainTrack/DeviceChain/Mixer/Tempo/Manual',
      );
      expect(tempo, isNot(120));
      final document = _build(
        DawProject(
          tracks: const [DawTrack(name: 'Track 0')],
          tempoBpm: tempo,
        ),
      );
      final mainTrack = _liveSet(document).getElement('MainTrack')!;
      expect(_number(mainTrack, 'DeviceChain/Mixer/Tempo/Manual'), tempo);
      final target = _at(
        mainTrack,
        'DeviceChain/Mixer/Tempo/AutomationTarget',
      ).getAttribute('Id');
      final envelope = _at(mainTrack, 'AutomationEnvelopes/Envelopes')
          .findElements('AutomationEnvelope')
          .singleWhere((e) => _value(e, 'EnvelopeTarget/PointeeId') == target);
      expect(
        envelope
            .findAllElements('FloatEvent')
            .map((e) => double.parse(e.getAttribute('Value')!)),
        everyElement(tempo),
      );
      // As in the set Live saved at that tempo.
      final referenceEvents = _at(
        reference,
        'MainTrack/AutomationEnvelopes/Envelopes',
      ).findAllElements('FloatEvent');
      expect(
        referenceEvents.map((e) => double.parse(e.getAttribute('Value')!)),
        everyElement(tempo),
      );
    });

    test('opens in the Arrangement, zoomed to fit the longest clip', () {
      final liveSet = _liveSet(
        _build(DawProject(tracks: [_fullTrack('Track 0')])),
      );
      expect(_value(liveSet, 'SelectedDocumentViewInMainWindow'), '0');
      // 10 s at 120 BPM is 20 beats over 500 pixels.
      expect(
        _number(liveSet, 'SequencerNavigator/BeatTimeHelper/CurrentZoom'),
        closeTo(20 / 500, 1e-12),
      );
    });

    test('throws for a project with no tracks, which Live cannot open', () {
      expect(() => buildAls(const DawProject(tracks: [])), throwsArgumentError);
    });

    test('a set with no Arrangement clip keeps the template zoom', () {
      final liveSet = _liveSet(
        _build(
          const DawProject(
            tracks: [
              DawTrack(
                name: 'Track 0',
                sessionClips: [DawSessionClip(laneIndex: 0, audio: _loop)],
              ),
            ],
          ),
        ),
      );
      expect(
        _value(liveSet, 'SequencerNavigator/BeatTimeHelper/CurrentZoom'),
        _value(
          _liveSet(XmlDocument.parse(liveSetTemplate)),
          'SequencerNavigator/BeatTimeHelper/CurrentZoom',
        ),
      );
    });

    group('automation', () {
      List<XmlElement> events(XmlElement track, int envelope) =>
          _at(track, 'AutomationEnvelopes/Envelopes')
              .findElements('AutomationEnvelope')
              .elementAt(envelope)
              .findAllElements('Automation')
              .single
              .getElement('Events')!
              .childElements
              .toList();

      test('opens each envelope with its value before the song, as Live '
          'does, then one event per breakpoint', () {
        final track = _audioTracks(
          _build(DawProject(tracks: [_fullTrack('Track 0')])),
        ).single;
        // Its first breakpoint is after the start: an event at 0 holds the
        // value at arm until then, since Live ramps between events.
        final volume = events(track, 0);
        expect(volume.map((e) => e.name.local), everyElement('FloatEvent'));
        expect(volume.map((e) => e.getAttribute('Time')), [
          '-63072000',
          '0',
          '2',
          '4',
        ]);
        expect(volume.map((e) => e.getAttribute('Value')), [
          '1',
          '1',
          '1',
          '0.25',
        ]);
        expect(volume.map((e) => e.getAttribute('Id')), ['0', '1', '2', '3']);

        final reference = _audioTracks(_corpus('automation')).single;
        expect(events(reference, 0).first.getAttribute('Time'), '-63072000');
      });

      test('shows the Mixer volume lane of a track with volume automation, '
          'with Automation Mode on', () {
        final document = _build(
          DawProject(
            tracks: [
              _fullTrack('Track 0'),
              const DawTrack(name: 'Track 1'),
            ],
          ),
        );
        expect(_value(_liveSet(document), 'AutomationMode'), 'true');
        final tracks = _audioTracks(document);
        List<(String, String)> lanes(XmlElement track) => [
          for (final lane in _at(
            track,
            'DeviceChain/AutomationLanes/AutomationLanes',
          ).findElements('AutomationLane'))
            (_value(lane, 'SelectedDevice'), _value(lane, 'SelectedEnvelope')),
        ];
        expect(lanes(tracks[0]), [('1', '2')]);
        // A track without automation keeps the template's lane.
        final template = _audioTracks(XmlDocument.parse(liveSetTemplate))
            .single;
        expect(lanes(tracks[1]), lanes(template));
      });

      test('leaves Automation Mode off when nothing is automated', () {
        final document = _build(
          const DawProject(tracks: [DawTrack(name: 'Track 0')]),
        );
        expect(_value(_liveSet(document), 'AutomationMode'), 'false');
      });

      test("clamps a volume to the Volume parameter's range", () {
        final track = _audioTracks(
          _build(
            const DawProject(
              tracks: [
                DawTrack(
                  name: 'Track 0',
                  volume: AutomationLane(
                    initialValue: 0,
                    breakpoints: [AutomationBreakpoint(beat: 1, value: 2)],
                  ),
                ),
              ],
            ),
          ),
        ).single;
        final range = _at(
          track,
          'DeviceChain/Mixer/Volume/MidiControllerRange',
        );
        expect(events(track, 0).map((e) => e.getAttribute('Value')), [
          _value(range, 'Min'),
          _value(range, 'Min'),
          _value(range, 'Max'),
        ]);
      });

      test('a track with no lanes has no envelopes', () {
        final track = _audioTracks(
          _build(const DawProject(tracks: [DawTrack(name: 'Track 0')])),
        ).single;
        expect(
          _at(track, 'AutomationEnvelopes/Envelopes').childElements,
          isEmpty,
        );
      });
    });

    group('reference tracks (#1799)', () {
      const second = DawAudioFile(
        fileRef: 'master-002.wav',
        sampleRate: 48000,
        frames: 48000 * 4,
      );
      XmlElement build(DawTrack track) =>
          _audioTracks(_build(DawProject(tracks: [track]))).single;

      test('a switched-off track has its activator off; a track is on by '
          'default', () {
        String activator(XmlElement t) =>
            _value(t, 'DeviceChain/Mixer/Speaker/Manual');
        expect(
          activator(build(const DawTrack(name: 'Ref', active: false))),
          'false',
        );
        expect(activator(build(const DawTrack(name: 'Main'))), 'true');
      });

      test("writes the info text into the track's Annotation", () {
        const info = 'Effects when the take started:\nLane 1: Reverb';
        final track = build(const DawTrack(name: 'Main', info: info));
        expect(_value(track, 'Name/Annotation'), info);
      });

      test('places each Arrangement clip where it starts, numbered in its '
          'list, and fits the zoom to the last one', () {
        final document = _build(
          const DawProject(
            tracks: [
              DawTrack(
                name: 'Master (as heard)',
                arrangementClips: [
                  DawClip(audio: _stem, startSeconds: 0),
                  DawClip(audio: second, startSeconds: 10),
                ],
              ),
            ],
          ),
        );
        final clips = _at(
          _audioTracks(document).single,
          'DeviceChain/MainSequencer/Sample/ArrangerAutomation/Events',
        ).findElements('AudioClip').toList();
        expect(clips.map((c) => c.getAttribute('Id')), ['0', '1']);
        expect(clips.map((c) => c.getAttribute('Time')), ['0', '20']);
        expect(clips.map((c) => _value(c, 'CurrentEnd')), ['20', '28']);
        expect(
          _number(
            _liveSet(document),
            'SequencerNavigator/BeatTimeHelper/CurrentZoom',
          ),
          closeTo(28 / 500, 1e-12),
        );
      });

      test('a step in the volume is two events at one beat', () {
        final track = build(
          const DawTrack(
            name: 'Main dry',
            volume: AutomationLane(
              initialValue: 1,
              breakpoints: [
                AutomationBreakpoint(beat: 0, value: 1),
                AutomationBreakpoint(beat: 2, value: 1),
                AutomationBreakpoint(beat: 2, value: 0),
              ],
            ),
          ),
        );
        final events = track
            .findAllElements('FloatEvent')
            .map((e) => (e.getAttribute('Time'), e.getAttribute('Id')))
            .toList();
        expect(events, [
          ('-63072000', '0'),
          ('0', '1'),
          ('2', '2'),
          ('2', '3'),
        ]);
      });
    });

    test('secondsToBeats converts at the given tempo', () {
      expect(secondsToBeats(1, 120), 2);
      expect(secondsToBeats(3, 90), 4.5);
    });
  });
}
