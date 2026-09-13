import 'package:controller_repository/src/controller_input.dart';
import 'package:equatable/equatable.dart';

/// How a mapped control's MIDI messages are read.
///
/// Explicit, never guessed. A single CC byte cannot say whether it is a plain
/// 7-bit knob, the high half of a 14-bit one, or a relative encoder step: the
/// same `CC 21 = 64` means all three. So Learn is told the format first, and
/// every message is read in the format its mapping was saved with.
enum MidiProtocol {
  /// Ordinary 7-bit Note, CC and Program messages.
  standard,

  /// A CC 0–31 MSB and its CC 32–63 LSB, read as one 14-bit value.
  cc14,

  /// A CC 99/98 parameter selection, then CC 6/38 14-bit Data Entry.
  nrpn,

  /// A CC 0/32 bank selection, then the Program it applies to.
  bankProgram,

  /// A CC carrying a two's-complement step: 1–63 up, 65–127 down, 0 nothing.
  relative;

  /// Parses a persisted [name], or `null` when it names nothing.
  static MidiProtocol? tryParse(Object? name) {
    for (final protocol in values) {
      if (protocol.name == name) return protocol;
    }
    return null;
  }
}

/// The identity of one mapped MIDI control: the device it comes from, the
/// channel, the format it is read in, and the numbers that format needs.
///
/// Two sources that are the same control are [sameAs] each other; two that
/// would read any of the same raw messages [overlaps]. The second is the one
/// that matters for saving: a CC 21 knob and a 14-bit CC 21/53 knob on one
/// channel are different sources, and they cannot both be mapped, because
/// every message of one is a message of the other.
class MidiSource extends Equatable {
  /// Creates a [MidiSource].
  const MidiSource({
    required this.device,
    required this.kind,
    required this.number,
    this.channel,
    this.protocol = MidiProtocol.standard,
    this.parameter,
    this.bank,
  });

  /// Rebuilds a source from its [toJson] map, or `null` when the map does not
  /// describe a valid one.
  static MidiSource? fromJson(Map<String, dynamic> json) {
    final device = json['device'];
    final kind = ControllerSourceKind.fromName(json['kind'] as String?);
    final number = json['number'];
    final channel = json['channel'];
    final protocol = MidiProtocol.tryParse(json['protocol']);
    final parameter = json['parameter'];
    final bank = json['bank'];
    if (device is! String || kind == null || number is! int) return null;
    if (channel != null && channel is! int) return null;
    if (protocol == null) return null;
    if (parameter != null && parameter is! int) return null;
    if (bank != null && bank is! int) return null;
    final source = MidiSource(
      device: device,
      kind: kind,
      number: number,
      channel: channel as int?,
      protocol: protocol,
      parameter: parameter as int?,
      bank: bank as int?,
    );
    return source.isValid ? source : null;
  }

  /// The device it comes from, by its stable identity.
  final String device;

  /// Whether it is a Note, a CC or a Program — the message that CARRIES the
  /// control, which for NRPN is always Data Entry's CC 6.
  final ControllerSourceKind kind;

  /// The Note, CC or Program number: the MSB CC for 14-bit, CC 6 for NRPN,
  /// the Program for Bank + Program.
  final int number;

  /// The MIDI channel `0..15`, or `null` for All.
  final int? channel;

  /// How its messages are read.
  final MidiProtocol protocol;

  /// The NRPN parameter `0..16382`, for [MidiProtocol.nrpn] only.
  final int? parameter;

  /// The bank `0..16383`, for [MidiProtocol.bankProgram] only.
  final int? bank;

  /// The largest 14-bit value; NRPN reserves it as the null selection.
  static const int maxWord = 16383;

  /// Whether every field is in range and the fields fit the protocol.
  bool get isValid {
    if (device.isEmpty || !_isByte(number)) return false;
    final ch = channel;
    if (ch != null && (ch < 0 || ch > 15)) return false;
    return switch (protocol) {
      MidiProtocol.standard => parameter == null && bank == null,
      MidiProtocol.cc14 =>
        kind == ControllerSourceKind.midiCc &&
            number <= 31 &&
            parameter == null &&
            bank == null,
      MidiProtocol.nrpn =>
        kind == ControllerSourceKind.midiCc &&
            number == 6 &&
            _isWord(parameter) &&
            parameter != maxWord &&
            bank == null,
      MidiProtocol.bankProgram =>
        kind == ControllerSourceKind.midiProgram &&
            _isWord(bank) &&
            parameter == null,
      MidiProtocol.relative =>
        kind == ControllerSourceKind.midiCc &&
            parameter == null &&
            bank == null,
    };
  }

  /// Whether this and [other] are the same control: one device, one format,
  /// one number, the same NRPN parameter or bank, on channels that meet.
  bool sameAs(MidiSource other) =>
      isValid &&
      other.isValid &&
      device == other.device &&
      kind == other.kind &&
      number == other.number &&
      protocol == other.protocol &&
      _channelsMeet(other) &&
      parameter == other.parameter &&
      bank == other.bank;

  /// Whether this and [other] would read any of the same raw messages.
  ///
  /// Within one format that is [sameAs]: two NRPN parameters share their CCs
  /// on purpose, and Data Entry is routed by the selection, not by the bytes.
  /// Across formats it is any shared raw footprint on channels that meet, on
  /// the same device — the case a saved mapping must refuse, whether or not
  /// either mapping is enabled.
  bool overlaps(MidiSource other) {
    if (!isValid || !other.isValid) return false;
    if (device != other.device || !_channelsMeet(other)) return false;
    if (protocol == other.protocol) return sameAs(other);
    return footprint.intersection(other.footprint).isNotEmpty;
  }

  /// Every raw message this source reads, as `kind:number`.
  Set<String> get footprint => switch (protocol) {
    MidiProtocol.nrpn => const {'cc:6', 'cc:38', 'cc:98', 'cc:99'},
    MidiProtocol.cc14 => {'cc:$number', 'cc:${number + 32}'},
    MidiProtocol.bankProgram => {'cc:0', 'cc:32', 'program:$number'},
    MidiProtocol.standard || MidiProtocol.relative => {
      '${_kindToken(kind)}:$number',
    },
  };

  bool _channelsMeet(MidiSource other) =>
      channel == null || other.channel == null || channel == other.channel;

  /// Serializes this source with a fixed key order, omitting what its
  /// protocol does not use.
  Map<String, dynamic> toJson() => {
    'device': device,
    'kind': kind.name,
    'number': number,
    if (channel != null) 'channel': channel,
    'protocol': protocol.name,
    if (parameter != null) 'parameter': parameter,
    if (bank != null) 'bank': bank,
  };

  static bool _isByte(int value) => value >= 0 && value <= 127;

  static bool _isWord(int? value) =>
      value != null && value >= 0 && value <= maxWord;

  static String _kindToken(ControllerSourceKind kind) => switch (kind) {
    ControllerSourceKind.midiNote => 'note',
    ControllerSourceKind.midiCc => 'cc',
    ControllerSourceKind.midiProgram => 'program',
  };

  @override
  List<Object?> get props => [
    device,
    kind,
    number,
    channel,
    protocol,
    parameter,
    bank,
  ];
}

/// One complete control reading: which source, and its value.
class MidiControlEvent extends Equatable {
  /// Creates a [MidiControlEvent].
  const MidiControlEvent({
    required this.source,
    required this.value,
    required this.maximum,
    this.delta,
  });

  /// The control, with the channel it actually arrived on.
  final MidiSource source;

  /// The complete value: `0..127` for a 7-bit reading, `0..16383` for a
  /// 14-bit one. A Program carries its [maximum], which is the value a
  /// parameter mapped to it applies.
  final int value;

  /// The largest [value] this reading can carry.
  final int maximum;

  /// The step a relative reading moves by, or `null` for an absolute one.
  final int? delta;

  @override
  List<Object?> get props => [source, value, maximum, delta];
}

/// Reads raw MIDI messages in an explicit [MidiProtocol] and returns only
/// COMPLETE control readings.
///
/// Pure: it dispatches nothing and stores nothing beyond the partial messages
/// it is assembling. Partial state is kept separately for each device, channel
/// and protocol, so an NRPN selection on one channel cannot complete Data
/// Entry on another.
///
/// Receiver choices the accepted design records as prototype contracts that
/// need physical controller validation:
///
/// - a pair (14-bit value, NRPN selection, NRPN data, bank) completes only
///   when both halves arrive within [freshness] of the first, and a fresh
///   pair is required for every update — a controller sending only its
///   changed byte is outside this subset;
/// - RPN selection (CC 101/100) and the NRPN null selection cancel NRPN
///   state; Data Increment/Decrement (CC 96/97) is not mapped and discards
///   pending data;
/// - a partial bank pair invalidates the previous bank until a full one
///   completes.
class MidiDecoder {
  /// Creates a [MidiDecoder] reading time from [clock].
  MidiDecoder({required Duration Function() clock, this.freshness = _fresh})
    : _clock = clock;

  static const Duration _fresh = Duration(milliseconds: 100);

  final Duration Function() _clock;

  /// How long a pair's first half waits for its second.
  final Duration freshness;

  final Map<(String, int, MidiProtocol), _PartialState> _states = {};

  /// The complete reading [message] from [device] finishes in [protocol], or
  /// `null` when it completes nothing — a first half, a selection, a message
  /// the protocol does not read.
  MidiControlEvent? feed(
    String device,
    RawControllerInput message,
    MidiProtocol protocol,
  ) {
    final kind = message.kind;
    final number = message.id;
    final value = message.value;
    final channel = message.midiChannel;
    if (device.isEmpty || channel < 0 || channel > 15) return null;
    if (number < 0 || number > 127 || value < 0 || value > 127) return null;

    MidiSource source({
      required ControllerSourceKind kind,
      required int number,
      int? parameter,
      int? bank,
    }) => MidiSource(
      device: device,
      kind: kind,
      number: number,
      channel: channel,
      protocol: protocol,
      parameter: parameter,
      bank: bank,
    );

    switch (protocol) {
      case MidiProtocol.standard:
        final program = kind == ControllerSourceKind.midiProgram;
        return MidiControlEvent(
          source: source(kind: kind, number: number),
          value: program ? 127 : value,
          maximum: 127,
        );
      case MidiProtocol.relative:
        if (kind != ControllerSourceKind.midiCc) return null;
        return MidiControlEvent(
          source: source(kind: kind, number: number),
          value: value,
          maximum: 127,
          delta: value < 64 ? value : value - 128,
        );
      case MidiProtocol.cc14:
      case MidiProtocol.nrpn:
      case MidiProtocol.bankProgram:
        break;
    }

    final state = _states.putIfAbsent(
      (device, channel, protocol),
      _PartialState.new,
    );
    final now = _clock();

    switch (protocol) {
      case MidiProtocol.cc14:
        if (kind != ControllerSourceKind.midiCc || number > 63) return null;
        final msb = number % 32;
        final word = state.pair(
          'cc:$msb',
          now,
          freshness,
          high: number < 32,
          value: value,
        );
        if (word == null) return null;
        return MidiControlEvent(
          source: source(kind: ControllerSourceKind.midiCc, number: msb),
          value: word,
          maximum: MidiSource.maxWord,
        );
      case MidiProtocol.bankProgram:
        if (kind == ControllerSourceKind.midiCc &&
            (number == 0 || number == 32)) {
          state.bankReady = false;
          final bank = state.pair(
            'bank',
            now,
            freshness,
            high: number == 0,
            value: value,
          );
          if (bank != null) {
            state
              ..bank = bank
              ..bankReady = true;
          }
          return null;
        }
        if (kind != ControllerSourceKind.midiProgram || !state.bankReady) {
          return null;
        }
        return MidiControlEvent(
          source: source(
            kind: ControllerSourceKind.midiProgram,
            number: number,
            bank: state.bank,
          ),
          value: 127,
          maximum: 127,
        );
      case MidiProtocol.nrpn:
        if (kind != ControllerSourceKind.midiCc) return null;
        switch (number) {
          case 101 || 100:
            // An RPN selection: whatever NRPN was selected is not any more.
            state
              ..parameter = null
              ..clear('select')
              ..clear('data');
            return null;
          case 99 || 98:
            state
              ..parameter = null
              ..clear('data');
            final selected = state.pair(
              'select',
              now,
              freshness,
              high: number == 99,
              value: value,
            );
            if (selected != null && selected != MidiSource.maxWord) {
              state.parameter = selected;
            }
            return null;
          case 96 || 97:
            state.clear('data');
            return null;
          case 6 || 38:
            final parameter = state.parameter;
            if (parameter == null) return null;
            final data = state.pair(
              'data',
              now,
              freshness,
              high: number == 6,
              value: value,
            );
            if (data == null) return null;
            return MidiControlEvent(
              source: source(
                kind: ControllerSourceKind.midiCc,
                number: 6,
                parameter: parameter,
              ),
              value: data,
              maximum: MidiSource.maxWord,
            );
          default:
            return null;
        }
      case MidiProtocol.standard:
      case MidiProtocol.relative:
        return null;
    }
  }

  /// Discards partial messages from [device], or from every device.
  ///
  /// Called on disconnect, when Learn starts, and when control resets: a half
  /// assembled before any of those belongs to a moment that is over.
  void reset([String? device]) {
    if (device == null) {
      _states.clear();
    } else {
      _states.removeWhere((key, _) => key.$1 == device);
    }
  }
}

/// What one device, channel and protocol has half-received.
class _PartialState {
  final Map<String, _Pair> _pairs = {};
  int? parameter;
  int bank = 0;
  bool bankReady = false;

  /// Adds one half of the pair [key] and returns the complete 14-bit word, or
  /// `null` while the other half is still missing.
  ///
  /// A completed pair is forgotten, so the next update needs both halves again.
  int? pair(
    String key,
    Duration now,
    Duration freshness, {
    required bool high,
    required int value,
  }) {
    var pair = _pairs[key];
    if (pair == null || now - pair.at > freshness) {
      pair = _pairs[key] = _Pair(now);
    }
    if (high) {
      pair.high = value;
    } else {
      pair.low = value;
    }
    final msb = pair.high;
    final lsb = pair.low;
    if (msb == null || lsb == null) return null;
    _pairs.remove(key);
    return msb * 128 + lsb;
  }

  void clear(String key) => _pairs.remove(key);
}

class _Pair {
  _Pair(this.at);

  final Duration at;
  int? high;
  int? low;
}
