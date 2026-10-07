/* Shared render recipe (#1202, Part 1): literal-PCM oracles through the
 * production entry points. Fixtures import literal material (track A ramps
 * 1..16, track B steps of 100 over 24 frames), so every rendered sample names
 * the source indices it came from. The engine runs two outputs, so a live
 * output pair is directly comparable with the rendered pair. */
#include "engine_render.h" /* le_render_worker_choice, LE_RENDER_MAX_YIELDS */
#include "engine_wav.h"    /* le_wav_flush, le_wav_seal */

#define RR_SR 48000

static const char* rr_tmp(void) {
  const char* tmp = getenv("TMPDIR");
  return tmp != NULL && tmp[0] != '\0' ? tmp : "/tmp";
}

static le_engine* rr_engine(void) {
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, RR_SR, 1, 2, 0) == LE_OK);
  return e;
}

/* Imports A (16 frames, A[i] = i + 1) on track 0 and B (24 frames,
 * B[i] = 100 * (i + 1)) on track 1, committed on an 8-frame base. */
static le_engine* rr_fixture(void) {
  le_engine* e = rr_engine();
  float a[16];
  float b[24];
  for (int i = 0; i < 16; ++i) a[i] = (float)(i + 1);
  for (int i = 0; i < 24; ++i) b[i] = 100.0f * (float)(i + 1);
  CHECK(le_engine_import_track(e, 0, a, 16) == LE_OK);
  CHECK(le_engine_import_track(e, 1, b, 24) == LE_OK);
  CHECK(le_engine_commit_session(e, 8, 0) == LE_OK);
  drain(e);
  return e;
}

static float rr_a(int64_t i) { return (float)(((i % 16) + 16) % 16 + 1); }
static float rr_b(int64_t i) { return 100.0f * (float)(((i % 24) + 24) % 24 + 1); }

/* Pumps `frames` of silence through the callback, stereo out kept. */
static void rr_pump(le_engine* e, float* out, int frames, int block) {
  float in[512] = {0};
  float scratch[1024];
  for (int at = 0; at < frames;) {
    int n = frames - at;
    if (n > block) n = block;
    le_engine_process(e, out != NULL ? out + 2 * at : scratch, in, (uint32_t)n);
    at += n;
  }
}

static le_render_request rr_request(uint32_t mask, int32_t tails) {
  le_render_request q;
  memset(&q, 0, sizeof(q));
  q.source_mask = mask;
  q.tails = tails;
  q.target = LE_RENDER_TARGET_MEMORY;
  return q;
}

/* Polls (each poll is a staging heartbeat) until DONE or FAILED. */
static int32_t rr_wait(le_engine* e, uint32_t id, int32_t* result) {
  int32_t state = LE_RENDER_NONE;
  for (int k = 0; k < 10000; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, NULL, result) == LE_OK);
    if (state == LE_RENDER_DONE || state == LE_RENDER_FAILED) return state;
    test_sleep_ms(1);
  }
  return state;
}

/* Begins, lets the callback freeze, and waits. Returns the frames copied
 * into `out` (interleaved stereo), or a negative code. */
static int32_t rr_render(le_engine* e, const le_render_request* q, float* out,
                         int32_t max) {
  uint32_t id = 0;
  const int32_t rc = le_engine_render_begin(e, q, &id);
  if (rc != LE_OK) return rc;
  drain(e); /* the freeze applies at this drain */
  int32_t result = LE_OK;
  if (rr_wait(e, id, &result) != LE_RENDER_DONE) return result;
  return out != NULL ? le_engine_render_copy(e, id, out, max) : 0;
}

static void test_render_common_cycle_literal(void) {
  printf("test_render_common_cycle_literal\n");
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  le_render_plan plan;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.frames == 48); /* lcm(16, 24) */
  CHECK(plan.method == LE_RENDER_COMMON_CYCLE);
  CHECK(plan.tempo_set == 0 && plan.beats_milli == 0);
  CHECK(plan.plugin_mask == 0 && plan.faded_mask == 0);
  float out[2 * 64];
  CHECK(rr_render(e, &q, out, 64) == 48);
  for (int f = 0; f < 48; ++f) {
    CHECK(out[2 * f] == rr_a(f) + rr_b(f));
    CHECK(out[2 * f + 1] == rr_a(f) + rr_b(f));
  }
  /* A stopped engine renders without anyone playing it: transport is not a
   * gate, and Wrap equals Cut without any window stage. */
  le_render_request w = rr_request(0x3, LE_RENDER_WRAP);
  float wrap[2 * 64];
  CHECK(rr_render(e, &w, wrap, 64) == 48);
  CHECK(memcmp(out, wrap, sizeof(float) * 96) == 0);
  le_engine_destroy(e);
}

static void test_render_ignores_transport_mute_solo(void) {
  printf("test_render_ignores_transport_mute_solo\n");
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  float plain[2 * 48];
  CHECK(rr_render(e, &q, plain, 48) == 48);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  CHECK(le_engine_set_track_solo(e, 2, 1) == LE_OK); /* another track soloed */
  drain(e);
  float gated[2 * 48];
  CHECK(rr_render(e, &q, gated, 48) == 48);
  CHECK(memcmp(plain, gated, sizeof(plain)) == 0);
  le_engine_destroy(e);
}

static void test_render_levels_pans_gain(void) {
  printf("test_render_levels_pans_gain\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_set_lane_volume(e, 0, 0, 0.5f) == LE_OK);
  CHECK(le_engine_set_lane_pan(e, 1, 0, 1.0f) == LE_OK);
  le_mix_settings mix;
  memset(&mix, 0, sizeof(mix));
  mix.revision = 1;
  mix.track_gain_mask = 1u;
  mix.track_gain[0] = 2.0f;
  CHECK(le_engine_set_mix(e, &mix) == LE_OK);
  drain(e);
  float gl, gr;
  le_pan_gains(1.0f, &gl, &gr);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  float out[2 * 48];
  CHECK(rr_render(e, &q, out, 48) == 48);
  for (int f = 0; f < 48; ++f) {
    const float a = rr_a(f) * 0.5f * 2.0f; /* level, then gain */
    CHECK(out[2 * f] == a + rr_b(f) * gl);
    CHECK(out[2 * f + 1] == a + rr_b(f) * gr);
  }
  le_engine_destroy(e);
}

/* Render frame f is the live read law run forward from the top of the
 * iteration the freeze lands in: the live pair continues exactly as the
 * render predicts, for a forward pair and after a mid-loop Reverse toggle
 * (a non-zero origin, review H1). */
static void test_render_live_phase_and_reverse_offset(void) {
  printf("test_render_live_phase_and_reverse_offset\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_play(e, 0) == LE_OK);
  CHECK(le_engine_play(e, 1) == LE_OK);
  rr_pump(e, NULL, 37, 5);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  float live[2 * 96];
  rr_pump(e, live, 96, 7); /* the first block applies the freeze at 37 */
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  float out[2 * 48];
  CHECK(le_engine_render_copy(e, id, out, 48) == 48);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  const int top = 37 % 8; /* frames since the iteration top at the freeze */
  for (int m = 0; m < 96; ++m) {
    CHECK(live[2 * m] == out[2 * ((top + m) % 48)]);
  }
  /* Reverse A mid-loop, past its turn window, then freeze again. */
  uint64_t rq;
  CHECK(le_engine_toggle_reverse(e, 0, &rq) == LE_OK);
  rr_pump(e, NULL, 1003, 64);
  le_track_snapshot ts;
  le_engine_get_track(e, 0, &ts);
  CHECK(ts.reversed == 1);
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  const int at = (37 + 96 + 1003) % 8;
  rr_pump(e, live, 96, 5);
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  CHECK(le_engine_render_copy(e, id, out, 48) == 48);
  for (int m = 0; m < 96; ++m) {
    CHECK(live[2 * m] == out[2 * ((at + m) % 48)]);
  }
  le_engine_destroy(e);
}

static void test_render_once_then_silence(void) {
  printf("test_render_once_then_silence\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_set_one_shot_mask(e, 1u, 1) == LE_OK);
  drain(e);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  q.length_bars = 0;
  /* A alone has a 16-frame cycle; widen the window with B present but
   * render A only through a chosen length is not available without a
   * tempo, so render both and subtract B's literal. */
  q.source_mask = 0x3;
  float out[2 * 48];
  CHECK(rr_render(e, &q, out, 48) == 48);
  for (int f = 0; f < 48; ++f) {
    const float a = f < 16 ? rr_a(f) : 0.0f;
    CHECK(out[2 * f] == a + rr_b(f));
  }
  le_engine_destroy(e);
}

/* A reversed Once source on a common cycle plays its single pass backwards
 * (review L-D2): from the frame its law reads the lap start, A[15] down to
 * A[0], once, and silence elsewhere (the window is a loop, so the pass may
 * wrap at its end). */
static void test_render_once_reversed(void) {
  printf("test_render_once_reversed\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_set_one_shot_mask(e, 1u, 1) == LE_OK);
  uint64_t rq;
  CHECK(le_engine_toggle_reverse(e, 0, &rq) == LE_OK);
  drain(e);
  le_track_snapshot ts;
  le_engine_get_track(e, 0, &ts);
  CHECK(ts.reversed == 1);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  float out[2 * 48];
  CHECK(rr_render(e, &q, out, 48) == 48);
  int start = -1;
  for (int f = 0; f < 48 && start < 0; ++f) {
    const int prev = (f + 47) % 48;
    if (out[2 * f] != rr_b(f) && out[2 * prev] == rr_b(prev)) start = f;
  }
  CHECK(start >= 0);
  for (int k = 0; k < 48 && start >= 0; ++k) {
    const int f = (start + k) % 48;
    const float a = k < 16 ? rr_a(15 - k) : 0.0f;
    CHECK(out[2 * f] == a + rr_b(f));
  }
  le_engine_destroy(e);
}

static void test_render_fade_frozen_amount(void) {
  printf("test_render_fade_frozen_amount\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_play(e, 0) == LE_OK);
  uint64_t rq;
  CHECK(le_engine_toggle_fade(e, 0, 0.5f, &rq) == LE_OK); /* 24000 frames */
  rr_pump(e, NULL, 30000, 512);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  drain(e);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  le_render_plan plan;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.faded_mask == 0x1u);
  float out[2 * 48];
  CHECK(rr_render(e, &q, out, 48) == 48);
  for (int f = 0; f < 48; ++f) CHECK(out[2 * f] == rr_b(f)); /* A faded out */
  le_engine_destroy(e);
}

static void test_render_origin_phase_multiples(void) {
  printf("test_render_origin_phase_multiples\n");
  /* Two k = 2 tracks over a base of 8, the second started one loop later:
   * frame 0 reads the first's segment 0 and the second's segment 1. */
  le_engine* e = rr_engine();
  float a[16];
  for (int i = 0; i < 16; ++i) a[i] = (float)(i + 1);
  float base[8];
  for (int i = 0; i < 8; ++i) base[i] = 0.0f;
  CHECK(le_engine_import_track(e, 0, base, 8) == LE_OK);
  CHECK(le_engine_import_track(e, 1, a, 16) == LE_OK);
  CHECK(le_engine_commit_session(e, 8, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rr_pump(e, NULL, 8, 4); /* one base loop */
  CHECK(le_engine_play(e, 1) == LE_OK);
  rr_pump(e, NULL, 8 + 3, 4); /* mid-iteration */
  le_render_request q = rr_request(0x2, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  float live[2 * 32];
  rr_pump(e, live, 32, 3);
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  float out[2 * 16];
  CHECK(le_engine_render_copy(e, id, out, 16) == 16);
  for (int m = 0; m < 32; ++m) CHECK(live[2 * m] == out[2 * ((3 + m) % 16)]);
  le_engine_destroy(e);
}

static void test_render_chosen_length_and_tempo(void) {
  printf("test_render_chosen_length_and_tempo\n");
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  q.length_bars = 3;
  le_render_plan plan;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_ERR_INVALID); /* no tempo */
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.method == LE_RENDER_CHOSEN_LENGTH);
  CHECK(plan.frames == 3 * 4 * RR_SR / 2); /* 12 beats at 120 BPM */
  CHECK(plan.beats_milli == 12000 && plan.tempo_set == 1);
  q.length_bars = 1000; /* clamps to floor(1024 / 4) bars */
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.frames == 256 * 4 * RR_SR / 2);
  q.length_bars = 1;
  q.max_frames = 100;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_ERR_CAPACITY);
  le_engine_destroy(e);
}

static void test_render_no_common_cycle(void) {
  printf("test_render_no_common_cycle\n");
  le_engine* e = rr_engine();
  static float a[4000], b[4001];
  for (int i = 0; i < 4000; ++i) a[i] = 1.0f;
  for (int i = 0; i < 4001; ++i) b[i] = 1.0f;
  CHECK(le_engine_import_track(e, 0, a, 4000) == LE_OK);
  CHECK(le_engine_import_track(e, 1, b, 4001) == LE_OK);
  CHECK(le_engine_commit_session(e, 4000, 0) == LE_OK);
  drain(e);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  le_render_plan plan;
  /* No tempo: the cap is 512 s = 24,576,000 frames; lcm = 16,004,000 fits. */
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.frames == 16004000 && plan.tempo_set == 0);
  /* At 300 BPM the cap is 1024 beats = 9,830,400 frames. */
  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_ERR_NO_COMMON_CYCLE);
  q.source_mask = 0x1; /* one source alone always has a cycle */
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK && plan.frames == 4000);
  le_engine_destroy(e);
}

/* A lane delay as Pre is the take (wrapped at the lane's length, kept by
 * Cut); the same delay as Post is a window stage (cut by Cut, wrapped by
 * Wrap). Review M2. */
static le_engine* rr_delay_fixture(int32_t pre_count) {
  le_engine* e = rr_engine();
  static float pcm[6000];
  memset(pcm, 0, sizeof(pcm));
  pcm[5000] = 1.0f; /* the echo at 5000 + 2400 wraps to frame 1400 */
  CHECK(le_engine_import_track(e, 0, pcm, 6000) == LE_OK);
  CHECK(le_engine_commit_session(e, 6000, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, pre_count) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0,
                                    2400.0f / (float)(RR_SR - 1)) == LE_OK);
  drain(e);
  return e;
}

static float rr_energy(const float* out, int from, int to) {
  float sum = 0.0f;
  for (int f = from; f < to; ++f) sum += fabsf(out[2 * f]) + fabsf(out[2 * f + 1]);
  return sum;
}

static void test_render_pre_is_take_and_tails(void) {
  printf("test_render_pre_is_take_and_tails\n");
  static float cut[2 * 6000], wrap[2 * 6000];
  /* Post: Cut starts dry (nothing before the impulse); Wrap carries the
   * window end's echo into its start. */
  le_engine* post = rr_delay_fixture(0);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  CHECK(rr_render(post, &q, cut, 6000) == 6000);
  q.tails = LE_RENDER_WRAP;
  CHECK(rr_render(post, &q, wrap, 6000) == 6000);
  CHECK(rr_energy(cut, 0, 5000) == 0.0f);
  CHECK(rr_energy(wrap, 1300, 1500) > 0.0f);
  le_engine_destroy(post);
  /* Pre: both tails keep the wrapped echo, identically. */
  le_engine* pre = rr_delay_fixture(1);
  q.tails = LE_RENDER_CUT;
  CHECK(rr_render(pre, &q, cut, 6000) == 6000);
  q.tails = LE_RENDER_WRAP;
  CHECK(rr_render(pre, &q, wrap, 6000) == 6000);
  CHECK(rr_energy(cut, 1300, 1500) > 0.0f);
  CHECK(memcmp(cut, wrap, sizeof(cut)) == 0);
  /* And the Pre material is the cache's own print, byte for byte. */
  le_fx_frozen_chain chain;
  LE_FX_FROZEN_CAPTURE(&chain, &pre->tracks[0].lanes[0]);
  static float dry[6000], print[2 * 6000];
  memset(dry, 0, sizeof(dry));
  dry[5000] = 1.0f;
  CHECK(le_fx_print(&chain, chain.pre, dry, 0, 1.0f, 6000, RR_SR,
                    pre->fx_delay_frames, print, NULL, NULL) == LE_OK);
  CHECK(memcmp(cut, print, sizeof(print)) == 0);
  le_engine_destroy(pre);
}

static void test_render_mix_fx_optional(void) {
  printf("test_render_mix_fx_optional\n");
  le_engine* e = rr_fixture();
  float plain[2 * 48], off[2 * 48], on[2 * 48];
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  CHECK(rr_render(e, &q, plain, 48) == 48);
  CHECK(le_engine_set_all_tracks_fx_count(e, 1) == LE_OK);
  CHECK(le_engine_set_all_tracks_fx(e, 0, LE_FX_DRIVE) == LE_OK);
  drain(e);
  CHECK(rr_render(e, &q, off, 48) == 48);
  CHECK(memcmp(plain, off, sizeof(plain)) == 0);
  q.mix_fx = 1;
  CHECK(rr_render(e, &q, on, 48) == 48);
  CHECK(memcmp(plain, on, sizeof(plain)) != 0);
  le_engine_destroy(e);
}

static void test_render_excludes_buses(void) {
  printf("test_render_excludes_buses\n");
  le_engine* e = rr_fixture();
  float plain[2 * 48], busy[2 * 48];
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  CHECK(rr_render(e, &q, plain, 48) == 48);
  /* Output FX, the master limiter and live input do not reach a render. */
  CHECK(le_engine_set_output_fx_count(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_output_fx(e, 0, 0, LE_FX_DRIVE) == LE_OK);
  float in[64], out[128];
  for (int i = 0; i < 64; ++i) in[i] = 0.75f;
  le_engine_process(e, out, in, 64);
  CHECK(rr_render(e, &q, busy, 48) == 48);
  CHECK(memcmp(plain, busy, sizeof(plain)) == 0);
  le_engine_destroy(e);
}

/* A source with a cold Post chain: the live pair from the loop top equals the
 * Cut render sample for sample. */
static void test_render_live_parity_post_chain(void) {
  printf("test_render_live_parity_post_chain\n");
  le_engine* e = rr_engine();
  static float pcm[4000];
  for (int i = 0; i < 4000; ++i) pcm[i] = (float)((i * 7) % 13) / 13.0f - 0.4f;
  CHECK(le_engine_import_track(e, 0, pcm, 4000) == LE_OK);
  CHECK(le_engine_commit_session(e, 4000, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0,
                                    300.0f / (float)(RR_SR - 1)) == LE_OK);
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  static float live[2 * 3000];
  rr_pump(e, live, 3000, 64);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  static float out[2 * 4000];
  CHECK(rr_render(e, &q, out, 4000) == 4000);
  for (int f = 0; f < 3000; ++f) {
    CHECK(live[2 * f] == out[2 * f]);
    CHECK(live[2 * f + 1] == out[2 * f + 1]);
  }
  le_engine_destroy(e);
}

static void test_render_refusals(void) {
  printf("test_render_refusals\n");
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  le_render_plan plan;
  le_render_request empty = rr_request(0x4, LE_RENDER_CUT); /* track 2 empty */
  CHECK(le_engine_render_measure(e, &empty, &plan) == LE_ERR_INVALID);
  le_render_request none = rr_request(0, LE_RENDER_CUT);
  CHECK(le_engine_render_measure(e, &none, &plan) == LE_ERR_INVALID);
  le_render_request file = rr_request(0x3, LE_RENDER_CUT);
  file.target = LE_RENDER_TARGET_FILE;
  CHECK(le_engine_render_measure(e, &file, &plan) == LE_ERR_INVALID); /* no path */
  q.max_frames = 47;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_ERR_CAPACITY);
  q.max_frames = 0;
  /* No raw post of the freeze command. */
  CHECK(le_engine_post_command(e, LE_CMD_RENDER_FREEZE, 0, 0.0f) !=
        LE_OK);
  /* A second begin while one runs. */
  uint32_t id = 0, other = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  CHECK(le_engine_render_begin(e, &q, &other) == LE_ERR_ALREADY_RUNNING);
  drain(e);
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  /* A finished job gives way to the next begin; the old id is gone. */
  CHECK(le_engine_render_begin(e, &q, &other) == LE_OK);
  CHECK(le_engine_render_poll(e, id, NULL, NULL, NULL) == LE_ERR_INVALID);
  CHECK(le_engine_render_cancel(e, other) == LE_OK);
  /* Over the recipe's own budget: 256 bars at 30 BPM in memory is
   * 98,304,000 stereo frames (786 MB). The wet cache's cap plays no part. */
  CHECK(le_engine_set_tempo(e, 30.0f) == LE_OK);
  drain(e);
  le_render_request huge = rr_request(0x3, LE_RENDER_CUT);
  huge.length_bars = 256;
  le_render_plan big;
  CHECK(le_engine_render_measure(e, &huge, &big) == LE_OK);
  CHECK(le_engine_render_begin(e, &huge, &id) == LE_ERR_CAPACITY);
  CHECK(le_engine_set_fx_cache_cap(e, 64) == LE_OK);
  CHECK(le_engine_render_begin(e, &q, &other) == LE_OK);
  CHECK(le_engine_render_cancel(e, other) == LE_OK);
  /* Without the render worker. */
  struct le_fx_cache* cache = e->cache;
  e->cache = NULL;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_ERR_UNSUPPORTED);
  e->cache = cache;
  /* A capturing source. */
  CHECK(le_engine_record(e, 2) == LE_OK);
  rr_pump(e, NULL, 64, 64);
  le_render_request rec = rr_request(0x4, LE_RENDER_CUT);
  CHECK(le_engine_render_measure(e, &rec, &plan) == LE_ERR_NOT_READY);
  le_engine_destroy(e);
}

static void test_render_staging_tracks_changed(void) {
  printf("test_render_staging_tracks_changed\n");
  const uint64_t budget = le_render_stage_budget_ns;
  le_render_stage_budget_ns = 0; /* one chunk per heartbeat */
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e); /* frozen */
  CHECK(le_engine_clear(e, 0) == LE_OK); /* material changes before staging */
  drain(e);
  int32_t result = LE_OK;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_FAILED);
  CHECK(result == LE_ERR_TRACKS_CHANGED);
  le_engine_destroy(e);
  /* After staging completes, a change no longer touches the result. */
  e = rr_fixture();
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t state = LE_RENDER_FREEZING;
  for (int k = 0; k < 5000 && state < LE_RENDER_RENDERING; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  }
  CHECK(state >= LE_RENDER_RENDERING);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  float out[2 * 48];
  CHECK(le_engine_render_copy(e, id, out, 48) == 48);
  for (int f = 0; f < 48; ++f) CHECK(out[2 * f] == rr_a(f) + rr_b(f));
  le_render_stage_budget_ns = budget;
  le_engine_destroy(e);
}

static void test_render_cancel_and_shutdown(void) {
  printf("test_render_cancel_and_shutdown\n");
  le_engine* e = rr_fixture();
  CHECK(le_engine_set_tempo(e, 30.0f) == LE_OK);
  drain(e);
  le_render_request q = rr_request(0x3, LE_RENDER_WRAP);
  q.length_bars = 64; /* 256 beats at 30 BPM: 512 s of window, two passes */
  q.target = LE_RENDER_TARGET_FILE;
  char path[512];
  snprintf(path, sizeof(path), "%s/rr_cancel_%d.wav", rr_tmp(), (int)test_getpid());
  q.path = path;
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t state = LE_RENDER_FREEZING;
  for (int k = 0; k < 2000 && state < LE_RENDER_RENDERING; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  }
  CHECK(le_engine_render_cancel(e, id) == LE_OK);
  CHECK(le_engine_render_poll(e, id, NULL, NULL, NULL) == LE_ERR_INVALID);
  for (int k = 0; k < 200; ++k) { /* the retired job frees once idle */
    drain(e);
    le_engine_drain_events(e);
    test_sleep_ms(1);
  }
  FILE* f = fopen(path, "rb");
  CHECK(f == NULL);
  if (f != NULL) fclose(f);
  /* A configure joins the worker mid-render: the job fails with DEVICE. */
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  for (int k = 0; k < 50; ++k) le_engine_render_poll(e, id, NULL, NULL, NULL);
  CHECK(le_engine_configure(e, RR_SR, 1, 2, 0) == LE_OK);
  int32_t result = LE_OK;
  CHECK(le_engine_render_poll(e, id, &state, NULL, &result) == LE_OK);
  CHECK(state == LE_RENDER_FAILED && result == LE_ERR_DEVICE);
  le_engine_destroy(e);
  remove(path);
}

static void test_render_file_target_wav(void) {
  printf("test_render_file_target_wav\n");
  le_engine* e = rr_fixture();
  char path[512], part[520];
  snprintf(path, sizeof(path), "%s/rr_file_%d.wav", rr_tmp(), (int)test_getpid());
  snprintf(part, sizeof(part), "%s.part", path);
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  q.target = LE_RENDER_TARGET_FILE;
  q.path = path;
  CHECK(rr_render(e, &q, NULL, 0) == 0);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  unsigned char bytes[44 + 48 * 8];
  CHECK(f != NULL && fread(bytes, 1, sizeof(bytes), f) == sizeof(bytes));
  CHECK(f != NULL && fgetc(f) == EOF);
  if (f != NULL) fclose(f);
  const unsigned char head[44] = {
      'R', 'I', 'F', 'F', 0xA4, 0x01, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't',
      ' ', 16, 0, 0, 0, 3, 0, 2, 0, 0x80, 0xBB, 0, 0, 0x00, 0xDC, 0x05, 0,
      8, 0, 32, 0, 'd', 'a', 't', 'a', 0x80, 0x01, 0, 0};
  CHECK(memcmp(bytes, head, 44) == 0); /* 36 + 384 = 420; 48000 Hz; 384000 B/s */
  float first[2];
  memcpy(first, bytes + 44, sizeof(first));
  CHECK(first[0] == rr_a(0) + rr_b(0) && first[1] == first[0]);
  CHECK(fopen(part, "rb") == NULL);
  remove(path);
  /* A write failure leaves no file and reports DEVICE. */
  char bad[600];
  snprintf(bad, sizeof(bad), "%s/rr_no_such_dir_%d/x.wav", rr_tmp(), (int)test_getpid());
  q.path = bad;
  CHECK(rr_render(e, &q, NULL, 0) == LE_ERR_DEVICE);
  CHECK(fopen(bad, "rb") == NULL);
  le_engine_destroy(e);
}

/* A finished job holds only its result (review M1): a DONE memory job its
 * stereo output, a DONE file job nothing. */
static int64_t rr_settled_bytes(le_engine* e, int64_t want) {
  for (int k = 0; k < 2000 && le_render_held_bytes(e) != want; ++k) {
    le_render_tick(e);
    test_sleep_ms(1);
  }
  return le_render_held_bytes(e);
}

static void test_render_done_releases_bytes(void) {
  printf("test_render_done_releases_bytes\n");
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  uint32_t id = 0;
  int32_t result = LE_OK;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  CHECK(le_render_held_bytes(e) > 2 * 48 * (int64_t)sizeof(float));
  drain(e);
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  CHECK(rr_settled_bytes(e, 2 * 48 * (int64_t)sizeof(float)) ==
        2 * 48 * (int64_t)sizeof(float));
  float out[2 * 48];
  CHECK(le_engine_render_copy(e, id, out, 48) == 48);
  CHECK(out[0] == rr_a(0) + rr_b(0));
  CHECK(le_engine_render_cancel(e, id) == LE_OK);
  char path[512];
  snprintf(path, sizeof(path), "%s/rr_release_%d.wav", rr_tmp(),
           (int)test_getpid());
  q.target = LE_RENDER_TARGET_FILE;
  q.path = path;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  CHECK(rr_settled_bytes(e, 0) == 0);
  CHECK(le_engine_render_cancel(e, id) == LE_OK);
  remove(path);
  le_engine_destroy(e);
}

static void test_render_plugin_mask(void) {
  printf("test_render_plugin_mask\n");
  le_engine* e = rr_fixture();
  e->tracks[1].lanes[0].a_fx_count = 1; /* a hosted plugin entry */
  e->tracks[1].lanes[0].a_fx_type[0] = LE_FX_PLUGIN;
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  le_render_plan plan;
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.plugin_mask == 0x2u);
  float out[2 * 48];
  CHECK(rr_render(e, &q, out, 48) == 48); /* renders dry */
  for (int f = 0; f < 48; ++f) CHECK(out[2 * f] == rr_a(f) + rr_b(f));
  e->tracks[1].lanes[0].a_fx_count = 0;
  e->tracks[1].lanes[0].a_fx_type[0] = LE_FX_NONE;
  le_engine_destroy(e);
}

/* A reversed source with a Pre delay renders what the live rig plays: the
 * live chain runs forward over the backward read (a print never engages on a
 * reversed track), so the echo follows each note (review H1). */
static void test_render_reversed_pre_live_parity(void) {
  printf("test_render_reversed_pre_live_parity\n");
  le_engine* e = rr_engine();
  static float pcm[6000];
  memset(pcm, 0, sizeof(pcm));
  pcm[5000] = 1.0f;
  CHECK(le_engine_import_track(e, 0, pcm, 6000) == LE_OK);
  CHECK(le_engine_commit_session(e, 6000, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK); /* Pre */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0,
                                    2400.0f / (float)(RR_SR - 1)) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.25f) == LE_OK);
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  uint64_t rq;
  CHECK(le_engine_toggle_reverse(e, 0, &rq) == LE_OK);
  rr_pump(e, NULL, 6000 * 4 + 1234, 64); /* past the turn, to steady state */
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  static float live[2 * 6000];
  rr_pump(e, live, 6000, 64); /* the first block applies the freeze */
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  static float out[2 * 6000];
  CHECK(le_engine_render_copy(e, id, out, 6000) == 6000);
  const int top = (6000 * 4 + 1234) % 6000;
  for (int m = 0; m < 6000; ++m) {
    CHECK(fabsf(live[2 * m] - out[2 * ((top + m) % 6000)]) < 1e-6f);
  }
  /* The echo comes after its impulse in the read order: with the read
   * running backward from the impulse at index 5000, the echo lands 2,400
   * read frames later. */
  int impulse = -1;
  for (int f = 0; f < 6000; ++f) {
    if (out[2 * f] > 0.5f) impulse = f; /* dry 0.75; the echo is 0.25 */
  }
  CHECK(impulse >= 0);
  float after = 0.0f;
  for (int k = 2350; k < 2450; ++k) after += fabsf(out[2 * ((impulse + k) % 6000)]);
  CHECK(after > 0.1f);
  le_engine_destroy(e);
}

/* Once on a chosen length (review M3): one pass from its start, then
 * silence, whatever the window. A pass crossing the window end continues at
 * the window start from its own phase; a window shorter than the span holds
 * one pass cut at the window end. */
static void rr_once_fixture(le_engine** pe, int32_t base, int32_t span,
                            float* a) {
  le_engine* e = rr_engine();
  float* zeros = (float*)calloc((size_t)base, sizeof(float));
  for (int32_t i = 0; i < span; ++i) a[i] = (float)(i + 1);
  CHECK(le_engine_import_track(e, 0, zeros, base) == LE_OK);
  CHECK(le_engine_import_track(e, 1, a, span) == LE_OK);
  CHECK(le_engine_commit_session(e, base, 0) == LE_OK);
  CHECK(le_engine_set_one_shot_mask(e, 1u << 1, 1) == LE_OK);
  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK); /* 1 bar = 38,400 frames */
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  rr_pump(e, NULL, base + 7, 512); /* into iteration 1: track 1 at segment 1 */
  free(zeros);
  *pe = e;
}

static void test_render_once_chosen_length(void) {
  printf("test_render_once_chosen_length\n");
  static float a[60000];
  static float out[2 * 38400];
  /* Span 30,000 (k = 2 over 15,000) at segment 1: its pass starts 15,000
   * frames into the 38,400-frame window and wraps 6,600 frames. */
  le_engine* e;
  rr_once_fixture(&e, 15000, 30000, a);
  le_render_request q = rr_request(0x2, LE_RENDER_CUT);
  q.length_bars = 1;
  le_render_plan plan;
  memset(&plan, 0, sizeof(plan));
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.once_cut_mask == 0); /* the whole pass fits */
  CHECK(rr_render(e, &q, out, 38400) == 38400);
  for (int f = 0; f < 38400; ++f) {
    const float want = f >= 15000 ? a[f - 15000]
                       : f < 6600 ? a[f + 23400]
                                  : 0.0f;
    CHECK(out[2 * f] == want);
  }
  le_engine_destroy(e);
  /* Span 60,000 (k = 2 over 30,000) at segment 1: the pass starts 30,000
   * frames in and the window ends 8,400 frames later. */
  rr_once_fixture(&e, 30000, 60000, a);
  /* The readout names it: its pass is longer than the window (L-D1). */
  memset(&plan, 0, sizeof(plan));
  CHECK(le_engine_render_measure(e, &q, &plan) == LE_OK);
  CHECK(plan.once_cut_mask == 0x2);
  CHECK(rr_render(e, &q, out, 38400) == 38400);
  for (int f = 0; f < 38400; ++f) {
    CHECK(out[2 * f] == (f >= 30000 ? a[f - 30000] : 0.0f));
  }
  le_engine_destroy(e);
}

/* The whole-track print path: every part wholly Pre and a track Pre delay,
 * so the track's take is its print over the parts at their levels and pans
 * (review M4). The oracle prints the same material with the cache's own
 * function; Cut keeps the wrapped echo because it is the take. */
static void test_render_whole_track_print(void) {
  printf("test_render_whole_track_print\n");
  le_engine* e = rr_engine();
  static float pcm[6000];
  memset(pcm, 0, sizeof(pcm));
  pcm[5000] = 1.0f;
  CHECK(le_engine_import_track(e, 0, pcm, 6000) == LE_OK);
  CHECK(le_engine_commit_session(e, 6000, 0) == LE_OK);
  CHECK(le_engine_set_lane_pan(e, 0, 0, 0.5f) == LE_OK);
  CHECK(le_engine_set_track_fx_count(e, 0, 1, 1) == LE_OK); /* track Pre */
  CHECK(le_engine_set_track_fx(e, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_track_fx_param(e, 0, 0, 0,
                                     2400.0f / (float)(RR_SR - 1)) == LE_OK);
  drain(e);
  static float out[2 * 6000];
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  CHECK(rr_render(e, &q, out, 6000) == 6000);
  float gl, gr;
  le_pan_gains(0.5f, &gl, &gr);
  static float src[2 * 6000], print[2 * 6000];
  for (int f = 0; f < 6000; ++f) {
    src[2 * f] = pcm[f] * gl;
    src[2 * f + 1] = pcm[f] * gr;
  }
  le_fx_frozen_chain chain;
  LE_FX_FROZEN_CAPTURE(&chain, &e->tracks[0].bus);
  CHECK(le_fx_print(&chain, chain.pre, src, 1, 1.0f, 6000, RR_SR,
                    e->fx_delay_frames, print, NULL, NULL) == LE_OK);
  CHECK(memcmp(out, print, sizeof(print)) == 0);
  le_engine_destroy(e);
}

/* A live track chain (Post) with track gain 0.5 inside it: the live pair
 * from the loop top equals the Cut render sample for sample (review M4). */
static void test_render_track_post_gain_live_parity(void) {
  printf("test_render_track_post_gain_live_parity\n");
  le_engine* e = rr_engine();
  static float pcm[4000];
  for (int i = 0; i < 4000; ++i) pcm[i] = (float)((i * 5) % 11) / 11.0f - 0.4f;
  CHECK(le_engine_import_track(e, 0, pcm, 4000) == LE_OK);
  CHECK(le_engine_commit_session(e, 4000, 0) == LE_OK);
  CHECK(le_engine_set_track_fx_count(e, 0, 1, 0) == LE_OK); /* track Post */
  CHECK(le_engine_set_track_fx(e, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_track_fx_param(e, 0, 0, 0,
                                     300.0f / (float)(RR_SR - 1)) == LE_OK);
  le_mix_settings gain;
  memset(&gain, 0, sizeof(gain));
  gain.revision = 1;
  gain.track_gain_mask = 1u;
  gain.track_gain[0] = 0.5f;
  CHECK(le_engine_set_mix(e, &gain) == LE_OK);
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK);
  static float live[2 * 3000];
  rr_pump(e, live, 3000, 64);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  static float out[2 * 4000];
  CHECK(rr_render(e, &q, out, 4000) == 4000);
  for (int f = 0; f < 3000; ++f) {
    CHECK(live[2 * f] == out[2 * f]);
    CHECK(live[2 * f + 1] == out[2 * f + 1]);
  }
  le_engine_destroy(e);
}

/* The freeze and the staging both refuse material that moved: a length that
 * changed before the freeze landed, and a source whose revision moved after
 * its last chunk was copied (review M4). */
static void test_render_freeze_and_completion_checks(void) {
  printf("test_render_freeze_and_completion_checks\n");
  const uint64_t budget = le_render_stage_budget_ns;
  le_render_stage_budget_ns = 0; /* one chunk per heartbeat */
  le_engine* e = rr_fixture();
  le_render_request q = rr_request(0x3, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  /* An edit that lands before the freeze changes the span (a length edit,
   * #1168): stood in for by publishing another length. */
  store_i32(&e->tracks[0].lanes[0].a_len, 8);
  drain(e);
  int32_t result = LE_OK;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_FAILED);
  CHECK(result == LE_ERR_TRACKS_CHANGED);
  store_i32(&e->tracks[0].lanes[0].a_len, 16);
  CHECK(le_engine_render_cancel(e, id) == LE_OK);
  /* Staging: track 0 is copied by the first heartbeat, track 1 by the
   * second; a revision bump on track 0 after that is caught at completion. */
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t state = LE_RENDER_NONE;
  CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  CHECK(state == LE_RENDER_STAGING);
  atomic_fetch_add(&e->tracks[0].a_audio_rev, 1u);
  CHECK(rr_wait(e, id, &result) == LE_RENDER_FAILED);
  CHECK(result == LE_ERR_TRACKS_CHANGED);
  le_render_stage_budget_ns = budget;
  le_engine_destroy(e);
}

/* Starting a render never unpublishes a print a playing lane plays (review
 * M1): the recipe has its own budget, even with the cache at its cap. */
static void test_render_keeps_published_prints(void) {
  printf("test_render_keeps_published_prints\n");
  le_engine* e = cache_engine(LE_CACHE_DEFAULT_CAP_BYTES);
  cache_record_loop(e, CACHE_LOOP, 1.0f);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK); /* Pre */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  drain(e);
  le_lane_cache_info info;
  le_engine_get_lane_cache(e, 0, 0, &info); /* registers the key */
  pump_frames(e, 0.0f, CACHE_SETTLE);
  CHECK(cache_wait_state(e, 0, 0, LE_CACHE_CACHED, 3000));
  pump_frames(e, 0.0f, CACHE_LOOP); /* engages at the next loop top */
  CHECK(cache_engaged(e, 0, 0) == 1);
  /* The cache holds exactly what it uses: no room left. */
  CHECK(le_engine_set_fx_cache_cap(e, le_engine_fx_cache_used_bytes(e)) ==
        LE_OK);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  CHECK(atomic_load(&e->tracks[0].lanes[0].a_wet) != NULL);
  pump_frames(e, 0.0f, 64);
  int32_t result;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  CHECK(atomic_load(&e->tracks[0].lanes[0].a_wet) != NULL);
  CHECK(cache_engaged(e, 0, 0) == 1);
  le_engine_destroy(e);
}

/* A configure during a recipe's lane print returns without waiting for the
 * print (review M2): the print's abort check reads the cache's shutdown flag.
 * The undisturbed render's time is dominated by one 30 s Pre reverb print,
 * so a configure that waited for it would take most of that time. */
static void test_render_configure_mid_print(void) {
  printf("test_render_configure_mid_print\n");
  le_engine* e = rr_engine();
  const int32_t len = 30 * RR_SR;
  float* pcm = (float*)calloc((size_t)len, sizeof(float));
  CHECK(pcm != NULL);
  if (pcm == NULL) return;
  for (int32_t i = 0; i < len; i += RR_SR / 4) pcm[i] = 0.5f;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  free(pcm);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 1) == LE_OK); /* Pre */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
  drain(e);
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  uint32_t id = 0;
  int32_t state = LE_RENDER_NONE;
  int32_t result = LE_OK;
  /* The whole render, undisturbed. */
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  for (int k = 0; k < 20000 && state < LE_RENDER_RENDERING; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  }
  const uint64_t t0 = le_now_ns();
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  const uint64_t whole = le_now_ns() - t0;
  CHECK(le_engine_render_cancel(e, id) == LE_OK);
  /* The same render, interrupted a quarter of the way through its print. */
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  state = LE_RENDER_NONE;
  for (int k = 0; k < 20000 && state < LE_RENDER_RENDERING; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, NULL, NULL) == LE_OK);
  }
  test_sleep_ms((int)(whole / 4000000u));
  const uint64_t t1 = le_now_ns();
  CHECK(le_engine_configure(e, RR_SR, 1, 2, 0) == LE_OK);
  const uint64_t configure = le_now_ns() - t1;
  CHECK(configure * 2 < whole);
  CHECK(le_engine_render_poll(e, id, &state, NULL, &result) == LE_OK);
  CHECK(state == LE_RENDER_FAILED && result == LE_ERR_DEVICE);
  le_engine_destroy(e);
}

/* The writer's flush and size patch, as the capture drain and its recovery
 * use them (review L4): a flushed but unsealed file with a torn last frame
 * is repaired to its whole frames, then cut back to a trusted length. */
static void test_wav_flush_and_patch_sizes(void) {
  printf("test_wav_flush_and_patch_sizes\n");
  char path[512];
  snprintf(path, sizeof(path), "%s/rr_patch_%d.wav", rr_tmp(),
           (int)test_getpid());
  const unsigned char chunk[4] = {1, 2, 3, 4};
  le_wav_writer w;
  CHECK(le_wav_open(&w, path, 48000, 2, "sgno", chunk, 3) == 0); /* odd */
  le_wav_abandon(&w);
  CHECK(le_wav_open(&w, path, 48000, 2, "sgno", chunk, 4) == 1);
  const uint32_t header = 44 + 12; /* fmt, data and the 12-byte sgno chunk */
  CHECK(w.header_bytes == header);
  float pcm[20];
  for (int i = 0; i < 20; ++i) pcm[i] = (float)(i + 1);
  CHECK(le_wav_append(&w, pcm, 10) == 1);
  CHECK(le_wav_flush(&w) == 1);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f == NULL) return;
  fseek(f, 0, SEEK_END);
  CHECK(ftell(f) == (long)(header + 80)); /* every sample reached the OS */
  fclose(f);
  le_wav_abandon(&w); /* a crash: the sizes were never patched */
  f = fopen(path, "ab");
  CHECK(f != NULL);
  if (f == NULL) return;
  fwrite(pcm, 1, 3, f); /* a torn last frame */
  fclose(f);
  uint64_t kept = 0;
  CHECK(le_wav_patch_sizes(path, UINT64_MAX, &kept) == 1 && kept == 10);
  unsigned char bytes[56 + 80 + 8];
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f == NULL) return;
  size_t n = fread(bytes, 1, sizeof(bytes), f);
  fclose(f);
  CHECK(n == header + 80);
  CHECK(bytes[4] == (unsigned char)(header + 80 - 8) && bytes[5] == 0);
  CHECK(bytes[header - 4] == 80 && bytes[header - 3] == 0);
  CHECK(memcmp(bytes + header, pcm, 80) == 0);
  /* Cut back to a checkpoint of four frames. */
  CHECK(le_wav_patch_sizes(path, 4, &kept) == 1 && kept == 4);
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f == NULL) return;
  n = fread(bytes, 1, sizeof(bytes), f);
  fclose(f);
  CHECK(n == header + 32);
  CHECK(bytes[4] == (unsigned char)(header + 32 - 8));
  CHECK(bytes[header - 4] == 32);
  CHECK(memcmp(bytes + header, pcm, 32) == 0);
  /* Not this layout: refused, untouched. */
  f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  fwrite("not a wav file at all", 1, 21, f);
  fclose(f);
  CHECK(le_wav_patch_sizes(path, UINT64_MAX, &kept) == 0 && kept == 0);
  remove(path);
}

/* Seal cuts a torn frame the caller's own write path left past the credited
 * frames (#1198 Part 2's drain rewinds over a short write and credits only
 * whole frames): a sealed file is exactly its header and its data. */
static void test_wav_seal_cuts_torn_frame(void) {
  printf("test_wav_seal_cuts_torn_frame\n");
  char path[512];
  snprintf(path, sizeof(path), "%s/rr_seal_%d.wav", rr_tmp(),
           (int)test_getpid());
  le_wav_writer w;
  CHECK(le_wav_open(&w, path, 48000, 2, NULL, NULL, 0) == 1);
  const float pcm[6] = {1, 2, 3, 4, 5, 6};
  CHECK(fwrite(pcm, 1, 2 * 8 + 3, w.file) == 2 * 8 + 3); /* 2 frames + torn */
  le_wav_note_frames(&w, 2);
  CHECK(le_wav_seal(&w, 1) == 1);
  unsigned char bytes[44 + 16 + 8];
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f == NULL) return;
  const size_t n = fread(bytes, 1, sizeof(bytes), f);
  fclose(f);
  CHECK(n == 44 + 16);
  CHECK(bytes[4] == 44 + 16 - 8 && bytes[40] == 16);
  CHECK(memcmp(bytes + 44, pcm, 16) == 0);
  remove(path);
}

/* Progress moves while sources are staged (review M1 of Part 2): staging is
 * on the same permille scale as the render, so a job with a lot of material
 * never reads 0% for seconds. One chunk per heartbeat here (a zero time
 * budget), so the steps are observable. */
static void test_render_staging_progress(void) {
  printf("test_render_staging_progress\n");
  le_engine* e = rr_engine();
  const int32_t len = 10 * LE_RENDER_COPY_CHUNK_FRAMES;
  float* pcm = (float*)calloc((size_t)len, sizeof(float));
  CHECK(pcm != NULL);
  if (pcm == NULL) return;
  CHECK(le_engine_import_track(e, 0, pcm, len) == LE_OK);
  free(pcm);
  CHECK(le_engine_commit_session(e, len, 0) == LE_OK);
  drain(e);
  const uint64_t budget = le_render_stage_budget_ns;
  le_render_stage_budget_ns = 0;
  le_render_request q = rr_request(0x1, LE_RENDER_CUT);
  uint32_t id = 0;
  CHECK(le_engine_render_begin(e, &q, &id) == LE_OK);
  drain(e);
  int32_t state = LE_RENDER_NONE, permille = -1, last = 0, steps = 0;
  for (int k = 0; k < 100; ++k) {
    CHECK(le_engine_render_poll(e, id, &state, &permille, NULL) == LE_OK);
    if (state != LE_RENDER_STAGING) break;
    CHECK(permille >= last); /* never backwards */
    if (permille > last) ++steps;
    last = permille;
  }
  CHECK(steps >= 8 && last > 0 && last < 1000); /* nine of ten chunks */
  le_render_stage_budget_ns = budget;
  int32_t result = LE_OK;
  CHECK(rr_wait(e, id, &result) == LE_RENDER_DONE);
  le_engine_destroy(e);
}

static void test_render_worker_choice(void) {
  printf("test_render_worker_choice\n");
  int yields = 0;
  CHECK(le_render_worker_choice(1, 0, &yields) == 0); /* no recipe */
  CHECK(le_render_worker_choice(0, 1, &yields) == 1); /* before stopped prints */
  for (int k = 0; k < LE_RENDER_MAX_YIELDS; ++k) {
    CHECK(le_render_worker_choice(1, 1, &yields) == 0); /* audible first */
  }
  CHECK(le_render_worker_choice(1, 1, &yields) == 1); /* aged: recipe next */
  CHECK(yields == 0);
  CHECK(le_render_worker_choice(1, 1, &yields) == 0);
}

static void run_render_tests(void) {
  test_render_common_cycle_literal();
  test_render_ignores_transport_mute_solo();
  test_render_levels_pans_gain();
  test_render_live_phase_and_reverse_offset();
  test_render_once_then_silence();
  test_render_once_reversed();
  test_render_fade_frozen_amount();
  test_render_origin_phase_multiples();
  test_render_chosen_length_and_tempo();
  test_render_no_common_cycle();
  test_render_pre_is_take_and_tails();
  test_render_mix_fx_optional();
  test_render_excludes_buses();
  test_render_live_parity_post_chain();
  test_render_refusals();
  test_render_staging_tracks_changed();
  test_render_cancel_and_shutdown();
  test_render_file_target_wav();
  test_render_plugin_mask();
  test_render_worker_choice();
  test_render_reversed_pre_live_parity();
  test_render_once_chosen_length();
  test_render_whole_track_print();
  test_render_track_post_gain_live_parity();
  test_render_freeze_and_completion_checks();
  test_render_keeps_published_prints();
  test_render_configure_mid_print();
  test_render_done_releases_bytes();
  test_wav_flush_and_patch_sizes();
  test_wav_seal_cuts_torn_frame();
  test_render_staging_progress();
}
