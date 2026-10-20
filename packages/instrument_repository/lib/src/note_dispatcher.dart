import 'package:instrument_repository/src/models/instrument.dart';
import 'package:segno_engine/segno_engine.dart';

/// A release the engine could not take yet: retried until accepted.
typedef _Owed = ({int token, int? sustainSlot});

/// Plays the notes Dart owns: computer keys, the touch keyboard and action
/// tokens. Each press gets an origin token the engine releases by; a chord
/// is one token. A release the engine's lane cannot take yet is kept and
/// retried on every snapshot, never dropped; a refused note-on is dropped
/// and its release is then a harmless no-op.
class NoteDispatcher {
  /// Creates a [NoteDispatcher] over [engine]; [instruments] reads the
  /// current definitions.
  NoteDispatcher({
    required InstrumentHost engine,
    required List<Instrument> Function() instruments,
  }) : _engine = engine,
       _instruments = instruments;

  final InstrumentHost _engine;
  final List<Instrument> Function() _instruments;
  int _lastToken = 0;
  final List<_Owed> _owed = [];
  final Map<String, List<int>> _keysDown = {};
  final Map<Object, int> _latched = {};
  final Map<Object, ({int token, int slot})> _sustains = {};

  /// Releases waiting for room in the engine's release lane.
  int get owedReleases => _owed.length;

  /// The keys currently held, in press order.
  Iterable<String> get keysDown => _keysDown.keys;

  Instrument? _find(String id) {
    for (final i in _instruments()) {
      if (i.id == id) return i;
    }
    return null;
  }

  int _token() => _lastToken = _lastToken == 0x7fffffff ? 1 : _lastToken + 1;

  /// Starts [notes] on instrument [id] as one token (a chord when there are
  /// several, at most `kMaxChordNotes`) and returns it, or null for an
  /// unknown instrument.
  int? press(String id, List<int> notes, {int velocity = 100}) {
    final instrument = _find(id);
    if (instrument == null) return null;
    final token = _token();
    if (notes.length == 1) {
      _engine.instrumentNoteOn(
        slot: instrument.slot,
        origin: token,
        note: notes.single,
        velocity: velocity,
      );
    } else if (notes.isNotEmpty) {
      // one origin, one sounding note: a chord goes as one
      _engine.instrumentChordOn(
        slot: instrument.slot,
        origin: token,
        notes: notes.take(kMaxChordNotes).toList(growable: false),
        velocity: velocity,
      );
    }
    return token;
  }

  /// Releases [token]'s notes on every instrument.
  void release(int token) => _settle((token: token, sustainSlot: null));

  /// Latches [notes] on [id] under [key], or releases them when [key] is
  /// already latched. Returns whether [key] is latched afterwards.
  bool toggleLatch(
    Object key,
    String id,
    List<int> notes, {
    int velocity = 100,
  }) {
    final held = _latched.remove(key);
    if (held != null) {
      release(held);
      return false;
    }
    final token = press(id, notes, velocity: velocity);
    if (token != null) _latched[key] = token;
    return token != null;
  }

  /// Whether [key] holds a latch.
  bool isLatched(Object key) => _latched.containsKey(key);

  /// Holds ([on]) or lets go of sustain on instrument [id] for [key], one
  /// contributor among the engine's others.
  void sustain(Object key, String id, {required bool on}) {
    if (!on) {
      final held = _sustains.remove(key);
      if (held != null) _settle((token: held.token, sustainSlot: held.slot));
      return;
    }
    final instrument = _find(id);
    if (instrument == null || _sustains.containsKey(key)) return;
    final token = _token();
    final result = _engine.instrumentSustain(
      slot: instrument.slot,
      origin: token,
      on: true,
    );
    if (result.isOk) _sustains[key] = (token: token, slot: instrument.slot);
  }

  /// A computer key went down: every instrument whose keys are enabled and
  /// that maps [key] plays its notes. Repeats of a held key are ignored.
  void keyDown(String key) {
    final label = key.toUpperCase();
    if (_keysDown.containsKey(label)) return;
    final tokens = <int>[];
    for (final instrument in _instruments()) {
      if (!instrument.keys.enabled) continue;
      for (final mapping in instrument.keys.mappings) {
        if (mapping.key.toUpperCase() != label) continue;
        tokens.add(press(instrument.id, mapping.notes)!);
      }
    }
    if (tokens.isNotEmpty) _keysDown[label] = tokens;
  }

  /// A computer key went up: its notes end, whatever the mappings say now.
  void keyUp(String key) =>
      _keysDown.remove(key.toUpperCase())?.forEach(release);

  /// Focus left, the window deactivated or the app paused: every held key
  /// lets go.
  void releaseAllKeys() => _keysDown.keys.toList().forEach(keyUp);

  /// The instrument [key] would play, for the claim notice, or null.
  Instrument? keyOwner(String key) {
    final label = key.toUpperCase();
    for (final instrument in _instruments()) {
      if (instrument.keys.enabled &&
          instrument.keys.mappings.any((m) => m.key.toUpperCase() == label)) {
        return instrument;
      }
    }
    return null;
  }

  /// Retries every owed release, in order.
  void retry() {
    final owed = List.of(_owed);
    _owed.clear();
    owed.forEach(_settle);
  }

  /// The engine re-initialised its synth: everything held is gone there, so
  /// latches, sustain, held keys and owed releases are dropped here too.
  void reset() {
    _owed.clear();
    _keysDown.clear();
    _latched.clear();
    _sustains.clear();
  }

  void _settle(_Owed owed) {
    final slot = owed.sustainSlot;
    final result = slot == null
        ? _engine.instrumentRelease(owed.token)
        : _engine.instrumentSustain(slot: slot, origin: owed.token, on: false);
    if (result == EngineResult.capacity) _owed.add(owed);
  }
}
