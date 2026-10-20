<!-- cspell:words IRLZ Infineon NPBF Omron Schurter autorouter backorder centerlines derating desoldering millifarads onsemi pypdf -->
<!-- cspell:words Littelfuse pulldown backfeed -->
# Screen power: stocked parts and lower cost — #1072

Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072). Hardware PR:
[#1080](https://github.com/tomassasovsky/segno/pull/1080).

**Current implementation decision, 28 September 2026:** only the main input
fuse F1 will be replaceable without desoldering. Use one Schurter SPT
**0001.2513** 8 A cartridge in an **OGN 0031.8201** PCB holder, and retain
four soldered Bel 0697H time-delay branch fuses. This preserves a serviceable
input fuse while avoiding the cartridge and clip cost on every output.

| Position | Selected fuse | Mounting / purchase quantity |
| --- | --- | --- |
| F1, 8 A input | Schurter SPT **0001.2513**, 5 × 20 mm | One cartridge plus one separately counted **OGN 0031.8201** holder |
| F101/F201, 4 A main outputs | Bel **0697H4000-02** | Two soldered radial through-hole fuses |
| F102/F202, 800 mA touch outputs | Bel **0697H0800-02** | Two soldered radial through-hole fuses |

The fitted BOM and purchase list each contain **five fuses and one input
holder**. No output clips, output cartridges or spare holders are included.
Branch-fuse replacement requires desoldering; instructions must not describe
all five positions as removable. F1 must have access for cartridge removal
with power disconnected.

The fresh complete Mouser US quote shows **53 lines / 168 units, all requested
quantities Ships Now**. Its **$86.56 before-tax estimate** includes tariffs
and $8.49 estimated US shipping, versus $97.62 for the fully socketed
proposal. This is not an order, reserved stock or a shipping quote for a
specific Miami address.

Use the [Bel branch-fuse selection](../reviews/screen-power-stock-cost-1072/branch-fuse-selection.md)
and [input-holder/coil assessment](../reviews/screen-power-stock-cost-1072/holder-coil-budget.md)
for the selected component limits. The old [soldered input-fuse assessment](../reviews/screen-power-stock-cost-1072/input-fuse-assessment.md)
is superseded for F1's part, holder losses and coil margins. The S506/clip
assessment concerns an unselected alternative and is not the present release
basis. None of these electrical assessments is final native-layout or
fabrication approval.

Status: source circuit, BOM and native routing implemented. Native checks,
filled-copper analysis and manufacturing export are complete; the linked
revision review records the final independent verdict and artifact identities. The owner authorized a redesign that can
be assembled by hand and purchased in one stocked Mouser US shipment. This
document records that direction without authorizing an order, merge, flashing
or deployment. The existing released files retain their identity until a
complete replacement passes its checks.

## Problem and selected circuit

The two SUP70101EL-GE3 power MOSFETs cannot currently be supplied from Mouser
without a long backorder. Their negative supply, optocoupler and associated
parts also increase cost and assembly work. Replace that power stage with one
normally-open relay and a low-loss coil driver. Retain the established GPIO
buffer, independent USB host-presence controls and selected cable interfaces.

| Reference | Selected part | Connection or change |
| --- | --- | --- |
| F1, new | Schurter 0001.2513 in OGN 0031.8201 | Replaceable 8 A time-delay input cartridge immediately after J1: AUX_5V_IN to AUX_5V, before every board power load. |
| K1, new | Omron G6C-1117P-US-DC5 | Normally-open contact from AUX_5V to SWITCHED_5V; coil positive from AUX_5V. |
| Q5, new | Infineon IRLZ44NPBF | Low-side coil driver: drain to K1 coil negative, source to GND, gate to DATA_ENABLE. |
| D3, new | Littelfuse P6KE6.8CA | Bidirectional TVS directly across K1's coil, with a short local loop. |
| R7 | 10 kΩ, 1% | Reduce the existing 100 kΩ DATA_ENABLE pulldown to discharge Q5's larger gate and preserve a firm default-off state. |
| C1/C101/C201 | Vishay K104K10X7RF53H5 | Replace the three retained film bypass capacitors with 100 nF, 50 V, X7R, 5 mm lead-spacing through-hole parts. |
| D101/D201 | onsemi 1N4007G | Retain USB relay flyback topology and polarity; use exact Mouser 863-1N4007G. |
| F101/F201 | Bel 0697H4000-02 | Replace 4 A fast axial fuses with soldered 4 A time-delay radial through-hole fuses for relay turn-on. |
| F102/F202 | Bel 0697H0800-02 | Replace 750 mA fast axial fuses with soldered 800 mA time-delay radial through-hole fuses; retain the 500 mA nominal touch-power budget per channel. |

Remove these twelve populated references: **Q3, Q4, U1, U2, C3, C4, C5, D2,
R3, R4, R9 and R10**. Remove their obsolete negative-supply, optical-drive and
common-source nets, models and checks where no remaining component uses them.
Do not retain an alternative pump-based build path.

J1 pin 1 is the raw **AUX_5V_IN** net. Only J1 and F1's input terminal belong
to that net. F1's output retains the name **AUX_5V** and feeds the input
capacitors, power and USB relay coils, control supply and power contact rail.
There must be no raw-input bypass around F1. F1 protects this screen board's
branch; the console and ring do not acquire their power through it.

Remove the external 7.5 A ATO fuse and holder from the proposed harness and
shopping list. Use a **very short 16 AWG incoming pair**, with insulated,
secured and strain-relieved routing between the buck and J1. **The PCB fuse
cannot protect this incoming wire or a short on its upstream side.** Record
that limit plainly in the wiring instructions; do not imply moving the fuse
onto the PCB gives protection to the entire supply cable.

Keep Q1/Q2, R1/R2/R5/R6/R7, all four USB TN0702 devices, K101/K201, all four
branch protection positions with the selected replacement fuses, R8's
100 Ω/1 W discharge path and the existing bulk capacitors.
Q1/Q2 drive gates and the DATA_ENABLE pulldown only; the new power-relay coil
current bypasses both bipolar transistors. R7's new 10 kΩ value draws about
0.525 mA at 5.25 V, before its tolerance allowance. Verify Q2's saturation
with this load and its existing approximately 0.7 mA base drive. R7 pulls
Q5's gate down when Q2 releases DATA_ENABLE.

G6C-2117P-US is **one normally-open plus one normally-closed contact**, not two
normally-open poles. It is not a substitute for the selected part or a way to
delete the retained USB enable stage. Do not parallel unrelated relay contacts
or rely on undocumented ordering between power and data contacts.

## Fixed boundaries

- Preserve the 68 × 76 mm outline, 3 mm corner radii, four mounting-hole
  positions, two copper layers, purple mask and existing connector locations,
  orientations and pinouts. Keep all solder joints accessible from the bottom.
- Preserve all eight USB data nets' actual centerlines, widths, layers,
  differential spacing, length relationship and absence of data vias. Retain
  the ground reference underneath and local shield-drain access. No USB
  connector, data relay or purchased XH cable interface changes.
- Preserve the console board, ring board, threaded encoder selection and
  40-LED strip's unrestricted full-white allocation. Recalculate the shared
  AUX budget for the changed screen control load without reallocating that
  ring allowance or assuming all 120 ring/pill pixels can run full white.
- Pi host VBUS continues to supply only its presence-divider input. It must
  not feed a screen power pin, AUX rail or relay coil. Screen ground stays
  continuous; switching the return would permit alternate touch-ground paths.
- A released or weakly pulled GPIO keeps power and touch data disabled. When
  disabled, or after release with AUX absent, an externally powered screen
  output must have no contact or diode path into AUX. A closed relay is
  bidirectional; do not claim reverse blocking while it is deliberately on.

## Electrical basis and limits

The [Omron G6C datasheet](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6c.pdf)
specifies 30 mΩ maximum initial contact resistance, 10 A at 30 VDC resistive,
70% maximum pickup at 23 °C and a 5 V, 125 Ω, 200 mW coil with ±10%
resistance. Its ordinary non-FD contact family also has tungsten and DC motor
load approvals. These support selecting a robust power contact, but do not
certify an arbitrary 5 V capacitive pulse. Initial resistance is not a
guaranteed lifetime limit. Its sample temperature plot and varying-voltage
maximum are not a guaranteed coil self-heating curve.

At the **4.31 A contact allowance** (4.25 A screens plus 60 mA bleeder),
30 mΩ contributes **0.1293 V** and **0.557 W**. Keep the fuse, connector, copper and harness
losses in the complete voltage budget. Account for the coil and retained USB
control load separately. The final bound explicitly allocates 4.25 A to
screens and 60 mA to R8, preventing ambiguity about the bleeder.

The supply requirement remains **4.75 V measured at J1**, on AUX_5V_IN,
**before F1 and its holder**. Do not silently apply it to the fused AUX_5V
rail. The replaceable input assembly changes the working coil-feed budget:

| J1-to-coil loss | Allowance | Basis |
| --- | --- | --- |
| F1 cartridge | 100 mV | SPT 8 A published maximum drop at rated current, carried as a working allowance at lower load; not a guaranteed 60 °C maximum. |
| OGN holder | 1.5 mV before K1 closes; 44.6 mV at full load | The holder's complete-terminal-path 10 mΩ specification applied to the 150 mA pickup allowance or 4.46 A loaded allowance. Do not count it once per end. |
| Shared/local positive and ground-return copper | 20 mV | Layout target requiring calculation from actual lengths, widths, layers, pads, vias and return paths. |
| Q5 | 5 mV | Covers the doubled-resistance driver estimate at the relevant coil current. |
| Total | 126.5 mV at pickup; 169.6 mV fully loaded | Leaves **4.6235 V before K1 closes** or **4.5804 V fully loaded** from 4.75 V at J1. |

K1's normally-open contact isolates the screens during pickup, so the input
assembly then supplies only coils and control. Retain a conservative 150 mA
allowance for that state, including the USB coils. A 4.46 A screen-board
load is not present before the power contact makes. Subsequent capacitor
charging and contact bounce belong to the separate startup assessment.

Branch the coil/control feed near F1's protected terminal so the long
switched-load bus does not consume the coil-feed copper budget. At 4.46 A,
20 mV corresponds to 4.48 mΩ if the entire allowance were shared copper;
weight the local coil-only path by its much lower current. The final layout
must substantiate this target; wide-looking traces are not evidence.

Use a rounded **4.46 A screen-board input allowance**, including switched
screen load, 60 mA for the bleeder, and a combined 150 mA for both USB coils,
K1's coil, TVS leakage and control current.
Recheck the SPT cartridge's temperature derating and the OGN holder's power
acceptance against their own specifications. Do not carry over the removed
Bel fuse's 90% graph reading. The OGN has a 16 A UL/CSA rating and an ambient
limit of 85 °C; neither alone proves acceptable contact temperature on this
board. Its 10 mΩ resistance is a specified measurement under stated
conditions, not an unlimited-life hot-contact guarantee. F1 is supplementary
protection, not an 8 A current clamp or a rapid-clearing promise from a
nominal 10 A buck.

The [IRLZ44NPBF datasheet](https://www.infineon.com/assets/row/public/documents/24/49/infineon-irlz44n-datasheet-en.pdf)
specifies 35 mΩ maximum at VGS = 4.0 V. Verify the retained buffer supplies at
least this gate voltage after F1 at the normal J1 input floor. Even a doubled
resistance allowance spends less than 5 mV at 65 mA, but that does not absorb
or replace the shared input-fuse drop. Include low-temperature coil
resistance, tolerance and TVS leakage when calculating maximum driver current.
With an additional conservative 0.4 V Q2 drop, its fully loaded gate rail is
at least **4.186 V**, above Q5's 4 V resistance specification point and the
retained USB TN0702 devices' 3 V point.

Use **100 °C winding temperature** as an explicit hot-restart design budget
with 60 °C local enclosure air. With a conservative copper coefficient of
0.004/°C, maximum pickup is modeled as
`3.5 × (1 + 0.004 × (100 - 23)) = 4.578 V`. The light-load pickup floor of
4.6235 V leaves **45.5 mV modeled hot-pickup margin**. The fully loaded floor
of 4.5804 V is only **3 mV above that same pickup model**: it is a simultaneous
stress case, not a substantial reserve or proof of a guaranteed holding
voltage. At 90 °C winding the fully loaded comparison leaves 143 mV. Do not
reuse the obsolete 67 mV Bel-fuse margin or describe the relay's 10%
must-release figure as a guaranteed hold threshold.

The 100 mV working fuse allowance is not a published 60 °C maximum-resistance
guarantee. The 40 °C winding-rise allowance is not a measured prediction or
a manufacturer-guaranteed bound. Preserve those distinctions, contact
condition and heating effects in the calculations and assembly instructions.
Also check continuous coil operation at 5.25 V. A higher minimum supply must
not be silently assumed to create more margin; the requirement remains
4.75 V at J1.

For the retained USB relays, 100 mV F1, 44 mV holder and 20 mV shared/local
copper leave **4.586 V** before the two series TN0702 drivers. Reusing the
existing adverse preheat model gives 85.44 °C winding, 162.52 Ω coil resistance and 4.2094 V
required pickup. Two 5 Ω hot-driver allowances leave **4.3202 V at the coil**,
or approximately **110.2 mV pickup margin** even at full screen load. Update
the checker to include the fuse and holder; passing the old calculation with
an unmodified 4.75 V USB feed would not verify the new circuit. This is a retained thermal sensitivity,
not measured enclosure behavior.

Passing relay pickup does not establish the screens' unknown minimum input
voltage. Keep the complete screen-path drop assessment separate. The 100 mV
input-fuse allowance, 44 mV holder and 127.5 mV power-contact allowance total
**271.5 mV**, before copper, branch fuses and harnesses. This is larger than
the old pair's modeled 216.75 mV hot loss. Include the selected Bel branch
fuses and complete wiring losses; relay pickup does not establish an
assembled-screen operating guarantee.

Use the Bel branch-fuse rated-current maximum drops of **80 mV main** and
**150 mV touch** as conservative working allowances at the lower normal
branch currents. They are not manufacturer guarantees of the installed
hot-fuse drop. There are no output clip losses in this selected assembly.
The deliberately stacked 4.75 V J1, 3 A main or 500 mA touch, 30 cm cable
case leaves approximately 4.209 V main or 4.185 V touch before the final USB
termination. Those values neither establish screen failure nor prove
minimum-voltage compliance. Keep the distinction from ordinary operation
at nominal 5 V at J1.

Target **20 cm maximum one-way main and touch runs** where the enclosure
allows it, using at least 20 AWG on both main-power conductors and retaining
the purchased 28 AWG touch leads. That length is a wiring target, not a
measurement of the purchased cables. The main VH contacts also permit
18 AWG as a lower-loss wiring choice. Preserve the **3 A main / 500 mA touch
normal operating ceilings** and the combined 4.25 A switched allocation;
do not allocate 3 A simultaneously to both screens or rely on touch as the
large screen's sole power source.

The [Littelfuse P6KE datasheet](https://www.littelfuse.com/~/media/electronics/datasheets/tvs_diodes/littelfuse_tvs_diode_p6ke_datasheet.pdf.pdf)
gives P6KE6.8CA a 5.8 V stand-off and a specified 10.5 V maximum pulse clamp.
The nominal drain ceiling is therefore 5.25 + 10.5 = 15.75 V. Include
temperature variation and a layout overshoot allowance, and require the result
to remain below Q5's **55 V** drain limit with margin. Its low-voltage
bidirectional leakage limit is doubled to 2 mA at stand-off. Use the CA part;
a unidirectional substitute changes release behavior. [TE's suppression
guidance](https://www.te.com/en/products/relays-and-contactors/electromechanical-relays/intersection/relay-coil-suppression-dc-relays.html)
supports TVS suppression for prompt power-contact opening.

Retain the existing R2 = 4.7 kΩ weak-source assessment: 3.63 V through at least
50 kΩ plus the documented leakage allowance, and the conservative Q1 base
bias budget. This is an engineering envelope, not a guaranteed RP1 internal
pull resistance. Recalculate strong-high Q1/Q2 drive after removing the
optocoupler load and reducing R7 to 10 kΩ. Check Q5 gate leakage/discharge
with its larger gate capacitance. Do not connect the coil directly to the
GPIO or Q1 collector.

Startup remains an assessment under stated assumptions. Re-evaluate the
known 0.3 mF downstream capacitance and 1/5/10 mF total sensitivities, source
impedance, screen operating load and relay contact bounce. Ten millifarads at
5.25 V stores 0.138 J. The prior 10 A/100 ms stress case is a sensitivity,
not a promise that a nominal 10 A buck limits every instantaneous pulse.
The new relay does not implement active inrush limiting, and the old MOSFET
gate-charge estimate did not guarantee a universal charge-current waveform.

Use the selected Bel 0697H time-delay output fuses. The
[November 2025 Bel data sheet](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf)
gives the 4 A part 16 mΩ typical cold resistance and 81 A²s nominal melting
I²t for pulses below 10 ms; the 800 mA part is 0.130 Ω typical and 2.3 A²s
under that condition. Both ratings support 200 A interruption at 72 VDC;
the 800 mA part also has its separately specified 100 VDC rating. Both
specify maximum opening of 60 seconds at 2× rated current. These typical or
nominal figures are not guaranteed minimum resistance or repetitive-pulse
survival. The `-02` suffix selects taped long leads; use its actual lead and
body dimensions, not the tape spacing, for the footprint.

The [Schurter SPT data sheet](https://www.schurter.com/pdf/english/typ_SPT_5x20.pdf)
specifies the selected 8 A cartridge at 150 VDC, with 1,500 A DC interruption
and 268 A²s typical melting I²t at 10× current. Preserve its own time-current
limits, including the 30-minute maximum at 2.1×, rather than importing the
Bel branch-fuse limits. The input and output fuses use different families.

Carry the Bel pulse/protection assessment into the layout and checks,
including charging C102/C202, internally joined screen inputs, branch
resistance and contact-bounce sensitivities. Recalculate the selected
system with the actual input holder; do not reuse the unselected S506
resistance or melting-I²t values. Preserve the **500 mA normal touch-power
limit**; an 800 mA fuse does not authorize 800 mA continuous use of a thin
USB lead. Delayed clearing must be assessed against wire/connector heating,
not only nominal melting energy. A 60-second 2× limit does not establish a
safe insulation temperature for every unspecified 28 AWG cable and jacket.

The buck's nominal 10 A output is not a guaranteed instantaneous current
clamp. Neither F1 nor the upstream fuse establishes clearing of every
current-limited partial fault. Preserve separate main/touch fuses when the
screen inputs join internally. A verified fuse or contact conflict requires
a focused correction, not an assumption about unknown screen capacitance.
Relay release takes finite time: assess AUX collapse and output-backfeed
transients before contact opening, then verify settled isolation and R8
output discharge.

## Dependency-ordered implementation

1. **Close the exact-part assessment.** Record primary part pin maps, contact
   state, lead/body dimensions, minimum finished-hole requirements, coil
   margins, clamp limits, startup/fuse calculations and updated AUX budget in
   `docs/reviews/screen-power-stock-cost-1072/`. Verify the two inexpensive
   passive replacements' actual electrical and mechanical specifications.
   Include the exact SPT/OGN input assembly and Bel branch-fuse pulse,
   protection and voltage-loss assessment. Record separate light-load pickup
   and loaded coil budgets, verify each selected packaging and count five
   fuses plus one input holder, without output clips. Complete a
   fresh consolidated Mouser US quote for one assembly of each board,
   including harness parts, showing every required quantity stocked
   and shippable in one shipment. Do not reserve, substitute or purchase parts.

2. **Replace the circuit and functional guards.** Edit
   `hardware/kicad/screen_power/switch_circuit.py`, `schematic.py`, `circuit.py`,
   `check.py` and `hand_checks.py` as needed. Generate the schematic, netlist,
   `hand/components.json` and `hand/bom.csv` from the single new circuit.
   Replace the obsolete `gate_drive.kicad_sch` page; do not ship a disconnected
   historical pump sheet. Preserve existing USB state checks and extend the
   electrical graph to K1's actual normally-open contacts and Q5's body diode.
   Require meaningful fault controls for a normally-closed/wrong-pin power
   relay, an AUX/host-VBUS bridge, a bypass around F1, a board load on raw
   AUX_5V_IN, missing gate pulldown, inadequate hot pickup,
   wrong/unidirectional clamp, inadequate driver rating, incorrect fuse types
   or current budgets, and broken or narrow high-current copper.
   Retain applicable weak-pull, USB, component-fit,
   two-layer and through-hole guards. Retire obsolete pump/FET controls
   explicitly rather than weakening the test runner to obtain a pass count.

3. **Implement the compact native layout with Claude when available.** Update
   `layout.py`, `pcb.py`, `route_critical.py`, `finish.py`, `cleanup.py` and
   `screen_power.pretty/` only as required by the replacement top control bay
   and the input holder plus four radial branch fuses.
   Verify K1's footprint against its primary drawing; no existing KiCad G6C
   footprint has been established. The relay body is **20 × 15 mm with 10 mm
   height**. Use the direct-PCB contact-blade dimensions, 0.9 × 0.5 mm
   (approximately 1.03 mm diagonal), not the drawing's bracketed socket-version
   dimensions. Reconcile the manufacturer's four 1.1 mm recommended holes
   with fabrication tolerance and hand-insertion clearance: a nominal 1.1 mm
   finished hole can shrink to 1.02 mm at a −0.08 mm tolerance. Verify a
   suitable allowance, such as nominal 1.2 mm, with annulus and neighboring
   clearance checks. This is a focused footprint-fit check, not a claim that
   the socket dimensions establish a larger direct-pin tolerance.
   Verify Q5's G-D-S/tab map and lead-hole
   allowance instead of inheriting a footprint named for the removed Vishay
   device. Add matching models through `models.py`, `model_geometry.py` and
   `models/`. Replace the four axial branch-fuse footprints with Bel 0697H
   radial land patterns verified against the primary lead/body drawing,
   finished-hole tolerances and soldering access. Add F1 in its OGN 0031.8201
   holder directly after J1, ahead of every capacitor, coil, control-supply
   and contact-rail branch. Verify cartridge insertion/removal access after
   nearby components are fitted. Model the one cartridge, its input holder
   and four radial fuses without duplicate electrical fuses. Update local
   power connections; do not reuse the old axial or unselected clip geometry.
   Update
   bypass-capacitor body/courtyard/models to the actual part. Preserve USB
   copper item geometry, connector/data-relay anchors and power-distribution
   widths; adapt power endpoints around the relay and new fuse bodies.
   Keep rounded, uniform-width power routes, mounting keepouts, complete
   ground fills and hand-solderable pad connections. Protect the reviewed USB
   routes from a blanket autorouter or full-board regeneration.

4. **Validate source and native behavior before packaging.** Run the updated
   native suite and all applicable negative controls. Require clean ERC,
   zero routed-board DRC violations, zero unconnected pads, schematic/netlist/
   component/native parity, complete models and unchanged USB geometry and
   ground-reference checks. Compare preserved route geometry by net name,
   coordinates, layers and widths rather than transient net numbers. Inspect
   top/bottom copper, assembly drawings and 3D renders for fit and alignment.
   Record tests with the final source and native hashes. Obtain independent
   circuit and layout reviews, adjudicate findings and repeat affected checks
   after repairs. Earlier Claude approval covers the earlier circuit only.

5. **Refresh the complete deliverable.** Update the screen `README.md`,
   `COSTS.md`, `external_bom.csv`, assembly instructions and the consolidated
   shopping list. Remove the external ATO fuse/holder records and add the
   selected input cartridge, one PCB input holder and four Bel branch fuses,
   with no output clips or duplicate fuse/holder assembly entries.
   Document the short incoming pair and its upstream protection limitation.
   Replace current pump/gate-drive explanations
   with the relay assessment; keep historical reviews identifiable as
   historical. Run `export.py hand` only after final verification, preserving
   its atomic publication and changed-input rejection. Independently compare
   native files, loose CAM, ZIP members and manifest hashes. Refresh
   `docs/reviews/pcb-finish-all-three-1072/manufacturing-zips.json` and the
   established delivery inventory/folder for the new screen revision; verify
   unchanged console/ring production identities. Update #1072 and PR #1080
   under the existing tracking contract. No `review:clean` claim until the
   resulting head receives complete independent review; no manufacturing
   order or merge is part of this plan.

## Success Criteria

Commands run from the repository root with the documented `KICAD_PYTHON` and
`KICAD_CLI` environment configured. Create the new evidence directory during
implementation. Python used for the independent fabrication verifier needs
its existing `pypdf` dependency. The assertions described below must be added
to the established checker where absent; an old passing report is not proof.

```success-criteria
GOAL: Deliver the same hand-soldered two-layer screen power behavior using stocked Mouser parts at lower cost, with a reviewed relay circuit and matching manufacturing package.

SUCCESS CRITERIA:
- Low, floating and assessed weak-pull GPIO states leave power contacts open and USB data disabled; AUX-absent settled states and external output power cannot bypass that isolation or feed Pi VBUS. | verify: "$KICAD_PYTHON" hardware/kicad/screen_power/check.py hand --self-test --output docs/reviews/screen-power-stock-cost-1072/native-validation.json
- With 4.75 V at J1 before F1 and its holder, the final topology supplies only coils/control before K1 closes. The updated model includes the SPT fuse, OGN holder and actual copper: 4.6235 V at K1 during the 150 mA pickup allowance, 45.5 mV modeled hot-pickup margin at the declared 100 C winding allowance, and 4.5804 V under the separate 4.46 A loaded stress case. It records the loaded 2.4 mV comparison as narrow model margin, not a guaranteed holding threshold. The retained USB model has approximately 110.2 mV pickup margin, and actual geometry supports the 20 mV copper allowance. GPIO, driver/clamp and full-white-ring AUX limits pass with meaningful negative controls. | verify: "$KICAD_PYTHON" hardware/kicad/screen_power/check.py hand --self-test --output docs/reviews/screen-power-stock-cost-1072/native-validation.json
- Every board power load is downstream of F1, with no bypass from raw AUX_5V_IN; wiring instructions identify the very short 16 AWG incoming pair as outside the PCB fuse's protection. | verify: manual 1. Check native/source graph and injected F1 bypass rejection in the native suite. 2. Check the wiring diagram and assembly instructions state the incoming-wire limitation.
- The main input cartridge can be replaced without desoldering in the OGN holder, with manufacturer-verified mechanical fit and access. The four Bel branch fuses remain soldered. The BOM and purchase list contain one input cartridge, one holder and four radial branch fuses, without output clips or duplicate fuse assemblies. | verify: manual 1. Compare manufacturer drawings with native footprints and the assembly model. 2. Inspect input-cartridge insertion/removal clearance and branch-fuse soldering access. 3. Reconcile fitted and purchase quantities; ensure assembly instructions state which fuse is removable.
- The routed board retains its outline, two layers, connector interfaces and reviewed USB geometry/reference, and has clean ERC/DRC, no unconnected pads, exact net parity and all component models. | verify: "$KICAD_PYTHON" hardware/kicad/screen_power/check.py hand --self-test --output docs/reviews/screen-power-stock-cost-1072/native-validation.json
- Current native files, loose manufacturing data, portable package and ZIP agree under the existing strict export checks. | verify: python3 docs/reviews/screen-power-rev-l-1072/verify_fabrication.py --board hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb --package hardware/kicad/screen_power/hand/fabrication --zip hardware/kicad/screen_power/hand/fabrication/screen_power_hand_prototype_gerbers.zip --output docs/reviews/screen-power-stock-cost-1072/fabrication-verification.json
- Primary-source startup, fuse-pulse, contact-release and thermal assumptions are reviewed without an unresolved actionable finding, and the final native layout is visually checked for connector access, lead fit and smooth power copper. | verify: manual 1. Review the dated circuit calculations and adversarial findings. 2. Inspect final copper and assembly renders. 3. Record the exact reviewed revision and remaining physical limits.
- The complete one-of-each-board BOM includes the removable input fuse and four soldered branches and is cheaper than the original $105.86 one-shipment estimate; every required quantity can ship together from Mouser US. | verify: manual 1. Reconcile exact MPNs and quantities with all three final BOMs. 2. Check the fresh live US quote for stock and restrictions on every line; expected replenishment is not stock. 3. Compare parts, tariffs and shipping on the same basis, including the input holder and all five fuses. 4. Save dated prices separately and do not place the order.
- The delivery inventory identifies the new screen package and preserved console/ring packages, with no stale archive presented as current. | verify: manual 1. Independently hash all delivered native/CAM/ZIP files against the manifests. 2. Confirm reviewed-source identity and PR evidence. 3. Record the completed inventory before publishing the delivery update.

NON-GOALS:
- Altering console/ring geometry, the 40-LED full-white requirement, USB pairs, connector pinouts or runtime behavior.
- Adding a second relay pole, replacing the four USB TN0702 devices, low-side screen-power switching or new USB-C/PD electronics.
- Claiming active inrush limiting, measured enclosure temperature, assembled USB certification or unlimited capacitive-load immunity from static checks.
- Ordering, merging, flashing or deploying.

VERIFICATION COMMAND: "$KICAD_PYTHON" hardware/kicad/screen_power/check.py hand --self-test --output docs/reviews/screen-power-stock-cost-1072/native-validation.json && python3 docs/reviews/screen-power-rev-l-1072/verify_fabrication.py --board hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb --package hardware/kicad/screen_power/hand/fabrication --zip hardware/kicad/screen_power/hand/fabrication/screen_power_hand_prototype_gerbers.zip --output docs/reviews/screen-power-stock-cost-1072/fabrication-verification.json
```

## Procurement and cost basis

The [fresh complete Mouser US quote](https://www.mouser.com/en/price-availability/Edit?bomId=8d557212-bfa8-4ecd-9a90-89cffde392b4)
confirms **53 lines / 168 units, all requested quantities Ships Now**, with
**$68.59 parts + $9.48 estimated tariffs**. Adding the earlier **$8.49 US
shipping estimate gives $86.56 before tax**. Shipping has not been rated for
a specific Miami address. No order or reservation has been made; availability
and final checkout charges may change.

This estimate is $11.06 below the fully socketed $97.62 proposal and $19.30
below the original $105.86 estimate. The scope tradeoff is explicit: F1 is
removable; branch-fuse repair requires soldering. These are quoted-parts
comparisons with estimated shipping, not manufacturing acceptance or a
confirmed checkout total.

The G6C relay retains the 30 mΩ initial contact bound and 70% pickup
specification. Its IRLZ44N driver preserves coil voltage margin. Keep the
new Pico 2, new XIAO/encoder/nut, all required harness parts and the existing
owned-part exclusions when reconciling the quote. Do not make an apparent
saving by deleting a required part or counting an existing component twice.

Relevant prior evidence: [complete earlier three-board review](../code-review/pcb-claude-followup-1072/review.md),
[existing screen startup assessment](../reviews/screen-power-rev-l-1072/startup.md),
[USB revision assessment](../reviews/screen-power-usb-revision-1072/review.md),
and [current screen build/assembly guide](../../hardware/kicad/screen_power/README.md).
The new relay review replaces obsolete power-stage conclusions while
preserving unchanged USB and harness evidence. Refresh the purchasing and
release records only after the implemented circuit and native layout pass
review; superseded proposal prices must not be presented as the current order.
