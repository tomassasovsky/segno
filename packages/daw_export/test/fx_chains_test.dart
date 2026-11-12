import 'dart:convert';
import 'dart:io';

import 'package:daw_export/daw_export.dart';
import 'package:test/test.dart';

Map<String, dynamic> _effect(
  int type, {
  bool enabled = true,
  Map<String, dynamic>? rack,
}) => {
  'type': type,
  'params': <double>[],
  if (!enabled) 'enabled': false,
  'rack': ?rack,
};

void main() {
  group('FxChainsWriter.render', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('fx_chains_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void manifest(Map<String, dynamic> json) =>
        File('${dir.path}/performance.json')
            .writeAsStringSync(jsonEncode(json));

    test('returns null when performance.json is missing, corrupt or not an '
        'object', () {
      expect(FxChainsWriter.render(dir.path), isNull);
      File('${dir.path}/performance.json').writeAsStringSync('{not json');
      expect(FxChainsWriter.render(dir.path), isNull);
      File('${dir.path}/performance.json').writeAsStringSync('[]');
      expect(FxChainsWriter.render(dir.path), isNull);
    });

    test('says so when the take recorded no effects, instead of writing '
        'nothing', () {
      manifest({
        'armSnapshot': {
          'tracks': [
            {
              'channel': 0,
              'lanes': [
                {'lane': 0},
              ],
            },
          ],
        },
      });
      expect(
        FxChainsWriter.render(dir.path),
        'Effects when the take started. Changes made during the\n'
        'take are in events.log.\n'
        '\n'
        'No effects were recorded.\n',
      );
    });

    test("lists each track's, input's and the output's chains under the "
        'names the Live set gives their tracks', () {
      manifest({
        'channel_layout': {
          'captured_inputs': [0],
        },
        'armSnapshot': {
          'tracks': [
            {
              'channel': 1,
              'name': 'Bass',
              'lanes': [
                {
                  'lane': 0,
                  'effects': [_effect(16)],
                },
                {'lane': 1},
              ],
            },
            {
              'channel': 0,
              'lanes': [
                {
                  'lane': 1,
                  'effects': [_effect(7)],
                },
              ],
            },
          ],
          'trackChains': [
            {
              'channel': 1,
              'effects': [_effect(14)],
            },
          ],
          'inputs': [
            {'input': 0, 'name': 'Guitar'},
          ],
          'monitors': [
            {
              'input': 0,
              'effects': [_effect(29)],
            },
          ],
          'outputEffects': [_effect(10)],
        },
      });
      expect(
        FxChainsWriter.render(dir.path),
        'Effects when the take started. Changes made during the\n'
        'take are in events.log.\n'
        '\n'
        'Track 1:\n'
        '  Lane 2: Reverb\n'
        'Bass:\n'
        '  Track: Chorus\n'
        '  Lane 1: Overdrive\n'
        'Guitar:\n'
        '  Amp\n'
        'Master (as heard):\n'
        '  Compressor\n',
      );
    });
  });

  group('EffectText', () {
    Map<String, dynamic> lane(
      List<Map<String, dynamic>> effects, {
      bool chainEnabled = true,
    }) => {
      'armSnapshot': {
        'tracks': [
          {
            'channel': 0,
            'lanes': [
              {
                'lane': 0,
                'effects': effects,
                if (!chainEnabled) 'chainEnabled': false,
              },
            ],
          },
        ],
      },
    };

    test('groups a rack under its name and marks what is off', () {
      const studio = {'id': 'r1', 'name': 'Studio'};
      const dub = {'id': 'r2', 'name': 'Dub', 'bypassed': true};
      expect(
        EffectText.track(
          lane([
            _effect(1),
            _effect(16, rack: studio),
            _effect(29, rack: studio, enabled: false),
            _effect(22, rack: dub),
            _effect(3),
          ]),
          0,
        ),
        'Lane 1: Drive, Studio (Overdrive, Amp off), Dub off (Dub reverb), '
        'Delay',
      );
    });

    test('marks a chain switched off as a whole', () {
      expect(
        EffectText.track(lane([_effect(7)], chainEnabled: false), 0),
        'Lane 1: Reverb (chain off)',
      );
    });

    test('names a plugin by format and id, and an unknown type by its '
        'code', () {
      expect(
        EffectText.track(
          lane([
            {
              'type': 8,
              'plugin': {'format': 1, 'id': 'org.example.verb'},
            },
            {'type': 8},
            {'type': 99},
          ]),
          0,
        ),
        'Lane 1: CLAP org.example.verb, VST3 plugin, Effect 99',
      );
    });

    test('skips empty slots, and a chain of only empty slots is no chain', () {
      expect(
        EffectText.track(lane([_effect(0), _effect(5)]), 0),
        'Lane 1: Octaver',
      );
      expect(EffectText.track(lane([_effect(0)]), 0), isNull);
      expect(EffectText.track(lane([]), 0), isNull);
    });

    test('reads nothing from a missing or malformed snapshot', () {
      expect(EffectText.track(const {}, 0), isNull);
      expect(EffectText.input(const {}, 0), isNull);
      expect(EffectText.output(const {}), isNull);
      expect(
        EffectText.input(const {
          'armSnapshot': {
            'monitors': [
              {'input': 1, 'effects': <dynamic>[]},
              'not a map',
            ],
          },
        }, 0),
        isNull,
      );
    });
  });
}
