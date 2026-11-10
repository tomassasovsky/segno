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

/* The drive control raises a quiet input. */
static void test_overdrive_controls(void) {
  printf("test_overdrive_controls\n");
  float lo[LE_FX_PARAMS] = {0};
  float hi[LE_FX_PARAMS] = {0};
  lo[1] = hi[1] = 0.5f;
  hi[0] = 1.0f;
  CHECK(drive_h1(LE_FX_OVERDRIVE, hi, -60.0, NULL) >
        drive_h1(LE_FX_OVERDRIVE, lo, -60.0, NULL) + 10.0);
}

/* Below its knee the overdrive has the Guitar Rack OvDrive's band-pass
 * response (#1663, session s18idle, white noise at -90 dBFS): at Drive 0,
 * 50.3 and 100 % with Tone 50.2 %, and at Tone 0 and 100 % with Drive
 * 50.3 %, from 50 Hz to 4 kHz within 2 dB, at 48 kHz as captured and at
 * 44.1 and 96 kHz. It lifts 50 Hz 12 to 22 dB less than 1 kHz, so it does
 * not raise an input's mains hum by the full drive gain. */
static void test_overdrive_small_signal_matches_the_capture(void) {
  printf("test_overdrive_small_signal_matches_the_capture\n");
  const int rates[3] = {48000, 44100, 96000};
  const float amp = 1e-5f; /* far under the clipped part's knee */
  const double hz[7] = {50, 100, 250, 500, 1000, 2000, 4000};
  const float set[5][2] = {
      {0.0f, 0.502f}, {0.503f, 0.502f}, {1.0f, 0.502f}, {0.503f, 0.0f},
      {0.503f, 1.0f}};
  /* The captured gain, dB. */
  const double want[5][7] = {
      {-1.30, 1.92, 7.71, 11.53, 12.46, 9.60, 4.29},
      {2.91, 7.91, 14.83, 18.87, 19.84, 16.93, 11.39},
      {12.45, 18.52, 25.94, 29.99, 30.73, 26.98, 19.25},
      {2.83, 7.64, 13.55, 15.70, 14.65, 11.19, 6.91},
      {2.93, 8.00, 15.39, 20.73, 24.56, 25.47, 23.00}};
  for (int r = 0; r < 3; ++r) {
    const int sr = rates[r];
    const int n = sr == 96000 ? 1 << 16 : 1 << 15;
    float* in = (float*)calloc((size_t)n, sizeof(float));
    float* h = (float*)calloc((size_t)n, sizeof(float));
    in[0] = amp;
    for (int k = 0; k < 5; ++k) {
      float p[LE_FX_PARAMS] = {0};
      p[0] = set[k][0];
      p[1] = set[k][1];
      le_fx_state* fx = dyn_state(LE_FX_OVERDRIVE, sr);
      uint32_t clock = 0;
      dyn_run(fx, LE_FX_OVERDRIVE, p, sr, in, h, NULL, n, &clock);
      dyn_free(fx);
      for (int i = 0; i < 7; ++i) {
        const double got = eq_measured_db(h, n, hz[i], sr) - 20.0 * log10(amp);
        if (fabs(got - want[k][i]) >= 2.0) {
          printf("  %d Hz: drive %.3f tone %.3f at %.0f Hz: %+.2f dB, capture "
                 "%+.2f\n",
                 sr, set[k][0], set[k][1], hz[i], got, want[k][i]);
        }
        CHECK(fabs(got - want[k][i]) < 2.0);
      }
    }
    free(in);
    free(h);
  }
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
 * capture's (s4/16) within 1.5 dB, relative to 1 kHz, at 48 kHz, the
 * Looper X's rate. */
static void test_distortion_cabinet(void) {
  printf("test_distortion_cabinet\n");
  const int sr = 48000;
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

/* The drive's law is the Studio Rack's Dist's (#1731, session s19std, the
 * Dist alone at Drive 0 to 100 % as the Looper X shows them): the 1 kHz
 * fundamental at -48 dBFS in is within 3.5 dB of the capture at every
 * setting, and rises with it as the capture does. */
static void test_distortion_drive_is_the_studio_dist(void) {
  printf("test_distortion_drive_is_the_studio_dist\n");
  const float drives[8] = {0.0f,  0.056f, 0.10f, 0.233f,
                           0.5f,  0.665f, 0.80f, 1.0f};
  const double want[8] = {-56.35, -55.85, -55.08, -51.77,
                          -46.06, -37.50, -27.93, -19.88};
  double last = -1e9;
  for (int d = 0; d < 8; ++d) {
    float p[LE_FX_PARAMS] = {0};
    p[0] = drives[d];
    p[1] = 0.5f;
    const double got = drive_h1(LE_FX_DISTORTION, p, -48.0, NULL);
    if (fabs(got - want[d]) >= 3.5) {
      printf("  drive %.3f: %.2f, capture %.2f\n", drives[d], got, want[d]);
    }
    CHECK(fabs(got - want[d]) < 3.5);
    CHECK(got > last);
    last = got;
  }
}

/* The tone reads as the gain of its 2 kHz shelf: at 16 kHz, with the curve
 * near linear, each setting moves the response from the flat middle by
 * the descriptor's dB within 0.5 dB. */
static void test_distortion_tone_reads_in_db(void) {
  printf("test_distortion_tone_reads_in_db\n");
  const int sr = 48000;
  const int n = 1 << 15;
  const float tones[5] = {0.0f, 0.25f, 0.5f, 0.9f, 1.0f};
  const le_fx_param_desc tone = fxd_get(LE_FX_DISTORTION, 1);
  CHECK(tone.unit == LE_FX_UNIT_DB);
  float* in = (float*)calloc((size_t)n, sizeof(float));
  float* h = (float*)calloc((size_t)n, sizeof(float));
  in[0] = 1e-4f;
  double flat = 0.0;
  double got[5];
  for (int t = 0; t < 5; ++t) {
    float p[LE_FX_PARAMS] = {0};
    p[1] = tones[t];
    le_fx_state* fx = dyn_state(LE_FX_DISTORTION, sr);
    uint32_t clock = 0;
    dyn_run(fx, LE_FX_DISTORTION, p, sr, in, h, NULL, n, &clock);
    dyn_free(fx);
    got[t] = eq_measured_db(h, n, 16000.0, sr);
    if (tones[t] == 0.5f) flat = got[t];
  }
  for (int t = 0; t < 5; ++t) {
    const double want = fxd_value(&tone, tones[t]);
    if (fabs(got[t] - flat - want) >= 0.5) {
      printf("  tone %.2f: %.2f dB, descriptor %.2f\n", tones[t],
             got[t] - flat, want);
    }
    CHECK(fabs(got[t] - flat - want) < 0.5);
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
    /* The loop plays a steady 0.5 through the drive: the output stays
     * finite, and the drive's response to the loop starting is heard (its
     * high-pass then removes the steady part; the capture tests check what
     * it does to signal). */
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

/* The oversampled drives report their latency (#1547), and the snapshot
 * sums a chain's slots: an Overdrive after an octaver adds to the
 * octaver's, a bypassed one adds nothing, and the Distortion, which runs
 * at 1x at 96 kHz, adds there only the few frames of the half-band that
 * keeps its curve's harmonics off its 48 kHz cabinet (le_hb). */
static void test_drive_latency_sums_in_a_chain(void) {
  printf("test_drive_latency_sums_in_a_chain\n");
  le_engine* e = make_configured_engine(); /* 48 kHz */
  le_snapshot s;
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OVERDRIVE);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  const int32_t od = s.fx_added_latency_frames;
  printf("  the Overdrive at 48 kHz: %d frames\n", od);
  CHECK(od > 0 && od < 48); /* under a millisecond */
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 0.0f); /* PV mode */
  le_engine_set_monitor_input_fx(e, 0, 1, LE_FX_OVERDRIVE);
  le_engine_set_monitor_input_fx_count(e, 0, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == LE_PV_LATENCY + od);
  le_engine_set_monitor_input_fx_enabled(e, 0, 1, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == LE_PV_LATENCY);
  le_engine_destroy(e);

  e = le_engine_create();
  le_engine_configure(e, 96000, 1, 1, 1000);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DISTORTION);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  printf("  the Distortion at 96 kHz: %d frames\n", s.fx_added_latency_frames);
  CHECK(s.fx_added_latency_frames > 0 && s.fx_added_latency_frames < 8);
  le_engine_destroy(e);
}

static void run_drive_tests(void) {
  test_drive_latency_sums_in_a_chain();
  test_overdrive_matches_the_capture();
  test_overdrive_controls();
  test_overdrive_small_signal_matches_the_capture();
  test_distortion_matches_the_capture();
  test_distortion_cabinet();
  test_distortion_drive_is_the_studio_dist();
  test_distortion_tone_reads_in_db();
  test_drive_offline_equals_live();
  test_drive_on_a_lane();
}
