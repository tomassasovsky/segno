<!-- cspell:words Littelfuse Littelfuse's Schurter Vmax Vtyp centerlines floorplan fuseholder milliohm respaced styp upsize -->
# Replaceable screen-board fuses — technical selection

> Historical all-five-replaceable option, superseded for cost. The selected design retains only the OGN main-input holder and uses soldered Bel 0697H output fuses. These Eaton/Keystone findings do not describe the current output parts.

Read-only assessment, 27 September 2026. No circuit, CAD or manufacturing files changed. This supersedes the earlier soldered-fuse choice only as a design recommendation; it is not a completed layout or production approval.

## Recommendation

Use **five 5×20 mm cartridge fuses**. For the input use the **Schurter OGN 0031.8201 through-hole holder** with **SPT 0001.2513, 8 A time-delay**. For the four outputs, use **two Keystone 3521 through-hole clips per fuse**, with their integral end stops facing outward. Preserve 4 A main and 800 mA touch ratings and the 500 mA normal touch-current allocation. The procurement agent is checking the least-expensive suitable output cartridges; exact output fuse MPNs still need their pulse/drop comparison before acceptance.

This mixed arrangement gives the input a documented resistance budget, uses less space around the output connectors than five molded holders, and permits every replacement without lead cutting or soldering. Clips are genuine fuse contacts, not improvised headers. An unpowered board and a small fuse puller give access where fingers cannot fit; do not hide the fuse under a connector mating envelope or wire bundle.

Current Keystone product page rates 3521 at **15 A**; legacy catalog and some distributor fields say 10 A. Both exceed the 8/4/0.8 A choices, but quote the current manufacturer page and retain this discrepancy in selection evidence. No numerical contact-resistance bound was found for 3521, so do not label an invented resistance as a datasheet guarantee.

## Size and board fit

The native board remains 68×76 mm. Current connector anchors and both USB rows were read from `layout.py`, `route_critical.py` and the routed native PCB. The existing axial fuse centers are approximately (43,23), (43,43), (43,48), (43,68) in the generator's centering convention. The **middle fuse centers are only 5 mm apart**. Neither radial sockets nor cartridge holders can simply replace those footprints in place.

| System | Published mechanical facts | Consequence |
| --- | --- | --- |
| OGN 0031.8201 THT | Body 25×9.6 mm, **10.8 mm installation width**, 22.5 mm pin pitch, recommended 1.3 +0.1/−0 mm holes; drawing gives 11.5 mm uncovered /12.7 mm covered height | Suitable input assembly. Do not use 0031.8221, which is SMT. Reserve its actual courtyard and vertical removal access. |
| Keystone 3521 pair for 5×20 | Manufacturer mounting guide figure 7: clip-to-clip mounting-column pitch **18.1 mm**, two leads per clip at **5.0 mm** transverse pitch, **1.19 mm** recommended holes. Each clip must be oriented for the end stops to retain the selected 20 mm cartridge. | Four plated holes per complete holder. Do not copy the 13.1 mm layout for shorter 2AG fuses. The bare clip assembly is appreciably narrower than OGN; use the actual 3521 drawing for the final body/courtyard, not the neighboring 3562's 12 mm dimensions. |
| Littelfuse 560 | Ø9.5 mm body, 5.08 mm pitch; 56000001009/1019 height A=4.3 mm, 56000001319 A=3.0 mm | Compact radial option, but **6.3 A maximum**. Not the 8 A input choice. |
| Littelfuse 56200001009 | 5.08 mm pitch; drawing shows approximately 7.65×4.55 mm holder body, with a round TR5 fuse itself Ø8.5 mm | Attractive with rectangular TE5 fuses; THT 562, not SMT 564. Still 6.3 A. |

A **mixed holder/clip floorplan is plausible within the same outline**, but this report does not claim collision-free placement. First attempt four horizontal output cartridges in the existing right-hand fuse region, with touch-1 and main-2 respaced, preserving the two straight USB corridors at y=36 and y=61. The following work is genuinely required:

- Redistribute the adjacent TN0702 drivers/dividers and local capacitors if their current courtyards collide with the longer cartridges; moving those parts does not require moving the USB relay contacts, connectors, or data pairs.
- Reserve roughly an 8 mm-wide planning band around each clip assembly until the exact assembled model/courtyard is checked. A four-row stack needs more than the present 5 mm middle spacing.
- The top bay released by the charge pump/opto/power MOSFETs can accommodate the rotated 20×15 mm relay and one OGN input holder in separate bands, subject to actual lead positions and the input copper-loss target. Put F1 close to J1 and the relay coil take-off immediately after F1.
- Check C102/C202, the lower bleeder and the Q102/Q202 areas explicitly: these occupy the space a casual cartridge-footprint substitution would consume. Their old positions cannot be treated as fixed while claiming all cartridges fit.
- All five OGN bodies alone occupy 1,200 mm², about 23% of gross board area before service/courtyard spacing. Their 10.8 mm installation width (1,350 mm² for five rectangular envelopes) makes them substantially less attractive around the two fixed connector/USB rows. Mixed input OGN/output clips is the first design attempt, not arbitrary board enlargement.
- No fuse-pad drill, non-ground copper clearance or routing cut may disturb the front-layer reference beneath the existing back-layer USB pairs. Preserve pair centerlines, width/gap, length matching and via count, and rerun the reference-plane guard after refilling.

Exact sources: [OGN drawing, pp2–3 and order table p5](https://www.schurter.com/en/datasheet/typ_ogn.pdf); [Keystone mounting guide, p49 figure7](https://www.keyelco.com/userAssets/file/M65-fuse-mountinglayout.pdf); [current 3521 product and drawing link](https://www.keyelco.com/product.cfm/For-2AG-5mm-Cylindrical-Fuses/Snap-In-PC-Fuse-Clips/product_id/359).

## Input electrical budget

The OGN is rated 16 A under UL/CSA, 500 VAC/VDC and −40…85 °C; its IEC power-acceptance curves account for ambient temperature and fuse heating. Its contact resistance is ≤10 mΩ at 100 mA. Schurter explicitly defines catalog contact resistance **between the fuseholder terminals**, so this covers the complete holder, not 10 mΩ for each end.

SPT 0001.2513 is 8 A, 150 VDC, time-delay; maximum rated-current voltage drop is **100 mV**, typical 70 mV, typical melting integral **268 A²s at 10×In**. Do not transfer the removed Bel's 80 mV limit or 273 A²s number. The data do not prove indefinite dirty-contact behavior, fuse resistance at arbitrary temperatures, or total fault-clearing energy.

The updated independent calculation is [the holder/coil budget](holder-coil-budget.md). With 4.75 V still measured at J1, the deliberately conservative fully loaded budget is 100 mV fuse +44 mV holder +20 mV copper +5 mV driver: **4.581 V coil voltage**, only **3 mV** over the prior 100 °C winding pickup model. This is not the old 67 mV margin. At actual pickup the normally open relay excludes the screen load; with all coils/control below150 mA the holder contributes only1.5 mV, giving **4.6235 V** and **45.5 mV** hot-pickup margin while retaining the full100 mV fuse allowance. The 100 °C winding ceiling remains an engineering envelope, not a measured or manufacturer-guaranteed rise.

Once the power contact closes, screen capacitance can sag the source and cause bounce; neither a DC drop calculation nor the must-release voltage proves immunity. Preserve the existing bounded capacitance/inrush assessment. The USB relay adverse thermal model retains approximately **110.8 mV** pickup margin at full screen load with the new input allowance.

Primary evidence: [SPT data](https://www.schurter.com/en/datasheet/typ_spt_5x20.pdf), [OGN data](https://www.schurter.com/en/datasheet/typ_ogn.pdf), [definition and thermal selection guidance](https://www.schurter.com/en/knowledge/fuseholder).

## Output clip significance and fuse acceptance

A 15 A clip carrying at most3 A main or0.5 A normal touch is lightly loaded. Missing a milliohm guarantee does **not** itself make this established fuse-clip design unsuitable. It does mean the voltage-drop model should label its contact allowance honestly. For sensitivity, a complete pair at10 mΩ drops30 mV and dissipates90 mW at3 A, or5 mV/2.5 mW at0.5 A. A20 mΩ pair doubles those values. These are engineering scenarios, not Keystone specifications. Output clip drop does not feed back into the relay coil supply because it is downstream of the power contact.

Use genuinely time-delay cartridges and compare the actual selected rows, not just the word “slow”: the previous Bel touch fuse had nominal2.3 A²s below10 ms and3.1 A²s at10×In; the previous main fuse had81/92 A²s. A lower value can still be adequate, but requires rerunning the existing local-cap/possible joined-screen-path pulse calculation, including bounce assumptions. Do not silently choose fast glass fuses, upsize touch fuses, or infer a DC interrupt rating from an AC-only listing.

For an exact fully documented alternative, Schurter SPT **0001.2510 4 A** gives100 mV max/90 mVtyp and62.4 A²styp at10×In; **0001.2503 800 mA** gives500 mVmax/260 mVtyp and2.3 A²styp at10×In. The latter drop is markedly worse than the prior150 mV touch-fuse allowance and should not be accepted as a transparent substitution merely because pulse energy matches. Procurement's cheaper alternatives need the same checks. SPT has explicit DC interrupt tables for these rows.

At5 V the interruption problem is modest, but the finished packet should still cite the selected cartridge's published DC rating rather than invent one. Keep all fuse ratings readable near their holders and in the replacement list; no arbitrary cartridge with the same nominal current is automatically equivalent.

## Why compact radial sockets are not the selected route

Littelfuse's 559/560/562 and capped571/576 systems are genuine sockets but all are6.3 A maximum. Four radial output fuses would save space, but a different input system is still required. Active-looking Littelfuse37408000410/37414000410 are proper4.3 mm short-pin800 mA/4 A versions; current primary tables give minimum melting integrals2.112/56 A²s at10×In, but only AC interruption evidence was found. The round8.5 mm bodies also collide at the original middle5 mm row pitch.

Schurter MST250 offered explicit63 VDC and suitable short pins, but its current manufacturer PDF is PHASE-OUT and January2026 notice states last shipment July31,2026. It is inappropriate as the preferred new replaceable system.

Bel0697H -01 has4.3±0.3 mm leads, -05 has3.5±0.3 mm leads; both have5.08±0.1 mm pitch and0.6±0.1 mm round pins with an8.35×4.0 mm rectangular body. A same-brand mating endorsement is not inherently required for a documented standard interface. However, the shortened -05 pin needs real insertion/contact-engagement verification against the chosen socket, and no such engagement bound was found in the socket drawing. Do not trim the stocked -02 taped parts and call them ready-made replaceable fuses. Given current stock and the user's simple replacement requirement, standard cartridges provide the clearer path.

Sources: [Littelfuse560](https://www.littelfuse.com/assetdocs/littelfuse_fuse_holder_559_560_datasheet?assetguid=e5df74ca-cbc9-4ae3-a8e5-3d2504b27b6f), [562](https://www.littelfuse.com/assetdocs/562-564-series-datasheet?assetguid=0c9b83b8-2853-4e31-9999-622141b4638a), [374](https://www.littelfuse.com/assetdocs/fuse-374-datasheet?assetguid=3a419d96-9ce7-47cd-8c71-4ff91f37569c), [Bel mechanical drawing](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf), [MST phase-out-marked current data](https://www.schurter.com/en/datasheet/typ_mst_250.pdf).

## Remaining implementation checks

Proceed with the mixed-holder floorplan and exact stocked cartridge selection. Before releasing it, verify the actual clip drawing/assembled cartridge envelope, all four holes/annuli per holder, replacement access, fixed connector mating clearances, input copper-loss budget and USB reference continuity. Update BOM, source, native PCB/schematic, models, calculation guards and package manifests together. Run the existing negative controls, ERC/DRC, schematic/native net parity and fabrication/export integrity checks. This report does not authorize an order or claim those future checks have passed.
