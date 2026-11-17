import 'package:daw_export/src/chain_timeline.dart';
import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:meta/meta.dart';

/// A device on a Live track: one of Segno's plugins, or an Audio Effect
/// Rack of them.
@immutable
sealed class DawDevice {
  const new();
}

/// One of Segno's plugins with the state it loads with, and what changed
/// in it during the take.
@immutable
final class DawPluginDevice extends DawDevice {
  /// Creates a [DawPluginDevice].
  const new({
    required this.plugin,
    required this.state,
    this.switching,
    this.parameters = const {},
  });

  /// The plugin.
  final SegnoPlugin plugin;

  /// Its settings and channel handling, its engine enable bit when the take
  /// starts ([SegnoPluginState.enabled]), and where the take stands in
  /// time.
  final SegnoPluginState state;

  /// Its engine enable bit during the take (1 on, 0 off), a step at each
  /// change, or `null` when it never changes. The plugin's own switch,
  /// which ramps and drains as the engine's does.
  final AutomationLane? switching;

  /// Each setting that changed during the take, by parameter id, as the
  /// plugin's normalized value: a step at each change.
  final Map<int, AutomationLane> parameters;
}

/// A Live Audio Effect Rack: chains that each start from the rack's input,
/// summed at their volumes.
@immutable
final class DawRackDevice extends DawDevice {
  /// Creates a [DawRackDevice].
  const new({
    required this.name,
    required this.chains,
    this.on = true,
    this.switching,
  });

  /// The rack's name in Live.
  final String name;

  /// Its chains, at least one.
  final List<DawRackChain> chains;

  /// Whether the rack is switched on when the take starts. Off, it passes
  /// its input through.
  final bool on;

  /// Its switch during the take (1 on, 0 off), a step at each change, or
  /// `null` when it never changes.
  final AutomationLane? switching;
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

  /// Input [source]'s monitor, its Input stage (`le_fx_monitor_hop_seed`).
  factory monitor(int source, {int clockOffset = 0, double beatOffset = 0}) =>
      ChainOrigin(
        hopSeed: _quarter(source + 1),
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
/// entries), as Live devices, with what [timeline] says changed in them
/// during the take (by default nothing: the chain as it was at arm, on when
/// [chainEnabled]).
///
/// - Each built-in effect becomes its Segno plugin, with its settings and
///   channel handling, on the chain slot it held (its index in [effects]),
///   its engine enable bit the entry's own and the chain's, and its
///   switching and setting changes as automation. A slot that held other
///   effects during the take has one plugin for each, next to each other,
///   each switched on while the slot held it (#1806 D6); one that held
///   none at arm gets them where it stands in the chain.
/// - A run of entries of one rack becomes an Audio Effect Rack named as the
///   rack, always on: a rack switch or an A/B press is its entries'
///   switches (#1806 D5), and each plugin carries its own. Inside it, a
///   run of entries on the Dub Rack's two parallel paths becomes a rack of
///   its own with an Amb and a Dub chain at the gains the section's
///   Amb-Dub Mix gives them, as the engine sums them (`fx_section_merge`),
///   switched on while any entry of the rack runs, as the engine fades the
///   section to its input when none does (`fx_rack_head`).
/// - A hosted plugin and an empty entry become nothing: the offline render
///   passes a hosted plugin through dry, so the set does too.
List<DawDevice> devicesOfChain(
  Object? effects, {
  required ChainOrigin origin,
  bool chainEnabled = true,
  ChainTimeline? timeline,
}) {
  final times =
      timeline ??
      ChainTimeline.atArm(effects: effects, chainEnabled: chainEnabled);
  final list = effects is List ? effects : const <Object?>[];
  final slots = times.slots;
  final length = [
    list.length,
    if (slots.isNotEmpty) slots.last + 1,
  ].reduce((a, b) => a > b ? a : b);
  final entries = [
    for (var i = 0; i < length; i++)
      (
        i,
        switch (i < list.length ? list[i] : null) {
          final Map<String, dynamic> e => e,
          _ => const <String, dynamic>{},
        },
      ),
  ];
  final devices = <DawDevice>[];
  var k = 0;
  while (k < entries.length) {
    final rack = _rackOf(entries[k].$2);
    if (rack == null) {
      devices.addAll(_plugins(entries[k], origin, times));
      k++;
      continue;
    }
    final members = <(int, Map<String, dynamic>)>[];
    while (k < entries.length && _rackOf(entries[k].$2)?.id == rack.id) {
      members.add(entries[k++]);
    }
    final inside = _rackDevices(members, origin, times);
    // A rack with nothing in it that sounds is nothing: no Segno plugin
    // and no parallel section (whose paths sum their input at their gains
    // even when every entry on them passes it through).
    if (!_holdsPlugin(inside)) continue;
    devices.add(
      DawRackDevice(
        name: rack.name,
        chains: [DawRackChain(name: rack.name, devices: inside)],
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
  ChainTimeline timeline,
) {
  final devices = <DawDevice>[];
  var k = 0;
  while (k < members.length) {
    if (_path(members[k].$2) == null) {
      devices.addAll(_plugins(members[k], origin, timeline));
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
      final params = _params(entry.$2);
      if (type == _kAmbVerb && mix == null && params.length > 2) {
        mix = params[2];
      }
      (path == 'amb' ? amb : dub).addAll(_plugins(entry, origin, timeline));
    }
    final (ambGain, dubGain) = pathGains(mix ?? _kAmbDubMixDefault);
    final runs = timeline.anyRuns(members.map((m) => m.$1));
    devices.add(
      DawRackDevice(
        name: 'Amb / Dub',
        on: runs.on,
        switching: runs.lane,
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

/// The plugins [entry]'s slot needs: one for each Segno effect [timeline]
/// says it held, none for a slot that held none.
List<DawPluginDevice> _plugins(
  (int, Map<String, dynamic>) entry,
  ChainOrigin origin,
  ChainTimeline timeline,
) {
  final (slot, json) = entry;
  final channels = json['channels'];
  final ch = channels is Map<String, dynamic>
      ? channels
      : const <String, dynamic>{};
  return [
    for (final held in timeline.slot(slot))
      DawPluginDevice(
        plugin: segnoPlugins[held.type]!,
        switching: held.switching,
        parameters: held.parameters,
        state: SegnoPluginState(
          type: held.type,
          params: held.params,
          slot: slot,
          hopSeed: origin.hopSeed,
          clockOffset: origin.clockOffset,
          beatOffset: origin.beatOffset,
          input: _kInputs[ch['input']] ?? 0,
          output: _kOutputs[ch['output']] ?? 0,
          placement: _double(ch['placement']) ?? 0,
          level: _double(ch['level']) ?? 1,
          enabled: held.enabled,
        ),
      ),
  ];
}

List<double> _params(Map<String, dynamic> json) {
  final params = json['params'];
  if (params is! List) return const [];
  return [
    for (final p in params)
      if (p is num) p.toDouble() else 0.0,
  ];
}

({String id, String name})? _rackOf(Map<String, dynamic> e) {
  final rack = e['rack'];
  if (rack is! Map<String, dynamic>) return null;
  final id = rack['id'];
  final name = rack['name'];
  if (id is! String || id.isEmpty || name is! String) return null;
  return (id: id, name: name);
}

/// The parallel path an entry is on, `amb` or `dub`, or `null`.
String? _path(Map<String, dynamic> e) => switch (e['rackPath']) {
  'amb' => 'amb',
  'dub' => 'dub',
  _ => null,
};

int? _int(Object? value) => value is num ? value.toInt() : null;

double? _double(Object? value) => value is num ? value.toDouble() : null;

/// Whether [devices] hold a Segno plugin or a parallel section anywhere.
bool _holdsPlugin(List<DawDevice> devices) => devices.any(
  (d) => switch (d) {
    DawPluginDevice() => true,
    DawRackDevice(:final chains) =>
      chains.length > 1 || chains.any((c) => _holdsPlugin(c.devices)),
  },
);
