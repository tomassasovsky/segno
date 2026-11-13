/*
 * capture_log.h — the events.log of the null test's captures, written in C
 * because the log's entry types live in the engine's C headers.
 */
#ifndef SEGNO_VST3_CAPTURE_LOG_H
#define SEGNO_VST3_CAPTURE_LOG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One change the log carries, at capture frame [frame]: setting [param] of
 * lane 0's entry 0 to [value], or (param -1) the entry's enable bit to
 * [value] != 0. */
typedef struct capture_log_change {
  int32_t frame;
  int32_t param;
  float value;
} capture_log_change;

/* Writes [path]: the header at [rate], the PERF_ARMED fact with FX clock
 * [clock] and the arm's tempo anchor ([beat], [qpf], 4/4) at frame 0, then
 * [count] changes in order. Returns 0 on failure. */
int capture_log_write(const char* path, int32_t rate, uint32_t clock, double beat,
                      float qpf, const capture_log_change* changes, int count);

#ifdef __cplusplus
}
#endif

#endif
