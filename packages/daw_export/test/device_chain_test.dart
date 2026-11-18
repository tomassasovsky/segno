import 'package:daw_export/src/chain_timeline.dart';
import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/device_chain.dart';
import 'package:daw_export/src/event_log_reader.dart';
import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:test/test.dart';

import 'helpers/fx_log.dart';

DawPluginDevice _plugin(DawDevice d) => d as DawPluginDevice;
DawRackDevice _rack(DawDevice d) => d as DawRackDevice;

void main() {
  const origin = ChainOrigin(hopSeed: 64, clockOffset: 1000, beatOffset: 2.5);

  group('devicesOfChain', () {
    test('makes each built-in effect its plugin, on its chain slot', () {
      final devices = devicesOfChain([
        {
          'type': 3,
          'params': [0.35, 0.4, 0.5],
        },
        {'type': 0, 'params': <double>[]},
        {
          'type': 1,
          'params': [0.5, 0.8],
          'enabled': false,
          'channels': {
            'input': 'monoSum',
            'output': 'mono',
            'placement': -0.5,
            'level': 1.25,
          },
        },
      ], origin: origin);
      expect(devices, hasLength(2));
      final delay = _plugin(devices[0]);
      expect(delay.plugin, segnoPlugins[3]);
      expect(delay.state.params, [0.35, 0.4, 0.5]);
      expect(delay.state.slot, 0);
      expect(delay.state.enabled, isTrue);
      expect(delay.switching, isNull);
      expect(delay.parameters, isEmpty);
      expect(delay.state.hopSeed, 64);
      expect(delay.state.clockOffset, 1000);
      expect(delay.state.beatOffset, 2.5);
      final drive = _plugin(devices[1]);
      expect(drive.plugin, segnoPlugins[1]);
      expect(drive.state.slot, 2);
      // Off by its own switch, the plugin's Enabled, as the engine runs it.
      expect(drive.state.enabled, isFalse);
      expect(drive.state.input, 3);
      expect(drive.state.output, 1);
      expect(drive.state.placement, -0.5);
      expect(drive.state.level, 1.25);
    });

    test('switches every plugin off with its chain', () {
      final devices = devicesOfChain(
        [
          {
            'type': 7,
            'params': [0.5, 0.5, 0.35],
          },
        ],
        origin: origin,
        chainEnabled: false,
      );
      expect(_plugin(devices.single).state.enabled, isFalse);
    });

    test('leaves out hosted plugins and anything that is not a list', () {
      expect(
        devicesOfChain([
          {
            'type': 8,
            'plugin': {'format': 0, 'id': 'x', 'version': 0},
          },
        ], origin: origin),
        isEmpty,
      );
      expect(devicesOfChain(null, origin: origin), isEmpty);
    });

    test('makes a run of one rack an Audio Effect Rack', () {
      const rack = {'id': 'r1', 'name': 'Lo-Fi Rack'};
      final devices = devicesOfChain([
        {
          'type': 1,
          'params': [0.5, 0.8],
        },
        {
          'type': 18,
          'params': [0.4, 0.35, 0.3, 0.9],
          'rack': rack,
        },
        {
          'type': 19,
          'params': [1.0, 1.0, 1.0],
          'rack': rack,
        },
        {
          'type': 3,
          'params': [0.35, 0.35, 0.35],
          'rack': {'id': 'r2', 'name': 'Echo Rack', 'bypassed': true},
        },
      ], origin: origin);
      expect(devices, hasLength(3));
      final lofi = _rack(devices[1]);
      expect(lofi.name, 'Lo-Fi Rack');
      expect(lofi.on, isTrue);
      expect(lofi.chains.single.devices.map((d) => _plugin(d).state.slot), [
        1,
        2,
      ]);
      // A rack is always on: its switch is its entries' (#1806 D5).
      final echo = _rack(devices[2]);
      expect(echo.on, isTrue);
      expect(echo.switching, isNull);
    });

    test("switches a switched-off rack's modules off by their recorded "
        'bit, the one the engine runs, and leaves the rack on', () {
      final devices = devicesOfChain([
        {
          'type': 3,
          'params': [0.35, 0.35, 0.35],
          'enabled': false,
          'rack': {'id': 'r2', 'name': 'Echo Rack', 'bypassed': true},
        },
      ], origin: origin);
      final echo = _rack(devices.single);
      expect(echo.on, isTrue);
      expect(_plugin(echo.chains.single.devices.single).state.enabled, isFalse);
    });

    test('leaves out a rack with nothing Segno runs in it', () {
      const rack = {'id': 'r1', 'name': 'Plugin Rack'};
      expect(
        devicesOfChain([
          {
            'type': 8,
            'plugin': {'format': 0, 'id': 'x', 'version': 0},
            'rack': rack,
          },
          {'type': 0, 'params': <double>[], 'rack': rack},
        ], origin: origin),
        isEmpty,
      );
    });

    test('keeps a rack whose parallel section holds only hosted plugins: '
        'its paths still sum the input at their gains', () {
      const rack = {'id': 'd1', 'name': 'Dub Rack'};
      const hosted = {
        'type': 8,
        'plugin': {'format': 0, 'id': 'x', 'version': 0},
        'rack': rack,
      };
      final devices = devicesOfChain([
        {...hosted, 'rackPath': 'amb'},
        {...hosted, 'rackPath': 'dub'},
      ], origin: origin);
      final paths = _rack(_rack(devices.single).chains.single.devices.single);
      expect(paths.chains.map((c) => c.devices), [isEmpty, isEmpty]);
      expect(paths.chains.map((c) => c.volume), [1.0, closeTo(0.64, 1e-9)]);
    });

    test('reads a malformed entry without throwing', () {
      final devices = devicesOfChain([
        {
          'type': 23,
          'params': [0.2],
          'rack': {'id': 'd', 'name': 'Dub Rack'},
          'rackPath': 'amb',
          'channels': {'placement': 'centre', 'level': null},
        },
      ], origin: origin);
      final paths = _rack(_rack(devices.single).chains.single.devices.single);
      // No Amb-Dub Mix: the default, 0.4.
      expect(paths.chains.map((c) => c.volume), [1.0, closeTo(0.64, 1e-9)]);
      final ambience = _plugin(paths.chains.first.devices.single);
      expect(ambience.state.placement, 0);
      expect(ambience.state.level, 1);
    });

    test('makes a parallel section a rack of an Amb and a Dub chain', () {
      const rack = {'id': 'd1', 'name': 'Dub Rack'};
      final devices = devicesOfChain([
        {
          'type': 2,
          'params': [0.5, 0.2],
          'rack': rack,
        },
        {
          'type': 23,
          'params': [0.2, 0.4, 0.75],
          'rack': rack,
          'rackPath': 'amb',
        },
        {
          'type': 22,
          'params': [0.7, 0.2],
          'rack': rack,
          'rackPath': 'dub',
        },
        {
          'type': 3,
          'params': [0.35, 0.35, 0.35],
          'rack': rack,
        },
      ], origin: origin);
      final dub = _rack(devices.single);
      final chain = dub.chains.single.devices;
      expect(chain, hasLength(3));
      final paths = _rack(chain[1]);
      expect(paths.chains.map((c) => c.name), ['Amb', 'Dub']);
      // m = 0.75: d = 1.5, so Amb 1 - 0.25 and Dub 1.
      expect(paths.chains[0].volume, 0.75);
      expect(paths.chains[1].volume, 1);
      expect(_plugin(paths.chains[0].devices.single).state.type, 23);
      expect(_plugin(paths.chains[1].devices.single).state.type, 22);
    });
  });

  group('pathGains', () {
    test('follows the engine law', () {
      expect(pathGains(0), (1.0, 0.0));
      expect(pathGains(0.25), (1.0, 0.25));
      expect(pathGains(0.5), (1.0, 1.0));
      expect(pathGains(1), (0.0, 1.0));
    });
  });

  group('ChainOrigin', () {
    test('seeds a lane and a bus as the engine does', () {
      expect(ChainOrigin.lane(0, 0).hopSeed, 0);
      expect(ChainOrigin.lane(3, 0).hopSeed, 192);
      expect(ChainOrigin.lane(5, 0).hopSeed, 64);
      expect(ChainOrigin.bus(0).hopSeed, 128);
      expect(ChainOrigin.bus(3).hopSeed, 64);
      expect(ChainOrigin.monitor(0).hopSeed, 64);
      expect(ChainOrigin.monitor(3).hopSeed, 0);
    });
  });

  group('devicesOfChain with what changed during the take (#1836)', () {
    ChainTimeline timeline(List<RawLogEntry> entries, List<Object> effects) =>
        ChainTimeline.lane(
          entries,
          0,
          0,
          effects: effects,
          chainEnabled: true,
          sampleRate: 48000,
          tempoBpm: 120,
        );
    List<double> values(AutomationLane? lane) => [
      for (final b in lane!.breakpoints) b.value,
    ];

    test("carries each plugin's switching and settings as automation", () {
      final effects = [
        {
          'type': 3,
          'params': [0.35, 0.4, 0.5],
        },
      ];
      final devices = devicesOfChain(
        effects,
        origin: origin,
        timeline: timeline([
          FxLog.laneEnabled(24000, 0, 0, 0, on: false),
          FxLog.laneParam(48000, 0, 0, 0, 2, 0.75),
        ], effects),
      );
      final delay = _plugin(devices.single);
      expect(values(delay.switching), [1, 0]);
      expect(values(delay.parameters[2]), [0.5, 0.75]);
      expect(delay.state.hopSeed, 64);
    });

    test('an A/B press is the switches of both racks, each rack on with its '
        'modules switched (D5)', () {
      const a = {'id': 'a', 'name': 'Rack A'};
      const b = {'id': 'b', 'name': 'Rack B', 'bypassed': true};
      final effects = [
        {
          'type': 1,
          'params': [0.5, 0.8],
          'rack': a,
        },
        {
          'type': 17,
          'params': [0.2, 0.5],
          'rack': b,
          'enabled': false,
        },
      ];
      final devices = devicesOfChain(
        effects,
        origin: origin,
        timeline: timeline([
          FxLog.laneEnabled(24000, 0, 0, 0, on: false),
          FxLog.laneEnabled(24000, 0, 0, 1, on: true),
        ], effects),
      );
      final [rackA, rackB] = devices.map(_rack).toList();
      expect([rackA.on, rackB.on], [isTrue, isTrue]);
      final drive = _plugin(rackA.chains.single.devices.single);
      final distortion = _plugin(rackB.chains.single.devices.single);
      expect(drive.state.enabled, isTrue);
      expect(values(drive.switching), [1, 0]);
      expect(distortion.state.enabled, isFalse);
      expect(values(distortion.switching), [0, 1]);
    });

    test('a slot whose effect changed holds a plugin for each, next to each '
        'other in its rack (D6)', () {
      const rack = {'id': 'r', 'name': 'Rack'};
      final effects = [
        {
          'type': 1,
          'params': [0.5, 0.8],
          'rack': rack,
        },
      ];
      final devices = devicesOfChain(
        effects,
        origin: origin,
        timeline: timeline([FxLog.laneType(24000, 0, 0, 0, 17)], effects),
      );
      final [drive, distortion] = _rack(devices.single).chains.single.devices
          .map(_plugin)
          .toList();
      expect(drive.plugin, segnoPlugins[1]);
      expect(distortion.plugin, segnoPlugins[17]);
      expect(distortion.state.slot, 0);
      expect(distortion.state.enabled, isFalse);
      expect(values(distortion.switching), [0, 1]);
      expect(values(drive.switching), [1, 0]);
    });

    test('a slot past the arm chain gets the plugin that lands on it, in '
        'place', () {
      final effects = [
        {
          'type': 3,
          'params': [0.35, 0.4, 0.5],
        },
      ];
      final devices = devicesOfChain(
        effects,
        origin: origin,
        timeline: timeline([
          FxLog.laneCount(24000, 0, 0, 2),
          FxLog.laneType(24000, 0, 0, 1, 7),
        ], effects),
      );
      expect(devices.map((d) => _plugin(d).state.slot), [0, 1]);
      expect(_plugin(devices[1]).plugin, segnoPlugins[7]);
    });

    test('switches the Amb / Dub section on while any entry of its rack '
        'runs, as the engine fades it to its input when none does', () {
      const rack = {'id': 'd', 'name': 'Dub Rack'};
      final effects = [
        {
          'type': 2,
          'params': [0.5, 0.2],
          'rack': rack,
        },
        {
          'type': 23,
          'params': [0.2, 0.4, 0.75],
          'rack': rack,
          'rackPath': 'amb',
        },
      ];
      final devices = devicesOfChain(
        effects,
        origin: origin,
        timeline: timeline([
          FxLog.laneEnabled(24000, 0, 0, 0, on: false),
          FxLog.laneEnabled(24000, 0, 0, 1, on: false),
          FxLog.laneEnabled(48000, 0, 0, 1, on: true),
        ], effects),
      );
      final paths = _rack(_rack(devices.single).chains.single.devices[1]);
      expect(paths.on, isTrue);
      expect(values(paths.switching), [1, 0, 0, 1]);
    });
  });
}
