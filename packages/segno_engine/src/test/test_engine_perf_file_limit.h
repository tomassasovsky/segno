/* #1794: every file a performance take renders fits one file on a FAT32
 * stick (4 GiB less one byte, header included) at the longest take the
 * drain lets run, whatever the take's longest length, rate or master width.
 * The headers are read from a real render, so a wider stem, a wider sample
 * or a longer header fails here, as does a longest take that is no longer
 * held to what one file can hold. Included by test_engine_core.c after
 * test_engine_perf_render_memory.h (shares its fixture). */

#include "perf_drain.h" /* le_perf_longest_take_frames */

/* FAT32's largest file, written out here rather than taken from the
 * engine, so the engine's own figure is checked too. */
#define FL_FAT32_MAX_FILE_BYTES 4294967295ull

/* The header bytes before the samples and the bytes per frame of the WAV at
 * `rel` under [dir]: 1 when it reads. */
static int file_limit_layout(const char* dir, const char* rel,
                             uint64_t* header_bytes, uint64_t* frame_bytes,
                             int* channels) {
  char path[760];
  snprintf(path, sizeof(path), "%s/%s", dir, rel);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  unsigned char riff[12];
  int ok = fread(riff, 1, sizeof(riff), f) == sizeof(riff) &&
           memcmp(riff, "RIFF", 4) == 0 && memcmp(riff + 8, "WAVE", 4) == 0;
  uint64_t at = 12;
  int found = 0;
  while (ok && !found) {
    unsigned char head[8];
    if (fread(head, 1, sizeof(head), f) != sizeof(head)) {
      ok = 0;
      break;
    }
    const uint32_t size = (uint32_t)head[4] | (uint32_t)head[5] << 8 |
                          (uint32_t)head[6] << 16 | (uint32_t)head[7] << 24;
    at += 8;
    if (memcmp(head, "fmt ", 4) == 0) {
      unsigned char fmt[16];
      ok = size >= 16 && fread(fmt, 1, sizeof(fmt), f) == sizeof(fmt);
      if (!ok) break;
      *channels = fmt[2] | fmt[3] << 8;
      *frame_bytes = (uint64_t)(fmt[12] | fmt[13] << 8);
      ok = fseek(f, (long)(size - 16 + (size & 1u)), SEEK_CUR) == 0;
      at += size + (size & 1u);
    } else if (memcmp(head, "data", 4) == 0) {
      *header_bytes = at;
      found = 1;
    } else {
      ok = fseek(f, (long)(size + (size & 1u)), SEEK_CUR) == 0;
      at += size + (size & 1u);
    }
  }
  fclose(f);
  return ok && found && *frame_bytes > 0;
}

/* What le_wav_seal accepts, which a render checks before it writes a
 * master: a take an earlier build stopped at the RIFF limit, a frame or two
 * past today's longest, still renders its master. The frames are credited, not
 * written (the sealed file is sparse). */
static void file_limit_check_sealable(void) {
  char path[760];
  snprintf(path, sizeof(path), "%s/sealable.wav", perf_test_dir());
  test_render_mkdir(perf_test_dir());
  CHECK(le_wav_sealable_frames(2) == le_wav_max_frames(2) + 1);
  CHECK(le_wav_sealable_frames(1) == le_wav_max_frames(1) + 2);
  for (int over = 0; over < 2; ++over) {
    le_wav_writer w;
    CHECK(le_wav_open(&w, path, 96000, 2, NULL, NULL, 0));
    le_wav_note_frames(&w, le_wav_sealable_frames(2) + (uint64_t)over);
    CHECK(le_wav_seal(&w, 0) == !over);
    remove(path);
  }
}

static void test_perf_longest_take_fits_one_fat32_file(void) {
  printf("test_perf_longest_take_fits_one_fat32_file\n");
  static const char* const rels[] = {"stems/dry/track0.wav",
                                     "stems/dry/track1.wav",
                                     "stems/wet/track0.wav",
                                     "stems/wet/track1.wav",
                                     "stems/wet/master.wav"};
  static const uint64_t rates[] = {44100, 48000, 88200, 96000, 176400, 192000};
  /* The app's longest take (PerformanceRepository.longestTake, 3 h) and
   * the longest a target can ask for. */
  static const int32_t caps[] = {3 * 60 * 60, INT32_MAX};
  for (int stereo = 0; stereo < 2; ++stereo) {
    const int master_channels = stereo ? 2 : 1;
    const char* dir = render_fixture_masked(
        stereo ? "file-limit-stereo" : "file-limit-mono", 4800,
        stereo ? 3 : 1);
    le_engine* e = le_engine_create();
    CHECK(le_perf_render_begin(e, dir) == LE_OK);
    int32_t done = 0;
    for (int i = 0; i < 60000 && !done; ++i) {
      le_perf_render_poll(e, &done, NULL, NULL);
      if (!done) test_sleep_ms(1);
    }
    CHECK(done == 1);
    le_engine_destroy(e);
    for (size_t r = 0; r < sizeof(rels) / sizeof(rels[0]); ++r) {
      uint64_t header_bytes = 0, frame_bytes = 0;
      int channels = 0;
      CHECK(file_limit_layout(dir, rels[r], &header_bytes, &frame_bytes,
                              &channels));
      if (r == 4) CHECK(channels == master_channels);
      for (size_t k = 0; k < sizeof(rates) / sizeof(rates[0]); ++k) {
        for (size_t c = 0; c < sizeof(caps) / sizeof(caps[0]); ++c) {
          const uint64_t frames =
              le_perf_longest_take_frames(caps[c], rates[k], master_channels);
          CHECK(frames != UINT64_MAX);
          const uint64_t bytes = header_bytes + frames * frame_bytes;
          if (bytes > FL_FAT32_MAX_FILE_BYTES) {
            printf("  %s: %llu bytes at %llu Hz, cap %d s\n", rels[r],
                   (unsigned long long)bytes, (unsigned long long)rates[k],
                   (int)caps[c]);
          }
          CHECK(bytes <= FL_FAT32_MAX_FILE_BYTES);
        }
      }
    }
    render_memory_clean(dir);
  }
  /* Today's lengths: 3 h at 48 kHz, cut by nothing; a stereo master at
   * 96 kHz stops at 93 min, one file's worth. */
  CHECK(le_perf_longest_take_frames(3 * 60 * 60, 48000, 2) ==
        3ull * 60 * 60 * 48000);
  CHECK(le_perf_longest_take_frames(3 * 60 * 60, 96000, 2) / 96000 / 60 ==
        93);
  CHECK(le_perf_longest_take_frames(0, 48000, 2) == UINT64_MAX);
  file_limit_check_sealable();
}
