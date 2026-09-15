import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/src/uart_pedal_io.dart';

void main() {
  group(NativeUartPedalIo, () {
    late _CountingAllocator allocator;
    late NativeUartPedalIo io;

    setUp(() {
      allocator = _CountingAllocator();
      io = NativeUartPedalIo(allocator: allocator);
    });

    test(
      'releases the temporary write buffer even when libc rejects the fd',
      () {
        expect(io.write(-1, Uint8List.fromList([1, 2])), -1);
        expect(allocator.allocations, 1);
        expect(allocator.frees, 1);
        expect(allocator.live, isEmpty);
      },
    );

    test(
      'reads real pipe bytes and frees each killed reader buffer once',
      () async {
        // Pipes use the same read/write syscalls without touching a device. EOF
        // releases a blocking pipe read before stop; the UART has VTIME.
        for (var attempt = 0; attempt < 3; attempt++) {
          final (readFd, writeFd) = _pipe();
          final reader = await io.startReader(readFd);
          expect(allocator.live, hasLength(1));
          final received = reader.bytes.first;
          final bytes = Uint8List.fromList([1, 2, attempt]);
          expect(io.write(writeFd, bytes), bytes.length);
          expect(await received.timeout(const Duration(seconds: 5)), bytes);
          io.close(writeFd);
          final stopped = reader.stop();
          expect(identical(stopped, reader.stop()), isTrue);
          await stopped.timeout(const Duration(seconds: 5));
          expect(allocator.live, isEmpty);
          io.close(readFd);
        }
        // One reader allocation and one temporary write allocation per round.
        expect(allocator.allocations, 6);
        expect(allocator.frees, allocator.allocations);
      },
    );

    test(
      'stops and frees the reader even if nobody subscribed to its bytes',
      () async {
        final (readFd, writeFd) = _pipe();
        final reader = await io.startReader(readFd);
        io.close(writeFd);
        await reader.stop().timeout(const Duration(seconds: 5));
        expect(allocator.live, isEmpty);
        expect(allocator.frees, 1);
        io.close(readFd);
      },
    );
  }, skip: !Platform.isLinux && !Platform.isMacOS);
}

/// Counts actual native ownership while delegating allocation to libc.
class _CountingAllocator implements Allocator {
  final live = <int>{};
  int allocations = 0;
  int frees = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final pointer = malloc.allocate<T>(byteCount, alignment: alignment);
    live.add(pointer.address);
    allocations++;
    return pointer;
  }

  @override
  void free(Pointer<NativeType> pointer) {
    if (!live.remove(pointer.address)) {
      throw StateError('native buffer freed twice or by the wrong owner');
    }
    frees++;
    malloc.free(pointer);
  }
}

(int, int) _pipe() {
  final pipe = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Int32>),
        int Function(Pointer<Int32>)
      >('pipe');
  final descriptors = calloc<Int32>(2);
  try {
    if (pipe(descriptors) != 0) throw StateError('creating a pipe failed');
    return (descriptors[0], descriptors[1]);
  } finally {
    calloc.free(descriptors);
  }
}
