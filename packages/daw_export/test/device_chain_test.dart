import 'package:daw_export/src/device_chain.dart';
import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:test/test.dart';

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
      expect(delay.state.hopSeed, 64);
      expect(delay.state.clockOffset, 1000);
      expect(delay.state.beatOffset, 2.5);
      final drive = _plugin(devices[1]);
      expect(drive.plugin, segnoPlugins[1]);
      expect(drive.state.slot, 2);
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
      final echo = _rack(devices[2]);
      expect(echo.on, isFalse);
      expect(_plugin(echo.chains.single.devices.single).state.enabled, isTrue);
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
    });
  });
}
