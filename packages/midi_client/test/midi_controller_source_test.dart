import 'dart:ffi';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';

import 'helpers/fake_segno_engine_bindings.dart';

/// MIDI status bytes (channel 0) used across the cases.
const int _noteOn = 0x90;
const int _noteOff = 0x80;
const int _cc = 0xB0;

void main() {
  group('MidiControllerSource', () {
    late FakeSegnoEngineBindings bindings;
    late MidiControllerSource source;

    MidiControllerSource build({
      List<MidiDevice> devices = const [],
      int openResult = 0,
    }) {
      bindings = FakeSegnoEngineBindings(
        devices: devices,
        openResult: openResult,
      );
      source = MidiControllerSource(
        client: MidiClient(bindings: bindings),
      );
      addTearDown(source.dispose);
      source.open('test-device');
      return source;
    }

    group('parsing', () {
      test('Control Change -> midiCc with value', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_cc, 80, 127);
        await pumpEventQueue();

        expect(received, const [
          RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: 80,
            value: 127,
          ),
        ]);
        expect(received.single.isPress, isTrue);
        await sub.cancel();
      });

      test('Note On -> midiNote with velocity', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOn, 60, 100);
        await pumpEventQueue();

        expect(received, const [
          RawControllerInput(
            kind: ControllerSourceKind.midiNote,
            id: 60,
            value: 100,
          ),
        ]);
        await sub.cancel();
      });

      test('Note On with velocity 0 maps to a release (value 0)', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOn, 60, 0);
        await pumpEventQueue();

        expect(received.single.value, 0);
        expect(received.single.isPress, isFalse);
        await sub.cancel();
      });

      test('Note Off maps to value 0', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOff, 60, 64);
        await pumpEventQueue();

        expect(received.single.value, 0);
        await sub.cancel();
      });

      test('carries the channel from the status low nibble', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        // CC on channel 9 (0xB9). The channel rides along so a learned
        // controller binding can scope itself to it...
        source.pushForTest(0xB9, 80, 127);
        await pumpEventQueue();

        expect(received.single.id, 80);
        expect(received.single.kind, ControllerSourceKind.midiCc);
        expect(received.single.midiChannel, 9);
        // ...while the trigger identity the built-in action mappings key on
        // stays channel-agnostic.
        expect(received.single.trigger.midiChannel, isNull);
        expect(received.single.channelTrigger.midiChannel, 9);
        await sub.cancel();
      });

      test('channel 0 is reported as 0, never as absent', () async {
        build();
        final received = <RawControllerInput>[];
        final sub = source.inputs.listen(received.add);

        source.pushForTest(_noteOn, 60, 100);
        await pumpEventQueue();

        expect(received.single.midiChannel, 0);
        await sub.cancel();
      });

      test('drops SysEx / real-time / aftertouch / pitch bend', () async {
        build();
        final received = <RawControllerInput>[];
        final activity = <RawControllerInput>[];
        final inputSub = source.inputs.listen(received.add);
        final activitySub = source.activity.listen(activity.add);

        source
          ..pushForTest(0xF0, 0, 0) // SysEx start
          ..pushForTest(0xF8, 0, 0) // timing clock
          ..pushForTest(0xFE, 0, 0) // active sensing
          ..pushForTest(0xA0, 60, 10) // polyphonic aftertouch
          ..pushForTest(0xE0, 0, 64); // pitch bend
        await pumpEventQueue();

        expect(received, isEmpty);
        expect(activity, isEmpty);
        await inputSub.cancel();
        await activitySub.cancel();
      });
    });

    test('rapid same-source press and release are both delivered', () async {
      build();
      final received = <MidiInputMessage>[];
      final sub = source.messages.listen(received.add);
      source
        ..pushForTest(_noteOn, 60, 127, tsUs: 1000000)
        ..pushForTest(_noteOff, 60, 0, tsUs: 1101000)
        ..pushForTest(0xCF, 8, 0);
      await pumpEventQueue();
      expect(received.map((m) => m.input.value), [127, 0, 127]);
      expect(received.take(2).map((m) => m.timestampMicros), [
        1000000,
        1101000,
      ]);
      expect(received.last.input.kind, ControllerSourceKind.midiProgram);
      expect(received.last.input.midiChannel, 15);
      expect(received.every((m) => m.session == source.session), isTrue);
      await sub.cancel();
    });

    test(
      'old native callback cannot enter a switched or reconnected port',
      () async {
        build();
        final oldSession = source.session;
        final oldCallback = bindings.lastOpenedCb!
            .asFunction<void Function(int, int, int, int)>();
        final received = <MidiInputMessage>[];
        final sub = source.messages.listen(received.add);
        oldCallback(0x90, 60, 127, 1);
        source
          ..open('other-device')
          ..pushForTest(0x90, 62, 127);
        await pumpEventQueue();
        expect(received.map((m) => m.input.id), [62]);
        expect(received.single.session.device, 'other-device');
        expect(received.single.session, isNot(oldSession));
        received.clear();
        source.open('test-device');
        await pumpEventQueue();
        expect(received, isEmpty);
        await sub.cancel();
      },
    );

    group('device control', () {
      test('enumerate delegates to the client', () {
        build(
          devices: const [MidiDevice(id: 'uid-1', name: 'Pedal')],
        );
        expect(source.enumerate(), const [
          MidiDevice(id: 'uid-1', name: 'Pedal'),
        ]);
      });

      test('open passes the id and the listener callback to native', () {
        build();
        final result = source.open('uid-1');

        expect(result, 0);
        expect(bindings.lastOpenedId, 'uid-1');
        expect(bindings.lastOpenedCb, isNotNull);
        expect(bindings.calls, contains('open'));
      });

      test('open surfaces the native failure code', () {
        build(openResult: 3);
        expect(source.open('busy'), 3);
      });

      test('close delegates to the client', () {
        build();
        expect(source.close(), 0);
        expect(bindings.calls, contains('close'));
      });
    });

    group('dispose', () {
      test(
        'closes native before destroying, then releases the callable',
        () async {
          build();
          source.open('uid-1');
          expect(source.isDisposed, isFalse);

          await source.dispose();

          expect(source.isDisposed, isTrue);
          // le_midi_close must precede le_midi_destroy so the native side can
          // never call a freed callback (the NativeCallable is closed last).
          final closeIndex = bindings.calls.indexOf('close');
          final destroyIndex = bindings.calls.indexOf('destroy');
          expect(closeIndex, greaterThanOrEqualTo(0));
          expect(destroyIndex, greaterThan(closeIndex));
        },
      );

      test('closes both streams', () async {
        build();
        await source.dispose();
        await expectLater(source.inputs, emitsDone);
        await expectLater(source.activity, emitsDone);
      });

      test('is idempotent', () async {
        build();
        await source.dispose();
        await source.dispose();
        expect(
          bindings.calls.where((c) => c == 'destroy').length,
          1,
        );
      });

      test('a message after dispose emits nothing', () async {
        build();
        final received = <RawControllerInput>[];
        // Subscribe before dispose; the stream then closes.
        final sub = source.inputs.listen(received.add);
        await source.dispose();

        // Pushing post-dispose must be a safe no-op (no add to a closed sink).
        source.pushForTest(_cc, 80, 127);
        await pumpEventQueue();

        expect(received, isEmpty);
        await sub.cancel();
      });
    });
  });
}
