---
title: "feat: `gpio` — a pure-Dart Linux GPIO (cdev uAPI v2) package as a child OSS project"
type: feat
date: 2026-08-21
issue: 787
---

## feat: `gpio` — a pure-Dart Linux GPIO (cdev uAPI v2) package as a child OSS project

Tracking [#787](https://github.com/tomassasovsky/segno/issues/787) ·
Brainstorm [`docs/brainstorm/2026-08-21-dart-linux-gpio-package-brainstorm-doc.md`](../brainstorm/2026-08-21-dart-linux-gpio-package-brainstorm-doc.md)

> **This plan ships almost entirely outside this repository.** Segno takes **no
> dependency** on the package (see Overview). Only PR 1 lands here; PRs 2–6 land in the
> new `gpio` repo. The thread stays tracked on #787 so the board reflects it.

## Overview

A new standalone package, **`gpio`** (the bare name is unclaimed on pub.dev), that
reads and drives Linux GPIO lines over `/dev/gpiochipN` using the **v2 userspace ABI**
— pure `dart:ffi` to libc `ioctl`/`read`/`epoll`, **no native library and no bundled
binary**. Own repository, **MIT**, published to pub.dev.

Decisions taken at the plan gate, recorded so they are not relitigated:

| decision | choice |
|---|---|
| build at all | **yes**, as an OSS package on its own merits |
| repo | **separate from commit one**; not incubated under `packages/` |
| license | **MIT** (GPL is impossible — Segno's own `license_check.yaml` would reject it) |
| name | **`gpio`** — OS-neutral, survives a BSD or USB-bridge backend with no rename |
| Segno consumption | **none for now** |

## Problem Statement / Motivation

**Segno does not need this, and the plan says so up front.** The first draft of #787
claimed the console's power button lands on a Pi GPIO. It does not. From the netlist
([`hardware/kicad/console_board.py`](../../hardware/kicad/console_board.py), `PI_HDR`)
every Pi-side signal on the ribbon belongs to a **kernel driver**: `uart0` (GPIO14/15)
is MIDI, `uart3` (GPIO8/9) is the link to the Pico 2, and GPIO24/25 are SWCLK/SWDIO
driven by **openocd** ([console board v2 plan:103](2026-08-17-feat-console-board-v2-plan.md)).
The power button is J8 → J9, a flying lead to the **Pi 5's own power-button pads**,
because *"on a Pi 5 an external button cannot be a GPIO: RP1 and the SoC are unpowered
until the PMIC brings them up"* (`console_board.py:401`).

What motivates the work instead:

**The ecosystem gap is real and verified.** No maintained, Dart-3, pure-Dart, uAPI-v2
GPIO package exists. `flutter_gpiod` (MIT, 0.6.0) is pinned `>=2.17.0 <3.0.0` — it
cannot resolve against Dart 3 at all — and requests lines through the **v1** ioctls the
kernel header marks *"deprecated"*. `gpiod` (3.0.1, 2022) is dead. `dart_periphery`
(BSD-3, alive, Dart 3) is the real alternative but ships per-architecture prebuilt
binaries, exposes blocking `poll()`/`readEvent()` rather than a stream, and discards
the v2 event `seqno` so a kfifo overflow drops edges silently.

uAPI **v2** is the only ABI that carries kernel debounce
(`GPIO_V2_LINE_ATTR_ID_DEBOUNCE`), event sequence numbers
(`gpio_v2_line_event.seqno` / `line_seqno`) and a selectable event clock
(`GPIO_V2_LINE_FLAG_EVENT_CLOCK_REALTIME` / `…_HTE`) — the three things that separate a
usable button input from a guess.

## Proposed Solution

One package, one backend, no plugin machinery.

### Public API

Backend-neutral vocabulary throughout — `ioctl`, file descriptors and `/dev/…` never
appear in the public surface. Linux-ness is confined to one named constructor, so a
FreeBSD `gpioc` or USB-bridge backend later needs no rename and no API break.

```dart
// ---- discovery -------------------------------------------------------------
List<GpioChipInfo> chips = Gpio.listChips();
final chip = GpioChip.byLabel('pinctrl-rp1');   // primary — never an index
final chip = GpioChip.byName('gpiochip0');
final chip = GpioChip.byPath('/dev/gpiochip0'); // explicit, Linux-flavoured

chip.info;                       // GpioChipInfo(name, label, lineCount)
chip.lineInfo(17);               // GpioLineInfo(offset, name, consumer, direction,
                                 //   bias, drive, activeLow, used, debouncePeriod)
chip.findLine('GPIO17');         // int? — by kernel line name

// ---- request ---------------------------------------------------------------
final req = chip.request(
  consumer: 'segno',
  lines: [
    LineConfig.input(17,
      bias: Bias.pullUp,
      edge: Edge.both,
      debounce: const Duration(milliseconds: 5),
      activeLow: true),
    LineConfig.output(27, initialValue: false, drive: Drive.pushPull),
  ],
  eventClock: EventClock.monotonic,
);

req.getValue(17);                // bool
req.getValues();                 // Map<int, bool> — one atomic ioctl
req.setValue(27, true);
req.setValues({27: true});
req.reconfigure([...]);          // GPIO_V2_LINE_SET_CONFIG
await req.close();

// ---- events ----------------------------------------------------------------
req.events.listen((event) => switch (event) {
  LineEdgeEvent(:final offset, :final edge, :final timestamp) => ...,
  LineEventsDropped(:final offset, :final count)             => ...,
});
```

`LineEdgeEvent` carries `offset`, `edge`, `timestamp` (kernel-stamped, `Duration` since
the chosen clock's epoch), `seqno` and `lineSeqno`. `LineEventsDropped` is emitted when
a `seqno` gap proves the kernel's kfifo overflowed — **the differentiator**: no other
Dart package can tell you an edge was lost.

Errors are one `GpioException` carrying `errno`, the failing operation and an
actionable message: `EBUSY` names the current consumer, `EACCES` names the `gpio`
group and the udev rule, `ENOTTY` says "not a GPIO character device", and a v2 ioctl
rejected on an old kernel says "requires Linux 5.10 or newer".

### Internal structure

```
lib/gpio.dart                    public surface only
lib/src/ffi/libc.dart            open, close, read, ioctl, epoll_*, eventfd, errno
lib/src/ffi/gpio_uapi.dart       ffigen output from <linux/gpio.h>, checked in
lib/src/ffi/ioctl.dart           _IOC encoding, request numbers computed at runtime
lib/src/syscalls.dart            abstract Syscalls seam + LibcSyscalls
lib/src/chip.dart                discovery, chip info, line info
lib/src/line_request.dart        request/get/set/reconfigure
lib/src/events.dart              event isolate, decode, seqno-gap detection
lib/src/models.dart              enums + value types
```

## Technical Considerations

### ioctl numbers are computed, not hardcoded

Request numbers encode the struct size, so they are computed in Dart from the
asm-generic `_IOC` formula over `sizeOf<Struct>()`. If a hand-written or regenerated
`ffi.Struct` ever mismatches the kernel's layout, the computed number stops matching
and the ioctl **fails loudly** rather than scribbling past a buffer.

Measured against the current header, and asserted in a test:

| struct | bytes | | ioctl | value |
|---|---|---|---|---|
| `gpiochip_info` | 68 | | `GPIO_GET_CHIPINFO` | `0x8044b401` |
| `gpio_v2_line_info` | 256 | | `GPIO_V2_GET_LINEINFO` | `0xc100b405` |
| `gpio_v2_line_config` | 272 | | `GPIO_V2_GET_LINE` | `0xc250b407` |
| `gpio_v2_line_request` | 592 | | `GPIO_V2_LINE_SET_CONFIG` | `0xc110b40d` |
| `gpio_v2_line_values` | 16 | | `GPIO_V2_LINE_GET_VALUES` | `0xc010b40e` |
| `gpio_v2_line_event` | 48 | | `GPIO_V2_LINE_SET_VALUES` | `0xc010b40f` |

The uAPI is deliberately fixed-width (`__u32`/`__u64`/fixed char arrays), so these hold
on 32-bit ARM as well as arm64/x64 — but that is an assumption the CI matrix has to
*prove*, not assert in prose. Hence the same test on every architecture CI runs.

### The event isolate, and how it shuts down

A dedicated isolate owns an `epoll` fd with every requested line-fd registered, blocks
in `epoll_wait`, reads `gpio_v2_line_event` records and posts decoded events over a
`SendPort`. Two consequences worth stating:

- **Timestamps are the kernel's**, stamped at the interrupt. Isolate scheduling affects
  *delivery* latency — bounded and measurable — but never the timestamp. This is why
  the stream is honest enough to measure latency with.
- **Blocking forever needs a wakeup.** `epoll_wait` with no timeout would strand the
  isolate on `close()`. An `eventfd` is registered alongside the line fds purely so the
  owning isolate can break the wait; closing is then deterministic rather than
  timeout-polled. (A poll timeout would work and is simpler, but it trades a clean
  shutdown for a wakeup every N ms on an appliance that idles.)

Synchronous FFI calls run on the calling isolate's own thread, so `errno` read
immediately after a failing call is valid — no thread-hop hazard.

### Testable without a Pi — the crux

Three layers, in order of how much they carry:

1. **A fake kernel behind the `Syscalls` seam.** The real gate. Implements `open`,
   `ioctl`, `read`, `close` over in-memory buffers, so request encoding, value get/set,
   event decode, seqno-gap → `LineEventsDropped`, and every errno mapping are unit
   tested with no hardware, on any OS including the macOS dev machine.
2. **ABI assertions.** Struct sizes and computed ioctl numbers against the table above,
   run on every architecture in the matrix.
3. **`gpio-sim` integration.** The kernel's own configfs-backed GPIO simulator — what
   libgpiod's own suite uses. Creates a virtual chip, drives a pull, asserts the event
   arrives with the right edge and a monotonic timestamp. Needs root and
   `CONFIG_GPIO_SIM`; **skips cleanly** when either is missing, so it confirms rather
   than gates.

### Permissions

`/dev/gpiochip*` is root-only by default. The package cannot fix that, but it can stop
the failure being cryptic: `EACCES` returns a message naming the `gpio` group and a
udev rule, and the README carries both. This is also why `flutter_gpiod` says "root
required" — it is a property of the interface, not of the package.

### Hot restart leaks a line request

A known `flutter_gpiod` failure worth designing against rather than discovering: a
Flutter hot restart tears down isolates but **not the process**, so the line fd — and
the kernel's ownership of the line — survives, and the next request fails `EBUSY` with
the app itself named as consumer. Answer: a process-lifetime registry keyed by
`(chip, offsets)` that hands back the live request instead of re-requesting, plus an
`EBUSY` message that recognises its own consumer string and says "still held from a
previous hot restart; full restart to release".

### Pi 5 chip renumbering

RP1 sits on PCIe, so probe order gives it a high number: older Pi 5 kernels expose the
40-way as `gpiochip4`, kernels after mid-2024 renumber it to `gpiochip0`. `byLabel` is
the documented path and every example uses it; `byPath` exists but the README says
plainly why not to reach for it.

## Success Criteria

- [ ] `dart analyze` clean; `dart format` clean; pana score reported in CI.
- [ ] Fake-kernel suite covers: chip discovery, line info, multi-line request encoding,
      atomic get/set, reconfigure, edge decode, seqno-gap detection, every mapped errno.
- [ ] ABI test passes on **x64, arm64 and armv7** — struct sizes and computed ioctl
      numbers match the table above on all three.
- [ ] `gpio-sim` suite passes where available, skips (not fails) where not.
- [ ] A `blink` and a `button` example that run on a Pi 5 from a fresh `dart pub get`,
      with **no apt package installed**.
- [ ] README documents the `gpio` group + udev rule, the `byLabel` rule, and the
      hot-restart caveat.
- [ ] Published to pub.dev as `gpio` 0.1.0, MIT.

**On-hardware, `autonomy:blocked-verify`** — green CI is not proof for any of these:

- [ ] Press → `LineEdgeEvent` delivery latency measured on a Pi 5, distribution recorded.
- [ ] Kernel debounce demonstrably suppresses contact bounce a bare edge request shows.
- [ ] `byLabel('pinctrl-rp1')` resolves on the appliance kernel.

## Implementation

### PR 1 — this repo (docs only)

Brainstorm + this plan, plus the doc-drift fixes the brainstorm uncovered
(`console_board.py:394` header comment,
[`console board v2 plan:53`](2026-08-17-feat-console-board-v2-plan.md) ribbon contents,
and the #747 brainstorm's power-button bullet + board table — all three still say the
power button reaches a Pi GPIO; the netlist is right and the prose is stale). Trivial
one-liners, folded in here rather than given their own issue per `CLAUDE.md`.

### PR 2 — child repo: skeleton + ABI layer

Repo bootstrap (MIT, `very_good_analysis`, CI matrix x64/arm64/armv7), `ffigen` config
and checked-in `gpio_uapi.dart`, `_IOC` encoding, the `Syscalls` seam with
`LibcSyscalls`, and the ABI assertion test. No public API yet.

### PR 3 — child repo: chips, lines, values

Discovery (`listChips`, `byLabel`, `byName`, `byPath`), chip/line info, `request` with
full `LineConfig` (direction, bias, drive, activeLow, debounce), atomic get/set,
`reconfigure`, `GpioException` + errno mapping. Fake-kernel suite lands with it.

### PR 4 — child repo: edge events

Event isolate, `epoll` + `eventfd` shutdown, event decode, `seqno`-gap →
`LineEventsDropped`, `EventClock` selection, deterministic `close()`. Fake-kernel event
tests.

### PR 5 — child repo: gpio-sim + examples

The configfs `gpio-sim` integration suite with its skip logic, the CI job that runs it,
and the `blink` / `button` examples.

### PR 6 — child repo: publish

README (permissions, `byLabel`, hot restart, the honest "no macOS/Windows GPIO exists"
note), CHANGELOG, `dart pub publish` as 0.1.0.

## PR split

| # | repo | contents | depends on |
|---|---|---|---|
| 1 | segno | these docs + 3 doc-drift one-liners | — |
| 2 | gpio | skeleton, ffigen, `_IOC`, `Syscalls`, ABI test | — |
| 3 | gpio | chips, lines, values, errors | 2 |
| 4 | gpio | edge events, isolate | 3 |
| 5 | gpio | gpio-sim suite, examples | 4 |
| 6 | gpio | README, CHANGELOG, publish 0.1.0 | 5 |

## Dependencies & Risks

| risk | severity | mitigation |
|---|---|---|
| `gpio-sim` unavailable on GitHub runners | low | fake-kernel suite carries the gate; the sim suite skips cleanly |
| 32-bit ARM struct layout differs from the table | medium | ABI test runs on armv7 in the matrix — it is there to *prove* the fixed-width assumption, not restate it |
| `epoll_wait` strands the isolate on close | medium | `eventfd` wakeup, not a poll timeout |
| Hot restart leaks the line | medium | process-lifetime registry + a self-aware `EBUSY` message |
| Kernel < 5.10 | low | v2 ioctl fails; error says so explicitly. No v1 fallback, by decision |
| Package has no in-repo consumer, so it bit-rots | **real** | accepted deliberately: it is an OSS deliverable, not Segno infrastructure. Revisit if the bare-Pi footswitch path is ever committed |
| Owning a published package is ongoing work | real | accepted at the plan gate |

No dependency on #747, #752 or any hardware milestone — deliberately. Nothing in Segno
blocks on this and nothing here blocks Segno.

## References & Research

- `include/uapi/linux/gpio.h` (`GPL-2.0 WITH Linux-syscall-note` — the note is what
  permits an MIT userspace implementation). **Written from the header; libgpiod is LGPL
  and must not be read-and-transcribed.**
- Prior art measured via the pub.dev API and package source, not documentation:
  `flutter_gpiod` 0.6.0 (`sdk >=2.17.0 <3.0.0`, v1 ioctls, MIT),
  `gpiod` 3.0.1 (2022, `<3.0.0`), `dart_periphery` 0.9.20 (BSD-3, c-periphery 2.5.0).
- `c-periphery/src/gpio.h` — `gpio_config_t` (confirms it does carry `debounce_us`; the
  gap is `seqno` and the blocking API, not v2 support).
- [`hardware/kicad/console_board.py`](../../hardware/kicad/console_board.py) — `PI_HDR`,
  and the J8/J9 power-button path that corrected this thread's premise.
