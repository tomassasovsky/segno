import 'package:equatable/equatable.dart';
import 'package:segno_engine/segno_engine.dart';

/// Why a backing file could not be imported, loaded or staged.
enum BackingFailureReason {
  /// The file is not there (a removed asset, a missing source).
  missing,

  /// The file does not decode, decodes to another length than it states, or
  /// its bytes no longer match its digest.
  damaged,

  /// Outside the decoder's whitelist: not a WAV (16/24/32-bit PCM or 32-bit
  /// float) or an MP3, more than two channels, or a rate it cannot convert.
  unsupported,

  /// Over the 15-minute cap.
  tooLong,

  /// Loading it would leave too little memory, or the backing budget is
  /// full.
  noMemory,

  /// The copy into Internal failed (full, read-only, an I/O error, a drive
  /// that went away).
  storage,

  /// No audio interface is running.
  notRunning,

  /// The engine refused for another reason (a full command ring, a buffer
  /// still in transit after a retry).
  busy;

  /// The reason for a decoder or engine [result].
  static BackingFailureReason fromEngine(EngineResult result) =>
      switch (result) {
        EngineResult.unsupported => unsupported,
        EngineResult.tooLong => tooLong,
        EngineResult.capacity => noMemory,
        EngineResult.notRunning => notRunning,
        EngineResult.invalid => damaged,
        _ => busy,
      };
}

/// A refused import, load or stage, for the UI to explain.
class BackingFailure extends Equatable implements Exception {
  /// Creates a [BackingFailure].
  const BackingFailure(this.reason, {this.name = '', this.digest});

  /// Why.
  final BackingFailureReason reason;

  /// The file's display name, when known.
  final String name;

  /// The asset's digest, when it has one.
  final String? digest;

  @override
  List<Object?> get props => [reason, name, digest];

  @override
  String toString() => 'BackingFailure($reason, $name)';
}
