#include "capture_log.h"

#include <stdio.h>
#include <string.h>

#include "perf_log_ring.h"

/* One 28-byte entry: the frame, the code, the 16-byte payload. */
static void entry(FILE* f, uint64_t frame, const le_log_command* c) {
  fwrite(&frame, 8, 1, f);
  fwrite(&c->code, 4, 1, f);
  fwrite(&c->arg_i, 16, 1, f);
}

int capture_log_write(const char* path, int32_t rate, uint32_t clock, double beat,
                      float qpf, const capture_log_change* changes, int count) {
  FILE* f = fopen(path, "wb");
  if (f == NULL) return 0;
  const uint32_t version = 16;
  fwrite("PLEV", 1, 4, f);
  fwrite(&version, 4, 1, f);
  fwrite(&rate, 4, 1, f);
  le_log_command armed;
  memset(&armed, 0, sizeof(armed));
  armed.code = LE_PLOG_PERF_ARMED;
  armed.perf_arm.fx_clock = clock;
  entry(f, 0, &armed);
  le_log_command tempo;
  memset(&tempo, 0, sizeof(tempo));
  tempo.code = LE_PLOG_FX_TEMPO;
  uint64_t bits;
  memcpy(&bits, &beat, 8);
  tempo.fx_tempo_log.beat_lo = (uint32_t)bits;
  tempo.fx_tempo_log.beat_hi = (uint32_t)(bits >> 32);
  tempo.fx_tempo_log.qpf = qpf;
  tempo.fx_tempo_log.num = 4;
  tempo.fx_tempo_log.den = 4;
  entry(f, 0, &tempo);
  for (int i = 0; i < count; ++i) {
    le_log_command c;
    memset(&c, 0, sizeof(c));
    if (changes[i].param >= 0) {
      c.code = LE_PLOG_SET_LANE_FX_PARAM;
      c.fx.index = LE_PLOG_FX_PARAM_PACK(0, changes[i].param);
      memcpy(&c.fx.type, &changes[i].value, 4);
    } else {
      c.code = LE_PLOG_SET_LANE_FX_ENABLED;
      c.fx.type = changes[i].value != 0.0f;
    }
    entry(f, (uint64_t)changes[i].frame, &c);
  }
  return fclose(f) == 0;
}
