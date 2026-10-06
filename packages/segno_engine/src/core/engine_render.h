/* engine_render.h — the shared render recipe's seams into the engine (#1202).
 *
 * The recipe (engine_render.c) renders the selected recorded tracks offline
 * for Bounce and Save selected audio. It is one job per engine, frozen by a
 * callback command (LE_CMD_RENDER_FREEZE), staged by the control thread with
 * the wet cache's copy-at-enqueue gate, and rendered in slices on the wet
 * cache's worker. NOT the FFI surface (segno_engine_api.h declares the
 * le_engine_render_* entry points) and not included by engine_private.h. */
#ifndef SEGNO_ENGINE_RENDER_H
#define SEGNO_ENGINE_RENDER_H

#include "engine_private.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_render_job le_render_job;

/* Frames one worker slice renders; the bound on how long a recipe can hold an
 * audible lane's print back. */
#define LE_RENDER_SLICE_FRAMES 48000

/* Audible-lane prints the worker may take ahead of a waiting recipe before
 * the recipe's next slice goes first (aging). */
#define LE_RENDER_MAX_YIELDS 8

/* The most a render job may hold at once: staged sources, prints, effect
 * states and its output (a file job holds one slice of output). The recipe's
 * own budget, apart from the wet cache's (plan 4.7): eight stereo 30 s tracks
 * at 96 kHz stage about 176 MiB of dry audio, and a Bounce's 30 s stereo
 * result is about 22 MiB more. Memory is held only while a job runs. */
#define LE_RENDER_BUDGET_BYTES (256ll * 1024 * 1024)

/* Frames of one source lane the control thread stages per copy. */
#define LE_RENDER_COPY_CHUNK_FRAMES 48000

/* Wall time one staging heartbeat may spend copying, in nanoseconds (2 ms);
 * a heartbeat copies at least one chunk. A variable so a test can set 0 and
 * step staging one chunk at a time. */
extern uint64_t le_render_stage_budget_ns;

/* Control thread: the bytes the current job holds (0 without one). A
 * finished job holds only a memory result. */
int64_t le_render_held_bytes(le_engine* engine);

/* Control thread, from the cache tick: advances freezing and staging, and
 * collects the worker's outcome. */
void le_render_tick(le_engine* engine);

/* Worker thread: 1 when a recipe slice is waiting. */
int le_render_worker_ready(le_engine* engine);

/* The worker's choice for one turn: 1 = run a recipe slice, 0 = run the
 * cache's job. Prints for audible lanes go first; a waiting recipe goes before
 * stopped-lane prints; after LE_RENDER_MAX_YIELDS audible prints in a row
 * have gone ahead of a waiting recipe, the recipe goes next. Pure. */
int le_render_worker_choice(int audible_print, int recipe, int* yields);

/* Worker thread: renders one unit (one print, or one window slice). */
void le_render_worker_step(le_engine* engine);

/* Control thread, from le_cache_shutdown after the worker joined: fails an
 * unfinished job with LE_ERR_DEVICE and returns its bytes to the cache. */
void le_render_on_cache_shutdown(le_engine* engine);

/* Control thread, le_engine_destroy: frees every job. */
void le_render_destroy(le_engine* engine);

/* Audio thread, LE_CMD_RENDER_FREEZE: defined in engine_process.c, where
 * the read law lives. */

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_RENDER_H */
