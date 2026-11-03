import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:midi_client/midi_client.dart';

/// The factory `MidiDeviceRepository` opens one native capture per device
/// with, kept deliberately separate from audio bootstrap so the MIDI
/// lifecycle is fully independent of the audio engine ("losing MIDI never
/// restarts audio").
///
/// Building a capture opens the native MIDI library; on a build/platform with
/// no MIDI backend (or a flavor where the native library is absent) it throws,
/// so this probes once and returns `null` rather than aborting launch — the
/// looper stays fully usable without MIDI and the page shows its empty state.
MidiControllerSource Function()? nativeMidiCaptures({
  MidiControllerSource Function()? factory,
}) {
  final create = factory ?? MidiControllerSource.new;
  try {
    unawaited(create().dispose());
    return create;
  } on Object catch (error, stackTrace) {
    // A missing/unsupported native MIDI backend is non-fatal: log and run on.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'segno',
        context: ErrorDescription('creating the native MIDI source'),
      ),
    );
    return null;
  }
}
