<!-- cspell:words fanout overmolds Mbps BXHALFSN -->
# Revision O USB harness

The approved harness uses suitable existing USB donor cables, terminated in
four five-position JST XH plugs. This replaces the ready-made four-position
cable plan. Main-power VH connections are unchanged. Connector selection is
not a claim of completed assembled USB qualification or enclosure fit.

## Parts and pin assignment

J101, J102, J201 and J202 use **B5B-XH-A(LF)(SN)** through-hole headers and
**XHP-5** cable housings. The [JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf)
defines 2.50 mm pitch and a 10 mm span between the five contact centers.
The five-position housing is 14.8 × 5.7 mm, 2.5 mm longer than the four-position
housing. Its plan envelope fits within the 14.9 × 5.75 mm header body; the
mated height is 9.8 mm. Local fit must also account for the wire exits.

| Pin | Function |
| --- | --- |
| 1 | VBUS: host-presence input on J101/J201; fused switched touch power on J102/J202 |
| 2 | D− |
| 3 | D+ |
| 4 | GND, dedicated power return |
| 5 | Cable shield to board GND |

The connector carries no CC signal. Keep the correct legacy-source 56 kΩ
Rp in the factory USB-C plug. Unplugging a housing removes all five conductors;
there is no separate shield solder connection to the PCB. TP101, TP102, TP201
and TP202 are removed.

Four USB plugs need **20 new crimp contacts**, including four shield contacts.
The selected **SXH-001T-P0.6** contact requires 28–22 AWG conductor and
**0.9–1.9 mm insulation outside diameter**. Those are separate constraints.
The owner's donor wire sizes are unknown; verify both before choosing and
crimping a donor. Do not fold strands or rely on a loose insulation crimp to
make a wire fit. Use tooling appropriate to the contact and inspect retention.

## Construction and remaining fit check

One suitable A-to-C donor and one A-to-Micro-B donor can supply the four touch
tails, preserving factory plugs and overmolds. Retain the cable shield and
controlled data pair up to the shortest practical fanout. Bring an insulated
shield termination into pin 5; if a bare drain does not fit the contact, join
it to a short wire with suitable conductor and insulation dimensions and
insulate the joint. Keep that shield breakout within 10 mm as a construction
target. Clamp the jacket so connector handling does not pull individual wires.
Do not use braid as a load-current return.

The old side-solder-pad fit assessment does not prove the new in-plug fanout
fit. Check the actual donor and jacket arrangement at the five-position plug.
The retained cable-length limits are 30 cm per host tail, 25 cm for C touch
and 30 cm for Micro-B touch, including service slack. Measure the enclosure
routes before cutting. The earlier placement study suggests a Pi-to-board
route longer than the host limit; the five-pin change does not resolve that
installation question. Either the placement or the assessed full-channel
length must be resolved before claiming the harness fits the enclosure.

Main-power leads still use VH2, at most 30 cm, with 20 AWG or larger supply
and return conductors and 3 A-rated terminations. Unidentified old test cables
are not assumed to meet this requirement.

Continuity checks must cover all five numbered cavities, USB contacts and
shell, plus shorts. Assembled verification still covers the UPERFECT 480 Mbps
hub path, APROTII touch, both C orientations, startup and shutdown cutoff.
Factory donor certification does not certify the modified complete channel.

## Mouser US procurement check

Live US product pages checked September 28, 2026; prices are USD before tax.
These quantities go into the same consolidated Mouser order for Miami.

| Mouser part | Qty | Unit price | Stock shown |
| --- | ---: | ---: | ---: |
| [306-B5BXHALFSN](https://www.mouser.com/en/ProductDetail/JST-Commercial/B5B-XH-ALFSN?qs=cdbOS8ANM9ApoXpxtybURg%3D%3D) | 4 | $0.20 | 46,461 |
| [306-XHP-5](https://www.mouser.com/en/ProductDetail/JST-Commercial/XHP-5?qs=QpmGXVUTftFWFYWMIpK8uw%3D%3D) | 4 | $0.10 | 156,710 |
| [306-SXH-001T-P0.6](https://www.mouser.com/en/ProductDetail/JST-Commercial/SXH-001T-P0.6?qs=QpmGXVUTftHVe8yFBLIwfA%3D%3D) | 35 combined | $0.041 at 25+ | 963,813 |

All three showed immediate shipment. Indicated US tariffs were 30%, 30% and
11%, respectively; stock is not reserved. The consolidated contact quantity
is **15 for other harnesses plus 20 for USB**, without spare crimps. Four
additional shield contacts cost about $0.16 at that price break; the larger
shopping-list increase also accounts for the previously omitted USB crimps.

The prior quote's four console/ring B4 headers and four XHP-4 housings remain
required; do not replace those with five-pin parts. The screen changes take
the consolidated list from 53 lines / 168 units to **55 lines / 192 units**.
The incremental estimate is **$88.22 before tax**, carrying forward all other
prices and the previous shipping estimate. A fresh complete quote was not
obtained and no cart was changed. See [component costs](../../../hardware/kicad/screen_power/COSTS.md)
for the calculation and exclusions.
