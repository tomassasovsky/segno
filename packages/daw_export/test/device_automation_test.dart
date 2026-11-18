import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// The automation of devices in a Live set (#1836), against the set Live
/// saved with Segno's plugins automated (`test/corpus/plugin_automation.als`).

XmlDocument _decode(List<int> als) =>
    XmlDocument.parse(utf8.decode(gzip.decode(als)));

XmlDocument _corpus(String name) =>
    _decode(File('test/corpus/$name.als').readAsBytesSync());

List<XmlElement> _audioTracks(XmlDocument d) => d.rootElement
    .getElement('LiveSet')!
    .getElement('Tracks')!
    .findElements('AudioTrack')
    .toList();

XmlElement _at(XmlElement e, String path) {
  var node = e;
  for (final name in path.split('/')) {
    node = node.getElement(name)!;
  }
  return node;
}

String _value(XmlElement e, String path) => _at(e, path).getAttribute('Value')!;

List<XmlElement> _envelopes(XmlElement track) => _at(
  track,
  'AutomationEnvelopes/Envelopes',
).findElements('AutomationEnvelope').toList();

/// [envelope]'s events as (name, time, value).
List<(String, String, String)> _events(XmlElement envelope) => [
  for (final e in _at(envelope, 'Automation/Events').childElements)
    (e.name.local, e.getAttribute('Time')!, e.getAttribute('Value')!),
];

/// The element whose `AutomationTarget` [envelope] points at: a
/// parameter's `ParameterValue`, or a device's `On`.
XmlElement _targetOf(XmlElement track, XmlElement envelope) {
  final id = _value(envelope, 'EnvelopeTarget/PointeeId');
  return track
      .findAllElements('AutomationTarget')
      .singleWhere((t) => t.getAttribute('Id') == id)
      .parentElement!;
}

/// The plugin parameter slot holding [value], a `ParameterValue`.
XmlElement _slotOf(XmlElement value) => value.parentElement!;

(String, String) _chooser(XmlElement track) {
  final lane = _at(
    track,
    'DeviceChain/AutomationLanes/AutomationLanes',
  ).findElements('AutomationLane').single;
  return (_value(lane, 'SelectedDevice'), _value(lane, 'SelectedEnvelope'));
}

DawPluginDevice _plugin(
  int type, {
  AutomationLane? switching,
  Map<int, AutomationLane> parameters = const {},
  bool enabled = true,
}) => DawPluginDevice(
  plugin: segnoPlugins[type]!,
  state: SegnoPluginState(
    type: type,
    params: [for (final p in segnoPlugins[type]!.parameters) p.defaultValue],
    enabled: enabled,
  ),
  switching: switching,
  parameters: parameters,
);

/// [from], then a step to each value at its beat in [steps].
AutomationLane _steps(double from, List<(double, double)> steps) {
  final points = <AutomationBreakpoint>[];
  var before = from;
  for (final (beat, value) in steps) {
    points
      ..add(AutomationBreakpoint(beat: beat, value: before))
      ..add(AutomationBreakpoint(beat: beat, value: value));
    before = value;
  }
  return AutomationLane(initialValue: from, breakpoints: points);
}

const _clip = DawClip(
  audio: DawAudioFile(fileRef: 'pluck.wav', sampleRate: 48000, frames: 768000),
  startSeconds: 0,
);

XmlElement _track(List<DawDevice> devices, {AutomationLane? volume}) =>
    _audioTracks(
      _decode(
        buildAls(
          DawProject(
            tracks: [
              DawTrack(
                name: 'A',
                arrangementClips: const [_clip],
                devices: devices,
                volume: volume,
              ),
            ],
          ),
        ),
      ),
    ).single;

void main() {
  late final saved = _corpus('plugin_automation');
  late final savedTracks = _audioTracks(saved);

  group('the set Live saved with plugin automation', () {
    test('holds every envelope of a track on the track, a device in a rack '
        "included, each on its parameter's or its device's target", () {
      final c = savedTracks[2];
      final envelopes = _envelopes(c);
      expect(envelopes, hasLength(2));
      // The rack's Device On, then Segno Distortion's Drive inside it.
      expect(_targetOf(c, envelopes[0]).name.local, 'On');
      expect(
        _targetOf(c, envelopes[0]).parentElement!.name.local,
        'AudioEffectGroupDevice',
      );
      expect(
        _value(_slotOf(_targetOf(c, envelopes[1])), 'ParameterName'),
        'Drive',
      );
    });

    test('a switch is BoolEvents, a parameter FloatEvents, and a step two '
        'events at one time', () {
      final a = savedTracks[0];
      final [on, mix, mode] = _envelopes(a).map(_events).toList();
      expect(on, [
        ('BoolEvent', '-63072000', 'true'),
        ('BoolEvent', '8', 'true'),
        ('BoolEvent', '8', 'false'),
        ('BoolEvent', '16', 'true'),
      ]);
      expect(mix.map((e) => e.$1), everyElement('FloatEvent'));
      expect(mix.where((e) => e.$2 == '20'), hasLength(2));
      // A stepped setting that is not a list (Mode delay's Delay mode, 13
      // positions) is normalized, as its value is.
      final value = _targetOf(a, _envelopes(a)[2]);
      expect(_value(_slotOf(value), 'ParameterName'), 'Delay mode');
      expect(_value(value, 'MidiControllerRange/Max'), '1');
      expect(mode.map((e) => double.parse(e.$3)), everyElement(lessThan(1)));
      expect(mode.map((e) => double.parse(e.$3)).toSet().length, 2);
    });

    test('a recorded switch is one event at each press', () {
      final b = savedTracks[1];
      final on = _events(_envelopes(b).single);
      expect(on.first, ('BoolEvent', '-63072000', 'false'));
      final recorded = on
          .where((e) => !e.$2.startsWith('1.0') && e.$2 != '-63072000')
          .toList();
      expect(recorded.map((e) => e.$3), ['false', 'true', 'false']);
      expect(recorded.map((e) => e.$2).toSet(), hasLength(3));
    });

    test(
      'numbers a device parameter in the lane chooser after its Device '
      'On, and a device in a rack after the rack and the chains before it',
      () {
        // Track A: Segno Delay's Mix, its third parameter.
        expect(_chooser(savedTracks[0]), ('1', '3'));
        // Track C: the rack (1), the Doubler chain's Doubler (2) and mixer
        // (3), then Segno Distortion (4) and its Drive.
        expect(_chooser(savedTracks[2]), ('4', '1'));
      },
    );

    test('lists no bypass parameter: Segno Delay lists its settings, its '
        'channel handling and nothing else', () {
      final delay = savedTracks[1].findAllElements('PluginDevice').single;
      expect(
        [
          for (final p in delay.findAllElements('PluginFloatParameter'))
            if (_value(p, 'ParameterId') != '-1') _value(p, 'ParameterName'),
        ],
        [
          'Time',
          'Feedback',
          'Mix',
          'Input',
          'Output',
          'Balance / Pan',
          'Output level',
        ],
      );
    });
  });

  group('buildAls automates', () {
    test("a plugin's switch as its Enabled, a step at each change, with the "
        'device on', () {
      final track = _track([
        _plugin(3, switching: _steps(1, [(8, 0), (16, 1)])),
      ]);
      final envelope = _envelopes(track).single;
      final value = _targetOf(track, envelope);
      expect(_value(_slotOf(value), 'ParameterId'), '$kSegnoEnabledParameter');
      expect(_value(_slotOf(value), 'ParameterName'), 'Enabled');
      expect(_events(envelope), [
        ('FloatEvent', '-63072000', '1'),
        ('FloatEvent', '0', '1'),
        ('FloatEvent', '8', '1'),
        ('FloatEvent', '8', '0'),
        ('FloatEvent', '16', '0'),
        ('FloatEvent', '16', '1'),
      ]);
      final device = track.findAllElements('PluginDevice').single;
      expect(_value(device, 'On/Manual'), 'true');
      // Enabled is the Delay's eighth parameter: its envelope is the ninth,
      // after Device On.
      expect(_chooser(track), ('1', '8'));
    });

    test('a setting on its own slot, normalized, and a list in steps, as '
        'Live keeps them', () {
      final track = _track([
        _plugin(
          27,
          parameters: {
            0: _steps(0.25, [(4, 0.5)]),
            3: _steps(0, [(2, 3 / 13)]),
            1000: _steps(0, [(6, 1)]),
          },
        ),
      ]);
      final envelopes = _envelopes(track);
      expect(
        [
          for (final e in envelopes)
            _value(_slotOf(_targetOf(track, e)), 'ParameterName'),
        ],
        ['Delay time', 'Delay mode', 'Input'],
      );
      expect(_events(envelopes[1]).last.$3, '${3 / 13}');
      expect(
        _value(_targetOf(track, envelopes[1]), 'MidiControllerRange/Max'),
        '1',
      );
      expect(_events(envelopes[2]).map((e) => e.$3), ['0', '0', '0', '3']);
      expect(
        [for (final e in envelopes) e.getAttribute('Id')],
        ['0', '1', '2'],
      );
    });

    test("a rack's switch as its Device On, and a device in it on the "
        "track, numbered in Live's lane chooser", () {
      final track = _track([
        DawRackDevice(
          name: 'Audio Effect Rack',
          switching: _steps(1, [(8, 0), (16, 1)]),
          chains: [
            DawRackChain(name: 'Doubler', devices: [_plugin(13)]),
            DawRackChain(
              name: 'Distortion',
              devices: [
                _plugin(
                  17,
                  parameters: {
                    0: _steps(0.2, [(16, 0.78)]),
                  },
                ),
              ],
            ),
          ],
        ),
      ]);
      final [on, drive] = _envelopes(track);
      expect(_targetOf(track, on).name.local, 'On');
      expect(_events(on), [
        ('BoolEvent', '-63072000', 'true'),
        ('BoolEvent', '8', 'false'),
        ('BoolEvent', '16', 'true'),
      ]);
      expect(
        _value(_slotOf(_targetOf(track, drive)), 'ParameterName'),
        'Drive',
      );
      // As Live numbered the same layout: the rack's On is the first lane.
      expect(_chooser(track), ('1', '0'));
      final distortionOnly = _track([
        DawRackDevice(
          name: 'Audio Effect Rack',
          chains: [
            DawRackChain(name: 'Doubler', devices: [_plugin(13)]),
            DawRackChain(
              name: 'Distortion',
              devices: [
                _plugin(
                  17,
                  parameters: {
                    0: _steps(0.2, [(16, 0.78)]),
                  },
                ),
              ],
            ),
          ],
        ),
      ]);
      expect(_chooser(distortionOnly), _chooser(savedTracks[2]));
    });

    test("a Delay's Mix in the lane Live shows for it", () {
      final track = _track([
        _plugin(
          3,
          parameters: {
            2: _steps(1, [(8, 0.3)]),
          },
        ),
        _plugin(27),
      ]);
      expect(_chooser(track), _chooser(savedTracks[0]));
    });

    test('the volume first when the track has both, and turns Automation '
        'Mode on for device automation alone', () {
      final volume = _steps(1, [(4, 0.5)]);
      final both = _track([
        _plugin(3, switching: _steps(1, [(8, 0)])),
      ], volume: volume);
      expect(
        _targetOf(both, _envelopes(both).first).parentElement!.name.local,
        'Mixer',
      );
      expect(_chooser(both), ('2', '2'));
      final als = _decode(
        buildAls(
          DawProject(
            tracks: [
              DawTrack(
                name: 'A',
                devices: [
                  DawRackDevice(
                    name: 'R',
                    chains: [
                      DawRackChain(
                        name: 'R',
                        devices: [
                          _plugin(
                            3,
                            parameters: {
                              0: _steps(0.3, [(2, 0.4)]),
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      expect(
        _value(als.rootElement.getElement('LiveSet')!, 'AutomationMode'),
        'true',
      );
    });

    test('envelopes with the shapes Live saved', () {
      Set<String> shape(XmlElement e) {
        final paths = <String>{};
        void walk(XmlElement x, String prefix) {
          final attributes = x.attributes.map((a) => a.name.local).toList()
            ..sort();
          final path = '$prefix/${x.name.local}';
          paths.add('$path[${attributes.join(',')}]');
          for (final c in x.childElements) {
            walk(c, path);
          }
        }

        walk(e, '');
        return paths;
      }

      final track = _track([
        DawRackDevice(
          name: 'R',
          switching: _steps(1, [(8, 0)]),
          chains: [
            DawRackChain(
              name: 'R',
              devices: [
                _plugin(
                  3,
                  parameters: {
                    2: _steps(1, [(8, 0.3)]),
                  },
                ),
              ],
            ),
          ],
        ),
      ]);
      final [on, mix] = _envelopes(track);
      final [savedOn, savedMix, _] = _envelopes(savedTracks[0]);
      expect(shape(on), shape(savedOn));
      expect(shape(mix), shape(savedMix));
    });
  });
}
