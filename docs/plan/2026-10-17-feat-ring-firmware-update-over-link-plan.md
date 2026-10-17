---
date: 2026-10-17
topic: ring-firmware-update-over-link
---

<!-- cspell:words XIAO BOOTSEL TBYB ATRANS picotool objcopy bootrom Bootrom PICOBIN varm -->

# Ring carrier firmware updates over the console link — plan

Tracking: [#1342](https://github.com/tomassasovsky/segno/issues/1342).
Brainstorm: [`2026-10-16-ring-firmware-update-over-link-brainstorm-doc.md`](../brainstorm/2026-10-16-ring-firmware-update-over-link-brainstorm-doc.md).
Base: `claude/segno-integration` at 930f79202 (ring link VERSION 3 from #1345).

## Direction (owner, 2026-10-16)

Update the ring XIAO over the existing ring link with the RP2350 bootrom's
A/B partitions and try-before-you-buy (TBYB). No PCB change. One more USB
BOOTSEL session installs the partition table and the first updater-capable
firmware; after that, updates go Pi → console Pico → XIAO. A failed or
interrupted transfer leaves the old firmware booting. The appliance ships the
ring image with a version marker, like the console ELF. Nothing is installed
on the device without the owner's go-ahead.

## Spike result (offline)

Done against arduino-pico 6.0.0 and its bundled picotool 2.0.0:

- The ring build's flash image starts with arduino-pico's 12 KB OTA stage.
  Its block loop at offset 0x124 holds the only `IMAGE_DEF` the bootrom sees
  in the first 4 KB (image type 0x1021: Arm, secure, RP2350). The default
  "2MB (no FS)" layout makes that stage jump straight to the sketch, so it
  never reads flash outside the image.
- Setting `PICOBIN_IMAGE_TYPE_EXE_TBYB_BITS` (0x8000) in that item and then
  running `picotool seal --hash --major M --minor m` appends a final block
  with the TBYB image type, the version, a load map and a SHA-256 hash. The
  last `IMAGE_DEF` in a block loop wins (datasheet §5.1.5.2). This is the
  same result as the SDK's `PICO_CRT0_IMAGE_TYPE_TBYB` plus
  `pico_hash_binary`.
- `explicit_buy()` clears the TBYB bit in flash after a successful trial
  (§5.4.8.4). The bootrom masks that bit when it checks the hash
  (`varm_blocks.c`: "clear tbyb flag so we don't break sig check"), so the
  bought image stays valid.
- A TBYB-flagged image only boots from a flash-update boot of its own
  partition. A USB drag-and-drop install of a TBYB image would be tried and
  then, with no Pi to confirm it, never booted again. So one ELF is sealed
  twice: **with** TBYB for over-the-link updates (`ring_board.bin`) and
  **without** it for the USB install (`ring_board.uf2`).
- `picotool partition create` builds the table offline: A = sectors
  2–129, B = 130–257 (512 KB each), linked as a pair.

Hardware behaviour (trial boot, revert, power cut) still needs the bench;
see Acceptance.

## Design

### Wire protocol

A new **update channel** on the ring UART, in
`firmware/libraries/SegnoRing/src/ring_update.h` (plain C, shared by the
XIAO and the Pi tool). Frames use the ring link's SLIP and CRC-16, factored
into `ring_frame.h`, with first body byte `0xB5` instead of a link version.
The v3 ring-link parser drops them, and they are frozen independently of the
ring-link version, so any future console can update any updater-capable ring.

| Type | Direction | Payload | Meaning |
|---|---|---|---|
| `QUERY` 0x01 | Pi → ring | – | reply with HELLO |
| `BEGIN` 0x02 | Pi → ring | size u32, SHA-256 | start writing the other partition |
| `DATA` 0x03 | Pi → ring | offset u32, 1–1024 bytes | next chunk, in order |
| `COMMIT` 0x04 | Pi → ring | – | check the digest, finish, flash-update reboot |
| `CONFIRM` 0x05 | Pi → ring | – | buy the image on trial |
| `BRIDGE_END` 0x06 | Pi → console | – | the console leaves bridge mode |
| `HELLO` 0x81 | ring → Pi | fw major, fw minor, protocol, flags, partition | frozen |
| `ACK` 0x82 | ring → Pi | for type, status, value u32 | result of BEGIN/DATA/COMMIT/CONFIRM |

### Console Pico (firmware 2.1, pedal-link protocol 10 unchanged)

- New pedal-link message `RING_BRIDGE` (0x12, payload `'R' 'B'`), sent only
  by the boot-time tool, never by the app. The Dart codec does not encode it.
- In bridge mode the console stops HELLO, ring STATE and indicator output,
  copies bytes both ways between the Pi UART and the ring UART, and watches
  the Pi's bytes for a `BRIDGE_END` frame. It leaves on `BRIDGE_END` or after
  5 s without bytes from the Pi, and resumes normal operation.

### Ring XIAO (firmware 1.0, first updater-capable build)

`firmware/ring_board/ring_updater.h`, driven from `ring_board.ino`:

- HELLO at boot and on QUERY: version, update protocol, `TRIAL` while a
  flash-update boot awaits its buy, `NO_TABLE` when flash has no partition
  table.
- `BEGIN`: refuses while on trial or without a table. Takes the target from
  `rom_get_uf2_target_partition` and checks it is not the running partition.
  Erases the target's first sector at once, so an abandoned transfer never
  leaves a bootable block loop behind.
- `DATA`: in order only, stop-and-wait. The first 4 KB is held in RAM and
  written last, at COMMIT; the rest is erased and programmed as it arrives.
  A duplicate of the previous chunk is acknowledged again without writing
  (lost ACK).
- `COMMIT`: compares the SHA-256 of the received stream with `BEGIN`'s,
  programs the first sector, acknowledges, then
  `rom_reboot(FLASH_UPDATE, ...)`.
- `CONFIRM` on trial: `rom_explicit_buy` with a 4 KB work area. Without it,
  the bootrom's 16.7 s watchdog reverts to the previous image.
- The receive buffer grows from 256 to 2048 bytes for 1 KB chunks.

### Pi (`segno-ring-flash`, C, in the segno-console-board recipe)

Runs after `segno-console-flash` and before `segno.service`, oneshot, exits 0
on every failure:

1. Read `/usr/lib/segno/ring-board/version` (`firmware=M.m size=N
   sha256=HEX`) and `ring_board.bin`.
2. Send `RING_BRIDGE`, then QUERY until HELLO (1.5 s). No HELLO: log that
   the ring needs its one USB install, end the bridge, exit.
3. Version matches and not on trial: end the bridge, exit. On trial with the
   wanted version: CONFIRM it.
4. Otherwise, unless three attempts at this version are already recorded in
   `/data/segno/ring-board/attempts`: BEGIN, DATA chunks (1.5 s ACK timeout,
   3 retries each), COMMIT; wait for HELLO from the new image (8 s), CONFIRM,
   wait for HELLO without `TRIAL`; record success in
   `/data/segno/ring-board/last-flashed`.
5. End the bridge.

### Build and ship

- `firmware/ring_board/partition_table.json`; `firmware/ring_board/seal.py`
  (sets TBYB in the first `IMAGE_DEF`, seals both variants with the core's
  picotool, writes `ring_board.bin`, `ring_board.uf2`,
  `partition_table.uf2` and `version`).
- Main CI compiles and seals the XIAO target. Appliance release adds the ring
  files to the `segno-console-board` artifact; the recipe installs them to
  `/usr/lib/segno/ring-board/` and the rootfs check compares their hash.

## Tasks

1. Shared framing and protocol headers; ring-link refactor onto `ring_frame.h`.
2. Ring updater, HELLO, version constants, bigger RX buffer.
3. Console bridge mode, `RING_BRIDGE` in `pedal_link.h`/`.c`, firmware 2.1.
4. `segno-ring-flash` tool, service, recipe changes.
5. Host tests: ring updater against simulated flash and bootrom (resume,
   duplicate chunk, wrong offset, digest mismatch, trial refusal, buy, no
   table); tool engine against the simulated ring end to end; console bridge.
6. Seal script, partition table, CI and appliance-release wiring.
7. Docs: ring and console READMEs (USB install, update path), PROGRESS.

## Acceptance

Verified here: all firmware host suites, both MCU targets compile, seal
produces both variants with the expected blocks, `dart analyze` and
`bloc lint` untouched, shell tests pass.

On the bench (owner go-ahead, after build 177 lands on 192.168.50.124):

- [ ] USB install: partition table, then `ring_board.uf2`; the ring boots
      and the console sees it.
- [ ] Update over the link from the appliance; a second update in a row
      (proves the bought image boots normally after its TBYB flag clears).
- [ ] Interrupt mid-transfer (unplug J1 or cut AUX): the old firmware boots;
      the next boot updates.
- [ ] Withhold CONFIRM (kill the tool after COMMIT): the ring reverts after
      ~17 s.
- [ ] Boot-time cost when the ring is current (expected under 0.5 s).
