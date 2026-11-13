/*
 * render_capture.c — renders a capture's stems on this machine with the
 * engine's offline render (le_perf_render_begin), as the console renders
 * them after a take: stems/dry, stems/wet and stems/wet/master.wav. Built
 * with the console's tanhf and powf like the plugins, so it is what the
 * console would render for the capture's manifest and log.
 *
 * Used to check an exported Live set against a capture whose chains were
 * changed by hand (#1804): edit performance.json, render, export.
 *
 * Usage: segno_render_capture <capture dir>
 */
#include <stdio.h>
#include <unistd.h>

#include "segno_engine_api.h"

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <capture dir>\n", argv[0]);
    return 2;
  }
  le_engine* e = le_engine_create();
  if (e == NULL) {
    fprintf(stderr, "cannot create an engine\n");
    return 1;
  }
  if (le_perf_render_begin(e, argv[1]) != LE_OK) {
    fprintf(stderr, "cannot start the render of %s\n", argv[1]);
    le_engine_destroy(e);
    return 1;
  }
  int32_t done = 0, progress = 0, tracks = 0;
  int32_t status = LE_OK;
  while (!done) {
    status = le_perf_render_poll(e, &done, &progress, &tracks);
    if (!done) usleep(20000);
  }
  /* A manifest the render cannot use ends it with no track. */
  int failed = status != LE_OK || tracks == 0;
  if (failed) fprintf(stderr, "the render failed (%d)\n", status);
  for (int32_t i = 0; i < tracks; ++i) {
    int32_t channel = -1, ok = 0;
    le_perf_render_track_status(e, i, &channel, &ok);
    printf("track %d: %s\n", channel, ok ? "rendered" : "FAILED");
    failed |= !ok;
  }
  le_engine_destroy(e);
  return failed;
}
