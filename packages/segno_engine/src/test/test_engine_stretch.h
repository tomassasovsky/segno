/* le_stretch oracles (#1179 Part 1): the C shim over the vendored Signalsmith
 * Stretch renders exact lengths, the requested pitch, deterministically. */

/* Goertzel power of `x[from, to)` at `hz`. */
static double stretch_power_at(const float* x, int32_t from, int32_t to,
                               double hz, int32_t sr) {
  const double w = 2.0 * M_PI * hz / (double)sr;
  const double coeff = 2.0 * cos(w);
  double s0 = 0, s1 = 0, s2 = 0;
  for (int32_t i = from; i < to; ++i) {
    s0 = (double)x[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

static float* stretch_sine(int32_t frames, double hz, int32_t sr) {
  float* x = (float*)malloc(sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < frames; ++i) {
    x[i] = 0.5f * (float)sin(2.0 * M_PI * hz * (double)i / (double)sr);
  }
  return x;
}

static int stretch_all_finite(const float* x, int32_t n) {
  for (int32_t i = 0; i < n; ++i) if (!isfinite(x[i])) return 0;
  return 1;
}

static void test_stretch_lifecycle_and_latency(void) {
  printf("test_stretch_lifecycle_and_latency\n");
  CHECK(le_stretch_create(0, 48000, 1, 1) == NULL);
  CHECK(le_stretch_create(1, 0, 1, 1) == NULL);
  /* absurd sizes are refused, not thrown across the C boundary (an uncaught
   * std::length_error out of the library's vectors aborted the process) */
  CHECK(le_stretch_create(INT32_MAX, 48000, 1, 1) == NULL);
  CHECK(le_stretch_create(LE_STRETCH_MAX_CHANNELS + 1, 48000, 1, 1) == NULL);
  CHECK(le_stretch_create(1, INT32_MAX, 1, 1) == NULL);
  {
    le_stretch* widest = le_stretch_create(LE_STRETCH_MAX_CHANNELS, 48000, 1, 1);
    CHECK(widest != NULL);
    le_stretch_destroy(widest);
  }
  le_stretch* cheap = le_stretch_create(1, 48000, 1, 7);
  le_stretch* full = le_stretch_create(2, 48000, 0, 7);
  CHECK(cheap != NULL && full != NULL);
  CHECK(le_stretch_channels(cheap) == 1 && le_stretch_channels(full) == 2);
  /* the two presets of the library (block 0.1 s / 0.04 s and 0.12 s / 0.03 s) */
  CHECK(le_stretch_block_samples(cheap) == 4800);
  CHECK(le_stretch_interval_samples(cheap) == 1920);
  CHECK(le_stretch_block_samples(full) == 5760);
  CHECK(le_stretch_interval_samples(full) == 1440);
  CHECK(le_stretch_input_latency(cheap) + le_stretch_output_latency(cheap) ==
        le_stretch_block_samples(cheap));
  /* streaming at 64 frames per call produces 64 frames per call */
  float in_buf[64], out_buf[64];
  const float* in1[1] = {in_buf};
  float* out1[1] = {out_buf};
  for (int i = 0; i < 64; ++i) in_buf[i] = 0.25f;
  le_stretch_set_semitones(cheap, 3.0f, 8000.0f / 48000.0f);
  for (int k = 0; k < 200; ++k) {
    le_stretch_process(cheap, in1, 64, out1, 64);
    CHECK(stretch_all_finite(out_buf, 64));
  }
  le_stretch_seek(cheap, in1, 64, 1.0);
  le_stretch_flush(cheap, out1, 64);
  le_stretch_reset(cheap);
  /* NULL-tolerant */
  le_stretch_destroy(NULL);
  le_stretch_reset(NULL);
  CHECK(le_stretch_channels(NULL) == 0);
  le_stretch_destroy(cheap);
  le_stretch_destroy(full);
}

static void test_stretch_offline_exact_length_and_pitch(void) {
  printf("test_stretch_offline_exact_length_and_pitch\n");
  const int32_t sr = 48000;
  const int32_t in_frames = 2 * sr; /* a two-second lap at 220 Hz */
  float* sine = stretch_sine(in_frames, 220.0, sr);
  const float* in[1] = {sine};
  /* +12 st at ratio 1: exact length, pitch doubled, level kept */
  float* up = (float*)calloc((size_t)in_frames, sizeof(float));
  float* out1[1] = {up};
  CHECK(le_stretch_render_offline(in, in_frames, 1, sr, 1.0, 12.0f, 0.0f, 1,
                                  42u, 1, out1, in_frames) == LE_STRETCH_OK);
  CHECK(stretch_all_finite(up, in_frames));
  {
    const int32_t a = sr / 4, b = in_frames - sr / 4; /* skip the edges */
    const double p440 = stretch_power_at(up, a, b, 440.0, sr);
    const double p220 = stretch_power_at(up, a, b, 220.0, sr);
    CHECK(p440 > 10.0 * p220);
    double sumsq = 0;
    for (int32_t i = a; i < b; ++i) sumsq += (double)up[i] * up[i];
    const double rms = sqrt(sumsq / (double)(b - a));
    CHECK(rms > 0.2 && rms < 0.5); /* a 0.5 amplitude sine is 0.354 rms */
  }
  /* -12 st: pitch halved */
  float* down = (float*)calloc((size_t)in_frames, sizeof(float));
  float* out2[1] = {down};
  CHECK(le_stretch_render_offline(in, in_frames, 1, sr, 1.0, -12.0f, 0.0f, 1,
                                  42u, 1, out2, in_frames) == LE_STRETCH_OK);
  {
    const int32_t a = sr / 4, b = in_frames - sr / 4;
    CHECK(stretch_power_at(down, a, b, 110.0, sr) >
          10.0 * stretch_power_at(down, a, b, 220.0, sr));
  }
  /* time stretch at 0.75 and 4/3 keeps the pitch and fills the exact length */
  const double ratios[] = {0.75, 4.0 / 3.0};
  for (int r = 0; r < 2; ++r) {
    const int32_t out_frames = (int32_t)llround((double)in_frames * ratios[r]);
    float* y = (float*)calloc((size_t)out_frames, sizeof(float));
    float* outs[1] = {y};
    CHECK(le_stretch_render_offline(in, in_frames, 1, sr, ratios[r], 0.0f, 0.0f,
                                    1, 42u, 1, outs, out_frames) == LE_STRETCH_OK);
    CHECK(stretch_all_finite(y, out_frames));
    const int32_t a = sr / 4, b = out_frames - sr / 4;
    CHECK(stretch_power_at(y, a, b, 220.0, sr) >
          10.0 * stretch_power_at(y, a, b, 220.0 * ratios[r], sr));
    CHECK(stretch_power_at(y, a, b, 220.0, sr) >
          10.0 * stretch_power_at(y, a, b, 220.0 / ratios[r], sr));
    /* the last frames carry signal: the render filled the requested length */
    double tail = 0;
    for (int32_t i = out_frames - 2048; i < out_frames; ++i) tail += fabs((double)y[i]);
    CHECK(tail / 2048.0 > 0.05);
    free(y);
  }
  /* default preset too, stereo, non-cyclic */
  const float* in2[2] = {sine, sine};
  float* l = (float*)calloc((size_t)in_frames, sizeof(float));
  float* rr = (float*)calloc((size_t)in_frames, sizeof(float));
  float* out3[2] = {l, rr};
  CHECK(le_stretch_render_offline(in2, in_frames, 2, sr, 1.0, 7.0f,
                                  8000.0f / 48000.0f, 0, 42u, 0, out3,
                                  in_frames) == LE_STRETCH_OK);
  CHECK(stretch_all_finite(l, in_frames) && stretch_all_finite(rr, in_frames));
  {
    /* the two channels carry the same material at the same level (their
     * band phases are randomized independently, so not sample-identical) */
    double sl = 0, sr2 = 0;
    for (int32_t i = sr / 4; i < in_frames - sr / 4; ++i) {
      sl += (double)l[i] * l[i];
      sr2 += (double)rr[i] * rr[i];
    }
    CHECK(sl > 0 && fabs(sl - sr2) / sl < 0.1);
    const int32_t a = sr / 4, b = in_frames - sr / 4;
    CHECK(stretch_power_at(rr, a, b, 220.0 * pow(2.0, 7.0 / 12.0), sr) >
          10.0 * stretch_power_at(rr, a, b, 220.0, sr));
  }
  free(l);
  free(rr);
  free(down);
  free(up);
  free(sine);
}

static void test_stretch_offline_deterministic_and_guards(void) {
  printf("test_stretch_offline_deterministic_and_guards\n");
  const int32_t sr = 48000;
  const int32_t n = sr; /* one second */
  float* src = stretch_sine(n, 330.0, sr);
  /* a little noise so the spectrum is not a single line */
  uint32_t state = 1234567u;
  for (int32_t i = 0; i < n; ++i) {
    state = state * 1664525u + 1013904223u;
    src[i] += 0.05f * ((float)(state >> 8) / 16777216.0f - 0.5f);
  }
  const float* in[1] = {src};
  float* a = (float*)calloc((size_t)n, sizeof(float));
  float* b = (float*)calloc((size_t)n, sizeof(float));
  float* c = (float*)calloc((size_t)n, sizeof(float));
  float* oa[1] = {a};
  float* ob[1] = {b};
  float* oc[1] = {c};
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 5.0f, 0.0f, 1, 99u, 1, oa, n) == LE_STRETCH_OK);
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 5.0f, 0.0f, 1, 99u, 1, ob, n) == LE_STRETCH_OK);
  CHECK(memcmp(a, b, sizeof(float) * (size_t)n) == 0); /* same seed: byte-identical */
  /* another recipe is another render (the seed only enters above the
   * library's clean-stretch limit, so a different seed alone need not) */
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 6.0f, 0.0f, 1, 99u, 1, oc, n) == LE_STRETCH_OK);
  CHECK(memcmp(a, c, sizeof(float) * (size_t)n) != 0);
  /* argument guards */
  CHECK(le_stretch_render_offline(NULL, n, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, 0, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 1, sr, 0.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 1, sr, -1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  /* ratios outside [1/16, 16] are refused before any frame count is derived */
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1e-12, 0.0f, 0.0f, 1, 1u, 1, oa, 1) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1e12, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 1, sr, LE_STRETCH_MAX_RATIO * 1.01, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  /* both ends of the range render the exact length (the chunking keeps each
   * process() call's output near 512 frames even at 16x) */
  {
    const double ends[] = {1.0 / LE_STRETCH_MAX_RATIO, LE_STRETCH_MAX_RATIO};
    for (int e = 0; e < 2; ++e) {
      const int32_t m = (int32_t)llround((double)n * ends[e]);
      float* y = (float*)calloc((size_t)m, sizeof(float));
      float* oy[1] = {y};
      CHECK(le_stretch_render_offline(in, n, 1, sr, ends[e], 0.0f, 0.0f, 1, 1u,
                                      1, oy, m) == LE_STRETCH_OK);
      CHECK(stretch_all_finite(y, m));
      free(y);
    }
  }
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, 0) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 0, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, INT32_MAX, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 1, INT32_MAX, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  /* an output far longer than the ratio allows is refused, not truncated */
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, 3 * n) == LE_STRETCH_ERR_INVALID);
  free(a);
  free(b);
  free(c);
  free(src);
}

/* Index of the largest |x[i]| over the circular window [centre - half,
 * centre + half] of a buffer of n frames (wrapping, so a click near a lap's
 * edge is found on whichever side of the seam it landed). */
static int64_t stretch_peak_near(const float* x, int64_t n, int64_t centre,
                                 int64_t half) {
  int64_t best = -1;
  float best_v = -1.0f;
  for (int64_t k = centre - half; k <= centre + half; ++k) {
    int64_t i = k % n;
    if (i < 0) i += n;
    if (fabsf(x[i]) > best_v) {
      best_v = fabsf(x[i]);
      best = i;
    }
  }
  return best;
}

/* Circular distance between two frame indices of an n-frame loop. */
static int64_t stretch_circ_dist(int64_t a, int64_t b, int64_t n) {
  int64_t d = (a - b) % n;
  if (d < 0) d += n;
  return d < n - d ? d : n - d;
}

/* A quiet 220 Hz bed (so the stretcher never takes its silence shortcut)
 * with unit clicks at `clicks`. */
static float* stretch_clicks(int32_t frames, int32_t sr, const int32_t* clicks,
                             int n_clicks) {
  float* x = (float*)malloc(sizeof(float) * (size_t)frames);
  for (int32_t i = 0; i < frames; ++i) {
    x[i] = 0.02f * (float)sin(2.0 * M_PI * 220.0 * (double)i / (double)sr);
  }
  for (int k = 0; k < n_clicks; ++k) x[clicks[k]] = 1.0f;
  return x;
}

/* Alignment: a click at input frame c comes out within 2 ms of c * ratio, at
 * every ratio a lap is rendered at and in both modes, over the plan's 30 s
 * input. This is the latency compensation (`discard`) that lets a rendered
 * lap tile the clock: without it every click lands a stretcher block late
 * (100 ms at 48 kHz). The search window (250 ms) is wider than that shift,
 * so a wrong compensation is measured, not missed. */
static void test_stretch_offline_click_alignment(void) {
  printf("test_stretch_offline_click_alignment\n");
  const int32_t sr = 48000;
  const int32_t in_frames = 30 * sr;
  const int32_t clicks[] = {sr + 123, 15 * sr + 7, 29 * sr - 311};
  float* src = stretch_clicks(in_frames, sr, clicks, 3);
  const float* in[1] = {src};
  const double ratios[] = {1.0, 0.75, 4.0 / 3.0};
  const int64_t tol = 2 * sr / 1000; /* 2 ms */
  for (int r = 0; r < 3; ++r) {
    const int32_t out_frames = (int32_t)llround((double)in_frames * ratios[r]);
    float* y = (float*)calloc((size_t)out_frames, sizeof(float));
    float* outs[1] = {y};
    for (int cyclic = 0; cyclic < 2; ++cyclic) {
      memset(y, 0, sizeof(float) * (size_t)out_frames);
      CHECK(le_stretch_render_offline(in, in_frames, 1, sr, ratios[r], 0.0f,
                                      0.0f, 1, 42u, cyclic, outs,
                                      out_frames) == LE_STRETCH_OK);
      for (int k = 0; k < 3; ++k) {
        const int64_t want = llround((double)clicks[k] * ratios[r]);
        const int64_t got = stretch_peak_near(y, out_frames, want, sr / 4);
        if (stretch_circ_dist(got, want, out_frames) > tol) {
          printf("  click %d at ratio %.4f cyclic %d: want %lld got %lld\n", k,
                 ratios[r], cyclic, (long long)want, (long long)got);
        }
        CHECK(stretch_circ_dist(got, want, out_frames) <= tol);
      }
    }
    free(y);
  }
  free(src);
}

/* The cyclic seam: a cyclic render loops. (1) Continuity: a lap of a sine
 * with a whole number of cycles at every ratio (660 cycles in 3 s at 220 Hz;
 * 495 at 0.75, 880 at 4/3) renders a loop whose wrap step out[n-1] -> out[0]
 * is no larger than the render's own largest step between neighbours (with
 * 25 % headroom), so the loop point is inaudible. (2) The material on each side of the loop point is
 * the lap's own: a click 20 ms before the lap's end and one 20 ms after its
 * start come out 20 ms * ratio either side of the seam, not shifted across
 * it by the stretcher's latency. */
static void test_stretch_offline_cyclic_seam(void) {
  printf("test_stretch_offline_cyclic_seam\n");
  const int32_t sr = 48000;
  const int32_t in_frames = 3 * sr;
  float* sine = stretch_sine(in_frames, 220.0, sr);
  const int32_t edge = sr / 50; /* 20 ms */
  const int32_t clicks[] = {in_frames - edge, edge};
  float* marks[2] = {stretch_clicks(in_frames, sr, &clicks[0], 1),
                     stretch_clicks(in_frames, sr, &clicks[1], 1)};
  const double ratios[] = {1.0, 0.75, 4.0 / 3.0};
  const int64_t tol = 2 * sr / 1000; /* 2 ms */
  for (int r = 0; r < 3; ++r) {
    const int32_t n = (int32_t)llround((double)in_frames * ratios[r]);
    float* y = (float*)calloc((size_t)n, sizeof(float));
    float* outs[1] = {y};
    const float* in_sine[1] = {sine};
    CHECK(le_stretch_render_offline(in_sine, in_frames, 1, sr, ratios[r], 0.0f,
                                    0.0f, 1, 42u, 1, outs, n) == LE_STRETCH_OK);
    float max_step = 0.0f;
    for (int32_t i = 0; i + 1 < n; ++i) {
      const float d = fabsf(y[i + 1] - y[i]);
      if (d > max_step) max_step = d;
    }
    /* 25 % of headroom over the largest neighbour step: at ratio 1 the wrap
     * step IS an ordinary sine step (equal to the largest to 1e-6), while a
     * discontinuity at the seam is tens of times larger */
    const float seam = fabsf(y[0] - y[n - 1]);
    if (!(max_step > 0.0f && seam <= 1.25f * max_step)) {
      printf("  seam at ratio %.4f: step %g, largest interior step %g\n",
             ratios[r], (double)seam, (double)max_step);
    }
    CHECK(max_step > 0.0f && seam <= 1.25f * max_step);

    /* one click per render: the two sit 40 ms apart across the seam, closer
     * than the search window */
    for (int k = 0; k < 2; ++k) {
      const float* in_marks[1] = {marks[k]};
      CHECK(le_stretch_render_offline(in_marks, in_frames, 1, sr, ratios[r],
                                      0.0f, 0.0f, 1, 42u, 1, outs,
                                      n) == LE_STRETCH_OK);
      const int64_t want = llround((double)clicks[k] * ratios[r]);
      const int64_t got = stretch_peak_near(y, n, want, sr / 4);
      if (stretch_circ_dist(got, want, n) > tol) {
        printf("  seam click %d at ratio %.4f: want %lld got %lld\n", k,
               ratios[r], (long long)want, (long long)got);
      }
      CHECK(stretch_circ_dist(got, want, n) <= tol);
    }
    free(y);
  }
  free(marks[0]);
  free(marks[1]);
  free(sine);
}

static double stretch_rms(const float* x, int a, int b) {
  double sum = 0;
  for (int i = a; i < b; ++i) sum += (double)x[i] * x[i];
  return sqrt(sum / (b - a));
}

/* The loop fold holds the level (#1179 Part 3a review, L1). The fold mixes
 * the head (v) with the run-out past the lap (u), two renders of the same
 * input; over the middle of the 20 ms fold the folded RMS stays within 1.5 dB
 * of the two signals' own blended level, sqrt((Pu + Pv) / 2), for a
 * sustained three-tone chord (the review measured -5.2 dB to +4.6 dB
 * against v alone with the fixed equal-power law) and for noise, across lap
 * lengths and pitches in both directions. u and v come from the same
 * cyclic render the fold is built from. */
static void test_stretch_loop_fold_holds_level(void) {
  printf("test_stretch_loop_fold_holds_level\n");
  const int sr = 48000, fold = sr * 20 / 1000;
  const int lens[] = {24000, 96000, 100003};
  uint32_t seed = 1;
  double worst = 0;
  for (int l = 0; l < 3; ++l) for (int kind = 0; kind < 2; ++kind) {
    for (int st = -12; st <= 12; st += 5) {
      const int n = lens[l];
      float* in = (float*)malloc(sizeof(float) * (size_t)n);
      float* out = (float*)malloc(sizeof(float) * (size_t)n);
      float* plain = (float*)malloc(sizeof(float) * (size_t)(n + fold));
      for (int i = 0; i < n; ++i) {
        if (kind == 0) {
          in[i] = 0.2f * (float)(sin(2 * M_PI * 196 * i / sr) +
                                 sin(2 * M_PI * 247 * i / sr) +
                                 sin(2 * M_PI * 294 * i / sr));
        } else {
          seed = seed * 1103515245u + 12345u;
          in[i] = 0.3f * ((float)((seed >> 8) & 0xffff) / 32768.0f - 1.0f);
        }
      }
      CHECK(le_stretch_render_loop(in, n, sr, (float)st, 8000.0f / sr, 1,
                                   1179u, fold, out) == LE_STRETCH_OK);
      const float* ins[1] = {in};
      float* outs[1] = {plain};
      CHECK(le_stretch_render_offline(ins, n, 1, sr, 1.0, (float)st,
                                      8000.0f / sr, 1, 1179u, 1, outs,
                                      n + fold) == LE_STRETCH_OK);
      const double pv = stretch_rms(plain, fold / 4, 3 * fold / 4);
      const double pu = stretch_rms(plain, n + fold / 4, n + 3 * fold / 4);
      const double db = 20 * log10(stretch_rms(out, fold / 4, 3 * fold / 4) /
                                   sqrt((pu * pu + pv * pv) / 2));
      if (fabs(db) > fabs(worst)) worst = db;
      if (fabs(db) > 1.5) {
        printf("  len %d %s %+d st: %.2f dB\n", n, kind ? "noise" : "chord",
               st, db);
      }
      CHECK(fabs(db) <= 1.5);
      free(in);
      free(out);
      free(plain);
    }
  }
  printf("  worst fold level change %.2f dB\n", worst);
}
