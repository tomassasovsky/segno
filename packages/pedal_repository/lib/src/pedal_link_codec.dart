import 'dart:typed_data';

import 'package:pedal_repository/src/pedal_button.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';
import 'package:pedal_repository/src/pedal_mode.dart';
import 'package:pedal_repository/src/pedal_state_frame.dart';

/// The pedal link wire format, shared byte for byte with the console board
/// firmware (`firmware/console_board/pedal_link.h`).
///
/// Every message is one frame:
///
/// ```text
/// A5 <type> <len> <payload: len bytes> <xor>
/// ```
///
/// `xor` is the XOR of `type`, `len` and every payload byte. Plain 8-bit
/// bytes throughout: this is a point-to-point UART between two boards in one
/// enclosure, so there is no MIDI, no 7-bit packing and no version byte on
/// the state frame. [HelloMessage] carries [protocolVersion] so a firmware
/// built against another revision is visible in the log rather than silently
/// misread.
///
/// ### State payload (segno → board), [statePayloadLength] bytes
///
/// | byte   | meaning                                                    |
/// |--------|------------------------------------------------------------|
/// | 0      | flags: bit0 clearFadeActive, bit1 goodbye,                 |
/// |        | bit2 performanceArmed, bit3 countingIn                     |
/// | 1      | [PedalMode] index                                          |
/// | 2      | [PedalLooperMode] index                                    |
/// | 3      | [GlobalColor] index                                        |
/// | 4      | active bank (0 = A, 1 = B)                                 |
/// | 5      | selected track (0..7)                                      |
/// | 6..13  | [PedalTrackLed] index for tracks 0..7                      |
/// | 14..17 | loop length, microseconds, unsigned 32-bit little-endian   |
/// | 18     | master gain, `round(masterGain * 255)`                     |
///
/// Enum indices are the wire values: none of those enums may be reordered.
abstract final class PedalLinkCodec {
  /// The frame start byte.
  static const sync = 0xA5;

  /// The link protocol this codec speaks, reported by the board in
  /// [HelloMessage.protocolVersion].
  static const protocolVersion = 1;

  /// Message types, board → segno.
  static const typeButton = 0x01;

  /// See [typeButton].
  static const typeEncoder = 0x02;

  /// See [typeButton].
  static const typeHello = 0x03;

  /// Message types, segno → board.
  static const typeState = 0x10;

  /// See [typeState].
  static const typeLoopTop = 0x11;

  /// The number of payload bytes in a [StateMessage].
  static const statePayloadLength = 19;

  /// How often the board sends [HelloMessage], in milliseconds
  /// (`PEDAL_LINK_HELLO_MS`). The liveness clocks on both ends derive from
  /// it: `PedalRepository.helloTimeout` on this side, the board's frame
  /// watchdog on the other.
  static const helloIntervalMs = 1000;

  /// [helloIntervalMs] as a [Duration].
  static const helloInterval = Duration(milliseconds: helloIntervalMs);

  /// The payload length every message type carries, or `null` for a type this
  /// codec does not know. Every message is fixed-length, so the parser can
  /// reject a corrupted type or length byte the moment it sees it instead of
  /// committing to a bogus length and swallowing the frames behind it.
  static int? payloadLengthFor(int type) => switch (type) {
    typeButton => 2,
    typeEncoder => 1,
    typeHello => 3,
    typeState => statePayloadLength,
    typeLoopTop => 0,
    _ => null,
  };

  /// Serializes [message] to one complete frame.
  static Uint8List encode(PedalLinkMessage message) {
    final (type, payload) = switch (message) {
      ButtonMessage(:final button, :final pressed) => (
        typeButton,
        <int>[button.index, if (pressed) 1 else 0],
      ),
      EncoderMessage(:final delta) => (typeEncoder, <int>[delta & 0xFF]),
      HelloMessage(
        :final protocolVersion,
        :final firmwareMajor,
        :final firmwareMinor,
      ) =>
        (typeHello, <int>[protocolVersion, firmwareMajor, firmwareMinor]),
      StateMessage(:final frame) => (typeState, encodeStatePayload(frame)),
      LoopTopMessage() => (typeLoopTop, const <int>[]),
    };
    final out = Uint8List(4 + payload.length);
    out[0] = sync;
    out[1] = type;
    out[2] = payload.length;
    out.setRange(3, 3 + payload.length, payload);
    out[3 + payload.length] = checksum(type, payload);
    return out;
  }

  /// The XOR of [type], the payload length and every byte of [payload].
  static int checksum(int type, List<int> payload) {
    var x = type ^ payload.length;
    for (final b in payload) {
      x ^= b;
    }
    return x & 0xFF;
  }

  /// Decodes one frame's [type] and [payload] into a message, or `null` when
  /// the type is unknown or the payload does not fit it.
  static PedalLinkMessage? decode(int type, List<int> payload) {
    if (payload.length != payloadLengthFor(type)) return null;
    switch (type) {
      case typeButton:
        final button = PedalButtonIndex.fromIndex(payload[0]);
        if (button == null || payload[1] > 1) return null;
        return ButtonMessage(button, pressed: payload[1] == 1);
      case typeEncoder:
        return EncoderMessage(payload[0].toSigned(8));
      case typeHello:
        return HelloMessage(
          protocolVersion: payload[0],
          firmwareMajor: payload[1],
          firmwareMinor: payload[2],
        );
      case typeState:
        final frame = decodeStatePayload(payload);
        return frame == null ? null : StateMessage(frame);
      case typeLoopTop:
        return const LoopTopMessage();
      default:
        return null;
    }
  }

  /// The [statePayloadLength]-byte payload for [frame].
  static Uint8List encodeStatePayload(PedalStateFrame frame) {
    final p = Uint8List(statePayloadLength);
    p[0] =
        (frame.clearFadeActive ? 0x01 : 0) |
        (frame.isGoodbye ? 0x02 : 0) |
        (frame.performanceArmed ? 0x04 : 0) |
        (frame.countingIn ? 0x08 : 0);
    p[1] = frame.mode.index;
    p[2] = frame.looperMode.index;
    p[3] = frame.globalColor.index;
    p[4] = frame.activeBank;
    p[5] = frame.selectedTrack;
    for (var i = 0; i < PedalStateFrame.trackCount; i++) {
      p[6 + i] = frame.trackLeds[i].index;
    }
    final us = frame.loopLengthMicros;
    p[14] = us & 0xFF;
    p[15] = (us >> 8) & 0xFF;
    p[16] = (us >> 16) & 0xFF;
    p[17] = (us >> 24) & 0xFF;
    p[18] = (frame.masterGain.clamp(0.0, 1.0) * 255).round();
    return p;
  }

  /// The inverse of [encodeStatePayload]; `null` for a malformed payload
  /// (wrong length, an out-of-range enum index, a reserved flag bit set).
  /// Mirrors what the firmware does, so the golden fixtures pin both.
  static PedalStateFrame? decodeStatePayload(List<int> p) {
    if (p.length != statePayloadLength) return null;
    if (p[0] & ~0x0F != 0) return null;
    if (p[1] >= PedalMode.values.length) return null;
    if (p[2] >= PedalLooperMode.values.length) return null;
    if (p[3] >= GlobalColor.values.length) return null;
    if (p[4] > 1) return null;
    if (p[5] >= PedalStateFrame.trackCount) return null;
    final leds = <PedalTrackLed>[];
    for (var i = 0; i < PedalStateFrame.trackCount; i++) {
      final index = p[6 + i];
      if (index >= PedalTrackLed.values.length) return null;
      leds.add(PedalTrackLed.values[index]);
    }
    return PedalStateFrame(
      globalColor: GlobalColor.values[p[3]],
      trackLeds: leds,
      activeBank: p[4],
      selectedTrack: p[5],
      mode: PedalMode.values[p[1]],
      loopLengthMicros: p[14] | (p[15] << 8) | (p[16] << 16) | (p[17] << 24),
      clearFadeActive: p[0] & 0x01 != 0,
      isGoodbye: p[0] & 0x02 != 0,
      performanceArmed: p[0] & 0x04 != 0,
      masterGain: p[18] / 255.0,
      looperMode: PedalLooperMode.values[p[2]],
      countingIn: p[0] & 0x08 != 0,
    );
  }
}

/// Reassembles [PedalLinkMessage]s from a byte stream that arrives in
/// arbitrary chunks.
///
/// A frame is dropped, and the parser resynchronizes on the next
/// [PedalLinkCodec.sync], when its type is unknown, its length byte is not
/// the length that type carries, its checksum fails, or its payload does not
/// decode. Checking the type and length up front is what keeps one corrupted
/// byte from swallowing the frames behind it: the parser never reads more
/// bytes than the claimed type can legitimately have, and a sync byte found
/// in the type or length slot starts the next frame instead of being eaten.
/// [droppedFrames] counts the drops so a noisy line is visible rather than
/// silent.
class PedalLinkParser {
  final List<int> _payload = [];
  _ParseState _state = _ParseState.sync;
  int _type = 0;
  int _length = 0;

  /// How many frames were started and then thrown away.
  int droppedFrames = 0;

  /// Forgets a half-received frame, for a link that reopened its device.
  void reset() {
    _state = _ParseState.sync;
    _payload.clear();
  }

  /// Feeds [bytes] and returns every complete, valid message they finished.
  List<PedalLinkMessage> push(List<int> bytes) {
    final out = <PedalLinkMessage>[];
    for (final b in bytes) {
      switch (_state) {
        case _ParseState.sync:
          if (b == PedalLinkCodec.sync) _state = _ParseState.type;
        case _ParseState.type:
          if (PedalLinkCodec.payloadLengthFor(b) == null) {
            droppedFrames++;
            // A sync byte here is the start of the NEXT frame (a stray sync
            // or a glitch ate this one); consuming it would lose that frame.
            _state = b == PedalLinkCodec.sync
                ? _ParseState.type
                : _ParseState.sync;
          } else {
            _type = b;
            _state = _ParseState.length;
          }
        case _ParseState.length:
          if (b != PedalLinkCodec.payloadLengthFor(_type)) {
            droppedFrames++;
            _state = b == PedalLinkCodec.sync
                ? _ParseState.type
                : _ParseState.sync;
          } else {
            _length = b;
            _payload.clear();
            _state = _length == 0 ? _ParseState.checksum : _ParseState.payload;
          }
        case _ParseState.payload:
          _payload.add(b);
          if (_payload.length == _length) _state = _ParseState.checksum;
        case _ParseState.checksum:
          _state = _ParseState.sync;
          final message = b == PedalLinkCodec.checksum(_type, _payload)
              ? PedalLinkCodec.decode(_type, _payload)
              : null;
          if (message == null) {
            droppedFrames++;
          } else {
            out.add(message);
          }
      }
    }
    return out;
  }
}

enum _ParseState { sync, type, length, payload, checksum }
