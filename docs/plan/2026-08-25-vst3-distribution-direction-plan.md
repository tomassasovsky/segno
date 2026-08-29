# VST3 FX plugins — the distribution direction pick (#194)

Status: **the two owner decisions the epic waits on, laid out with a
recommendation each.** #194 has sat in `stage:plan-review` since 2026-07-13
because parts 12 and 15–17 need direction, not code. This doc is the
decision surface; each chosen part then follows the normal plan → build
pipeline.

## Current state (verified 2026-08-25)

- Parts 1–11 shipped (#137–#147); parts 13–14 shipped (#159/#160/#161).
  CI carries three per-OS gates today: `vst3-plugins-macos` /
  `vst3-plugins-windows` / `vst3-plugins-linux`
  (`.github/workflows/main.yaml:348/363/377`) — GUID + golden-parity +
  wrapper + load-smoke CTests. No `pluginval` anywhere in the build.
- **Part 12** (macOS hardened runtime + notarization) is still only a
  breadcrumb (`packages/segno_engine/vst3/CMakeLists.txt:192`) and is
  blocked on an Apple Developer Program membership that does not exist.
- **Parts 15–17** have two competing in-repo definitions:
  - the original installer plans
    (`docs/plan/2026-07-08-feat-segno-fx-vst3-plugins-part-{15,16,17}-plan.md`):
    macOS `.pkg`, Windows installer, Linux package — parts 15 and 16
    **hard-depend on signing certs** (part 15's dependency line: "Part 12
    … must be Developer ID signed before packaging"), i.e. blocked on the
    same membership plus an Authenticode cert;
  - the A/B/C redefinition
    (`docs/brainstorm/2026-07-13-vst3-plugins-parts-15-17-brainstorm-doc.md`):
    15 = `pluginval` CI gate, 16 = CLAP builds, 17 = unsigned release
    packaging — none cert-blocked.
- **Licensing landscape has moved under the original plans.** The repo is
  GPL-3.0-or-later (ASIO vendoring forced the relicense). The vendored VST3
  SDK is now **v3.8.0, MIT** (`packages/segno_engine/third_party/README.md`)
  — the old Steinberg proprietary/GPLv3 dual-license tension is gone for the
  plugin wrappers. The CLAP SDK is already vendored (MIT). The plugin
  bundles link `segno_dsp_core` + the MIT VST3 SDK only — the
  Steinberg-agreement ASIO SDK is the *engine's* Windows audio path and is
  not in any plugin artifact, so the distributable plugins are cleanly
  GPLv3.

## Decisions for the owner

### D-1. Part 12: drop, or keep blocked?

- **Drop it** (recommended): ad-hoc signing loads locally; distribution
  documents `xattr -dr com.apple.quarantine`, which the brainstorm already
  proposed and parts 13–14 shipped their macOS story around. Nothing else in
  the epic depends on it once D-2 picks the unsigned path. Reopen as a fresh
  issue if an Apple Developer Program membership (~USD 99/yr) ever exists —
  notarizing GPL software is fine; the cost is the membership and the CI
  secret handling, not the license.
- **Keep it blocked**: an open checkbox that no plan can unblock is board
  noise; it also silently keeps the original parts 15–16 alive as
  "someday" items.

### D-2. Parts 15–17: which definition?

- **Original installers**: real end-user value, but 15 and 16 are
  cert-blocked today (Developer ID + Authenticode), each is a first-ever
  installer infrastructure for this repo (their own plans say so), and an
  unsigned installer is *worse* than a documented archive — it trips
  SmartScreen/Gatekeeper with none of the trust it implies.
- **A/B/C redefinition** (recommended):
  - **15 = `pluginval` CI gate** — extend the three existing
    `vst3-plugins-*` jobs to run pluginval per plugin per OS at a pinned
    strictness. Catches what load-smoke cannot (state round-trip, param
    bounds, threading, bus arrangements, audio-thread allocation). Small,
    self-contained, no product design — a candidate for `autonomy:auto`.
  - **16 = CLAP builds** — a `clap/` sibling to `vst3/` reusing
    `segno_dsp_core` (the CLAP SDK is vendored and the engine already
    scans CLAP, `src/host/scan_clap.cpp`); golden-parity + load-smoke +
    CI jobs mirroring the VST3 ones. Medium-large; gets its own plan.
  - **17 = unsigned release packaging** — a tag-triggered job zipping the
    per-OS bundles (`.vst3`, and `.clap` once 16 lands) with an INSTALL
    note (macOS: the quarantine-clear step). **GPLv3 compliance goes here
    and is cheap but mandatory:** each archive ships `LICENSE` and a
    pinned source link (tag URL) satisfying the corresponding-source
    offer; the vendored MIT/BSD notices ride along as the third_party
    tree already keeps them.

**Recommended order: 15 → 17 → 16.** 15 hardens what already ships in CI
this week; 17 is small and turns green CI into something a user can
download (it does not depend on 16 — CLAP artifacts join the archive when
they exist); 16 is the biggest slice and lands into an already-validated,
already-shipping pipeline. (The brainstorm ordered 15 → 16 → 17; flipping
16/17 front-loads user value and defers the largest unknown — this is the
only place this doc departs from it.)

## Implementation outline

1. Owner answers D-1 and D-2 (a comment on #194 suffices).
2. Update #194's body checkboxes to the chosen definition; move the epic
   `stage:plan-review` → `stage:plan`.
3. If A/B/C: retire the three 2026-07-08 part-15/16/17 installer plans with
   a status header pointing here (do not delete — they are the record of
   the installer design, and become live again the day certs exist).
4. Per-part plans follow: 15 is small enough to plan+build in one slice;
   17 similarly; 16 gets a real plan (bus layout, CLAP param/state mapping,
   per-OS bundle shape).

## Verification plan

Per part, at build time: 15 — pluginval passing at the pinned strictness on
all three OS jobs, and a deliberately broken plugin failing it; 17 — a tag
dry-run produces three archives whose contents load in a real host per the
existing manual-check playbook, `LICENSE` + source link present; 16 — the
same golden-parity CTest discipline the VST3 side has, plus load-smoke in a
CLAP host. Epic-level: this doc's decisions recorded on #194.

## Acceptance criteria

- D-1 and D-2 answered on the issue by the owner; labels and body updated.
- The chosen parts each have (or are queued for) their own plan docs.
- No part remains defined only by a checkbox with two contradictory
  in-repo definitions.

## Non-goals

- Building any of 15–17 here.
- Signing/notarization work of any kind (that is exactly what D-1 retires
  or defers).
- DAW-export targets, custom plugin editor GUIs, factory presets — ranked
  out in the brainstorm, still out.
