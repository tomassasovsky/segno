import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/instruments.dart';
import 'package:segno_engine/src/synth_catalogue.dart';

/// A deterministic, audio-free model of the engine's instrument slots and
/// MIDI input ports, shared by `MockAudioEngine` and the test fakes so they
/// all answer [InstrumentHost] and [MidiInputSink] the same way.
///
/// It keeps the engine's rules that a caller can observe: results and
/// refusals, patch changes ending a slot's voices, one sounding note per
/// origin (a note-on for an origin still held on the slot replaces it, a
/// sustained voice rings on) and chords through [instrumentChordOn], release
/// by origin across every slot, sustain contributors (drums ignore them),
/// the GM notes a kit plays, the voice limit with stealing, and the synth
/// epoch. A parity test runs one script through this model and the engine.
/// It renders nothing, so a released voice stops counting at once instead
/// of after its release time, and it routes no MIDI: attached captures are
/// only recorded.
mixin SimulatedInstruments implements InstrumentHost, MidiInputSink {
  /// The catalogue [synthCatalogue] returns. Defaults to a copy of the
  /// engine's table, pinned against the native one by a native-library test.
  SynthCatalogue simulatedCatalogue = referenceSynthCatalogue;

  /// Whether the simulated engine is configured. Calls the native engine
  /// refuses before configure return [EngineResult.notRunning] while this is
  /// false. Fakes leave it true; `MockAudioEngine` follows its lifecycle.
  bool simulatedInstrumentsConfigured = true;

  /// Every instrument call, in order, by name.
  final List<String> instrumentCalls = [];

  final List<int> _patch = List.filled(kMaxInstruments, -1);
  final List<List<double>> _params = List.generate(
    kMaxInstruments,
    (_) => const [],
  );
  final List<SimulatedVoice> _voices = [];
  final List<List<int>> _sustain = List.generate(kMaxInstruments, (_) => []);
  List<InstrumentRoute> _routes = const [];
  final Map<int, MidiCaptureHandle> _attached = {};
  int _voiceLimit = 32;
  int _stolen = 0;
  int _eventsRefused = 0;
  int _sustainRefused = 0;
  int _epoch = 0;

  /// The sounding voices, oldest first.
  List<SimulatedVoice> get simulatedVoices => List.unmodifiable(_voices);

  /// The published routes (one entry per slot given).
  List<InstrumentRoute> get simulatedRoutes => _routes;

  /// Slot [slot]'s three parameter settings (empty for an empty slot).
  List<double> simulatedParams(int slot) => _params[slot];

  /// The sustain contributors holding [slot].
  List<int> simulatedSustain(int slot) => List.unmodifiable(_sustain[slot]);

  /// The capture attached to each port.
  Map<int, MidiCaptureHandle> get simulatedAttached =>
      Map.unmodifiable(_attached);

  /// What the snapshot reports for the instruments.
  InstrumentsSnapshot get simulatedInstrumentsSnapshot => InstrumentsSnapshot(
    patches: List.unmodifiable(_patch),
    voices: [
      for (var k = 0; k < kMaxInstruments; k++)
        _voices.where((v) => v.slot == k).length,
    ],
    peaks: List.filled(kMaxInstruments, 0),
    monitorPeaks: List.filled(kMaxInstruments, 0),
    voiceLimit: _voiceLimit,
    voicesStolen: _stolen,
    synthEpoch: _epoch,
    eventsRefused: _eventsRefused,
    sustainRefused: _sustainRefused,
  );

  /// What the snapshot reports for the MIDI input ports.
  MidiInputSnapshot get simulatedMidiInputSnapshot => MidiInputSnapshot(
    attachedMask: _attached.keys.fold(0, (mask, p) => mask | (1 << p)),
  );

  /// Re-initialises the synth as configure and reopen do: every slot, voice,
  /// sustain and route is gone and the epoch advances. Attached captures
  /// stay attached, as on the engine.
  void resetSimulatedInstruments() {
    _patch.fillRange(0, kMaxInstruments, -1);
    for (var k = 0; k < kMaxInstruments; k++) {
      _params[k] = const [];
      _sustain[k].clear();
    }
    _voices.clear();
    _routes = const [];
    _voiceLimit = 32;
    _stolen = 0;
    _eventsRefused = 0;
    _sustainRefused = 0;
    _epoch++;
    simulatedInstrumentsConfigured = true;
  }

  @override
  SynthCatalogue synthCatalogue() {
    instrumentCalls.add('synthCatalogue');
    return simulatedCatalogue;
  }

  @override
  EngineResult setInstrument({
    required int slot,
    required int? patch,
    List<double>? params,
  }) {
    instrumentCalls.add('setInstrument');
    if (!_validSlot(slot) || (params != null && params.length != 3)) {
      return EngineResult.invalid;
    }
    if (params != null && params.any((v) => v.isNaN)) {
      return EngineResult.invalid;
    }
    final info = patch == null ? null : simulatedCatalogue.byIndex(patch);
    if (patch != null && (patch < 0 || info == null)) {
      return patch < 0 ? EngineResult.invalid : EngineResult.unknownPatch;
    }
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    if (_patch[slot] != (patch ?? -1)) _endSlot(slot);
    _patch[slot] = patch ?? -1;
    _params[slot] = info == null
        ? const []
        : List.unmodifiable([
            for (final v in params ?? info.defaults) v.clamp(0.0, 100.0),
          ]);
    return EngineResult.ok;
  }

  @override
  EngineResult setInstrumentParam({
    required int slot,
    required int param,
    required double value,
  }) {
    instrumentCalls.add('setInstrumentParam');
    if (!_validSlot(slot) || param < 0 || param > 2 || value.isNaN) {
      return EngineResult.invalid;
    }
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    if (_patch[slot] < 0) return EngineResult.noInstrument;
    _params[slot] = List.unmodifiable(
      List<double>.of(_params[slot])..[param] = value.clamp(0.0, 100.0),
    );
    return EngineResult.ok;
  }

  @override
  EngineResult setVoiceLimit(int limit) {
    instrumentCalls.add('setVoiceLimit');
    if (limit < 1 || limit > kMaxVoiceLimit) return EngineResult.invalid;
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    _voiceLimit = limit;
    while (_voices.length > limit) {
      _voices.removeAt(_stealIndex(-1));
    }
    return EngineResult.ok;
  }

  @override
  EngineResult resetInstrument(int slot) {
    instrumentCalls.add('resetInstrument');
    if (!_validSlot(slot)) return EngineResult.invalid;
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    _voices.removeWhere((v) => v.slot == slot);
    return EngineResult.ok;
  }

  @override
  EngineResult instrumentNoteOn({
    required int slot,
    required int origin,
    required int note,
    required int velocity,
  }) {
    instrumentCalls.add('instrumentNoteOn');
    if (!_validSlot(slot) ||
        note < 0 ||
        note > 127 ||
        velocity < 1 ||
        velocity > 127) {
      return EngineResult.invalid;
    }
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    if (_patch[slot] < 0) return EngineResult.noInstrument;
    _start(slot, origin, note, velocity, restrike: true);
    return EngineResult.ok;
  }

  @override
  EngineResult instrumentChordOn({
    required int slot,
    required int origin,
    required List<int> notes,
    required int velocity,
  }) {
    instrumentCalls.add('instrumentChordOn');
    if (!_validSlot(slot) ||
        notes.isEmpty ||
        notes.length > kMaxChordNotes ||
        notes.any((n) => n < 0 || n > 127) ||
        velocity < 1 ||
        velocity > 127) {
      return EngineResult.invalid;
    }
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    if (_patch[slot] < 0) return EngineResult.noInstrument;
    for (var n = 0; n < notes.length; n++) {
      _start(slot, origin, notes[n], velocity, restrike: n == 0);
    }
    return EngineResult.ok;
  }

  /// The engine's note start: a kit plays only its GM notes; with
  /// [restrike] the origin's held voices on [slot] (whatever their note)
  /// give way, while a voice held on only by sustain rings on; at the limit
  /// a voice is stolen.
  void _start(
    int slot,
    int origin,
    int note,
    int velocity, {
    required bool restrike,
  }) {
    final family = simulatedCatalogue.byIndex(_patch[slot])?.family;
    if (family == SynthFamily.drums && !_drumNotes.contains(note)) return;
    if (restrike) {
      _voices.removeWhere(
        (v) => v.slot == slot && v.origin == origin && !v.sustained,
      );
    }
    if (_voices.length >= _voiceLimit) {
      _voices.removeAt(_stealIndex(slot));
      _stolen++;
    }
    _voices.add(
      SimulatedVoice(
        slot: slot,
        origin: origin,
        note: note,
        velocity: velocity,
      ),
    );
  }

  /// The notes a kit plays (GM kick, snare, clap and closed hat).
  static const Set<int> _drumNotes = {35, 36, 38, 39, 40, 42, 44};

  @override
  EngineResult instrumentRelease(int origin) {
    instrumentCalls.add('instrumentRelease');
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    for (var i = _voices.length - 1; i >= 0; i--) {
      final v = _voices[i];
      if (v.origin != origin || v.sustained) continue;
      if (_sustains(v.slot)) {
        _voices[i] = v.copyWith(sustained: true);
      } else {
        _voices.removeAt(i);
      }
    }
    return EngineResult.ok;
  }

  @override
  EngineResult instrumentSustain({
    required int slot,
    required int origin,
    required bool on,
  }) {
    instrumentCalls.add('instrumentSustain');
    if (!_validSlot(slot)) return EngineResult.invalid;
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    final held = _sustain[slot];
    if (!on) {
      if (held.remove(origin) && held.isEmpty) {
        _voices.removeWhere((v) => v.slot == slot && v.sustained);
      }
      return EngineResult.ok;
    }
    if (_patch[slot] < 0) return EngineResult.noInstrument;
    final family = simulatedCatalogue.byIndex(_patch[slot])?.family;
    if (family == SynthFamily.drums || held.contains(origin)) {
      return EngineResult.ok;
    }
    if (held.length >= 16) {
      _sustainRefused++;
    } else {
      held.add(origin);
    }
    return EngineResult.ok;
  }

  @override
  EngineResult setInstrumentRoutes(List<InstrumentRoute> routes) {
    instrumentCalls.add('setInstrumentRoutes');
    if (routes.length > kMaxInstruments || routes.any((r) => !r.isValid)) {
      return EngineResult.invalid;
    }
    if (!simulatedInstrumentsConfigured) return EngineResult.notRunning;
    _routes = List.unmodifiable(routes);
    return EngineResult.ok;
  }

  @override
  EngineResult attachMidiInput(MidiCaptureHandle capture, {required int port}) {
    instrumentCalls.add('attachMidiInput');
    if (port < 0 || port >= kMaxMidiPorts) return EngineResult.invalid;
    _attached
      ..removeWhere((_, c) => c == capture)
      ..[port] = capture;
    return EngineResult.ok;
  }

  @override
  EngineResult detachMidiInput(int port) {
    instrumentCalls.add('detachMidiInput');
    if (port < 0 || port >= kMaxMidiPorts) return EngineResult.invalid;
    _attached.remove(port);
    return EngineResult.ok;
  }

  bool _validSlot(int slot) => slot >= 0 && slot < kMaxInstruments;

  bool _sustains(int slot) =>
      _sustain[slot].isNotEmpty &&
      simulatedCatalogue.byIndex(_patch[slot])?.family != SynthFamily.drums;

  void _endSlot(int slot) {
    _voices.removeWhere((v) => v.slot == slot);
    _sustain[slot].clear();
  }

  /// The voice a new note on [slot] takes when the pool is full: the oldest
  /// sustained voice of [slot], then of any slot, then the oldest held voice
  /// of [slot], then of any slot (the engine's order, minus the releasing
  /// voices this model does not keep).
  int _stealIndex(int slot) {
    int find(bool Function(SimulatedVoice v) test) => _voices.indexWhere(test);
    for (final i in [
      find((v) => v.sustained && v.slot == slot),
      find((v) => v.sustained),
      find((v) => v.slot == slot),
    ]) {
      if (i >= 0) return i;
    }
    return 0;
  }
}

/// One voice of [SimulatedInstruments].
class SimulatedVoice {
  /// Creates a [SimulatedVoice].
  const SimulatedVoice({
    required this.slot,
    required this.origin,
    required this.note,
    required this.velocity,
    this.sustained = false,
  });

  /// The instrument slot.
  final int slot;

  /// The identity its release names.
  final int origin;

  /// The MIDI note.
  final int note;

  /// The strike velocity.
  final int velocity;

  /// Whether it was released and sustain holds it.
  final bool sustained;

  /// This voice with [sustained] replaced.
  SimulatedVoice copyWith({bool? sustained}) => SimulatedVoice(
    slot: slot,
    origin: origin,
    note: note,
    velocity: velocity,
    sustained: sustained ?? this.sustained,
  );

  @override
  String toString() =>
      'SimulatedVoice(slot $slot, origin $origin, note $note'
      '${sustained ? ', sustained' : ''})';
}

/// A Dart copy of the engine's synthesis catalogue (`synth_patch.c`), for
/// the mock engine and the test fakes, which have no native library. Not
/// exported from `segno_engine` (plan, the stop list: app code reads the
/// catalogue only from an engine), and pinned to the engine's table field
/// by field by a native-library test, so it cannot drift silently.
const SynthCatalogue referenceSynthCatalogue = SynthCatalogue(
  patches: [
    SynthPatch(
      index: 0,
      id: 'piano',
      family: SynthFamily.keys,
      defaults: [68, 72, 22],
    ),
    SynthPatch(
      index: 1,
      id: 'keys',
      family: SynthFamily.keys,
      defaults: [52, 60, 45],
    ),
    SynthPatch(
      index: 2,
      id: 'clav',
      family: SynthFamily.keys,
      defaults: [80, 18, 65],
    ),
    SynthPatch(
      index: 3,
      id: 'organ',
      family: SynthFamily.organs,
      defaults: [60, 35, 8],
    ),
    SynthPatch(
      index: 4,
      id: 'reed',
      family: SynthFamily.organs,
      defaults: [45, 12, 22],
    ),
    SynthPatch(
      index: 5,
      id: 'lead',
      family: SynthFamily.synths,
      defaults: [72, 2, 25],
    ),
    SynthPatch(
      index: 6,
      id: 'pad',
      family: SynthFamily.synths,
      defaults: [42, 60, 72],
    ),
    SynthPatch(
      index: 7,
      id: 'pluck',
      family: SynthFamily.synths,
      defaults: [62, 0, 12],
    ),
    SynthPatch(
      index: 8,
      id: 'bass',
      family: SynthFamily.bass,
      defaults: [35, 65, 18],
    ),
    SynthPatch(
      index: 9,
      id: 'synth-bass',
      family: SynthFamily.bass,
      defaults: [43, 75, 24],
    ),
    SynthPatch(
      index: 10,
      id: 'sub',
      family: SynthFamily.bass,
      defaults: [20, 20, 30],
    ),
    SynthPatch(
      index: 11,
      id: 'strings',
      family: SynthFamily.strings,
      defaults: [42, 55, 28],
    ),
    SynthPatch(
      index: 12,
      id: 'violin',
      family: SynthFamily.strings,
      defaults: [64, 30, 38],
    ),
    SynthPatch(
      index: 13,
      id: 'cello',
      family: SynthFamily.strings,
      defaults: [30, 45, 20],
    ),
    SynthPatch(
      index: 14,
      id: 'drums',
      family: SynthFamily.drums,
      defaults: [52, 40, 65],
    ),
    SynthPatch(
      index: 15,
      id: 'electronic-drums',
      family: SynthFamily.drums,
      defaults: [75, 25, 80],
    ),
    SynthPatch(
      index: 16,
      id: 'marimba',
      family: SynthFamily.percussion,
      defaults: [35, 42, 0],
    ),
    SynthPatch(
      index: 17,
      id: 'vibes',
      family: SynthFamily.percussion,
      defaults: [50, 80, 35],
    ),
    SynthPatch(
      index: 18,
      id: 'bells',
      family: SynthFamily.percussion,
      defaults: [80, 90, 0],
    ),
  ],
  params: {
    SynthFamily.keys: [
      SynthParamInfo(
        key: 'brightness',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'decay',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'character',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
    ],
    SynthFamily.organs: [
      SynthParamInfo(
        key: 'harmonics',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'rotary',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'release',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
    ],
    SynthFamily.synths: [
      SynthParamInfo(
        key: 'cutoff',
        unit: _hz,
        atMin: 180,
        atMax: 12600,
        exponential: true,
      ),
      SynthParamInfo(
        key: 'attack',
        unit: _s,
        atMin: 0.008,
        atMax: 0.908,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'release',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
    ],
    SynthFamily.bass: [
      SynthParamInfo(
        key: 'cutoff',
        unit: _hz,
        atMin: 180,
        atMax: 12600,
        exponential: true,
      ),
      SynthParamInfo(
        key: 'punch',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'release',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
    ],
    SynthFamily.strings: [
      SynthParamInfo(
        key: 'brightness',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'attack',
        unit: _s,
        atMin: 0.008,
        atMax: 0.908,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'vibrato',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
    ],
    SynthFamily.drums: [
      SynthParamInfo(
        key: 'tone',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'decay',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'body',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
    ],
    SynthFamily.percussion: [
      SynthParamInfo(
        key: 'hardness',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'decay',
        unit: _s,
        atMin: 0.08,
        atMax: 2.48,
        exponential: false,
      ),
      SynthParamInfo(
        key: 'tremolo',
        unit: _pct,
        atMin: 0,
        atMax: 100,
        exponential: false,
      ),
    ],
  },
);

const SynthParamUnit _pct = SynthParamUnit.percent;
const SynthParamUnit _s = SynthParamUnit.seconds;
const SynthParamUnit _hz = SynthParamUnit.hertz;
