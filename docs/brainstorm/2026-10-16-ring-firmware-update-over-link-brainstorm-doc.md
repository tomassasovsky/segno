---
date: 2026-10-16
topic: ring-firmware-update-over-link
---

<!-- cspell:words XIAO BOOTSEL TBYB ATRANS QSPI picotool Seeed Updater LittleFS CCITT SWDCLK bootrom Bootrom memmap Mbaud flashless -->

# Ring carrier firmware updates from the console

Tracking: [#1342](https://github.com/tomassasovsky/segno/issues/1342).
Firmware: [#1081](https://github.com/tomassasovsky/segno/issues/1081) /
[PR #1082](https://github.com/tomassasovsky/segno/pull/1082) (`codex/console-v3-runtime-publication`).
Hardware: [PR #1080](https://github.com/tomassasovsky/segno/pull/1080) (`codex/screen-power-board-1072`).
Harness question: [#987](https://github.com/tomassasovsky/segno/issues/987).

## The question

The V3 ring carrier has its own MCU, a Seeed XIAO RP2350. The console's Pico 2
is reflashed by the Pi over SWD at every boot when its version is wrong
(`segno-console-flash`). The XIAO has no such path. The only way to update it
today is:

1. Turn AUX off and unplug ring J1.
2. Connect a USB cable to the XIAO, hold BOOT, and copy the UF2.
3. Remove USB, reconnect J1, restore AUX.

Once the ring sits inside the enclosure, every ring firmware change means
opening the console. The appliance image can then ship a ring firmware that
the installed ring does not run, with nothing on the unit able to fix it.

This document decides whether the console can update the ring, and how.

## What exists today

Read from PR #1082 and PR #1080 at the time of writing.

- **Harness.** Ring J1 is 4-way: 1 = +5 V, 2 = GND, 3 = console-to-ring,
  4 = ring-to-console. Only pins 3/4 run to console J6 pins 3/4; power comes
  from the near-ring AUX split (`hardware/kicad/RING_ASSEMBLY.md`).
- **Link.** Full-duplex UART at 115200 8N1. The console side is a PIO UART on
  GP13/GP14. The XIAO side is `SerialPIO` on D10/D9 (GP3/GP4) with a 256-byte
  receive queue. Frames are SLIP with CRC-16/CCITT-FALSE; the first body byte
  is the link version (2), and the parser drops any frame whose version byte
  differs (`firmware/libraries/SegnoPanel/src/ring_link.h`).
- **XIAO footprint.** `segno.pretty/XIAO_RP2350_SMD.kicad_mod` keeps only the
  14 castellated side pads. Seeed's 16 underside pads, including
  SWDIO (23), SWDCLK (24), EN (25) and BOOT (27), were deleted by an earlier
  owner call; `ring_board.py` explains that nothing under the module body is
  soldered and that bench recovery is the module's own USB-C and buttons.
- **Console flashing.** `segno-console-flash` runs before `segno.service`,
  listens for the console's frozen HELLO frame
  (`A5 03 03 <protocol> <major> <minor> <xor>`), and runs OpenOCD over Pi
  GPIO24/25 only when the version differs from the image's marker. It exits 0
  on every failure so the app still starts.
- **Ring image.** The XIAO target builds to 64,024 bytes of flash
  (PR #1082 body). The XIAO RP2350 has 2 MB of flash. The ring sketch uses
  neither EEPROM nor LittleFS.

## Options

### 1. Firmware only: update over the existing UART

The Pi sends a ring image to the console. The console bridges it over J6 to
the ring. The ring firmware receives it and writes it to its own flash. There
are two ways to make the write safe on the ring.

**1a. RP2350 bootrom A/B partitions with try-before-you-buy (TBYB).**
The RP2350 bootrom supports this directly (datasheet §5.1.7, §5.1.13,
§5.1.16, §5.1.17, §5.1.19):

- A partition table in the first flash sector defines partitions A and B as a
  linked pair. On a normal boot the bootrom picks the partition with the
  valid `IMAGE_DEF` and the higher version.
- The running image writes the new image into the other partition
  (`rom_get_uf2_target_partition` returns which one), then calls
  `rom_reboot` with the `FLASH_UPDATE` boot type and the partition's address.
- On that boot the bootrom tries the new partition. If the image fails
  validation (including its hash), the old partition is used on later boots.
- An image flagged TBYB is entered under a fixed 16.7 s watchdog. It must
  call `explicit_buy()` within that time. If it does, the bootrom erases the
  first sector of the old partition and the new image becomes the preferred
  one. If it does not, the chip reboots into the old image. On a normal
  (non-`FLASH_UPDATE`) boot a TBYB image is never chosen over a non-TBYB one.
- Address translation (`ATRANS0`–`3`) maps the booted partition to
  `0x10000000`, so the same binary runs from A or B without relinking.

Raspberry Pi's `pico-examples/pico_w/wifi/ota_update` implements this flow
over TCP (`rom_get_uf2_target_partition`, `rom_flash_op`, `rom_reboot`
with `REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE`, `rom_explicit_buy`), with the
image built using `PICO_CRT0_IMAGE_TYPE_TBYB=1`. The ring would do the same
over the UART.

**1b. arduino-pico's own OTA bootloader.** Every arduino-pico sketch already
carries a 12 KB "stage 3" OTA bootloader, for RP2040 and RP2350
(`ota/memmap_ota_rp2350.ld` in arduino-pico 6.0.0). The sketch stores the new
image as a file in a LittleFS partition through the `Updater` class
(`Update.begin`, `Update.writeStream`, `Update.end`, MD5 checked), writes a
command file, and reboots. The OTA bootloader copies the file over the sketch.
A power loss during the copy restarts the copy on the next boot. It has no
rollback: an image that copies correctly but does not work stays installed.
It also requires a LittleFS region, chosen in the flash-size menu at compile
time, so the first USB install must already include it.

### 2. Hardware: route the XIAO's SWD to the console

Bring SWDIO/SWCLK from the XIAO to the console so the Pico 2 or the Pi can
program the XIAO over SWD, like the console itself.

- SWDIO and SWDCLK are underside pads. The carrier is hand-soldered and the
  footprint deliberately omits them. Using them means either reflowing the
  module or soldering flying wires to the underside pads before mounting it.
- J1 grows from 4 to 6 ways, the harness from 2 to 4 signal conductors over
  the ~600 mm run that also carries the LED supply (#987 measures it).
  SWD over that run needs a low clock and is a new signal-integrity risk.
- The console end needs either two more Pi GPIOs reaching J6 (console board
  respin and a new Pi-to-console conductor pair) or SWD host firmware on the
  Pico 2 driving GP12/GP15 (a second programmer in the product, and J22 is a
  separate header, so the harness still changes).
- It moves against #987, which asks whether this harness can shrink.
- PR #1080's boards are fabricated and being soldered now. This is a respin
  of the carrier, the console and the harness.

### Rejected without further comparison

- **RP2350 bootrom UART boot.** It is selected by holding QSPI CSn low and
  QSPI SD1 high at reset, and uses QSPI SD2/SD3 as TX/RX at 1 Mbaud
  (datasheet §5.2.8, §5.8). On the XIAO those pins are wired to the flash
  chip and not exposed. It also loads only a RAM image into a flashless part;
  it does not program flash.
- **Routing BOOT/RUN so the console can force BOOTSEL.** BOOTSEL then offers
  only USB or the QSPI-pin UART boot, so it does not help without USB. Both
  pads are underside pads too.

## Comparison

| | 1a bootrom A/B + TBYB | 1b arduino-pico OTA | 2 SWD harness |
|---|---|---|---|
| Hardware change | none | none | carrier footprint, J1 4→6, console respin, harness |
| Interrupted transfer | old image keeps running | old image keeps running | OpenOCD retries; chip stays in SWD reach |
| Power loss while writing | old partition untouched | copy restarts next boot | reflash at next boot |
| Image that boots but is broken | reverts automatically (no `explicit_buy`) | stays installed; USB to recover | reflash at next boot |
| Unflashed or blank ring | USB once | USB once | works from blank |
| Uses existing parts | RP2350 bootrom, `pico-examples` pattern | arduino-pico `Updater` | OpenOCD flow already used for the console |
| Unknown | can arduino-pico 6.0.0 emit a hashed, TBYB-flagged image that boots from partition B | none significant | SWD reliability over ~600 mm |

Option 2's only advantage is that it can program a blank or crashed XIAO
without USB. Both firmware options keep USB BOOTSEL as the last resort, and
BOOTSEL is in ROM, so the XIAO cannot be bricked by any of them; the worst
case is the current procedure.

## Recommendation

**Option 1, implemented with the bootrom A/B partitions and TBYB (1a).
No hardware change. Solder the V3 boards as designed.**

1a is the only option that recovers from an image that boots but does not
work without opening the enclosure, and the RP2350 provides the mechanism in
ROM. It costs no copper and no harness conductors, which keeps #987 open.

One risk decides between 1a and 1b, so a spike runs first:

> Build the ring sketch with arduino-pico 6.0.0, seal it with
> `picotool seal --hash --major/--minor` and the TBYB flag set in its
> `IMAGE_DEF`, install a partition table with linked A/B partitions on a bench
> XIAO over USB, then: write a second image into B from the running sketch,
> `FLASH_UPDATE` reboot, confirm `explicit_buy` keeps B; repeat without
> calling it and confirm the revert to A; cut power mid-write and confirm A
> still boots.

`picotool seal` has no TBYB option, and nothing in arduino-pico sets
`PICO_CRT0_IMAGE_TYPE_TBYB`, so the spike must find where the flag can be
set: a build define, or a post-build patch of the `IMAGE_DEF` before sealing.
It must also confirm that arduino-pico's startup does not disable or reload
the watchdog the bootrom armed, and that its 12 KB OTA stage in front of the
sketch boots correctly from a translated partition.

If the spike fails, use 1b. It keeps the same bridge, Pi tool and ring
receiver; only the storage step changes (a LittleFS file and the arduino-pico
OTA bootloader instead of partition B and the bootrom). Moving the ring off
arduino-pico to a plain pico-sdk build to get TBYB is not recommended: it
splits the two MCUs across two toolchains and two LED/UART library stacks.

## Design sketch for 1a

### Path

```
Pi /dev/ttyAMA3 ──115200── console Pico 2 (bridge) ──115200, J6 3/4── ring XIAO
```

The console does not parse the update. A new pedal-protocol command puts it
in **bridge mode**: it stops sending STATE frames and copies bytes both ways
between the Pi UART and the ring PIO UART. It leaves bridge mode after a few
seconds without bytes from the Pi, or when it is reset. The Pi and the
console are always matched (the Pi flashes the console first), so adding
this command needs no compatibility handling. Keeping the update protocol
between the Pi tool and the ring keeps it in one place.

### Ring side

- **Frozen ring HELLO.** Like the console's HELLO, a frame whose layout never
  changes: ring firmware version, link version, update-protocol version,
  running partition, and whether the image is on trial. The Pi tool reads it
  through the bridge to decide whether to update. The ring sends it at boot
  and on request.
- **Separate update channel.** Update frames use their own first body byte,
  frozen across ring-link versions. The current v2 parser drops any frame
  whose first byte is not 2, so a ring running an old runtime ignores them
  instead of misreading them. Messages: `BEGIN` (size, SHA-256, version),
  `DATA` (offset, 1 KiB), `COMMIT`, `CONFIRM`, and `ACK`/`NAK` replies.
- **Stop and wait.** The ring acknowledges each chunk only after it has been
  written. Flash erase/program disables XIP, and a sector erase can take up
  to ~400 ms; with stop-and-wait no UART bytes are in flight during it. LED
  output stops for the whole update.
- **First sector last.** The bootrom finds an image through the block loop in
  its first 4 KB. Writing that sector last means a partial transfer never
  presents a valid image. The sealed hash covers the rest.
- **Verify before reboot.** After the last chunk the ring reads the partition
  back through `rom_flash_op` (it cannot read it through XIP; the translated
  window covers only the running partition) and compares the SHA-256 with
  `BEGIN`. Only then does it `FLASH_UPDATE` reboot.
- **Buy only after the full path works.** The new image boots on trial and
  sends HELLO. The Pi tool, still in bridge mode, answers with `CONFIRM`. The
  ring calls `explicit_buy()` on `CONFIRM`. This proves the new image can
  receive through the console and answer the Pi, which is what the next
  update needs. No `CONFIRM` within ~10 s leaves the watchdog to revert.

### Pi side

- `segno-ring-flash`, run after `segno-console-flash` and before
  `segno.service`, in the same oneshot style: exit 0 on every failure, so a
  ring problem never stops the app from starting.
- The image carries the sealed ring binary and a marker
  (`firmware=<major>.<minor> update=<n>`), produced by the existing
  `segno-ring-board` release artifact.
- The tool updates only when the ring's HELLO version differs from the
  marker. It does not retry the same image indefinitely: record failed
  attempts per image version under `/data` and stop after a small number, so
  a bad image does not add update time to every boot.

### Flash layout

Partition table in slot 0 (the first 4 KB sector, plus slot 1 as the bootrom
reserves it), then partitions A and B of 512 KB each, linked as a pair. The
current image is 64 KB, so each partition has eight times that. The rest of
the 2 MB stays unpartitioned. Because the running image can only see its own
partition through XIP, the ring firmware must not start using arduino-pico's
EEPROM or LittleFS (both live at the end of flash) unless that region is
moved inside the partition.

### First install

Over USB, once per carrier: load the partition-table UF2
(`picotool partition create`) and then the sealed image; UF2 targeting puts
it in A. This replaces the current BOOTSEL step in `RING_ASSEMBLY.md`
"Programming". After that, the ring stays closed up.

## Risks

| Risk | What happens | Mitigation |
|---|---|---|
| Bricking | Not possible in the ROM sense: BOOTSEL is in mask ROM and is always available through USB. The realistic failure is a ring that needs the enclosure opened, which is today's normal procedure. | TBYB revert; verify-before-reboot; never touch the partition table after the first install. |
| Power loss mid-transfer | Partition B holds a partial image with no valid first sector. | The bootrom keeps booting A. The next boot's `segno-ring-flash` sees the old version and starts again. |
| Power loss during the trial boot | B is on trial, not bought. | A normal boot prefers the non-TBYB image in A. |
| New image boots but its link is broken | It never receives `CONFIRM`. | Watchdog reverts to A after 16.7 s. The Pi tool sees the old version, logs it and counts the attempt. |
| Watchdog on trial is reloaded by the sketch | Trial image could stay running without being bought. | Spike checks arduino-pico startup; the ring firmware must not reload the watchdog before `CONFIRM`. |
| Link speed | 115200 8N1 is 11,520 B/s. 64 KB in 1 KiB stop-and-wait chunks is about 6 s, plus about 0.7 s of sector erases (up to ~6 s at worst-case erase time), plus the trial reboot. | About 10 s, only on boots where the version changed. Raising the baud rate is possible later; not needed now. |
| Flash size | 2 MB total. | Two 512 KB partitions leave 8x headroom over today's image. |
| Bytes lost while flash is busy | XIP is off during erase/program; PIO RX FIFO is small. | Stop-and-wait: nothing is sent until the previous chunk is acknowledged. |
| Ring and console link versions drift | A console with link v3 talking to a ring with link v2. | The update channel and HELLO are frozen and independent of the ring-link version, so any console can update any update-capable ring. |
| Update during a performance | Ring goes dark and the encoder stops for ~10 s. | Updates run only in the boot unit before the app starts. |
| Strip DIN floating while the ring reboots | The XIAO releases D0 during reset. | R5 (100k) holds the AHCT125 input low while D0 is undriven, as for any ring reset today (`ring_board.py`). |
| The spike fails | No TBYB with arduino-pico. | Fall back to 1b. Same transport; loses only automatic rollback. |

## Open questions

1. Owner: approve option 1 (firmware only) over option 2 (SWD harness)?
2. Owner: bootrom A/B + TBYB as the target, with arduino-pico's `Updater` as
   the fallback if the spike fails?
3. Owner: ring updates only at boot, before the app starts. Agreed?
4. Owner: the first OTA-capable install needs USB. Do it before the enclosure
   is closed on the first V3 unit, or accept one more USB session later?
   The current UF2 is fine for bench bring-up either way.
5. Plan: does the bridge command belong in pedal protocol 7 (PR #1082 is
   still a draft) or the next protocol version?

## Non-goals

- No PCB, footprint or harness change. #987 stays independent.
- No change to how the console Pico 2 is flashed.
- No signed images or anti-rollback OTP. The RP2350 supports both; nothing in
  this product needs them yet.
- No firmware written, nothing flashed, in this brainstorm.

## Sources

- RP2350 datasheet, chapter 5 (Bootrom): §5.1.7 A/B versions, §5.1.13 flash
  partition boot, §5.1.16 flash update boot, §5.1.17 try before you buy,
  §5.1.19 address translation, §5.2.8 BOOTSEL (USB/UART) boot, §5.8 UART boot.
  <https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf>
- Raspberry Pi `pico-examples/pico_w/wifi/ota_update` (A/B + TBYB over TCP).
  <https://github.com/raspberrypi/pico-examples/tree/master/pico_w/wifi/ota_update>
- arduino-pico OTA documentation and the `ota/` bootloader (6.0.0).
  <https://arduino-pico.readthedocs.io/en/latest/ota.html>
- `picotool seal` options (`--hash`, `--major`, `--minor`; no TBYB flag).
  <https://github.com/raspberrypi/picotool>
