# RPi 5 boot experience: the decision already shipped — close #271 (#271)

Status: **recommendation to close, with one narrow residual.** #271 is the
parent plan-gate for "fast boot + Flutter splash + no desktop, Tier 2 vs
Tier 3". Auditing the shipped image against the issue's own scope shows every
fork it was opened to decide has since been decided by shipped code. What is
left is a measurement pass and one visual seam — a single blocked-verify
issue, not a standing architecture question.

## Current state (verified against the issue's scope)

The issue asked for three things and a direction call. All four are on
`master`:

- **The direction call (Tier 2 vs 3, 3a vs 3b).** The shipping unit boots the
  Yocto image (`deploy/yocto/`): weston kiosk-shell + the prebuilt GTK bundle
  — that *is* Tier 3a, chosen through spike #284 (closed) and hardened by
  every appliance issue since. The 3b fork existed because
  `desktop_multi_window` was believed incompatible with a lean image; the
  shipped answer kept the two-window GTK architecture and pinned each window
  to an output with kiosk-shell `app-ids`
  (`recipes-graphics/weston-init/files/weston.ini`, #689) — no re-architecture
  of the 7" waveform panel was ever needed. `deploy/yocto/README.md` states
  the Pi 4 is retired and Pi 5 ships; the README's "No meta-flutter" note
  records why 3b's embedder never entered the image.
- **NVMe vs microSD.** Decided and shipped: `kas-segno-rpi5.yml`
  (`SEGNO_BOOT_DISK=nvme0n1`), #799 closed, the `--use-label` fstab trap fixed
  in `segno-tryboot.wks.in` (#802 closed).
- **No desktop / no flashes.** weston kiosk-shell, `disable_splash=1` (kills
  the firmware rainbow), `console=tty3 fbcon=map:9 quiet loglevel=3
  logo.nologo vt.global_cursor_default=0` (kills kernel text and the cursor) —
  all in `kas-segno-common.yml`'s `kiosk-console` block.
- **Splash.** Plymouth with the segno theme
  (`recipes-graphics/plymouth-segno-theme/`), determinate progress, mark-only
  art per #830. `weston-after-plymouth.conf` orders weston after
  `plymouth-quit-wait.service` so the two never fight over DRM.

Also verified: the issue's "linchpin" — `plymouth quit --retain-splash` fired
from the runner's first-frame gate — **cannot work on the shipped
architecture** and should be retired from the issue's mythology. Retaining a
splash across a compositor start requires the compositor to inherit the
framebuffer; weston takes DRM master itself, which is exactly why the shipped
drop-in makes plymouth quit *first*. The gap between splash death and first
app frame is real and is currently masked by palette (the splash's #08080A
near-black against weston's default background and the app's dark first
frame), not eliminated by a handoff.

## What genuinely remains

1. **Nothing here was ever measured on the shipping hardware.** The issue's
   ~2–4 s Tier 3 estimate, the seam inventory, and the splash handoff were
   validated ad hoc on the Pi 4 bench at best. There is no recorded
   power-on→splash / power-on→first-frame budget for the Pi 5 + NVMe unit
   anywhere in the repo.
2. **The splash→weston→first-frame seam** needs a deliberate audit: pin
   weston's background color to the splash's #08080A (weston.ini
   `[shell] background-color` is not currently set) and confirm the app's
   first frame is the same near-black, so the unavoidable DRM handoff reads
   as a continuous dark screen on camera, not just to a forgiving eye.
3. **Stale prose.** `docs/RUNNING_ON_RPI.md` still opens with the Tier 2
   decisions ("Decision 1: GTK-on-Wayland", "Decision 2: labwc") — labwc lost
   to weston when the Yocto image shipped, and a reader landing there today is
   told the wrong compositor.

Out of this issue's scope but adjacent, so said plainly: the image still
ships `allow-root-login empty-root-password` + dropbear unconditionally
(`segno-kiosk-image.bb`, marked "drop for anything resembling production").
That is production hardening, not boot experience, and deserves its own issue
rather than a ninth life for this one.

## Decision for the owner

- **(a) Close #271 now.** Comment with the audit above as the sign-off record
  (Tier 3a, NVMe, plymouth splash — all shipped), and file one narrow
  follow-up: *"measure and close the boot seams on the shipping Pi 5"*
  (blocked-verify) carrying §What genuinely remains items 1–2, plus the
  RUNNING_ON_RPI.md cleanup as a docs task. File the production-hardening
  issue separately.
- **(b) Re-scope #271** down to that residual and keep the number.
- **(c) Keep it open as an umbrella.** Rejected: a plan-gate issue whose
  every gate has been decided by shipped code is board noise, and this one has
  already needed two board-hygiene comments explaining why it is still open.

**Recommendation: (a).** The issue's value was the decision; the decision
exists in `deploy/yocto/` with more fidelity than any sign-off comment. A
fresh, small issue states the remaining work honestly instead of asking
readers to subtract six shipped PRs from a 2026-07 framing.

## Implementation outline (for the residual issue, not for #271)

1. weston.ini: set the kiosk-shell background to #08080A; confirm the app's
   first frame color on both outputs.
2. Bench measurement: phone-camera recording of a cold boot; record power-on →
   splash-visible → app-first-frame timestamps; append the numbers to the
   residual issue and `docs/RUNNING_ON_RPI.md`.
3. Docs: replace RUNNING_ON_RPI.md's Tier-2 decision prose with a pointer to
   `deploy/yocto/README.md` as the appliance's canonical description.

## Verification plan

Honest posture: **every remaining check is on-device** (`blocked-verify`).
There is no CI signal for "no grey flash between plymouth and weston" — the
acceptance instrument is a slow-motion camera pointed at the panel during a
cold power-on. The only CI-checkable piece is the weston.ini value and the
docs change.

## Acceptance criteria

- #271 closed with the sign-off audit, or re-scoped by explicit owner choice.
- The residual seam/measurement issue exists, labeled `stage:brainstorm` +
  `autonomy:blocked-verify`, with the camera checklist in its body.
- A production-hardening issue exists for the debug image features.
- No open issue any longer implies Tier 2 vs Tier 3 is an open question.

## Non-goals

- Re-opening 3b/ivi-homescreen or meta-flutter (the two-window GTK
  architecture shipped and works; the research doc remains as history).
- Boot-time *optimization* work — until the measurement exists there is no
  evidence the current boot is too slow, and the issue's original estimates
  are not requirements.
- The splash art itself (#830 settled it: the mark alone).
