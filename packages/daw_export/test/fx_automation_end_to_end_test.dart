import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'helpers/fx_log.dart';

/// A take's effect switching and setting changes, from a capture's
/// `events.log` to the automation in the Live set (#1836): presses on and
/// off, an A/B switch between two racks, an effect replaced mid-take, knob
/// moves, and an input's monitor chain switched.

const int _rate = 48000;

/// 120 BPM: a beat is half a second.
const int _framesPerBeat = 24000;

/// A mono 32-bit float WAV of [frames] silent frames.
Uint8List _wav(int frames) {
  final header = ByteData(44)
    ..setUint32(0, 0x46464952, Endian.little)
    ..setUint32(4, 36 + frames * 4, Endian.little)
    ..setUint32(8, 0x45564157, Endian.little)
    ..setUint32(12, 0x20746d66, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 3, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, _rate, Endian.little)
    ..setUint32(28, _rate * 4, Endian.little)
    ..setUint16(32, 4, Endian.little)
    ..setUint16(34, 32, Endian.little)
    ..setUint32(36, 0x61746164, Endian.little)
    ..setUint32(40, frames * 4, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(Uint8List(frames * 4)))
      .toBytes();
}

/// The events of the envelope on [track] whose target is the parameter
/// named [name] of the device whose plugin is [plugin], as (frame, value):
/// the frame each event's time stands for, at the set's tempo. The event
/// before the song is left out.
List<(int, double)> _automation(XmlElement track, String plugin, String name) {
  final device = track
      .findAllElements('PluginDevice')
      .singleWhere(
        (d) =>
            d
                .getElement('PluginDesc')!
                .getElement('Vst3PluginInfo')!
                .getElement('Name')!
                .getAttribute('Value') ==
            plugin,
      );
  final slot = device
      .findAllElements('PluginFloatParameter')
      .singleWhere(
        (p) => p.getElement('ParameterName')!.getAttribute('Value') == name,
      );
  final target = slot
      .getElement('ParameterValue')!
      .getElement('AutomationTarget')!
      .getAttribute('Id');
  final envelopes = track
      .getElement('AutomationEnvelopes')!
      .getElement('Envelopes')!
      .findElements('AutomationEnvelope')
      .where(
        (e) =>
            e
                .getElement('EnvelopeTarget')!
                .getElement('PointeeId')!
                .getAttribute('Value') ==
            target,
      )
      .toList();
  if (envelopes.isEmpty) return const [];
  return [
    for (final event in envelopes.single.findAllElements('FloatEvent'))
      if (double.parse(event.getAttribute('Time')!) >= 0)
        (
          (double.parse(event.getAttribute('Time')!) * _framesPerBeat).round(),
          double.parse(event.getAttribute('Value')!),
        ),
  ];
}

/// [name]'s value on [plugin]'s device on [track], as the set opens it.
String _manual(XmlElement track, String plugin, String name) => track
    .findAllElements('PluginDevice')
    .singleWhere(
      (d) => d
          .findAllElements('Name')
          .any((n) => n.getAttribute('Value') == plugin),
    )
    .findAllElements('PluginFloatParameter')
    .singleWhere(
      (p) => p.getElement('ParameterName')!.getAttribute('Value') == name,
    )
    .getElement('ParameterValue')!
    .getElement('Manual')!
    .getAttribute('Value')!;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daw_export_fx_automation_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a take with presses, an A/B switch, an effect replaced and knob '
      'moves exports them as automation at the frames they happened', () {
    const frames = _rate * 8;
    void write(String file) => (File(
      '${dir.path}/$file',
    )..parent.createSync(recursive: true)).writeAsBytesSync(_wav(frames));
    write('stems/dry/track0-lane0.wav');
    write('stems/wet/track0-lane0.wav');
    write('loops/clean.wav');
    write('input-0-001.wav');
    write('input-raw-0-001.wav');
    File('${dir.path}/stems/stems.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'lanes': [
          {
            'channel': 0,
            'lane': 0,
            'dry': 'stems/dry/track0-lane0.wav',
            'wet': 'stems/wet/track0-lane0.wav',
          },
        ],
      }),
    );
    const rackA = {'id': 'a', 'name': 'Drive Rack'};
    const rackB = {'id': 'b', 'name': 'Fuzz Rack', 'bypassed': true};
    File('${dir.path}/performance.json').writeAsStringSync(
      jsonEncode({
        'sample_rate': _rate,
        'capture_frames': frames,
        'channel_layout': {
          'master_channels': 2,
          'captured_inputs': [0],
          'raw_inputs': [0],
        },
        'armSnapshot': {
          'tempoBpm': 120,
          'tracks': [
            {
              'channel': 0,
              'name': 'Guitar',
              'lanes': [
                {
                  'lane': 0,
                  'pcmRef': 'loops/clean.wav',
                  'effects': [
                    {
                      'type': 3,
                      'params': [0.35, 0.35, 0.35],
                    },
                    {
                      'type': 1,
                      'params': [0.5, 0.8],
                      'rack': rackA,
                    },
                    {
                      'type': 17,
                      'params': [0.2, 0.5],
                      'rack': rackB,
                      'enabled': false,
                    },
                    {
                      'type': 2,
                      'params': [0.5, 0.2],
                    },
                  ],
                },
              ],
            },
          ],
          'monitors': [
            {
              'input': 0,
              'effects': [
                {
                  'type': 4,
                  'params': [0.3, 0.7],
                },
              ],
            },
          ],
        },
        'disarmSnapshot': {'tracks': <Object>[]},
        'layers': <Object>[],
        'parts': [
          {'stream': 1, 'index': 1, 'file': 'input-0-001.wav'},
          {'stream': 100, 'index': 1, 'file': 'input-raw-0-001.wav'},
        ],
      }),
    );
    FxLog.write(dir.path, _rate, [
      // The Delay off and on again, off a block boundary.
      FxLog.laneEnabled(24017, 0, 0, 0, on: false),
      FxLog.laneEnabled(60001, 0, 0, 0, on: true),
      // Its Mix turned, a value each block.
      FxLog.laneParam(30000, 0, 0, 0, 2, 0.5),
      FxLog.laneParam(30032, 0, 0, 0, 2, 0.625),
      FxLog.laneParam(30064, 0, 0, 0, 2, 0.75),
      // An A/B press: the Drive Rack off and the Fuzz Rack on, one frame.
      FxLog.laneEnabled(96000, 0, 0, 1, on: false),
      FxLog.laneEnabled(96000, 0, 0, 2, on: true),
      // The Filter replaced by a Chorus, whose Depth then moves.
      FxLog.laneType(120000, 0, 0, 3, 14),
      FxLog.laneParam(144000, 0, 0, 3, 1, 0.5),
      // The input's Tremolo switched off.
      FxLog.monitorEnabled(72000, 0, 0, on: false),
    ]);

    final project = DawManifestReader.read(dir.path)!;
    final tracks = _audioTracks(buildAls(project));
    final lane = tracks.singleWhere((t) => _name(t) == 'Guitar L1');

    // An event at 0 holds the value at arm, as every envelope opens.
    expect(_automation(lane, 'Segno Delay', 'Enabled'), [
      (0, 1.0),
      (24017, 1.0),
      (24017, 0.0),
      (60001, 0.0),
      (60001, 1.0),
    ]);
    expect(
      _automation(lane, 'Segno Delay', 'Mix'),
      _matches([
        (0, closeTo(0.35, 1e-6)),
        (30000, closeTo(0.35, 1e-6)),
        (30000, 0.5),
        (30032, 0.5),
        (30032, 0.625),
        (30064, 0.625),
        (30064, 0.75),
      ]),
    );
    expect(_automation(lane, 'Segno Drive', 'Enabled'), [
      (0, 1.0),
      (96000, 1.0),
      (96000, 0.0),
    ]);
    expect(_manual(lane, 'Segno Distortion', 'Enabled'), '0');
    expect(_automation(lane, 'Segno Distortion', 'Enabled'), [
      (0, 0.0),
      (96000, 0.0),
      (96000, 1.0),
    ]);
    expect(_automation(lane, 'Segno Filter', 'Enabled'), [
      (0, 1.0),
      (120000, 1.0),
      (120000, 0.0),
    ]);
    expect(_manual(lane, 'Segno Chorus', 'Enabled'), '0');
    expect(_automation(lane, 'Segno Chorus', 'Enabled'), [
      (0, 0.0),
      (120000, 0.0),
      (120000, 1.0),
    ]);
    expect(
      _automation(lane, 'Segno Chorus', 'Depth'),
      // The Chorus starts at its defaults: Depth 0.21.
      _matches([
        (0, closeTo(0.21, 1e-6)),
        (144000, closeTo(0.21, 1e-6)),
        (144000, 0.5),
      ]),
    );
    // Both racks stay on: their switches are their modules' (D5).
    expect(
      lane
          .findAllElements('AudioEffectGroupDevice')
          .map(
            (r) =>
                r.getElement('On')!.getElement('Manual')!.getAttribute('Value'),
          ),
      ['true', 'true'],
    );

    final raw = tracks.singleWhere((t) => _name(t) == 'Input 1 raw');
    expect(_automation(raw, 'Segno Tremolo', 'Enabled'), [
      (0, 1.0),
      (72000, 1.0),
      (72000, 0.0),
    ]);
    // The references carry no automation: their audio holds it already.
    for (final heard in tracks.where((t) => _name(t).endsWith('(as heard)'))) {
      expect(heard.findAllElements('AutomationEnvelope'), isEmpty);
    }
  });
}

List<XmlElement> _audioTracks(List<int> als) =>
    XmlDocument.parse(utf8.decode(gzip.decode(als))).rootElement
        .getElement('LiveSet')!
        .getElement('Tracks')!
        .findElements('AudioTrack')
        .toList();

String _name(XmlElement track) => track
    .getElement('Name')!
    .getElement('EffectiveName')!
    .getAttribute('Value')!;

/// [expected] as a matcher of (frame, value) pairs, each value a matcher or
/// a number.
Matcher _matches(List<(int, Object)> expected) =>
    pairwiseCompare<(int, Object), (int, double)>(
      expected,
      (e, a) => e.$1 == a.$1 && wrapMatcher(e.$2).matches(a.$2, {}),
      'at the same frame with a matching value',
    );
