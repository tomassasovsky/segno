import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// The player's saved sounds: what "Save preset" writes and what My presets
/// lists (accepted design, "Adding, arranging and saving effects").
///
/// One owner for the saved list, because three surfaces touch it — the two
/// editors save into it, the library recalls from it, and My presets renames
/// and deletes in it — and a second copy would let them disagree about what is
/// saved.
///
/// The whole list is rewritten on every change. It is a handful of small
/// records, and rewriting it whole is what makes a delete and a rename the
/// same one write as a save.
/// The preset called [name] among [presets], or `null`.
///
/// Case-insensitive, because the accepted collision question is about a name
/// the player will read back: two presets differing only in case would be two
/// rows a player cannot tell apart.
///
/// A function over the state rather than a method on the cubit: a cubit's
/// public methods change state, and this one only asks a question about it.
FxUserPreset? fxPresetNamed(List<FxUserPreset> presets, String name) {
  final folded = name.trim().toLowerCase();
  for (final preset in presets) {
    if (preset.name.toLowerCase() == folded) return preset;
  }
  return null;
}

class FxPresetsCubit extends Cubit<List<FxUserPreset>> {
  /// Creates an [FxPresetsCubit].
  FxPresetsCubit({required SettingsRepository settings})
    : _settings = settings,
      super(const []);

  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the saved list.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final encoded = await _settings.loadFxUserPresets();
    final presets = FxUserPreset.decodeAll(encoded);
    if (!isClosed && presets.isNotEmpty) emit(presets);
  }

  /// Saves [entries] under [name], as a new preset.
  ///
  /// The entries are copied WITHOUT their rack, their slot ids or their
  /// placement: a saved sound is a definition, and those three are what make
  /// one instance of it distinct from the next. Recall mints fresh ones.
  Future<void> save({
    required String name,
    required List<TrackEffect> entries,
    String? art,
  }) => _write([
    ...state,
    FxUserPreset(
      id: SlotIds.mint(),
      name: name.trim(),
      entries: _definition(entries),
      art: art,
    ),
  ]);

  /// Replaces the preset [id]'s entries, keeping its identity and its name.
  ///
  /// Existing instances are untouched, which is the accepted rule: replacing a
  /// saved definition never rewrites the copies already in a chain.
  Future<void> replace({
    required String id,
    required List<TrackEffect> entries,
    String? art,
  }) => _write([
    for (final preset in state)
      if (preset.id == id)
        preset.copyWith(entries: _definition(entries), art: art)
      else
        preset,
  ]);

  /// Renames the preset [id].
  Future<void> rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    return _write([
      for (final preset in state)
        if (preset.id == id) preset.copyWith(name: trimmed) else preset,
    ]);
  }

  /// Deletes the preset [id]. Effects already added from it are not affected.
  Future<void> remove(String id) => _write([
    for (final preset in state)
      if (preset.id != id) preset,
  ]);

  /// An instance's entries as a DEFINITION: no rack, no slot ids, no
  /// placement. See [save].
  static List<TrackEffect> _definition(List<TrackEffect> entries) => [
    for (final fx in entries)
      switch (fx) {
        BuiltInEffect() => BuiltInEffect(
          type: fx.type,
          params: fx.params,
          enabled: fx.enabled,
          channels: fx.channels,
          module: fx.module,
        ),
        PluginEffect() => PluginEffect(
          ref: fx.ref,
          paramValues: fx.paramValues,
          state: fx.state,
          name: fx.name,
          enabled: fx.enabled,
          channels: fx.channels,
          module: fx.module,
        ),
      },
  ];

  Future<void> _write(List<FxUserPreset> presets) async {
    if (isClosed) return;
    emit(presets);
    await _settings.saveFxUserPresets(FxUserPreset.encodeAll(presets));
  }
}
