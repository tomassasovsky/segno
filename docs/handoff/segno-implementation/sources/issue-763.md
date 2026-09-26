# #763 feat(pedal): custom pedal mode + protocol v4 [open]

The second surviving scope item of epic #442 (the first is named racks #535), which until now lived only in that epic's comments — no tracker of its own. Related: the switch-behavior (bypass) scope cut from the FX screen redesign was also never tracked; it lands here.

**Scope:** a custom pedal mode beyond the fixed three — the pedal's switches get user-assignable behaviours (e.g. FX bypass toggles) — carried by pedal protocol v4.

**Current state:** `packages/pedal_repository/lib/src/pedal_codec.dart` still speaks v3; mode value 3 is reserved-and-rejected (the codec's own comment). Firmware contract implications overlap #752 (board v2 / Pico 2) and the LED topology call in #369.

**Why plan-gate:** what the custom mode can bind to (chain bypass? per-effect? racks from #535?) is a product-direction call that shapes the protocol.

---
## comment 2026-08-26T02:58:27Z

Plan is up: [`docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md`](https://github.com/tomassasovsky/segno/blob/plan/pedal-definitions/docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md) via PR #847.

Short version: the pedal is a thin client, so a custom mode is almost entirely app-side — most of the machinery already shipped as FX-mode bindings (per-button/per-bank keys, toggle/momentary with the B1 discipline, R25 stale no-op, zero-wire-byte LED projection). The wire cost collapses to unreserving mode value 3, which both decoders currently reject; that is the whole of protocol v4 as recommended: version byte 0x04, payload stays 17 bytes, custom degrades to play (mute) at ≤v3 exactly as FX does. v4 lands once in the shared `pedal_protocol.{h,c}` unit + golden fixtures, so the Pico 2 firmware (#752) speaks it from its first compile — and #369 contributes nothing to v4 in either direction (its companion plan shows the indicator chain never touches the wire).

Four calls are yours (details + options in the doc): D1 binding vocabulary — recommended FX targets **plus named app actions** (undo, clear-all, stop-all, tap-tempo, track arm…), rack targets joining when #535 lands; D2 wire shape — recommended zero growth; D3 negotiation — recommended manual version picker now, identity discovery deferred; D4 — custom joins the MODE cycle after fx, boot-excluded like fx (R12).

**The one that shapes everything is D1: should a custom switch bind only to FX targets, or also to the named app actions (with rack loads deferred to #535) as recommended?**

---
## comment 2026-08-26T04:48:14Z

**Direction approved (2026-08-26):** per `docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md` — all four calls:
- D1: binding vocabulary = FX targets + named app actions (rack targets defer to #535).
- D2: zero-growth wire v4 — version 0x04, unreserve mode 3, 17-byte payload, degrades to play on <=v3.
- D3: manual version picker now.
- D4: custom joins the MODE cycle, boot-excluded.


---
## comment 2026-09-10T05:25:01Z

Slice 3d of the accepted-design programme (epic #1009, issue #1016) has landed its **Mixer view**, and its **foot Mixer** waits on this issue.

The accepted Mixer design enters the foot Mixer from a custom pedal assignment: "Custom pedal assigned Mixer — press enters Mixer, hold runs its separately configured action". That is D1's binding vocabulary, so entering the Mixer by foot is a named app action in the set this issue defines, not an interaction mode of its own.

Building it as a separate mode would need a fifth wire value and a second protocol version, against the direction approved here on 2026-08-26, which spends the one free value on `custom`.

Recording the dependency so the sequencing is visible: this issue is now the prerequisite for the foot half of #1016's part 3d. Its direction is approved and its implementation has not started.


---
## comment 2026-09-11T19:44:34Z

Slice 1 of the approved plan (protocol v4, codec-only) is up as #1029, stacked on the accepted-design slice-4 train (#1027 → #1028 → #1029).

Version byte 0x04, the same 17-byte payload, mode value 3 meaning custom from v4 on and rejected below it — D2's zero-growth wire as approved. Custom degrades to mute below v4, so an un-reflashed pedal shows the wrong mode LED rather than no LEDs. Amber in all three colour sites; the plate's widget test now pins every mode rather than only FX. Two new golden fixtures carry the contract across the language boundary, and the C contract test reaches the decoder's version gate by relabelling a v4 frame, since the encoder will not write those bits below v4 on its own.

Slice 2 (firmware render) landed with it: the `modeColor` arm is in both sketches, held identical by the existing drift gate.

Sequencing note for slices 3 and 4: the accepted-design programme reached the same place from the other side. Issue #1026 part 4c shipped the Pedals setup screen and the shared action catalogue (#1028), so the Custom map is already edited and persisted, and the catalogue already covers D1's named app actions for everything the rig can do today. What remains is `InteractionMode.custom` itself and its dispatch, which is #1026's part 4d.

One consequence worth recording: part 4c retired `ModeSwitchStyle` into the accepted MODE pair, which took the foot's only path to arming a performance recording (it was the MODE hold). The catalogue carries `command:record-performance`; the mode that dispatches it is part 4d, so that gap closes with this work.

---
## comment 2026-09-11T20:47:09Z

Recording the hardware the mode LED actually has to render on, since it is not the one the two Arduino sketches target.

The console ships a **Pico 2 / RP2350** on console board v2, linked to the Pi over UART (Pico uart0 GP16/17 to Pi uart3 GPIO8/9, 10 k series each way) and cold-flashed over SWD from the Pi's GPIO24/25. No Pico 2 firmware exists in this repo, and there is no UART `PedalTransport` app-side either — the three that exist are noop, native MIDI and the simulator.

This is the case the plan made for landing v4 once in the shared plain-C `pedal_protocol.{h,c}`, and #1029 did exactly that: the Pico 2 bring-up speaks v4 from its first compile rather than needing a second protocol change after the board arrives.

**What that firmware will still owe:** its own `modeColor` amber arm for `PEDAL_MODE_CUSTOM`. `firmware/test/run_tests.sh` holds the two existing sketches' colour vocabularies identical to each other, and cannot cover a file that does not exist — so the third copy is the one drift the gate will not catch. Worth adding to that gate when the sketch lands.

The Arduino sketches stay the V1 standalone pedal. Amber there, and the degrade on an un-reflashed one, are checkable whenever that hardware is in hand; the console's mode LED waits on the Pico 2 firmware and the transport that reaches it.

---
## comment 2026-09-11T20:50:50Z

**D2 revisited and widened (owner call, today).** The approved zero-growth v4 rejected per-pedal LED bytes as "wire bytes for feedback no hardware can show: V1 has no transport indicators, and the v2 faceplate deliberately dropped them (#792 — six pills)".

That premise is stale. `hardware/segno_wiring.md` records the change under #930: the pills went from 6 single LEDs to **ten 8-LED segments**, one per footswitch, in full colour. The hardware to show a per-pedal colour now exists, which is also what the accepted design assumes when #1026 part 4e asks for "colour configurable on all ten including the fixed-action pedals".

The reasoning behind D2 still holds — do not pay wire bytes for feedback nothing can render. The answer changed because the renderer did.

**Decision: widen v4 now rather than spending a v5.** Nothing has been flashed with v4 — #1029 is unmerged and no Pico 2 firmware exists — so completing the version costs nothing today, and the Pico 2 bring-up still speaks the final shape from its first compile, which was the whole point of "v4 lands once".

The non-goal "no payload growth, no new message types" is lifted for exactly this, and for nothing else.

---
## comment 2026-09-11T21:01:55Z

Widened v4 is up as #1031, stacked on #1030.

Thirty bytes appended: one RGB triplet per footswitch, indexed by `PedalButton` so the order is the one both sides already share for note numbers. Raw RGB rather than a palette index — the user's colours reach the LED unquantised, thirty rarely-changing bytes cost nothing at this frame rate, and the pedal holds no second thing that can go stale across a reboot the app did not see. Below v4 they fall off entirely and decode as the default palette; every pre-v4 fixture is byte-identical.

Nothing renders them yet. How a configured colour combines with a fixed-action pedal's own signal is the open behaviour question — the MODE LED currently says which mode by its colour, and the default palette is white on all ten, so applying colour there naively would cost every user who never opens the editor their mode reading. That call belongs with the palette editor.

**One thing worth a closer look than the feature:** the decoder was reading past its buffer. `pedal_unpack7` writes one byte per payload byte it finds into a fixed stack buffer, and the length came off the wire unchecked, so a long SysEx walked off the end. It predates all of this — the buffer was 17 bytes before — and it is reachable from anything that can send MIDI to the app or the pedal. Both copies now bound the body before unpacking, and the contract test builds under AddressSanitizer so the guard is proven rather than asserted: remove it and the suite reports a stack-buffer-overflow in `pedal_unpack7`.
