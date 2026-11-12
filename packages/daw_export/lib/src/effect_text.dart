import 'package:daw_export/src/manifest_json.dart';

/// The console's name for each effect type code (`le_fx_type`), as
/// `TrackEffectType` labels them. Reproduced here because this package does
/// not depend on `segno_engine`; the app's tests check the two agree.
const Map<int, String> effectTypeNames = {
  1: 'Drive',
  2: 'Filter',
  3: 'Delay',
  4: 'Tremolo',
  5: 'Octaver',
  6: 'Echo',
  7: 'Reverb',
  9: 'EQ',
  10: 'Compressor',
  11: 'Transient',
  12: 'HP / Gate',
  13: 'Doubler',
  14: 'Chorus',
  15: 'Wah',
  16: 'Overdrive',
  17: 'Distortion',
  18: 'Vinyl',
  19: 'Degrade',
  20: 'LPF',
  21: 'Spring reverb',
  22: 'Dub reverb',
  23: 'Ambience',
  24: 'Whammy',
  25: 'Pumper',
  26: 'Slicer',
  27: 'Mode delay',
  28: 'Dual octaver',
  29: 'Amp',
  30: 'Modulation',
  31: 'Room reverb',
  32: 'Smart Tune',
};

const int _kNone = 0;
const int _kPlugin = 8;
const Map<int, String> _kPluginFormats = {0: 'VST3', 1: 'CLAP'};

/// The effect chains a capture's arm snapshot recorded, as text: what each
/// track, input and the captured output played through when the take
/// started. Changes made during the take are in `events.log`, not here.
///
/// Every function reads the decoded `performance.json` and returns one line
/// per chain that has entries, or `null` when there are none.
abstract final class EffectText {
  /// Looper track [channel]'s chains: its Track stage, then each lane's.
  static String? track(Map<String, dynamic> manifest, int channel) {
    final arm = manifest['armSnapshot'];
    final lines = <String>[];
    for (final chain in _list(arm, 'trackChains')) {
      if (_int(chain['channel']) != channel) continue;
      final line = _chain(chain['effects'], chain['chainEnabled']);
      if (line != null) lines.add('Track: $line');
    }
    for (final t in tracksOf(arm)) {
      if (_int(t['channel']) != channel) continue;
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final json = lane as Map<String, dynamic>;
        final line = _chain(json['effects'], json['chainEnabled']);
        if (line == null) continue;
        lines.add('Lane ${(_int(json['lane']) ?? 0) + 1}: $line');
      }
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// Hardware input [input]'s monitor chain.
  static String? input(Map<String, dynamic> manifest, int input) {
    for (final monitor in _list(manifest['armSnapshot'], 'monitors')) {
      if (_int(monitor['input']) != input) continue;
      return _chain(monitor['effects'], monitor['chainEnabled']);
    }
    return null;
  }

  /// The captured output's chain.
  static String? output(Map<String, dynamic> manifest) {
    final arm = manifest['armSnapshot'];
    if (arm is! Map<String, dynamic>) return null;
    return _chain(arm['outputEffects'], arm['outputChainEnabled']);
  }

  /// [effects] in order, consecutive entries of one rack grouped under its
  /// name, each switched-off entry or rack marked `off`; `null` when there
  /// are none.
  static String? _chain(Object? effects, Object? chainEnabled) {
    if (effects is! List) return null;
    final parts = <String>[];
    String? rackId;
    var rackLabel = '';
    final inRack = <String>[];
    void closeRack() {
      if (rackId != null) parts.add('$rackLabel (${inRack.join(', ')})');
      rackId = null;
      inRack.clear();
    }

    for (final effect in effects.whereType<Map<String, dynamic>>()) {
      final type = _int(effect['type']) ?? _kNone;
      if (type == _kNone) continue;
      final (id, label) = switch (effect['rack']) {
        {'id': final String id, 'name': final String name} && final rack => (
          id,
          rack['bypassed'] == true ? '$name off' : name,
        ),
        _ => (null, ''),
      };
      if (id != rackId) closeRack();
      if (id == null) {
        parts.add(_entry(effect, type));
        continue;
      }
      if (rackId == null) {
        rackId = id;
        rackLabel = label;
      }
      inRack.add(_entry(effect, type));
    }
    closeRack();
    if (parts.isEmpty) return null;
    final text = parts.join(', ');
    return chainEnabled == false ? '$text (chain off)' : text;
  }

  static String _entry(Map<String, dynamic> effect, int type) {
    final String name;
    if (type == _kPlugin) {
      final plugin = effect['plugin'] as Map<String, dynamic>?;
      final format = _kPluginFormats[_int(plugin?['format']) ?? 0] ?? 'plugin';
      name = '$format ${plugin?['id'] ?? 'plugin'}';
    } else {
      name = effectTypeNames[type] ?? 'Effect $type';
    }
    return effect['enabled'] == false ? '$name off' : name;
  }

  static List<Map<String, dynamic>> _list(Object? json, String key) {
    if (json is! Map<String, dynamic>) return const [];
    final list = json[key];
    if (list is! List) return const [];
    return [for (final e in list) ?(e is Map<String, dynamic> ? e : null)];
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}
