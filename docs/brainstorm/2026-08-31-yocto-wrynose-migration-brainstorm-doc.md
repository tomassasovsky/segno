---
date: 2026-08-31
topic: yocto-wrynose-migration
---

# Yocto Wrynose Migration

## What We're Building

Move the Segno appliance image from **Yocto 5.2 walnascar** (commit-pinned via kas today) to **Yocto 6.0 wrynose LTS** (supported until April 2030), keeping the same product shape: weston kiosk-shell, prebuilt Flutter GTK bundle, RAUC/tryboot A/B on Pi 5 (NVMe), ALSA + PREEMPT_RT audio path.

The migration is **not** a product redesign — no display-stack swap, no Flutter host bump, no Pi 4 publishing change. It **is** a series bump plus the deferred RAUC work to ship **boot + rootfs together** in the `.raucb`, so existing walnascar units can OTA onto wrynose with a kernel whose modules match the rootfs.

## Why This Approach

### Motivation

Walnascar is not LTS. Wrynose is the current LTS line and aligns with long-term maintenance for a shipping floor console. Staying on a short-lived series repeats the unreproducible-upstream drift pain that commit-pinning (#465) was meant to stop — but on an EOL-ish branch.

### Approaches considered

**A — kas + split poky repos + boot-in-bundle + 6.18-if-RT (chosen)**

Keep `kas-container` and the existing kas project layout (`kas-segno-common.yml` + per-board files). Replace the deprecated **poky combo-layer** clone with commit-pinned `openembedded-core`, `bitbake`, and `meta-yocto` on `wrynose`. Absorb wrynose layout/API changes in `meta-segno`. Add the FAT boot slot to `RAUC_BUNDLE_SLOTS` so OTA delivers kernel + modules together. Prefer `linux-raspberrypi` 6.18 with `PREEMPT_RT`; fall back to 6.12 on wrynose if RT is not selectable.

**B — wrynose userspace only, rootfs-only OTA, stay on 6.12**

Smaller diff, but contradicts the 6.18 goal and leaves kernel/modules skew if the boot slot is not updated. Rejected.

**C — switch fetch/setup to bitbake-setup**

Upstream’s official replacement for the poky combo-layer, but it does **not** replace kas-container or solve macOS/CI isolation. Would rewrite CI/README on top of the same recipe/Weston/RAUC work with no LTS benefit. Rejected for this migration; can be a follow-up chore.

### Boot-slot decision

`system.conf` already parents `firmware.0/1` (FAT boot slots) to `rootfs.0/1`, but `segno-update-bundle.bb` only bundles rootfs today. **OTA from walnascar with a new kernel requires boot-in-bundle** — otherwise `/lib/modules/$(uname -r)` on the new rootfs will not match the kernel still running from the old FAT slot. First wrynose OTA must include both slots.

## Key Decisions

- **Target series:** wrynose (YP 6.0 LTS), not styhead/whinlatter as an intermediate hop.
- **Tooling:** keep **kas + kas-container**; split poky into OE-core + bitbake + meta-yocto in kas YAML. Do **not** migrate to bitbake-setup in this work.
- **Kernel:** prefer **6.18 + PREEMPT_RT** on wrynose; if RT is not selectable or fails on bench, ship **6.12.% on wrynose** and follow up on 6.18.
- **OTA:** must work from walnascar production/experimental channels onto wrynose with the same `segno-raspberrypi5` compatible string. **Boot slot in `.raucb` from day one.**
- **Flutter bundle:** keep Ubuntu 24.04-built prebuilt bundle; verify GLib/GTK SONAME load on device (same failure mode as scarthgap → walnascar GLib 2.80 crash).
- **Scope exclusions:** no display-stack evaluation (#897), no Pi 4 publish path, no bundle host OS change, no EEPROM self-provision (#826) unless a wrynose recipe forces it.
- **Autonomy:** `plan-gate` for direction (boot-slot OTA + tooling), then `blocked-verify` for merge (green BitBake ≠ works on Pi 5).

## Open Questions

- Does wrynose’s default `linux-raspberrypi` 6.18 expose `CONFIG_PREEMPT_RT` on `raspberrypi5` arm64 without the current 6.12 pin rationale changing?
- Do the two weston out-of-tree patches apply cleanly on wrynose’s weston version, or need rewrite?
- Does meta-rauc’s wrynose move of `system.conf` to `/usr/lib/rauc` require more than a path tweak in `rauc-conf.bbappend` / runtime assumptions?
- After boot-in-bundle lands, does tryboot + `segno-mark-good` need bundle-format or handler changes beyond slot list expansion?
- Self-hosted runner disk (#817): cold wrynose sstate — wipe/namespaced cache before first build, or accept ~2 h cold + tens of GB?
