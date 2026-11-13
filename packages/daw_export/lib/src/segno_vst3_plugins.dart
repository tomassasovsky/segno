import 'dart:typed_data';

/// One of Segno's VST3 plugins (`packages/segno_engine/vst3`): the plugin
/// Live loads for a built-in effect kind.
class SegnoPlugin {
  /// Creates a [SegnoPlugin].
  const new({required this.name, required this.processorId});

  /// The plugin's name in Live.
  final String name;

  /// The processor's class id as four big-endian 32-bit words, the plugin's
  /// identity.
  final List<int> processorId;

  /// The class id as Live's `Uid/Fields.0..3`: each word as a signed 32-bit
  /// integer.
  List<int> get liveUidFields => [
    for (final word in processorId) word.toSigned(32),
  ];
}

/// Segno's plugins by `le_fx_type` code: every built-in kind but none and a
/// hosted plugin. The ids are `segno_fx_kinds.h`'s, which the tests check.
const Map<int, SegnoPlugin> segnoPlugins = {
  1: SegnoPlugin(
    name: 'Segno Drive',
    processorId: [0x3B6057BF, 0xB0624797, 0xABA2EBB8, 0x599AAE91],
  ),
  2: SegnoPlugin(
    name: 'Segno Filter',
    processorId: [0x20A68767, 0x71C5463A, 0x92BC2E0C, 0x3A02E613],
  ),
  3: SegnoPlugin(
    name: 'Segno Delay',
    processorId: [0x6E698A08, 0x1C5445D5, 0xB5C0F9A1, 0xF2543803],
  ),
  4: SegnoPlugin(
    name: 'Segno Tremolo',
    processorId: [0xD8E602FC, 0x6B25466E, 0xAEB1BB29, 0x337E80CD],
  ),
  5: SegnoPlugin(
    name: 'Segno Octaver',
    processorId: [0x7486BCEA, 0x59714B95, 0xBFE3C1F1, 0xF344FCFD],
  ),
  6: SegnoPlugin(
    name: 'Segno Echo',
    processorId: [0xDC732855, 0x0021497D, 0x8053CD50, 0x94B592D3],
  ),
  7: SegnoPlugin(
    name: 'Segno Reverb',
    processorId: [0x6E35F5DA, 0x6D4E406F, 0x8D41A81C, 0xBE7AB75F],
  ),
  9: SegnoPlugin(
    name: 'Segno EQ',
    processorId: [0x5F221E04, 0x34E74839, 0xB988C082, 0xCF758CD5],
  ),
  10: SegnoPlugin(
    name: 'Segno Compressor',
    processorId: [0x093244E1, 0x13BE424A, 0xB523A1F7, 0x1115929D],
  ),
  11: SegnoPlugin(
    name: 'Segno Transient',
    processorId: [0xBC421B2B, 0x1B414AEB, 0xA078BCE4, 0x440B9006],
  ),
  12: SegnoPlugin(
    name: 'Segno HP / Gate',
    processorId: [0xBE5C001E, 0xAD0F40C4, 0x81A1AAB7, 0x848F11B5],
  ),
  13: SegnoPlugin(
    name: 'Segno Doubler',
    processorId: [0x18613919, 0xB57F4BE3, 0x8A06BE4B, 0xAB3581C6],
  ),
  14: SegnoPlugin(
    name: 'Segno Chorus',
    processorId: [0x4CDD90BF, 0xAD6E42B9, 0x9BF7EBBD, 0xA91FF8B3],
  ),
  15: SegnoPlugin(
    name: 'Segno Wah',
    processorId: [0x27D1F229, 0x8C6944DF, 0xAEE761E0, 0x7DF17039],
  ),
  16: SegnoPlugin(
    name: 'Segno Overdrive',
    processorId: [0x05F5B34F, 0xA3094E55, 0x80299B01, 0x04C0A5CB],
  ),
  17: SegnoPlugin(
    name: 'Segno Distortion',
    processorId: [0x71C7F461, 0x30A94EDF, 0xA49D96FC, 0x7E81AF28],
  ),
  18: SegnoPlugin(
    name: 'Segno Vinyl',
    processorId: [0xF03164F2, 0x63044EAA, 0x89609B98, 0x0D51BA07],
  ),
  19: SegnoPlugin(
    name: 'Segno Degrade',
    processorId: [0x2C5FF786, 0x56F84B19, 0x81A68856, 0x3644BEE5],
  ),
  20: SegnoPlugin(
    name: 'Segno LPF',
    processorId: [0x5ED01649, 0x5706426D, 0x8C5FFD74, 0x36121AF9],
  ),
  21: SegnoPlugin(
    name: 'Segno Spring reverb',
    processorId: [0x18E14C30, 0x251B4735, 0x8FABA270, 0xADB195C7],
  ),
  22: SegnoPlugin(
    name: 'Segno Dub reverb',
    processorId: [0x7988FD87, 0x94D24BEA, 0xABBA557B, 0xD6F6DF4A],
  ),
  23: SegnoPlugin(
    name: 'Segno Ambience',
    processorId: [0x77D9FCDC, 0x6CAC42FE, 0x950885BF, 0xB18D91B6],
  ),
  24: SegnoPlugin(
    name: 'Segno Whammy',
    processorId: [0x6F56732E, 0x46264E80, 0xA861C6DE, 0x71B23ACD],
  ),
  25: SegnoPlugin(
    name: 'Segno Pumper',
    processorId: [0x2F1E61CC, 0x9892403F, 0x939A97CC, 0x33A9B20D],
  ),
  26: SegnoPlugin(
    name: 'Segno Slicer',
    processorId: [0x75C5A76B, 0x73B04920, 0xB23C72F3, 0x07E86AB9],
  ),
  27: SegnoPlugin(
    name: 'Segno Mode delay',
    processorId: [0xC32C951E, 0x2B9846FA, 0xB77984C9, 0x8418854A],
  ),
  28: SegnoPlugin(
    name: 'Segno Dual octaver',
    processorId: [0x2D7AF1A0, 0x90624EC0, 0x84535B6C, 0x73DC0897],
  ),
  29: SegnoPlugin(
    name: 'Segno Amp',
    processorId: [0x5A5E5968, 0xF68F438D, 0xB6CED6FC, 0x89754BC0],
  ),
  30: SegnoPlugin(
    name: 'Segno Modulation',
    processorId: [0x4DDE94C0, 0xAC4141EE, 0x95F044CC, 0xB6068D34],
  ),
  31: SegnoPlugin(
    name: 'Segno Room reverb',
    processorId: [0x2F3F3017, 0x29694686, 0x854E4D77, 0x1CA55889],
  ),
  32: SegnoPlugin(
    name: 'Segno Smart Tune',
    processorId: [0x8F8D32E7, 0xD14E4512, 0x82769C58, 0xCAD79196],
  ),
};

/// A Segno plugin's saved state: the bytes its `getState` writes and
/// `setState` reads (`segno_fx_state.h`, version 1), which Live keeps as the
/// device's `ProcessorState`.
class SegnoPluginState {
  /// Creates a [SegnoPluginState].
  const new({
    required this.type,
    required this.params,
    this.slot = 0,
    this.hopSeed = 0,
    this.clockOffset = 0,
    this.beatOffset = 0,
    this.input = 0,
    this.output = 0,
    this.placement = 0,
    this.level = 1,
    this.enabled = true,
  });

  /// The `le_fx_type` the plugin runs.
  final int type;

  /// The kind's settings, each `0..1`, in the engine's order.
  final List<double> params;

  /// The entry's index in its chain on the console.
  final int slot;

  /// The chain owner's octaver hop quarter.
  final int hopSeed;

  /// The engine frame Live's sample 0 stands for.
  final int clockOffset;

  /// The beat, in quarter notes, at Live's sample 0.
  final double beatOffset;

  /// `le_fx_chan_in`: 0 stereo, 1 left, 2 right, 3 mono sum.
  final int input;

  /// `le_fx_chan_out`: 0 stereo, 1 mono.
  final int output;

  /// Balance or pan, `-1..1`.
  final double placement;

  /// The entry's gain.
  final double level;

  /// The engine's enable bit for the entry.
  final bool enabled;

  /// The state's bytes.
  Uint8List encode() {
    final data = ByteData(56 + 4 * params.length);
    const magic = [0x53, 0x47, 0x46, 0x58]; // "SGFX"
    for (var i = 0; i < 4; i++) {
      data.setUint8(i, magic[i]);
    }
    data
      ..setUint32(4, 1, Endian.little)
      ..setInt32(8, type, Endian.little)
      ..setInt32(12, slot, Endian.little)
      ..setInt32(16, hopSeed, Endian.little)
      ..setUint32(20, clockOffset, Endian.little)
      ..setFloat64(24, beatOffset, Endian.little)
      ..setInt32(32, input, Endian.little)
      ..setInt32(36, output, Endian.little)
      ..setFloat32(40, placement, Endian.little)
      ..setFloat32(44, level, Endian.little)
      ..setInt32(48, enabled ? 1 : 0, Endian.little)
      ..setInt32(52, params.length, Endian.little);
    for (var i = 0; i < params.length; i++) {
      data.setFloat32(56 + 4 * i, params[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
