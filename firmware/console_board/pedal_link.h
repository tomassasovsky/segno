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
/* 12: PD_STATUS (0x06) -- the USB-C PD contract and whether the trigger's
 * NVM holds the console profile (#1352).
 * 11: STATE flags bit 4 is dimmed -- the console idled and the app dimmed the
 * screens, so the board dims its LEDs too (#1349).
 * 10: STATE53 -- the Song queue (#1077): which footswitch's pill fills, and
 * how far, while a section waits for the playing one's next lap edge.
 * 9: ENCODER_BUTTON (0x05) -- the encoder's push switch, press and release.
 * 8: ten RGB hues and a ten-bit physical activity mask (STATE51).
 * 7 is the separate Song/hardware branch (STATE21), not this format.
 * 6: mode value 3 is CUSTOM, with the same STATE shape. 5: CTRL kind NONE --
 * the board can now say a jack is EMPTY (a plug pulled
 * out, or the tip-normal contact on a switched jack), instead of reporting an
 * unplugged jack as a pedal at full toe. 4: CTRL (0x04) grew a contact byte
 * and reports an expression pedal's RAW position; calibration moved to segno.
 * 3: the CTRL jacks. 2: the loop-top pulse (0x11) was retired when the ring
 * stopped tracking the loop. The board is flashed over SWD independently of
 * the app, so the two can drift; this is what makes that visible instead of
 * silent. */
#define PEDAL_LINK_PROTOCOL_VERSION 12u

/* board -> segno */
#define PEDAL_LINK_TYPE_BUTTON 0x01u   /* [button, pressed] */
#define PEDAL_LINK_TYPE_ENCODER 0x02u  /* [int8 delta] */
/* HELLO is frozen for every protocol version: type 0x03, three bytes, the
 * protocol version first. It is how a board built against another revision is
 * recognised as incompatible at all; a revision that needs more from the board
 * adds a message type, never a hello byte. */
#define PEDAL_LINK_TYPE_HELLO 0x03u    /* [protocol, fw major, fw minor] */
#define PEDAL_LINK_TYPE_CTRL 0x04u     /* [jack, contact, kind, value] */
#define PEDAL_LINK_TYPE_ENCODER_BUTTON 0x05u /* [pressed] */
/* Once a second, after HELLO: [profile, mismatch, mV LE16, mA LE16,
 * source max mA LE16]. profile is a PEDAL_PD_PROFILE_* value; the contract
 * fields are zero when the trigger did not answer or holds no PD contract. */
#define PEDAL_LINK_TYPE_PD_STATUS 0x06u
/* segno -> board */
#define PEDAL_LINK_TYPE_STATE 0x10u    /* [PEDAL_LINK_STATE_LEN bytes] */
/* Pi -> board, from segno-ring-flash before the app starts, never from the
 * app (PedalLinkCodec does not encode it): bridge this UART to the ring
 * carrier's, so the Pi can update the ring XIAO (#1342, SegnoRing's
 * ring_update.h). The payload is a fixed magic, so line noise that passes
 * the checksum cannot enter the bridge. */
#define PEDAL_LINK_TYPE_RING_BRIDGE 0x12u /* ['R', 'B'] */
#define PEDAL_LINK_RING_BRIDGE_MAGIC0 0x52u
#define PEDAL_LINK_RING_BRIDGE_MAGIC1 0x42u

#define PEDAL_LINK_PD_STATUS_LEN 8u
#define PEDAL_LINK_STATE_LEN 53u
#define PEDAL_LINK_MAX_PAYLOAD PEDAL_LINK_STATE_LEN
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

/* The two CTRL jacks, in wire order. Each takes an expression pedal OR a
 * footswitch; the board tells them apart by what the tip does (a switch sits
 * at the rails, a pot moves through the middle) and says which in `kind`.
 *
 * A jack has two readable contacts. The TIP is the pot's wiper or a switch.
 * The RING is the pot's supply (3V3 through 1k) — and, on a two-switch pedal
 * like a BOSS FS-6 on its A&B jack, the SECOND switch, which shorts the ring
 * to sleeve. Console board v2 senses the ring on a spare GPIO (a wire from
 * each jack's ring pin to the J22 pads; see console_board.ino), so that
 * switch reports as contact RING, always kind SWITCH. */
enum { PEDAL_CTRL1 = 0, PEDAL_CTRL2, PEDAL_CTRL_COUNT };
enum { PEDAL_CTRL_TIP = 0, PEDAL_CTRL_RING, PEDAL_CTRL_CONTACT_COUNT };
enum {
  PEDAL_CTRL_KIND_SWITCH = 0, /* value is 0 or 255 */
  /* value is the RAW position, 0..255 (the 12-bit reading's top byte), NOT a
   * calibrated travel: a pedal never uses the whole scale (the tip's pull-up
   * and the ring's 1k compress both ends, and every pedal's travel differs),
   * and where the ends really are is segno's to learn and keep — the board
   * forgets everything at power-off. */
  PEDAL_CTRL_KIND_EXPRESSION,
  /* Nothing on the jack. Sent once when a plug leaves (tip contact only,
   * value 0) and covers the WHOLE jack: the ring's switch goes with the
   * tip's, released first if it was down. Whatever was bound to the jack
   * holds where it was, and the jack is classified afresh on the next plug.
   * An EXPRESSION tip likewise means no ring switch: a pot's ring is its
   * supply, and a ring closure the plug's tip brushed in is released. */
  PEDAL_CTRL_KIND_NONE,
  PEDAL_CTRL_KIND_COUNT
};

/* Enum wire values, mirroring the Dart enums' declaration order. */
enum {
  PEDAL_MODE_REC = 0,
  PEDAL_MODE_PLAY,
  PEDAL_MODE_FX,
  PEDAL_MODE_CUSTOM,
  PEDAL_MODE_COUNT
};
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

/* Whether the PD trigger's NVM holds the console profile, as the board found
 * it at boot (pd_trigger.h). WRITTEN means it did not and the board wrote it
 * and read it back; the new profile governs the next negotiation, after a
 * power cycle. */
enum {
  PEDAL_PD_PROFILE_NOT_READ = 0, /* the trigger did not answer on J23 */
  PEDAL_PD_PROFILE_MATCHES,
  PEDAL_PD_PROFILE_WRITTEN,
  PEDAL_PD_PROFILE_WRITE_FAILED,
  PEDAL_PD_PROFILE_COUNT
};

/* The decoded STATE payload. Byte layout (see PedalLinkCodec):
 *   0      flags: bit0 clear_fade, bit1 goodbye, bit2 performance_armed,
 *          bit3 counting_in, bit4 dimmed (bits 5-7 reserved, must be zero)
 *   1      mode          2 looper_mode   3 global_color
 *   4      active_bank   5 selected_track
 *   6..13  track_leds[0..7]
 *   14..17 loop_length_micros, uint32 little-endian
 *   18     master_gain, 0..255
 *   19..48 ten RGB triples in PEDAL_BTN order
 *   49..50 active_button_mask LE16; bits10..15 reserved zero
 *   51     queued_button: 0 none, else the PEDAL_BTN value + 1
 *   52     queued_progress: 0..254 of 255, 0 without a queued button
 * The app picks the button (only a visible queued Song section has one) and
 * lights it like any other; the board only fills that pill left to right by
 * the progress. A full pill is never drawn from a queue: the engine ends the
 * wait by starting the section, and the next frame carries no queue.
 */
typedef struct pedal_color { uint8_t r, g, b; } pedal_color;

typedef struct pedal_state {
  uint8_t clear_fade;
  uint8_t goodbye;
  uint8_t performance_armed;
  uint8_t counting_in;
  uint8_t dimmed;
  uint8_t mode;
  uint8_t looper_mode;
  uint8_t global_color;
  uint8_t active_bank;
  uint8_t selected_track;
  uint8_t track_leds[PEDAL_TRACK_COUNT];
  uint32_t loop_length_micros;
  uint8_t master_gain;
  pedal_color pedal_colors[PEDAL_BTN_COUNT];
  uint16_t active_button_mask;
  uint8_t queued_button;
  uint8_t queued_progress;
} pedal_state;

/* Frame a payload. `out` must hold PEDAL_LINK_MAX_FRAME bytes. Returns the
 * frame length, or 0 if the payload is too long. */
size_t pedal_link_encode(uint8_t type, const uint8_t *payload, uint8_t len, uint8_t *out);

size_t pedal_link_encode_button(uint8_t button, uint8_t pressed, uint8_t *out);
size_t pedal_link_encode_encoder(int8_t delta, uint8_t *out);
size_t pedal_link_encode_encoder_button(uint8_t pressed, uint8_t *out);
size_t pedal_link_encode_hello(uint8_t fw_major, uint8_t fw_minor, uint8_t *out);
size_t pedal_link_encode_ctrl(uint8_t jack, uint8_t contact, uint8_t kind, uint8_t value,
                              uint8_t *out);
size_t pedal_link_encode_state(const pedal_state *state, uint8_t *out);
size_t pedal_link_encode_ring_bridge(uint8_t *out);
size_t pedal_link_encode_pd_status(uint8_t profile, uint8_t mismatch, uint16_t millivolts,
                                   uint16_t milliamps, uint16_t max_milliamps, uint8_t *out);

/* Decode a STATE payload. Returns 1 on success, 0 for a wrong length, an
 * out-of-range enum, a reserved flag bit, an active_bank > 1, a
 * selected_track >= PEDAL_TRACK_COUNT, a queued_button > PEDAL_BTN_COUNT, a
 * queued_progress of 255 or a progress without a button - the same
 * rejections as the Dart side. */
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
