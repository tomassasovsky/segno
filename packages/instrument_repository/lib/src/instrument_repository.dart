import 'dart:async';

import 'package:instrument_repository/src/models/instruments_state.dart';
import 'package:instrument_repository/src/models/working_copy.dart';
import 'package:instrument_repository/src/route_compiler.dart';
import 'package:segno_engine/segno_engine.dart';

/// What one engine slot was last given (patch index or null, and params).
typedef _SlotImage = ({int? patch, List<double> params});

/// Owns the instruments' engine side: it drives every slot, parameter and
/// the routing table from the applied [InstrumentsWorkingCopy] plus the
/// runtime auditions and parameter drafts, and keeps the engine there.
///
/// Persistence is the caller's: the `instruments` settings family writes a
/// copy through its owner and calls [apply]. Nothing a refusal can lose is
/// dropped: a patch change or table the engine cannot take yet is retried on
/// the next snapshot, latest wins. The engine's synth epoch is the one reset
/// trigger: when it moves, auditions and drafts end and every slot and the
/// table are sent again.
class InstrumentRepository {
  /// Creates an [InstrumentRepository] over [engine], observing [snapshots]
  /// (the caller's engine poll).
  InstrumentRepository({
    required AudioEngine engine,
    required Stream<EngineSnapshot> snapshots,
  }) : _engine = engine {
    _subscription = snapshots.listen(_onSnapshot);
  }

  final AudioEngine _engine;
  late final StreamSubscription<EngineSnapshot> _subscription;
  final _states = StreamController<InstrumentsState>.broadcast();
  InstrumentsState _state = const InstrumentsState();
  SynthCatalogue? _catalogue;
  Map<String, int> _ports = const {};
  final _sent = List<_SlotImage?>.filled(kMaxInstruments, null);
  List<InstrumentRoute>? _publishedRoutes;
  int _epoch = 0;

  /// The engine's sounds.
  SynthCatalogue get catalogue => _catalogue ??= _engine.synthCatalogue();

  /// The current state.
  InstrumentsState get state => _state;

  /// Every state change.
  Stream<InstrumentsState> get states => _states.stream;

  /// The applied definitions.
  InstrumentsWorkingCopy get workingCopy => _state.workingCopy;

  /// Drives the engine from [next]. Returns [EngineResult.invalid] for a copy
  /// whose parameters are out of range (nothing changes); otherwise the copy
  /// is adopted and every slot and the table are reconciled, those the engine
  /// cannot take yet retried on later snapshots.
  EngineResult apply(InstrumentsWorkingCopy next) {
    final valid = next.instruments.every(
      (i) =>
          i.params.length == kSynthFamilyParams &&
          i.params.every((v) => v >= 0 && v <= 100),
    );
    if (!valid) return EngineResult.invalid;
    // An audition or draft survives only while its instrument's saved sound
    // and parameters stay as they were: writing them commits or replaces it.
    bool unchanged(String id) {
      final before = workingCopy.byId(id);
      final after = next.byId(id);
      return before != null &&
          after != null &&
          before.soundId == after.soundId &&
          _listEquals(before.params, after.params);
    }

    _state = InstrumentsState(
      workingCopy: next,
      unavailable: {
        for (final i in next.instruments)
          if (catalogue.byId(i.soundId) == null) i.id,
      },
      voices: _state.voices,
      auditions: {
        for (final e in _state.auditions.entries)
          if (unchanged(e.key)) e.key: e.value,
      },
      drafts: {
        for (final e in _state.drafts.entries)
          if (unchanged(e.key)) e.key: e.value,
      },
    );
    _reconcile();
    return EngineResult.ok;
  }

  /// The engine ports each MIDI device is attached to (device id to port).
  void setPorts(Map<String, int> ports) {
    _ports = Map.unmodifiable(ports);
    _reconcile();
  }

  /// Previews [soundId] on instrument [id] without saving it; [cancelAudition]
  /// returns to the saved sound, and writing the definition commits it.
  /// [EngineResult.invalid] for an unknown instrument or sound.
  EngineResult listen(String id, String soundId) {
    if (workingCopy.byId(id) == null || catalogue.byId(soundId) == null) {
      return EngineResult.invalid;
    }
    _runtime(auditions: {..._state.auditions, id: soundId}, dropDraft: id);
    return EngineResult.ok;
  }

  /// Ends [id]'s audition: the saved sound plays again.
  void cancelAudition(String id) =>
      _runtime(auditions: {..._state.auditions}..remove(id), dropDraft: id);

  /// Sets [id]'s parameter [param] as a draft: audible at once, not saved
  /// until the definition is written. [EngineResult.invalid] for an unknown
  /// instrument or a value out of range.
  EngineResult setParamDraft(String id, int param, double value) {
    final current = _image(id);
    if (current == null ||
        param < 0 ||
        param >= kSynthFamilyParams ||
        !(value >= 0 && value <= 100)) {
      return EngineResult.invalid;
    }
    final params = List<double>.of(current.params)..[param] = value;
    _runtime(drafts: {..._state.drafts, id: List.unmodifiable(params)});
    return EngineResult.ok;
  }

  /// Drops [id]'s parameter draft: the saved values play again.
  void discardDraft(String id) =>
      _runtime(drafts: {..._state.drafts}..remove(id));

  /// Stops observing snapshots.
  Future<void> dispose() async {
    await _subscription.cancel();
    await _states.close();
  }

  void _runtime({
    Map<String, String>? auditions,
    Map<String, List<double>>? drafts,
    String? dropDraft,
  }) {
    _state = InstrumentsState(
      workingCopy: _state.workingCopy,
      unavailable: _state.unavailable,
      voices: _state.voices,
      auditions: auditions ?? _state.auditions,
      drafts: {...drafts ?? _state.drafts}..remove(dropDraft),
      problems: _state.problems,
    );
    _reconcile();
  }

  /// What instrument [id]'s slot should play: the audition's sound with its
  /// defaults, else the saved sound with the draft or saved parameters.
  _SlotImage? _image(String id) {
    final instrument = workingCopy.byId(id);
    if (instrument == null) return null;
    final audition = _state.auditions[id];
    if (audition != null) {
      final patch = catalogue.byId(audition)!;
      return (patch: patch.index, params: _state.drafts[id] ?? patch.defaults);
    }
    return (
      patch: catalogue.byId(instrument.soundId)?.index,
      params: _state.drafts[id] ?? instrument.params,
    );
  }

  void _onSnapshot(EngineSnapshot snapshot) {
    final instruments = snapshot.instruments;
    if (instruments.synthEpoch != _epoch) {
      // The synth was re-initialised: nothing sent survives, and runtime
      // previews end with it.
      _epoch = instruments.synthEpoch;
      _sent.fillRange(0, kMaxInstruments, null);
      _publishedRoutes = null;
      _state = InstrumentsState(
        workingCopy: _state.workingCopy,
        unavailable: _state.unavailable,
        voices: _state.voices,
        problems: _state.problems,
      );
    }
    final voices = {
      for (final i in workingCopy.instruments) i.id: instruments.voices[i.slot],
    };
    if (!_mapEquals(voices, _state.voices)) {
      _state = InstrumentsState(
        workingCopy: _state.workingCopy,
        unavailable: _state.unavailable,
        voices: voices,
        auditions: _state.auditions,
        drafts: _state.drafts,
        problems: _state.problems,
      );
    }
    _reconcile();
  }

  /// Sends every slot and the table that differ from what the engine was
  /// last given. A slot or table the engine refuses for now stays unsent and
  /// is retried on the next snapshot; before the first configure (epoch 0)
  /// nothing is sent, the first epoch sends it all.
  void _reconcile() {
    if (_epoch != 0) {
      for (var slot = 0; slot < kMaxInstruments; slot++) {
        final owner = workingCopy.bySlot(slot);
        _sendSlot(
          slot,
          owner == null ? (patch: null, params: const []) : _image(owner.id)!,
        );
      }
    }
    final compiled = compileRoutes(workingCopy, _ports);
    if (_epoch != 0 && !_listEquals(compiled.routes, _publishedRoutes)) {
      if (_engine.setInstrumentRoutes(compiled.routes).isOk) {
        _publishedRoutes = compiled.routes;
      }
    }
    final next = InstrumentsState(
      workingCopy: _state.workingCopy,
      unavailable: _state.unavailable,
      voices: _state.voices,
      auditions: _state.auditions,
      drafts: _state.drafts,
      problems: compiled.problems,
    );
    if (next != _lastEmitted) {
      _lastEmitted = next;
      _states.add(next);
    }
    _state = next;
  }

  InstrumentsState? _lastEmitted;

  void _sendSlot(int slot, _SlotImage want) {
    final sent = _sent[slot];
    if (sent != null &&
        sent.patch == want.patch &&
        _listEquals(sent.params, want.params)) {
      return;
    }
    if (sent == null || sent.patch != want.patch || want.patch == null) {
      final result = _engine.setInstrument(
        slot: slot,
        patch: want.patch,
        params: want.patch == null ? null : want.params,
      );
      if (result.isOk) _sent[slot] = want;
      return;
    }
    var all = true;
    for (var p = 0; p < kSynthFamilyParams; p++) {
      if (sent.params[p] == want.params[p]) continue;
      final ok = _engine
          .setInstrumentParam(slot: slot, param: p, value: want.params[p])
          .isOk;
      all &= ok;
    }
    if (all) _sent[slot] = want;
  }
}

bool _listEquals<T>(List<T> a, List<T>? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
