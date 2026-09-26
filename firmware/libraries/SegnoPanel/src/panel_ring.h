#pragma once
// Ring animation retained from the console v2 implementation.
// Included by the ring sketch after its frame and NeoPixel state.
// A comet travels the ring at a FIXED cadence — it says
// "something is happening", in the activity colour, and deliberately does not
// track the loop: one revolution per loop is unreadably slow at any musical
// length, and the playhead is already on the screens (owner's call,
// 2026-09-03).
//
// A Stop that leaves a loop loaded freezes the comet where it was. With nothing
// loaded and nothing playing the ring breathes green so it reads as alive; the
// breathe never reaches black, so an idle panel still shows the board is up.
static const unsigned long RING_MS_PER_REV = 700;
static const unsigned long BREATHE_MS = 1200;
// The dimmest the breathe goes, as a fraction of full: never off.
static const float BREATHE_FLOOR = 0.35f;
// The comet's shape, picked on the unit against an even fade, a fast drop and
// four steps (#1064): the tail trails 3/4 of a turn behind the head, stays
// bright for most of it and drops at the end. It fades to a floor, not to
// black, because gamma plus LED_BRIGHTNESS turn anything under ~25% level off,
// and a fade to 0 looked half as long as it was. The last quarter stays dark.
static const float COMET_TAIL = RING_N * 0.75f;  // LEDs, head included
static const float COMET_FLOOR = 0.3f;
static float g_ringPhase = 0.0f;  // comet head, 0..RING_N
static unsigned long g_ringLastMs = 0;
// What the ring buffer currently holds. One question, asked once: every branch
// of renderRing() states which view it just painted, and the caller pushes the
// strip only when that key changed. Per-branch latches were tried and each one
// grew its own reset rule — the arc forgot to restore what it painted over,
// and the dark branch forgot to repaint at all.
enum RingView : uint8_t { RING_NONE = 0, RING_DARK, RING_ARC, RING_COMET, RING_BREATHE };
static uint8_t g_ringView = RING_NONE;
static uint8_t g_ringKeyA = 0;  // arc: lit pixels; comet: phase in whole pixels
static uint8_t g_ringKeyB = 0;  // the colour that view was painted in
// The colour the comet was last drawn in. A Stop freezes the comet but sends
// GLOBAL_OFF, so the frame no longer says what colour to freeze it at; without
// remembering it, restoring the comet paints it black.
static Rgb g_cometColour = {0, 255, 0};

// Draws the comet with its head at the current phase, in `c`.
static void paintComet(Rgb c) {
  for (uint16_t i = 0; i < RING_N; i++) {
    // How far this pixel trails the head, in the direction of travel.
    const float behind = fmodf(g_ringPhase - (float)i + (float)RING_N, (float)RING_N);
    float b = 0.0f;
    if (behind <= COMET_TAIL - 1.0f) {
      const float x = behind / (COMET_TAIL - 1.0f);  // 0 at the head, 1 at the tail's end
      b = COMET_FLOOR + (1.0f - COMET_FLOOR) * (1.0f - x * x);
    } else if (behind < COMET_TAIL) {
      b = COMET_FLOOR * (COMET_TAIL - behind);  // the tail's last pixel, fading out
    } else if (behind > RING_N - 1.0f) {
      b = behind - (RING_N - 1.0f);  // the pixel the head is moving onto, fading in
    }
    ring.setPixelColor(i, scaled(c.r, c.g, c.b, (uint8_t)(b * 255.0f + 0.5f)));
  }
}

// Returns whether the ring buffer changed and needs pushing.
static bool renderRing() {
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;

  // Records which view is now in the buffer; returns whether that is new.
  auto settle = [](uint8_t view, uint8_t keyA, uint8_t keyB) -> bool {
    const bool changed =
        g_ringView != view || g_ringKeyA != keyA || g_ringKeyB != keyB;
    g_ringView = view;
    g_ringKeyA = keyA;
    g_ringKeyB = keyB;
    return changed;
  };

  if (!g_haveFrame || g_frame.goodbye) {
    if (g_ringView == RING_DARK) return false;
    ring.clear();
    return settle(RING_DARK, 0, 0);
  }
  const Rgb activity = globalColor(g_frame.global_color);

  // The master level, as a filled arc, for a moment after it changes. In the
  // ring's own colours: the activity colour it is already showing, or the
  // standby green it breathes when there is no activity to report. Elapsed
  // form, so it is wrap-safe AND cannot fire on a stale deadline.
  if (g_gainArmed && now - g_gainShownAt < GAIN_SHOW_MS) {
    const bool coloured = activity.r || activity.g || activity.b;
    const Rgb c = coloured ? activity : Rgb{0, 255, 0};
    const uint8_t lit = (uint8_t)((g_frame.master_gain * RING_N + 254) / 255);
    if (!settle(RING_ARC, lit, g_frame.global_color)) return false;
    for (uint16_t i = 0; i < RING_N; i++) {
      ring.setPixelColor(i, i < lit ? rgb(c.r, c.g, c.b) : 0);
    }
    return true;
  }
  g_gainArmed = false;

  const bool active = (activity.r || activity.g || activity.b) && g_frame.global_color != PEDAL_GLOBAL_BLUE;
  // A Stop with a loop still loaded freezes the comet where it was — in the
  // colour it was playing in, which the frame no longer carries.
  if (!active && g_frame.loop_length_micros > 0) {
    if (!settle(RING_COMET, (uint8_t)g_ringPhase, PEDAL_GLOBAL_COUNT)) {
      return false;
    }
    paintComet(g_cometColour);
    return true;
  }
  if (!active) {  // standby: breathe green
    const unsigned long p = now % BREATHE_MS;
    const unsigned long half = BREATHE_MS / 2;
    float t = (p < half) ? (p / (float)half) : (1.0f - (p - half) / (float)half);
    t = t * t * (3.0f - 2.0f * t);
    const uint8_t level =
        (uint8_t)((BREATHE_FLOOR + (1.0f - BREATHE_FLOOR) * t) * 255.0f + 0.5f);
    const uint32_t green = scaled(0, 255, 0, level);  // same for every pixel
    for (uint16_t i = 0; i < RING_N; i++) ring.setPixelColor(i, green);
    settle(RING_BREATHE, level, 0);
    return true;  // it animates every tick
  }
  g_ringPhase =
      fmodf(g_ringPhase + (float)dt / (float)RING_MS_PER_REV * (float)RING_N, (float)RING_N);
  g_cometColour = activity;
  settle(RING_COMET, (uint8_t)g_ringPhase, g_frame.global_color);
  paintComet(activity);
  return true;
}
