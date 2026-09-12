/*
 * pedal_protocol.h - the segno <-> pedal wire protocol, as a plain-C unit.
 *
 * This is the firmware side of the exact same contract segno's Dart `PedalCodec`
 * implements (packages/pedal_repository). It is deliberately free of any Arduino
 * / FastLED dependency so it can be:
 *   - #included by the segno_pedal.ino sketch, and
 *   - compiled on a host and unit-tested against the committed golden SysEx
 *     fixtures (firmware/test/test_pedal_protocol.c), the same .syx files segno
 *     tests against — proving both sides agree byte-for-byte.
 *
 * Frame on the wire (segno -> pedal), 26 bytes:
 *   F0 7D <ver> <type=01> <20 packed payload bytes> <checksum> F7
 * The 17-byte logical payload (the current fields, master gain included),
 * the 7-bit packing, and the XOR checksum match PedalCodec exactly (see that
 * file for the field table). <ver> is PEDAL_PROTOCOL_VERSION_V1 (0x01),
 * PEDAL_PROTOCOL_VERSION_V2 (0x02, D11), PEDAL_PROTOCOL_VERSION_V3 (0x03,
 * FX v3 part 5a) or PEDAL_PROTOCOL_VERSION_V4 (0x04, #763) — the payload's
 * byte *count* is identical at all four versions: v2 only claims 4
 * previously-unused bits in the existing flags byte (looper_mode +
 * counting_in), v3 only claims bit 1 of the active-bank byte as the mode
 * field's high bit so a third interaction mode (FX) fits, and v4 only
 * unreserves that field's fourth value for a fourth mode (custom); see
 * pedal_decode_frame.
 *
 * This file is mirrored byte-for-byte in
 * hardware/firmware/segno_pedal_32u4/ — firmware/test/run_tests.sh fails if
 * the two copies drift.
 */
#ifndef SEGNO_PEDAL_PROTOCOL_H
#define SEGNO_PEDAL_PROTOCOL_H

#include <stdint.h>

#define PEDAL_TRACK_COUNT 8
#define PEDAL_MANUFACTURER_ID 0x7D
/* Wire protocol version 1 (pre-B5a): flags byte bits 4-7 are unused/reserved
 * and always zero -- no looper_mode / counting_in on this wire. */
#define PEDAL_PROTOCOL_VERSION_V1 0x01
/* Wire protocol version 2 (D11): flags byte bits 4-6 carry the looper-mode
 * code (PEDAL_LOOPER_MODE_*), bit 7 carries counting_in. Same 17-byte
 * payload as v1 -- the flags byte had the headroom. */
#define PEDAL_PROTOCOL_VERSION_V2 0x02
/* Wire protocol version 3 (FX v3 part 5a): the interaction-mode
 * field widens to 2 bits so PEDAL_MODE_FX fits -- low bit stays flags
 * bit 0, the high bit claims bit 1 of the active-bank byte (payload byte 2,
 * which used 1 of its 8 bits). Same 17-byte payload again; the mode field
 * is the only wire difference from v2 (R8: no other growth). */
#define PEDAL_PROTOCOL_VERSION_V3 0x03
/* Wire protocol version 4 (current, #763): two changes, both about what the
 * plate can SAY.
 *
 * The mode field's fourth value (0b11) stops being reserved and becomes
 * PEDAL_MODE_CUSTOM. A version of its own is unavoidable for that: every
 * deployed v3 decoder REJECTS a frame carrying mode 3, so a fourth mode
 * could not ride v3 without darkening the pedal it reached. Encoding a
 * custom frame below v4 writes the mode as PEDAL_MODE_PLAY (mute), the same
 * inert-safe degrade FX takes below v3.
 *
 * And the payload grows for the first time since v1: 30 bytes carrying one
 * RGB triplet per footswitch (pedal_frame.pedal_colors, indexed by
 * PEDAL_BTN_*), so each of the ten indicators can be given its own hue.
 * The earlier zero-growth call rejected exactly this as bytes for feedback
 * no hardware could show -- true of the six single LEDs the v2 faceplate had
 * then, and no longer true of the ten 8-LED colour pills it has now (#930).
 * Raw RGB rather than a palette index: the colours a user picks are exact,
 * the frame is pushed a handful of times a second, and 30 bytes that rarely
 * change cost less than a palette the pedal could hold a stale copy of. */
#define PEDAL_PROTOCOL_VERSION_V4 0x04
/* The version pedal_encode_frame emits when a pedal_frame carries no
 * remembered version (protocol_version == 0) -- i.e. the newest this unit
 * speaks. Also the wire-protocol revision the identity reply reports (the
 * value #331's version discovery will read). Decoded frames instead
 * re-emit at whatever version they arrived at (see
 * pedal_frame.protocol_version) so the host contract test's
 * decode-then-reencode round trip is version-preserving.
 *
 * NOTE this deliberately does NOT mirror the Dart side's encode default:
 * PedalCodec.protocolVersion stays pinned at v2 as the app's R6 safety
 * floor (an app must never send v3 to a pedal that has not negotiated it),
 * while this constant tracks the newest version the FIRMWARE decodes.
 * pedal_encode_frame is host-test-only today; any future runtime C encode
 * path must pass an explicitly negotiated protocol_version rather than
 * relying on this newest-version fallback. */
#define PEDAL_PROTOCOL_VERSION PEDAL_PROTOCOL_VERSION_V4
#define PEDAL_MSG_TYPE_STATE 0x01
#define PEDAL_SYSEX_START 0xF0
#define PEDAL_SYSEX_END 0xF7

/* System real-time "Start" byte, reused as the loop-top pulse. */
#define PEDAL_LOOP_TOP 0xFA
/* The relative CC the encoder reports / the pedal sends (binary-offset). */
#define PEDAL_ENCODER_CC 0x10

/* The absolute CC each external CTRL jack's expression position arrives on.
 *
 * An expression pedal is a potentiometer the console board reads on the same
 * jack a switch would use, so its position reaches segno on the link the
 * footswitches and the encoder already share -- as a Control Change whose
 * value is the RAW reading, 0 at one mechanical end and 0x7F at the other.
 * Which end is which is not fixed: the app calibrates, and accepts a pedal
 * wired the other way round. Keep these in step with PedalExpressionJack in
 * packages/pedal_repository.
 *
 * The board sends each jack's CURRENT position once when the link comes up,
 * and then on change. That initial report is what lets the app tell a jack
 * with nothing plugged into it from a pedal simply standing still: a jack that
 * has said nothing has nothing on it. A pedal pulled out afterwards cannot be
 * reported at all on this wire -- its position just stops changing.
 *
 * 7 bits of raw travel, one message: the inbound side of this link is 3-byte
 * MIDI only (segno's capture drops SysEx), so a higher-resolution position
 * would need an MSB/LSB pair and a half-assembled value held between two
 * messages. 128 raw steps is what a commercial expression input delivers; a
 * calibration near the app's 10% minimum span cuts that to about 13, so if
 * the bench shows that stepping, the answer is a 14-bit CC pair here rather
 * than anything the app can do about it. */
#define PEDAL_EXPRESSION_CTRL1_CC 0x11
#define PEDAL_EXPRESSION_CTRL2_CC 0x12
/* The raw value at a mechanical end -- the full 7-bit CC range. */
#define PEDAL_EXPRESSION_MAX 0x7F

/* The largest state frame, for output buffers (60 in practice at v4, 26 at
 * v3 and below). */
#define PEDAL_FRAME_MAX_BYTES 64

/* Per-track LED, matching PedalTrackLed. BLUE (FX v3 part 5a) is the
 * FX-mode chain-enabled color part 5b's app-side projection emits -- the
 * firmware renders it verbatim like every other entry, with no mode branch
 * in the track-LED path (R8/A3). */
enum {
  PEDAL_LED_OFF = 0,
  PEDAL_LED_GREEN = 1,
  PEDAL_LED_RED = 2,
  PEDAL_LED_BLUE = 3,
  PEDAL_LED_COUNT = 4
};

/* The pedal's interaction mode (pedal_frame.play_mode), matching PedalMode.
 * A 2-bit wire field since protocol v3: low bit in flags bit 0, high bit in
 * bit 1 of the active-bank byte. The fourth wire value (3) was reserved
 * until v4 and is PEDAL_MODE_CUSTOM from v4 on; a v3 frame carrying it is
 * still rejected, which is exactly why a fourth mode needed a version. On a
 * v1/v2 wire only the low bit exists, so those frames can never decode to
 * PEDAL_MODE_FX or PEDAL_MODE_CUSTOM. This is a DIFFERENT axis from
 * PEDAL_LOOPER_MODE_* (the engine's transport mode). */
enum {
  PEDAL_MODE_REC = 0,
  PEDAL_MODE_PLAY = 1,
  PEDAL_MODE_FX = 2,
  PEDAL_MODE_CUSTOM = 3,
  PEDAL_MODE_COUNT = 4
};

/* Global / mode color, matching GlobalColor. */
enum {
  PEDAL_GLOBAL_OFF = 0,
  PEDAL_GLOBAL_GREEN = 1,
  PEDAL_GLOBAL_RED = 2,
  PEDAL_GLOBAL_AMBER = 3,
  PEDAL_GLOBAL_BLUE = 4,
  PEDAL_GLOBAL_COUNT = 5
};

/* Looper-mode wire code (protocol v2, D11), matching PedalLooperMode
 * value-for-value -- do not reorder. This is a DIFFERENT axis from
 * pedal_frame.play_mode (the pedal's own Rec/Play interaction mode, wire
 * bit 0, unaffected by v2): this is the engine's looper transport mode
 * (Multi/Sync/Song/Band/Free). Values 5-7 are reserved/unused; a v2 decode
 * rejects them. */
enum {
  PEDAL_LOOPER_MODE_MULTI = 0,
  PEDAL_LOOPER_MODE_SYNC = 1,
  PEDAL_LOOPER_MODE_SONG = 2,
  PEDAL_LOOPER_MODE_BAND = 3,
  PEDAL_LOOPER_MODE_FREE = 4,
  PEDAL_LOOPER_MODE_COUNT = 5
};

/* The fixed Note number each footswitch transmits, matching PedalButton. */
enum {
  PEDAL_BTN_REC_PLAY = 0,
  PEDAL_BTN_STOP = 1,
  PEDAL_BTN_UNDO = 2,
  PEDAL_BTN_MODE = 3,
  PEDAL_BTN_TRACK1 = 4,
  PEDAL_BTN_TRACK2 = 5,
  PEDAL_BTN_TRACK3 = 6,
  PEDAL_BTN_TRACK4 = 7,
  PEDAL_BTN_CLEAR = 8,
  PEDAL_BTN_BANK = 9,
  PEDAL_BTN_COUNT = 10
};

/* The Note number each switch on the two external CTRL jacks transmits.
 *
 * The console board reads those jacks alongside the ten footswitches and the
 * encoder, so an external switch reaches segno the way a footswitch does. The
 * numbers follow the plate's, so a build that predates them decodes nothing
 * rather than mistaking one for a footswitch. Append, never renumber: keep
 * these in step with PedalExternalSwitch in packages/pedal_repository.
 *
 * A single pedal uses only the first switch of its jack's pair. These are
 * INPUT numbers; nothing in the state frame addresses an external switch. */
enum {
  PEDAL_EXT_CTRL1_FIRST = PEDAL_BTN_COUNT + 0,
  PEDAL_EXT_CTRL1_SECOND = PEDAL_BTN_COUNT + 1,
  PEDAL_EXT_CTRL2_FIRST = PEDAL_BTN_COUNT + 2,
  PEDAL_EXT_CTRL2_SECOND = PEDAL_BTN_COUNT + 3,
  PEDAL_EXT_COUNT = 4
};

/* One indicator hue (protocol v4). Full 8-bit RGB, matching the WS2812 the
 * pills and the V1 indicators are built from, so a colour the user picked
 * reaches the LED unquantised. */
typedef struct pedal_color {
  uint8_t r;
  uint8_t g;
  uint8_t b;
} pedal_color;

/* What a pedal's indicator uses when nothing has chosen a colour for it: the
 * palette's white, which is also what it assigns to all ten before a user
 * opens the editor. One number, not one on each side -- keep it in step with
 * PedalColor.white in packages/pedal_repository. Short of 0xFFFFFF on
 * purpose: a WS2812 run flat out washes its own hue out at the distance a
 * foot reads it from. */
#define PEDAL_COLOR_DEFAULT_R 0xE6u
#define PEDAL_COLOR_DEFAULT_G 0xEEu
#define PEDAL_COLOR_DEFAULT_B 0xF9u

/* The decoded looper state the pedal renders. */
typedef struct pedal_frame {
  uint8_t play_mode;  /* PEDAL_MODE_*: 0 = Rec, 1 = Play, 2 = FX (v3) */
  uint8_t clear_fade; /* clear-all fade in progress */
  uint8_t goodbye;    /* shutdown frame: darken everything */
  /* D-PEDAL: the host reports performance-recording armed here; the pedal
   * does NOT render it. It used to blink the mode LED red; armed already
   * shows on segno's screens, and the mode LED now reports the
   * interaction mode only (solid in every state). */
  uint8_t performance_armed;
  uint8_t global_color;
  uint8_t active_bank; /* 0 = A, 1 = B */
  uint8_t armed_track; /* 0..7 */
  uint8_t track_leds[PEDAL_TRACK_COUNT];
  /* protocol v4 (#763): the hue each footswitch's indicator uses, indexed by
   * PEDAL_BTN_*. Carried below v4 as PEDAL_COLOR_DEFAULT for every pedal --
   * the wire had no bytes for it, so a v1/v2/v3 decode reports the default
   * rather than inventing one. */
  pedal_color pedal_colors[PEDAL_BTN_COUNT];
  uint32_t loop_length_micros;
  uint8_t master_gain; /* engine master output gain, 0..255 (255 = unity) */
  /* protocol v2 (D11); PEDAL_LOOPER_MODE_MULTI / 0 on a v1-decoded frame --
   * the wire never carried anything else at v1. */
  uint8_t looper_mode;
  uint8_t counting_in;
  /* The version this frame was decoded at (PEDAL_PROTOCOL_VERSION_V1/V2/V3),
   * or 0 for a frame that was never decoded (freshly constructed by a
   * caller). pedal_encode_frame re-emits at this version when non-zero, so
   * the host contract test's decode -> re-encode round trip reproduces the
   * exact bytes it started from regardless of which version they were.
   * Firmware itself never calls pedal_encode_frame at runtime (see its doc
   * comment) -- this field only matters to the host test. */
  uint8_t protocol_version;
} pedal_frame;

#ifdef __cplusplus
extern "C" {
#endif

/* Decodes a complete SysEx message (F0..F7) into *out. Accepts
 * PEDAL_PROTOCOL_VERSION_V1 through _V4 -- a v1 frame decodes with
 * looper_mode/counting_in at their defaults (v1 never carried them), and a
 * v1/v2 frame can never decode to PEDAL_MODE_FX (only v3 carries the mode
 * field's high bit). Returns 1 on success, 0 for any malformed /
 * unrecognized-version / bad-checksum / out-of-range frame (including the
 * reserved fourth mode value) -- every field is validated before anything
 * is written, so on a 0 return *out is left completely untouched (the
 * caller keeps its last good frame). Never reads past `len`. */
int pedal_decode_frame(const uint8_t* msg, int len, pedal_frame* out);

/* Encodes *frame into `buf` (must hold PEDAL_FRAME_MAX_BYTES), at
 * frame->protocol_version if set (a decoded frame remembers its version),
 * else PEDAL_PROTOCOL_VERSION (the newest). Returns the number of bytes
 * written. Produces the exact bytes PedalCodec.encodeFrame does — the
 * firmware uses this only in its host contract test, not at runtime. */
int pedal_encode_frame(const pedal_frame* frame, uint8_t* buf);

/* Whether `msg` is the Universal Identity Request (F0 7E 7F 06 01 F7). */
int pedal_is_identity_request(const uint8_t* msg, int len);

/* Writes a 3-byte Note message for button `note` (a PEDAL_BTN_* value) into
 * `buf`: NoteOn velocity 127 when `pressed`, else NoteOff. Returns 3. */
int pedal_encode_button(uint8_t note, int pressed, uint8_t channel,
                        uint8_t* buf);

/* Writes the 3-byte relative-encoder CC for `delta` detents (binary-offset,
 * clamped to -64..+63) into `buf`. Returns 3. */
int pedal_encode_encoder(int delta, uint8_t channel, uint8_t* buf);

/* Writes the 3-byte absolute CC carrying an expression jack's position into
 * `buf`: `cc` is PEDAL_EXPRESSION_CTRL1_CC or PEDAL_EXPRESSION_CTRL2_CC and
 * `raw` is the reading, clamped to PEDAL_EXPRESSION_MAX. Returns 3.
 *
 * Raw, not calibrated: the board sends what it read, and which end of the
 * travel is heel is the app's to decide. */
int pedal_encode_expression(uint8_t cc, int raw, uint8_t channel,
                            uint8_t* buf);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_PEDAL_PROTOCOL_H */
