<!-- cspell:words Axicom fanout nonqualifying -->
## Architecture Review

Reviewed on 25 September 2026. Scope: the working Revision J delta from
`e98256a5a36f5341b9a521d63b6b951ca2b67f70`, with complete screen-switch
connectivity considered where needed to assess the correction. This is a
Python/SKiDL/KiCad hardware review; Dart, Bloc and presentation-layer criteria
are not applicable.

The review used the stable checkpoint supplied by the coordinator. Independently
verified SHA-256 identities:

| Input | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb` | `037d462c64196cca1d697975325be9b979a5360783949ed89c62c441ebef3032` |
| `hardware/kicad/screen_power/route_critical.py` | `783192ede2861c4156c2683939c4b2cbde0ad821a907a86cd1b6867b37221716` |
| `hardware/kicad/screen_power/switch_circuit.py` | `cbd54d055e2bb21a4449cac956bdd4779d39da548193661550dc2e43117395ad` |
| `hardware/kicad/screen_power/check.py` | `c60edff01da613431bdaa0a1c1b1330020d7779a5339f5a567d1d6682c977d0d` |

### Layer Separation

- Violations found: 0.
- The circuit generator owns parts and pin-level nets. Placement owns the
  existing outline and component positions. Critical routing owns USB pairs,
  reference reservations and power distribution; the remaining routing,
  finishing and validation stages retain their existing responsibilities.
- No dependency, extra component, board enlargement or new design abstraction
  is introduced. Native comparison against the base found the same 41
  footprint references, values, footprint identities, positions and rotations:
  37 populated components plus four mounting holes. The native outline remains
  68 × 76 mm with the existing rounded corners and two copper layers.

### Circuit State Assessment

**Relay enable/off topology: correct at the reviewed checkpoint.** The
[TE/Axicom manufacturer drawing, terminal assignment on page 5](https://www.farnell.com/datasheets/477186.pdf)
shows the non-latching relay from the component side: commons 3/6, resting
contacts 2/7, energized contacts 4/5, coil positive 1 and negative 8. Native
footprint coordinates preserve that orientation. K101 and K201 both connect
host D− to 3, host D+ to 6, screen D− to 4 and screen D+ to 5. Pads 2/7 have
no assigned net. The relay coils use the correctly polarized host-VBUS supply
and low-side drivers.

The native board's actual KiCad copper connectivity was used to construct a
second connectivity graph, then the datasheet contact closures were applied.
All four possible two-relay states passed 16 upstream-path assertions: each
energized channel connects only its matching D− and D+ endpoints; a released
channel reaches neither screen endpoint; no channel or polarity crossing
appears. This does not rely solely on matching the generator's expected pin
numbers.

**Power-switch and control topology: correct within the documented operating
scope.** Native Q3/Q4 pads are gate 1, drain 2, source 3, consistent with the
[Vishay SUP70101EL drawing](https://www.vishay.com/docs/77632/sup70101el.pdf).
The two sources are physically joined, with drains at AUX and SWITCHED_5V.
The opposed body-diode arrangement provides the intended off-state blocking
in either direction; it does not provide reverse-current blocking while the
channels are enabled. R4 returns the gates to the joined sources. Q1 pulls
through R3 when enabled. D1's cathode is at CONTROL_SINK and its anode is at
BUFFER_SINK, preventing a charged output from using Q2's base network to
pull the power gates down toward an absent AUX rail.

Native Q1 and Q2 assignments agree with the manufacturer's E-B-C TO-92
pin order for [2N3904](https://www.onsemi.com/pdf/datasheet/2n3904-d.pdf) and
[2N3906BU](https://www.onsemi.com/download/data-sheet/pdf/2n3906-d.pdf).
Q101/Q201 use source 1 at ground, gate 2 at DATA_ENABLE and drain 3 at the
coil, matching the [2N7000 datasheet](https://www.onsemi.com/pdf/datasheet/nds7002a-d.pdf).
The pull resistors provide the intended disabled state when control is low or
disconnected. Flyback-diode cathodes terminate at their respective host VBUS.
Host VBUS remains separate from every screen-power branch. R8 is still a
passive switched-rail bleeder, not an active discharge or timing circuit.

### Dependency Direction and Native Parity

- Direction violations: 0.
- Source review confirmed that both channel declarations use the corrected
  contact mapping. The generated component records and netlist contain only
  the intended relay contact reassignment.
- An independent fresh KiCad export of the full native schematic matched the
  generated netlist's complete physical component set and semantic nets.
- Every native PCB pad matched the generated netlist. An independent walk of
  native copper connectivity found no disconnected assigned-net terminals.
- The corrected contact check reasons about relay state, with no-connect
  terminals remaining isolated; it is a suitable architectural guard against
  repeating the original mutually-consistent but incorrect pin-map contract.

### Physical Package and Routing

- A fresh KiCad 10 DRC, with zone refill, all track errors and all severities,
  returned 0 violations and 0 unconnected items.
- Both channels retain 0.85 mm B.Cu data tracks without data vias. Each host
  pair member measures 23.357803 mm; each screen pair member measures
  26.351514 mm. Each corresponding pair has zero reported length skew.
- The native filled F.Cu reference passes 5,452 center/edge samples at at most
  0.1 mm spacing, outside the documented 1.35 mm terminal exclusions. The
  rounded fanout reservations keep the narrow coil-control channel from
  violating the revised contact-column geometry. This is geometric reference
  continuity evidence, not an impedance or USB-compliance measurement.
- The actual board contains continuous 1.9 mm minimum power paths at the
  selected TO-220 necks, the retained 3 mm connecting sections and 4.5 mm
  shared trunk, 2 mm main-output paths and 0.8 mm touch-power paths.
- C2 pin 1 has the new continuous 1.5 mm front-side feed. Its final bends
  avoid its ground pad; the existing capacitor position is unchanged.
- Three SWITCHED_5V vias at (46.4, 24.5), (47.5, 24.5) and (48.6, 24.5) mm
  have 0.9 mm copper diameter and 0.45 mm drills. Each lands in wide copper
  on both faces and belongs to the device-to-distribution path. They supplement
  the plated F101 terminal rather than relying on the fitted fuse lead.
- The supplied fresh Revision J 3D render shows the retained upright devices,
  keyed connectors and component arrangement. It establishes no enclosure or
  optional-heatsink clearance claim.

### Coverage Limits

The original advisory report was read alongside its assessment; unsupported
unconditional thermal, startup/SOA, fuse-clearing and universal heatsink-fit
claims were not accepted. The documented shared 6 A design allowance includes
main and touch outputs and the bleeder; branch ceilings cannot be added as a
simultaneous guarantee.

No assembly was measured. Thermal rise, actual screen inrush, fuse coordination,
control discharge time, relay hot restart, cable pinout/CC/shield behavior,
USB signal integrity and enclosure fit remain hardware-validation matters.
This review found no additional concrete CAD fault establishing a required
circuit change. It does not certify a 6 A assembly rating or screen operation.

The full build was not regenerated by this reviewer. Source declarations,
native schematic parity and final native copper were inspected directly;
fresh native DRC and focused power/USB checks were rerun. The coordinator's
35 passing mutation checks were observed in the validation artifact but are
not represented here as an independently rerun complete self-test. Manufacturing
exports and the final publication documentation were still pending and are
outside this report's coverage.

### Verdict

Architecture and electrical topology are clean for the reviewed correction.
No actionable Critical, Important or Suggestion findings were identified in
scope. This verdict is tied to the native-board and source hashes above and
does not authorize an order or replace the separate export verification.

### Final checker amendment review

Reviewed the subsequent `check_power` amendment at `check.py` SHA-256
`485dc24f5a5310ebc56504076fafb7a9512b6dbd9fe1764843f714861198ceb9`.
The native board remains
`037d462c64196cca1d697975325be9b979a5360783949ed89c62c441ebef3032`.

The additional disposable-board check removes F101.1's original plated
transition, narrow tracks and nonqualifying vias before rebuilding connectivity.
Requiring a surviving Q4.2-to-F201.1 path correctly distinguishes a useful
shared-power bypass from vias that merely touch a dead-end top island and
reach the distribution rail through the original fuse barrel. This preserves
separation between verification and the delivered native design: the mutation
is made only to a newly loaded in-memory board.

Independently reran the amended power check on the production board: no errors.
Independently recreated the three-via top-island mutation at x = 39, 40.1 and
41.2 mm, y = 20 mm: it produced exactly `power_via_bypass`, confirming that
the added check detects the targeted false positive while the older qualifying
via criteria still pass. The coordinator reports 36/36 complete self-tests;
this reviewer reran the focused production and island cases only.

Final verdict: no unresolved architectural or electrical findings at this
amended checker hash and unchanged native-board hash. The earlier coverage
limits, including separate manufacturing-export verification, remain in force.
