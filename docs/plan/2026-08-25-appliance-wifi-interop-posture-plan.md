# Console WiFi vs the customer's AP: what mitigation is actually buildable (#467)

Status: **plan for review.** #467 was opened the night an AP refused the
console for reasons neither side would name. Most of what it feared has since
been engineered away — and the issue's own follow-up comment already withdrew
its headline recommendation (the USB adapter). This document establishes what
the residual risk actually is, and which mitigations are worth building versus
merely reassuring.

## Current state (verified)

The failure that motivated this issue — associates, then the AP never sends
EAPOL-Key M1 — was ultimately fixed by **swapping the supplicant**: #470
(merged) drives the radio with iwd, and the issue's comment records the same
BCM43455 now joining the previously-impossible AP at 260 Mbit/s. The stack
that shipped around that fix is substantial, and each piece is in the tree:

- iwd backend (`recipes-connectivity/networkmanager/networkmanager_%.bbappend`,
  `wifi.backend=iwd` in `99-segno-wifi.conf`); wpa_supplicant is gone, and
  `segno-wifi-ctl`'s `reclaim_wifi` actively repairs the two-supplicants
  state older images could leave behind (#468).
- brcmfmac hardening: `roamoff=1` (`brcmfmac.conf`, validated on-device),
  power-save off twice (`wifi.powersave=2` + `iw set power_save off`), MAC
  randomization off — each one a named AP-interop failure mode.
- Boot determinism: passive iwd store + NM ownership
  (`iwd-main.conf`, #824) and the `segno-wifi-retry` backstop (#827), so a
  transient race no longer strands a working configuration.
- Honest failure narration: `segno-wifi-ctl`'s `map_connect_error` reads the
  supplicant's own journal evidence and refuses NM's "no-secrets" lie, so a
  handshake timeout no longer reaches the user as "wrong password" (#466,
  closed). The #459 evening was largely spent *because* the console lied
  about what failed.
- Reproducibility: every layer is commit-pinned (`kas-segno-common.yml`,
  #465 closed) — the precondition the issue named for qualifying anything.

What has NOT changed: the radio is still brcmfmac talking to firmware we
cannot see into, and the #459 failure class was invisible from both ends
until a supplicant swap happened to fix it. One AP cured is not the class
closed. The residual risk is real but its shape is now: *rare, total,
diagnosable only with evidence the unit must collect itself.*

## Options, and what each actually buys

1. **Supported-AP posture (qualification matrix + settings advisory).** A
   versioned bench procedure (join/reboot-autoconnect/throughput per release
   image) against a small set of owned APs, results recorded in-repo, plus a
   one-page customer advisory ("WPA2-PSK/AES, PMF off, this is what we test
   against"). Buildable now *because* #465 landed; before it, "qualified"
   was unfalsifiable. Cheap, honest, and turns "works with some APs" from a
   fear into a statement with a version number. Its limit: a matrix of the
   APs we own says little about the one in the customer's room.
2. **Diagnostics surface.** Extend `segno-wifi-ctl` with a `diagnose` verb:
   the join-evidence journal window it already collects for error mapping,
   plus regdom, RSSI, BSSID/band, driver+firmware versions, and the last N
   join attempts — bundled to a file on `/data` (and exportable off-device),
   surfaced from the Control Center's Network tab. This is the mitigation
   aimed at the actual worst case: when a customer AP fails, we currently get
   "the WiFi doesn't work"; with this we get the same evidence #459 took a
   night to gather, from a non-engineer, remotely. Mostly shell + a small
   Flutter surface; the shell half is testable in CI with the existing
   `run_wifi_*_tests.sh` harness pattern.
3. **External dongle policy.** The issue's original recommendation, already
   withdrawn by its own follow-up: post-#470 the onboard radio is fine, a
   dangling USB radio on a floor console is a snag hazard, and it spends the
   USB power budget #740 fought for. Keep mt76-class dongles as a *bench
   escape hatch* (a paragraph in the docs, no kernel/module work unless a
   customer case ever demands it) — not a product posture.
4. **Ethernet as the guaranteed path.** Already true in code (NM owns eth0;
   nothing about the app requires WiFi) but nowhere stated as posture.
   Documenting it costs a paragraph and gives support an unconditional
   fallback sentence for the total-failure case.

## Decisions for the owner

- **Posture:** adopt **1 + 2 + 4, reject 3 as product posture** — that is the
  recommendation. Onboard radio is primary and qualified per release;
  ethernet is the documented guaranteed fallback; diagnostics make the
  residual failures reportable. The real decision inside option 1: is the
  advisory/matrix **publishable** (a support commitment customers can quote)
  or **internal** (a bench discipline)? Recommendation: internal first —
  publish once it has survived a few releases.
- **Scope of option 2 now:** full bundle + Control Center surface, or the
  `diagnose` verb alone (journal + state to a file, UI later)? Recommendation:
  the verb alone first — it is the 80% that needs no design work, and the UI
  can follow the existing Network-tab patterns when it earns its place.

## Implementation outline

1. `segno-wifi-ctl diagnose` (shell): emit a timestamped bundle to
   `/data/diagnostics/` — `status` JSON, scan snapshot, saved profiles (names
   only, never PSKs), regdom (`iw reg get`), link info (`iw dev wlan0 link`),
   driver/firmware identifiers, and the `supplicant_evidence` window. Add
   `run_wifi_diagnose_tests.sh` beside the existing helper tests.
2. Docs: qualification procedure + results table (append per release), the
   AP-settings advisory, the ethernet-fallback statement, and the
   dongle-as-bench-tool paragraph — extending `docs/RUNNING_ON_RPI.md`'s
   existing WiFi section rather than a new doc.
3. First matrix run on the bench (the owned APs: the ASUS RT-AX89X from #459
   is the star witness — it is the AP that *found* the last bug).
4. Close/downgrade decision on #467 itself once posture is adopted: the issue
   becomes the tracking issue for the matrix's first fill, then closes.

## Verification plan

Honest split: the `diagnose` verb's *logic* is CI-verifiable (shell harness,
same pattern as `run_wifi_join_error_tests.sh` — fake `nmcli`/`journalctl`,
assert bundle shape and that no PSK ever appears in output). Everything that
matters about interop is `autonomy:blocked-verify`:

- Matrix run is by definition on-bench, per AP, per release image.
- The bundle must be exercised against a *real* failed join (bench AP with a
  wrong-side config, e.g. PMF required) to prove the evidence window catches
  the interesting lines — a fake journal can only prove plumbing.
- The RT-AX89X regression check belongs in every future image qualification:
  it is the only AP known to have exposed a firmware-level interop bug.

## Acceptance criteria

- A failed customer join can be turned into an evidence bundle by a
  non-engineer following one documented step, with secrets provably absent.
- The repo contains a repeatable qualification procedure and at least one
  filled matrix for the shipping image.
- The docs state the supported posture: onboard WiFi qualified, ethernet
  guaranteed, dongle = bench tool.
- #467 is closed or re-scoped to tracking the first matrix fill — it stops
  being an open-ended "risk" issue.

## Non-goals

- Debugging brcmfmac firmware internals (the issue's option 4 — poor return,
  and #470 removed the only live reproduction).
- Shipping or supporting a USB WiFi adapter as product.
- A captive-portal/WPA3/802.1X enterprise story — the advisory scopes v1 to
  WPA2-PSK, which is what the helpers and the UI implement today.
- Remote/automatic upload of diagnostics — bundles stay on the unit until a
  human exports them.
