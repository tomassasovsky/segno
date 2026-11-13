import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:meta/meta.dart';

/// A device on a Live track: one of Segno's plugins, or an Audio Effect
/// Rack of them.
@immutable
sealed class DawDevice {
  const new();
}

/// One of Segno's plugins with the state it loads with.
@immutable
final class DawPluginDevice extends DawDevice {
  /// Creates a [DawPluginDevice].
  const new({required this.plugin, required this.state});

  /// The plugin.
  final SegnoPlugin plugin;

  /// Its settings, channel handling and enable bit, and where the take
  /// stands in time.
  final SegnoPluginState state;
}

/// A Live Audio Effect Rack: chains that each start from the rack's input,
/// summed at their volumes.
@immutable
final class DawRackDevice extends DawDevice {
  /// Creates a [DawRackDevice].
  const new({required this.name, required this.chains, this.on = true});

  /// The rack's name in Live.
  final String name;

  /// Its chains, at least one.
  final List<DawRackChain> chains;

  /// Whether the rack is switched on. Off, it passes its input through.
  final bool on;
}

/// One chain of a [DawRackDevice].
@immutable
final class DawRackChain {
  /// Creates a [DawRackChain].
  const new({required this.name, required this.devices, this.volume = 1});

  /// The chain's name in Live.
  final String name;

  /// Its devices, in order.
  final List<DawDevice> devices;

  /// Its volume, a linear gain.
  final double volume;
}

/// Where a chain ran on the console and when the take started, which every
/// plugin of it needs to render what the console rendered.
@immutable
class ChainOrigin {
  /// Creates a [ChainOrigin].
  const new({required this.hopSeed, this.clockOffset = 0, this.beatOffset = 0});

  /// Looper track [channel]'s lane [lane] (`le_fx_lane_hop_seed`).
  factory lane(
    int channel,
    int lane, {
    int clockOffset = 0,
    double beatOffset = 0,
  }) => ChainOrigin(
    hopSeed: _quarter(channel + lane),
    clockOffset: clockOffset,
    beatOffset: beatOffset,
  );

  /// Looper track [channel]'s bus, its Track stage (`le_fx_bus_hop_seed`).
  factory bus(int channel, {int clockOffset = 0, double beatOffset = 0}) =>
      ChainOrigin(
        hopSeed: _quarter(channel + 2),
        clockOffset: clockOffset,
        beatOffset: beatOffset,
      );

  /// The chain owner's octaver hop quarter, in frames.
  final int hopSeed;

  /// The engine frame of the take's first frame (its `PERF_ARMED` clock).
  final int clockOffset;

  /// The beat at the take's first frame.
  final double beatOffset;

  /// `le_fx_quarter_seed`: a quarter of the octaver's 256-frame hop.
  static int _quarter(int q) => (q & 3) * 64;
}

/// The Amb-Verb's code and its Amb-Dub Mix default, which sets a Dub Rack's
/// parallel section when the section holds no Amb-Verb.
const int _kAmbVerb = 23;
const double _kAmbDubMixDefault = 0.4;

const Map<String, int> _kInputs = {
  'stereo': 0,
  'left': 1,
  'right': 2,
  'monoSum': 3,
};
const Map<String, int> _kOutputs = {'stereo': 0, 'mono': 1};

/// [effects], a chain from a capture's arm snapshot (`TrackEffect.toJson`
/// entries), as Live devices.
///
/// - Each built-in effect becomes its Segno plugin, with its settings and
///   channel handling, on the chain slot it held (its index in [effects]).
///   Its enable bit is the engine's: the entry's own, and off with the whole
///   chain when [chainEnabled] is false.
/// - A run of entries of one rack becomes an Audio Effect Rack named as the
///   rack, off when the rack was. Inside it, a run of entries on the Dub
///   Rack's two parallel paths becomes a rack of its own with an Amb and a
///   Dub chain at the gains the section's Amb-Dub Mix gives them, as the
///   engine sums them (`fx_section_merge`).
/// - A hosted plugin and an empty entry become nothing: the offline render
///   passes a hosted plugin through dry, so the set does too.
List<DawDevice> devicesOfChain(
  Object? effects, {
  required ChainOrigin origin,
  bool chainEnabled = true,
}) {
  if (effects is! List) return const [];
  final entries = [
    for (var i = 0; i < effects.length; i++)
      if (effects[i] case final Map<String, dynamic> e) (i, e),
  ];
  final devices = <DawDevice>[];
  var k = 0;
  while (k < entries.length) {
    final rack = _rackOf(entries[k].$2);
    if (rack == null) {
      final plugin = _plugin(entries[k], origin, chainEnabled);
      if (plugin != null) devices.add(plugin);
      k++;
      continue;
    }
    final members = <(int, Map<String, dynamic>)>[];
    while (k < entries.length && _rackOf(entries[k].$2)?.id == rack.id) {
      members.add(entries[k++]);
    }
    devices.add(
      DawRackDevice(
        name: rack.name,
        on: !rack.bypassed,
        chains: [
          DawRackChain(
            name: rack.name,
            devices: _rackDevices(members, origin, chainEnabled),
          ),
        ],
      ),
    );
  }
  return devices;
}

/// A rack's entries as the devices of its chain, each parallel section a
/// rack of its own.
List<DawDevice> _rackDevices(
  List<(int, Map<String, dynamic>)> members,
  ChainOrigin origin,
  bool chainEnabled,
) {
  final devices = <DawDevice>[];
  var k = 0;
  while (k < members.length) {
    if (_path(members[k].$2) == null) {
      final plugin = _plugin(members[k], origin, chainEnabled);
      if (plugin != null) devices.add(plugin);
      k++;
      continue;
    }
    final amb = <DawDevice>[];
    final dub = <DawDevice>[];
    double? mix;
    while (k < members.length) {
      final path = _path(members[k].$2);
      if (path == null) break;
      final entry = members[k++];
      final type = _int(entry.$2['type']);
      // A bypassed Amb-Verb's mix still sets the section's, as the engine
      // reads it (fx_section_enter).
      if (type == _kAmbVerb && mix == null) mix = _params(entry.$2)[2];
      final plugin = _plugin(entry, origin, chainEnabled);
      if (plugin != null) (path == 'amb' ? amb : dub).add(plugin);
    }
    final (ambGain, dubGain) = pathGains(mix ?? _kAmbDubMixDefault);
    devices.add(
      DawRackDevice(
        name: 'Amb / Dub',
        chains: [
          DawRackChain(name: 'Amb', devices: amb, volume: ambGain),
          DawRackChain(name: 'Dub', devices: dub, volume: dubGain),
        ],
      ),
    );
  }
  return devices;
}

/// The Amb-Dub Mix law at [m] (`fx_path_targets`): the Amb path's gain and
/// the Dub path's.
(double, double) pathGains(double m) {
  final d = 2 * m.clamp(0.0, 1.0);
  final dub = d < 1 ? d * d : 1.0;
  final amb = d > 1 ? 1 - (d - 1) * (d - 1) : 1.0;
  return (amb, dub);
}

DawPluginDevice? _plugin(
  (int, Map<String, dynamic>) entry,
  ChainOrigin origin,
  bool chainEnabled,
) {
  final (slot, json) = entry;
  final type = _int(json['type']);
  final plugin = type == null ? null : segnoPlugins[type];
  if (plugin == null) return null;
  final channels = json['channels'];
  final ch = channels is Map<String, dynamic>
      ? channels
      : const <String, dynamic>{};
  return DawPluginDevice(
    plugin: plugin,
    state: SegnoPluginState(
      type: type!,
      params: _params(json),
      slot: slot,
      hopSeed: origin.hopSeed,
      clockOffset: origin.clockOffset,
      beatOffset: origin.beatOffset,
      input: _kInputs[ch['input']] ?? 0,
      output: _kOutputs[ch['output']] ?? 0,
      placement: (ch['placement'] as num?)?.toDouble() ?? 0,
      level: (ch['level'] as num?)?.toDouble() ?? 1,
      enabled: chainEnabled && json['enabled'] != false,
    ),
  );
}

List<double> _params(Map<String, dynamic> json) {
  final params = json['params'];
  if (params is! List) return const [];
  return [
    for (final p in params)
      if (p is num) p.toDouble() else 0.0,
  ];
}

({String id, String name, bool bypassed})? _rackOf(Map<String, dynamic> e) {
  final rack = e['rack'];
  if (rack is! Map<String, dynamic>) return null;
  final id = rack['id'];
  final name = rack['name'];
  if (id is! String || id.isEmpty || name is! String) return null;
  return (id: id, name: name, bypassed: rack['bypassed'] == true);
}

/// The parallel path an entry is on, `amb` or `dub`, or `null`.
String? _path(Map<String, dynamic> e) => switch (e['rackPath']) {
  'amb' => 'amb',
  'dub' => 'dub',
  _ => null,
};

int? _int(Object? value) => value is num ? value.toInt() : null;
