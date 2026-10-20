<!-- cspell:words AHCT XIAO onsemi Littelfuse VREG BAT SOA GPIO SWD VSYS VBUS Seeed heatsinks -->
# Console, ring and system power review

Reviewed hardware `d32bca8b24c543b907ee1f104ebf8b04f6fa6947` on September 26,
2026. The independent reviewer found no circuit or power-copper defect requiring
another PCB layout change for one unrestricted full-white 40-pixel ring,
normal pill patterns and the 4.25 A combined-screen allowance. Subsequent
silkscreen changes require new native validation but preserve this circuit.
The subsequent end-to-end voltage challenge found a harness margin gap; the
[star-feed correction](ring-voltage-margin.md) supersedes the earlier straight-through
power wiring. With that correction, this supports first fabrication; it does
not certify an assembled unit.

## Circuit coverage

The saved native boards exactly match their netlists: **206 console and 63 ring
connected pads**. Fresh native power-path guards pass on all three boards.
The companion JSON records the reviewed inputs and calculations.

- Console J3 feeds Pico VSYS and the 5 V loads. Ribbon 5 V pins and Pico VBUS
  are unconnected. Pico 3V3 supplies CTRL bias; Pi 3V3 remains a separate domain.
  H1 is the chassis bond and the other mounting pads are isolated.
- The complete Pico pin budget, Pi UART and MIDI lines, SWD, ten switches,
  CTRL tip/ring/presence inputs, PD header and GPIO17/J25 were checked against
  native pads. J8/J9 carry the isolated Pi power-button pair. UART resistors
  limit cross-domain current; they are not galvanic isolation.
- Console AHCT125 enables only its used gates and ties unused gates correctly.
  It drives pills and MIDI OUT. H11L1 runs from Pi 3V3 with the correct input
  resistor, reverse diode and output pull-up. Do not substitute H11L2/H11L3.
- CTRL inputs are intended for passive switches/expression pedals. Their bias
  stays within ground and Pico 3V3. No powered-CV or industrial ESD rating is
  established by this review.
- Console J6 and ring J1 are identical: 1 = +5 V, 2 = ground, 3 = console TX
  to ring RX, 4 = ring TX to console RX. XIAO side pad 10 is D9/GPIO4 RX;
  pad 11 is D10/GPIO3 TX. Link pull-ups are only on the console Pi 3V3 rail.
- The ring encoder uses local 10 kΩ/100 nF filters. XIAO GPIO26 drives the
  correctly enabled AHCT125 gate through the LED data resistor. Bypass and
  unused-gate ties are correct. J2/J3/J4 are alternative LED connections;
  only the selected J2 strip is populated.
- Ring D1 feeds only the XIAO controller, not the LED current. Seeed's pad 14
  is USB VBUS. Unplug J1 before USB programming because the external diode
  does not block AUX power from reaching the USB host.
- J23 is ground/SDA/SCL. SparkFun provides 2.2 kΩ pull-ups from its VDD supply,
  normally fed by VREG_2V7 through BAT60A. There is no 20 V path to the Pico.
  Do not connect external 5 V to that logic supply. The matching runtime uses
  bounded 100 kHz reads with Pico internal I2C pulls disabled.

Primary sources: [Pico 2](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf),
[RP2350](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf),
[TI AHCT125](https://www.ti.com/lit/ds/symlink/sn74ahct125.pdf),
[onsemi H11L1 family](https://www.onsemi.com/download/data-sheet/pdf/h11l3m-d.pdf),
[Seeed schematic](https://files.seeedstudio.com/wiki/XIAO-RP2350/res/Seeed-Studio-XIAO-RP2350-v1.0.pdf),
[1N5819](https://www.vishay.com/docs/88525/1n5817.pdf),
[ALPS encoder](https://tech.alpsalpine.com/assets/catalog/product-catalog-ec-all.en.pdf),
[Neutrik NJ6FD-V](https://www.neutrik.com/en/product/nj6fd-v.pdf),
[SparkFun PD schematic](https://cdn.sparkfun.com/assets/9/2/6/8/6/SparkFun_PowerDeliveryBoardSchematic.pdf),
[STUSB4500](https://www.st.com/resource/en/datasheet/stusb4500.pdf).

## Power and temperature

The independently recomputed AUX budget is **7.608 A / 38.04 W**. Together
with the separate 25 W Pi allowance, approximately 70.0–74.2 W input is needed
at an assumed 90–85% buck efficiency, below the configured 100 W PD contract.
All 120 LEDs at flat white plus the screens would require **11.91 A** and
remains outside the retained 10 A AUX supply's scope.

The console ring supply is 93.007795 mm at 1.7 mm width; the carrier supply
is 21.731202 mm at 1.5 mm. At 2.64 A/2.44 A their nominal positive-track drops
are 72.22/17.67 mV. At 100 °C copper and 20% negative width tolerance these
become 118.65/29.04 mV. The IPC-2221 estimate gives about 7.54/7.75 °C rise
at reduced widths. Four console supply vias and three ring return vias remain
present. These estimates exclude harness/contact/return losses.

[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf) rates 3 A with 22 AWG.
The ring's 2.64 A is within that rating. The 85 °C operating maximum includes
current-induced heating; it is not an 85 °C ambient allowance at 3 A. At the
20 mΩ post-environment contact limit, each contact dissipates 0.139 W. Actual
enclosed rise is unmeasured. The initial nominal 600 mm cable illustration
omitted aged contacts, hot wire, console input and return losses. The final
[voltage-margin review](ring-voltage-margin.md) rejects that straight-through
harness for a guaranteed AHCT operating voltage. Use its separate direct AUX
feed to the LED strip and short low-current branch to J1. The PCB's full-current
copper stays unchanged, but the selected strip no longer sends LED current
through the long console path or J1 contacts.

[JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf) rates 10 A with 16 AWG.
The input fuse/holder and 16 AWG screen branch match their specified ratings.
Main-screen leads are at most 30 cm, 20 AWG or larger, with 3 A terminations.
Touch leads have a 500 mA operating allocation. Fuses do not impose those
ceilings or guarantee survival of every sustained partial overload. Both
proper main feeds must remain connected if a screen shares its input rails.

At 4.25 A, 15 mΩ maximum resistance times the documented 1.7 hot factor gives
**0.461 W per MOSFET**, 0.217 V for the pair. The assumed 60 °C local ambient
and 75 °C/W upright model yield **94.5 °C junction**. This supports operation
without heatsinks at the planning load. It is an estimate, not the datasheet's
40 °C/W mounting condition. The two drain tabs are different nets; never join
them with an uninsulated heatsink. [Vishay SUP70101EL](https://www.vishay.com/docs/77632/sup70101el.pdf).

The primary SOA/transient plots were inspected. The documented startup pulse
and capacitance sweeps provide useful margins, but their charging assumptions
are not a controlled ramp or measured screen capacitance. Hot upright fault
survival is not established by a 25 °C-case SOA curve. No need for an additional
active startup limiter was demonstrated for the stated loads. The screen
review independently obtains 5.218 V stressed gate drive after modeled copper
loss, above the 4.5 V resistance-rating point.

## Mechanical and assembly boundaries

The current screen STEP envelope is unchanged. At the proposed location it
retains 21.2 mm adjacent platform/buck clearance, 27.2 mm to the tower,
43.08 mm to the conservative lid envelope and 6.865 mm below untrimmed leads.
All seven enclosure-source hashes in the earlier assessment are unchanged.
The proposed 15 mm standoffs and four floor holes still need incorporation in
the enclosure release. This is not a completed mated-cable/Fusion fit check.
Console outline/hole pattern match the enclosure source and its 12.495 mm
STEP height fits the 16 mm allowance. The carrier's saved STEP shows the
24-module option; it cannot prove the separate 40-strip housing's fit.

The review found and the release corrects these assembly-document problems:

1. Required v3 runtime is PR #1082 at `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d`.
   Its actual E9 helper disables the input buffer between reads, enables it
   briefly with interrupts preserved and resolves A2 presence detection.
   The hardware branch's older firmware snapshot lacks that workaround.
2. Remove obsolete v2 J6 pin 5/6/7 and unused ring-data statements.
3. Disconnect console J3/J6/J24 before Pico USB programming, or program the
   module before fitting it. USB otherwise feeds VSYS and the AUX loads.
   Remove USB before reconnecting. Normal in-place programming uses SWD.
4. Select the existing 40-LED strip in the purchasing BOM; leave J3/J4 empty.

No new owner measurement campaign or pre-PCB build is required. First assembly
still verifies workmanship, cable polarity, touch operation, shutdown timing
and actual enclosed temperatures. Those are physical checks, not CAD guarantees.
