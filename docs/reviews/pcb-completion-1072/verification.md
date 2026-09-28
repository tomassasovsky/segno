<!-- cspell:words PIO IM microcontroller RP STUSB libgpiod preorder Mbps -->
# Console and screen-power completion — #1072

The owner's September 22 “fix everything” instruction has been implemented
locally. Software review is complete with **zero unresolved findings** across
VGV, architecture, test quality, simplicity and readiness. The September 24
[first-fabrication review](first-fabrication.md) supersedes the earlier blanket
order hold: no additional owner measurements are prerequisites for buying the
bare PCBs. Assembled hardware still needs validation. The September 24
[pill-chain diagnostic](pill-chain.md) temporarily tested the existing console;
the new v3 firmware and GPIO service have not been deployed. No PD configuration
changed, order was submitted, commit pushed or PR merged.

## Corrections

- Console v3 now uses its actual GP13/GP14 ring UART and all 80 indicator pixels.
  The XIAO RP2350 has its own firmware for the 24-pixel ring and encoder. Ring
  animation is preserved; corrupted/lost packets, reconnects and stale state
  are handled. PIO/DMA LED output avoids blocking UART/encoder interrupts.
- LEDs start dark until valid app state. Physical switched-jack presence replaces
  the old expression-pedal unplug heuristic, and applies the RP2350 E9 input
  workaround. A fast movement to full toe cannot falsely detach the pedal.
- Protocol 6 carries read-only PD status into repository diagnostics. Missing,
  changing or stale reports clear old values. Voltage remains explicitly unknown;
  reserved register 0x21 is not used to claim 20 V or 100 W readiness. See the
  [PD and presence evidence](pd-presence-completion.md).
- The Pi gets a dedicated GPIO17 owner. Weston enables screens before probing
  HDMI/touch, then drives the GPIO low and completes a provisional five-second
  wait before stopping HDMI. Stop, restart and keeper failure paths are covered.
  An off-only recovery path reclaims the line after a failed keeper; turning on
  always requires the keeper. The existing save/goodbye flow stays in place.
- Screen relays now use pin-compatible **TE IM02TS / 1-1462037-3**, with better
  pickup margin at low USB voltage. No routing or placement changed. The parts
  snapshot is $33.66 excluding boards, shipping and harnesses. The earlier
  corrected drill sizes, mount clearances and console ADC supply remain intact.

The screen is still hand-soldered only, two layers, purple, 68 × 76 mm with
3 mm corners. The console is still 99.5 × 99.5 mm. Exact pin assignments,
assembly limits and parts remain in their board/firmware guides.

## Observed validation

| Check | Result |
| --- | --- |
| Screen native ERC/DRC and circuit/layout parity | Clean, zero unconnected items; all 24 deliberately broken cases rejected |
| Console native ERC/DRC and parity, from unchanged corrected PCB | Clean; 21 circuit and 15 layout fault controls pass |
| Both actual MCU targets | Pico 2 and XIAO RP2350 compile with pinned dependencies |
| Firmware host tests | Eight suites pass, including 54 shared C/Dart fixtures and the bounded 80-pixel bench diagnostic |
| PD repository | 228 tests pass; 602/613 covered lines, 98.21%, above 96% gate |
| App pedal and power-off integration | 117 tests pass |
| GPIO owner host tests | 12 pass, including failed owner, bounded contention, interrupted re-enable and live socket/signal lifecycle |
| Real systemd sequencing in isolated Linux container | Normal stop, restart and killed keeper finish low/discharge before compositor stop |
| Existing appliance regression suites | Reboot 6, Wayland 8 and Weston integration 16 checks pass |
| Static checks | Root Dart analysis, package formatter and 30-file bloc lint clean; whitespace and changed Markdown spelling clean |

The systemd fixture runs the production helper and power units, substitutes a
GPIO request with exclusive locking, and shortens the waits to exercise ordering.
It is not a screen-voltage or real-time measurement. Its
[sequence log](screen-systemd-results.json), [fixture](screen-systemd-fixture.py)
and [checks](verify-screen-systemd.py) retain the local experiment. The full
Yocto image has not been rebuilt or deployed in this work.

The test review found a missing console-to-ring integration check. It was
corrected and independently rechecked: actual host UART bytes traverse the
console loop and ring codec; corrupt traffic cannot renew the host lease;
expiration blanks all indicators and forwards goodbye; valid traffic restores
both. A killed-keeper ordering gap found during local integration was also fixed
before final architecture review. A final interrupted re-enable regression
also proves that termination during the settling wait drives low and finishes
discharge before releasing GPIO ownership; architecture and test reviewers
independently rechecked that correction.

## Review findings index

Final findings: **0 Critical, 0 Important, 0 Suggestions**. Initial findings and
resolved checks remain in the individual reports:

- [VGV](raw/vgv-review.md)
- [Architecture](raw/architecture-review.md)
- [Test quality](raw/test-quality-review.md)
- [Simplicity](raw/simplicity-review.md)
- [Readiness](raw/pr-readiness-review.md)

The surgical diff review found the completion changes traceable to the authorized
hardware/firmware fixes. Obsolete console-local codec files were replaced by one
shared library, without compatibility copies. Pre-existing unrelated changes
were preserved. No unrelated code was removed. This is a local software review,
not a CI-green PR-head or manufacturing release.

## Exact PCB artifacts

| Board | SHA256 |
| --- | --- |
| Screen revision I with IM02TS relays | `273c4503440df2d6f3431d1f176bc1ca2e11c4b8d55cd499a94efca23aa95e1e` |
| Corrected console v3 | `cbf7dc20c01cfac7ab92bc41b0adade64ac018550d7f733d55c6a89f01c046e5` |

Current local review packages are `2026-09-22-screen-power-preorder-fixes` and
`2026-09-22-console-preorder-fixes`. Native files, BOM, drawings, previews,
Gerber/drill ZIPs and manifests are included. Older packages are historical.
The firmware build outputs are available locally; the normal release workflow
builds the same targets. The ring requires its own UF2 installation; the console
SWD updater does not program the XIAO.

## Validation after assembly

1. **Cables and fit:** continuity/polarity of every purchased USB-to-XH lead,
   shield/USB-C attachment behavior, housing fit, power-lead termination, actual
   harness bend and mounting clearance. The UPERFECT's internal 480 Mbps hub
   means its relay/cable path needs high-speed operation testing.
2. **Power envelope:** measure the retained fixed-5-V buck at the board under
   load, screen main/touch current sharing, simultaneous startup droop/inrush,
   fuse coordination and hot relay/MOSFET behavior. The present switch check's
   5.0-V input floor and provisional 6-A load are assumptions, not measured
   guarantees. A lone slew capacitor was rejected because modeled variants
   either delay switch-off or create an off-state hot-plug pulse.
3. **Assembled sequence:** install matched firmware/image, exercise controls and
   ring wiring, then capture GPIO17 and screen rails during halt, reboot/update
   and restart. Establish the real discharge time and verify both panels are
   dark before HDMI disappears. The five-second software wait remains provisional.

The owner's HDMI-only test **passes**: both screens go dark with power/touch USB
removed and HDMI retained. It closes that bypass question only. The remaining
checks validate the assembled system; they are not prerequisites for buying
bare boards. Issue #1072 remains `autonomy:blocked-verify` for hardware
validation and merge. See the first-fabrication review for the supply-margin
assessment and the limits of the existing 5.0 V calculation.
