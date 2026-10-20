/*
 * ring_flash.c - see ring_flash.h.
 *
 * Every step waits for the ring's reply before the next one (stop and wait):
 * the XIAO runs from the same flash it writes, so it hears nothing while a
 * sector erases, and nothing must be in flight then.
 */
#include "ring_flash.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "pedal_link.h"
#include "ring_update.h"

typedef struct {
  const ring_flash_io *io;
  ring_frame_parser parser;
  uint8_t body[RING_UPDATE_PARSER_CAPACITY];
  uint8_t type;
  uint8_t payload[RING_UPDATE_ACK_LEN > RING_UPDATE_HELLO_LEN ? RING_UPDATE_ACK_LEN : RING_UPDATE_HELLO_LEN];
  size_t n;
} session;

typedef struct {
  uint8_t major, minor, protocol, flags, partition;
} hello;

static void say(session *s, const char *format, ...) __attribute__((format(printf, 2, 3)));
static void say(session *s, const char *format, ...) {
  char line[160];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  s->io->log(s->io->ctx, line);
}

static void send(session *s, uint8_t type, const uint8_t *payload, size_t n) {
  uint8_t out[RING_UPDATE_MAX_FRAME];
  s->io->write(s->io->ctx, out, ring_update_encode(type, payload, n, out));
}

static void send_bridge(session *s) {
  uint8_t out[PEDAL_LINK_MAX_FRAME];
  s->io->write(s->io->ctx, out, pedal_link_encode_ring_bridge(out));
}

/* Waits for the next update message of `want` until the deadline. Ring-link
 * frames (the XIAO's encoder snapshots) and the console's own pedal-link bytes
 * share the line; the frame parser drops them. */
static int receive(session *s, uint8_t want, unsigned deadline) {
  for (;;) {
    const unsigned now = s->io->now_ms(s->io->ctx);
    if ((int)(deadline - now) <= 0) return 0;
    const int byte = s->io->read(s->io->ctx, deadline - now);
    if (byte < 0) return 0;
    size_t length = 0;
    if (!ring_frame_parser_push(&s->parser, (uint8_t)byte, &length)) continue;
    uint8_t type;
    const uint8_t *payload;
    size_t n;
    if (!ring_update_message(s->body, length, &type, &payload, &n) || type != want) continue;
    if (n > sizeof(s->payload)) continue;
    s->type = type;
    s->n = n;
    memcpy(s->payload, payload, n);
    return 1;
  }
}

/* QUERY every 250 ms until a HELLO arrives. `bridge` resends RING_BRIDGE with
 * each QUERY, for a console that was still starting when the first one went. */
static int query(session *s, unsigned timeout_ms, int bridge, hello *h) {
  const unsigned end = s->io->now_ms(s->io->ctx) + timeout_ms;
  for (;;) {
    const unsigned now = s->io->now_ms(s->io->ctx);
    if ((int)(end - now) <= 0) return 0;
    if (bridge) send_bridge(s);
    send(s, RING_UPDATE_QUERY, NULL, 0);
    const unsigned step = now + 250;
    if (receive(s, RING_UPDATE_HELLO, (int)(end - step) < 0 ? end : step) && s->n == RING_UPDATE_HELLO_LEN) {
      h->major = s->payload[0];
      h->minor = s->payload[1];
      h->protocol = s->payload[2];
      h->flags = s->payload[3];
      h->partition = s->payload[4];
      return 1;
    }
  }
}

/* Sends one request and waits for its ACK; returns the status, or -1. */
static int request(session *s, uint8_t type, const uint8_t *payload, size_t n, unsigned timeout_ms,
                   uint32_t *value) {
  send(s, type, payload, n);
  const unsigned deadline = s->io->now_ms(s->io->ctx) + timeout_ms;
  while (receive(s, RING_UPDATE_ACK, deadline)) {
    if (s->n != RING_UPDATE_ACK_LEN || s->payload[0] != type) continue;  // a stale reply
    if (value) *value = ring_update_get32(s->payload + 2);
    return s->payload[1];
  }
  return -1;
}

static int confirm(session *s) {
  for (unsigned attempt = 0; attempt < RING_FLASH_RETRIES; ++attempt) {
    const int status = request(s, RING_UPDATE_CONFIRM, NULL, 0, RING_FLASH_ACK_MS, NULL);
    if (status == RING_UPDATE_OK) return 1;
    if (status >= 0) {
      say(s, "the ring refused to keep the new firmware (status %d)", status);
      return 0;
    }
  }
  say(s, "no reply to CONFIRM");
  return 0;
}

/* A request the ring can safely receive twice: a lost ACK is answered by
 * sending it again (a repeated BEGIN restarts, a repeated chunk is acknowledged
 * without being written again). */
static int retried(session *s, uint8_t type, const uint8_t *payload, size_t n, uint32_t *value) {
  int status = -1;
  for (unsigned attempt = 0; attempt < RING_FLASH_RETRIES && status < 0; ++attempt)
    status = request(s, type, payload, n, RING_FLASH_ACK_MS, value);
  return status;
}

static int transfer(session *s, const ring_flash_job *job) {
  uint8_t begin[RING_UPDATE_BEGIN_LEN];
  ring_update_put32(begin, (uint32_t)job->size);
  memcpy(begin + 4, job->digest, RING_UPDATE_DIGEST_LEN);
  int status = retried(s, RING_UPDATE_BEGIN, begin, sizeof(begin), NULL);
  if (status != RING_UPDATE_OK) {
    say(s, "the ring refused the update (status %d)", status);
    return 0;
  }
  uint8_t chunk[4 + RING_UPDATE_CHUNK];
  for (size_t offset = 0; offset < job->size;) {
    const size_t n = job->size - offset < RING_UPDATE_CHUNK ? job->size - offset : RING_UPDATE_CHUNK;
    ring_update_put32(chunk, (uint32_t)offset);
    memcpy(chunk + 4, job->image + offset, n);
    uint32_t next = 0;
    status = retried(s, RING_UPDATE_DATA, chunk, 4 + n, &next);
    if (status != RING_UPDATE_OK || next != offset + n) {
      say(s, "chunk at %d failed (status %d, ring expects %d)", (int)offset, status, (int)next);
      return 0;
    }
    offset += n;
  }
  // Not retried: once accepted, the ring is already rebooting. A lost reply is
  // settled by what the ring says after the reboot.
  status = request(s, RING_UPDATE_COMMIT, NULL, 0, RING_FLASH_COMMIT_MS, NULL);
  if (status > 0) {
    say(s, "the ring did not accept the image (status %d)", status);
    return 0;
  }
  return 1;
}

static ring_flash_outcome finish(session *s, ring_flash_outcome outcome) {
  send(s, RING_UPDATE_BRIDGE_END, NULL, 0);
  return outcome;
}

ring_flash_outcome ring_flash_run(const ring_flash_io *io, const ring_flash_job *job) {
  session s;
  memset(&s, 0, sizeof(s));
  s.io = io;
  ring_frame_parser_init(&s.parser, s.body, sizeof(s.body));

  hello h;
  if (!query(&s, RING_FLASH_QUERY_MS, 1, &h)) {
    say(&s, "no answer through the console: its firmware predates the bridge, the ring's "
            "predates the updater, or no ring is connected");
    return finish(&s, RING_FLASH_SILENT);
  }
  if (h.flags & RING_UPDATE_FLAG_NO_TABLE) {
    say(&s, "the ring runs %d.%d without a partition table; install it once over USB", h.major, h.minor);
    return finish(&s, RING_FLASH_NO_TABLE);
  }
  // Any other version is sent, older ones included: an appliance rolled back
  // to an older image brings the ring back with it. The bootrom keeps such a
  // downgrade: when a flash-update boot tries a lower version than the other
  // partition holds, the buy erases that partition's first sector
  // (pico-bootrom-rp2350 varm_flash_boot.c, explicit_buy in
  // varm_launch_image.c), so the next normal boot cannot pick the higher one.
  const int wanted = h.major == job->major && h.minor == job->minor;
  if (wanted && (h.flags & RING_UPDATE_FLAG_TRIAL)) {
    say(&s, "the ring runs %d.%d on trial; confirming it", h.major, h.minor);
    return finish(&s, confirm(&s) ? RING_FLASH_CONFIRMED : RING_FLASH_FAILED);
  }
  if (wanted) {
    say(&s, "the ring runs firmware %d.%d; nothing to do", h.major, h.minor);
    return finish(&s, RING_FLASH_CURRENT);
  }
  if (h.flags & RING_UPDATE_FLAG_TRIAL) {
    // Not ours to keep: the bootrom returns to the previous image shortly.
    say(&s, "the ring runs %d.%d on trial, not %d.%d; leaving it to revert", h.major, h.minor, job->major,
        job->minor);
    return finish(&s, RING_FLASH_FAILED);
  }
  if (!job->may_update) {
    say(&s, "the ring runs %d.%d, not %d.%d, but earlier attempts failed; not retrying", h.major, h.minor,
        job->major, job->minor);
    return finish(&s, RING_FLASH_HELD);
  }

  say(&s, "the ring runs %d.%d; sending %d.%d", h.major, h.minor, job->major, job->minor);
  if (io->attempt) io->attempt(io->ctx);
  if (!transfer(&s, job)) return finish(&s, RING_FLASH_FAILED);

  // The ring reboots into the new image on trial and says HELLO from it.
  hello after;
  if (!query(&s, RING_FLASH_REBOOT_MS, 0, &after)) {
    say(&s, "no answer after the reboot");
    return finish(&s, RING_FLASH_FAILED);
  }
  if (after.major != job->major || after.minor != job->minor || !(after.flags & RING_UPDATE_FLAG_TRIAL)) {
    say(&s, "the ring came back on %d.%d, not %d.%d on trial", after.major, after.minor, job->major,
        job->minor);
    return finish(&s, RING_FLASH_FAILED);
  }
  if (!confirm(&s)) return finish(&s, RING_FLASH_FAILED);
  if (!query(&s, RING_FLASH_QUERY_MS, 0, &after) || (after.flags & RING_UPDATE_FLAG_TRIAL)) {
    say(&s, "the ring did not report the confirmed firmware");
    return finish(&s, RING_FLASH_FAILED);
  }
  say(&s, "the ring now runs %d.%d", after.major, after.minor);
  return finish(&s, RING_FLASH_UPDATED);
}
