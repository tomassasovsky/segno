#include "pedal_link.h"

#include <string.h>

static uint8_t checksum(uint8_t type, const uint8_t *payload, uint8_t len) {
  uint8_t x = (uint8_t)(type ^ len);
  for (uint8_t i = 0; i < len; i++) x ^= payload[i];
  return x;
}

size_t pedal_link_encode(uint8_t type, const uint8_t *payload, uint8_t len, uint8_t *out) {
  if (len > PEDAL_LINK_MAX_PAYLOAD) return 0;
  out[0] = PEDAL_LINK_SYNC;
  out[1] = type;
  out[2] = len;
  if (len) memcpy(&out[3], payload, len);
  out[3 + len] = checksum(type, payload, len);
  return (size_t)len + 4u;
}

size_t pedal_link_encode_button(uint8_t button, uint8_t pressed, uint8_t *out) {
  const uint8_t p[2] = {button, pressed ? 1u : 0u};
  return pedal_link_encode(PEDAL_LINK_TYPE_BUTTON, p, 2, out);
}

size_t pedal_link_encode_encoder(int8_t delta, uint8_t *out) {
  const uint8_t p[1] = {(uint8_t)delta};
  return pedal_link_encode(PEDAL_LINK_TYPE_ENCODER, p, 1, out);
}

size_t pedal_link_encode_hello(uint8_t fw_major, uint8_t fw_minor, uint8_t *out) {
  const uint8_t p[3] = {PEDAL_LINK_PROTOCOL_VERSION, fw_major, fw_minor};
  return pedal_link_encode(PEDAL_LINK_TYPE_HELLO, p, 3, out);
}

size_t pedal_link_encode_ctrl(uint8_t jack, uint8_t contact, uint8_t kind, uint8_t value,
                              uint8_t *out) {
  uint8_t payload[4];
  payload[0] = jack;
  payload[1] = contact;
  payload[2] = kind;
  payload[3] = value;
  return pedal_link_encode(PEDAL_LINK_TYPE_CTRL, payload, 4, out);
}

size_t pedal_link_encode_state(const pedal_state *s, uint8_t *out) {
  uint8_t p[PEDAL_LINK_STATE_LEN];
  p[0] = (uint8_t)((s->clear_fade ? 0x01u : 0u) | (s->goodbye ? 0x02u : 0u) |
                   (s->performance_armed ? 0x04u : 0u) | (s->counting_in ? 0x08u : 0u));
  p[1] = s->mode;
  p[2] = s->looper_mode;
  p[3] = s->global_color;
  p[4] = s->active_bank;
  p[5] = s->selected_track;
  for (uint8_t i = 0; i < PEDAL_TRACK_COUNT; i++) p[6 + i] = s->track_leds[i];
  p[14] = (uint8_t)(s->loop_length_micros & 0xFFu);
  p[15] = (uint8_t)((s->loop_length_micros >> 8) & 0xFFu);
  p[16] = (uint8_t)((s->loop_length_micros >> 16) & 0xFFu);
  p[17] = (uint8_t)((s->loop_length_micros >> 24) & 0xFFu);
  p[18] = s->master_gain;
  return pedal_link_encode(PEDAL_LINK_TYPE_STATE, p, PEDAL_LINK_STATE_LEN, out);
}

int pedal_link_decode_state(const uint8_t *p, uint8_t len, pedal_state *out) {
  if (len != PEDAL_LINK_STATE_LEN) return 0;
  if (p[0] & ~0x0Fu) return 0;
  if (p[1] >= PEDAL_MODE_COUNT) return 0;
  if (p[2] >= PEDAL_LOOPER_COUNT) return 0;
  if (p[3] >= PEDAL_GLOBAL_COUNT) return 0;
  if (p[4] > 1) return 0;
  if (p[5] >= PEDAL_TRACK_COUNT) return 0;
  for (uint8_t i = 0; i < PEDAL_TRACK_COUNT; i++) {
    if (p[6 + i] >= PEDAL_LED_COUNT) return 0;
  }
  out->clear_fade = (p[0] & 0x01u) ? 1 : 0;
  out->goodbye = (p[0] & 0x02u) ? 1 : 0;
  out->performance_armed = (p[0] & 0x04u) ? 1 : 0;
  out->counting_in = (p[0] & 0x08u) ? 1 : 0;
  out->mode = p[1];
  out->looper_mode = p[2];
  out->global_color = p[3];
  out->active_bank = p[4];
  out->selected_track = p[5];
  for (uint8_t i = 0; i < PEDAL_TRACK_COUNT; i++) out->track_leds[i] = p[6 + i];
  out->loop_length_micros = (uint32_t)p[14] | ((uint32_t)p[15] << 8) |
                            ((uint32_t)p[16] << 16) | ((uint32_t)p[17] << 24);
  out->master_gain = p[18];
  return 1;
}

int pedal_link_payload_len(uint8_t type) {
  switch (type) {
    case PEDAL_LINK_TYPE_BUTTON: return 2;
    case PEDAL_LINK_TYPE_ENCODER: return 1;
    case PEDAL_LINK_TYPE_HELLO: return 3;
    case PEDAL_LINK_TYPE_CTRL: return 4;
    case PEDAL_LINK_TYPE_STATE: return (int)PEDAL_LINK_STATE_LEN;
    default: return -1;
  }
}

enum { PS_SYNC = 0, PS_TYPE, PS_LEN, PS_PAYLOAD, PS_CHECKSUM };

void pedal_link_parser_init(pedal_link_parser *p) {
  memset(p, 0, sizeof(*p));
  p->state = PS_SYNC;
}

int pedal_link_parser_push(pedal_link_parser *p, uint8_t byte, uint8_t *type,
                           const uint8_t **payload, uint8_t *len) {
  switch (p->state) {
    case PS_SYNC:
      if (byte == PEDAL_LINK_SYNC) p->state = PS_TYPE;
      return 0;
    case PS_TYPE:
      if (pedal_link_payload_len(byte) < 0) {
        p->dropped++;
        /* A sync byte here is the start of the NEXT frame (a stray sync or a
         * glitch ate this one); consuming it would lose that frame too. */
        p->state = byte == PEDAL_LINK_SYNC ? PS_TYPE : PS_SYNC;
        return 0;
      }
      p->type = byte;
      p->state = PS_LEN;
      return 0;
    case PS_LEN:
      if ((int)byte != pedal_link_payload_len(p->type)) {
        p->dropped++;
        p->state = byte == PEDAL_LINK_SYNC ? PS_TYPE : PS_SYNC;
        return 0;
      }
      p->len = byte;
      p->pos = 0;
      p->state = byte == 0 ? PS_CHECKSUM : PS_PAYLOAD;
      return 0;
    case PS_PAYLOAD:
      p->payload[p->pos++] = byte;
      if (p->pos == p->len) p->state = PS_CHECKSUM;
      return 0;
    case PS_CHECKSUM:
    default:
      p->state = PS_SYNC;
      if (byte != checksum(p->type, p->payload, p->len)) {
        p->dropped++;
        return 0;
      }
      *type = p->type;
      *payload = p->payload;
      *len = p->len;
      return 1;
  }
}
