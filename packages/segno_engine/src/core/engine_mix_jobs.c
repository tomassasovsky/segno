/*
 * engine_mix_jobs.c — the mixer whose track chains run as jobs (#1729).
 *
 * engine_process.c holds one mixer body. This translation unit compiles it a
 * third time, with LE_MIX_HEARD_TU and LE_MIX_JOBS_TU defined: the heard
 * image's code (#1713) and the jobs' (#1729), named mix_tracks_frame_jobs,
 * the copy le_engine_process calls for a block whose track chains run on
 * the effects workers. It records each track's frame for its job
 * (le_trk_job) instead of running the lanes' and the track's chains and
 * routing them, and it defines the jobs themselves (le_trk_job_run and the
 * calls engine_workers.h lists). The plain copy, mix_tracks_frame, and the
 * heard one, mix_tracks_frame_heard, have none of this code, so the mixer
 * the 64-lane bench gates compiles as it did. This copy defines none of
 * engine_process.c's other external functions.
 */
#define LE_MIX_HEARD_TU 1
#define LE_MIX_JOBS_TU 1

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-function"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

#include "engine_process.c"
