import 'dart:typed_data';

import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/event_log_reader.dart';
import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:meta/meta.dart';

/// The chain slots an engine chain has (`LE_FX_MAX`).
const int kChainSlots = 64;

/// What one chain did during a take, read from `events.log`
/// (`docs/formats/performance-event-log-format.md`): for each slot, every
/// effect it held, each with the frames its engine enable bit and its
/// settings changed at.
///
/// It replays the log as the offline render replays it for a lane's wet
/// stem (`perf_render.c`, `le_pr_wet_render`), from the chain the take
/// started with:
///
/// - an entry's switch (`LE_PLOG_SET_LANE_FX_ENABLED`, or
///   `LE_PLOG_SET_MONITOR_FX_ENABLED` for an input) and the chain's
///   (`..._CHAIN_ENABLED`): the effective bit is both. A rack switch or an
///   A/B press arrives as the switches of its entries, so it needs nothing
///   of its own;
/// - a setting (`LE_PLOG_SET_LANE_FX_PARAM`, `LE_PLOG_SET_MONITOR_FX_PARAM`);
/// - a type (`LE_CMD_SET_LANE_FX`, `LE_CMD_SET_MONITOR_INPUT_FX`): an actual
///   change puts the new type at its defaults and switches the entry on, as
///   the engine's setter does without logging either;
/// - the chain's length (`..._FX_COUNT`): a slot past it is not run, and a
///   slot entering it is switched on.
///
/// Entries at one frame all apply before that frame plays, so a change is
/// what stands after the last of them.
@immutable
class ChainTimeline {
  const new _(this._slots, this._effective, this._toBeat);

  /// Looper track [channel]'s lane [lane]: its chain at arm is [effects]
  /// (the arm snapshot's `TrackEffect.toJson` entries), on when
  /// [chainEnabled].
  factory lane(
    List<RawLogEntry> entries,
    int channel,
    int lane, {
    required Object? effects,
    required bool chainEnabled,
    required int sampleRate,
    required double tempoBpm,
  }) => ChainTimeline._read(
    entries,
    _LaneCodes(channel, lane),
    effects,
    chainEnabled,
    sampleRate,
    tempoBpm,
  );

  /// Input [input]'s monitor chain, as [ChainTimeline.lane] reads a lane's.
  factory monitor(
    List<RawLogEntry> entries,
    int input, {
    required Object? effects,
    required bool chainEnabled,
    required int sampleRate,
    required double tempoBpm,
  }) => ChainTimeline._read(
    entries,
    _MonitorCodes(input),
    effects,
    chainEnabled,
    sampleRate,
    tempoBpm,
  );

  /// The chain as it was at arm, with nothing changing: for a chain the
  /// log does not follow (a Track stage) or a take without a log.
  factory atArm({required Object? effects, required bool chainEnabled}) =>
      ChainTimeline._read(const [], null, effects, chainEnabled, 1, 60);

  factory _read(
    List<RawLogEntry> entries,
    _OwnerCodes? codes,
    Object? effects,
    bool chainEnabled,
    int sampleRate,
    double tempoBpm,
  ) {
    final chain = _Chain.atArm(effects, chainEnabled: chainEnabled);
    double toBeat(int frame) => frame / sampleRate * tempoBpm / 60;
    final devices = <int, List<_SlotDevice>>{};
    final effective = <int, _Steps>{};

    // Slot [s]'s devices and effective bit as they stand from [frame] on.
    void observe(int frame, int s) {
      final type = chain.types[s];
      final list = devices.putIfAbsent(s, () => []);
      if (segnoPlugins.containsKey(type) && !list.any((d) => d.type == type)) {
        list.add(_SlotDevice(type, chain.params[s], frame: frame));
      }
      final runs = chain.runs(s);
      for (final device in list) {
        final current = device.type == type;
        device.observe(
          frame,
          on: current && runs,
          params: current ? chain.params[s] : null,
        );
      }
      effective
          .putIfAbsent(s, () => _Steps(runs ? 1 : 0))
          .set(frame, runs ? 1 : 0);
    }

    // The entries at frame 0 apply before it plays: they are the start.
    final sorted = EventLogReader.sortedByFrame(entries);
    var i = 0;
    while (i < sorted.length && sorted[i].frame == 0) {
      codes?.apply(sorted[i++], chain);
    }
    for (var s = 0; s < kChainSlots; s++) {
      observe(0, s);
    }
    while (i < sorted.length) {
      final frame = sorted[i].frame;
      final touched = <int>{};
      for (; i < sorted.length && sorted[i].frame == frame; i++) {
        final slot = codes?.apply(sorted[i], chain);
        if (slot == null) continue;
        if (slot < 0) {
          touched.addAll(List.generate(kChainSlots, (s) => s));
        } else if (slot < kChainSlots) {
          touched.add(slot);
        }
      }
      for (final s in touched) {
        observe(frame, s);
      }
    }
    return ChainTimeline._(
      {
        for (final MapEntry(key: slot, value: list) in devices.entries)
          if (list.isNotEmpty) slot: [for (final d in list) d.timeline(toBeat)],
      },
      effective,
      toBeat,
    );
  }

  final Map<int, List<SlotTimeline>> _slots;
  final Map<int, _Steps> _effective;
  final double Function(int frame) _toBeat;

  /// The slots that held a Segno effect at some point, in order.
  Iterable<int> get slots => _slots.keys.toList()..sort();

  /// The devices slot [slot] needs, one per effect it held, the one it held
  /// at arm first; empty when it never held a Segno effect.
  List<SlotTimeline> slot(int slot) => _slots[slot] ?? const [];

  /// Whether any of [slots] runs, the way the engine switches a rack's
  /// crossfade (`fx_rack_head`): on at arm, and its changes, a step at
  /// each, or `null` when it never changes.
  ({bool on, AutomationLane? lane}) anyRuns(Iterable<int> slots) {
    final steps = _Steps.any([
      for (final s in slots) _effective[s] ?? _Steps(0),
    ]);
    return (on: steps.initial != 0, lane: steps.lane(_toBeat));
  }
}

/// One device a chain slot needs: an effect the slot held during the take.
@immutable
class SlotTimeline {
  /// Creates a [SlotTimeline].
  const new({
    required this.type,
    required this.params,
    required this.enabled,
    this.switching,
    this.parameters = const {},
  });

  /// The `le_fx_type` it runs.
  final int type;

  /// Its settings when the take starts: the arm snapshot's for the effect
  /// the slot held at arm, the kind's defaults for one that came later.
  final List<double> params;

  /// Whether the engine runs it when the take starts.
  final bool enabled;

  /// Its engine enable bit (1 on, 0 off) during the take, a step at each
  /// change, or `null` when it never changes. Off whenever the slot holds
  /// another effect, is past the chain's length, or is switched off.
  final AutomationLane? switching;

  /// Each setting that changed during the take, by plugin parameter id
  /// (its index), as normalized values: a step at each change.
  final Map<int, AutomationLane> parameters;
}

/// Points of a value that changes in steps: what it starts at and each
/// frame it changes at, the new value.
class _Steps {
  new(this.initial);

  /// The union of [all], 1 while any of them is not 0.
  factory any(List<_Steps> all) {
    // One sweep over every change in frame order, each member's value
    // carried as it goes.
    final values = [for (final s in all) s.initial];
    final changes = [
      for (var m = 0; m < all.length; m++)
        for (final (frame, value) in all[m]._changes) (frame, m, value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final union = _Steps(values.any((v) => v != 0) ? 1 : 0);
    var on = values.where((v) => v != 0).length;
    var i = 0;
    while (i < changes.length) {
      final frame = changes[i].$1;
      for (; i < changes.length && changes[i].$1 == frame; i++) {
        final (_, m, value) = changes[i];
        on += (value != 0 ? 1 : 0) - (values[m] != 0 ? 1 : 0);
        values[m] = value;
      }
      union.set(frame, on > 0 ? 1 : 0);
    }
    return union;
  }

  final double initial;
  final List<(int, double)> _changes = [];

  double get last => _changes.isEmpty ? initial : _changes.last.$2;

  void set(int frame, double value) {
    if (value != last) _changes.add((frame, value));
  }

  /// The steps as an envelope: two points at each change's beat, the value
  /// before it and the value after, Live's step. `null` for no change.
  AutomationLane? lane(double Function(int) toBeat) {
    if (_changes.isEmpty) return null;
    var before = initial;
    final points = <AutomationBreakpoint>[];
    for (final (frame, value) in _changes) {
      final beat = toBeat(frame);
      points
        ..add(AutomationBreakpoint(beat: beat, value: before))
        ..add(AutomationBreakpoint(beat: beat, value: value));
      before = value;
    }
    return AutomationLane(initialValue: initial, breakpoints: points);
  }
}

/// A slot's device while the timeline is read.
class _SlotDevice {
  new(this.type, List<double> params, {required int frame})
    : _arm = frame == 0,
      _start = List.of(params.take(segnoPlugins[type]!.parameters.length));

  final int type;

  /// Whether the slot held it at arm, so it starts as the slot did.
  final bool _arm;
  final List<double> _start;
  _Steps? _on;
  final Map<int, _Steps> _params = {};

  void observe(int frame, {required bool on, required List<double>? params}) {
    // A device that comes later starts off and comes on when it lands.
    (_on ??= _Steps(_arm && on ? 1 : 0)).set(frame, on ? 1 : 0);
    if (params == null) return;
    for (var p = 0; p < _start.length; p++) {
      _params.putIfAbsent(p, () => _Steps(_start[p])).set(frame, params[p]);
    }
  }

  SlotTimeline timeline(double Function(int) toBeat) => SlotTimeline(
    type: type,
    params: _start,
    enabled: _on!.initial != 0,
    switching: _on!.lane(toBeat),
    parameters: {
      for (final MapEntry(key: p, value: steps) in _params.entries)
        p: ?steps.lane(toBeat),
    },
  );
}

/// A chain's state as the replay moves it (`le_pr_fx_chain`).
class _Chain {
  new _(this.chainEnabled, this.count);

  /// The chain at arm, as `le_pr_fx_chain_init_from_lane` reads it: each
  /// entry on unless it says otherwise, its settings past what it lists at
  /// the kind's defaults (what the plugin runs them at).
  factory atArm(Object? effects, {required bool chainEnabled}) {
    final list = effects is List ? effects : const <Object?>[];
    final chain = _Chain._(
      chainEnabled,
      list.length > kChainSlots ? kChainSlots : list.length,
    );
    for (var s = 0; s < chain.count; s++) {
      final entry = list[s];
      if (entry is! Map<String, dynamic>) continue;
      final type = entry['type'];
      chain.types[s] = type is num ? type.toInt() : 0;
      chain.enabled[s] = entry['enabled'] != false;
      final params = entry['params'];
      final defaults = _defaults(chain.types[s]);
      for (var p = 0; p < defaults.length; p++) {
        final v = params is List && p < params.length ? params[p] : null;
        chain.params[s][p] = v is num ? v.toDouble() : defaults[p];
      }
    }
    return chain;
  }

  bool chainEnabled;
  int count;
  final List<int> types = List.filled(kChainSlots, 0);
  final List<bool> enabled = List.filled(kChainSlots, true);
  final List<List<double>> params = [
    for (var s = 0; s < kChainSlots; s++) List.filled(_kParams, 0),
  ];

  /// Whether the engine runs slot [s] with its effect on.
  bool runs(int s) => s < count && chainEnabled && enabled[s];

  // Each mutator returns the slot it moved, or -1 for every slot.

  int setType(int s, int type) {
    if (s < 0 || s >= kChainSlots || types[s] == type) return s;
    types[s] = type;
    final defaults = _defaults(type);
    for (var p = 0; p < _kParams; p++) {
      params[s][p] = p < defaults.length ? defaults[p] : 0;
    }
    enabled[s] = true;
    return s;
  }

  int setCount(int n) {
    final next = n < 0 ? 0 : (n > kChainSlots ? kChainSlots : n);
    for (var s = count; s < next; s++) {
      enabled[s] = true;
    }
    count = next;
    return -1;
  }

  int setParam(int s, int p, double value) {
    if (s >= 0 && s < kChainSlots && p >= 0 && p < _kParams) {
      params[s][p] = value;
    }
    return s;
  }

  int setEnabled(int s, {required bool on}) {
    if (s >= 0 && s < kChainSlots) enabled[s] = on;
    return s;
  }

  int setChainEnabled({required bool on}) {
    chainEnabled = on;
    return -1;
  }

  static List<double> _defaults(int type) => [
    for (final p in segnoPlugins[type]?.parameters ?? const <SegnoParameter>[])
      p.defaultValue,
  ];
}

/// `LE_FX_PARAMS`: the settings an entry holds.
const int _kParams = 32;

/// How one owner's chain changes are logged.
sealed class _OwnerCodes {
  /// Applies [e] to [chain] when it is one of this owner's: the slot it
  /// moved, -1 for every slot (the chain's switch or length), or `null` for
  /// an entry of another owner.
  int? apply(RawLogEntry e, _Chain chain);
}

/// A looper lane's (`fx` and `fxcount` arms carry `{channel, lane, ...}`).
final class _LaneCodes extends _OwnerCodes {
  new(this.channel, this.lane);

  final int channel;
  final int lane;

  static const int _type = 20; // LE_CMD_SET_LANE_FX
  static const int _count = 21; // LE_CMD_SET_LANE_FX_COUNT
  static const int _param = 306; // LE_PLOG_SET_LANE_FX_PARAM
  static const int _enabled = 310; // LE_PLOG_SET_LANE_FX_ENABLED
  static const int _chain = 311; // LE_PLOG_SET_LANE_FX_CHAIN_ENABLED

  @override
  int? apply(RawLogEntry e, _Chain chain) {
    final p = e.payload;
    if (!const {_type, _count, _param, _enabled, _chain}.contains(e.code) ||
        _i32(p, 0) != channel ||
        _i32(p, 4) != lane) {
      return null;
    }
    switch (e.code) {
      case _type:
        return chain.setType(_i32(p, 8), _i32(p, 12));
      case _count:
        return chain.setCount(_i32(p, 8));
      case _param:
        final packed = _i32(p, 8);
        return chain.setParam(packed >> 8, packed & 0xff, _f32(p, 12));
      case _enabled:
        return chain.setEnabled(_i32(p, 8), on: _i32(p, 12) != 0);
      default:
        return chain.setChainEnabled(on: _f32(p, 8) != 0);
    }
  }
}

/// An input's monitor (`fx` arms carry `{input, lane, ...}`, the chain
/// switch `{input, value}`).
final class _MonitorCodes extends _OwnerCodes {
  new(this.input);

  final int input;

  static const int _type = 31; // LE_CMD_SET_MONITOR_INPUT_FX
  static const int _count = 32; // LE_CMD_SET_MONITOR_INPUT_FX_COUNT
  static const int _param = 307; // LE_PLOG_SET_MONITOR_FX_PARAM
  static const int _enabled = 312; // LE_PLOG_SET_MONITOR_FX_ENABLED
  static const int _chain = 313; // LE_PLOG_SET_MONITOR_FX_CHAIN_ENABLED

  @override
  int? apply(RawLogEntry e, _Chain chain) {
    final p = e.payload;
    if (!const {_type, _count, _param, _enabled, _chain}.contains(e.code) ||
        _i32(p, 0) != input) {
      return null;
    }
    switch (e.code) {
      case _type:
        return chain.setType(_i32(p, 8), _i32(p, 12));
      case _count:
        return chain.setCount(_i32(p, 8));
      case _param:
        final packed = _i32(p, 8);
        return chain.setParam(packed >> 8, packed & 0xff, _f32(p, 12));
      case _enabled:
        return chain.setEnabled(_i32(p, 8), on: _i32(p, 12) != 0);
      default:
        return chain.setChainEnabled(on: _f32(p, 4) != 0);
    }
  }
}

int _i32(ByteData p, int at) => p.getInt32(at, Endian.little);

double _f32(ByteData p, int at) => p.getFloat32(at, Endian.little);
