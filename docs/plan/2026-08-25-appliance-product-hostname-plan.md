# Product hostname on WiFi and SSH (#496)

Status: **plan for review; one string to pick.** The mechanism is a one-line
policy override plus verification; the only genuine decision is the name.
The issue predates the Pi 5 switch and the rebrand, so this refreshes its
facts first.

## Current state (verified)

- **No hostname override exists anywhere under `deploy/yocto/`** — no
  base-files bbappend, no `hostname:pn-base-files`, no NetworkManager
  hostname key (grep, 2026-08-25; matches the 2026-08-20 triage comment).
  Poky's base-files defaults the hostname to `${MACHINE}`.
- The issue title says `raspberrypi4-64`; the shipping image is now
  `kas-segno-rpi5.yml` / `MACHINE=raspberrypi5` (the Pi 4 is retired), so the
  unit today announces **`raspberrypi5`**. Same defect, new spelling — the
  issue's point stands unchanged.
- **DHCP:** NetworkManager owns eth0 + wlan0 (systemd-networkd is masked in
  `segno-kiosk-image.bb`) and sends the system hostname in DHCP requests by
  default (`dhcp-send-hostname` defaults true), which is exactly how the stock
  name reaches the AP's client list. Fixing `/etc/hostname` therefore fixes
  the router display with no NM configuration.
- **SSH:** dropbear, with host keys persisted on `/data`
  (`dropbear-segno.conf` sets `DROPBEAR_RSAKEY_DIR=/data/dropbear`,
  `segno-ssh-persist`). Hostname is orthogonal to keys: `known_hosts` entries
  keyed by name will be re-learned, keys and IP-keyed entries survive.
- **mDNS: not shipped.** No avahi anywhere in the image (verified), so picking
  a name does **not** buy `segno.local` discovery — the acceptance is the DHCP
  client list and the shell prompt, nothing more.
- Rebrand context: the product name is Segno (#247 happened; the layer is
  `meta-segno`, the RAUC compatible string is `segno-raspberrypi5`).

## Decision for the owner: the string

- **`segno`** — brand-first, and the thing typed daily: `ssh root@segno`.
  On a LAN with two consoles both report the same DHCP hostname; that is
  cosmetic ambiguity in a router UI, not a protocol conflict (DHCP hostnames
  are informational; we ship no mDNS, so no `.local` name clash either).
- **`segno-console`** — clearer in a client list full of IoT junk, at the cost
  of being nobody's first guess at a name to type.
- **`segno-<serial>`** — per-unit disambiguation. Rejected for v1 by the issue
  itself, and it costs the fixed-name property (a runbook can say
  `ssh root@segno`; it cannot say `ssh root@segno-????`). If multi-console
  LANs become real, add a serial suffix later behind a `/data` override
  without changing the default.

**Recommendation: `segno`.** Single fixed name, matches the brand and the
RAUC/product naming already in the tree; the multi-unit LAN is a bench
scenario today and has a clean escape hatch when it stops being one.

## Implementation outline

1. `deploy/yocto/kas-segno-common.yml`, `segno` local_conf_header block:
   `hostname:pn-base-files = "segno"`. Common, not per-board — a retired-board
   rebuild should carry the product name too. (A
   `base-files_%.bbappend` in meta-segno is the equivalent alternative; the
   kas file is where this layer's image policy already lives, next to
   `IMAGE_INSTALL` and the kernel pin, so policy stays greppable in one file.)
2. Verify at build that `/etc/hosts` resolves the new name (poky's base-files
   writes the hostname into its hosts template; confirm on the built rootfs
   rather than trusting the recipe — a name that does not self-resolve turns
   every `sudo`-style lookup and some libc warnings into slow boots).
3. `deploy/yocto/README.md`: document the name where flashing is documented,
   including the `known_hosts` note (`ssh-keygen -R raspberrypi5` /
   old-name entries go stale; keys themselves persist on `/data`).
4. Grep the repo for `raspberrypi4-64`/`raspberrypi5` prose that describes
   the *network identity* (docs only — `MACHINE` itself stays untouched; it is
   a BSP target, not a name).

Explicitly not needed: NM keyfile changes (send-hostname is default-on), iwd
changes (iwd never does DHCP here; NM does), dropbear changes.

## Verification plan

CI proves almost nothing here and should not pretend otherwise: the kas line
is not exercised by any workflow that boots the image. What is checkable
without hardware is the built rootfs (`/etc/hostname` content, `/etc/hosts`
self-resolution) — worth doing once by hand in the local kas build rather
than building CI machinery for a constant.

On-bench (`autonomy:blocked-verify` for the end-to-end claim):
- Fresh flash, cold boot: `uname -n` → `segno`; the AP's client list shows
  `segno` for the WiFi association; the same for a wired DHCP lease.
- `ssh root@<ip>` works; prompt shows the new name; a stale
  `known_hosts` name entry produces the expected re-learn, not a key-change
  warning (keys are on `/data` and did not move).
- RAUC update A→B: name survives (it is in the rootfs both slots share by
  construction — confirm rather than assume).

## Acceptance criteria

- Fresh flash reports the chosen name via `hostname`/`uname -n`, on the AP
  client list, and over SSH; `raspberrypi5` appears nowhere a customer can
  see.
- The name is documented in `deploy/yocto/README.md`.
- No regression in WiFi join/retry flows (the helpers key on interface and
  UUIDs, not hostname — `segno-wifi-ctl`, `segno-wifi-retry` untouched).

## Non-goals

- mDNS/avahi (`segno.local`) — a separate feature with its own daemon,
  security surface, and multi-unit name-collision semantics. This issue only
  stops the stock name leaking.
- Per-unit naming/serial suffixes (v1 explicitly ships one fixed name).
- Renaming `MACHINE`, the RAUC compatible string, or anything that gates OTA
  compatibility.
