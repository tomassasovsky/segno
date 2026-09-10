# Short screws for the CLEAR/BANK platform

## What We're Building

A proposed two-joint mounting for the two tall console platforms. Keep their
height, bore, cable opening and connection to the metal bottom base, while
replacing the approximately 45 mm chassis screws with short M3 fasteners.
The owner approved the bottom-base arrangement; it is implemented in the
source and saved Fusion models with a dedicated mid-row sled.

Status: implemented locally for first-print verification; physical load
qualification remains open. The owner approved the recommendation to retain
the bottom base attachment. This continues the existing enclosure work
tracked by the September sheet-metal release plan.

## Why This Approach

The current bare stack before the lower sled insert is 2.000 mm of metal plus
38.345 mm of tall platform. This requires roughly M3×45, with 4.655 mm nominal
insertion before coating and washers. Splitting the joints removes that long
fastener without moving the existing floor holes.

Recommended: four short screws through the existing base holes into blind
inserts in the bottoms of the platform's four column legs, plus four separate
short screws from the hollow underside through its 8 mm deck into a dedicated
mid-row sled. Assemble that upper joint on the bench before anchoring the
complete module to the base. For servicing, release the four base screws and
lift out the complete pedal/sled/platform module first.

Alternative: preserve the existing sled and use lateral screw-head access
windows at its current lower pattern. Those axes run through the base columns;
access windows and intersecting passages complicate the columns and tooling.
A separate deck pattern offers clear axial access while the module is off the
base and does not require those windows.

Alternative: fasten the platform to the sloped upper faceplate. This changes
where pedal loads enter the enclosure, adds attachment details near the pedal
apertures and complicates lid removal. It needs a separate design assessment;
it is not equivalent to the proposed floor-mounted module. The existing
1050 enclosure's structural qualification remains open.

## Key Decisions

- Proposed base joint: preserve the four existing axes, local X = ±48.685 mm,
  Y = ±22.1875 mm. Replace the tall platform's through-bores at these axes with
  blind bottom insert pockets, retaining the approximately Ø12 mm column legs.
  Target the owner's M3 Ø5 ×5 mm inserts in Ø4.5 ×6 mm pockets. M3×6 is a starting
  screw candidate: 4 mm bare insertion, about 3.8–3.88 mm after a 60–100 µm coat
  on both metal faces, before any insert recess or added washer.
- Proposed sled joint: use a separate 60 ×36 mm pattern, local X = ±30 mm,
  Y = ±18 mm. Four M3×12 screws through the 8 mm deck give 4 mm nominal insertion
  into the sled's lower inserts. Keep the screw heads in the underside cavity.
- Use a dedicated mid-row sled with the new four lower pockets. Keep its upper
  pedal pattern, outer fit, top relief and 12.633 mm thickness. The existing
  front sled and front collar stay unchanged; avoid unused extra pockets in
  every front-row sled.
- Bench sequence: install inserts; bolt the pedal to its sled and close its
  case; thread the cable through the stadium opening and seat the sled; drive
  the four short deck screws from below; then fasten the complete module to the
  metal base with the separate short floor screws.
- CAD screening of the proposed deck pattern found no collision for Ø6 ×3 mm
  head envelopes or Ø8 mm straight driver passages inside the underside cavity.
  The nearest existing Ø5 insert envelope leaves 6.400 mm of planar material;
  heads clear existing columns by 10.148 mm and the perimeter by 20.375 mm.
  These are layout checks, not a strength rating.
- Preserve the current closed 8.6 ×13.5 mm stadium cable opening and the
  faceplate clearance. No metal-hole change is needed for the recommended
  bottom-base layout.

The existing 6 mm pocket depth is consistent with the general recommendation
of insert length plus two thread pitches; boss dimensions, actual insert fit
and resistance to pull-out still depend on the selected insert and print.
[SPIROL design guidance](https://www.spirol.com/resources/white-papers/how-to-design-the-proper-hole-for-heat-ultrasonic-inserts/).

## Open Questions

- Verify the actual first-print insert fit, screw heads, coated grip and insert
  seating against the qualified digital envelopes. Keep physical PETG load
  qualification separate.
- Completed: regenerated both tall-part STEP/STL pairs, saved/reopened both
  Fusion documents and replaced the first-print package with four front/mid
  collar and sled variants. See the mounting review for verification evidence.
