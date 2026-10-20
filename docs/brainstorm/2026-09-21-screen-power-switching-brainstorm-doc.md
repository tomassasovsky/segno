---
date: 2026-09-21
topic: screen-power-switching
status: proposed
issue: 1072
---

<!-- cspell:words EDID UPTJ backfeed -->

# Switch screen power before HDMI shuts down

Tracking: [#1072](https://github.com/tomassasovsky/segno/issues/1072),
`stage:brainstorm`, `autonomy:blocked-verify`.

## What We're Building

The screens currently receive power directly from BUCK_AUX. They stay on when
the Pi stops sending HDMI and show their blue no-signal screen. Route their
power through a PCB so orderly shutdown turns them off before video disappears.
Keep the existing two buck converters and the independent Pi power button.

This document recommends the next design; it does not add switching to the
console or ring boards delivered by #1062 / PR #1066.

## Why This Approach

Recommend a small, separate screen-power board with its own feed from BUCK_AUX,
two switched outputs and a shared Pi-controlled enable. It separates display
power and cable requirements from the console's controls and MIDI circuitry.

| Approach | Assessment |
| --- | --- |
| Separate screen-power board | Recommended. Dedicated supply branch, room for output protection and proper connectors; needs mounting and a control cable. |
| Integrate into the console PCB | Possible, but requires a separate power input or a redesigned input path, more connectors and a new layout. The existing 99.5 mm board is crowded. |
| Switch from Pi power state alone | Insufficient to guarantee no blue frame: HDMI can disappear before the Pi's power rails turn off. |

Do not feed both screens through existing J3. Its single JST VH power contact
is rated around 10 A; the existing worst-case AUX model totals 10.78 A including
screens, logic and all LEDs. Keeping the buck is an established owner decision;
this feature does not establish its simultaneous full-load margin.

## Key Decisions and Requirements

- **User requirement:** remove screen power at Pi shutdown so no blue no-signal
  screen appears. Both displays must be dark with the Pi off.
- **Recommended circuit:** switch each positive 5 V branch and keep ground
  continuous. A ground-side switch would be bypassed by USB/HDMI grounds.
  Use load switches with controlled startup, adequate current and defined
  reverse-current behavior, plus appropriate branch protection and discharge.
- **Recommended control:** active-high enable with an external pull-down, so
  unplugging the control cable defaults to off. GPIO17 / physical pin 11 is a
  candidate, unassigned in the current Pi header map. Confirm the deployed pin
  ownership. J22 exposes Pico signals, not a ready Pi control connection.
  Design an explicit keyed connector or ribbon interposer.
- **Orderly shutdown:** finish the existing save/goodbye sequence, switch off
  screen power, wait for the measured display power-down interval, then permit
  HDMI teardown. Cover system shutdown and update reboot as well as the app's
  button. Keep this in the appliance service/helper layer.
- **Reboot/startup:** retain the off default across reset. Restore power at a
  tested video milestone; verify that initially unpowered panels still produce
  correct modes and touch mapping. The current forced HDMI modes help but do
  not prove that cold boot without EDID works.
- **No alternate power path:** test each touch USB and HDMI connection with
  main screen power removed. If USB VBUS sustains the display, include it in
  the switched path while preserving valid USB sensing and enumeration. Do not
  assume cutting a cable wire solves this, or blindly remove HDMI power/HPD.
- **Forced power-off:** the circuit must turn off when the Pi control domain
  dies without relying on application code. Verify its timing separately;
  orderly shutdown tests do not prove a blue-free forced shutdown.

Pi `POWER_OFF_ON_HALT=1` can shut down the Pi 5 PMIC outputs; check the actual
EEPROM and coordinate provisioning with #826. It is not a replacement for the
early screen-off sequence. The `gpio-poweroff` overlay runs at final power-off
and changes the host shutdown sequence, so it is not the proposed screen-only
control. See [Pi power-off configuration](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#POWER_OFF_ON_HALT)
and the [overlay contract](https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.12.y/arch/arm/boot/dts/overlays/README).

An enable-owning system service must hold the GPIO while screens are on and
explicitly drive it low on stop. Its dependency ordering must stop it before
Weston; `After=` reverses order during shutdown. A process being started is not
a video-ready signal. See [systemd ordering](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#Before=).

## Known Hardware and Open Questions

The main panel is UPERFECT UPTJ14. The owner's
[in-hand correction on #705](https://github.com/tomassasovsky/segno/issues/705#issuecomment-5305050976)
confirms separate USB-C power/touch and 5 V power support. The old PD-required
warning in the wiring document is therefore stale; full-brightness current and
alternate power paths still need measurement. The 7-inch APROTII's exact
electrical model and connector arrangement need recording.

Before selecting parts and freezing a layout:

1. Record both panel labels and actual power, touch and HDMI cables. Measure
   whether either alternate connection can keep a display lit or backfeed a
   supply with the main power input disconnected.
2. Measure each panel's full-brightness current, startup peak and turn-off
   delay, plus voltage at the screens under the intended combined LED load.
3. Choose connectors and the USB-C source circuit from that evidence. Native
   USB-C outputs need correct attach detection and current advertisement.
   TPS22953 is a candidate 5 A load switch; TPS25810 is a candidate integrated
   3 A USB-C source. Neither is selected yet. Review maximum ratings, voltage
   drop, thermal limits and discharge behavior, not only typical resistance.
   [TPS22953](https://www.ti.com/product/TPS22953),
   [TPS25810](https://www.ti.com/product/TPS25810).
4. Confirm board mounting and control-connector clearance in the enclosure.
5. On both real screens, verify normal shutdown, reboot/update, forced off,
   control-cable disconnect, and cold boot. Observe the displays and rail
   timing; logs alone cannot prove that no blue frame appeared.

## Boundaries

No change to the Pi power-button floating pair, no additional buck, no switch
in the Pi supply, and no HDMI high-speed routing through the proposed board.
An OS hang or unplugged HDMI cable while the Pi remains on needs separate
video-valid detection if that behavior is later required. The schematic,
board layout and appliance integration are subsequent implementation work;
electrical behavior remains subject to physical validation.
