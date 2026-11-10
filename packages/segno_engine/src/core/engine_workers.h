/*
 * engine_workers.h — effects on more than one core (#1515).
 *
 * The worker pool that runs a block's monitor chains beside the audio
 * callback, and the jobs themselves. le_engine_process calls le_fx_jobs_run
 * once per block of its frame loop (le_fx_par in engine_private.h has the
 * block's shape); the control thread starts and stops the pool. Not part of
 * the FFI surface; the public calls are le_engine_set_fx_workers and
 * le_engine_get_fx_workers_telemetry (segno_engine_api.h).
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

/* ---- Track chains as jobs (#1729), engine_mix_jobs.c ----
 *
 * le_trk_jobs_begin decides at a block's start whether its track chains run
 * as jobs: only with workers running and two jobs at least, counting the
 * monitor jobs already queued. If so it queues a job per track with a chain
 * (le_engine.trk_job_t, after the le_engine.trk_job_mon_n monitor jobs of
 * le_fx_par), points every track chain's clock and
 * tempo at its job's (le_trk_job.time) and the All tracks chains' at
 * le_engine.at_time, and returns the tracks queued; le_engine.trk_jobs_live
 * is then nonzero until le_trk_jobs_end, and le_engine_process mixes the
 * block with mix_tracks_frame_jobs. le_trk_job_run runs track [t]'s job
 * over the block's frames up to [upto] (on a worker or the callback).
 * le_trk_jobs_flush runs the jobs of [tracks] up to the frame the mixer is
 * at, on the callback, before it changes what they read; a no-op outside
 * such a block. le_trk_jobs_end, after the join, runs whatever is left,
 * sums every track onto [out] in the mixer's order, runs the All tracks
 * stage and points the chains back at the engine's clock. Audio thread
 * only; no allocation, no lock. */
uint32_t le_trk_jobs_begin(le_engine* e, int tc, const int32_t* lane_n,
                           const int* lane_fx_any);
#ifdef LE_NATIVE_TESTS
/* Native tests only: every block with a track chain runs its track chains as
 * jobs, with no workers too (the callback runs them, in job order), so the
 * whole suite exercises the records, the jobs and the join against its own
 * expectations (a local tool: run with SEGNO_TRK_JOBS_FORCE=1). */
extern int le_test_trk_jobs_force;
/* Native tests only: the blocks whose track chains ran as jobs, counted in
 * every build (the workers' job counts are callback telemetry). */
extern uint64_t le_test_trk_jobs_blocks;
#endif
void le_trk_job_run(le_engine* e, int t, uint32_t upto);
void le_trk_jobs_flush(le_engine* e, uint32_t tracks);
/* The same for lane [l] of track [t]'s chain alone, ahead of its job: what
 * a heard lane's crossfade or a lane print needs, frame after frame, while
 * the track's other chains stay on the job. */
void le_trk_lane_flush(le_engine* e, int t, int l);
void le_trk_jobs_end(le_engine* e, float* out, int ch_out,
                     uint32_t out_enabled, float* trk_lpeak,
                     float* trk_rpeak);

/* Starts the requested workers (le_engine_set_fx_workers) unless they run
 * already. Control thread, while no callback runs. */
void le_fx_pool_start(le_engine* e);

/* Stops and joins every worker. Control thread, while no callback runs. */
void le_fx_pool_stop(le_engine* e);

#endif /* SEGNO_ENGINE_WORKERS_H */
