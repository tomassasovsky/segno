<!-- cspell:words XHP B4B ASCS SOD EEUFR polyline waypoints fanout -->
# Local shield-drain fit

The four shield pads can support separate insulated drain tails no
longer than 10 mm using the side breakouts below. This is a local mechanical
construction assessment, not qualification of the complete harness, USB performance or enclosure fit.
The separate native and manufacturing checks are recorded in [the review](review.md). No PCB geometry was changed here.
Re-evaluate these paths if pad, connector, capacitor or adjacent part positions
change. A planar connector-to-pad distance is insufficient.

## Envelopes and assumptions

The [JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf), printed
pages 2 and 4, shows 9.8 mm fully mated height above the PCB, upward wire exit,
and a 12.3 × 5.7 mm XHP-4 housing. The current header courtyards conservatively
cover that housing in plan; extrude them to 9.8 mm when checking the plugs.
A shield breakout above the plug at 9.8 mm leaves only
`sqrt(10² − 9.8²) = 1.99 mm` horizontal reach even before bends or slack.
It therefore cannot establish the 10 mm bound for these adjacent pads.

The following heights were read from the bundled STEP solids, relative to the
PCB top. Low components are checked at their actual heights, not treated as
infinitely tall courtyard walls:

| Nearby part | Model top | Envelope used |
|---|---:|---|
| D101/D201, DO-41 diode | 3.21 mm | Model radius 1.36 mm and installed height; [Vishay body maximum](https://www.vishay.com/docs/88503/1n4001.pdf), p.4, is 2.7 mm diameter |
| Axial resistors | 2.50 mm | Current horizontal model |
| C102/C202, EEUFR1A151 | 11.0 mm | 5.5 mm diameter × 12.5 mm height, including [Panasonic FR-A tolerances](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1259.pdf), p.1 |
| K101/K201, relay | 5.66 mm | Current relay solid; the proposed local jacket corridors avoid it |

Use a jacket no larger than 5 mm diameter, as documented for the optional
[USBFireWire donor](https://www.usbfirewire.com/parts/rr-ascs-xxgc.html), and an
insulated drain no larger than 2 mm outside diameter. The stripped conductor,
not its insulation, enters the 1 mm hole. The donor's 20 mm jacket bend radius
still applies beyond the straight local approach; these coordinates do not
approve an arbitrary bend elsewhere. The 0.5 mm local body clearance used here
is an assembly allowance, not a JST or USB certification requirement.

## Local construction

All coordinates are millimeters. `r` is the USB row: 36 for channel 1, 61 for
channel 2. `z=0` is the PCB top. `S` is the actual shield takeoff at the jacket
breakout, not the XH centre. Route the insulated drain from S to W, then expose
only the short conductor needed to enter the hole at T. Smooth the bend at W
without adding a detour. Retain any required slack inside the length allowance.

| Cable | S, shield takeoff | W, final approach | T, pad centre | S–W–T length | Remaining to 10 mm |
|---|---|---|---|---:|---:|
| J101/J201 host | (13.95, r−2, 6.5) | (13.5, r−4.5, 1) | (13.5, r−4.5, 0) | 7.0583 mm | 2.9417 mm |
| J102/J202 touch | (50.1, r+1.8, 6.5) | (51.47, r−4, 1) | (51.47, r−4, 0) | 9.1097 mm | 0.8903 mm |

The final native positions are TP101 (13.5,31.5), TP201
(13.5,56.5), TP102 (51.47,32), and TP202 (51.47,57). These match
`hardware/kicad/screen_power/layout.py` SHA-256
`a8cd83e901fbb763c6444726edbf2c2843e8eda4d50d9eab9d24146f84117ae7`.
These coordinates match the finished native board checked in the revision review.

The lengths above include the final 1 mm descent to the board but exclude the
conductor inside/below the plated hole. They are physical polyline lengths,
`distance(S,W) + distance(W,T)`, rather than plan-view distances. A small tangent
bend replacing W lies inside that corner and shortens this polyline; its actual
radius and any extra loop must still fit the stated total. Keep the connection
insulated except at the solder termination; the shield does not replace XH pin 4.

## Local clearance checks

- The conservative header courtyard bounds are x=4.105..10.945 for the host,
  and x=53.105..59.945 for touch. A 5 mm jacket at host x=13.95 leaves
  0.505 mm to the host envelope; touch x=50.1 leaves the same 0.505 mm.
- The jacket bottom at z=6.5 is z=4.0. It clears the diode top by 0.79 mm
  and horizontal resistor tops by 1.50 mm. Consequently the narrow 2D gap
  between the host header and diode does not prohibit this raised jacket.
- For the host, the final 5 mm of straight jacket can approach S from smaller
  y at x=13.95. That local corridor stays beside the plug and above the low
  diode/nearby axial parts; it does not cross the relay. The drain itself has
  at least 0.69 mm lateral clearance to the diode model after including its
  own 1 mm insulation radius, and at least 1.555 mm to the header envelope.
- For touch, approach S from smaller x, with the final 10 mm straight jacket
  centred on y=r+1.8. C102/C202 are centred at approximately
  (47.044888,r−4). Their 2.75 mm maximum radius plus the jacket's 2.5 mm
  radius leaves `5.8 − 2.75 − 2.5 = 0.55 mm` clearance. The local approach
  stops well east of the relay. The fuse is lower and outside this local
  jacket corridor.
- Along the complete touch drain polyline, the closest projected distance to
  the capacitor centre is 4.3066 mm. Subtracting the 2.75 mm maximum can radius
  and 1 mm insulated-drain radius leaves 0.5566 mm clearance. The closest
  touch-header clearance is `53.105 − 51.47 − 1 = 0.635 mm`.

These calculations reserve real local paths without relocating the connectors
or requiring an outboard cable overhang. They assume the documented seated
component envelopes and the specified cable/drain sizes. The complete harness
must retain these side breakouts, keep the data pair twisted/shielded to its
short fanout, and leave access for mating. This assessment does not establish
that every purchased lead has that construction, nor does it certify the full
fanout length, mating service motion or a finished enclosure cable route.
