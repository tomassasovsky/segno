import 'dart:io';
import 'dart:typed_data';

import 'package:backing_repository/backing_repository.dart';
import 'package:segno_engine/segno_engine.dart';

/// A stand-in digest for tests: 64 hex digits from eight 32-bit FNV-1a runs
/// with different seeds over the file's bytes. Not SHA-256, but equal bytes
/// give equal digests and any change gives another, which is all the store
/// relies on. The real one is covered by `native_store_test.dart`.
Future<String?> fakeDigest(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  final out = StringBuffer();
  for (var seed = 0; seed < 8; seed++) {
    var h = 0x811c9dc5 ^ seed;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    out.write(h.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}

/// A decoder that reads its verdict from the file: `rate=R;frames=F` (and an
/// optional `;channels=C`) decodes, `fail=<result name>` refuses. Delegates
/// the decode itself to a [MockAudioDecoder], so frees are counted.
class ContentDecoder implements AudioDecoder {
  /// The decoder doing the work and counting buffers.
  final MockAudioDecoder mock = MockAudioDecoder();

  /// Probes run.
  int probes = 0;

  /// A hook run before each decode completes (a test seam for races).
  Future<void> Function()? beforeDecode;

  void _register(String path) {
    final text = File(path).existsSync() ? File(path).readAsStringSync() : '';
    final fields = <String, String>{
      for (final part in text.split(';'))
        if (part.contains('='))
          part.split('=').first.trim(): part.split('=').last.trim(),
    };
    final fail = fields['fail'];
    mock.files[path] = fail != null
        ? MockAudioFile.refused(EngineResult.values.byName(fail))
        : MockAudioFile(
            sourceRate: int.parse(fields['rate'] ?? '48000'),
            sourceFrames: int.parse(fields['frames'] ?? '100'),
            channels: int.parse(fields['channels'] ?? '2'),
          );
  }

  @override
  Future<DecodedAudio> decode(
    String path, {
    required int sampleRate,
    int startFrame = 0,
    int maxFrames = 0,
  }) async {
    if (File(path).existsSync()) _register(path);
    await beforeDecode?.call();
    return mock.decode(
      path,
      sampleRate: sampleRate,
      startFrame: startFrame,
      maxFrames: maxFrames,
    );
  }

  @override
  Future<AudioProbe> probe(String path, {int buckets = 512}) {
    probes++;
    if (File(path).existsSync()) _register(path);
    return mock.probe(path, buckets: buckets);
  }
}

/// A copier into [root] that records its calls and can be told to fail or
/// to write other bytes than the source.
class FakeCopier {
  /// Creates a [FakeCopier] writing under [root].
  FakeCopier(this.root);

  /// The Internal root.
  final String root;

  /// Calls, as relative paths.
  final List<String> calls = [];

  /// When set, every copy throws this.
  Exception? failWith;

  /// When set, the copy holds these bytes instead of the source's.
  List<int>? corruptTo;

  /// The [BackingCopier].
  Future<String> call(String source, String relative) async {
    calls.add(relative);
    final failure = failWith;
    if (failure != null) throw failure;
    final target = File('$root/$relative')..parent.createSync(recursive: true);
    final bytes = corruptTo;
    if (bytes != null) {
      target.writeAsBytesSync(bytes);
    } else {
      File(source).copySync(target.path);
    }
    return target.path;
  }
}

/// An engine that answers NOT_READY to the next [notReadyCount] loads and
/// stages, then behaves like the [MockAudioEngine] it wraps: the repository's
/// one retry.
class NotReadyEngine implements BackingControl {
  /// Wraps [inner].
  NotReadyEngine(this.inner);

  /// The engine doing the work.
  final MockAudioEngine inner;

  /// How many hand-offs to refuse.
  int notReadyCount = 0;

  /// What to answer instead of NOT_READY, when set: any refusal.
  EngineResult? refuseWith;

  int _handoffs = 0;

  /// Hand-offs attempted.
  int get handoffs => _handoffs;

  /// Settings writes (End, level, pan, output), in order.
  final List<String> settings = [];

  /// Added to the inner engine's epoch: a retained reopen, which keeps the
  /// loaded file, without a real device.
  int extraEpoch = 0;

  EngineResult _gate(EngineResult Function() go) {
    _handoffs++;
    final refusal = refuseWith;
    if (refusal != null) return refusal;
    if (notReadyCount > 0) {
      notReadyCount--;
      return EngineResult.notReady;
    }
    return go();
  }

  @override
  EngineResult backingLoad(
    DecodedAudio audio, {
    required int item,
    required bool play,
  }) => _gate(() => inner.backingLoad(audio, item: item, play: play));

  @override
  EngineResult backingStageNext(DecodedAudio? audio, {required int item}) =>
      audio == null
      ? inner.backingStageNext(null, item: item)
      : _gate(() => inner.backingStageNext(audio, item: item));

  @override
  EngineResult backingClear() => inner.backingClear();

  @override
  EngineResult backingTransport(BackingTransportOp op) =>
      inner.backingTransport(op);

  @override
  EngineResult backingSeek(int frame) => inner.backingSeek(frame);

  @override
  EngineResult setBackingEnd(BackingEnd mode) {
    settings.add('end ${mode.name}');
    return inner.setBackingEnd(mode);
  }

  @override
  EngineResult setBackingOutput(int mask) {
    settings.add('output $mask');
    return inner.setBackingOutput(mask);
  }

  @override
  EngineResult setBackingLevel(double gain) {
    settings.add('level $gain');
    return inner.setBackingLevel(gain);
  }

  @override
  EngineResult setBackingPan(double pan) {
    settings.add('pan $pan');
    return inner.setBackingPan(pan);
  }

  @override
  EngineResult setClickPan(double pan) => inner.setClickPan(pan);

  @override
  BackingState backingState() {
    final s = inner.backingState();
    if (extraEpoch == 0) return s;
    return BackingState(
      epoch: s.epoch + extraEpoch,
      item: s.item,
      nextItem: s.nextItem,
      transport: s.transport,
      position: s.position,
      frames: s.frames,
      endCount: s.endCount,
      lastEnd: s.lastEnd,
      endMode: s.endMode,
      outputMask: s.outputMask,
      level: s.level,
      pan: s.pan,
      clickPan: s.clickPan,
      owned: s.owned,
      ownedBytes: s.ownedBytes,
    );
  }
}

/// Writes a decodable test file (see [ContentDecoder]) and returns its path.
String writeAudio(
  Directory dir,
  String name, {
  int rate = 48000,
  int frames = 100,
  String? fail,
  String tag = '',
}) {
  return (File('${dir.path}/$name')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          fail != null
              ? 'fail=$fail;$tag'
              : 'rate=$rate;frames=$frames;tag=$tag',
        ))
      .path;
}

/// [frames] as bytes of stereo float, for comparing with `ownedBytes`.
int stereoBytes(int frames) => frames * 2 * Float32List.bytesPerElement;
