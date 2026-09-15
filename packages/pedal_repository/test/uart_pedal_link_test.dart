import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/src/uart_pedal_io.dart';

void main() {
  group(UartPedalLink, () {
    late _FakeIo io;
    late List<String> logs;

    setUp(() {
      io = _FakeIo();
      logs = [];
    });

    void dispose(UartPedalLink link, FakeAsync time) {
      unawaited(link.dispose());
      time.flushMicrotasks();
      expect(io.openDescriptors, isEmpty);
      expect(io.unsafeCloses, isEmpty);
      expect(time.nonPeriodicTimerCount, 0);
    }

    test('configures the UART and exchanges framed messages', () {
      fakeAsync((time) {
        final link = UartPedalLink(io: io, log: logs.add);
        final messages = <PedalLinkMessage>[];
        link.inbound.listen(messages.add);
        const message = EncoderMessage(-2);
        link.send(message); // Still configuring: no descriptor yet.
        expect(io.writes, isEmpty);
        time.flushMicrotasks();
        expect(io.configuration, ('/dev/ttyAMA3', 115200));
        expect(io.openedForWriting, [true, false]);
        final bytes = PedalLinkCodec.encode(message);
        io.readers.single
          ..emit(bytes.sublist(0, 2))
          ..emit(bytes.sublist(2));
        time.flushMicrotasks();
        expect(messages, [message]);
        link.send(message);
        expect(io.writes.single, bytes);
        expect(logs.last, contains('open on /dev/ttyAMA3 at 115200'));
        dispose(link, time);
        link.send(message);
        expect(io.writes, hasLength(1));
      });
    });

    test('backs off an absent device to 30 seconds and logs absence once', () {
      fakeAsync((time) {
        io.present = false;
        final link = UartPedalLink(io: io, log: logs.add);
        time.flushMicrotasks();
        expect(io.existsCalls, 1);
        for (final seconds in [2, 4, 8, 16, 30, 30]) {
          final before = io.existsCalls;
          time.elapse(
            Duration(seconds: seconds) - const Duration(milliseconds: 1),
          );
          expect(io.existsCalls, before);
          time.elapse(const Duration(milliseconds: 1));
          expect(io.existsCalls, before + 1);
        }
        expect(logs, hasLength(1));
        expect(io.configuration, isNull);
        dispose(link, time);
        final before = io.existsCalls;
        time.elapse(const Duration(minutes: 2));
        expect(io.existsCalls, before);
      });
    });

    for (final failure in [
      'configuration',
      'write-open',
      'read-open',
      'reader',
    ]) {
      test('cleans up and retries after $failure fails', () {
        fakeAsync((time) {
          io.failure = failure;
          final link = UartPedalLink(io: io, log: logs.add);
          time.flushMicrotasks();
          expect(io.openDescriptors, isEmpty);
          expect(logs.last, contains('opening /dev/ttyAMA3 failed'));
          io.failure = null;
          time.elapse(const Duration(seconds: 2));
          expect(io.readers, hasLength(1));
          expect(io.openDescriptors, hasLength(2));
          dispose(link, time);
        });
      });
    }

    test('times out configuration and retries without opening descriptors', () {
      fakeAsync((time) {
        io.configureGate = Completer<void>();
        final link = UartPedalLink(io: io, log: logs.add);
        time.elapse(const Duration(seconds: 5));
        expect(logs.last, contains('TimeoutException'));
        expect(io.openDescriptors, isEmpty);
        io.configureGate = null;
        time.elapse(const Duration(seconds: 2));
        expect(io.readers, hasLength(1));
        dispose(link, time);
      });
    });

    test('recovers from read errors and forgets an incomplete old frame', () {
      fakeAsync((time) {
        final link = UartPedalLink(io: io, log: logs.add);
        final messages = <PedalLinkMessage>[];
        link.inbound.listen(messages.add);
        time.flushMicrotasks();
        const message = EncoderMessage(3);
        final frame = PedalLinkCodec.encode(message);
        io.readers.single
          ..emit(frame.sublist(0, 3))
          ..fail();
        time.flushMicrotasks();
        expect(io.openDescriptors, isEmpty);
        expect(io.readers.single.stopped, isTrue);
        time.elapse(const Duration(seconds: 2));
        io.readers.last.emit(frame);
        time.flushMicrotasks();
        expect(messages, [message]);
        expect(logs.any((line) => line.contains('read from')), isTrue);
        dispose(link, time);
      });
    });

    test('recovers when the reader exits without a read error', () {
      fakeAsync((time) {
        final link = UartPedalLink(io: io, log: logs.add);
        time.flushMicrotasks();
        io.readers.single.exit();
        time.flushMicrotasks();
        expect(io.openDescriptors, isEmpty);
        expect(logs.last, contains('reader stopped unexpectedly'));
        time.elapse(const Duration(seconds: 2));
        expect(io.readers, hasLength(2));
        dispose(link, time);
      });
    });

    for (final throws in [false, true]) {
      test('recovers after a ${throws ? 'throwing' : 'short'} write', () {
        fakeAsync((time) {
          final link = UartPedalLink(io: io);
          time.flushMicrotasks();
          io
            ..shortWrite = !throws
            ..writeThrows = throws;
          link.send(const EncoderMessage(1));
          time.flushMicrotasks();
          expect(io.openDescriptors, isEmpty);
          time.elapse(const Duration(seconds: 2));
          io
            ..shortWrite = false
            ..writeThrows = false;
          link.send(const EncoderMessage(2));
          expect(
            io.writes.last,
            PedalLinkCodec.encode(const EncoderMessage(2)),
          );
          dispose(link, time);
        });
      });
    }

    test('resets retry delay after a successful connection', () {
      fakeAsync((time) {
        io.present = false;
        final link = UartPedalLink(io: io);
        time.elapse(const Duration(seconds: 6)); // Next attempt is in 8 s.
        io.present = true;
        time.elapse(const Duration(seconds: 8));
        io.readers.single.fail();
        time
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 2));
        expect(io.readers, hasLength(2));
        dispose(link, time);
      });
    });

    test('logs noisy-line edges without logging every corrupt frame', () {
      fakeAsync((time) {
        final link = UartPedalLink(io: io, log: logs.add);
        time.flushMicrotasks();
        final valid = PedalLinkCodec.encode(const EncoderMessage(1));
        final corrupt = Uint8List.fromList(valid)..[valid.length - 1] ^= 1;
        io.readers.single
          ..emit(corrupt)
          ..emit(corrupt);
        time.flushMicrotasks();
        expect(
          logs.where((line) => line.contains('dropping frames')),
          hasLength(1),
        );
        io.readers.single.emit(valid);
        time.flushMicrotasks();
        expect(logs.last, contains('2 frame(s) dropped'));
        dispose(link, time);
      });
    });

    test(
      'disposal waits for pending configuration without opening the UART',
      () {
        fakeAsync((time) {
          final gate = Completer<void>();
          io.configureGate = gate;
          final link = UartPedalLink(io: io);
          var disposed = false;
          unawaited(link.dispose().then((_) => disposed = true));
          time.flushMicrotasks();
          expect(disposed, isFalse);
          gate.complete();
          time.flushMicrotasks();
          expect(disposed, isTrue);
          expect(io.openedForWriting, isEmpty);
          dispose(link, time);
        });
      },
    );

    test(
      'disposal waits for a pending reader before releasing descriptors',
      () {
        fakeAsync((time) {
          final gate = Completer<void>();
          io.readerGate = gate;
          final link = UartPedalLink(io: io);
          time.flushMicrotasks();
          var disposed = false;
          unawaited(link.dispose().then((_) => disposed = true));
          time.flushMicrotasks();
          expect(disposed, isFalse);
          expect(io.openDescriptors, hasLength(2));
          gate.complete();
          time.flushMicrotasks();
          expect(disposed, isTrue);
          expect(io.readers.single.stopped, isTrue);
          dispose(link, time);
        });
      },
    );

    test(
      'overlapping failures and disposal share termination and never reopen',
      () {
        fakeAsync((time) {
          final link = UartPedalLink(io: io);
          time.flushMicrotasks();
          final reader = io.readers.single;
          final stop = Completer<void>();
          reader.stopGate = stop;
          io.shortWrite = true;
          link.send(const EncoderMessage(1));
          reader.fail();
          time.flushMicrotasks();
          expect(reader.stopCalls, 1);
          expect(io.openDescriptors, hasLength(2));
          var disposed = false;
          final first = link.dispose();
          expect(identical(first, link.dispose()), isTrue);
          unawaited(first.then((_) => disposed = true));
          link.send(const EncoderMessage(2));
          time.flushMicrotasks();
          expect(disposed, isFalse);
          expect(io.writes, hasLength(1));
          stop.complete();
          time.flushMicrotasks();
          expect(disposed, isTrue);
          expect(reader.stopCalls, 1);
          dispose(link, time);
          time.elapse(const Duration(minutes: 2));
          expect(io.readers, hasLength(1));
        });
      },
    );
  });
}

/// A controllable OS boundary; it records ownership, not the link's retry or
/// parsing logic. The production connection state machine runs in every test.
class _FakeIo implements UartPedalIo {
  bool present = true;
  int existsCalls = 0;
  String? failure;
  (String, int)? configuration;
  Completer<void>? configureGate;
  Completer<void>? readerGate;
  int _nextFd = 10;
  final openDescriptors = <int>{};
  final openedForWriting = <bool>[];
  final readers = <_FakeReader>[];
  final unsafeCloses = <int>[];
  final writes = <Uint8List>[];
  bool shortWrite = false;
  bool writeThrows = false;

  @override
  bool exists(String device) {
    existsCalls++;
    return present;
  }

  @override
  Future<void> configure(String device, int baud) async {
    configuration = (device, baud);
    if (failure == 'configuration') throw StateError('configuration failed');
    await configureGate?.future;
  }

  @override
  int open(String device, {required bool forWriting}) {
    openedForWriting.add(forWriting);
    if (failure == (forWriting ? 'write-open' : 'read-open')) return -1;
    final fd = _nextFd++;
    openDescriptors.add(fd);
    return fd;
  }

  @override
  Future<UartPedalReader> startReader(int fd) async {
    if (failure == 'reader') throw StateError('reader spawn failed');
    final reader = _FakeReader(fd);
    readers.add(reader);
    await readerGate?.future;
    return reader;
  }

  @override
  int write(int fd, Uint8List bytes) {
    if (!openDescriptors.contains(fd)) throw StateError('closed descriptor');
    if (writeThrows) throw StateError('write failed');
    writes.add(bytes);
    return shortWrite ? bytes.length - 1 : bytes.length;
  }

  @override
  void close(int fd) {
    if (readers.any((reader) => reader.fd == fd && !reader.stopped)) {
      unsafeCloses.add(fd);
    }
    if (!openDescriptors.remove(fd)) {
      throw StateError('descriptor closed twice');
    }
  }
}

class _FakeReader implements UartPedalReader {
  _FakeReader(this.fd);
  final int fd;
  // Complete cancellation in the test's clock zone instead of returning the
  // SDK's shared null future, which can have been created outside fakeAsync.
  final _chunks = StreamController<Uint8List>(
    onCancel: Future<void>.value,
  );
  Completer<void>? stopGate;
  bool stopped = false;
  int stopCalls = 0;

  void emit(List<int> bytes) => _chunks.add(Uint8List.fromList(bytes));
  void fail() => _chunks.addError(StateError('read failed'));
  void exit() => unawaited(_chunks.close());

  @override
  Stream<Uint8List> get bytes => _chunks.stream;

  @override
  Future<void> stop() async {
    stopCalls++;
    await stopGate?.future;
    stopped = true;
    unawaited(_chunks.close());
  }
}
