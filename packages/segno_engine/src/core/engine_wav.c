/* engine_wav.c — see engine_wav.h. */
#include "engine_wav.h"

#include "segno_engine_api.h" /* le_fs_sync_dir */

#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

static void le_wav_put_u32(unsigned char* p, uint32_t v) {
  p[0] = (unsigned char)(v & 0xff);
  p[1] = (unsigned char)((v >> 8) & 0xff);
  p[2] = (unsigned char)((v >> 16) & 0xff);
  p[3] = (unsigned char)((v >> 24) & 0xff);
}

static void le_wav_put_u16(unsigned char* p, uint16_t v) {
  p[0] = (unsigned char)(v & 0xff);
  p[1] = (unsigned char)((v >> 8) & 0xff);
}

int le_wav_open(le_wav_writer* w, const char* path, int32_t sample_rate,
                int32_t channels, const char* chunk_id, const void* chunk,
                uint32_t chunk_bytes) {
  memset(w, 0, sizeof(*w));
  if (path == NULL || sample_rate <= 0 || channels <= 0) return 0;
  if (chunk_id != NULL && chunk_bytes > 0 && chunk == NULL) return 0;
  /* RIFF word alignment: an odd chunk would need a pad byte (review L4). */
  if (chunk_id != NULL && (chunk_bytes & 1u)) return 0;
  /* Close-on-exec, so a child the app spawns while a file is open never
   * inherits a writable descriptor onto it (the inheritance window #722
   * describes for perf_drain.c's streams). */
#if defined(_WIN32)
  const int fd = _open(path, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY |
                                 _O_NOINHERIT,
                       _S_IREAD | _S_IWRITE);
  if (fd < 0) return 0;
  w->file = _fdopen(fd, "wb");
  if (w->file == NULL) _close(fd);
#else
  const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
  if (fd < 0) return 0;
  w->file = fdopen(fd, "wb");
  if (w->file == NULL) close(fd);
#endif
  if (w->file == NULL) return 0;
  w->channels = channels;
  unsigned char fmt[36];
  memcpy(fmt + 0, "RIFF", 4);
  le_wav_put_u32(fmt + 4, 0);
  memcpy(fmt + 8, "WAVE", 4);
  memcpy(fmt + 12, "fmt ", 4);
  le_wav_put_u32(fmt + 16, 16);
  le_wav_put_u16(fmt + 20, 3); /* WAVE_FORMAT_IEEE_FLOAT */
  le_wav_put_u16(fmt + 22, (uint16_t)channels);
  le_wav_put_u32(fmt + 24, (uint32_t)sample_rate);
  le_wav_put_u32(fmt + 28, (uint32_t)sample_rate * (uint32_t)channels * 4u);
  le_wav_put_u16(fmt + 32, (uint16_t)(channels * 4));
  le_wav_put_u16(fmt + 34, 32);
  int ok = fwrite(fmt, 1, sizeof(fmt), w->file) == sizeof(fmt);
  w->header_bytes = sizeof(fmt);
  if (ok && chunk_id != NULL) {
    unsigned char head[8];
    memcpy(head, chunk_id, 4);
    le_wav_put_u32(head + 4, chunk_bytes);
    ok = fwrite(head, 1, 8, w->file) == 8 &&
         (chunk_bytes == 0 ||
          fwrite(chunk, 1, chunk_bytes, w->file) == chunk_bytes);
    w->header_bytes += 8 + chunk_bytes;
  }
  unsigned char data[8];
  memcpy(data, "data", 4);
  le_wav_put_u32(data + 4, 0);
  ok = ok && fwrite(data, 1, 8, w->file) == 8;
  w->header_bytes += 8;
  if (!ok) w->failed = 1;
  return ok;
}

int le_wav_append(le_wav_writer* w, const float* samples, uint64_t frames) {
  if (w->file == NULL || w->failed) return 0;
  if (frames == 0) return 1;
  const size_t n = (size_t)frames * (size_t)w->channels;
  if (fwrite(samples, sizeof(float), n, w->file) != n) {
    w->failed = 1;
    return 0;
  }
  w->frames += frames;
  return 1;
}

void le_wav_note_frames(le_wav_writer* w, uint64_t frames) {
  w->frames += frames;
}

int le_wav_flush(le_wav_writer* w) {
  if (w->file == NULL || w->failed) return 0;
  if (fflush(w->file) != 0) {
    w->failed = 1;
    return 0;
  }
  return 1;
}

int le_wav_seal(le_wav_writer* w, int sync) {
  if (w->file == NULL) return 0;
  const uint64_t data_bytes = w->frames * (uint64_t)w->channels * 4u;
  int ok = !w->failed && data_bytes + w->header_bytes - 8 <= UINT32_MAX;
  if (ok) {
    unsigned char size[4];
    le_wav_put_u32(size, (uint32_t)(data_bytes + w->header_bytes - 8));
    ok = fseek(w->file, 4, SEEK_SET) == 0 &&
         fwrite(size, 1, 4, w->file) == 4;
    le_wav_put_u32(size, (uint32_t)data_bytes);
    ok = ok && fseek(w->file, (long)(w->header_bytes - 4), SEEK_SET) == 0 &&
         fwrite(size, 1, 4, w->file) == 4;
  }
  ok = ok && fflush(w->file) == 0;
  if (ok && sync) {
#if defined(_WIN32)
    ok = _commit(_fileno(w->file)) == 0;
#else
    ok = fsync(fileno(w->file)) == 0;
#endif
  }
  if (fclose(w->file) != 0) ok = 0;
  w->file = NULL;
  return ok;
}

void le_wav_abandon(le_wav_writer* w) {
  if (w->file != NULL) fclose(w->file);
  w->file = NULL;
}

int le_wav_publish(const char* part_path, const char* final_path) {
#if defined(_WIN32)
  if (MoveFileExA(part_path, final_path, MOVEFILE_REPLACE_EXISTING) == 0) {
    return 0;
  }
#else
  if (rename(part_path, final_path) != 0) return 0;
#endif
  /* The rename is durable once the directory entry is (#1198 Part 1). A
   * failed directory sync leaves the file published in place; it is
   * reported as published (2), not as a failed write (review L3). */
  const size_t n = strlen(final_path);
  char* dir = (char*)malloc(n + 2);
  if (dir == NULL) return 2; /* renamed: published, directory not synced */
  memcpy(dir, final_path, n + 1);
  char* slash = strrchr(dir, '/');
#if defined(_WIN32)
  char* back = strrchr(dir, '\\');
  if (back != NULL && (slash == NULL || back > slash)) slash = back;
#endif
  if (slash == NULL) {
    dir[0] = '.';
    dir[1] = '\0';
  } else if (slash == dir) {
    dir[1] = '\0';
  } else {
    *slash = '\0';
  }
  const int synced = le_fs_sync_dir(dir) == LE_OK;
  free(dir);
  return synced ? 1 : 2;
}

static uint32_t le_wav_get_u32(const unsigned char* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static uint16_t le_wav_get_u16(const unsigned char* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

#if defined(_WIN32)
#define LE_WAV_SEEK _fseeki64
#define LE_WAV_TELL _ftelli64
#else
#define LE_WAV_SEEK fseeko
#define LE_WAV_TELL ftello
#endif

/* Reads `n` bytes at `at`. */
static int le_wav_read_at(FILE* f, int64_t at, unsigned char* out, size_t n) {
  return LE_WAV_SEEK(f, at, SEEK_SET) == 0 && fread(out, 1, n, f) == n;
}

static int le_wav_write_u32_at(FILE* f, int64_t at, uint32_t v) {
  unsigned char b[4];
  le_wav_put_u32(b, v);
  return LE_WAV_SEEK(f, at, SEEK_SET) == 0 && fwrite(b, 1, 4, f) == 4;
}

/* Finds the `fmt ` block align and the first data byte. Chunks before
 * `data` are walked by their sizes (a caller chunk such as `sgno` sits
 * between); `data` itself may still carry the zero size of an unsealed
 * file, so the walk stops at its header. */
static int le_wav_locate(FILE* f, int64_t file_bytes, uint32_t* block,
                         int64_t* data_at) {
  unsigned char h[16];
  if (!le_wav_read_at(f, 0, h, 12)) return 0;
  if (memcmp(h, "RIFF", 4) != 0 || memcmp(h + 8, "WAVE", 4) != 0) return 0;
  int64_t at = 12;
  *block = 0;
  for (int guard = 0; guard < 64 && at + 8 <= file_bytes; ++guard) {
    if (!le_wav_read_at(f, at, h, 8)) return 0;
    const uint32_t size = le_wav_get_u32(h + 4);
    at += 8;
    if (memcmp(h, "data", 4) == 0) {
      *data_at = at;
      return *block > 0;
    }
    if (memcmp(h, "fmt ", 4) == 0) {
      if (size < 16 || !le_wav_read_at(f, at, h, 16)) return 0;
      const uint16_t channels = le_wav_get_u16(h + 2);
      if (le_wav_get_u16(h) != 3 || le_wav_get_u16(h + 14) != 32 ||
          channels == 0 || le_wav_get_u16(h + 12) != channels * 4u) {
        return 0;
      }
      *block = le_wav_get_u16(h + 12);
    }
    at += (int64_t)size + (size & 1u);
  }
  return 0;
}

int le_wav_patch_sizes(const char* path, uint64_t max_frames, uint64_t* kept) {
  if (kept != NULL) *kept = 0;
  if (path == NULL) return 0;
#if defined(_WIN32)
  const int fd = _open(path, _O_RDWR | _O_BINARY | _O_NOINHERIT);
  if (fd < 0) return 0;
  FILE* f = _fdopen(fd, "r+b");
  if (f == NULL) _close(fd);
#else
  const int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0) return 0;
  FILE* f = fdopen(fd, "r+b");
  if (f == NULL) close(fd);
#endif
  if (f == NULL) return 0;
  int ok = LE_WAV_SEEK(f, 0, SEEK_END) == 0;
  const int64_t file_bytes = ok ? (int64_t)LE_WAV_TELL(f) : -1;
  uint32_t block = 0;
  int64_t data_at = 0;
  ok = ok && file_bytes >= 0 && le_wav_locate(f, file_bytes, &block, &data_at);
  uint64_t frames = 0;
  if (ok) {
    frames = (uint64_t)(file_bytes - data_at) / block;
    if (frames > max_frames) frames = max_frames;
    const uint64_t data_bytes = frames * block;
    ok = (uint64_t)data_at + data_bytes - 8 <= UINT32_MAX;
    ok = ok && fflush(f) == 0;
#if defined(_WIN32)
    ok = ok && _chsize_s(_fileno(f), data_at + (int64_t)data_bytes) == 0;
#else
    ok = ok && ftruncate(fileno(f), (off_t)(data_at + (int64_t)data_bytes)) == 0;
#endif
    ok = ok &&
         le_wav_write_u32_at(f, 4, (uint32_t)(data_at + data_bytes - 8)) &&
         le_wav_write_u32_at(f, data_at - 4, (uint32_t)data_bytes) &&
         fflush(f) == 0;
#if defined(_WIN32)
    ok = ok && _commit(_fileno(f)) == 0;
#else
    ok = ok && fsync(fileno(f)) == 0;
#endif
  }
  if (fclose(f) != 0) ok = 0;
  if (ok && kept != NULL) *kept = frames;
  return ok;
}

int le_wav_write_file(const char* path, const float* samples, uint64_t frames,
                      int32_t sample_rate, int32_t channels) {
  le_wav_writer w;
  if (!le_wav_open(&w, path, sample_rate, channels, NULL, NULL, 0)) {
    le_wav_abandon(&w);
    return 0;
  }
  le_wav_append(&w, samples, frames);
  return le_wav_seal(&w, 0);
}
