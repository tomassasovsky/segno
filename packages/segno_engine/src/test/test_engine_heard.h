/* #1713: the heard image. A take recorded through effects keeps the input
 * chain's output, captured in stereo beside the clean take, in lockstep with
 * it slot for slot, and plays it back instead of re-running the chain.
 * Included by test_engine_core.c (shares its harness: CHECK, drain,
 * settle_layers, record_base_loop's conventions). */

/* ---- the lockstep check ---- */

/* The slots a check may compare on track [ch], with the frames each holds:
 * the live image and every image on the undo and redo stacks. Armed shadows
 * are left out (only what a pass has written yet is meaningful there). */
static int heard_check_slots(le_engine* e, int32_t ch, int32_t* slots,
                             int32_t* lens) {
  le_track* t = &e->tracks[ch];
  const int32_t track_len = load_i32(&t->lanes[0].a_len);
  int n = 0;
  slots[n] = load_i32(&t->lanes[0].a_live);
  lens[n++] = track_len;
  for (int i = 0; i < t->undo_count; ++i) {
    const le_hist_entry* h = &t->undo_stack[i];
    if (h->slot < 0) continue;
    slots[n] = h->slot;
    lens[n++] = h->len > 0 ? h->len : track_len;
  }
  for (int i = 0; i < t->redo_count; ++i) {
    const le_hist_entry* h = &t->redo_stack[i];
    if (h->slot < 0) continue;
    slots[n] = h->slot;
    lens[n++] = h->len > 0 ? h->len : track_len;
  }
  return n;
}

static int g_heard_checks;
static int g_heard_check_failed;

/* With no chain on its input, a lane's image IS its clean take: both planes
 * equal the clean slot over every image the track holds, after any sequence
 * of captures, folds, fades, drains and history moves. Lanes whose input runs
 * a chain differ by design and are skipped. */
static void heard_lockstep_check(le_engine* e) {
  /* The live image every callback; the whole history every 16th (a long
   * history of long loops is otherwise most of the suite's time). */
  const int all = g_heard_checks++ % 16 == 0;
  int32_t slots[2 * LE_POOL_SLOTS + 1];
  int32_t lens[2 * LE_POOL_SLOTS + 1];
  for (int32_t ch = 0; ch < e->track_count; ++ch) {
    const int n = all ? heard_check_slots(e, ch, slots, lens) : 1;
    if (!all) {
      slots[0] = load_i32(&e->tracks[ch].lanes[0].a_live);
      lens[0] = load_i32(&e->tracks[ch].lanes[0].a_len);
    }
    for (int32_t l = 0; l < LE_MAX_LANES; ++l) {
      if (!le_heard_any(e, ch, l)) continue;
      const le_lane* ln = &e->tracks[ch].lanes[l];
      const int32_t input = load_i32(&((le_lane*)ln)->a_input_channel);
      if (input >= 0 && input < LE_MAX_MONITORED_INPUTS &&
          load_i32(&e->monitors[input].a_fx_count) > 0) {
        continue;
      }
      for (int k = 0; k < n; ++k) {
        const int32_t s = slots[k];
        float* pl;
        float* pr;
        if (!le_heard_planes(e, ch, l, s, &pl, &pr)) continue;
        const float* c = ln->pool[s];
        if (c == NULL) {
          if (!g_heard_check_failed) {
            printf("  FAIL: heard planes on a slot with no clean buffer "
                   "(track %d lane %d slot %d)\n", ch, l, s);
          }
          g_heard_check_failed = 1;
          g_failures++;
          continue;
        }
        int32_t len = lens[k];
        if (len > ln->pool_cap[s]) len = ln->pool_cap[s];
        for (int32_t i = 0; i < len; ++i) {
          if (pl[i] != c[i] || pr[i] != c[i]) {
            if (!g_heard_check_failed) {
              printf("  FAIL: heard image differs from the clean take "
                     "(track %d lane %d slot %d frame %d: %g %g vs %g)\n",
                     ch, l, s, i, pl[i], pr[i], c[i]);
            }
            g_heard_check_failed = 1;
            g_failures++;
            break;
          }
        }
      }
    }
  }
}

/* ---- helpers ---- */

static le_record_image heard_image(uint32_t revision, uint32_t heard_mask) {
  le_record_image image = {.revision = revision, .lane_mask = 1};
  image.gain[0] = 1.0f;
  image.heard_mask = heard_mask;
  return image;
}

/* A stereo-out engine with input 0's monitor on, routed to both outputs. */
static le_engine* heard_engine(int32_t max_frames) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 2, max_frames) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x3) == LE_OK);
  drain(e);
  return e;
}

/* Input 0's monitor chain: one reverb at half mix, so its output differs
 * between the two sides and from the input. */
static void heard_monitor_reverb(le_engine* e) {
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_REVERB) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.6f) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 0.5f) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 0.5f) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK);
  drain(e);
}

/* A deterministic test signal: a decaying burst of a few partials. */
static float heard_signal(int32_t i) {
  const float t = (float)i / 48000.0f;
  return 0.2f * expf(-6.0f * t) *
         (sinf(6.2831853f * 220.0f * t) + 0.5f * sinf(6.2831853f * 517.0f * t));
}

/* Processes [n] mono frames of heard_signal from [from], in blocks of
 * [blk], into the stereo [out] (2 * n). */
static void heard_feed(le_engine* e, int32_t from, int32_t n, int32_t blk,
                       float* out) {
  float in[512];
  float o[1024];
  for (int32_t done = 0; done < n;) {
    int32_t k = n - done < blk ? n - done : blk;
    if (k > 512) k = 512;
    for (int32_t i = 0; i < k; ++i) in[i] = heard_signal(from + done + i);
    le_engine_process(e, o, in, (uint32_t)k);
    if (out != NULL) memcpy(out + 2 * done, o, (size_t)k * 2 * sizeof(float));
    done += k;
  }
}

static void heard_silence(le_engine* e, int32_t n, int32_t blk, float* out) {
  float in[512] = {0};
  float o[1024];
  for (int32_t done = 0; done < n;) {
    int32_t k = n - done < blk ? n - done : blk;
    if (k > 512) k = 512;
    le_engine_process(e, o, in, (uint32_t)k);
    if (out != NULL) memcpy(out + 2 * done, o, (size_t)k * 2 * sizeof(float));
    done += k;
  }
}

/* ---- tests ---- */

/* The defining take through a reverb: its image is exactly what the monitor
 * played (the output, while nothing else sounds), its clean take exactly the
 * input, and the master's seam crossfade folds the image's continuation into
 * its head with the clean take's own arithmetic. */
static void test_heard_take_records_the_chain_output(void) {
  printf("test_heard_take_records_the_chain_output\n");
  enum { N = 4800, F = 480 };
  le_engine* e = heard_engine(48000);
  heard_monitor_reverb(e);
  le_record_image image = heard_image(1, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  static float out[2 * (N + 2 * F)];
  heard_feed(e, 0, N, 64, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize: F more frames, folded */
  heard_feed(e, N, 2 * F, 64, out + 2 * N);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == N);

  le_lane* ln = &e->tracks[0].lanes[0];
  const int32_t live = load_i32(&ln->a_live);
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
  if (pl == NULL) {
    le_engine_destroy(e);
    return;
  }
  int sides_differ = 0;
  for (int32_t i = F; i < N; ++i) {
    CHECK(pl[i] == out[2 * i]);
    CHECK(pr[i] == out[2 * i + 1]);
    if (pl[i] != pr[i]) sides_differ = 1;
  }
  CHECK(sides_differ); /* a stereo image, not a copy of one side */
  for (int32_t i = 0; i < F; ++i) {
    const float x = (float)i / (float)F;
    const float wl = out[2 * (N + i)] * (1.0f - x) + out[2 * i] * x;
    const float wr = out[2 * (N + i) + 1] * (1.0f - x) + out[2 * i + 1] * x;
    CHECK(fabsf(pl[i] - wl) < 1e-6f);
    CHECK(fabsf(pr[i] - wr) < 1e-6f);
  }
  /* The clean take is the input, untouched by the chain. */
  for (int32_t i = F; i < N; ++i) CHECK(ln->pool[live][i] == heard_signal(i));

  le_lane_snapshot ls;
  le_engine_get_lane(e, 0, 0, &ls);
  CHECK(ls.heard == 1);
  CHECK(ls.source == LE_LANE_SOURCE_HEARD);
  le_engine_destroy(e);
}

/* Playback reads the image through the head: with the monitor muted, every
 * output frame of a lap is the image at the frame's own read index, and a
 * chain on the lane does not run over it. */
static void test_heard_take_plays_its_image(void) {
  printf("test_heard_take_plays_its_image\n");
  enum { N = 4800, F = 480 };
  le_engine* e = heard_engine(48000);
  heard_monitor_reverb(e);
  /* A drive on the lane, which would colour a clean playback. */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 1.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  le_record_image image = heard_image(2, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, N, 2 * F, 64, NULL);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, N, 64, NULL); /* a lap for the play gain to settle */
  const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
  float in = 0.0f;
  float o[2];
  int matched = 0;
  for (int32_t k = 0; k < N && pl != NULL; ++k) {
    le_engine_process(e, o, &in, 1);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int32_t p = s.tracks[0].position_frames;
    CHECK(o[0] == pl[p]);
    CHECK(o[1] == pr[p]);
    matched += o[0] == pl[p] && o[1] == pr[p];
  }
  CHECK(matched == N);
  le_engine_destroy(e);
}

/* Switching the lane to its clean take crossfades over 10 ms to the clean
 * take through the lane's chain, which comes back through its re-enable
 * ramp; switching back returns to the image. */
static void test_heard_source_switch(void) {
  printf("test_heard_source_switch\n");
  enum { N = 4800, F = 480 };
  le_engine* e = heard_engine(48000);
  heard_monitor_reverb(e);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 1.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  le_record_image image = heard_image(3, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, N, 2 * F, 64, NULL);
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  heard_silence(e, N, 64, NULL);

  CHECK(le_engine_set_lane_source(e, 0, 0, LE_LANE_SOURCE_CLEAN) == LE_OK);
  le_lane_snapshot ls;
  le_engine_get_lane(e, 0, 0, &ls);
  CHECK(ls.source == LE_LANE_SOURCE_CLEAN);
  heard_silence(e, 2 * F, 64, NULL); /* the crossfade and the chain's ramp */
  CHECK(e->heard[0][0].mix == 0.0f);
  /* Clean through the drive now: not the image. */
  const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
  float in = 0.0f;
  float o[2];
  int differs = 0;
  for (int32_t k = 0; k < 256 && pl != NULL; ++k) {
    le_engine_process(e, o, &in, 1);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int32_t p = s.tracks[0].position_frames;
    if (fabsf(o[0] - pl[p]) > 1e-4f) differs = 1;
    CHECK(o[0] == o[1]); /* the clean take is mono through a mono drive */
  }
  CHECK(differs);

  CHECK(le_engine_set_lane_source(e, 0, 0, LE_LANE_SOURCE_HEARD) == LE_OK);
  heard_silence(e, F, 64, NULL);
  CHECK(e->heard[0][0].mix == 1.0f);
  for (int32_t k = 0; k < 256 && pl != NULL; ++k) {
    le_engine_process(e, o, &in, 1);
    le_snapshot s;
    le_engine_get_snapshot(e, &s);
    const int32_t p = s.tracks[0].position_frames;
    CHECK(o[0] == pl[p]);
    CHECK(o[1] == pr[p]);
  }
  le_engine_destroy(e);
}

/* The image is captured from the chain whether or not the monitor plays it:
 * muted, the take's image is still the chain's output. */
static void test_heard_records_an_unmonitored_chain(void) {
  printf("test_heard_records_an_unmonitored_chain\n");
  enum { N = 4800 };
  le_engine* a = heard_engine(48000); /* monitored: the reference */
  le_engine* b = heard_engine(48000); /* muted */
  heard_monitor_reverb(a);
  heard_monitor_reverb(b);
  CHECK(le_engine_set_monitor_input_mute(b, 0, 1) == LE_OK);
  drain(b);
  le_record_image image = heard_image(4, 1);
  CHECK(le_engine_record_with_image(a, 0, &image) == LE_OK);
  CHECK(le_engine_record_with_image(b, 0, &image) == LE_OK);
  static float out_a[2 * N];
  static float out_b[2 * N];
  heard_feed(a, 0, N, 64, out_a);
  heard_feed(b, 0, N, 64, out_b);
  for (int32_t i = 0; i < 2 * N; ++i) CHECK(out_b[i] == 0.0f); /* silent */
  const int32_t live = load_i32(&b->tracks[0].lanes[0].a_live);
  float* pl;
  float* pr;
  CHECK(le_heard_planes(b, 0, 0, live, &pl, &pr));
  for (int32_t i = 0; i < N && pl != NULL; ++i) {
    CHECK(pl[i] == out_a[2 * i]);
    CHECK(pr[i] == out_a[2 * i + 1]);
  }
  le_engine_destroy(a);
  le_engine_destroy(b);
}

/* The image does not depend on the callback's size: blocks of 1, 37, 64 and
 * 300 frames (past LE_FX_BLOCK, so the frame loop splits) capture the same
 * image bit for bit. */
static void test_heard_capture_is_block_invariant(void) {
  printf("test_heard_capture_is_block_invariant\n");
  enum { N = 4800 };
  static float ref_l[N];
  static float ref_r[N];
  const int32_t blocks[] = {64, 1, 37, 300};
  for (int b = 0; b < 4; ++b) {
    le_engine* e = heard_engine(48000);
    heard_monitor_reverb(e);
    le_record_image image = heard_image(5, 1);
    CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
    heard_feed(e, 0, N, blocks[b], NULL);
    const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
    float* pl;
    float* pr;
    CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
    for (int32_t i = 0; i < N && pl != NULL; ++i) {
      if (b == 0) {
        ref_l[i] = pl[i];
        ref_r[i] = pr[i];
      } else {
        CHECK(pl[i] == ref_l[i]);
        CHECK(pr[i] == ref_r[i]);
      }
    }
    le_engine_destroy(e);
  }
}

/* With an empty input chain the image is the clean take, so the lockstep
 * check (after every callback) holds through overdubs with feedback, Undo,
 * Redo, Peel, a punch-out's drain, rec/dub and a Stop inside a dub. */
static void test_heard_lockstep_through_history(void) {
  printf("test_heard_lockstep_through_history\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_test_heard_check = heard_lockstep_check;
  g_heard_checks = 0;
  g_heard_check_failed = 0;
  le_record_image image = heard_image(6, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  float in[LOOP_N] = {0.9f, -0.4f, 0.3f, 0.7f};
  le_engine_process(e, out, in, LOOP_N);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  CHECK(le_heard_has(e, 0, 0, load_i32(&e->tracks[0].lanes[0].a_live)));
  CHECK(le_engine_set_overdub_feedback(e, 0.6f) == LE_OK);
  for (int pass = 0; pass < 3; ++pass) {
    CHECK(le_engine_record(e, 0) == LE_OK);
    process_const(e, 0.25f * (float)(pass + 1), LOOP_N, out);
    CHECK(le_engine_record(e, 0) == LE_OK);
    drain(e);
    settle_layers(e);
  }
  /* A punch-out mid-pass: the drain completes the layer. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.1f, 2, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  settle_layers(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_peel(e, 0) == LE_OK);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  /* Every undo image keeps its own image. */
  le_track* t = &e->tracks[0];
  for (int i = 0; i < t->undo_count; ++i) {
    if (t->undo_stack[i].slot >= 0) {
      CHECK(le_heard_has(e, 0, 0, t->undo_stack[i].slot));
    }
  }
  /* rec/dub on a second take, stopped inside the dub. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  image = heard_image(7, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* -> OVERDUBBING */
  process_const(e, 0.2f, 3, out);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  drain(e);
  settle_layers(e);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(g_heard_checks > 20);
  CHECK(!g_heard_check_failed);
  CHECK(atomic_load_explicit(&e->a_heard_dropped, memory_order_relaxed) == 0);
  le_test_heard_check = NULL;
  le_engine_destroy(e);
}

/* The seam (#728) and the take's ends (#730) on a loop long enough to fold:
 * a non-defining take over a master, which captures its continuation past
 * the loop end and folds it into its head, and one that stops early, whose
 * ends taper. The image follows the clean take exactly. */
static void test_heard_lockstep_through_seams(void) {
  printf("test_heard_lockstep_through_seams\n");
  enum { L = 4800 };
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 1, 1, 4 * L) == LE_OK);
  le_test_heard_check = heard_lockstep_check;
  g_heard_check_failed = 0;
  g_heard_checks = 0;
  le_test_osc osc = make_osc(36.25, 48000.0);
  /* The master on track 0 (its finalize folds its own seam). */
  le_record_image image = heard_image(8, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  feed_osc(e, &osc, L, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  feed_osc(e, &osc, 512, NULL, NULL);
  drain(e);
  feed_to_loop_top(e);
  /* Track 1: a take from the top that fills its loop, so its continuation
   * is captured past the end and folded into its head (#728). */
  image = heard_image(9, 1);
  CHECK(le_engine_record_with_image(e, 1, &image) == LE_OK);
  drain(e);
  feed_osc(e, &osc, L, NULL, NULL);
  CHECK(le_engine_record(e, 1) == LE_OK);
  feed_osc(e, &osc, 64, NULL, NULL);
  CHECK(e->tracks[1].seam_capture > 0); /* the fold is armed */
  feed_osc(e, &osc, 512 - 64, NULL, NULL);
  drain(e);
  settle_layers(e);
  CHECK(le_heard_has(e, 1, 0, load_i32(&e->tracks[1].lanes[0].a_live)));
  /* An overdub on it, punched out half way: the drain completes the layer. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  feed_osc(e, &osc, L / 2, NULL, NULL);
  CHECK(le_engine_record(e, 1) == LE_OK);
  feed_const(e, 0.0f, 2 * L, NULL, NULL);
  settle_layers(e);
  CHECK(e->tracks[1].undo_count >= 1);
  /* A fresh take that stops short of its loop: both ends taper (#730). */
  CHECK(le_engine_clear(e, 1) == LE_OK);
  drain(e);
  feed_to_loop_top(e);
  image = heard_image(10, 1);
  CHECK(le_engine_record_with_image(e, 1, &image) == LE_OK);
  drain(e);
  feed_osc(e, &osc, L / 2, NULL, NULL);
  CHECK(le_engine_record(e, 1) == LE_OK);
  feed_const(e, 0.0f, 2 * L, NULL, NULL);
  settle_layers(e);
  CHECK(le_heard_has(e, 1, 0, load_i32(&e->tracks[1].lanes[0].a_live)));
  CHECK(g_heard_checks > 100);
  CHECK(!g_heard_check_failed);
  CHECK(atomic_load_explicit(&e->a_heard_dropped, memory_order_relaxed) == 0);
  le_test_heard_check = NULL;
  le_engine_destroy(e);
}

/* A take recorded without an image (a dry take) gets one copied from its
 * clean take, after which an overdub through a chain is captured into it,
 * and its Undo goes back to the copy. */
static void test_heard_attach_gives_a_dry_take_an_image(void) {
  printf("test_heard_attach_gives_a_dry_take_an_image\n");
  enum { N = 4800, F = 480 };
  le_engine* e = heard_engine(48000);
  le_record_image image = heard_image(11, 0); /* no image */
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, N, 2 * F, 64, NULL);
  le_lane* ln = &e->tracks[0].lanes[0];
  int32_t live = load_i32(&ln->a_live);
  CHECK(!le_heard_any(e, 0, 0));
  CHECK(le_engine_heard_attach(e, 0, 0) == LE_OK);
  le_lane_snapshot ls;
  le_engine_get_lane(e, 0, 0, &ls);
  CHECK(ls.heard == 1); /* reported from the post, before it lands */
  CHECK(le_engine_heard_attach(e, 0, 0) == LE_ERR_NOT_READY); /* in flight */
  drain(e);                /* the callback installs it */
  le_engine_drain_events(e); /* and control reads the report */
  float* pl;
  float* pr;
  CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
  for (int32_t i = 0; i < N && pl != NULL; ++i) {
    CHECK(pl[i] == ln->pool[live][i]);
    CHECK(pr[i] == ln->pool[live][i]);
  }
  CHECK(e->heard[0][0].attach[0] == NULL); /* owned by the table now */
  CHECK(le_engine_heard_attach(e, 0, 0) == LE_OK); /* already has one */

  /* An overdub through the reverb: the image gets the chain's output. */
  heard_monitor_reverb(e);
  static float before_l[N];
  memcpy(before_l, pl, sizeof(before_l));
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_silence(e, 64, 64, NULL);
  settle_layers(e);
  live = load_i32(&ln->a_live);
  CHECK(le_heard_planes(e, 0, 0, live, &pl, &pr));
  CHECK(e->tracks[0].undo_count >= 1);
  const int32_t layer = e->tracks[0].undo_stack[e->tracks[0].undo_count - 1].slot;
  float* ul;
  float* ur;
  CHECK(le_heard_planes(e, 0, 0, layer, &ul, &ur));
  for (int32_t i = 0; i < N && ul != NULL; ++i) CHECK(ul[i] == before_l[i]);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(load_i32(&ln->a_live) == layer);
  le_engine_destroy(e);
}

/* A lane playing its image is not printed by the wet cache, and its track
 * has no whole-track print; the chain installed on it does not count as
 * printable work. */
static void test_heard_lane_is_not_printed(void) {
  printf("test_heard_lane_is_not_printed\n");
  enum { N = 4800, F = 480 };
  le_engine* e = heard_engine(48000);
  heard_monitor_reverb(e);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK);
  le_record_image image = heard_image(12, 1);
  CHECK(le_engine_record_with_image(e, 0, &image) == LE_OK);
  heard_feed(e, 0, N, 64, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  heard_feed(e, N, 2 * F, 64, NULL);
  CHECK(le_heard_lane_plays(e, 0, 0));
  CHECK(!le_track_pre_printable(e, 0));
  /* Long enough for a print to settle and render, were it scheduled. */
  for (int k = 0; k < 400; ++k) {
    heard_silence(e, 64, 64, NULL);
    le_engine_drain_events(e);
  }
  le_lane_cache_info info;
  CHECK(le_engine_get_lane_cache(e, 0, 0, &info) == LE_OK);
  CHECK(info.state == LE_CACHE_LIVE);
  CHECK(atomic_load_explicit(&e->tracks[0].lanes[0].a_wet,
                             memory_order_acquire) == NULL);
  le_engine_destroy(e);
}

static void run_heard_tests(void) {
  test_heard_take_records_the_chain_output();
  test_heard_take_plays_its_image();
  test_heard_source_switch();
  test_heard_records_an_unmonitored_chain();
  test_heard_capture_is_block_invariant();
  test_heard_lockstep_through_history();
  test_heard_lockstep_through_seams();
  test_heard_attach_gives_a_dry_take_an_image();
  test_heard_lane_is_not_printed();
}
