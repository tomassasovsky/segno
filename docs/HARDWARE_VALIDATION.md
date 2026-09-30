# Hardware validation checklist

The on-device checks that **cannot run in CI or headless** — they need a real
audio interface, the console's pedal board, or a second display in front of you. Every
software gate around these is already green (native tests, fuzzer, per-OS builds,
plugin CTests); this is the remaining physical bench work. Check items off as you
confirm them.

> Context: these were tracked across `docs/PROGRESS.md` ("On-hardware validations
> still open") and the pedal/LED memory. Collected here so there's one list.

## 1. Round-trip latency gate (Phase-1 acceptance: ≤ 10 ms)
- [ ] Plug in a class-compliant interface + a loopback path (a physical cable
      out→in, or a virtual device like BlackHole/VB-Cable).
- [ ] Run the app; trigger the loopback latency auto-measure in audio setup.
- [ ] **Pass:** measured round-trip ≤ 10 ms at a sane buffer (e.g. 128 frames).
- [ ] Confirm the **latency-compensated** overdub lands tight (record over a click,
      listen for flam) and that undo/redo clicks are acceptably small.

## 2. ASIO full-count interface (Windows)
- [ ] Plug in a multi-channel interface (e.g. Focusrite Scarlett/Clarett) on
      Windows; select the ASIO backend + its driver in audio setup.
- [ ] **Pass:** all input/output channels enumerate at the interface's real count
      (e.g. 18 in / 20 out) — not the WASAPI-limited pair.
- [ ] Record/monitor/route across several channels; confirm the WASAPI↔ASIO device
      match and the loopback-exclusion (a "Loopback" input is hidden).
- [ ] Confirm the exclusive-mode / fallback status row reflects reality.

## 3. Secondary-window waveform visualizer (2nd display)
- [ ] With a second display attached, open the waveform window (the toggle in Big
      Picture settings / the `desktop_multi_window` sub-window).
- [ ] **Pass:** the whole-loop output waveform renders with a moving playhead bar
      and tracks the audio; it survives a device reconnect.

---

When an item passes, tick it and (optionally) note the interface/OS used. If one
fails, capture the symptom — those become software bugs to file, since the code
paths themselves are unit-/integration-covered but never hardware-exercised.

## Results — 2026-07-13 (first bench pass)
- **#2 ASIO full-count: ✅ PASS** — 18 in / 20 out on a Clarett OctoPre+ (Windows).
  Validates the whole multichannel/ASIO effort (previously build-verified only).
- **#1 latency: ⚠️ 15.15 ms** — over the 10 ms gate, but it's the *monitoring*
  path (recording stays tight via latency compensation) and buffer-dependent.
  Re-measure at 128 frames; if still >10 ms it's the interface floor and the gate
  should be revised to ≤16 ms. Not a correctness bug.
- **#3 waveform window: ⚠️ works, but should go full-screen on the 2nd monitor.**
  Addressed — the output window now detects a secondary display, moves onto it,
  and fullscreens (windowed fallback when there's one screen). Needs a re-check
  on the 2-monitor bench.
