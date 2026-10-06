import 'package:equatable/equatable.dart';

/// What a remap matches on the instrument's MIDI device.
enum RemapTrigger {
  /// A note number: Note On starts the chord, its Note Off releases it.
  note,

  /// A controller number: 64 and above starts the chord, below 64 releases.
  controller,
}

/// A pad remap: one incoming note or controller plays [notes] (a chord with
/// one identity) instead of its ordinary handling.
class NoteRemap extends Equatable {
  /// Creates a [NoteRemap].
  const NoteRemap({
    required this.trigger,
    required this.number,
    required this.notes,
    this.channel,
  });

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory NoteRemap.fromJson(Map<String, dynamic> json) => NoteRemap(
    trigger: RemapTrigger.values.byName(_string(json, 'trigger')),
    number: _int(json, 'number'),
    channel: json['channel'] as int?,
    notes: _ints(json, 'notes'),
  );

  /// Note or controller.
  final RemapTrigger trigger;

  /// The note or controller number, 0..127.
  final int number;

  /// The MIDI channel 1..16, or null for any.
  final int? channel;

  /// The notes played, 0..127 each.
  final List<int> notes;

  /// The JSON form.
  Map<String, dynamic> toJson() => {
    'trigger': trigger.name,
    'number': number,
    if (channel != null) 'channel': channel,
    'notes': notes,
  };

  @override
  List<Object?> get props => [trigger, number, channel, notes];
}

/// How an instrument plays its MIDI device. New instruments start disabled.
class MidiNoteInput extends Equatable {
  /// Creates a [MidiNoteInput].
  const MidiNoteInput({
    this.enabled = false,
    this.deviceId,
    this.channel,
    this.low = 0,
    this.high = 127,
    this.remaps = const [],
  });

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory MidiNoteInput.fromJson(Map<String, dynamic> json) => MidiNoteInput(
    enabled: json['enabled'] == true,
    deviceId: json['deviceId'] as String?,
    channel: json['channel'] as int?,
    low: json['low'] as int? ?? 0,
    high: json['high'] as int? ?? 127,
    remaps: [
      for (final r in (json['remaps'] as List<dynamic>? ?? const []))
        NoteRemap.fromJson(r as Map<String, dynamic>),
    ],
  );

  /// Whether the device plays this instrument at all.
  final bool enabled;

  /// The MIDI device (its inventory id), or null for none chosen.
  final String? deviceId;

  /// The MIDI channel 1..16, or null for All.
  final int? channel;

  /// The lowest note played.
  final int low;

  /// The highest note played.
  final int high;

  /// Pad remaps.
  final List<NoteRemap> remaps;

  /// This input with the named fields replaced.
  MidiNoteInput copyWith({
    bool? enabled,
    String? deviceId,
    int? channel,
    bool clearChannel = false,
    int? low,
    int? high,
    List<NoteRemap>? remaps,
  }) => MidiNoteInput(
    enabled: enabled ?? this.enabled,
    deviceId: deviceId ?? this.deviceId,
    channel: clearChannel ? null : channel ?? this.channel,
    low: low ?? this.low,
    high: high ?? this.high,
    remaps: remaps ?? this.remaps,
  );

  /// The JSON form.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (deviceId != null) 'deviceId': deviceId,
    if (channel != null) 'channel': channel,
    'low': low,
    'high': high,
    'remaps': [for (final r in remaps) r.toJson()],
  };

  @override
  List<Object?> get props => [enabled, deviceId, channel, low, high, remaps];
}

/// One computer-key row: a key that plays [notes].
class KeyMapping extends Equatable {
  /// Creates a [KeyMapping].
  const KeyMapping({required this.key, required this.notes});

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory KeyMapping.fromJson(Map<String, dynamic> json) =>
      KeyMapping(key: _string(json, 'key'), notes: _ints(json, 'notes'));

  /// The key's label as the keyboard reports it (`A`, `W`, …).
  final String key;

  /// The notes the key plays.
  final List<int> notes;

  /// The JSON form.
  Map<String, dynamic> toJson() => {'key': key, 'notes': notes};

  @override
  List<Object?> get props => [key, notes];
}

/// Computer-key playing (desktop builds only; the appliance keeps the rows
/// untouched and never plays them). New instruments start disabled with the
/// default rows.
class ComputerKeys extends Equatable {
  /// Creates [ComputerKeys].
  const ComputerKeys({this.enabled = false, this.mappings = defaultMappings});

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory ComputerKeys.fromJson(Map<String, dynamic> json) => ComputerKeys(
    enabled: json['enabled'] == true,
    mappings: [
      for (final m in (json['mappings'] as List<dynamic>? ?? const []))
        KeyMapping.fromJson(m as Map<String, dynamic>),
    ],
  );

  /// The default rows: A W S E D F T G Y H U J K play C3 (60) to C4 (72).
  static const List<KeyMapping> defaultMappings = [
    KeyMapping(key: 'A', notes: [60]),
    KeyMapping(key: 'W', notes: [61]),
    KeyMapping(key: 'S', notes: [62]),
    KeyMapping(key: 'E', notes: [63]),
    KeyMapping(key: 'D', notes: [64]),
    KeyMapping(key: 'F', notes: [65]),
    KeyMapping(key: 'T', notes: [66]),
    KeyMapping(key: 'G', notes: [67]),
    KeyMapping(key: 'Y', notes: [68]),
    KeyMapping(key: 'H', notes: [69]),
    KeyMapping(key: 'U', notes: [70]),
    KeyMapping(key: 'J', notes: [71]),
    KeyMapping(key: 'K', notes: [72]),
  ];

  /// Whether the keys play this instrument.
  final bool enabled;

  /// The rows, defaults included.
  final List<KeyMapping> mappings;

  /// The JSON form.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'mappings': [for (final m in mappings) m.toJson()],
  };

  @override
  List<Object?> get props => [enabled, mappings];
}

/// One instrument definition: a stable identity in a fixed engine slot.
class Instrument extends Equatable {
  /// Creates an [Instrument].
  const Instrument({
    required this.id,
    required this.slot,
    required this.name,
    required this.soundId,
    required this.params,
    this.midi = const MidiNoteInput(),
    this.keys = const ComputerKeys(),
  });

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory Instrument.fromJson(Map<String, dynamic> json) {
    final params = (json['params'] as List<dynamic>? ?? const [])
        .map((v) => (v as num).toDouble())
        .toList(growable: false);
    if (params.length != 3) {
      throw FormatException('An instrument needs three parameters', json);
    }
    return Instrument(
      id: _string(json, 'id'),
      slot: _int(json, 'slot'),
      name: _string(json, 'name'),
      soundId: _string(json, 'soundId'),
      params: params,
      midi: MidiNoteInput.fromJson(
        json['midi'] as Map<String, dynamic>? ?? const {},
      ),
      keys: ComputerKeys.fromJson(
        json['keys'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  /// The identity bindings and sessions name; never reused.
  final String id;

  /// The engine slot, 0..7: source `kInstrumentSourceBase + slot`.
  final int slot;

  /// The player's name for it.
  final String name;

  /// The sound's patch id (`piano`, `synth-bass`, …). A build that lacks it
  /// shows the sound as unavailable and keeps the definition.
  final String soundId;

  /// The sound family's three parameters, 0..100 each.
  final List<double> params;

  /// The MIDI input.
  final MidiNoteInput midi;

  /// The computer keys.
  final ComputerKeys keys;

  /// This instrument with the named fields replaced.
  Instrument copyWith({
    String? name,
    String? soundId,
    List<double>? params,
    MidiNoteInput? midi,
    ComputerKeys? keys,
  }) => Instrument(
    id: id,
    slot: slot,
    name: name ?? this.name,
    soundId: soundId ?? this.soundId,
    params: params ?? this.params,
    midi: midi ?? this.midi,
    keys: keys ?? this.keys,
  );

  /// The JSON form.
  Map<String, dynamic> toJson() => {
    'id': id,
    'slot': slot,
    'name': name,
    'soundId': soundId,
    'params': params,
    'midi': midi.toJson(),
    'keys': keys.toJson(),
  };

  @override
  List<Object?> get props => [id, slot, name, soundId, params, midi, keys];
}

/// A removed instrument whose slot still names recorded material: its name
/// labels the source, and the slot is not reused while it stands.
class Tombstone extends Equatable {
  /// Creates a [Tombstone].
  const Tombstone({required this.slot, required this.name});

  /// Decodes [json]; throws [FormatException] when it is malformed.
  factory Tombstone.fromJson(Map<String, dynamic> json) =>
      Tombstone(slot: _int(json, 'slot'), name: _string(json, 'name'));

  /// The slot it holds.
  final int slot;

  /// The removed instrument's name.
  final String name;

  /// The JSON form.
  Map<String, dynamic> toJson() => {'slot': slot, 'name': name};

  @override
  List<Object?> get props => [slot, name];
}

String _string(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! String) throw FormatException('Missing $key', json);
  return v;
}

int _int(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! int) throw FormatException('Missing $key', json);
  return v;
}

List<int> _ints(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! List || v.any((e) => e is! int)) {
    throw FormatException('Missing $key', json);
  }
  return List<int>.unmodifiable(v.cast<int>());
}
