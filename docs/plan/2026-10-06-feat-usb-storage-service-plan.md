# Appliance USB storage service: detect, mount, account, eject, fail safely

Tracking: #1177 (gap inventory E9-5; parent M7 "Device + appliance"),
`autonomy:merge-gate` for Parts 1 and 5 (image behaviour and a redesigned
screen), `autonomy:auto` for Parts 2, 3, 4 and 6 (verifiable here, narrow).
Base: `origin/claude/segno-integration` at `c3714abc2`. Every `file:line`
below is on that head unless a branch is named.

Design source: `segno-ui.pen` (the 107 MB main-checkout file), group
`01 CURRENT UX`, read through the pencil MCP:

- section **31 Storage & safe eject** (`PQ2W9`, status "Accepted · capacity,
  transfer protection and safe USB removal"): `Storage overview` (`BQc2H`),
  `Ejecting USB` (`SowFm`), `Safe to remove` (`GbezI`), `No USB drive`
  (`t5SpNf`), `Eject failed` (`PQOpP`), `Low internal space` (`uvis2`);
- section **48 Recording destinations · Accepted** (`w70bn`): `Choose Internal
  or USB` (`cH9UX`), `Record directly to USB` (`FwjUV`), `USB interruption ·
  Take held` (`HWH3p`), `Recovered recording in Library` (`Z3V6Z`);
- section **47 Long recordings · Accepted** (`ut4fa`): `Capacity unavailable`
  (`T8ACW`), `Storage reserve · Recording kept` (`yzmtU`);
- section **20 Record performance & USB export** (`G2Cj8g`): `10 / Connect
  USB drive` (`m5XyVv`), `11 / Export storage error` (`M734SS`), `09 / Matching
  filename` (`DFfXS`), `08 / Export in progress` (`iYJSm`), `12 / Export
  complete` (`ee8o6`);
- section **18 Audio library** USB views: `02 / Audio library / USB drive`
  (`B5q2Q`), `06 / Audio library / USB disconnected` (`jsmae`);
- section **34 Session backup & restore**: `Retry an interrupted copy`
  (`vzH8N`, "USB drive disconnected. Nothing was changed.");
- section **44 Appliance backup · Accepted**: `USB appliance backups` (`Au2tf`).

Sections 20, 18, 34 and 44 are consumers. This plan builds the service they
share and the two surfaces that are the service's own (the Storage page and the
destination picker); the Library (#1178), export (E7-13), backup (E7-14/15) and
long-recording (E7-11/12) flows consume it through the interfaces defined here.

Accepted behaviour this plan implements: `docs/handoff/segno-app/accepted-behavior.md`
§6.6–6.8 (lines 445–460), §7.7 (lines 535–539), §7.8 (lines 541–543), §6.12
(lines 482–486 "capture, transfer, eject … must honor each other's active
guards").

## 1. Current state (verified)

**Image.** The appliance is a Pi 5 booting Yocto walnascar from NVMe
(`deploy/yocto/README.md:1-20`, `kas-segno-rpi5.yml`). systemd is the init
(`kas-segno-common.yml` `INIT_MANAGER = "systemd"`), so `systemd-udevd` is
present. Persistent data is `/data` (`data.mount`); the app runs as root with
`HOME=/data` (`segno-kiosk-launch:16-21`) and `segno.service` has
`RequiresMountsFor=/data`. Nothing in the image mounts removable media: no
udisks, no automount rule, no `/media` or `/run/media`. The kernel
(`linux-raspberrypi` 6.12, `bcm2712_defconfig`) has `USB_STORAGE=y`,
`USB_UAS=y`, `VFAT_FS=y`, `EXT4_FS=y`, `EXFAT_FS=m`, `NTFS3_FS=m`,
`NLS_CODEPAGE_437=y`, `FAT_DEFAULT_IOCHARSET="ascii"`, and no HFS+. meta-raspberrypi
installs every kernel module (`rpi-base.inc` `MACHINE_EXTRA_RRECOMMENDS +=
"kernel-modules …"`), so `exfat.ko` and `ntfs3.ko` land in the image unless a
trim removes them; Part 1 pins that with a manifest check rather than assuming
it. Userland block tools: busybox `mount`/`umount`/`blkid`; `udevadm` from
systemd; `util-linux-chrt` only (`segno-kiosk-image.bb` `IMAGE_INSTALL`).

**Existing helper pattern.** Privileged work is a POSIX-sh helper under
`/usr/bin` with JSON on stdout and detail on stderr (`segno-wifi-ctl:1-13`,
`segno-brightness-ctl:1-9`, `segno-touch-ctl:1-22`, `segno-update-ctl:1-50`),
installed by `segno-bundle.bb` (`SRC_URI`, `SYSTEMD_SERVICE:${PN}` line 126,
`FILES:${PN}` lines 146–163, `do_install` lines 240–275) and tested by a
`test/run_<name>_tests.sh` that stubs the system commands on `PATH` and asserts
transcripts and outputs (`run_mark_good_tests.sh`, `run_bt_ctl_tests.sh`),
each listed explicitly in the `appliance-shell-tests` job
(`.github/workflows/main.yaml:395-442`). A root-side unit watching a path the
app writes already exists: `segno-touch-apply.path` (`PathChanged=` on
`/data/touch/calibration`) runs `segno-touch-apply.service`.

**The fork constraint.** The app drives helpers with `Process.run`/`Process.start`
(`lib/update/appliance/system_appliance_env.dart:62,91,104`,
`packages/wifi_client/lib/src/system_wifi_client.dart:67`). On the appliance
each one is a `fork()` of a 1.7 GB process, which holds `mmap_lock` for
milliseconds and stalls the real-time audio thread; every audible dropout on
the Pi 5 bench landed within 3 ms of a fork (#806; the record is in
`segno_engine_api.h:2960-2978` and
`lib/performance/cubit/performance_recorder_cubit.dart:42-50`). Engine
sources cited by bare name in this document live under
`packages/segno_engine/src/core/` (`perf_drain.c`, `segno_engine_api.h`,
`engine_snapshot.c`, `engine_private.h`). (The same record is also in
`lib/performance/cubit/performance_recorder_cubit.dart:42-50`). The `df`
poll was moved into the engine as `le_perf_volume_free_bytes` (statvfs,
`perf_drain.c:126-150`, Dart `native_audio_engine.dart:2266`). The remaining
fork in storage code is `LocalConsoleFactsClient._dfDiskSpace`
(`packages/console_facts_client/lib/src/local_console_facts_client.dart:135-146`),
run when the Storage face opens (`storage_system_tab.dart:37-39`). A storage
service that polled a helper for drive state would reintroduce the fault at a
steady cadence; detection must not fork the app, and eject should not either,
because it is pressed while loops play.

**App storage surfaces today.** `ConsoleFactsClient`
(`packages/console_facts_client/lib/src/console_facts_client.dart:12-38`)
answers `storage()` (internal breakdown via `df` plus directory walks),
`facts()`, `deleteCapturesOlderThan`, and two placeholders that no real client
implements: `exportDestination()` returns `''` and `exportEverything` is a
no-op (`local_console_facts_client.dart:116-121`, the unsupported client
likewise). The Storage face (`lib/system/view/storage_system_tab.dart`, 208
lines) draws five usage rows, a delete-captures action and an "Export
everything to USB" row that is never tappable on the appliance (`:62-63`,
`:151-166`); its cubit `ConsoleFactsCubit` (`lib/system/cubit/console_facts_cubit.dart:42,115-126`)
carries the placeholders. The face is hosted by the settings tray
(`lib/system/view/system_tray_panel.dart:46`), which the owner has retired;
E3-4 re-homes Storage as one of the ten Settings destinations.

**Recorder.** `PerformanceRepository` arms into `{exportsRoot}/perf-…`
(`packages/performance_repository/lib/src/performance_repository.dart:60,284-310`),
where `exportsRoot` is fixed at construction to `defaultExportDirectory`
(`lib/session_directory.dart:15-21`, `lib/app/run_segno.dart:97-100`). The
cubit samples free space every 20 ticks through the engine statvfs
(`performance_recorder_cubit.dart:97-131,400-470`), refuses to arm under
500 MB (`lowDiskThresholdBytes`), stops at a computed floor, and treats the
drain's self-stop (`perf_drain.c:706-709`, published as
`snapshot.perfStopped`, `engine_snapshot.c:392`) as `diskFull`. The drain
itself never retries a short write and marks the sidecar `stopped_early:
disk_full` or `device_changed` (`perf_drain.c:1268-1276`); there is no
removable-volume reason (`performance_recorder_state.dart:5-17`). Nothing
fsyncs (`perf_drain.c:485-500`), which matters for yank-safety of a FAT
volume.

**Power.** `powerOffSnapshotOf` (`lib/appliance/power_off/power_off_gate.dart:47-69`)
refuses shutdown for a take in flight; it has no notion of a transfer or an
eject in progress, which §7.8 requires ("Transfers/eject guard it").

**Gap inventory.** E9-5 is "Partial. Internal breakdown and free space only;
no removable-drive service. Prerequisite for every USB item" (L, HW), and the
dependency chain is E9-5 → E7-7, E7-11 → E7-12, E7-13, E5-5, E9-7, E7-14.

## 2. Design

### 2.1 Ownership and data flow

```
 udev (ID_BUS=usb, block, filesystem)            app (Dart, no fork)
   │ SYSTEMD_WANTS=segno-usb-mount@sdX1              │
   ▼                                                  │ inotify (Directory.watch)
 segno-usb-mount@.service ── segno-usb-ctl attach ──► /run/segno/usb/volumes/<gen>.json
   BindsTo=dev-sdX1.device   ── segno-usb-ctl detach ──► (file removed)
                                                      ▲
 segno-usb-eject.path  (PathExistsGlob)               │ eject request = app writes
   └─ segno-usb-eject.service ── segno-usb-ctl serve ─┘ /run/segno/usb/requests/<id>
```

- **Detection and mount are the OS's job**, the way udisks does it on a
  desktop but without udisks: a udev rule tags each USB filesystem with
  `SYSTEMD_WANTS=segno-usb-mount@%k.service`; the template unit is
  `BindsTo=dev-%i.device`, so when the device vanishes systemd stops the unit
  and its `ExecStop` cleans up. `RUN+=` is not used for the mount (udev kills
  long RUN programs and they cannot own a mount namespace cleanly).
- **State is files on a tmpfs**, one JSON per volume under
  `/run/segno/usb/volumes/`, written atomically (tmp + `mv`). The app reads the
  directory once and then watches it with `Directory.watch` (inotify; no
  subprocess, no timer). Deletion of the file is the removal signal.
- **Eject is a request file**, not a helper call: the app writes
  `/run/segno/usb/requests/<uuid>.json` containing the volume id and generation;
  `segno-usb-eject.path` (`PathExistsGlob=/run/segno/usb/requests/*.json`, so a
  `.tmp` the app left behind cannot keep re-triggering it) starts the eject
  service, which
  processes and deletes every request and writes the outcome into the volume's
  JSON (`"eject": {"request": "<uuid>", "ok": false, "reason": "busy"}`). One
  watch covers both. This is the `segno-touch-apply.path` pattern turned
  around, and it keeps the app fork-free on the eject path.
- **Identity.** Every attach gets a per-boot monotonic `generation`
  (`/run/segno/usb/.generation`). The volume id the app uses is the
  generation; a replug is a new generation, so no operation started against
  the old one can complete against the new drive (§7.7 "reconnect cannot be
  consumed by an old callback"). The stable identity for "same drive"
  recovery (`ID_SERIAL` + `ID_FS_UUID`) is carried alongside as `fingerprint`
  for E7-11 to match on.
- **Capacity** is statvfs from the engine for both Internal and USB (Part 2
  widens `le_perf_volume_free_bytes` to total + free), so the Storage page and
  the recorder read capacity without a fork. Volume size at attach time also
  goes into the JSON for the "of 32 GB" readout before the first statvfs.
- **Write throughput** is probed once per attach by the helper (16 MiB temp
  file, `fsync`, deleted; skipped on read-only mounts) and recorded as
  `writeBytesPerSecond`. The volume JSON is written **before** the probe with
  `writeBytesPerSecond: null` and rewritten (tmp + `mv`) after it, so a slow
  stick still appears within the attach budget and the rate arrives as a
  second event. Elapsed time comes from `/proc/uptime` (centiseconds; path
  overridable by `SEGNO_USB_UPTIME_FILE`), because busybox `date` has no
  `%N` and coreutils is not in the image. Consumers compare it with their frozen format's byte
  rate (the recorder's verdict and the in-flight stop policy stay in E7-11/12;
  this plan only measures and exposes). Zoom's LiveTrak and most field
  recorders run the same kind of card test.

### 2.2 Mount policy (helper, `segno-usb-ctl attach`)

| udev facts | action | state |
| --- | --- | --- |
| `ID_FS_USAGE != filesystem` (blank, partition table only, LUKS) | no mount | `unsupported`, `fsType` = `ID_FS_TYPE` or `"none"` |
| `vfat` | `mount -t vfat -o rw,nosuid,nodev,noatime,flush,utf8=1,uid=0,gid=0,fmask=0022,dmask=0022` | `mounted` |
| `exfat` | `mount -t exfat -o rw,nosuid,nodev,noatime,uid=0,gid=0,fmask=0022,dmask=0022` (needs `exfat.ko`) | `mounted` |
| `ext4`/`ext3`/`ext2` | `mount -t <fs> -o rw,nosuid,nodev,noatime` | `mounted` |
| `ntfs` | `mount -t ntfs3 -o rw,nosuid,nodev,noatime,uid=0,gid=0` (needs `ntfs3.ko`); dirty volume falls to the ro row | `mounted` |
| any rw mount failure | retry once with the same options and `ro` for `rw` (vfat drops `flush`) | `readOnly` (import allowed, write refused with reason) |
| ro mount failure | nothing mounted | `mountFailed`, `reason` = mount's stderr first line |
| anything else (`hfsplus`, `apfs`, `btrfs`, …) | no mount | `unsupported` |

Every row carries `nosuid,nodev`: the drive is untrusted media (#1186
review). `attach`, `detach` and `serve-requests` hold an exclusive `flock` on
`/run/segno/usb/.lock` (util-linux `flock`, in RDEPENDS) for their whole run:
systemd starts one mount unit per partition in parallel, and without the lock
two attaches read the same generation, one record overwrites the other, and
that volume's mount leaks past detach.

The label in the JSON is `ID_FS_LABEL_ENC` decoded only where its `\xNN`
escapes form valid UTF-8; a byte that does not (an OEM-codepage FAT label,
a Spanish word whose accented letter is the single byte 0xE9) stays as its `\xNN` text, and every byte below 0x20 is
written as `\u00XX`, so the record is always valid UTF-8 JSON. An eject
rewrites only `status` and `eject` in place, so the label survives it byte for
byte. The write probe strips the leading zero from `/proc/uptime`'s
centiseconds before the arithmetic (`08` and `09` are not octal numbers).

Mount point: `/run/media/segno/<generation>-<label>` with the label reduced
to `[A-Za-z0-9._-]`, other bytes replaced by `_`; an empty label falls back to
the kernel name (`SEGNO USB` on `sda1` as generation 1 mounts at
`/run/media/segno/1-SEGNO_USB`). Removed on detach. `flush` on vfat makes the FAT metadata reach the device shortly
after each write, which is what gives a yanked FAT stick a consistent
directory. `utf8=1` is required because the kernel's FAT default charset is
`ascii` and the Spanish UI will produce accented file names; verified on
device in Part 1.

Detach (`ExecStop`): `umount` the mount point, and if that fails because the
device is gone, `umount -l`; remove the mount point; delete the volume JSON.
Eject (`serve-requests`): `sync`, then a **non-lazy** `umount`; `EBUSY` is the
kernel's own refusal and is reported as `busy`. On success the JSON state
becomes `ejected` (the "Safe to remove" screen) and stays until the physical
removal deletes the file. Cancel during eject (pen `SowFm` has Cancel) is
honoured only before the request is served: the app deletes its own request
file, and the helper takes a request by renaming it to `.taking-<id>.json`
before reading it, so the delete and the take cannot both succeed and
`cancelEject` reports which one did. A taken request is past the point of
return, and the next state is either `ejected` or `mounted` plus a failure,
both of which the UI draws truthfully. A request a killed run had taken is
served by the next run (it holds the lock, so no other run is on it).

### 2.3 Domain model (`packages/storage_repository`)

```dart
enum RemovableVolumeStatus { mounted, readOnly, unsupported, mountFailed, ejecting, ejected }

class RemovableVolume { int generation; String fingerprint; String label;
  String fsType; String? mountPoint; int sizeBytes; RemovableVolumeStatus status;
  int? writeBytesPerSecond; String? failureReason; }

sealed class StorageDestination { const factory internal(); const factory removable(int generation); }

class VolumeSpace { int totalBytes; int freeBytes; }     // from the engine statvfs

class WriteLease { StorageDestination target; String purpose; }  // held by any writer

sealed class StorageFailure implements Exception { full, readOnly, volumeLost(generation), unsupported, io(reason) }
```

`StorageRepository` owns: the volume list stream (fed by the client), the
lease registry (`acquire(destination, purpose)` → `WriteLease`, `release`),
`eject(generation)` which refuses with `EjectRefused(holders)` while a lease on
that volume is held and otherwise writes the request and completes on the
state change (timeout → `EjectFailed(timeout)`), `space(destination)`,
`recordingTimeRemaining(destination, bytesPerSecond)` (null when space is
unknown — "unknown capacity cannot claim available time", §6.7),
`copyFile(source, destination, relativePath, onConflict)` (write to
`<name>.part`, `fsync`, rename; delete the part on any failure; `Keep both`
appends ` (2)`; typed failures per the table in §4), and `internalReserveBytes
= 1 GB` (decimal: §6.7's "1 GB reserve", pen `BQc2H` "Internal storage · 1.0 GB
reserved"; the pen's 64.0 GB free at 288000 B/s is 60 hr 45 min only with a
decimal reserve). When a
volume's JSON disappears, every lease on it completes with
`StorageFailure.volumeLost(generation)` so the holder (recorder, export,
backup) can stop at a complete frame and keep what it has.

### 2.4 App surfaces

- **Storage page** (pen 31) replaces the body of `StorageSystemTab`: an
  Internal card (`64.0 GB free` / `of 128 GB`, `Sessions and audio`, `Open
  library`, the recording-remaining line `60 hr 45 min recording remaining ·
  estimated` with `48 kHz · 24-bit · Stereo`, the reserve note), one USB card
  per volume (`24.2 GB free` / `of 32 GB`, label, `Browse`, `Eject`), and the
  five variants: `Ejecting…` with Cancel, `Safe to remove` with "Your internal
  audio stays available.", `Not connected` with "Connect a drive to import or
  export audio.", `Eject failed` with "Could not eject. The drive is still
  connected. Try again.", and `Low internal space` ("Internal storage is
  nearly full.", `No recording space`) when free < reserve. `Open library`
  opens the full-screen Library (#1178). A USB card has no `Browse` until the
  Library has a USB view to open at: a Browse that opened Internal would
  show the wrong files as the drive's (#1217 review). It comes back with
  that view.
- **Destination picker** (pen 48 `cH9UX` "Save to · Internal | USB drive",
  pen 20 `m5XyVv` "Connect a USB drive / Your recording stays in Internal. /
  Cancel · Try again"): one shared widget, `StorageDestinationPicker`, that
  lists Internal and each mounted volume by label, disables read-only or
  unsupported volumes with the reason, and shows the connect sheet when USB
  is chosen with nothing mounted. Library, Recorder and backup all use it.
- **Guards.** `powerOffSnapshotOf` gains `transferInFlight` (any lease held
  or an eject in progress) → `refuse` (§7.8). Eject refuses while a lease is
  held (§7.7 "Eject is unavailable during USB work") and the button is
  disabled with the holder's purpose as subtitle.

### 2.5 What is removed

`ConsoleFactsClient.exportDestination` and `exportEverything`, their three
implementations, `ConsoleFactsState.exportDestination`,
`ConsoleFactsCubit.exportEverything`, the `system_storage_export` row and the
`storageExportTitle`/`storageNoUsb` strings (in both `app_en.arb` and
`app_es.arb`). The files touched beyond the three implementations:
`lib/system/cubit/console_facts_state.dart` (`exportDestination` field and
`copyWith`), `packages/console_facts_client/lib/src/fake_console_facts_client.dart`
(`exportVolumeMounted`), `packages/console_facts_client/lib/src/unsupported_console_facts_client.dart`,
`packages/console_facts_client/test/console_facts_client_test.dart`,
`test/system/cubit/console_facts_cubit_test.dart` (8 references) and
`test/system/view/system_faces_test.dart:648-703`. They never did anything on any
real client, the accepted design has no "export everything" action (appliance
backup, pen 44, is E7-15 on this service), and AGENTS.md says remove obsolete
paths rather than keep them. No install changes behaviour: the row was never
tappable on the appliance.

## 3. Standing-rule calls taken (no owner question needed)

1. **Preserve installs.** Internal storage keeps its path and layout; the
   recorder's 500 MB arm refusal is untouched here (E7-12 aligns it with the
   1 GB reserve). Only the Storage page's *estimate* uses the reserve.
2. **Fail safe, audio keeps running.** No fork on detection or eject; a lost
   volume fails leases, never the engine; mount failures leave the drive
   unmounted and the app running.
3. **No silent changes.** Every state is drawn (unsupported, read-only, failed,
   ejected, lost) with the pen copy; the write probe is logged to stderr and
   recorded in the JSON.
4. **Consolidate.** One statvfs path for Internal and USB (the `df` fork goes);
   one picker for three consumers; one lease registry that power-off, eject
   and the recorder read.
5. **Drop uncertain native state with a notice.** A volume whose mount cannot be
   trusted (dirty NTFS, failed rw) is read-only or unmounted and says why.

Decisions the owner may override, taken on defaults:

- Write probe on every attach (16 MiB written and deleted on the user's drive).
- NTFS mounted read-write through `ntfs3`, with read-only fallback.
- One USB card per mounted volume on the Storage page (the pen shows one; a
  multi-partition stick shows two).
- Mount point root `/run/media/segno/` (tmpfs; udisks convention).

## 4. Fault matrix

| Fault | Where it is detected | Behaviour | Surface |
| --- | --- | --- | --- |
| Unplug while idle | device unit stops → `detach` deletes JSON | volume disappears; Storage page shows `Not connected` | pen `t5SpNf`, 18/06 `jsmae` |
| Unplug mid-write (export/backup copy) | `copyFile` gets EIO/ENOENT; lease completes `volumeLost` | `.part` is unreachable, nothing on Internal changed; failure typed | pen 34 `vzH8N` "USB drive disconnected. Nothing was changed." |
| Unplug mid-record (direct USB) | lease `volumeLost`; drain self-stops on the failed write (`perf_drain.c:1434`) | recorder stops at the last complete frame, reason `volumeLost`, loops keep playing | pen 48 `HWH3p` (held-take recovery itself is E7-11) |
| Full disk | statvfs floor crossed, or ENOSPC on write | copy: `StorageFailure.full`, part deleted, source kept; record: existing floor path | pen 20 `M734SS` "Not enough space. Free up storage and try again."; pen 47 `yzmtU` |
| Slow writes | `writeBytesPerSecond` at attach; in-flight overrun counters (`perfOverruns`, zero-fill) | picker shows the measured rate; a rate under the consumer's requirement disables the choice with the reason; in-flight stop rule is E7-12 | pen 48 `cH9UX` destination row |
| Read-only (write-protect switch, dirty NTFS, failed rw mount) | `attach` ro fallback | `readOnly`; import allowed; export/record/backup refuse with reason before starting | picker row subtitle |
| Wrong or no filesystem | udev `ID_FS_USAGE`/`ID_FS_TYPE`; mount failure | `unsupported`/`mountFailed` with the type; nothing mounted | Storage page USB card subtitle: "`HFS+` isn't supported. Format the drive as exFAT." |
| Eject while a transfer runs | lease registry | refused before any request is written; button disabled | pen `BQc2H` Eject disabled |
| Eject fails (`EBUSY` from a process outside the app, I/O error) | `serve-requests` | state stays `mounted`, `eject.ok=false`; drive still usable | pen `PQOpP` |
| Replug during an operation | new generation | the operation's `volumeLost` stands; the new volume is a new entry | — |
| Eject-service missing / old image | client `isSupported` false (no `/run/segno/usb`) | USB features unavailable with a reason; Internal unaffected | Storage page `Not connected` + no picker USB row |

## 5. Parts

Each part is independently mergeable and leaves the app working. Sizes are
production lines (tests excluded).

### Part 1: image side — udev rule, mount unit, helper, eject path unit (about 420 production lines, `deploy/yocto`)

Files, all under `deploy/yocto/meta-segno/recipes-segno/segno-bundle/`:

- `files/98-segno-usb-storage.rules`:
  `ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition|disk",
  ENV{ID_FS_USAGE}=="filesystem", KERNEL!="nvme*|mmcblk*", TAG+="systemd",
  ENV{SYSTEMD_WANTS}+="segno-usb-mount@%k.service"`. A second rule with
  `ENV{DEVTYPE}=="disk"`, `ENV{ID_FS_USAGE}!="filesystem"`,
  `ENV{ID_PART_TABLE_TYPE}==""` and `ATTR{size}!="0"` (a blank stick, whole
  device only) also wants the unit so the app can say "not formatted". Both
  act on `change` as well as `add`: a superfloppy card inserted into a reader
  that is already plugged in raises `change` on the reader's `sdX`, and
  systemd starts the units a `change` adds to `SYSTEMD_WANTS`. A third rule
  sets `ENV{SYSTEMD_READY}="0"` on a USB disk of size 0 (an empty reader
  slot), so pulling that card stops its mount unit and the next card is a
  fresh plug.
- `files/segno-usb-mount@.service`: `BindsTo=dev-%i.device`,
  `After=dev-%i.device`, `Type=oneshot`, `RemainAfterExit=yes`,
  `ExecStart=/usr/bin/segno-usb-ctl attach %I`,
  `ExecStop=/usr/bin/segno-usb-ctl detach %I`. Not in `SYSTEMD_SERVICE` (a
  template is started by udev, never enabled). `detach` exits 0 when nothing
  is mounted any more (an ejected volume being unplugged), so the unit never
  enters the failed state.
- `files/segno.service` gains a comment stating that the app must see the
  root mount namespace (no `PrivateMounts`, `ProtectSystem`, `PrivateTmp` or
  `MountFlags`), because the USB volumes are mounted by `segno-usb-mount@`
  under `/run/media/segno` and read by the app at those paths.
- `files/segno-usb-eject.path` (`PathExistsGlob=/run/segno/usb/requests/*.json`)
  and `files/segno-usb-eject.service` (`ExecStart=/usr/bin/segno-usb-ctl
  serve-requests`); both enabled.
- `files/segno-usb-ctl` (POSIX sh, like `segno-wifi-ctl`): verbs `attach
  <kname>`, `detach <kname>`, `serve-requests`, `status` (prints the volume
  array), `probe <mountpoint>`. Every path and tool is overridable by
  environment (`SEGNO_USB_RUN_DIR`, `SEGNO_USB_MEDIA_DIR`, `SEGNO_USB_SYSFS`,
  `SEGNO_USB_PROBE_BYTES`, `SEGNO_USB_UPTIME_FILE`) the way `segno-update-ctl`
  does (`segno-update-ctl:43-56`), so the tests never touch `/run`, `/sys` or
  `/proc`. Temporary files are dotfiles beside their target
  (`volumes/.<gen>.json.tmp`, `requests/.<uuid>.json.tmp`) renamed into
  place; `serve-requests` ignores the app's dotfiles (it serves only its own
  `.taking-` leftovers). Volume JSON schema (one object per
  file, keys in this order so the test oracle is literal): `generation`,
  `kname`, `fingerprint`, `label`, `fsType`, `mountPoint`, `sizeBytes`,
  `status`, `readOnly`, `writeBytesPerSecond`, `failureReason`, `eject`.
- `.github/cspell.json`: add to `words`: exfat, ntfs, ntfs3, vfat, udev,
  blkid, statvfs, kname, fmask, dmask, superfloppy, udisks, hfsplus, apfs,
  btrfs, LUKS, inotify, EROFS, exfatprogs, fsync, umount (plus the pen ids
  and errno names this document uses; the `spell-check` job runs on every
  `.md`).
- `files/segno-runtime.conf` gains `d /run/segno/usb 0755 root root -`,
  `d /run/segno/usb/volumes`, `d /run/segno/usb/requests`, `d /run/media/segno`.
- `segno-bundle.bb`: `SRC_URI`, `FILES`, `do_install`, `SYSTEMD_SERVICE` (the
  `.path` and eject service), udev rule into `${sysconfdir}/udev/rules.d/`,
  `RDEPENDS += "util-linux-mount util-linux-umount util-linux-blkid util-linux-flock"` (busybox
  `mount` lacks `-o flush`-safe option passing for exfat and prints a
  different error vocabulary; the helper parses util-linux's; `flock`
  runs the helper's verbs one at a time). `exfatprogs`
  is **not** added (no fsck on user drives from an appliance).
- `segno-kiosk-image.bb`: no change expected; the part's success criteria
  include a manifest check that `kernel-module-exfat` and
  `kernel-module-ntfs3` are in the image.
- `test/run_usb_ctl_tests.sh`, registered in `.github/workflows/main.yaml`
  next to `run_bt_ctl_tests.sh`.

```success-criteria
GOAL: A USB filesystem plugged into the appliance is mounted by the OS with the right options, described in one JSON file the app can watch, ejected safely on request, and cleaned up on removal, with no process ever started from the app.
SUCCESS CRITERIA:
- attach of a vfat partition (stubbed udevadm/mount/blkid, fake sysfs size 62521344 sectors, a fake uptime file supplying two readings 1.00 s apart) writes volumes/1.json twice: first, before the probe, exactly {"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":"/run/media/segno/1-SEGNO_USB","sizeBytes":32010928128,"status":"mounted","readOnly":false,"writeBytesPerSecond":null,"failureReason":null,"eject":null}; then the same object with "writeBytesPerSecond":16777216; the mount transcript line is `mount -t vfat -o rw,nosuid,nodev,noatime,flush,utf8=1,uid=0,gid=0,fmask=0022,dmask=0022 /dev/sda1 /run/media/segno/1-SEGNO_USB`; a label `Gigs/2026 ñ` mounts at `/run/media/segno/2-Gigs_2026__` and an empty label at `/run/media/segno/3-sdb1`; no file other than `<gen>.json` and `.<gen>.json.tmp` is ever created under volumes/. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- exfat and ntfs use their rows' option strings; an rw mount failure retries once with ro and records status readOnly; a second failure records mountFailed with mount's first stderr line; hfsplus and ID_FS_USAGE=crypto record unsupported with the type and never call mount; a blank disk records fsType "none". | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- A second attach gets generation 2 even for the same fingerprint; detach of a mounted volume runs sync, umount, then umount -l only when the first umount fails, removes the mount point and deletes the JSON; detach of a volume already `ejected` (both umounts fail "not mounted") still removes the mount point, deletes the JSON and exits 0. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- serve-requests ignores dotfiles under requests/ (a `.x.json.tmp` is neither served nor deleted). | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- Three attaches run in parallel, ten rounds, always end with generations 1, 2 and 3 and one record each; uptimes 100.08 → 101.09 and 100.50 → 101.09 give 101 cs and 59 cs; a 0xE9 label byte stays `\xe9` text and control bytes are `\u00XX`, and every record decodes as strict UTF-8 JSON; an eject changes only `status` and `eject`. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- No unit under `files/segno-usb-*` and not `files/segno.service` contains `PrivateMounts`, `ProtectSystem`, `PrivateTmp` or `MountFlags` (the test greps them), and `segno.service` carries the comment saying why. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- serve-requests with a request naming generation 1 runs sync then umount (not -l); on success the JSON reads status "ejected" and "eject":{"request":"<id>","ok":true,"reason":null}; on EBUSY it stays "mounted" with "eject":{...,"ok":false,"reason":"busy"}; a request for an unknown generation is deleted and ignored; every request file is gone afterwards. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- The probe is skipped on readOnly (writeBytesPerSecond null), writes SEGNO_USB_PROBE_BYTES bytes to `<mountPoint>/.segno-probe`, fsyncs, deletes the file, and tolerates a write failure (null, not an error). | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- The suite passes under dash as well as bash (the image's /bin/sh is busybox ash). | verify: TEST_SHELL=dash bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh
- The image manifest lists kernel-module-exfat, kernel-module-ntfs3, util-linux-mount, util-linux-umount, util-linux-blkid, util-linux-flock and the three unit files. | verify: grep -E 'kernel-module-(exfat|ntfs3)|util-linux-(mount|umount|blkid|flock)' build/tmp/deploy/images/raspberrypi5/segno-kiosk-image-raspberrypi5.manifest (build output; CI image job)
- HARDWARE: on the Pi 5, a FAT32 stick, an exFAT stick, an NTFS stick and a Mac-formatted stick each produce the expected JSON within 3 s of insertion; a file named `canción.wav` written on a laptop lists with its accent intact on vfat; yanking a mounted stick removes the JSON and leaves no stale entry in /proc/mounts; `systemctl --failed` stays empty across ten plug/unplug cycles. | verify: manual on device, with `journalctl -u 'segno-usb-*'` and `cat /run/segno/usb/volumes/*.json`
NON-GOALS:
- Formatting drives, fsck, exfatprogs, udisks, polkit, any app-side change.
VERIFICATION COMMAND: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh && TEST_SHELL=dash bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh && npx cspell --config .github/cspell.json docs/plan/*.md
```

### Part 2: native volume space (about 90 production lines, engine + bindings; depends on nothing)

Replace `le_perf_volume_free_bytes` (`segno_engine_api.h:2980`,
`perf_drain.c:126-150`) with

```c
/* total and available bytes of the volume holding `path` (statvfs f_blocks /
 * f_bavail × f_frsize; GetDiskFreeSpaceExW on Windows). LE_ERR_INVALID on a
 * NULL/empty path or NULL outputs; LE_ERR_DEVICE when the path cannot be
 * stat'ed. Control thread only; microseconds on a local volume. */
LE_EXPORT int32_t le_volume_space(const char* path, uint64_t* out_total_bytes,
                                  uint64_t* out_free_bytes);
```

The native test `test_perf_volume_free_bytes` (`test_engine_core.c:9279-9296`)
becomes `test_volume_space` with the same argument checks plus the oracle
that `total` equals the test's own `statvfs(".")` `f_blocks * f_frsize`
exactly, `free` is within 64 MiB of its `f_bavail * f_frsize` (a CI disk is
written between the two calls), and `total >= free`. Dart: `AudioEngine.volumeFreeBytes`
(`audio_engine.dart:1436`) becomes `VolumeSpace? volumeSpace(String path)`;
`native_audio_engine.dart:2266`, `mock_audio_engine.dart:1645`,
`PerformanceRepository.freeSpaceBytes` (`performance_repository.dart:193`,
now `volumeSpace`) and the recorder cubit's `_freeSpaceBytes` injection
(`performance_recorder_cubit.dart:66-80`) follow. `LocalConsoleFactsClient`
takes the engine-backed reader from the composition root
(`run_segno.dart:155-157`) and `_dfDiskSpace`/`parseDfKP` are deleted (the
`df` fork, `local_console_facts_client.dart:135-169`); `DiskSpace` is
replaced by the shared `VolumeSpace` type living in `segno_engine`'s public
API so `console_facts_client` keeps no engine dependency (the root passes a
`Future<VolumeSpace?> Function(String)`; the pure-Dart package declares its
own two-field value type and the root adapts). Regenerate bindings and
`dart format` (ffigen drift, `docs/PROGRESS.md:506-512`); run
`check_ffi_symbols.sh` on the built library.

```success-criteria
GOAL: Total and free capacity of any path are one statvfs call away on every platform, and no storage code forks the app.
SUCCESS CRITERIA:
- le_volume_space rejects NULL/empty path and NULL outputs with LE_ERR_INVALID, a missing path with LE_ERR_DEVICE, and on "." returns total equal to the test's own statvfs f_blocks*f_frsize exactly, free within 64 MiB of its f_bavail*f_frsize, and total >= free. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- `grep -rn "Process.run('df'" packages lib` returns nothing; `parseDfKP` and `_dfDiskSpace` are gone; console_facts_client tests cover the injected reader returning null (unknown) and a value. | verify: (cd packages/console_facts_client && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/performance test/system
- Bindings regenerated, formatted, and every exported symbol resolves in the built library. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated && git diff --stat --exit-code lib/src/generated) ; bash packages/segno_engine/tool/check_ffi_symbols.sh <built libsegno_engine>
- Analyzer, Bloc lint and formatting clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- Any UI; any change to the recorder's thresholds.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages && npx cspell --config .github/cspell.json docs/plan/*.md
```

### Part 3: `packages/usb_storage_client` (about 330 production lines; depends on Part 1's file contract, not on its merge)

Pure Dart, modelled on `wifi_client` (`pubspec.yaml` deps `equatable`, `meta`;
`test` dev dep; `analysis_options.yaml` from `very_good_analysis`). Public
API:

```dart
abstract interface class UsbStorageClient {
  bool get isSupported;                       // Linux and the run dir exists
  Stream<List<RemovableVolumeRecord>> get volumes;  // replays current list first
  Future<String> requestEject(int generation);     // returns the request id
  Future<bool> cancelEject(String requestId);      // deletes an unserved request; false once taken
}
```

`LinuxUsbStorageClient(runDir: '/run/segno/usb')` lists `volumes/` once,
parses each JSON (malformed or half-written files are skipped and logged,
never thrown), then `Directory.watch` on `volumes/` re-reads the touched file
on create/modify/move and drops it on delete; names not matching
`^[0-9]+\.json$` (the helper's `.<gen>.json.tmp` dotfiles) are ignored, and a
`FileSystemEvent` burst is coalesced per event-loop turn so one attach
produces one list. Requests are
written as `<uuid>.json.tmp` then renamed into `requests/`.
`FakeUsbStorageClient` (under `SEGNO_FAKE_RADIOS`, the existing desktop
define, `create_console_facts_client.dart:15`) exposes `attach(...)`,
`detach(generation)` and `settleEject(generation, ok: , reason: )` so the
app and the widget tests drive every state. `UnsupportedUsbStorageClient`
reports `isSupported == false` and an empty list. `createUsbStorageClient()`
mirrors `createWifiClient()` (`system_wifi_client.dart:95-103`). Root
`pubspec.yaml` adds the path dependency; `main.yaml` gets a
`usb-storage-client` job on `dart_package.yml` with `min_coverage: 100` (the
`daw_export` shape, `main.yaml:43-47`).

```success-criteria
GOAL: The app sees the OS's view of removable volumes as a replayed stream with no polling and no subprocess, and can file and withdraw an eject request.
SUCCESS CRITERIA:
- With a temp run dir seeded with 1.json and 2.json the first event lists both parsed records; writing .3.json.tmp then renaming to 3.json emits one list of three; a `.3.json.tmp` create on its own emits nothing; deleting 2.json emits a list without it; a file containing `{` is skipped and the stream stays alive. | verify: (cd packages/usb_storage_client && /Users/Tomas/development/flutter/bin/flutter test)
- requestEject(1) leaves exactly one file in requests/ whose contents are {"generation":1,"request":"<returned id>"} and no .tmp; cancelEject deletes it; cancel of an already-served (missing) request is a no-op. | verify: (cd packages/usb_storage_client && /Users/Tomas/development/flutter/bin/flutter test)
- isSupported is false when the run dir is missing and the stream then completes with one empty list; the fake client replays attach/detach/settleEject deterministically. | verify: (cd packages/usb_storage_client && /Users/Tomas/development/flutter/bin/flutter test)
- No `Process.` import anywhere in the package; 100% coverage. | verify: grep -rn 'Process\.' packages/usb_storage_client/lib ; (cd packages/usb_storage_client && /Users/Tomas/development/flutter/bin/flutter test --coverage)
- Analyzer, formatting clean. | verify: dart analyze --fatal-infos packages/usb_storage_client
NON-GOALS:
- Capacity, leases, eject policy, any widget.
VERIFICATION COMMAND: (cd packages/usb_storage_client && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos && npx cspell --config .github/cspell.json docs/plan/*.md
```

### Part 4: `packages/storage_repository` (about 520 production lines; depends on Parts 2 and 3)

The domain owner from §2.3. Constructor takes the `UsbStorageClient`, the
Internal roots (`sessionsRoot`, `exportsRoot` — the same functions the root
already passes to the repositories, `run_segno.dart:93-100`), the
`volumeSpace` reader, and a clock. Behaviour:

- `volumes` stream maps records to `RemovableVolume`; a record whose status
  is `ejected` is kept until deletion so "Safe to remove" can be drawn.
- `acquire(destination, purpose)` returns a `WriteLease`; refused with
  `StorageFailure.readOnly`/`unsupported` for a volume that cannot be
  written, `volumeLost` for a generation no longer present.
- `eject(generation)`: throws `EjectRefused(holders)` while any lease on that
  generation is held; otherwise files the request, emits `ejecting` in its
  own `ejectPhase` stream and completes `EjectOutcome.safeToRemove` on
  status `ejected`, `EjectOutcome.failed(reason)` on an `eject.ok == false`
  record, `EjectOutcome.failed('timeout')` after 20 s (cancelling the request
  file). A request the helper has taken is waited on for 2 min more; past
  that the eject completes `failed('stillEjecting')` and the drive keeps
  reading `ejecting` (no lease, shutdown waits) until the helper answers or
  the drive is pulled. `cancelEject()` before service completes
  `EjectOutcome.cancelled` and returns true; once taken it returns false.
  Every lease on a volume fails `volumeLost` as soon as its status leaves
  `mounted` (ejected by anyone), not only when its record vanishes.
- `space(destination)` and `recordingTimeRemaining(destination,
  bytesPerSecond)`: Internal subtracts `internalReserveBytes`; null when the
  reader returns null.
- `copyFile(sourcePath, destination, relativePath, {ConflictPolicy})` with
  a hidden part of the copy's own, fsync, a rename that never replaces
  (`le_fs_rename_noreplace` through `StorageIo`; an exclusive-create claim
  where the filesystem cannot refuse a replacement), then `le_fs_sync_dir` on
  the directory and every parent the copy created, a refused sync failing
  the copy as `io`; `ConflictPolicy.ask` throws
  `NameConflict(existingPath)` before writing; `keepBoth` picks ` (2)`,
  ` (3)`…; `replace` renames over. ENOSPC → `full`; EROFS → `readOnly`;
  ENOENT/EIO on a removable destination whose record goes within the 10 s
  grace → `volumeLost`; a source that cannot be read → `io` at once. A lease
  is held for the copy's duration. No recording time is offered on a
  read-only volume or one being ejected.
- `lowInternalSpace` getter: Internal free < `internalReserveBytes`.

Tests use `FakeUsbStorageClient`, temp directories, and an injected
`FileSystem`-style write hook that raises `FileSystemException` with OS error
codes 28 (ENOSPC), 30 (EROFS) and 5 (EIO) to prove the typed mapping without
filling a disk. `main.yaml` gets a `storage-repository` job
(`flutter_package.yml`, `min_coverage: 100`, raise-only).

```success-criteria
GOAL: One owner answers where a write may go, how much fits, who is writing, and whether a drive may be ejected, and every removable fault reaches its caller as a typed failure that left existing content intact.
SUCCESS CRITERIA:
- eject with a held lease throws EjectRefused naming the purpose and writes no request; after release, eject files one request, emits ejecting, and completes safeToRemove when the fake settles status ejected, or failed('busy') when it settles ok:false; a 20 s silence completes failed('timeout') and the request is cancelled. | verify: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test)
- detach of a generation with two leases completes both with volumeLost(generation); a later acquire on that generation is refused the same way; a replug is generation+1 and acquires normally. | verify: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test)
- copyFile writes <name>.part first and the destination only after a successful rename; with ENOSPC injected the result is StorageFailure.full, no .part remains, the source is byte-identical; EROFS → readOnly; a record deleted mid-copy → volumeLost; ask/keepBoth/replace behave as specified with a pre-existing file. | verify: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test)
- recordingTimeRemaining(internal, 288000) with total 128 GB and free 64 GB equals Duration(seconds: (64 GB - 1 GB) ~/ 288000), 60 hr 45 min 50 s, exactly; a null reader yields null; a removable destination applies no reserve. | verify: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test)
- No Process import; coverage 100%; analyzer and formatting clean. | verify: grep -rn 'Process\.' packages/storage_repository/lib ; (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos packages/storage_repository
NON-GOALS:
- Widgets, l10n, recorder wiring, directory listing or browsing (the Library plan owns reading a volume's contents).
VERIFICATION COMMAND: (cd packages/storage_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos && npx cspell --config .github/cspell.json docs/plan/*.md
```

### Part 5: Storage page and guards (about 450 production lines, `lib/`; depends on Part 4)

- `lib/storage/cubit/storage_cubit.dart` + state: volumes, Internal and
  per-volume `VolumeSpace`, `ejectPhase`, `lowInternalSpace`, the current
  recording format's byte rate (from `AudioSetup`/output settings, read-only)
  for the remaining-time line. Methods return `void`/`Future<void>` (Bloc
  lint). Provided app-wide in `lib/app/view/app.dart` beside
  `ConsoleFactsCubit` (`app.dart:593-603`), non-lazy, because the power gate
  (and, from Part 6, the picker) read it outside the Storage page. statvfs
  cadence: the cubit reads `space()` on page open, on every volume-list
  event, and on a 5 s timer only while the Storage page is mounted
  (`startWatching`/`stopWatching` from the page's `initState`/`dispose`); there
  is no app-wide timer.
- `lib/storage/view/storage_page.dart` replaces the body of
  `StorageSystemTab` (keep the file and key `system_storage_tab` so the tray
  host and `system_faces_test.dart:616` keep working until E3-4/E3-5): the
  cards and six variants of §2.4, with keys `storage_internal_card`,
  `storage_usb_card_<generation>`, `storage_eject`, `storage_eject_cancel`,
  `storage_open_library`, `storage_low_space_banner`. The internal breakdown
  rows and the delete-captures action stay (accepted appliance
  housekeeping), except the breakdown's `Free` row: the Internal card
  carries free space, read every few seconds, and a second figure read once
  on open would disagree with it (#1217 review).
- Pen write-backs pending (section 31 draws six tiles; the page draws these
  further states, which the pen should gain as tiles or `c/` notes, and
  which this branch does not write itself):
  - read-only drive: `<label> · read-only`, Eject only;
  - drive in use: `<label> · in use for <purpose>`, Eject disabled; the
    purposes are `recording`, `copying files`, `export`, `backup`, each
    once, joined with a comma;
  - unsupported filesystem (`<fs> isn't supported. Format the drive as
    exFAT.`), unformatted (`This drive isn't formatted. Format it as
    exFAT.`), could not be opened (`This drive could not be opened.`), each
    with no actions;
  - unnamed drive (`Unnamed drive`) and capacity unavailable (`Capacity
    unavailable`, `Remaining time unavailable`);
  - Cancel after the helper has taken the eject: `Ejecting…` without
    Cancel, and `Already ejecting. Wait for it to finish.` under the card;
  - a taken eject unanswered after 2 minutes: the card stays `Ejecting…`
    (not `Could not eject`) until the helper answers or the drive is pulled;
  - no `Browse` on a USB card (above);
  - host and scale: the cards head the System tray's Storage tab at the
    tray's type scale with the pen's proportions, and Eject is the app's
    solid accent at weight 700.
- `powerOffSnapshotOf` gains `transferInFlight`, read from
  `StorageRepository.transferInFlight` at the press (a lease can be taken
  between two of the cubit's capacity reads; `power_off_gate.dart:47-69`, host
  `power_off_host.dart:67-73`); `powerOffGate` returns `refuse` for it. The
  refuse dialog says "Wait for the transfer" rather than the take's "Stop
  the take first" when only a transfer is in flight.
- Removals of §2.5 and their tests
  (`test/system/view/system_faces_test.dart:648-703` export cases are
  replaced by Storage page cases).
- l10n: new `storage*`/`destination*` keys in `lib/l10n/arb/app_en.arb`
  (template; `app_es.arb` is partial today, 2692 vs 6044 lines, so Spanish
  is optional) with the pen copy quoted in §2.4 verbatim.
- Composition: `createUsbStorageClient()` and `StorageRepository(...)` in
  `run_segno.dart` next to `createConsoleFactsClient`
  (`run_segno.dart:149-157`), `RepositoryProvider` in `app.dart:446-471`.

```success-criteria
GOAL: The Storage page shows real Internal and USB capacity and the accepted eject states, and shutdown and eject refuse while a transfer is in flight.
SUCCESS CRITERIA:
- With the fake client: no volume → "Not connected" and "Connect a drive to import or export audio."; a mounted 32 GB volume labelled SEGNO USB with 24.2 GB free → "24.2 GB free", "of 32 GB", Eject enabled and no Browse; tapping Eject → "Ejecting…" with Cancel; settling ejected → "Safe to remove" and "Your internal audio stays available."; settling ok:false → "Could not eject. The drive is still connected. Try again." with Eject enabled again. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage test/system/view/system_faces_test.dart
- Internal 128 GB total, 64 GB free, 48 kHz 24-bit stereo → "60 hr 45 min recording remaining · estimated" and the reserve note; free 0.2 GB → the Low internal space banner, "No recording space"; unknown space → "Remaining time unavailable" and no banner. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage
- While a lease is held the Eject button is disabled with the purpose, in words and once each, as subtitle and the cubit's eject() files nothing (the repository refuses); powerOffGate(snapshot with transferInFlight: true) == refuse. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage test/appliance
- With the Storage page mounted the cubit reads space on open, on each volume event and every 5 s; unmounting the page stops the timer (no further reads in a fake-async window). | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage
- `exportDestination`, `exportEverything`, `storageExportTitle`, `storageNoUsb` and `exportVolumeMounted` no longer exist anywhere. | verify: ! grep -rn -E 'exportDestination|exportEverything|storageExportTitle|storageNoUsb|exportVolumeMounted' lib test packages
- Root coverage floor holds; analyzer, Bloc lint and formatting clean; the Spanish file only loses the removed keys (the two export keys and the breakdown's `Free`) or gains new ones. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages && git diff origin/claude/segno-integration -- lib/l10n/arb/app_es.arb | grep '^-' | grep -v -E '^---|storageExportTitle|storageNoUsb|storageFreeTitle' | wc -l | grep -qx 0
- HARDWARE: on the appliance with loops playing, plug, browse to Storage, eject, see Safe to remove, pull the stick; repeat with a stick that is being written to by an export from the desktop build of Part 6 or a copy started over ssh (`cp` into the mount point) and confirm Eject is refused, then succeeds after the copy ends; no audible dropout on any eject (compare `perfOverruns` in the journal before and after). | verify: manual on device
NON-GOALS:
- Library browsing of a volume, export, backup, the destination picker and the recorder's destination (Part 6), the ten-tile Settings home (E3-4).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages && npx cspell --config .github/cspell.json docs/plan/*.md
```

### Part 6: Destination picker, recorder "Save to" and the removable stop reason (about 530 production lines; depends on Part 5)

- `lib/storage/view/storage_destination_picker.dart`: `StorageDestinationPicker
  ({value, onChanged, requiredBytesPerSecond?})` drawing the pen `Save to`
  pill pair (Internal | each volume label), subtitles for read-only,
  unsupported and "too slow" (when `writeBytesPerSecond` is known and under
  the requirement), and `ConnectUsbSheet` (pen `m5XyVv`) with Cancel and Try
  again (Try again re-reads nothing; it waits for the next volume event with
  the sheet open, so a plug while the sheet is up dismisses it). The recorder
  is its first consumer; Library (#1178) and backup (E7-14) reuse it.
- `PerformanceRepository.arm({chains, String? root})`
  (`performance_repository.dart:284-310`): `root` overrides the constructor's
  `exportsRoot` for this take only; `armedDirectory` stays the truth.
- `PerformanceRecorderCubit`: a `destination` field (default Internal, reset
  to Internal when its volume disappears while idle), `chooseDestination`,
  a lease acquired at arm with purpose `recording` and released at `done`;
  a lease completing with `volumeLost` while armed calls the existing
  `_stopForLowDisk` path with a new `PerformanceStopReason.volumeLost`
  (`performance_recorder_state.dart:5-17`), so the take ends at the last
  complete frame the drain wrote (`perf_drain.c:1434` self-stop) and the
  loops keep playing. `_volumeTooFullToArm`/`_checkLowDisk` read the chosen
  root. The remaining-time readout (pen `cH9UX` "60:45:49 remaining",
  `T8ACW` "Remaining time unavailable") comes from
  `StorageRepository.recordingTimeRemaining(destination, frozenByteRate)`.
- `lib/performance/view/...`: the `Save to` row with
  `StorageDestinationPicker` and `requiredBytesPerSecond` = the frozen format
  rate × 2 (headroom), the destination label while recording (pen `FwjUV`
  "SEGNO USB"), and the interruption copy for `volumeLost` (pen `HWH3p`:
  "Recording interrupted", "USB recording stopped. Reconnect <label> to save
  the recorded parts. Your loops keep playing."). Save recovered audio /
  Discard on a lost volume stay disabled with the reconnect hint: recovering a
  take whose sidecar is on the yanked drive is E7-11 (which must also mirror
  `arm-snapshot.json` and the manifest onto Internal; recorded here as a
  requirement for that plan).

```success-criteria
GOAL: One shared destination picker exists with the recorder as its first consumer; the recorder can be pointed at a mounted USB volume before Start, reports remaining time from that volume, and ends a take truthfully when the volume disappears while loops keep playing.
SUCCESS CRITERIA:
- The picker lists Internal and each mounted volume by label; a readOnly volume is disabled with the read-only reason, an unsupported one with its filesystem; with requiredBytesPerSecond 576000 and writeBytesPerSecond 400000 the row is disabled with the too-slow reason; choosing USB with no volume opens ConnectUsbSheet, Cancel closes it, a fake attach while open closes it and selects the new volume. | verify: /Users/Tomas/development/flutter/bin/flutter test test/storage/view/storage_destination_picker_test.dart
- arm(root: '/tmp/x') creates the bundle under /tmp/x and armedDirectory starts with it; arm() without root uses exportsRoot as before. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- With the fake client and a mounted volume, chooseDestination(removable(1)) then toggleArm arms under that volume's mountPoint with a lease of purpose recording; detaching generation 1 while armed emits Finalizing then Completed with PerformanceRecordStoppedEarly(reason: volumeLost) and no second stop; the lease is gone; the next arm defaults to Internal. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance
- remaining time shows "60:45:50 remaining" for 64 GB free Internal at 288000 B/s after the 1 GB reserve, and "Remaining time unavailable" when the reader returns null; the Save to row is disabled while armed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance/view
- Analyzer, Bloc lint, formatting and the root coverage floor hold. | verify: /Users/Tomas/development/flutter/bin/flutter test --coverage && dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: record directly to an exFAT stick for two minutes with loops playing, Stop, confirm the finalized WAV plays on a laptop; record again and yank the stick at 0:30, confirm the loops did not stop, the interruption screen names the drive, and the laptop sees master.pcm of about 0:30 at the frozen rate; `perfOverruns` and `perfZeroFilledFrames` both stay 0 on a stick whose probe reads above 4 MB/s (see §8 point 4 for what a non-zero reading changes). | verify: manual on device
NON-GOALS:
- Ordered 2 GB parts, same-drive/exact-part recovery, the 1 GB arm threshold change, sidecar mirroring (E7-11/E7-12).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages && npx cspell --config .github/cspell.json docs/plan/*.md
```

## 6. Order and dependencies

```
Part 1 (image)  ──┐
Part 2 (native) ──┼──► Part 4 (storage_repository) ──► Part 5 (page, picker, guards) ──► Part 6 (recorder)
Part 3 (client) ──┘
```

Parts 1, 2 and 3 are independent and can land in any order; Part 3 only needs
the JSON schema from §5 Part 1, which the two test suites pin from both sides
(the helper test's literal JSON is the client test's fixture). Part 4 needs 2
and 3. Part 5 needs 4. Part 6 needs 5. The Library plan (#1178) depends on
Part 4's interface and Part 5's picker; it does not need Part 6.

## 7. Hardware-only

Mount timing and udev property values on real sticks (`ID_BUS`, `ID_SERIAL`
shape, superfloppy sticks without a partition table), `exfat.ko`/`ntfs3.ko`
presence in the shipped image, the vfat `utf8=1` behaviour with the kernel's
`ascii` default, `flush`'s effect on yank consistency, `umount` latency on a
slow stick after a large write (the 20 s eject timeout), the write probe's
cost on a slow stick, and that no eject or attach is audible while loops play.

## 8. Open points (defaults taken; override on the issue)

1. Write probe on every attach: taken. Alternative is a probe only when a
   consumer first asks for a write.
2. NTFS read-write via `ntfs3` with read-only fallback: taken. Alternative is
   always read-only.
3. One Storage card per mounted volume: taken. Alternative is the first volume
   only with a count.
4. vfat `flush` is kept for yank-safety. It makes every FAT write
   near-synchronous, and the capture ring is 2 s (`LE_PERF_CAPTURE_SECONDS`,
   `engine_private.h:162`): a device stall longer than that zero-fills the
   take (#710). If Part 6's hardware check shows `perfZeroFilledFrames > 0`
   on a stick whose probe reads above 4 MB/s, Part 6 drops `flush` from the
   vfat row in Part 1's helper (a one-line change, logged in that part's
   record).
