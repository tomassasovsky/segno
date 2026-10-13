<!-- cspell:words prewired Creality -->

# Pill housing with a deep platform grip and friction closure

Use the current files in [`out/`](out/) or regenerate
**`pill_friction_mount_print_pack.zip`** using the commands below. This replaces the printed version
that rocked on the platform and whose housing hooks would not engage. The owner
confirmed **PLA** and requested a friction fit instead of bending snaps or screws.

**Fit revision 2 — tighter at both connections.** The first friction-fit sample
was printed and reported slightly loose both inside the cover and on the
platform. A 0.25 mm thickness gauge takes up the gap at a housing grip rib and at
the platform clip. This revision adds 0.15 mm to each opposing housing rib, increasing total
contact width by 0.30 mm, and narrows the platform contact throat by 0.30 mm.
Reprint **both black sample pieces** before the full parts, using the same print settings as the first sample.

Print the **black base and black cover**. Reuse the successful **white diffuser**.
The base retains its full **2.4 mm LED glue bed**, locating walls and ledges under
the white flange. Both **8 mm cable slots stay open to the top**, so the strip
can be soldered and tested outside the case, then lowered in with its wires
attached. Connectors and separate strain relief stay outside the housing.

## Housing closure

The base's bending tabs, hooks, flex slots and the cover's latch windows are
removed. Four solid triangular contact ribs press against the cover's inside
walls. Tapers at both ends provide a lead-in and permit straight removal; there
is no undercut to click past.

The body has **0.25 mm clearance per side**. Each rib projects 0.55 mm, giving
**0.30 mm nominal CAD contact interference per side**. The ribs concentrate that
contact locally instead of forcing the entire wall into a tight fit. A lower
edge recess on the outside long face exposes the base for fingernail removal.
The white flange seats between the base ledge and cover without diffuser glue.

Actual friction depends on this printer, filament and dimensional accuracy.
The printed sample had a gap even though its CAD ribs overlapped the cover.
The 0.30 mm increase across opposing ribs takes up the measured 0.25 mm play
with a small additional allowance; the next print checks the actual result.
The fit samples below check the local fit; they are not a claim that holding
force, wear or long-term retention have already been verified.

## Platform grip

Both inside and outside jaws reach **18 mm down the rear wall**. The previous
inside tongues reached 8 mm, while the outside bearing ended only about 2.3 mm
below the rim. The new outside jaw is **2.4 mm thick** over its lower depth;
the inside leaf is **1.2 mm thick**. Each grip is **14 mm wide** rather than 10.
The deep outside brace gives the housing a longer bearing surface against
rocking, while the inside leaf allows the grip to slide over the wall.

The chamfered entry stays **2.70 mm** for the pinned **2.40 mm cradle wall**;
the straight channel above the entry is 2.55 mm. The inside leaf moves 0.15 mm
towards the wall while retaining its 1.2 mm thickness, preserving clearance
beside the pedal under the increased deflection. The lower contact pads give a **1.95 mm free throat**, or 0.45 mm nominal CAD squeeze
when seated against the outside jaw. This is a friction grip on a plain wall;
it does not latch into the platform.

The case centre moves 1.2 mm outward to clear the thicker jaw during housing
assembly. The black capsule is **75.7 × 32.43 mm in its face plane**. The housing,
LED bed and diffuser now follow the platform's **12.498° slope**; the mounting
jaws stay vertical against the wall. The face centre is **10.2 mm above the rear
rim**, leaving the tilted floor clear of the existing pedal cable opening.
The optical air gap remains 5 mm. Print orientations flatten the relevant
housing face again, so the inclined assembly does not make the base print on
an edge.

References remain the current front/mid cradle release: 118.47 mm depth,
88.75 mm width, 2.4 mm rear wall and the closed cable opening. Both heights use
the same housing. `reference/provenance.json` records the pinned source hashes.

## Print the fit sample first

The two `pill_top_mount_fit_sample_*.stl` files reproduce one pair of housing
contact ribs and one complete pair of platform jaws in a 16 mm long section.
Their mating dimensions, installed slope and print orientations match the complete housing.
The sample cover has a solid roof to keep the cut section in one piece; test
it **without the white diffuser**. It is not a spare production housing.

1. Print both sample parts in the same black PLA and settings intended for the
   full housing. Keep dimensional compensation unchanged between them.
2. Press the sample base into its cover. It should seat by firm hand pressure,
   remain held when lifted, and pull apart without cracking or a tool.
3. Slide the empty sample cover over a plain portion of the actual rear rim
   beside the cable opening. Check that both jaws seat and resist rocking.
4. If either fit is loose or needs excessive force, do not duplicate the full
   parts yet. The contact dimensions need tuning to the actual print result.
   Even a passing sample does not establish the complete housing's strength
   or insertion force: the full case has twice as many housing ribs and grips.

## Print settings and colours

Import into **Creality Print** without auto-orienting. The STL orientations are
already set. Use a 0.4 mm nozzle, 0.2 mm layers, four walls, and solid infill for
these small structural pieces. Use the printer's matching PLA material profile.

| Part | Colour/material | Supplied orientation |
|---|---|---|
| `pill_top_mount_fit_sample_base.stl` | Black PLA | Floor down, open side up |
| `pill_top_mount_fit_sample_cover.stl` | Black PLA | Solid top face down, jaws up |
| `pill_top_mount_base.stl` | Black PLA | Floor down, open side up |
| `pill_top_mount_cover.stl` | Black PLA | Bezel face down, cavity and jaws up |
| `tall_pill_diffuser.stl` | White PLA | Reuse existing; flange down if replacing |

The revised black parts use tapered ribs and open slots instead of supported
hook shoulders and window ledges. They are intended to print without supports.
Inspect the sliced preview: no black part should bridge along the pill length.
Remove any first-layer flare from mating edges before checking the fit.
The unchanged white lens has its existing short roof bridge across its width.

The archive includes both full black parts, both fit samples, the unchanged
white part (each STL and STEP), both reference assemblies, preview and these
instructions. Assembly STEP files are inspection models, not single print jobs.

## Assemble

1. Check the full empty housing and diffuser before gluing in the LEDs. Place
   the white flange on the base ledges, then press the cover down evenly over
   both ends until the diffuser seats under the bezel. Nothing needs to click.
2. Remove the housing from the platform before opening it. Hold the cover and
   use the small lower-edge recess to pull the base perpendicular to the pill face, working both
   ends evenly. Do not pull on the lens or the LED wires.
3. Solder and test the eight-LED, 12 mm wide strip outside the case. Lower it
   onto the continuous glue bed and lay its leads in either or both end slots.
   Allow for the modeled 0.2 mm adhesive layer. The checked lead envelope is
   7.6 mm wide × 2.6 mm high above that layer. Bulky joints or connectors must
   remain outside; keep the complete strip and end pads supported on the bed.
4. Refit the diffuser and cover, then lower both platform grips evenly onto
   the rear rim. Check the full housing's retention, rocking and actual pedal
   movement. The housing is not a foot pad or handle.
5. The pedal's own cable still uses the unchanged closed opening underneath.
   The open LED-wire slots do not change that separate cable route.

## Verification and physical boundary

Checks cover full strip support, diffuser bearing/capture, all four intended
rib-contact regions, tapered entry, the complete carrier insertion approach perpendicular to the inclined face,
both deep platform jaws, current cradle dimensions and settling, pedal and
cable clearances, prewired loading, STEP/STL and assembly coherence, and sampled
print layers. Negative controls reject a ribless closure, shallow grip and
closed wire tunnels. The actual pill-face normals are compared with both sloping cradle solids.
The fit samples are also checked as printable single solids.

CAD overlap at the contact ribs is intentional. It does not predict real PLA
compression, friction force or creep. The owner's first friction sample was
loose at both connections. This tighter revision requires
its own physical trial for insertion/removal force, retention, rocking, wear,
layer strength, cable bends and pedal travel. Ring parts, metal, production
cradles, firmware and Fusion models are unchanged.

Regenerate in the enclosure Python environment:

```sh
python top_mount.py
python check_top_mount.py
python top_mount_preview.py
```
