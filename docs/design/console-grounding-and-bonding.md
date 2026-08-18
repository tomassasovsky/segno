# Console: grounding and chassis bonding

The scheme for the 10-pedal console. Issue #751; the board it lands on is #747.

The short version: **one hard DC bond from board ground to the chassis, at H1.**
Everything else that touches metal is either a known bond we accept or one we
break deliberately.

## Why there is a scheme at all

The board's mounting holes used to be bare NPTH — no copper — so the board
"floated" inside an earthed metal box. That was never a decision; it was the
default footprint. And it did not float in practice: the rear panel carries two
USB 3.0 couplers with metal flanges, two DIN-5 chassis sockets and two D-series
TRS jacks, all bolted through metal, and the **TRS sleeves are this board's GND**.
The Pi ties its USB shells to GND, so the coupler flanges likely bond the Pi too.

A floating board in a box full of bonded connector flanges is the worst case: the
loops exist anyway, through long, undefined, high-impedance paths. So the bonds
are made deliberate instead.

## The board

| Hole | Position | Bond |
|---|---|---|
| **H1** | top-left, nearest the rear-panel loom | **hard-wired to GND** — the single DC bond |
| H2 | top-right | plated pad, isolated — wired to nothing |
| H3 | bottom-right | plated pad, isolated |
| H4 | bottom-left | plated pad, isolated |

All four use `MountingHole_3.2mm_M3_Pad`: a 6.4 mm plated pad with bare copper on
**both** faces, so the screw head above and the standoff below both make contact.

H1 is top-left because that is the corner nearest where the outside world arrives
(power button, MIDI, CTRL, and the ten footswitch leads all land along the top
edge) and diagonally away from the Pi ribbon. An ESD strike on a footswitch cable
should reach the case there, not travel the 40-way into the Pi.

**If a second bond is ever wanted, it is a capacitor, not copper.** A second *DC*
bond closes a mains-frequency loop — chassis → Pi → ribbon → this board → chassis.
A capacitor does not: 10 nF is ~318 kΩ at 50 Hz, so no hum current flows, and
~0.16 Ω at 100 MHz, so ESD and RF still get a short path into the case. Add a 1 MΩ
in parallel to bleed the static the cap would otherwise hold.

**Those parts are not on the board, deliberately.** A version of this fitted all
three holes with a 10 nF 2 kV cap and a 1 MΩ bleeder, unfitted by default, so EMC
testing could add an RF bond without a respin. Nothing in through-hole fits those
corners, so they were SMD — six surface-mount parts on a board that is hand-soldered
through-hole on purpose, carried by every unit, for a bond that may never be wanted.
The pad is enough: if a bond is ever needed, a leaded cap solders from it to the
nearest ground via. That is a bench job on one board instead of a BOM line on all of
them.

`CHASSIS_BOND` in `console_board.py` gates this: exactly one hole hard-bonded to
GND, and the other three wired to nothing at all — a second path to ground through
*anything* fails. Its negative control is a hole strapped to GND "for a better
connection", which is the mistake the scheme exists to prevent.

## What goes on the M6 earth stud

The stud is on the rear wall with a 20 mm bare bonding land masked out of the
powder coat on both faces (`MASK_GND_D`). Powder coat is an insulator — every item
below needs bare metal or a star washer under its terminal, or it bonds to paint.

**Must be on the stud:**

1. **Any separate metal panel that is not a folded face of the base.** The rear
   panel and bottom plate are one part, so they need nothing. The top shell, the
   faceplate and any bracket that is its own part are joined by screws through
   *painted* faces, which is not a bond. Each needs a strap to the stud, or masked
   contact patches under its fasteners.
2. **A protective-earth conductor — only if mains ever enters the box.** Today it
   does not: the console takes 20 V DC over a USB-C PD contract (#754) and the
   fuse is in series with that feed. If an internal mains supply ever lands here,
   this stud becomes a *safety* earth and its rules harden: ≥1.5 mm² green/yellow,
   ring terminal, star washer, lock nut, and nothing else may share the fastener.
3. **The bucks' cases, if they are metal — and check V− first.** #754 replaced
   the single potted unit with two B0GGHN97TK bricks, which ship in aluminium
   shells. Before bolting either to bare metal, meter its shell against its own
   V−: a case-common negative bolted to the chassis is a second DC bond — the
   exact loop this scheme forbids (chassis → buck case → V− → board GND → H1 →
   chassis). Isolated shells may bond to the stud; case-common ones mount on
   insulating pads and bond through nothing.

**Deliberately NOT on the stud:**

1. **A second wire from board GND.** H1's standoff is the bond. A wire from a GND
   pad to the stud in addition is the second DC bond this scheme exists to prevent.
2. **A wire from any Pi GND pin.** The Pi reaches chassis through the ribbon and
   H1. Bonding it separately closes the loop.
3. **MIDI IN's DIN pin 2.** Left off at a receiver by MIDI 1.0, and bonding the
   shield here would short out the isolation U2 exists to provide.
4. **The audio interface's ground.** It references through its USB shield and
   nothing else; see below.

## The hum loop that actually matters

It is not on this board. Nothing here carries audio, AGND is tied to digital
ground, and the audio path is guitar → USB interface → Pi. The loop that hums is:

```
interface ↔ amp/PA ↔ mains earth ↔ console chassis ↔ USB shield ↔ interface
```

It is broken at the audio end — balanced outputs, or a DI with a ground lift, or
an isolated USB link to the interface — not in this board's copper. Bonding H1
cannot create it; it only changes the impedance of a path that already exists
through the USB coupler flanges.

## Bench audit (do this before trusting any of the above)

Ten minutes with a multimeter on continuity, from bare chassis metal to:

- [ ] **Pi GND** (any header ground pin). Raspberry Pi's own forum says the Pi's
      mounting holes are unplated and ungrounded, but that is documented for the
      Pi 3, and the N07 NVMe board sits between the Pi and the plate in this stack.
- [ ] **Console board GND**, with H1's screw *out* — expect open, because the only
      other paths are connector flanges. Anything else means an accidental bond.
- [ ] **Each rear-panel connector shell**: 2× USB coupler, 2× DIN-5, 2× TRS, and
      the USB-C PD coupler.
- [ ] **Each buck's shell against its own V−** (B0GGHN97TK ×2, aluminium cases):
      case-common negatives bolted to the chassis are a second DC bond — isolate
      the mounting if so (see item 3 above).
- [ ] **The top shell and faceplate**, to check whether the painted joints conduct.

Then decide:

- **Pi/N07 not chassis-bonded** (expected): H1 alone is the bond, and it is enough.
  If EMC testing later wants a lower-impedance RF bond, solder a leaded 10 nF from
  H2/H3/H4's pad to the nearest ground via — no DC loop is possible while only one
  board is bonded, so even a hard strap would be defensible there.
- **Pi/N07 *is* bonded**: keep H1 alone, add nothing, and consider nylon shoulder
  washers on whichever connector turns out to bond the panel, so the DC path stays
  single-point.
