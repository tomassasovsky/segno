import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:segno_engine/src/ffi_strings.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// Requested audio device configuration passed to `AudioEngine.start`.
///
/// Any field left at `0` defers to the device default. This is the pure-Dart
/// counterpart of the native `le_config` struct.
@immutable
class EngineConfig {
  /// Creates an [EngineConfig].
  const EngineConfig({
    this.sampleRate = 0,
    this.bufferFrames = 0,
    this.inputChannels = 0,
    this.outputChannels = 0,
    this.maxLoopFrames = 0,
    this.useLoopbackCapture = false,
    this.playbackDeviceId = '',
    this.captureDeviceId = '',
    this.keepMaterial = false,
  });

  /// Requested sample rate in Hz, or `0` for the device default.
  final int sampleRate;

  /// Requested period (buffer) size in frames, or `0` for the device default.
  ///
  /// Smaller values reduce latency at the cost of xrun risk.
  final int bufferFrames;

  /// Requested hardware capture channel count, or `0` for the device default.
  /// Clamped to the engine maximum.
  final int inputChannels;

  /// Requested hardware playback channel count, or `0` for the device default.
  /// Clamped to the engine maximum.
  final int outputChannels;

  /// Per-track loop buffer cap in frames, or `0` for the engine default
  /// (about two minutes at the device sample rate).
  final int maxLoopFrames;

  /// Whether the engine should capture from a detected loopback device (so
  /// latency can be measured without a physical cable). No effect when no
  /// loopback is detected.
  final bool useLoopbackCapture;

  /// The id of the playback device to open (an `AudioDevice.id` from
  /// `AudioEngine.enumerateDevices`), or the empty string for the system
  /// default (the unchanged behaviour).
  final String playbackDeviceId;

  /// The id of the capture device to open, or the empty string for the system
  /// default. Ignored when [useLoopbackCapture] resolves a loopback device.
  final String captureDeviceId;

  /// For `AudioEngine.reopen` only: refuse a reopen that would clear the
  /// recorded loops (the device negotiated another sample rate or loop cap)
  /// instead of clearing them. `AudioEngine.start` ignores it.
  final bool keepMaterial;

  /// Writes this configuration into a native [le_config] struct in [ptr].
  void writeTo(Pointer<le_config> ptr) {
    ptr.ref
      ..sample_rate = sampleRate
      ..buffer_frames = bufferFrames
      ..input_channels = inputChannels
      ..output_channels = outputChannels
      ..max_loop_frames = maxLoopFrames
      ..use_loopback_capture = useLoopbackCapture ? 1 : 0
      ..keep_material = keepMaterial ? 1 : 0;
    writeNativeString(ptr.ref.playback_device_id, playbackDeviceId);
    writeNativeString(ptr.ref.capture_device_id, captureDeviceId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineConfig &&
          runtimeType == other.runtimeType &&
          sampleRate == other.sampleRate &&
          bufferFrames == other.bufferFrames &&
          inputChannels == other.inputChannels &&
          outputChannels == other.outputChannels &&
          maxLoopFrames == other.maxLoopFrames &&
          useLoopbackCapture == other.useLoopbackCapture &&
          playbackDeviceId == other.playbackDeviceId &&
          captureDeviceId == other.captureDeviceId &&
          keepMaterial == other.keepMaterial;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    bufferFrames,
    inputChannels,
    outputChannels,
    maxLoopFrames,
    useLoopbackCapture,
    playbackDeviceId,
    captureDeviceId,
    keepMaterial,
  );

  @override
  String toString() =>
      'EngineConfig(sampleRate: $sampleRate, '
      'bufferFrames: $bufferFrames, inputChannels: $inputChannels, '
      'outputChannels: $outputChannels, '
      'maxLoopFrames: $maxLoopFrames, '
      'useLoopbackCapture: $useLoopbackCapture, '
      'playbackDeviceId: $playbackDeviceId, '
      'captureDeviceId: $captureDeviceId, '
      'keepMaterial: $keepMaterial)';
}
