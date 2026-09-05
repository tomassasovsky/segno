# Moving the console UX toward the Looper X (#919)

Status: **direction plan, plan-gate.** Nothing here is built until the owner
picks which of §3's principles to adopt. Sources: the feature reference
(#911) and the console as it stands.

Two things this plan refuses to do. It will not recommend copying the Looper X
wholesale — segno is a different product with a different chassis, and some of
their choices are consequences of constraints segno does not have. And it will
not treat segno's own features as leftovers: §6 gives each of them a home in
the same language as everything else.

**Every accepted item is a design change and lands in `segno-ui.pen` with its
`c/` rationale.** The pen is the source of truth; a change that only exists in
a PR body has not happened.

> **Revised 2026-08-28: segno is appliance-only** (#920). macOS and Windows are
> banked (backup branch `backup/multiplatform-macos-windows` at `4d0408fc`), and the
> desktop targets come out of the app. This makes the plan *stronger*, not
> weaker: segno and the Looper X are now the same kind of product — one fixed
> panel, one pedal, one room — so their choices transfer directly instead of
> having to be reconciled against a desktop context. Sections marked ⌁ changed
> as a result.

---

## 1. The honest comparison

### Where they are genuinely ahead

Not "prettier". Their surface answers questions without being asked, and
segno's more often makes you go and look.

### Where segno already matches or beats them

Worth stating first, because a plan that starts "theirs is better" tends to
throw away good work.

- **The information architecture is better.** Their menu is a flat grid of 17
  destinations in three unlabelled-by-function groups. segno has a rail of
  eight *domains* — signal · control · loop · tracks · audio · tuner · network ·
  system — each with tabs that answer one question, and the reasoning for each
  grouping is written down in the enum's own doc comments. The Looper X has
  nothing equivalent to "all three tabs answer *what governs the loop grid?*".
  **Do not trade the rail for their grid.**
- **Per-track undo/redo history.** segno draws a paged dot history per track.
  The Looper X has Undo and Redo as pedal functions and **no visual history at
  all**. This is a real segno advantage.
- **A richer FX addressing model.** Theirs is one slot per track with a
  pre/post flag. segno addresses `input · loop · track · master` — four stages
  in signal order. Their model is a special case of segno's.
- ⌁ ~~Cross-platform.~~ **Withdrawn.** This was on the list as a segno
  advantage; with the appliance decision it is no longer one, and the effort it
  was costing is exactly what pays for the work below. One panel is now a
  design *asset* — every pixel can be placed for a known screen, which is most
  of why their surface is as tight as it is.

So the gap is not architecture. It is **surface craft and product finish**.

---

## 2. What is actually different in kind

⌁ Revised for appliance-only.

| | Looper X | segno console |
|---|---|---|
| chassis | fixed appliance, one panel, 12 pedals | fixed appliance, one panel, different pedal |
| FX | 9 fixed racks, 159 factory presets, artwork per rack | user-built chains + hosted VST3/CLAP |
| tracks | 4, with layers | tracks with **lanes** |
| modes | Serial · Sync · SerialSync · Free · Multi | Multi · Sync · Song · Band · Free |
| export | bounce to audio | bounce **and** DAW project export |

The mode lists overlap on only three of five each way — this is not one product
copying another, and the plan should stop pretending it is.

⌁ With desktop gone, the chassis row is the one that stops being a difference.
Everything left in this table is a difference of *product*, not of platform, so
each one is a deliberate choice segno is making rather than a constraint it is
working around.

---

## 3. The seven principles worth stealing

Ranked by how much they change, per unit of work. Each is a *principle*, so
adopting one is a sweep across screens, not one screen.

### P1 — Chrome as permanent state display

**What they do.** Phantom power, CPU load, free disk, tempo, MIDI-slave state
and loop mode are always on screen. And the chrome *adapts*: loop times are
**hidden in Free and Sync modes**, where they would be meaningless.

**Why it works.** A performer never navigates to find out whether phantom power
is on. The chrome is a dashboard, not a title bar.

**For segno.** The stage status bar is already this shape — session name, mode
pill, bank pair, record light, tempo/clock — and its doc comment already says
"readouts, not controls", which is the right instinct. The gap is *coverage*:
segno does not surface engine health, storage headroom, or the input/monitor
state in the chrome. Add them, and adopt the second half of the idea —
**elements that are meaningless in the current mode should disappear, not grey
out**.

**Cost:** low. **Scope:** one widget, applies everywhere.

### P2 — Explain, don't disable

**What they do.** Conflicting actions are never greyed out. Choosing Storage
while USB Audio is live opens a dialog that *names the conflict* and offers to
resolve it. A setting that is unavailable states its precondition in words:
*"only available when Track Start is Aligned"*.

**Why it works.** A greyed control teaches nothing and cannot be recovered
from. Theirs converts every dead end into a decision.

**For segno.** This is the single highest-value import, because segno has *more*
conditional surface than they do — plugin availability, device state, engine
stopped, lanes, network. Every one of those is currently a candidate for a
silent disable.

**Cost:** medium, and ongoing — it is a rule, not a screen. **Scope:** global.

### P3 — Engineering units, never 0–100

**What they do.** Every FX parameter reads `name: value unit` through a
translator — `%.1f Hz`, `%.2f ms`, `%.1f : 1`, `%.0f dB` — with bespoke pan
formatting (`12.3 L`, `C`). Discrete parameters show real names ("4x10\"",
"Concert Hall"), never an index.

**Why it works.** A musician can dial a 250 ms delay. Nobody can dial "0.42".

**For segno.** This is a genuine functional gap: segno's built-in effects carry
normalized `0..1` params with a `ParamReadout` enum that today has only
`none`, `pitchShift` and `octaverMode`. Extending it to real units is a
contained, high-value change to `TrackEffectType.params` and the param tile.
It also sets up the FX work in #887 properly.

**Cost:** medium. **Scope:** the FX editor, then everywhere a value is shown.

### P4 — Small control, big editor

**What they do.** Tapping a pan control opens a **magnified slider over a
blurred live snapshot** of the page, titled with the track name, dismissed by
tapping outside. Same pattern on the mixer and the I/O page.

**Why it works.** It resolves the touchscreen contradiction — you want many
controls visible *and* one control precise — without a separate "edit" mode.

**For segno.** ⌁ Directly applicable to faders, pan, gain, tempo and any FX
parameter. segno already has a tempo keypad sheet, which is the same instinct
applied once; this generalizes it. Appliance-only sharpens this: the overlay
can be sized for one known panel and one thumb, with no pointer fallback to
design around.

**Cost:** low once the overlay exists. **Scope:** one component, many callers.

### P5 — One glyph, two facts

**What they do.** The `FX` badge on a track means "this track has effects", and
its *colour* (cyan vs white) means "this is the record-monitored track". One
glyph, two facts, no extra space.

**Why it works.** Stage instruments are read at a glance from two metres away.
Density has to come from encoding, not from more elements.

**For segno.** A discipline to apply when the track column gets crowded, rather
than a specific change. Worth writing into the design system as a rule.

**Cost:** none directly. **Scope:** a design-system rule.

### P6 — Recede, don't vanish

**What they do.** Inactive tracks de-saturate to `#383A3F` rather than
disappearing; the glow behind a strip is hidden only when empty or muted.
Bypassed text goes `#747A86`.

**Why it works.** The performer keeps a stable spatial map — track 3 is always
in the same place — while attention is drawn to what is live.

**For segno.** Check the track run against this. Anything that currently
*removes* an element on state change is a candidate to de-emphasize instead.

**Cost:** low. **Scope:** the track run and the signal cards.

### P7 — Colour as identity, carried everywhere

**What they do.** A track, a rack and a pedal all carry a user-visible colour,
and the *same* colour appears in the picker, on the slot strip, on the pedal
graphic and in the editor. Each rack ships four artwork variants so it is
recognizable in every context.

**Why it works.** It turns "which one is this?" into a pre-attentive judgement.

**For segno.** segno has track colours; the question is whether they propagate
to the signal cards, the pedal plate and the FX editor. Making one colour
identity travel the whole path is cheap and disproportionately effective.

**Cost:** low–medium. **Scope:** theme + the surfaces that draw an identity.

---

## 4. Feature gaps, ranked by product impact

Separate from principles: things they have that segno does not.

| gap | impact | note |
|---|---|---|
| **Two performance views** (channel strips *and* waveform timeline) | high | segno has the strip view; a waveform/arrangement view is the bigger missing surface |
| **dB-scaled metering with an overload region** | high | theirs: ticks −∞…+10 dB, labelled sparsely where crowded, densely near unity. segno's meters are not on a labelled dB scale |
| **FX as a product** — racks, factory presets, artwork | high | the #887 programme; UX half belongs here |
| **Modal footswitch pages** — Speed, Reverse, Length, Fade, Extend, Peel, Bounce, Transpose | high | this is most of what makes their pedal expressive |
| **Expression pedal with per-assignment min/max** | medium | segno has ~no expression-pedal UX |
| **Backing tracks + audio import** | medium | segno has neither |
| **Time stretch / sync-audio-to-tempo** | medium | absent in segno |
| **Save/Load browser drivable by pedals** | medium | their browser is operable without touching the screen |
| **MIDI learn** with encoder-type detection | medium | segno has MIDI mapping but not learn |
| **Tuner refinement** (±3 cent verdict, pitch reference, input select) | low | segno has a tuner; theirs is more specified |

---

## 5. Phasing

Each phase ships on its own and is judged on its own.

| # | phase | contents | gate |
|---|---|---|---|
| 1 | **Principles, cheap half** | P1 chrome coverage + mode-aware hiding; P4 magnified editor component; P6 recede-don't-vanish audit | `merge-gate` |
| 2 | **Explain, don't disable** | P2 as a rule: audit every disabled control, convert to explained-with-a-fix. Write it into the design system | `merge-gate` |
| 3 | **Metering** | dB scale with labelled ticks and an overload region, on the track run and the signal cards | `merge-gate` |
| 4 | **Engineering units** | P3: extend `ParamReadout` to real units; FX editor shows units everywhere | `merge-gate` |
| 5 | **Identity** | P7: one colour identity across track → signal card → pedal → FX editor | `merge-gate` |
| 6 | **The waveform view** | second performance surface | `plan-gate` — this is a new screen, not a refinement |
| 7 | **Pedal expressiveness** | modal footswitch pages; expression pedal with min/max | `plan-gate` |
| 8 | **FX as a product** | racks + presets UX, on top of #887's engine work | `plan-gate` |

Phases 1–5 are refinements of surfaces that exist. 6–8 are new product
surface and need a direction call first.

---

## 6. segno-only features, and how they get a UX

The features segno has and the Looper X does not currently look like they were
added at different times, because they were. Each needs a home in the same
language.

### 6.1 Plugin hosting (VST3/CLAP) ⌁ — needs a product call first

**The appliance decision hits this feature harder than anything else, and the
UX question is downstream of a product question that is not yet answered.**

The appliance is aarch64 Linux. Commercial VST3/CLAP plugins ship macOS and
Windows builds, sometimes x86_64 Linux, and essentially never arm64 Linux. With
macOS and Windows banked, the hosting stack keeps working — but almost nothing
a user already owns will load on it. What remains reachable is open source
plugins built for ARM, and anything compiled specifically for this device.

So the honest options are:

1. **Curate.** segno ships a vetted set of ARM-built plugins. Hosting becomes an
   internal mechanism, not a user-facing "bring your own plugins" feature, and
   the UX question mostly disappears — they are just more racks.
2. **Keep it open and set expectations.** Users may install ARM Linux plugins;
   the UI has to be honest that most of what they own will not work, which is
   P2 (explain, don't disable) applied to an empty plugin list.
3. **Bank it too,** alongside macOS and Windows, and revisit if segno ever gets
   a desktop again.

**This is a plan-gate call and should be made before any UX is drawn.** Note
that option 1 is also the option that makes plugins fit the Looper X-style rack
model cleanly, which is the direction the rest of this plan is heading.

*If* hosting stays user-facing (options 1 or 2), the UX proposal stands: treat a
plugin as **a rack that segno did not author**. Same slot chrome — name, colour,
bypass, meters, pre/post — and its editor opens into the same frame. The vendor
UI is a *guest inside segno's frame*, not a window that replaces it. Where segno
can read parameters, offer a native parameter view as an alternative, so the
engineering-units rule (P3) still holds.

### 6.2 DAW export

Currently a capability with almost no surface. It deserves a **destination**,
not a menu item: what will be exported, which chains survive as device chains
and which bounce to audio, and *why* — segno already computes exactly this
(`DeviceChainFallbackReason`) and shows the user none of it. This is P2
applied: explain the fallback rather than silently degrading.

### 6.3 Performance capture

The status bar already carries a record light. What is missing is the
**after**: takes, their ids, and what you can do with them. A take browser
belongs beside Sessions, and should use the same "small control, big editor"
idiom for take metadata.

### 6.4 Four-stage FX addressing and lanes

This is segno's biggest structural advantage and its biggest legibility risk:
`input · loop · track · master` is more powerful than one slot per track, and
correspondingly harder to hold in your head. The Signal domain already models
it as tabs in signal order, which is right. The missing piece is a **picture** —
the signal path drawn once, so the four stages are spatial rather than
remembered. (Memory: the owner's standing instruction that "in the graph" means
*integrated into the diagram itself*, and "move them around" means
drag-and-drop.)

### 6.5 Per-track undo/redo history

Already better than theirs. Keep it, and make sure it survives any track-column
redesign in phase 1/3 — it is the kind of thing that gets squeezed out when
meters grow.

### 6.6 Networking and OTA ⌁

These live in `network` and `system` domains and are genuinely *rig* settings
rather than performance surface. The Looper X's global-vs-loop settings split
is the relevant lesson: settings that travel with the song belong with the
song, settings that belong to the rig belong to the rig. Audit segno's split
against that test.

Appliance-only *raises* the stakes here rather than lowering them. On a device
with no desktop companion, the network and OTA surfaces are the only way in —
the Looper X has nothing equivalent, so there is no pattern to borrow and this
is segno's to design. It is also the one place where being a networked appliance
is a genuine advantage over the Looper X, and it is currently buried in
settings.

---

## 7. Risks

- **Copying without cause.** ⌁ Their choices follow from a fixed 800×1280 panel and 12
  pedals. segno's console is a different size with a different pedal. Each
  principle in §3 still has to be re-justified in segno's chassis — but with
  desktop banked this is now a one-chassis judgement rather than a three-way
  reconciliation, which is a real simplification.
- **The pen must lead.** If these land as code first, the pen stops being the
  source of truth and the next session inherits a lie. Design in the pen,
  build from it.
- **Phase 3 and 6 collide.** The waveform view and the metering rework both
  touch the track run; do 3 first, or do them together.
- **Do not lose the rail.** The strongest thing segno has is the domain
  structure. Nothing in this plan should dilute it in pursuit of their look.

- ⌁ **The removal could take the dev loop with it.** Phases 1–5 are all UI
  refinement, and UI refinement needs a fast iterate-and-look loop. If the
  macOS *build target* goes away along with macOS as a *product*, every visual
  change has to be deployed to the Pi to be seen, and the screenshot goldens —
  which only run on the author's machine — lose their host entirely. Keeping a
  developer-only desktop host is compatible with "segno is an appliance"; losing
  it would slow this plan down more than anything else in this document.
  **Flagged for a decision on #920, not assumed here.**

## 8. Next step

Owner picks from §3 which principles to adopt — they are independent, and P1,
P2 and P4 are cheap enough to do together. Phases 6–8 need their own direction
calls and should not start until 1–5 have shown what the surface looks like
after the refinements.
