import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/screen_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(segnoScreenFrom, () {
    test('names the screen the embedder passed', () {
      expect(segnoScreenFrom(['--segno-screen=main']), SegnoScreen.main);
      expect(
        segnoScreenFrom(['--ihs-view=readout', '--segno-screen=readout']),
        SegnoScreen.readout,
      );
    });

    test('is null when no embedder named a screen', () {
      expect(segnoScreenFrom([]), isNull);
      expect(segnoScreenFrom(['--ihs-view=main']), isNull);
    });

    test('throws for an unknown screen rather than starting a main one', () {
      expect(
        () => segnoScreenFrom(['--segno-screen=Main']),
        throwsArgumentError,
      );
      expect(() => segnoScreenFrom(['--segno-screen=']), throwsArgumentError);
    });
  });

  group(sendableCopy, () {
    test('rebuilds nested maps and lists as plain literals', () {
      final copy = sendableCopy({
        'names': List<String>.unmodifiable(['a', 'b']),
        'nested': const [
          {'n': 1, 'x': 0.5, 'b': true, 's': 'v', 'none': null},
        ],
      });
      expect(copy, {
        'names': ['a', 'b'],
        'nested': [
          {'n': 1, 'x': 0.5, 'b': true, 's': 'v', 'none': null},
        ],
      });
      // The unmodifiable list was replaced, not passed through.
      final names = (copy! as Map)['names'] as List<Object?>;
      expect(() => names.add('c'), returnsNormally);
    });

    test('passes ports and transferable bytes through', () {
      final port = ReceivePort();
      addTearDown(port.close);
      final bytes = packSamples(Float32List(2));
      expect(sendableCopy(port.sendPort), same(port.sendPort));
      expect(sendableCopy(bytes), same(bytes));
    });

    test('copies a typed list as a plain list of its numbers', () {
      final copy = sendableCopy(Float32List.fromList([0.5, 1]));
      expect(copy, isNot(isA<Float32List>()));
      expect(copy, [0.5, 1.0]);
    });

    test('refuses values that cannot cross between engines', () {
      expect(() => sendableCopy({'when': DateTime(2026)}), throwsArgumentError);
      expect(() => sendableCopy(Object()), throwsArgumentError);
    });

    test('its copies cross an isolate boundary', () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final message = sendableCopy({
        'list': List<int>.unmodifiable([1, 2]),
      });
      port.sendPort.send(message);
      expect(await port.first, {
        'list': [1, 2],
      });
    });
  });

  test('samples survive packing', () {
    final samples = Float32List.fromList([0, 0.25, -1, 1]);
    expect(unpackSamples(packSamples(samples)), samples);
    expect(unpackSamples([0.1, 0.2]), isNull);
    expect(unpackSamples(null), isNull);
  });

  group(IsolateNameServerDirectory, () {
    const name = 'segno.test.directory';
    const directory = IsolateNameServerDirectory();

    test('publishing replaces a stale port under the same name', () {
      final stale = ReceivePort();
      final fresh = ReceivePort();
      addTearDown(stale.close);
      addTearDown(fresh.close);

      directory
        ..publish(name, stale.sendPort)
        ..publish(name, fresh.sendPort);

      expect(directory.lookup(name), fresh.sendPort);
    });
  });
}
