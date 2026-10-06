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
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, 0) == LE_STRETCH_ERR_INVALID);
  CHECK(le_stretch_render_offline(in, n, 0, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, n) == LE_STRETCH_ERR_INVALID);
  /* an output far longer than the ratio allows is refused, not truncated */
  CHECK(le_stretch_render_offline(in, n, 1, sr, 1.0, 0.0f, 0.0f, 1, 1u, 1, oa, 3 * n) == LE_STRETCH_ERR_INVALID);
  free(a);
  free(b);
  free(c);
  free(src);
}
