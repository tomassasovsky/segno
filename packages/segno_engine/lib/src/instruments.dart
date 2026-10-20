import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// The number of instrument slots, mirroring the native `LE_MAX_INSTRUMENTS`.
const int kMaxInstruments = LE_MAX_INSTRUMENTS;

/// The source index of instrument slot 0: slot `k` is source
/// `kInstrumentSourceBase + k` wherever a source is named (monitors, lane
/// routing, meters). Mirrors the native `LE_INSTRUMENT_SOURCE_BASE`.
const int kInstrumentSourceBase = LE_INSTRUMENT_SOURCE_BASE;

/// The highest voice limit the engine accepts (its pool size), mirroring the
/// native `LE_INST_MAX_VOICES`.
const int kMaxVoiceLimit = LE_INST_MAX_VOICES;

/// The notes one chord note-on carries, mirroring the native
/// `LE_INST_CHORD_NOTES`.
const int kMaxChordNotes = LE_INST_CHORD_NOTES;

/// The engine's MIDI input ports, mirroring the native `LE_MAX_MIDI_PORTS`.
const int kMaxMidiPorts = LE_MAX_MIDI_PORTS;

/// Remaps per instrument, mirroring the native `LE_INST_MAX_REMAPS`.
const int kMaxInstrumentRemaps = LE_INST_MAX_REMAPS;

/// Notes one remap plays, mirroring the native `LE_INST_REMAP_NOTES`.
const int kMaxRemapNotes = LE_INST_REMAP_NOTES;

/// What a remap matches.
enum MidiRemapKind {
  /// A note number (Note On starts the chord, its Note Off releases it).
  note,

  /// A controller number (64 and above starts the chord, below 64 releases).
  controller,
}

/// One remap: a MIDI note or controller that plays [notes] (a chord with one
/// identity) on its instrument instead of the message's ordinary handling.
@immutable
class InstrumentRemap {
  /// Creates an [InstrumentRemap].
  const InstrumentRemap({
    required this.port,
    required this.kind,
    required this.number,
    required this.notes,
    this.channel = 0,
  });

  /// The engine MIDI port, `0..kMaxMidiPorts-1`.
  final int port;

  /// The MIDI channel, `1..16`, or `0` for any.
  final int channel;

  /// Whether [number] is a note or a controller.
  final MidiRemapKind kind;

  /// The note or controller number, `0..127`.
  final int number;

  /// The notes to play, `1..kMaxRemapNotes` of them, each `0..127`.
  final List<int> notes;

  /// Whether every field is in the range the engine accepts.
  bool get isValid =>
      _inRange(port, 0, kMaxMidiPorts - 1) &&
      _inRange(channel, 0, 16) &&
      _inRange(number, 0, 127) &&
      notes.isNotEmpty &&
      notes.length <= kMaxRemapNotes &&
      notes.every((n) => _inRange(n, 0, 127));

  @override
  bool operator ==(Object other) =>
      other is InstrumentRemap &&
      other.port == port &&
      other.channel == channel &&
      other.kind == kind &&
      other.number == number &&
      _listEquals(other.notes, notes);

  @override
  int get hashCode =>
      Object.hash(port, channel, kind, number, Object.hashAll(notes));
}

/// Which MIDI one instrument slot plays.
@immutable
class InstrumentRoute {
  /// Creates an [InstrumentRoute].
  const InstrumentRoute({
    required this.midiEnabled,
    this.port = 0,
    this.channel = 0,
    this.low = 0,
    this.high = 127,
    this.remaps = const [],
  });

  /// A slot that plays no MIDI.
  static const InstrumentRoute disabled = InstrumentRoute(midiEnabled: false);

  /// Whether the slot plays MIDI at all (ordinary notes and remaps).
  final bool midiEnabled;

  /// The engine MIDI port its ordinary notes come from.
  final int port;

  /// The MIDI channel, `1..16`, or `0` for any.
  final int channel;

  /// The lowest note played, `0..127`.
  final int low;

  /// The highest note played, `low..127`.
  final int high;

  /// The slot's remaps, at most [kMaxInstrumentRemaps].
  final List<InstrumentRemap> remaps;

  /// Whether every field is in the range the engine accepts.
  bool get isValid =>
      _inRange(port, 0, kMaxMidiPorts - 1) &&
      _inRange(channel, 0, 16) &&
      _inRange(low, 0, 127) &&
      _inRange(high, low, 127) &&
      remaps.length <= kMaxInstrumentRemaps &&
      remaps.every((r) => r.isValid);

  @override
  bool operator ==(Object other) =>
      other is InstrumentRoute &&
      other.midiEnabled == midiEnabled &&
      other.port == port &&
      other.channel == channel &&
      other.low == low &&
      other.high == high &&
      _listEquals(other.remaps, remaps);

  @override
  int get hashCode => Object.hash(
    midiEnabled,
    port,
    channel,
    low,
    high,
    Object.hashAll(remaps),
  );
}

/// An open MIDI capture the engine can read directly: the native `le_midi`
/// handle a `MidiClient` owns. Valid until that client is disposed; closing
/// or disposing the client detaches it from the engine first.
@immutable
class MidiCaptureHandle {
  /// Wraps the native capture [pointer].
  const MidiCaptureHandle(this.pointer);

  /// The native `le_midi*`.
  final Pointer<le_midi> pointer;

  @override
  bool operator ==(Object other) =>
      other is MidiCaptureHandle && other.pointer == pointer;

  @override
  int get hashCode => pointer.address.hashCode;
}

/// The engine's instrument state, read from the snapshot.
@immutable
class InstrumentsSnapshot {
  /// Creates an [InstrumentsSnapshot].
  const InstrumentsSnapshot({
    required this.patches,
    required this.voices,
    required this.peaks,
    required this.monitorPeaks,
    this.voiceLimit = 32,
    this.voicesStolen = 0,
    this.voicesStolenHard = 0,
    this.synthEpoch = 0,
    this.eventsRefused = 0,
    this.fallbackBlocks = 0,
    this.sustainRefused = 0,
  });

  /// Projects the instrument fields of a native snapshot.
  factory InstrumentsSnapshot.fromNative(le_snapshot native) =>
      InstrumentsSnapshot(
        patches: [
          for (var k = 0; k < kMaxInstruments; k++) native.instrument_patch[k],
        ],
        voices: [
          for (var k = 0; k < kMaxInstruments; k++) native.instrument_voices[k],
        ],
        peaks: [
          for (var k = 0; k < kMaxInstruments; k++) native.instrument_peaks[k],
        ],
        monitorPeaks: [
          for (var k = 0; k < kMaxInstruments; k++)
            native.monitor_peaks[kInstrumentSourceBase + k],
        ],
        voiceLimit: native.voice_limit,
        voicesStolen: native.voices_stolen,
        voicesStolenHard: native.voices_stolen_hard,
        synthEpoch: native.synth_epoch,
        eventsRefused: native.instrument_events_refused,
        fallbackBlocks: native.instrument_fallback_blocks,
        sustainRefused: native.instrument_sustain_refused,
      );

  /// No instruments: every slot empty and silent.
  static const InstrumentsSnapshot initial = InstrumentsSnapshot(
    patches: [-1, -1, -1, -1, -1, -1, -1, -1],
    voices: [0, 0, 0, 0, 0, 0, 0, 0],
    peaks: [0, 0, 0, 0, 0, 0, 0, 0],
    monitorPeaks: [0, 0, 0, 0, 0, 0, 0, 0],
  );

  /// Per slot, the patch index the callback applied, or `-1` for none.
  final List<int> patches;

  /// Per slot, its sounding voices (held, sustained or releasing).
  final List<int> voices;

  /// Per slot, its bus's block peak.
  final List<double> peaks;

  /// Per slot, its live monitor's peak (source `kInstrumentSourceBase + k`),
  /// zero when the monitor is off or muted.
  final List<double> monitorPeaks;

  /// The sounding-voice limit in force.
  final int voiceLimit;

  /// Voices taken for new notes with a fade.
  final int voicesStolen;

  /// Voices taken without a fade (no fade slot free).
  final int voicesStolenHard;

  /// Bumped whenever the synth is re-initialised (configure, reopen): every
  /// slot, voice, sustain and route is gone after a change, so the owner
  /// replays its configuration.
  final int synthEpoch;

  /// Note-ons the engine refused because its event ring was full.
  final int eventsRefused;

  /// Blocks too large for the instrument scratch, rendered silent.
  final int fallbackBlocks;

  /// Sustain contributors refused because an instrument had sixteen.
  final int sustainRefused;

  /// The total sounding voices.
  int get totalVoices => voices.fold(0, (a, b) => a + b);

  @override
  bool operator ==(Object other) =>
      other is InstrumentsSnapshot &&
      _listEquals(other.patches, patches) &&
      _listEquals(other.voices, voices) &&
      _listEquals(other.peaks, peaks) &&
      _listEquals(other.monitorPeaks, monitorPeaks) &&
      other.voiceLimit == voiceLimit &&
      other.voicesStolen == voicesStolen &&
      other.voicesStolenHard == voicesStolenHard &&
      other.synthEpoch == synthEpoch &&
      other.eventsRefused == eventsRefused &&
      other.fallbackBlocks == fallbackBlocks &&
      other.sustainRefused == sustainRefused;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(patches),
    Object.hashAll(voices),
    Object.hashAll(peaks),
    Object.hashAll(monitorPeaks),
    voiceLimit,
    voicesStolen,
    voicesStolenHard,
    synthEpoch,
    eventsRefused,
    fallbackBlocks,
    sustainRefused,
  );
}

/// The engine's MIDI input ports, read from the snapshot: what is attached and
/// the running totals of binding edges and losses. The per-message totals
/// (`midi_in_events`, `midi_in_stale`) are deliberately not projected: they
/// tick with every message, a MIDI clock 48 times a second, and would make
/// every snapshot unequal to the last.
@immutable
class MidiInputSnapshot {
  /// Creates a [MidiInputSnapshot].
  const MidiInputSnapshot({
    this.overflows = 0,
    this.lost = 0,
    this.attachedMask = 0,
    this.rebinds = 0,
  });

  /// Projects the MIDI input fields of a native snapshot.
  factory MidiInputSnapshot.fromNative(le_snapshot native) => MidiInputSnapshot(
    overflows: native.midi_in_overflows,
    lost: native.midi_in_lost,
    attachedMask: native.midi_in_attached_mask,
    rebinds: native.midi_in_rebinds,
  );

  /// Nothing attached, nothing received.
  static const MidiInputSnapshot initial = MidiInputSnapshot();

  /// Places where messages were lost (a full ring or an OS overrun).
  final int overflows;

  /// Captures whose device went away while attached.
  final int lost;

  /// Bit `p` set while a capture is attached to port `p`.
  final int attachedMask;

  /// Binding changes (detach, rebind) the drain observed.
  final int rebinds;

  /// Whether a capture is attached to [port].
  bool isAttached(int port) => (attachedMask >> port) & 1 == 1;

  @override
  bool operator ==(Object other) =>
      other is MidiInputSnapshot &&
      other.overflows == overflows &&
      other.lost == lost &&
      other.attachedMask == attachedMask &&
      other.rebinds == rebinds;

  @override
  int get hashCode => Object.hash(overflows, lost, attachedMask, rebinds);
}

bool _inRange(int v, int lo, int hi) => v >= lo && v <= hi;

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
