---
date: 2026-08-21
topic: dart-linux-gpio-package
---

# A pure-Dart Linux GPIO package (cdev uAPI v2) as a standalone OSS project

Tracking: [#787](https://github.com/tomassasovsky/segno/issues/787).
Board context: console board v2 [#747](https://github.com/tomassasovsky/segno/issues/747).

## What We're Building

A **standalone, generically useful Dart package** that reads and drives Linux GPIO
lines through the `/dev/gpiochipN` character device using the **v2 userspace ABI**,
with **no native library and no bundled binary** — `dart:ffi` straight to libc's
`ioctl`/`read`/`epoll`. Own repository, permissive license, published to pub.dev.

## The honest motivation, stated first

**The Segno console does not need this.** That has to be the first line of the doc,
because an earlier draft of this thread was built on a requirement that does not
exist, and a plan resting on a false premise is worse than no plan.

Console board v2 puts every control behind the RP2350, and every Pi-side signal on
the 40-way behind a **kernel driver**, not a GPIO line. From the netlist
([`hardware/kicad/console_board.py:PI_HDR`](../../hardware/kicad/console_board.py)) the
ribbon carries exactly:

| Pi pins | function | who owns it in Linux |
|---|---|---|
| 8 / 10 (GPIO14/15) | `uart0` — MIDI IN/OUT | kernel serial driver (`/dev/ttyAMA*`) |
| 24 / 21 (GPIO8/9) | `uart3` — LINK to the Pico 2 (`dtoverlay=uart3-pi5`) | kernel serial driver |
| 18 / 22 (GPIO24/25) | SWCLK / SWDIO — reflash the Pico 2 | **openocd** |
| 1, 17 / 6, 9, 14, 20, 25, 30, 34, 39 | 3V3 / GND | — |

And the power button is **not on a GPIO at all**, which is the specific thing the
earlier draft got wrong. It is J8 on the console board, net `PWR_BTN`, passed straight
through to J9 — a two-pin flying lead to the **Pi 5's own power-button solder pads**
beside the RTC connector. The generator says why, and it is a hardware fact rather
than a preference:

> On a Pi 5 an external button cannot be a GPIO: RP1 and the SoC are unpowered until
> the PMIC brings them up, so nothing on the 40-way can wake the machine.
> — `console_board.py:401`

with pin 5 / GPIO3 annotated `-- NOT the power button` (`console_board.py:584`).

SWD is openocd's too, explicitly: *"The Pi reflashes the MCU with openocd over
SWCLK/SWDIO/GND … **Requires `openocd` in the Pi image**"*
([console board v2 plan:103](../plan/2026-08-17-feat-console-board-v2-plan.md)). Even
if it were not, bit-banging SWD through the cdev ABI would be hopeless — one ioctl per
clock edge, microseconds each, against a flash image that needs millions of them.

So this package is **not** justified by the console. It is justified on its own merits,
below, and Segno's use of it is optional and secondary.

### Doc drift this uncovered — worth fixing separately

Three places still assert the dead version, and they are what led the first draft
astray. None is load-bearing on the board (the netlist is right), but all three read as
settled fact:

- `console_board.py:394` — section header `J8: rear power button -- passed STRAIGHT
  through to a Pi GPIO`, contradicted by its own next paragraph seven lines later.
- [`docs/plan/2026-08-17-feat-console-board-v2-plan.md:53`](../plan/2026-08-17-feat-console-board-v2-plan.md)
  — ribbon contents listed as `UART ×2, SWD, power button, 5 V, 3V3, GND`. `PI_HDR`
  has no power-button net.
- [`docs/brainstorm/2026-08-17-console-board-v2-brainstorm-doc.md`](2026-08-17-console-board-v2-brainstorm-doc.md)
  — *"Power button goes straight to a Pi GPIO, not through the MCU"*, and the same
  line in that doc's board-content table.

A one-line-each fix, no issue needed per `CLAUDE.md`.

## Why This Approach

### The real case for building it

Two things, and neither is a Segno requirement:

1. **The ecosystem gap is real and verified.** There is no maintained, Dart-3,
   pure-Dart, uAPI-v2 GPIO package. Evidence below. That is a genuine hole in the Dart
   embedded-Linux story, and filling it is the stated product intent for this thread.
2. **Segno's direct-wired path, if it is ever taken.** Three older plans and a research
   doc name a `packages/gpio_client` as though it existed
   ([`plan/2026-06-14-…:364`](../plan/2026-06-14-feat-native-midi-device-selection-plan.md),
   [`plan/2026-07-22-…:172`](../plan/2026-07-22-chore-rpi4b-hardware-validation-plan.md),
   [`research/2026-07-22-…:378`](../research/2026-07-22-rpi5-embedded-boot-experience-research.md));
   `git log --all` shows it never was. What they mean is footswitches wired straight to
   a bare Pi header with no console board — the bench / Pi 4B-validation / DIY build.
   That would reuse the existing `ControllerSource` seam. It is **not committed**, and
   this package must not be designed around it.

Point 1 carries the work. Point 2 is a bonus consumer. If the answer to "do we want to
own a pub.dev package" is no, then the honest answer to this whole thread is *don't
build it* — nothing in Segno is blocked.

### Prior art — checked before designing anything, per `AGENTS.md`

Facts from the pub.dev API and the packages' own source, not their marketing:

| package | latest | SDK constraint | ABI | events | native dep | license |
|---|---|---|---|---|---|---|
| `flutter_gpiod` | 0.6.0, 2026-02-09 | `>=2.17.0 <3.0.0` | **v1** | `Stream` (epoll in an isolate) | none | MIT |
| `gpiod` | 3.0.1, 2022-05-24 | `>=2.16.0 <3.0.0` | v1 (libgpiod FFI) | — | libgpiod | — |
| `dart_periphery` | 0.9.20, 2025-12-16 | `>=3.3.0 <4.0.0` | v2 (via c-periphery) | blocking `poll()`/`readEvent()` | bundled `.so` per arch | BSD-3 |

- **`flutter_gpiod` is pre-Dart-3.** Published constraint `<3.0.0`; Segno is on
  `sdk: ^3.11.0`, so it cannot resolve. Its architecture is right — despite the name it
  is a pure Dart package (no `flutter:` section, no Flutter SDK dep) and it runs
  `epoll_wait` in a spawned isolate feeding a `SendPort`, the pattern adopted below.
  But it requests lines with `GPIO_GET_LINEHANDLE_IOCTL` / `GPIO_GET_LINEEVENT_IOCTL`
  and reads `gpioevent_data` — the **v1** path, which the kernel header itself marks
  *"This version of the ABI is deprecated"* (`include/uapi/linux/gpio.h:309`).
- **`gpiod` is dead** — last published 2022, also `<3.0.0`, FFI to libgpiod v1 whose
  API (`gpiod_chip_get_line`) no longer exists in libgpiod v2.
- **`dart_periphery` is the real alternative** and deserves a straight answer rather
  than a strawman. Alive, Dart-3, BSD-3, and its underlying c-periphery genuinely
  speaks cdev v2 — `gpio_config_t` carries `debounce_us`, `bias`, `drive` and an event
  clock (`c-periphery/src/gpio.h:64`). What it costs:
  - **Blocking, not streamed.** `poll(timeoutMillis)` / `readEvent()` are synchronous,
    so the isolate + `SendPort` plumbing — the hard half of the job — still has to be
    written on top.
  - **No `seqno`.** `gpio_read_event(gpio, &edge, &timestamp)` discards the v2 event's
    `seqno`/`line_seqno`, so a kfifo overflow drops edges **silently**.
  - **A prebuilt binary blob** per architecture, or c-periphery installed system-wide
    (a Yocto recipe to own). Segno's `license_check.yaml` gate and a GPL appliance
    build both prefer no third-party binary in the image.
  - **Kitchen sink** — GPIO, LED, PWM, SPI, I²C, MMIO, ADC, Serial and twenty-odd
    sensor drivers.

### Why uAPI v2 specifically

Three v2-only features, verified against the current `include/uapi/linux/gpio.h`:

1. **Kernel debounce** — `GPIO_V2_LINE_ATTR_ID_DEBOUNCE` / `debounce_period_us`
   (lines 106, 136). Contact bounce filtered below userspace, no Dart-side timers.
2. **Sequence numbers** — `gpio_v2_line_event.seqno` / `line_seqno` (lines 300–301).
   A gap proves the kernel dropped events; v1's `gpioevent_data` has no such field, so
   overflow is invisible.
3. **Chosen event clock** — `GPIO_V2_LINE_FLAG_EVENT_CLOCK_REALTIME` / `…_HTE`
   (lines 84–85). v1's timestamp clock changed meaning across kernel versions.

Plus up to **64 lines per request** with per-line attributes (`GPIO_V2_LINES_MAX`,
line 45) — one fd and one atomic `GPIO_V2_LINE_GET_VALUES` for a whole footswitch bank.

### Why no native library

libgpiod v2's core is itself a thin wrapper over these ioctls. FFI-ing it buys nothing
and costs a runtime dependency, a v1-vs-v2 packaging split across distros (Bookworm
ships 1.6, Trixie 2.x), and an LGPL component in the image. The **ioctl interface is
the stable kernel ABI** — more guaranteed not to break than any library wrapping it.

## Key Decisions

- **v2 only.** No v1 fallback, no compatibility shim — `AGENTS.md` forbids exactly
  that. v2 landed in 5.10 (Dec 2020). An older chip gets a clear error, not a silent
  downgrade.
- **Pure Dart, not Flutter.** Usable from a CLI daemon, a test harness or a server.
- **Discovery by chip label and line name, never by index.** The Pi 5's I/O moved to
  RP1 on PCIe, so probe order gives it a high number: older Pi 5 kernels expose the
  header as `gpiochip4`, post-mid-2024 kernels renumber it to `gpiochip0`. Any
  hardcoded index is a bug waiting for a kernel update.
- **One event isolate, kernel timestamps.** A dedicated isolate owns an `epoll` fd with
  every requested line-fd registered, blocks in `epoll_wait`, and posts decoded events
  over a `SendPort`. Isolate scheduling affects *delivery* latency (bounded,
  measurable) but never the timestamp, which the kernel stamps at the interrupt.
- **Dropped events are surfaced, not swallowed.** A `seqno` gap becomes an explicit
  event on the stream.
- **ioctl request numbers computed at runtime** from the `_IOC` formula and
  `sizeOf<Struct>()`, not hardcoded — a mismatched hand-written `ffi.Struct` then
  changes the request number and fails loudly instead of scribbling on memory. Backed
  by explicit size assertions, measured against the current header:
  `gpio_v2_line_request` 592, `…_info` 256, `…_config` 272, `…_values` 16, `…_event`
  48, `gpiochip_info` 68.
- **Testable without a Pi.** The syscall layer is an injectable seam, so package logic
  is unit-testable against a fake kernel on any machine, macOS included. An opt-in
  second suite runs against the kernel's own `gpio-sim`. The fake carries the gate;
  `gpio-sim` confirms.
- **Permissive license, and it is forced.** Segno is GPL-3.0-or-later, but its own
  `license_check.yaml` allows only `MIT,BSD-3-Clause,BSD-2-Clause,Apache-2.0,Zlib` — a
  GPL child package would fail Segno's CI on the first `pubspec.lock` change.
- **Written from the kernel uapi header, never from libgpiod.**
  `include/uapi/linux/gpio.h` is `GPL-2.0 WITH Linux-syscall-note`, whose note exists
  precisely to let userspace use these definitions under any license. libgpiod is LGPL
  and must not be read-and-transcribed.
- **GPIO only.** No PWM, SPI, I²C or sysfs. Smallest thing that works end to end.

## Alternatives Considered

- **Don't build it.** Now the leading alternative, given nothing in Segno is blocked.
  Costs nothing, forfeits the pub.dev package the thread exists to produce.
- **Adopt `dart_periphery`** and write only the isolate/stream layer. Cheapest if a
  Segno consumer ever materialises; costs the blob, the silent-drop blind spot and the
  kitchen sink. This is the right answer *if* the OSS package is not wanted.
- **Fork `flutter_gpiod` to Dart 3.** MIT, right architecture — but the fork inherits
  the deprecated v1 ABI, and migrating it to v2 rewrites its entire ioctl layer. Only
  the isolate skeleton survives, which is a hundred lines.
- **FFI to libgpiod v2.** A runtime dependency and a distro packaging split, to wrap
  ioctls callable directly.
- **sysfs (`/sys/class/gpio`).** Deprecated since 4.8, no usable edge timestamps.
- **Incubate under `packages/gpio_client`, extract later.** `AGENTS.md`: "Do not accept
  a stopgap … meant to be replaced later." Extraction after the fact rewrites the
  license headers, CI, test layout and public API anyway.

## Open Questions

- **Do we want to own a pub.dev package at all?** The decision the whole thread now
  turns on, since the console requirement evaporated. Everything below is moot if this
  is no.
- **Is there a Segno consumer worth naming, or is direct-wiring hypothetical?** If the
  bare-Pi footswitch path is genuinely dead, the package has no in-repo consumer and
  should live entirely outside this repo, with Segno taking no dependency at all.
- **MIT or Apache-2.0?** MIT matches the Dart ecosystem norm and `flutter_gpiod`;
  Apache-2.0 adds a patent grant. Either passes Segno's license gate.
- **Package name.** `linux_gpio`, `gpio_cdev`, `linux_gpiod`, `dart_gpio` and
  `libgpiod` are all free on pub.dev (`gpiod` is taken by the dead 2022 package).
  Leaning `linux_gpio`; `gpio_cdev` mirrors the Rust crate and is more precise.
- **Is `gpio-sim` present on GitHub's Ubuntu runners?** Decides whether the integration
  suite is a CI job or hardware-only. Not blocking — the fake-syscall suite is the gate.
- **Flutter hot-restart leaks a line request.** A documented `flutter_gpiod` pain: the
  process survives hot restart, so the fd and the kernel's line ownership survive with
  it, and the next request fails "in use". Needs a deliberate answer — a
  process-lifetime singleton registry, or a documented "full restart in development".
