import 'package:segno_engine/segno_engine.dart';

/// The native decoder, so an app entrypoint can wire one without importing
/// the engine package.
AudioDecoder createNativeAudioDecoder() => NativeAudioDecoder();

/// The hardware-free decoder for the mock flavor.
AudioDecoder createMockAudioDecoder() => MockAudioDecoder();
