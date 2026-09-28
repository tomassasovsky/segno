<!-- cspell:words opencode deepseek -->

# DeepSeek response: ring capacitor and routing proposal

26 September 2026. Completed response from `opencode-go/deepseek-v4-flash`,
using the read-only plan agent and supplied baseline evidence. The text below
is preserved verbatim. It contains recommendations requiring correction;
read the [adjudication](deepseek-adjudication.md) before using it as evidence.
This is not a final-native or manufacturing approval.

---

# Ring-carrier design review

## C1 relocation — risk by configuration and verdict

**Confirmed baseline:** C1 (470 µF, low-ESR) at (36,62) is ~7 mm from the 24-ring +5V pad (31.86,67.318) but ~89.9 mm of predominantly 0.65 mm wiring from J2.1 and ~98.7 mm from J1.1. Today the reservoir effectively serves the module alternative, not the strip — the load the full-white spec is built around.

- **40-strip (J2, 2.44 A):** Moving C1 near J1/J2 on a short branch to the 1.5 mm F.Cu rail is a genuine improvement: bulk at the strip supply terminals per Adafruit, and it removes the 90 mm cap-to-input path. Low risk. Constraint: C1 pad1 (+5V_LED) must tap the main rail or module branch — never the D1/+5V_MCU path — and pad2 (GND) goes to the solid pour via a real via, not a fill-dependent sliver.
- **24-ring (J3, 1.44 A worst):** The binding case. Today C1 is local to the module entry; relocated, module pulse current traverses the 0.65 mm F.Cu branch to reach the reservoir. Acceptable **iff** the new site keeps C1 within a short branch of *both* the main rail and the module branch tap (region ~x32–40, y20–30), so the module loop stays comparable to today. If the only achievable placement is remote from the module +5V pad, the 24-ring loses its local bulk and the current site at (36,62) is the defensible compromise for a never-multiple-alternatives board.
- **16-ring (J4, ~0.96 A):** Same loop concern at lower current; non-binding.

**Conditional physical checks** (final layout not available): relocated D8 THT body/pins vs EC11 (36,36) legs/bush, U2 DIP-14, J1 XH housing on B.Cu, and the B.Cu cap body under the ring bore against the back-face envelope. The east USB approach (U1 shell to x≈70.6) is outside this area.

**Verdict:** The move is justified by the dominant strip case — it is an electrical improvement, not cosmetic. Keep it only if the module-case loop stays short.

## C5/unused-gate tie hazards

**Confirmed:** C5–U2.14 path is 7.32 mm (direct 3.698 mm), plus redundant F.Cu legs from C5.1 (39,18.5) and U2.14 (35.62,20) to y22 forming a same-net loop (8.912 mm² pocket).

Hazards: (1) removing a leg that is the only +5V path to OE pins 4/10/13 or the only GND tie to inputs 5/9/12; (2) orphaned locked `TAP_FILLET` zones (priority 20) left at the old tap x-positions re-creating copper off the rail; (3) refill GND pouring onto the ERC-exempt NC pads 6/8/11 — a same-net join that DRC unconnected does not flag.

**Minimum checks that detect them:** extend the ring_power.py-style graph walk to assert U2.14↔U2.4/10/13 on +5V_LED and U2.7↔U2.5/9/12 on GND; assert exactly one rail tap with its regenerated fillet and zero `TAP_FILLET` zones at the old coordinates; pin/netlist parity (already in acceptance) catches fill-to-NC joins; full refill DRC all severities run *after* the locked zones are removed. Keep C5.2's GND pour connection and the C5.1→U2.14 segment short.

## Rounding/current/return

**Confirmed:** 1.5 mm feed estimate 2.73 A vs 2.44 A strip load (20% tolerance included); JST XH 3 A/AWG22 vs 2.64 A at J1. The proposal changes no widths, so **no electrical capacity assumption is new or wrong**. Smoothing near J1→J2 must not shave the GND-pour necks feeding J2.2's three 0.4 mm barrels — re-run STRIP_POWER and STRIP_RETURN on the final board. Arcs must stay constant-width with no neck shorter than DRC minimum; the 0.65 mm module branch must remain 0.65 mm. Implement smoothing as scripted, locked copper (as ring_power.py does) so source/native parity and fresh CAM→ZIP parity hold without a new autoroute.

## Named corrections/constraints

- C1 pad1 +5V_LED / pad2 GND (POLARITY gate): short branch to main rail or module branch; GND via to solid pour; never via D1/+5V_MCU.
- U2.14 (+5V) / U2.7 (GND): single clean rail tap; keep C5.1→U2.14 short; preserve C5.2 GND.
- J2.1 1.5 mm feed and J2.2 three 0.4 mm barrels: untouched by C1/C5 edits.
- Relocated-C1 clearance vs EC11/U2/J1 and the module-branch loop length are **conditional final-layout risks**; everything else above is against the confirmed baseline. No prototype or owner measurement is needed for any of these checks — they are geometric/netlist/DRC verifiable.
