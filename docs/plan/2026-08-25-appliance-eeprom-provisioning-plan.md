# The image provisions the bootloader EEPROM itself (#826)

Status: **plan for review.** The issue already names the mechanism fork; this
document grounds it in what the image actually ships, picks a phased
recommendation, and is honest about the one experiment that has to happen on
the bench before any write path can be trusted.

## Current state (verified)

- The manual ritual is real and documented twice: `deploy/yocto/README.md`
  ("Pi 5: the EEPROM settings no image can carry") and the header of
  `deploy/yocto/kas-segno-rpi5.yml` both tell a human to run
  `sudo rpi-eeprom-config --edit` once per board, from whatever OS happens to
  be on it. That is a provisioning step the product cannot see, cannot check,
  and cannot repeat.
- The image genuinely cannot read the EEPROM today. `vcgencmd
  bootloader_config` is the read path, and `vcgencmd` is not in the image:
  meta-raspberrypi's raspi-utils recipe compiles only `pinctrl` and `dtmerge`,
  and our bbappend
  (`deploy/yocto/meta-segno/recipes-devtools/raspi-utils/raspi-utils_%.bbappend`)
  adds only `vcmailbox` (for the RAUC tryboot backend). One more
  `OECMAKE_TARGET_*:append` line closes the read gap.
- The image deliberately carries no python3, which rules out shipping
  `rpi-eeprom-config` on-device (it is python; `rpi-eeprom-update` and
  `rpi-eeprom-digest` are shell). Build-time is different: bitbake has native
  python, so rendering a config into an EEPROM image at build is free.
- The boot layout gives the `.upd` a home. `segno-tryboot.wks.in` builds the
  tryboot selector (p1, autoboot.txt only) plus bootA/bootB, both from
  `--source bootimg-partition` — anything added to `IMAGE_BOOT_FILES` lands in
  **both** slots, so whichever slot the firmware boots, the staged update is
  present.
- Target config (from the issue, and equal to the bench unit's current
  known-good state): `BOOT_ORDER=0xf416`, `PSU_MAX_CURRENT=5000`,
  `BOOT_UART=1`, and `NET_INSTALL_AT_POWER_ON` **absent** — the last one is the
  sneaky one, because the "Configure this Raspberry Pi 5" screen only appears
  on cold power-on and therefore survives every warm-reboot test pass.
- The bench evidence on the write path is ambiguous and must be treated as
  such: a staged `pieeprom.upd` was NOT consumed on a warm reboot, and the one
  cold boot that mattered was confounded by a simultaneous manual edit. Nobody
  currently knows whether the firmware's self-update scans our tryboot layout.

## Decisions for the owner

**1. Write mechanism.**

- **(A) Build-time `pieeprom.upd` staged in the boot partitions.** A
  meta-segno recipe pins an `rpi-eeprom` release, uses the build host's python
  to bake our config section into the official `pieeprom.bin`, emits
  `pieeprom.upd` + `pieeprom.sig`, and adds both to `IMAGE_BOOT_FILES`. The
  firmware self-applies on the next cold boot. Config-as-code, versioned with
  the image, rides OTA for free (the `.raucb` refreshes the boot slot).
  Cost: pins a bootloader *version* per image, and stands on the unverified
  assumption that self-update works under tryboot.
- **(B) Runtime drift-apply oneshot.** Read `vcgencmd bootloader_config`,
  diff, write on drift. Handles newer-bootloader units gracefully — but the
  writer is bootloader-flashing code we then own, on a device whose worst
  failure mode (bad EEPROM) is strictly worse than the disease (recovery is an
  SD rescue image), and the official writer is python we refuse to ship.
- **(C) Document-only.** Already rejected by the owner; it does not scale past
  one bench.

**Recommendation: (A), gated on the bench experiment below, with the
read-only drift detector from (B) shipped unconditionally.** The detector is
the half of (B) with all of the value and none of the risk: one journal line
saying "this board's EEPROM does not match the image" would have turned the
`0xf461`-vs-`0xf416` evening into a grep. If the experiment shows tryboot
starves self-update, fall back to deciding (B) — do not build the writer
speculatively.

**2. Newer-bootloader policy.** The firmware only applies a `.upd` that is
newer than the EEPROM it is running. Recommendation: **never downgrade** —
accept that a board carrying a future bootloader skips the staged update, and
rely on the detector to report any *config* drift on such a board. Config
changes we care about then ship by deliberately bumping the pinned
`rpi-eeprom` release. This turns "what do we do about newer bootloaders" from
a runtime branch into a review-time decision.

**3. Does the detector fail loudly or just log?** Recommendation: log loudly
(a clearly-tagged journal line + the unit visible in `systemctl --failed` via
a non-blocking oneshot exit 1), never block boot — a console that plays with a
drifted EEPROM beats one that refuses to.

## Implementation outline

Phase 1 — detector (buildable now, no write risk):
1. `raspi-utils_%.bbappend`: append `vcgencmd/all` + `vcgencmd/install` to the
   OECMAKE target lists (exactly the existing `vcmailbox` pattern).
2. `segno-bundle`: install `/etc/segno/eeprom.conf` (the target config,
   the single source of truth) and a `segno-eeprom-check` oneshot +
   service (After=multi-user, not boot-blocking): normalize
   `vcgencmd bootloader_config` output, diff against target, exit 1 with one
   tagged journal line per divergent key. Shell only; unit-testable with the
   existing `run_*_tests.sh` harness pattern under
   `recipes-segno/segno-bundle/test/`.

Phase 2 — the bench experiment (cheap, decides everything):
3. On the bench Pi 5, stage a `pieeprom.upd`/`pieeprom.sig` pair (config-only
   delta, e.g. a comment change) on the active boot slot by hand, **cold**
   power cycle, and read back `vcgencmd bootloader_version`/`_config`. Repeat
   from the *inactive* slot after a RAUC switch. Record the result on #826.

Phase 3 — build-time staging (only if phase 2 passes):
4. New recipe `rpi-eeprom-firmware`: fetch a pinned `rpi-eeprom` release
   (commit-pinned, same discipline as the kas layers, #465), run
   `rpi-eeprom-config --config` + `rpi-eeprom-digest` at build (native
   python3/openssl) to produce `pieeprom.upd` + `pieeprom.sig` carrying
   `/etc/segno/eeprom.conf`'s content, and add both to `IMAGE_BOOT_FILES`.
5. Build-time self-check: extend the `tryboot-cmdline.bbclass` mtools pattern
   with an assertion that both boot slots in the final `.wic` carry the pair,
   and that a read-back of the `.upd`'s config section contains the target
   values.
6. Rewrite `deploy/yocto/README.md`'s EEPROM section from "do this by hand"
   to "the image does this; here is the manual override for a bricked board".

## Verification plan

This is `autonomy:blocked-verify` in the fullest sense: **green in CI proves
the artifact, not the flash.** CI can and should prove: the recipe builds,
both boot partitions carry `.upd`+`.sig`, the config section matches
`/etc/segno/eeprom.conf`, and the detector script's diff logic passes its shell
tests. None of that says the firmware consumes the file.

On-bench (the bench Pi 5, whose current EEPROM is the known-good target):
- Deliberately drift the EEPROM (e.g. `BOOT_ORDER=0xf41`, add
  `NET_INSTALL_AT_POWER_ON`), flash the image, **cold** boot: EEPROM must
  read back at target and the console must reach the app.
- Warm reboot after that: no re-flash (bootloader version unchanged), no
  detector noise.
- RAUC update to the other slot, cold boot: same invariants from bootB.
- Detector-only image on a drifted board: exactly one loud journal line per
  divergent key, unit in `systemctl --failed`, boot otherwise unaffected.
- Keep the SD rescue card written **before** the first write test — a wrong
  EEPROM write is the one failure worse than the disease.

## Acceptance criteria

- A fresh Pi 5 with stock EEPROM goes flash → cold boot (→ possibly one
  firmware-initiated reboot) → app, with zero hand-typed EEPROM steps.
- A drifted unit reports drift in one greppable journal line.
- `deploy/yocto/README.md` no longer instructs a manual `rpi-eeprom-config`
  as the normal path.
- The pinned `rpi-eeprom` release is a reviewable, explicit bump, like every
  other layer pin.

## Non-goals

- EEPROM version management UI, or exposing bootloader state in the Control
  Center (the detector's journal line is the v1 surface).
- Downgrading a newer bootloader.
- The Pi 4 (retired board; SD boot has no NVMe BOOT_ORDER problem and its
  EEPROM story differs).
- Runtime EEPROM *writing* (option B's writer) — explicitly deferred unless
  phase 2 falsifies option A.
