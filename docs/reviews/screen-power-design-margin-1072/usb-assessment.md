# Screen power USB assessment

<!-- cspell:words UPERFECT APROTII Mbps fanout fanouts microstrip JLCPCB reterminated pinout -->

Date: 2026-09-25. Scope: the existing through-hole, two-layer screen power
board and a bounded routing refinement. No USB fault has been demonstrated.
The candidate is preserved in [usb-routing-candidate.patch](usb-routing-candidate.patch)
and awaits adoption; the published board and manufacturing package are unchanged.

## Actual link and present layout

The appliance observation recorded on 2026-09-22 identifies the UPERFECT
touch controller (`0457:0819`) at 12 Mbps **behind a 480 Mbps hub** (`1a40:0101`).
The APROTII controller (`1a86:e5e3`) attaches directly at 12 Mbps. Both screen
cables plug directly into the Pi, according to the owner. The UPERFECT upstream
path therefore needs to preserve high-speed USB; its slower touch controller
does not justify silently restricting the whole path to full speed. See the
[recorded topology and cable selection](../../../hardware/kicad/screen_power/README.md).

Each channel routes both data conductors through an IM02TS relay between
four-pin JST XH connectors. The approximately 49.71 mm copper route per
conductor uses B.Cu, no data vias, 0.85 mm trace width and 0.16 mm pair gap,
with F.Cu ground beneath it. About 33.6 mm of the current route is closely
paired; connector and relay fanouts occupy the remaining length. The
[TI USB layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf)
supports minimizing pair separation and maintaining a continuous reference.
The existing dimensions and discontinuities are engineering considerations,
not evidence that this assembled link has failed.

## Nominal impedance and its limits

An independent calculation using the
[KiCad 10.0.4 coupled-microstrip implementation](https://gitlab.com/kicad/code/kicad/-/blob/10.0.4/common/transline_calculations/coupled_microstrip.cpp)
reproduced approximately **89.64 ohms differential** for 35 micrometers of
copper over a 1.53 mm dielectric with relative permittivity 4.4, matching the
documented nominal design. Substituting relative permittivity 4.5 gives
approximately 88.84 ohms. These are suitable nominal targets around the
90-ohm USB differential impedance; they are not a measurement of the board.

[JLCPCB's published capabilities](https://jlcpcb.com/capabilities/pcb-capabilities)
list ordinary board-thickness and track-width tolerances and controlled
impedance service for four or more layers. The selected two-layer order does
not purchase that service. Solder mask and finite adjacent copper are omitted
from the calculation. Solder mask changes impedance, but no verified mask
thickness tolerance for this exact order establishes a justified trace-width
correction. Changing the nominal geometry on a guessed mask value would not
prove compliance. See also
[Polar's solder-mask discussion](https://www.polarinstruments.com/support/cits/AP169.html).

## Candidate and verification

The retained patch couples the traces closer to their terminals and extends
the corresponding F.Cu reference protection. It adds **6.9 mm of closely
paired run per channel**, from 33.6 to 40.5 mm, without extending the total
data route or moving connectors, relays or power routing. It reduces avoidable
fanout discontinuity while preserving the selected connectors and assembly
method.

The isolated full build completed with KiCad 10.0.4 on 2026-09-25. The
[retained validation summary](usb-candidate-validation.json) records:

- Zero DRC or ERC errors, warnings, exclusions or unconnected items.
- All 36 existing self-check cases passing.
- 5,360 passing USB ground-reference samples at 0.1 mm intervals, checking
  trace centers and both copper edges outside the terminal exclusions.
- Equal positive/negative trace lengths on all four segments: 23.357803 mm
  upstream and 26.351514 mm downstream on each channel.

The scratch board SHA-256 is
`2553693464455dd3a3fce93b1f420aee2affb61b464e28dcc997bcfb02f708da`.
These checks establish CAD consistency, not an eye-diagram or complete-link
USB compliance result. The candidate source was subsequently restored to the
published version; applying the saved patch and republishing remain pending.

## Replaceable cable uncertainty

The selected ready-made leads are USB-A to XH at 30 cm, USB-C to XH at 25 cm,
and Micro-B to XH at 30 cm; the owner reports 28 AWG conductors. Wire gauge
alone does not establish a twisted differential pair, shielding, controlled
impedance or USB-C plug configuration. Those construction details are not
documented by the available product information. The short board and the
longer cable assemblies must be considered together.

Retain the purchased connector choice: there is no demonstrated reason to
declare it unusable. A cable with unsuitable construction can be replaced
or reterminated without replacing the PCB. Pinout correction alone would
not repair unsuitable differential-pair construction. The routing candidate
improves the board contribution but cannot certify an unknown cable assembly.
