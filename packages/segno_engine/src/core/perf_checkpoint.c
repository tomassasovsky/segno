/* perf_checkpoint.c — see perf_checkpoint.h. */
#include "perf_checkpoint.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "engine_internal.h" /* le_perf_checkpoint_fail_slot_writes_for_test */

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#endif

/* Big enough for every part a take can list (LE_PD_MAX_PARTS, about 200
 * bytes each) and a few thousand layer names. */
#define LE_PCP_BUF_BYTES (1024 * 1024)

/* Test seam: the next `count` slot writes fail as a refused write would. */
static _Atomic int g_pcp_failing_slot_writes = 0;

void le_perf_checkpoint_fail_slot_writes_for_test(int count) {
  atomic_store_explicit(&g_pcp_failing_slot_writes, count < 0 ? 0 : count,
                        memory_order_relaxed);
}

void le_perf_part_filename(int32_t stream, int32_t index, char* out,
                           size_t cap) {
  if (stream == 0) {
    snprintf(out, cap, "master-%03d.wav", index);
  } else {
    snprintf(out, cap, "input-%d-%03d.wav", stream - 1, index);
  }
}

void le_pcp_read_boot_id(char* out, size_t cap) {
  if (cap == 0) return;
  out[0] = '\0';
#if defined(__linux__)
  FILE* f = fopen("/proc/sys/kernel/random/boot_id", "r");
  if (f == NULL) return;
  if (fgets(out, (int)cap, f) == NULL) out[0] = '\0';
  fclose(f);
  out[strcspn(out, "\r\n")] = '\0';
#elif defined(__APPLE__)
  size_t len = cap;
  if (sysctlbyname("kern.bootsessionuuid", out, &len, NULL, 0) != 0) {
    out[0] = '\0';
  }
  out[cap - 1] = '\0';
#endif
  /* Only hex digits and dashes reach the JSON. */
  for (char* c = out; *c != '\0'; ++c) {
    const int ok = (*c >= '0' && *c <= '9') || (*c >= 'a' && *c <= 'f') ||
                   (*c >= 'A' && *c <= 'F') || *c == '-';
    if (!ok) {
      *c = '\0';
      break;
    }
  }
}

int le_pcp_writer_init(le_pcp_writer* w) {
  memset(w, 0, sizeof(*w));
  w->buf = (char*)malloc(LE_PCP_BUF_BYTES);
  w->cap = LE_PCP_BUF_BYTES;
  return w->buf != NULL;
}

void le_pcp_writer_free(le_pcp_writer* w) {
  free(w->buf);
  w->buf = NULL;
}

/* Makes `path`'s bytes durable, whichever descriptor wrote them: Linux syncs
 * the inode, and on FAT and exFAT the sync also writes the file's directory
 * entry and allocation. A file that is not there is not an error here (a
 * part the progress names always exists; this keeps a racing test honest). */
static int le_pcp_sync_file(const char* path) {
#if defined(_WIN32)
  const int fd = _open(path, _O_RDWR | _O_BINARY | _O_NOINHERIT);
  if (fd < 0) return 0;
  const int ok = _commit(fd) == 0;
  _close(fd);
  return ok;
#else
  const int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
#if defined(__linux__)
  const int ok = fdatasync(fd) == 0;
#else
  const int ok = fsync(fd) == 0;
#endif
  close(fd);
  return ok;
#endif
}

static int le_pcp_sync_in(const char* dir, const char* name) {
  char path[LE_PCP_PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) {
    return 0;
  }
  return le_pcp_sync_file(path);
}

/* Appends to the slot buffer; the whole write fails on overflow. */
typedef struct le_pcp_out {
  char* buf;
  size_t cap;
  size_t len;
  int overflow;
} le_pcp_out;

#if defined(__GNUC__)
__attribute__((format(printf, 2, 3)))
#endif
static void le_pcp_put(le_pcp_out* o, const char* fmt, ...) {
  if (o->overflow) return;
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(o->buf + o->len, o->cap - o->len, fmt, ap);
  va_end(ap);
  if (n < 0 || (size_t)n >= o->cap - o->len) {
    o->overflow = 1;
    return;
  }
  o->len += (size_t)n;
}

static void le_pcp_put_hex(le_pcp_out* o, const uint8_t* bytes, size_t n) {
  for (size_t i = 0; i < n; ++i) le_pcp_put(o, "%02x", bytes[i]);
}

/* Builds the slot for `sequence` into o: the body, then the checksum of
 * every byte before the "checksum" key. */
static void le_pcp_build(le_pcp_out* o, const le_pcp_take* t,
                         const le_pcp_progress* p, uint64_t sequence) {
  le_pcp_put(o, "{\n  \"version\": 1,\n  \"sequence\": %llu,\n  \"take_id\": \"",
             (unsigned long long)sequence);
  le_pcp_put_hex(o, t->take_id, 16);
  le_pcp_put(o,
             "\",\n  \"boot_id\": \"%s\",\n  \"volume_generation\": %lld,\n"
             "  \"sample_rate\": %d,\n  \"encoding\": \"f32\",\n"
             "  \"frames\": %llu,\n  \"overs\": %llu,\n  \"streams\": [",
             t->boot_id, (long long)t->volume_generation, t->sample_rate,
             (unsigned long long)p->frames, (unsigned long long)p->overs);
  for (int32_t k = 0; k < p->stream_count; ++k) {
    const le_pcp_stream* s = &p->streams[k];
    const uint64_t frame_bytes = (uint64_t)s->channels * sizeof(float);
    le_pcp_put(o, "%s\n    {\"stream\": %d, \"channels\": %d, \"parts\": [",
               k == 0 ? "" : ",", s->stream, s->channels);
    int first = 1;
    char name[64];
    for (int32_t i = 0; i < p->sealed_count; ++i) {
      const le_perf_sealed_part* sp = &t->sealed[i];
      if (sp->stream != s->stream) continue;
      le_perf_part_filename(sp->stream, sp->index, name, sizeof(name));
      le_pcp_put(o,
                 "%s\n      {\"index\": %d, \"file\": \"%s\", \"frames\": %llu, "
                 "\"bytes\": %llu, \"overs\": %llu, \"sha256\": \"",
                 first ? "" : ",", sp->index, name,
                 (unsigned long long)sp->frames,
                 (unsigned long long)(LE_PERF_PART_HEADER_BYTES +
                                      sp->frames * frame_bytes),
                 (unsigned long long)sp->overs);
      le_pcp_put_hex(o, sp->sha256, LE_SHA256_BYTES);
      le_pcp_put(o, "\"}");
      first = 0;
    }
    if (s->open_index > 0) {
      le_perf_part_filename(s->stream, s->open_index, name, sizeof(name));
      le_pcp_put(o,
                 "%s\n      {\"index\": %d, \"file\": \"%s\", \"frames\": %llu, "
                 "\"bytes\": %llu, \"overs\": %llu}",
                 first ? "" : ",", s->open_index, name,
                 (unsigned long long)s->open_frames,
                 (unsigned long long)(LE_PERF_PART_HEADER_BYTES +
                                      s->open_frames * frame_bytes),
                 (unsigned long long)s->open_overs);
    }
    le_pcp_put(o, "]}");
  }
  le_pcp_put(o, "\n  ],\n  \"events_bytes\": %llu,\n  \"layers\": [",
             (unsigned long long)p->events_bytes);
  for (int32_t i = 0; i < p->layer_count; ++i) {
    le_pcp_put(o, "%s\"%s\"", i == 0 ? "" : ", ",
               t->layer_names + (size_t)i * t->layer_stride);
  }
  const long long written_at_ms = (long long)time(NULL) * 1000LL;
  le_pcp_put(o, "],\n  \"written_at_ms\": %lld,\n  ", written_at_ms);
  if (o->overflow) return;
  uint8_t digest[LE_SHA256_BYTES];
  le_sha256_ctx ctx;
  le_sha256_init(&ctx);
  le_sha256_update(&ctx, o->buf, o->len);
  le_sha256_final(&ctx, digest);
  le_pcp_put(o, "\"checksum\": \"");
  le_pcp_put_hex(o, digest, LE_SHA256_BYTES);
  le_pcp_put(o, "\"\n}\n");
}

/* Rewrites `dir`/checkpoint-<slot>.json in place: truncate, write, fsync. */
static int le_pcp_write_slot(const char* dir, int slot, const char* bytes,
                             size_t len) {
  if (atomic_load_explicit(&g_pcp_failing_slot_writes, memory_order_relaxed) >
      0) {
    atomic_fetch_sub_explicit(&g_pcp_failing_slot_writes, 1,
                              memory_order_relaxed);
    return 0;
  }
  char path[LE_PCP_PATH_MAX];
  if (snprintf(path, sizeof(path), "%s/checkpoint-%c.json", dir,
               slot == 0 ? 'a' : 'b') >= (int)sizeof(path)) {
    return 0;
  }
#if defined(_WIN32)
  const int fd = _open(path, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY |
                                 _O_NOINHERIT,
                       _S_IREAD | _S_IWRITE);
  if (fd < 0) return 0;
  int ok = 1;
  size_t done = 0;
  while (ok && done < len) {
    const unsigned chunk = len - done > (1u << 30) ? (1u << 30)
                                                   : (unsigned)(len - done);
    const int n = _write(fd, bytes + done, chunk);
    if (n <= 0) ok = 0;
    else done += (size_t)n;
  }
  ok = ok && _commit(fd) == 0;
  _close(fd);
  return ok;
#else
  const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return 0;
  int ok = 1;
  size_t done = 0;
  while (ok && done < len) {
    const ssize_t n = write(fd, bytes + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) ok = 0;
    else done += (size_t)n;
  }
  ok = ok && fsync(fd) == 0;
  close(fd);
  return ok;
#endif
}

int le_pcp_write(le_pcp_writer* w, const le_pcp_take* t,
                 const le_pcp_progress* p) {
  int ok = 1;
  char name[64];

  /* 1. Everything the slot will name, durable before the slot says so. A
   * sealed part or a layer file never changes again, so each is synced once;
   * the open parts and events.log grow and are synced every time. */
  while (w->synced_sealed < p->sealed_count) {
    const le_perf_sealed_part* sp = &t->sealed[w->synced_sealed];
    le_perf_part_filename(sp->stream, sp->index, name, sizeof(name));
    if (!le_pcp_sync_in(t->capture_dir, name)) {
      ok = 0;
      break;
    }
    w->synced_sealed++;
  }
  for (int32_t k = 0; k < p->stream_count; ++k) {
    const le_pcp_stream* s = &p->streams[k];
    if (s->open_index <= 0) continue;
    le_perf_part_filename(s->stream, s->open_index, name, sizeof(name));
    if (!le_pcp_sync_in(t->capture_dir, name)) ok = 0;
  }
  if (!le_pcp_sync_in(t->capture_dir, "events.log")) ok = 0;
  while (w->synced_layers < p->layer_count) {
    if (!le_pcp_sync_in(t->capture_dir,
                        t->layer_names +
                            (size_t)w->synced_layers * t->layer_stride)) {
      ok = 0;
      break;
    }
    w->synced_layers++;
  }
  /* New part and layer names, and the slots' own entries. */
  if (le_fs_sync_dir(t->capture_dir) != LE_OK) ok = 0;
  /* A slot that names data not yet on the device would be a lie: skip it,
   * the slot that stands still tells the truth. */
  if (!ok) return 0;

  /* 2. The slot, here and then in the mirror, from the same bytes. */
  le_pcp_out o = {w->buf, w->cap, 0, 0};
  le_pcp_build(&o, t, p, w->sequence + 1);
  if (o.overflow) return 0;
  const int slot = w->next_slot;
  if (!le_pcp_write_slot(t->capture_dir, slot, o.buf, o.len)) return 0;
  if (!w->slot_created[slot]) {
    /* The slot's own directory entry, the first time it is written. */
    if (le_fs_sync_dir(t->capture_dir) != LE_OK) ok = 0;
    w->slot_created[slot] = 1;
  }
  w->sequence++;
  w->next_slot = 1 - slot;
  if (t->mirror_dir != NULL && t->mirror_dir[0] != '\0') {
    if (!le_pcp_write_slot(t->mirror_dir, slot, o.buf, o.len) ||
        le_fs_sync_dir(t->mirror_dir) != LE_OK) {
      ok = 0;
    }
  }
  return ok;
}
