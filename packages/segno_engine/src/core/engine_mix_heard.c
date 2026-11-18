/*
 * engine_mix_heard.c — the mixer with the heard image compiled in (#1713).
 *
 * engine_process.c holds one mixer body. This translation unit compiles it a
 * second time with LE_MIX_HEARD_TU defined, which turns on its
 * #ifdef LE_MIX_HEARD_TU blocks (the capture log, a heard lane's pair from
 * le_heard_lane_wet, the seam fold's share of the images) and names the
 * result mix_tracks_frame_heard, the copy le_engine_process calls for a
 * block where a lane holds a heard image. engine_process.c's own copy,
 * mix_tracks_frame, has none of that code, and every helper it inlines keeps
 * its one caller there, so the plain mixer compiles as it did before the
 * heard image. This copy defines none of engine_process.c's external
 * functions; the static ones the heard mixer does not reach are dropped.
 */
#define LE_MIX_HEARD_TU 1

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-function"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

#include "engine_process.c"
