import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/waveform_window_channel.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

class _Delivery {
  _Delivery(this.payload);

  final Map<Object?, Object?> payload;
  final result = Completer<Object?>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(DesktopMultiWindowWaveformService, () {
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late DesktopMultiWindowWaveformService service;
    late List<_Delivery> deliveries;
    late Completer<void> created;

    Future<void> ready() async {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        channels.name,
        codec.encodeMethodCall(
          MethodCall('methodCall', {
            'channel': waveformWindowChannel.name,
            'method': waveformWindowReadyMethod,
            'arguments': null,
          }),
        ),
        reply.complete,
      );
      codec.decodeEnvelope((await reply.future)!);
    }

    Future<void> open() async {
      created = Completer<void>();
      final opening = service.open();
      await created.future;
      await Future<void>.delayed(Duration.zero);
      await ready();
      expect(await opening, isTrue);
    }

    setUp(() async {
      service = DesktopMultiWindowWaveformService();
      deliveries = [];
      messenger
        ..setMockMethodCallHandler(windows, (call) async {
          switch (call.method) {
            case 'getWindowDefinition':
              return {'windowId': 'main', 'windowArgument': ''};
            case 'getAllWindows':
              return <Object?>[];
            case 'createWindow':
              created.complete();
              return 'waveform';
            case 'window_show':
              return null;
            default:
              throw StateError('Unexpected window call: ${call.method}');
          }
        })
        ..setMockMethodCallHandler(channels, (call) async {
          if (call.method == 'registerMethodHandler') return null;
          final args = call.arguments as Map<Object?, Object?>;
          if (args['method'] == 'window_close') return null;
          expect(call.method, 'invokeMethod');
          expect(args['channel'], waveformWindowChannel.name);
          expect(args['method'], anyOf('waveform', 'readout'));
          final delivery = _Delivery(
            args['arguments']! as Map<Object?, Object?>,
          );
          deliveries.add(delivery);
          return delivery.result.future;
        });
      await open();
    });

    tearDown(() async {
      for (final delivery in deliveries) {
        if (!delivery.result.isCompleted) delivery.result.complete();
      }
      await Future<void>.delayed(Duration.zero);
      await service.close();
      service
        ..onWindowReady = null
        ..onControl = null;
      messenger
        ..setMockMethodCallHandler(windows, null)
        ..setMockMethodCallHandler(channels, null);
    });

    for (final waveform in [true, false]) {
      group(waveform ? 'waveform samples' : 'readout', () {
        Future<void> push(int value) => waveform
            ? service.pushWaveform(
                Float32List.fromList([value.toDouble()]),
                0.5,
                'Track',
              )
            : service.pushReadout(PerformanceReadout(elapsedSeconds: value));

        void expectFull(_Delivery delivery, int value) {
          expect(
            delivery.payload[waveform ? 'samples' : 'elapsedSeconds'],
            waveform ? Float32List.fromList([value.toDouble()]) : value,
          );
        }

        Future<void> expectAcknowledged(int value) async {
          final count = deliveries.length;
          final sent = push(value);
          await Future<void>.delayed(Duration.zero);
          if (waveform) {
            expect(deliveries, hasLength(count + 1));
            expect(deliveries.last.payload.containsKey('samples'), isFalse);
            deliveries.last.result.complete();
          } else {
            expect(deliveries, hasLength(count));
          }
          await sent;
        }

        test(
          'an equal follower carries data until delivery is acknowledged',
          () async {
            final first = push(1);
            final rejected = expectLater(first, throwsA(isA<Exception>()));
            await Future<void>.delayed(Duration.zero);
            final second = push(1);
            await Future<void>.delayed(Duration.zero);
            expect(deliveries, hasLength(2));
            expectFull(deliveries[0], 1);
            expectFull(deliveries[1], 1);

            deliveries[1].result.complete();
            await second;
            deliveries[0].result.completeError(PlatformException(code: 'lost'));
            await rejected;
            await expectAcknowledged(1);
          },
        );

        test(
          'a revert carries data and ignores an old acknowledgement',
          () async {
            final seed = push(1);
            await Future<void>.delayed(Duration.zero);
            deliveries.single.result.complete();
            await seed;

            final replacement = push(2);
            await Future<void>.delayed(Duration.zero);
            final revert = push(1);
            await Future<void>.delayed(Duration.zero);
            expect(deliveries, hasLength(3));
            expectFull(deliveries.last, 1);
            deliveries[2].result.complete();
            await revert;
            deliveries[1].result.complete();
            await replacement;
            await expectAcknowledged(1);
          },
        );

        test('a failed latest send is retried with its payload', () async {
          final first = push(1);
          final rejected = expectLater(first, throwsA(isA<Exception>()));
          await Future<void>.delayed(Duration.zero);
          deliveries.single.result.completeError(
            PlatformException(code: 'lost'),
          );
          await rejected;
          final retry = push(1);
          await Future<void>.delayed(Duration.zero);
          expectFull(deliveries.last, 1);
          deliveries.last.result.complete();
          await retry;
        });

        for (final reopen in [false, true]) {
          test(
            'a late reply cannot seed a '
            '${reopen ? 'reopened' : 'reannounced'} window',
            () async {
              final old = push(1);
              await Future<void>.delayed(Duration.zero);
              if (reopen) {
                await service.close();
                await open();
              } else {
                await ready();
              }
              deliveries.single.result.complete();
              await old;
              final fresh = push(1);
              await Future<void>.delayed(Duration.zero);
              expect(deliveries, hasLength(2));
              expectFull(deliveries.last, 1);
              deliveries.last.result.complete();
              await fresh;
            },
          );
        }
      });
    }
  });
}
