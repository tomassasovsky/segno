# Hardware validation checklist

The on-device checks that **cannot run in CI or headless** — they need a real
audio interface, the console's pedal board, or a second display in front of you. Every
software gate around these is already green (native tests, fuzzer, the appliance
image build); this is the remaining physical bench work. Check items off as you
confirm them.

> Context: these were tracked across `docs/PROGRESS.md` ("On-hardware validations
> still open") and the pedal/LED memory. Collected here so there's one list.

## 1. Round-trip latency gate (Phase-1 acceptance: ≤ 10 ms)
- [ ] Plug in a class-compliant interface + a loopback path (a physical cable
      from an output to an input).
- [ ] Run the app; trigger the loopback latency auto-measure in audio setup.
- [ ] **Pass:** measured round-trip ≤ 10 ms at a sane buffer (e.g. 128 frames).
- [ ] Confirm the **latency-compensated** overdub lands tight (record over a click,
      listen for flam) and that undo/redo clicks are acceptably small.

## 2. Readout screen (the console's 7″)
- [ ] On the console, the 7″ shows the readout: the selected track with its
      waveform, drawn by the second engine (`readout` in `homescreen.toml`).
- [ ] **Pass:** the waveform moves with the playhead and tracks the audio, the
      readout follows track selection on the main screen, and it survives an
      audio device reconnect.

---

When an item passes, tick it and (optionally) note the interface/OS used. If one
fails, capture the symptom — those become software bugs to file, since the code
paths themselves are unit-/integration-covered but never hardware-exercised.

## Results — 2026-07-13 (first bench pass)
- **ASIO full-count (Windows): ✅ PASS** — 18 in / 20 out on a Clarett OctoPre+.
  Historical: the Windows build was removed in #920, and this check went with it.
- **#1 latency: ⚠️ 15.15 ms** — over the 10 ms gate, but it's the *monitoring*
  path (recording stays tight via latency compensation) and buffer-dependent.
  Re-measure at 128 frames; if still >10 ms it's the interface floor and the gate
  should be revised to ≤16 ms. Not a correctness bug.
- **#2 waveform window: ⚠️ works, but should go full-screen on the 2nd monitor.**
  Addressed — the output window now detects a secondary display, moves onto it,
  and fullscreens (windowed fallback when there's one screen). Superseded: the
  readout is now the console's 7″ screen (#1330); see #2 above.
