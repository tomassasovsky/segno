/* The drive kinds (#887 part 7): Overdrive and Distortion. Included by
 * test_engine_core.c after the modulation tests, whose helpers it reuses
 * (dyn_run, dyn_state, dyn_free, dyn_db). */

/* The fundamental of a 1 kHz tone at [dbfs] through [type] at [p], 96 kHz,
 * in dBFS (peak), measured over 250 whole cycles after 150 ms; [sign] gets
 * the sign of its in-phase part against the input's sine. */
static double drive_h1(int32_t type, const float* p, double dbfs, int* sign) {
  const int sr = 96000;
  const int n = sr / 2;
  float* in = (float*)malloc(sizeof(float) * (size_t)n);
  float* out = (float*)malloc(sizeof(float) * (size_t)n);
  const float a = (float)pow(10.0, dbfs / 20.0);
  for (int i = 0; i < n; ++i) in[i] = a * sinf(2.0f * (float)M_PI * 1000.0f * i / sr);
  le_fx_state* fx = dyn_state(type, sr);
  uint32_t clock = 0;
  dyn_run(fx, type, p, sr, in, out, NULL, n, &clock);
  dyn_free(fx);
  const int from = (int)(0.15 * sr);
  const int len = sr / 4;
  double re = 0.0;
  double im = 0.0;
  for (int i = from; i < from + len; ++i) {
    const double ph = 2.0 * M_PI * 1000.0 * i / sr;
    re += out[i] * sin(ph);
    im += out[i] * cos(ph);
  }
  re *= 2.0 / len;
  im *= 2.0 / len;
  if (sign) *sign = re < 0.0 ? -1 : 1;
  free(in);
  free(out);
  return 20.0 * log10(sqrt(re * re + im * im));
}

/* ---- Overdrive ---- */

/* The overdrive reproduces the Guitar Rack's OvDrive captures (#891,
 * session fxlive, Tone 50 %): the 1 kHz fundamental at -48, -24 and
 * 0 dBFS in at Drive 10.7, 50 and 90 %, within 1 dB, and the inverted
 * polarity. */
static void test_overdrive_matches_the_capture(void) {
  printf("test_overdrive_matches_the_capture\n");
  const float drives[3] = {0.107f, 0.5f, 0.9f};
  /* Captured fundamentals, dBFS, at -48, -24 and 0 dBFS in. */
  const double want[3][3] = {{-34.53, -22.46, -9.96},
                             {-30.44, -22.43, -9.96},
                             {-27.82, -22.42, -9.96}};
  const double levels[3] = {-48.0, -24.0, 0.0};
  for (int d = 0; d < 3; ++d) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = drives[d];
    p[1] = 0.5f;
    for (int l = 0; l < 3; ++l) {
      int sign = 0;
      const double got = drive_h1(LE_FX_OVERDRIVE, p, levels[l], &sign);
      if (fabs(got - want[d][l]) >= 1.0) {
        printf("  drive %.3f at %.0f dBFS: %.2f, capture %.2f\n", drives[d],
               levels[l], got, want[d][l]);
      }
      CHECK(fabs(got - want[d][l]) < 1.0);
      if (l == 0) CHECK(sign < 0);
    }
  }
}

/* The tone control moves the roll-off: at 100 % 4 kHz comes through
 * louder than at 0 %, and the drive control raises a quiet input. */
static void test_overdrive_controls(void) {
  printf("test_overdrive_controls\n");
  const int sr = 96000;
  const int n = 1 << 15;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 0.001f; /* small: the curve is linear here */
  double at4k[2];
  for (int k = 0; k < 2; ++k) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = 0.0f;
    p[1] = k ? 1.0f : 0.0f;
    le_fx_state* fx = dyn_state(LE_FX_OVERDRIVE, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_OVERDRIVE, p, sr, in, h, NULL, n, &clock);
    dyn_free(fx);
    at4k[k] = eq_measured_db(h, n, 4000.0, sr) - eq_measured_db(h, n, 500.0, sr);
  }
  CHECK(at4k[1] > at4k[0] + 12.0);
  free(in);
  free(h);
  float lo[LE_FX_PARAMS] = {0};
  float hi[LE_FX_PARAMS] = {0};
  lo[1] = hi[1] = 0.5f;
  hi[0] = 1.0f;
  CHECK(drive_h1(LE_FX_OVERDRIVE, hi, -60.0, NULL) >
        drive_h1(LE_FX_OVERDRIVE, lo, -60.0, NULL) + 10.0);
}

/* ---- Distortion ---- */

/* The distortion reproduces the amp captures with the 4x12" cabinet (#891:
 * s3/3, s3/1, s4/16 and s3/2 at Drive 10, 22.7, 50 and 80 %): the 1 kHz
 * fundamental at -48, -24 and 0 dBFS within 2.5 dB (the fit's error is
 * within 2 dB; the s3 captures also had Bass 60 % and Modern 66.7 %). */
static void test_distortion_matches_the_capture(void) {
  printf("test_distortion_matches_the_capture\n");
  const float drives[4] = {0.10f, 0.227f, 0.5f, 0.8f};
  const double want[4][3] = {{-51.12, -27.13, -15.29},
                             {-49.34, -25.36, -15.63},
                             {-45.42, -21.62, -16.11},
                             {-28.26, -16.72, -16.34}};
  const double levels[3] = {-48.0, -24.0, 0.0};
  for (int d = 0; d < 4; ++d) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = drives[d];
    p[1] = 0.5f;
    for (int l = 0; l < 3; ++l) {
      const double got = drive_h1(LE_FX_DISTORTION, p, levels[l], NULL);
      if (fabs(got - want[d][l]) >= 2.5) {
        printf("  drive %.3f at %.0f dBFS: %.2f, capture %.2f\n", drives[d],
               levels[l], got, want[d][l]);
      }
      CHECK(fabs(got - want[d][l]) < 2.5);
    }
  }
}

/* The cabinet's response, with the curve near linear, is the 4x12"
 * capture's (s4/16) within 1.5 dB, relative to 1 kHz. */
static void test_distortion_cabinet(void) {
  printf("test_distortion_cabinet\n");
  const int sr = 96000;
  const int n = 1 << 15;
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1e-4f;
  float p[LE_FX_PARAMS] = {0};
  p[0] = 0.5f;
  p[1] = 0.5f;
  le_fx_state* fx = dyn_state(LE_FX_DISTORTION, sr);
  uint32_t clock = 0;
  dyn_run(fx, LE_FX_DISTORTION, p, sr, in, h, NULL, n, &clock);
  dyn_free(fx);
  const double ref = eq_measured_db(h, n, 1000.0, sr);
  const double want[5][2] = {{92, 2.0}, {263, 2.8}, {2639, 3.7}, {7524, -6.7},
                             {11439, -26.5}};
  for (int i = 0; i < 5; ++i) {
    const double got = eq_measured_db(h, n, want[i][0], sr) - ref;
    if (fabs(got - want[i][1]) >= 1.5) {
      printf("  %.0f Hz: %.2f dB, capture %.2f\n", want[i][0], got, want[i][1]);
    }
    CHECK(fabs(got - want[i][1]) < 1.5);
  }
  free(in);
  free(h);
}

/* ---- all ---- */

static void test_drive_offline_equals_live(void) {
  printf("test_drive_offline_equals_live\n");
  const int32_t kinds[2] = {LE_FX_OVERDRIVE, LE_FX_DISTORTION};
  const int sr = 48000;
  const int n = 4096;
  for (int k = 0; k < 2; ++k) {
    const int32_t ty = kinds[k];
    _Atomic uint32_t frame = 1000;
    le_fx_state* live = dyn_state(ty, sr);
    live->clock_src = &frame;
    le_fx_state* off = dyn_state(ty, sr);
    off->clocked = 1;
    float p[LE_FX_PARAMS] = {0};
    le_fx_defaults(ty, p);
    static float params[LE_FX_MAX][LE_FX_PARAMS];
    const int32_t types[1] = {ty};
    for (int i = 0; i < n; ++i) {
      if (i == 777) p[0] = 0.8f;
      if (i == 2222) p[1] = 0.2f;
      memcpy(params[0], p, sizeof(p));
      const float x = 0.5f * sinf((float)i * 0.05f);
      float ll = x, lr = -x, ol = x, orr = -x;
      off->clock = atomic_load(&frame);
      fx_apply_chain(live, sr, sr, &ll, &lr, 1, types, params, NULL);
      fx_apply_chain(off, sr, sr, &ol, &orr, 1, types, params, NULL);
      CHECK(ll == ol && lr == orr);
      atomic_fetch_add(&frame, 1u);
    }
    CHECK(!le_fx_type_drains(ty));
    CHECK(!le_fx_type_free_running(ty));
    dyn_free(live);
    dyn_free(off);
  }
}

static void test_drive_on_a_lane(void) {
  printf("test_drive_on_a_lane\n");
  const int32_t kinds[2] = {LE_FX_OVERDRIVE, LE_FX_DISTORTION};
  for (int k = 0; k < 2; ++k) {
    const int32_t ty = kinds[k];
    const int32_t count = le_fx_param_count(ty);
    le_engine* e = make_configured_engine();
    establish_loop(e, 0.5f);
    CHECK(le_engine_set_lane_fx(e, 0, 0, 0, ty) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, count - 1, 0.5f) == LE_OK);
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, count, 0.5f) == LE_ERR_INVALID);
    CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
    /* The loop plays a steady 0.5 through the drive: the output is finite
     * and, past the high-pass's settling, still carries the loop. */
    float out[64];
    double energy = 0.0;
    for (int b = 0; b < 200; ++b) {
      process_const(e, 0.0f, 64, out);
      for (int i = 0; i < 64; ++i) {
        CHECK(isfinite(out[i]));
        if (b < 4) energy += (double)out[i] * out[i];
      }
    }
    CHECK(energy > 0.0);
    le_engine_destroy(e);
  }
}

static void run_drive_tests(void) {
  test_overdrive_matches_the_capture();
  test_overdrive_controls();
  test_distortion_matches_the_capture();
  test_distortion_cabinet();
  test_drive_offline_equals_live();
  test_drive_on_a_lane();
}
