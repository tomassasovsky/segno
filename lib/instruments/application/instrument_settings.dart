import 'package:instrument_repository/instrument_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/instruments/application/instruments_family.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

/// Why [InstrumentSettings.remove] refused.
enum RemoveRefusal {
  /// No instrument has that id.
  unknown,

  /// A track is capturing (or about to capture) from the instrument.
  capturing,
}

/// The instruments' edits (#1197): each computes the next working copy and
/// writes it through the `instruments` settings owner, which applies it to
/// the engine before it is stored. Auditions and parameter drafts stay on
/// [repository] and are never written until committed here.
class InstrumentSettings {
  /// Builds the owner over [looper]'s lifetime, [instruments] and
  /// [settings]' record. [mintId] gives each new instrument its identity.
  InstrumentSettings({
    required LooperRepository looper,
    required InstrumentRepository instruments,
    required SettingsRepository settings,
    String Function() mintId = SlotIds.mint,
  }) : _looper = looper,
       repository = instruments,
       _mintId = mintId,
       owner = SettingsOwner(
         repository: looper,
         family: InstrumentsFamily(
           instruments: instruments,
           settings: settings,
         ),
       );

  final LooperRepository _looper;
  final String Function() _mintId;

  /// The engine side: auditions, drafts, notes and the state stream.
  final InstrumentRepository repository;

  /// The instruments transaction.
  final SettingsOwner<InstrumentsWorkingCopy, String?> owner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [owner];

  /// The stored definitions.
  InstrumentsWorkingCopy get confirmed => owner.durable;

  /// Restores the stored definitions into the engine.
  Future<void> load() => owner.load();

  /// Adds an instrument named [name] playing [soundId] with its defaults in
  /// the first free slot, or says why it cannot. New instruments start with
  /// their MIDI and computer keys off.
  Future<({AddRefusal? refusal, SettingOutcome? outcome})> add({
    required String soundId,
    required String name,
  }) async {
    final sound = repository.catalogue.byId(soundId);
    if (sound == null) {
      return (
        refusal: null,
        outcome: const SettingOutcome(SettingStatus.rejected),
      );
    }
    final id = _mintId();
    final probe = owner.live.add(
      id: id,
      name: name,
      soundId: soundId,
      params: sound.defaults,
    );
    if (probe.refusal != null) return (refusal: probe.refusal, outcome: null);
    final outcome = await owner.update(
      (live) =>
          live
              .add(id: id, name: name, soundId: soundId, params: sound.defaults)
              .copy ??
          live,
    );
    return (refusal: null, outcome: outcome);
  }

  /// Renames [id].
  Future<SettingOutcome> rename(String id, String name) =>
      _edit(id, (i) => i.copyWith(name: name));

  /// Commits [soundId] for [id] with that sound's default parameters (the
  /// audition's Apply); the audition ends with the write.
  Future<SettingOutcome> chooseSound(String id, String soundId) {
    final sound = repository.catalogue.byId(soundId);
    if (sound == null) {
      return Future.value(const SettingOutcome(SettingStatus.rejected));
    }
    return _edit(
      id,
      (i) => i.copyWith(soundId: soundId, params: sound.defaults),
    );
  }

  /// Writes [id]'s parameter draft, which ends with the write; without a
  /// draft nothing changes.
  Future<SettingOutcome> commitParams(String id) {
    final draft = repository.state.drafts[id];
    if (draft == null) {
      return Future.value(const SettingOutcome(SettingStatus.applied));
    }
    return _edit(id, (i) => i.copyWith(params: draft));
  }

  /// Sets [id]'s MIDI input.
  Future<SettingOutcome> setMidiInput(String id, MidiNoteInput midi) =>
      _edit(id, (i) => i.copyWith(midi: midi));

  /// Sets [id]'s computer keys.
  Future<SettingOutcome> setComputerKeys(String id, ComputerKeys keys) =>
      _edit(id, (i) => i.copyWith(keys: keys));

  /// Removes [id]. Refused while a track captures from it (or waits to);
  /// when a lane still holds material recorded from it, a tombstone keeps
  /// its name and slot so the recording stays labelled.
  Future<({RemoveRefusal? refusal, SettingOutcome? outcome})> remove(
    String id,
  ) async {
    final instrument = owner.live.byId(id);
    if (instrument == null) {
      return (refusal: RemoveRefusal.unknown, outcome: null);
    }
    final source = instrument.source;
    var material = false;
    for (final track in _looper.state.tracks) {
      final fed = track.lanes.any((lane) => lane.inputChannel == source);
      if (!fed) continue;
      if (track.isCapturing || track.pendingLaunch != null) {
        return (refusal: RemoveRefusal.capturing, outcome: null);
      }
      material |= track.lanes.any(
        (lane) => lane.inputChannel == source && lane.hasContent,
      );
    }
    final outcome = await owner.update(
      (live) => live.remove(id, keepLabel: material),
    );
    return (refusal: null, outcome: outcome);
  }

  /// Ends the owner.
  Future<void> close() => owner.close();

  Future<SettingOutcome> _edit(
    String id,
    Instrument Function(Instrument current) change,
  ) => owner.update((live) {
    final current = live.byId(id);
    return current == null ? live : live.replace(change(current));
  });
}
