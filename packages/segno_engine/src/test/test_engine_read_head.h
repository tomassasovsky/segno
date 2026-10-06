/* engine_read_head.h oracles (#1179 Part 1): the pure read coordinate every
 * later part consumes. Included from test_engine_core.c like test_engine_fade.h. */

static double head_ref_mod(double x, int32_t len) {
  double r = fmod(x, (double)len);
  if (r < 0) r += len;
  return r;
}

static void test_read_head_identity_is_exact(void) {
  printf("test_read_head_identity_is_exact\n");
  const int32_t len = 48000;
  float* ramp = (float*)malloc(sizeof(float) * (size_t)len);
  for (int32_t i = 0; i < len; ++i) ramp[i] = (float)i;
  const le_read_head id = {0, 0.0, 1.0};
  CHECK(le_head_is_identity(&id));
  for (int64_t pos = 0; pos < 1000000; pos += 7) {
    const double idx = le_head_index(&id, pos, len);
    CHECK(idx == (double)(pos % len));
    CHECK(le_head_sample(ramp, len, idx) == ramp[pos % len]);
  }
  /* an integral origin shifts the identity path without interpolating */
  const le_read_head shifted = {0, 123.0, 1.0};
  CHECK(!le_head_is_identity(&shifted));
  for (int64_t pos = 0; pos < 200000; pos += 3) {
    const double idx = le_head_index(&shifted, pos, len);
    CHECK(idx == (double)((pos + 123) % len));
    CHECK(le_head_sample(ramp, len, idx) == ramp[(pos + 123) % len]);
  }
  /* the reversed coordinate of the Foot Reverse plan: (origin - pos) mod len */
  const le_read_head rev = {1, (double)(len - 1), 1.0};
  for (int64_t pos = 0; pos < 200000; pos += 5) {
    const double idx = le_head_index(&rev, pos, len);
    CHECK(idx == head_ref_mod((double)(len - 1) - (double)pos, len));
  }
  CHECK(le_head_index(&id, 5, 0) == 0.0); /* empty source reads index 0 */
  free(ramp);
}

static void test_read_head_fractional_rates(void) {
  printf("test_read_head_fractional_rates\n");
  const int32_t len = 1000;
  float ramp[1000];
  for (int32_t i = 0; i < len; ++i) ramp[i] = (float)i;
  /* half speed: two song laps visit every index exactly twice, reading
   * i + 0.5 on the odd frames (linear interpolation of a ramp) */
  const le_read_head half = {0, 0.0, 0.5};
  int visits[1000] = {0};
  for (int64_t pos = 0; pos < 2 * len; ++pos) {
    const double idx = le_head_index(&half, pos, len);
    const int32_t i = (int32_t)idx;
    visits[i]++;
    const float s = le_head_sample(ramp, len, idx);
    if (pos % 2 == 0) {
      CHECK(s == ramp[i]);
    } else if (i < len - 1) {
      CHECK(fabsf(s - ((float)i + 0.5f)) < 1e-4f);
    } else {
      CHECK(fabsf(s - 499.5f) < 1e-4f); /* wrap: between len-1 and 0 */
    }
  }
  for (int32_t i = 0; i < len; ++i) CHECK(visits[i] == 2);
  /* integer rates visit r*i and the box average is the mean of the skipped run */
  const double rates[] = {2.0, 4.0, 8.0};
  for (int r = 0; r < 3; ++r) {
    const le_read_head h = {0, 0.0, rates[r]};
    const int32_t n = (int32_t)rates[r];
    for (int64_t pos = 0; pos < len / n; ++pos) {
      const double idx = le_head_index(&h, pos, len);
      CHECK(idx == (double)(pos * n));
      const float box = le_head_sample_decimated(ramp, len, idx, rates[r]);
      const float mean = (float)(pos * n) + (float)(n - 1) / 2.0f;
      CHECK(fabsf(box - mean) < 1e-3f);
    }
    /* the box wraps at the top of the source */
    const double top = le_head_index(&h, (len / n) - 1, len);
    CHECK(top == (double)(len - n));
    float expect = 0.0f;
    for (int32_t k = 0; k < n; ++k) expect += ramp[len - n + k];
    CHECK(fabsf(le_head_sample_decimated(ramp, len, top, rates[r]) - expect / (float)n) < 1e-3f);
  }
  /* tempo ratios: the index never leaves [0, len) and matches the reference */
  const double ratios[] = {0.75, 1.0 / 0.75, 1.0 / 3.0};
  for (int r = 0; r < 3; ++r) {
    const le_read_head h = {0, 37.25, ratios[r]};
    for (int64_t pos = 0; pos < 100000; pos += 11) {
      const double idx = le_head_index(&h, pos, len);
      CHECK(idx >= 0.0 && idx < (double)len);
      CHECK(fabs(idx - head_ref_mod(37.25 + ratios[r] * (double)pos, len)) < 1e-6);
    }
  }
  /* decimation below 2 is the plain sample */
  const le_read_head slow = {0, 0.0, 1.5};
  CHECK(le_head_sample_decimated(ramp, len, le_head_index(&slow, 3, len), 1.5) ==
        le_head_sample(ramp, len, 4.5));
}

static void test_read_head_reorigin_and_wrap(void) {
  printf("test_read_head_reorigin_and_wrap\n");
  const int32_t len = 44100;
  /* continuity: changing rate or direction at pos keeps the index */
  le_read_head a = {0, 0.0, 1.0};
  const int64_t pos = 123457;
  const double at = le_head_index(&a, pos, len);
  le_read_head b = {0, 0.0, 2.0};
  b.origin = le_head_origin(&b, at, pos, len);
  CHECK(fabs(le_head_index(&b, pos, len) - at) < 1e-9);
  CHECK(fabs(le_head_index(&b, pos + 1, len) - head_ref_mod(at + 2.0, len)) < 1e-9);
  le_read_head c = {1, 0.0, 0.5};
  c.origin = le_head_origin(&c, at, pos, len);
  CHECK(fabs(le_head_index(&c, pos, len) - at) < 1e-9);
  CHECK(fabs(le_head_index(&c, pos + 2, len) - head_ref_mod(at - 1.0, len)) < 1e-9);
  /* the head reversed again keeps its index and runs forward from it */
  le_read_head d = {0, 0.0, 0.5};
  const double at_c = le_head_index(&c, pos + 100, len);
  d.origin = le_head_origin(&d, at_c, pos + 100, len);
  CHECK(fabs(le_head_index(&d, pos + 100, len) - at_c) < 1e-9);
  CHECK(fabs(le_head_index(&d, pos + 102, len) - head_ref_mod(at_c + 1.0, len)) < 1e-9);
  /* wrap detection, both directions, at every rate */
  const double rates[] = {0.5, 1.0, 2.0, 8.0, 0.75};
  for (int r = 0; r < 5; ++r) {
    for (int rev = 0; rev < 2; ++rev) {
      const le_read_head h = {rev, 0.0, rates[r]};
      int wraps = 0;
      double prev = le_head_index(&h, 0, len);
      const int64_t frames = (int64_t)(4.0 * len / rates[r]);
      for (int64_t p = 1; p <= frames; ++p) {
        const double next = le_head_index(&h, p, len);
        if (le_head_wrapped(prev, next, rev)) wraps++;
        prev = next;
      }
      CHECK(wraps == 4 || wraps == 3); /* four laps; the last edge may land on the boundary */
    }
  }
  /* the modulus helper agrees with fmod for large positive and negative values */
  CHECK(fabs(le_head_wrap(1e12 + 0.5, 48000) - head_ref_mod(1e12 + 0.5, 48000)) < 1e-3);
  CHECK(fabs(le_head_wrap(-1e9 - 0.25, 48000) - head_ref_mod(-1e9 - 0.25, 48000)) < 1e-6);
  CHECK(le_head_wrap(48000.0, 48000) == 0.0);
}

static void test_read_head_turn_mix_and_q32(void) {
  printf("test_read_head_turn_mix_and_q32\n");
  const int32_t F = 960;
  CHECK(le_head_turn_mix(0, F, 0) == 0.0f && le_head_turn_mix(F, F, 0) == 1.0f);
  CHECK(le_head_turn_mix(0, F, 1) == 0.0f && le_head_turn_mix(F, F, 1) == 1.0f);
  for (int32_t i = 0; i <= F; ++i) {
    const float g_new = le_head_turn_mix(i, F, 0);
    const float g_old = le_head_turn_mix(F - i, F, 0);
    CHECK(fabsf(g_new + g_old - 1.0f) < 1e-5f); /* equal gain sums to one */
    const float p_new = le_head_turn_mix(i, F, 1);
    const float p_old = le_head_turn_mix(F - i, F, 1);
    CHECK(fabsf(p_new * p_new + p_old * p_old - 1.0f) < 1e-3f); /* equal power */
    CHECK(fabsf(p_new - sinf((float)i / (float)F * 1.5707963f)) < 2e-4f);
    if (i > 0) CHECK(p_new >= le_head_turn_mix(i - 1, F, 1)); /* monotonic */
  }
  CHECK(le_head_turn_mix(3, 0, 0) == 1.0f); /* a zero window snaps */
  const double idx = 12345.678901234;
  const uint64_t q = le_head_index_q32(idx);
  CHECK(fabs(le_head_index_from_q32(q) - idx) < 1e-9);
  CHECK(le_head_index_q32(1.0) == 4294967296ull);
  CHECK(le_head_index_q32(0.5) == 2147483648ull);
}
