/*
 * pedal_link.h - the Segno console board <-> segno wire format.
 *
 * Mirrored byte-for-byte by `PedalLinkCodec` in packages/pedal_repository. The
 * golden fixtures that package generates (test/fixtures/<name>.bin) are decoded and
 * re-encoded by firmware/test/test_pedal_link.c with THIS unit, so the two
 * cannot drift without a test failing.
 *
 * Every message is one frame on the UART:
 *
 *     A5 <type> <len> <payload: len bytes> <xor>
 *
 * xor = XOR of type, len and every payload byte. Plain 8-bit bytes: a
 * point-to-point UART between two boards in one enclosure, so no MIDI, no
 * 7-bit packing, no version byte on the state frame. HELLO carries the
 * protocol version so a mismatched build shows up in segno's log.
 *
 * Plain C99, no Arduino dependencies, so the host test compiles it as-is.
 */
#ifndef PEDAL_LINK_H
#define PEDAL_LINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PEDAL_LINK_SYNC 0xA5u
#define PEDAL_LINK_PROTOCOL_VERSION 1u

/* board -> segno */
#define PEDAL_LINK_TYPE_BUTTON 0x01u   /* [button, pressed] */
#define PEDAL_LINK_TYPE_ENCODER 0x02u  /* [int8 delta] */
/* HELLO is frozen for every protocol version: type 0x03, three bytes, the
 * protocol version first. It is how a board built against another revision is
 * recognised as incompatible at all; a revision that needs more from the board
 * adds a message type, never a hello byte. */
#define PEDAL_LINK_TYPE_HELLO 0x03u    /* [protocol, fw major, fw minor] */
/* segno -> board */
#define PEDAL_LINK_TYPE_STATE 0x10u    /* [PEDAL_LINK_STATE_LEN bytes] */

#define PEDAL_LINK_STATE_LEN 19u
#define PEDAL_LINK_MAX_PAYLOAD 32u
#define PEDAL_LINK_MAX_FRAME (4u + PEDAL_LINK_MAX_PAYLOAD)

/* Liveness, both directions, derived from one cadence. The board sends HELLO
 * every PEDAL_LINK_HELLO_MS; segno answers each with its current STATE and
 * counts the board as gone after a few missed hellos (PedalRepository's
 * helloTimeout). The board goes dark after PEDAL_LINK_FRAME_TIMEOUT_MS
 * without a STATE, so that must span more than one hello or a single lost
 * reply blanks the panel. Pinned against the Dart side by
 * packages/pedal_repository/test/pedal_link_header_test.dart. */
#define PEDAL_LINK_HELLO_MS 1000u
#define PEDAL_LINK_FRAME_TIMEOUT_MS 5000u

/* Footswitches, in wire order (= PedalButton's declaration order). */
enum {
  PEDAL_BTN_REC_PLAY = 0,
  PEDAL_BTN_STOP,
  PEDAL_BTN_UNDO,
  PEDAL_BTN_MODE,
  PEDAL_BTN_TRACK1,
  PEDAL_BTN_TRACK2,
  PEDAL_BTN_TRACK3,
  PEDAL_BTN_TRACK4,
  PEDAL_BTN_CLEAR,
  PEDAL_BTN_BANK,
  PEDAL_BTN_COUNT
};

#define PEDAL_TRACK_COUNT 8u

/* Enum wire values, mirroring the Dart enums' declaration order. */
enum { PEDAL_MODE_REC = 0, PEDAL_MODE_PLAY, PEDAL_MODE_FX, PEDAL_MODE_COUNT };
enum {
  PEDAL_LOOPER_MULTI = 0,
  PEDAL_LOOPER_SYNC,
  PEDAL_LOOPER_SONG,
  PEDAL_LOOPER_BAND,
  PEDAL_LOOPER_FREE,
  PEDAL_LOOPER_COUNT
};
enum {
  PEDAL_GLOBAL_OFF = 0,
  PEDAL_GLOBAL_GREEN,
  PEDAL_GLOBAL_RED,
  PEDAL_GLOBAL_AMBER,
  PEDAL_GLOBAL_BLUE,
  PEDAL_GLOBAL_COUNT
};
enum { PEDAL_LED_OFF = 0, PEDAL_LED_GREEN, PEDAL_LED_RED, PEDAL_LED_BLUE, PEDAL_LED_COUNT };

/* The decoded STATE payload. Byte layout (see PedalLinkCodec):
 *   0      flags: bit0 clear_fade, bit1 goodbye, bit2 performance_armed,
 *          bit3 counting_in (bits 4-7 reserved, must be zero)
 *   1      mode          2 looper_mode   3 global_color
 *   4      active_bank   5 selected_track
 *   6..13  track_leds[0..7]
 *   14..17 loop_length_micros, uint32 little-endian
 *   18     master_gain, 0..255
 */
typedef struct pedal_state {
  uint8_t clear_fade;
  uint8_t goodbye;
  uint8_t performance_armed;
  uint8_t counting_in;
  uint8_t mode;
  uint8_t looper_mode;
  uint8_t global_color;
  uint8_t active_bank;
  uint8_t selected_track;
  uint8_t track_leds[PEDAL_TRACK_COUNT];
  uint32_t loop_length_micros;
  uint8_t master_gain;
} pedal_state;

/* Frame a payload. `out` must hold PEDAL_LINK_MAX_FRAME bytes. Returns the
 * frame length, or 0 if the payload is too long. */
size_t pedal_link_encode(uint8_t type, const uint8_t *payload, uint8_t len, uint8_t *out);

size_t pedal_link_encode_button(uint8_t button, uint8_t pressed, uint8_t *out);
size_t pedal_link_encode_encoder(int8_t delta, uint8_t *out);
size_t pedal_link_encode_hello(uint8_t fw_major, uint8_t fw_minor, uint8_t *out);
size_t pedal_link_encode_state(const pedal_state *state, uint8_t *out);

/* Decode a STATE payload. Returns 1 on success, 0 for a wrong length, an
 * out-of-range enum, a reserved flag bit, an active_bank > 1 or a
 * selected_track >= PEDAL_TRACK_COUNT - the same rejections as the Dart side. */
int pedal_link_decode_state(const uint8_t *payload, uint8_t len, pedal_state *out);

/* The payload length a message type carries, or -1 for a type this codec does
 * not know. Every message is fixed-length, so a parser can reject a corrupted
 * type or length byte the moment it sees it instead of committing to a bogus
 * length and swallowing the frames behind it. */
int pedal_link_payload_len(uint8_t type);

/* Incremental parser: feed bytes as they arrive; when a checksum-valid frame
 * completes, pedal_link_parser_push() returns 1 and the type/payload/len
 * outputs describe it (payload points into the parser and is valid until the
 * next push). A frame is dropped, and the parser resyncs on the next sync
 * byte, when its type is unknown, its length is not that type's length, or its
 * checksum fails; a sync byte found in the type or length slot starts the next
 * frame instead of being eaten. `dropped` counts the drops. Enum-range validation is the
 * caller's, via pedal_link_decode_state() for STATE. */
typedef struct pedal_link_parser {
  uint8_t state;
  uint8_t type;
  uint8_t len;
  uint8_t pos;
  uint32_t dropped;
  uint8_t payload[PEDAL_LINK_MAX_PAYLOAD];
} pedal_link_parser;

void pedal_link_parser_init(pedal_link_parser *p);
int pedal_link_parser_push(pedal_link_parser *p, uint8_t byte, uint8_t *type,
                           const uint8_t **payload, uint8_t *len);

#ifdef __cplusplus
}
#endif

#endif /* PEDAL_LINK_H */
