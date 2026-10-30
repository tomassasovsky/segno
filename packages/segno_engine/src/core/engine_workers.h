/*
 * engine_workers.h — effects on more than one core (#1515).
 *
 * The worker pool that runs a block's monitor chains beside the audio
 * callback, and the jobs themselves. le_engine_process calls le_fx_jobs_run
 * once per block of its frame loop (le_fx_par in engine_private.h has the
 * block's shape); the control thread starts and stops the pool. Not part of
 * the FFI surface; the public calls are le_engine_set_fx_workers and
 * le_engine_get_fx_workers_telemetry (segno_engine_api.h).
 *
 * Deliberately not included by engine_private.h, so it reaches no C++
 * translation unit (docs/PROGRESS.md, "Adding a header to src/core/").
 */
#ifndef SEGNO_ENGINE_WORKERS_H
#define SEGNO_ENGINE_WORKERS_H

#include "engine_private.h"

/* The workers' SCHED_FIFO priority where the callback runs real-time: one
 * below the callback (80), above the ALSA MIDI thread (70) and the threaded
 * IRQs (50), below the sound card's IRQ thread (90). */
#define LE_FX_WORKER_PRIO 79

/* Each worker's stack, faulted in and locked as the worker starts: the
 * chains' deepest frames (the octaver's FFT scratch) are a few tens of
 * kilobytes. */
#define LE_FX_WORKER_STACK_BYTES ((size_t)512 << 10)

/* Runs the block's jobs (le_fx_par): with workers, releases them, claims
 * them alongside the workers and waits until every one is done; without,
 * runs them in job order. Audio thread only; no allocation, no lock. */
void le_fx_jobs_run(le_engine* e);

/* Starts the requested workers (le_engine_set_fx_workers) unless they run
 * already. Control thread, while no callback runs. */
void le_fx_pool_start(le_engine* e);

/* Stops and joins every worker. Control thread, while no callback runs. */
void le_fx_pool_stop(le_engine* e);

#endif /* SEGNO_ENGINE_WORKERS_H */
