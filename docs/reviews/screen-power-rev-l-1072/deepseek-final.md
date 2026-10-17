<!-- cspell:disable -->
# Revision L screen-power — final adversarial adjudication

**Verdict: no verified actionable electrical defect within this bounded review.** One verification item (relay coil polarity) remains unresolved from the source and datasheets I could reach; everything else either checks out or is an assumption the attached notes already disclose. I did not review artwork.

## Checks that pass with independent evidence

- **Pinouts.** TN0702 is Table 3‑1 S(1)/G(2)/D(3) (Microchip DS20005941A), matching `Q101/Q201 = {1:GND, 2:DATA_ENABLE, 3:coil}` and the reused 2N7000 symbol. TLP627M is LED 1–2 / collector 4 / emitter 3; `U2 = {1:GATE_LED,2:CONTROL_SINK,3:NEG_5V,4:GATE_SINK}` matches. LMC7660 CAP+(2)/GND(3)/CAP−(4)/VOUT(5)/LV(6)/OSC(7)/V+ (8) matches `U1`. SUP70101EL G1/D2/S3 with joined sources and joined gates is the required opposed-P configuration.
- **Default-off.** With the opto dark, R4 ties POWER_GATE to COMMON_SOURCE; the only injected bias is opto I_DARK through R4 (22 kΩ × 20 µA = 0.44 V worst case), far below the −1.5 V max |V_GS(th)|. GPIO-low/AUX-loss/charged-output traces in the notes hold.
- **Gate math.** Divider 0.821, V_source = 4.392 V, |V_GS| ≈ 5.9–6.1 V ≥ 4.5 V spec; max ≈ 8.7 V < 20 V. Reproduced.
- **Relay contacts / flyback.** Commons on 3/6, makes on 4/5, breaks 2/7 open is the off-open behavior; D101/D201 is correctly anode-to-coil-low, cathode-to-host. The contact-state machine is exercised by `check_relay_contacts`.
- **Coil voltage is *not* a defect.** IM02TS is the 4.5 V/145 Ω/140 mW standard monostable coil; TE's continuous "coil operating range" defines Umax (limiting continuous voltage) well above Unom, so 5.25 V max is a ~1.17× nominal bias, inside the rated continuous window, not an overstress.

## Unresolved question (actionable before the order)

**Relay coil polarity — verify, then only swap if wrong.**
- *Condition:* the IM series is a **polarized** magnetic system (TE 108‑98001: "1 and 2 pole … polarized"; distributors list "Coil Type: Polarized, Monostable"). The netlist fixes `K pin1 = HOST n_5V (+)`, `K pin8 = coil-low (−)`. If the physical coil polarity is the reverse of this assumption, the monostable armature does not pull in when DATA_ENABLE is high, and **all four USB data paths stay open** — a silent functional failure that no repository check detects (`check_relay_contacts` tests only contact continuity; `numerical_checks` tests only pickup voltage; neither asserts coil polarity).
- *Evidence limit:* I could not retrieve TE's terminal-assignment figure (graphic-only; TE PDF returned 403), so I could not confirm pin1 is the coil "+". The prior reviews that "matched the TE pinout" validated the **contact** pins (2–7), not coil polarity.
- *Fix:* confirm coil polarity against TE 108‑98001 terminal assignment (or the native KiCad `Relay:IM03`/`IM00` coil-pin convention); if reversed, swap the pin‑1/pin‑8 net assignments and add a coil-polarity assertion to the netlist contract.

## Assumptions already disclosed (not new defects)

- Low-corner pump budget is thin: ~394.5 µA modeled vs the 405 µA / 10 kΩ reference (~2.6%), resting on a 50 µA diode allowance and catalog (non-hot-max) capacitor leakage. The notes state this is an engineering loading check, not a hot guarantee.
- Gate drive, startup SOA, and 4.25 A steady junction estimates use the 1.7× hot-Rds and 75 °C/W upright allowances; hot coil re-enable and inrush are analytical, not measured.
- TLP627M I_DARK is a 200 V/85 °C maximum; at the ~5 V actual V_CE the real leakage is far lower, so 0.44 V is very conservative.

## Limitations
Through-hole, two-layer, 4.25 A planning load assumed. No prototype or full-temperature qualification was available, and final artwork/layout parity is being checked separately. The relay-polarity item is the only item I would gate the order on.
