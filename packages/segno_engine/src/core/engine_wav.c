/* engine_wav.c — see engine_wav.h. */
#include "engine_wav.h"

#include "segno_engine_api.h" /* le_fs_sync_dir */

#include <stdlib.h>
#include <string.h>

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
  /* Cut anything past the declared data: a short write leaves a torn
   * partial frame there, which the writer's caller rewound over but could
   * not remove. A sealed file is exactly its header and its data. */
  if (ok) {
    const uint64_t end = w->header_bytes + data_bytes;
#if defined(_WIN32)
    ok = _chsize_s(_fileno(w->file), (long long)end) == 0;
#else
    ok = ftruncate(fileno(w->file), (off_t)end) == 0;
#endif
  }
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
  /* The rename is durable once the directory entry is (#1198 Part 1). */
  const size_t n = strlen(final_path);
  char* dir = (char*)malloc(n + 2);
  if (dir == NULL) return 0;
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
  const int ok = le_fs_sync_dir(dir) == LE_OK;
  free(dir);
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
