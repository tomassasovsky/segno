import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/backing.dart';
import 'package:segno_engine/src/engine_library.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// Runs [work] off the calling isolate; the default is [Isolate.run].
typedef DecodeRunner = Future<R> Function<R>(R Function() work);

/// The [AudioDecoder] backed by the native engine library
/// (`le_backing_decode_file`, `le_backing_probe_file`).
///
/// Each call opens the library inside a background isolate and decodes
/// there, so the calling isolate never decodes. The decoded samples are a
/// native heap buffer; its address crosses back to the caller, who owns it
/// (see [DecodedAudio]).
class NativeAudioDecoder implements AudioDecoder {
  /// Creates a [NativeAudioDecoder]. [runner] is where the work runs (a test
  /// seam: it defaults to [Isolate.run]); [bindings] are this isolate's, for
  /// copying, peaking and freeing a result.
  NativeAudioDecoder({DecodeRunner? runner, SegnoEngineBindings? bindings})
    : _runner = runner ?? _isolateRun,
      _bindings = bindings ?? SegnoEngineBindings(openSegnoEngineLibrary());

  final DecodeRunner _runner;
  final SegnoEngineBindings _bindings;

  static Future<R> _isolateRun<R>(R Function() work) => Isolate.run(work);

  @override
  Future<DecodedAudio> decode(
    String path, {
    required int sampleRate,
    int startFrame = 0,
    int maxFrames = 0,
  }) async {
    final r = await _runner(
      () => _decodeHere(path, sampleRate, startFrame, maxFrames),
    );
    final result = EngineResult.fromCode(r.code);
    if (!result.isOk) throw EngineException(result, 'decode $path');
    return DecodedAudio(
      frames: r.frames,
      sampleRate: sampleRate,
      info: AudioFileInfo(
        sourceRate: r.sourceRate,
        sourceChannels: r.sourceChannels,
        sourceFrames: r.sourceFrames,
        truncated: r.truncated,
      ),
      payload: NativeDecodedAudioPayload(
        _bindings,
        Pointer<le_backing_buffer>.fromAddress(r.address),
      ),
    );
  }

  @override
  Future<AudioProbe> probe(String path, {int buckets = 512}) async {
    final r = await _runner(() => _probeHere(path, buckets));
    final result = EngineResult.fromCode(r.code);
    if (!result.isOk) throw EngineException(result, 'probe $path');
    return AudioProbe(
      info: AudioFileInfo(
        sourceRate: r.sourceRate,
        sourceChannels: r.sourceChannels,
        sourceFrames: r.sourceFrames,
      ),
      peaks: r.peaks,
    );
  }
}

typedef _Decoded = ({
  int code,
  int address,
  int frames,
  int sourceRate,
  int sourceChannels,
  int sourceFrames,
  bool truncated,
});

typedef _Probed = ({
  int code,
  int sourceRate,
  int sourceChannels,
  int sourceFrames,
  Float32List peaks,
});

/// The decode, in whatever isolate calls it (a background one).
_Decoded _decodeHere(String path, int rate, int start, int max) {
  final b = SegnoEngineBindings(openSegnoEngineLibrary());
  final pathPtr = path.toNativeUtf8();
  final out = calloc<Pointer<le_backing_buffer>>();
  final info = calloc<le_backing_decode_info>();
  try {
    final code = b.le_backing_decode_file(
      pathPtr.cast(),
      rate,
      start,
      max,
      out,
      info,
    );
    return (
      code: code,
      address: out.value.address,
      frames: out.value == nullptr ? 0 : b.le_backing_buffer_frames(out.value),
      sourceRate: info.ref.source_rate,
      sourceChannels: info.ref.source_channels,
      sourceFrames: info.ref.source_frames,
      truncated: info.ref.truncated != 0,
    );
  } finally {
    calloc
      ..free(info)
      ..free(out);
    malloc.free(pathPtr);
  }
}

/// The probe, in whatever isolate calls it.
_Probed _probeHere(String path, int buckets) {
  final b = SegnoEngineBindings(openSegnoEngineLibrary());
  final pathPtr = path.toNativeUtf8();
  final info = calloc<le_backing_decode_info>();
  final n = buckets < 0 ? 0 : buckets;
  final peaks = calloc<Float>(n == 0 ? 1 : n);
  try {
    final code = b.le_backing_probe_file(pathPtr.cast(), info, peaks, n);
    return (
      code: code,
      sourceRate: info.ref.source_rate,
      sourceChannels: info.ref.source_channels,
      sourceFrames: info.ref.source_frames,
      peaks: Float32List.fromList(peaks.asTypedList(n)),
    );
  } finally {
    calloc
      ..free(peaks)
      ..free(info);
    malloc.free(pathPtr);
  }
}

/// A native decode's buffer. `NativeAudioEngine` hands [buffer] to the
/// engine; everything else goes through [DecodedAudio].
///
/// A native finalizer frees the buffer if the payload is dropped while still
/// owned (an exception between a decode and its hand-over, an engine already
/// disposed): the explicit protocol stays primary, the finalizer only bounds
/// the damage of a missed path (review of P3, L2). It is detached when the
/// engine takes the buffer and when [free] runs.
@internal
class NativeDecodedAudioPayload implements DecodedAudioPayload, Finalizable {
  /// Wraps [buffer], read and freed through [_bindings].
  NativeDecodedAudioPayload(this._bindings, this.buffer) {
    if (buffer != nullptr) {
      _finalizer.attach(this, buffer.cast(), detach: this);
      _attached = true;
    }
  }

  /// One finalizer for the process: `le_backing_buffer_free` from the
  /// engine library.
  static final NativeFinalizer _finalizer = NativeFinalizer(
    openSegnoEngineLibrary().lookup<NativeFinalizerFunction>(
      'le_backing_buffer_free',
    ),
  );

  bool _attached = false;

  /// Whether the finalizer still guards the buffer.
  @visibleForTesting
  bool get finalizerAttached => _attached;

  final SegnoEngineBindings _bindings;

  /// The engine-ready buffer.
  final Pointer<le_backing_buffer> buffer;

  @override
  Float32List copySamples(int frames) => Float32List.fromList(
    _bindings.le_backing_buffer_pcm(buffer).asTypedList(frames * 2),
  );

  @override
  Float32List peaks(int buckets) {
    if (buckets <= 0) return Float32List(0);
    final out = calloc<Float>(buckets);
    try {
      _bindings.le_backing_buffer_peaks(buffer, out, buckets);
      return Float32List.fromList(out.asTypedList(buckets));
    } finally {
      calloc.free(out);
    }
  }

  @override
  void free() {
    detach();
    _bindings.le_backing_buffer_free(buffer);
  }

  @override
  void detach() {
    if (!_attached) return;
    _attached = false;
    _finalizer.detach(this);
  }
}
