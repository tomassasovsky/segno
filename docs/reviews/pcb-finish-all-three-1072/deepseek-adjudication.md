# Checked conclusions from the DeepSeek ring review

26 September 2026. The [recorded response](deepseek-response.md) is a completed
review of the proposed changes and supplied baseline evidence. It is not a
review of final revised copper.

## Carry forward

- Evaluate C1 supply/ground distribution for every supported output choice.
  Moving bulk capacitance toward J1/J2 helps the strip, but the old location
  was near the 24-LED module input. Preserve the 0.65 mm module path and assess
  the resulting route. The response provides no quantitative transient failure
  requiring a second capacitor or abandonment of the move.
- Preserve U2 +5V ties at pins 4/10/13/14, GND at 1/5/7/9/12, and floating
  outputs 6/8/11. Require native pad/net parity and fresh filled-board
  connectivity/DRC. Keep C5.1 close to VCC pin 14 and retain C5.2's ground return.
- Remove obsolete `TAP_FILLET` zones with replaced branches and inspect the
  refill. A locked same-net overlay can retain an unwanted shape despite clean
  connectivity and DRC.
- Preserve the 1.5 mm strip feed, 0.65 mm module branches, J2's three 0.4 mm
  ground barrels, connector rating/pinout and optical/encoder/USB clearances.
  Constant-width rounding alone changes no current-capacity assumption.

## Corrections to the model response

The long module branch is predominantly **B.Cu**, not F.Cu. The suggested upper
placement region cannot preserve C1's former short physical loop to J3's power
pad at y=67.318. Treat the tradeoff as a final-layout consideration, not the
response's unsupported absolute placement condition.

C1 is through-hole. Its correctly connected plated ground pad already provides
the layer transition; an additional discrete ground via is not inherently
required.

Pad/netlist parity alone would not detect filled copper contacting an unchanged
NC pad. Those empty-net pads have clearance in the baseline. Fresh clearance
DRC and filled-copper inspection are the relevant checks; the response wrongly
calls such contact a same-net join and attributes its detection to pad parity.

A graph of track endpoints, as used for the dedicated feed in
[ring_power.py](../../../hardware/kicad/ring_power.py), cannot establish
plane-only ground ties. Use native KiCad connectivity with refreshed zones and
DRC instead of adding a track-only ground graph.

The review establishes no new verified blocker. Final geometry, capacitor
paths, source replay and manufacturing parity remain separate acceptance work.
