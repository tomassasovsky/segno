<!-- cspell:words EEUFR WIMA KSSD -->
<!-- cspell:words DPDT AXICOM Littelfuse Lumberg Wuerth dshapes -->
<!-- cspell:words ECEA TLP NOPB PDIP StepUp ksu -->
<!-- cspell:words Vishay Digi easyw JLCPCB's -->
# Screen-power assembly models

Every populated component in the board has a project-relative STEP model.
The models are stored beside the native hand folder so KiCad does not need
machine-specific 3D library paths. Bare M3 mounting holes intentionally have
no solid body. Screws, mating plugs, cable bends and enclosure clearance are
not included in the populated board model.

## Custom models

These eight models were drawn for Segno with `model_geometry.py` and CadQuery
2.8. They are original simplified assembly geometry under the repository's
GPL-3.0 license, not manufacturer-supplied CAD. Dimensions are nominal except
where explicitly described as maximum; molded details and lead bends are
simplified. Use the linked manufacturer drawings for mechanical qualification.

| File stem | Published geometry used | Source |
| --- | --- | --- |
| Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm | 10 × 6 × 5.65 mm; 0.25 mm standoff; eight 0.4 × 0.2 mm leads, 5.08 mm row spacing, 3.2 mm lead projection | [TE IM02TS, customer drawing 1462037-4](https://www.te.com/en/product-1-1462037-3.html) |
| Fuse_Littelfuse_251_P12.70mm | Maximum 7.11 × diameter 2.8 mm body; 0.64 mm leads formed at 12.7 mm pitch; 0.4 mm assembly standoff | [Littelfuse 251](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688) |
| JST_VH_B2P-VH_1x02_P3.96mm_Vertical | 7.86 × 8.5 × 10.9 mm header envelope, 3.96 mm pitch | [JST VH standard header](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf) |
| Panasonic_EEUFR1A221 | Nominal diameter 6.3 × height 11.2 mm, 2.5 mm pitch, 0.5 mm leads; body center between pads | [Panasonic FR-A, pages 1 and 4](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1259.pdf) |
| Panasonic_EEUFR1A151 | Nominal diameter 5.0 × height 11.0 mm, 2.0 mm pitch, 0.5 mm leads; body center between pads | [Panasonic FR-A, pages 1 and 4](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ABA0000C1259.pdf) |
| Panasonic_ECEA1EN100U | Nominal diameter 5.0 × height 11.0 mm, 2.0 mm pitch, 0.5 mm leads; bipolar body without polarity stripe | [Panasonic SU-A, printed pages 86 and 88](https://industrial.panasonic.com/cdbs/www-data/pdf/RDF0000/ast-ind-152837.pdf) |
| WIMA_MKS2C031001A00KSSD | Nominal 7.2 × 2.5 × 6.5 mm body, 5.0 mm pitch, 0.5 mm leads | [WIMA catalogue, printed page 35](https://www.wima.de/wp-content/uploads/media/WIMA_Main_Catalogue_2026.pdf) |
| Vishay_PR01_P10.16mm | Maximum 6.5 mm main body, 8.0 mm coating extent, diameter 2.5 mm and 0.63 mm leads; formed at 10.16 mm pitch with 0.5 mm body standoff | [Vishay PR01 drawing, page 16](https://www.vishay.com/docs/28729/pr010203.pdf) |

The capacitor models show bodies seated at the PCB surface and leads trimmed to
3 mm below that surface for assembly. They do not show the much longer stock
Panasonic leads or the WIMA stock 6−2 mm lead option. The stripe marks the
FR-A negative pin 2. Model dimensions are nominal; fit review uses the
Panasonic maximum diameter/height envelopes of 6.8 × 12.7 mm (C2) and
5.5 × 12.5 mm (C102/C202). These include the published +0.5 mm diameter and
+1.5 mm body-length tolerances. No unspecified WIMA body tolerance is assumed.

Revision L adds the bipolar SU-A model for C3/C4. It deliberately has no
polarity stripe, and uses `C_Radial_D5.0mm_H11.0mm_P2.00mm`, whose silkscreen
has no positive marker. Either capacitor lead may enter pad 1. SU-A has
different tolerances from FR-A: diameter ±0.5 mm, length ±1.0 mm, lead
diameter ±0.05 mm and pitch ±0.5 mm. Reserve a 5.5 × 12.0 mm maximum body
envelope. The 0.8 mm footprint drill permits a minimum 0.72 mm finished hole,
leaving 0.17 mm diametral clearance over the maximum 0.55 mm wire. C5 reuses
the WIMA model and its existing 5 mm pitch.

Procurement check, 2026-09-25: Panasonic's
[Japanese product page](https://industrial.panasonic.com/jp/eol/pt/aluminum-cap-lead/models/ECEA1EN100U)
marks ECEA1EN100U discontinued. The
[DigiKey ECE-A1EN100U listing](https://www.digikey.com/en/products/detail/panasonic-electronic-components/ECE-A1EN100U/227617)
returned 5,092 in stock at USD 0.45 each and still listed the part as active.
These lifecycle entries disagree; the selected part relies on distributor
stock for this small hand-assembled batch, not a promise of future production.
The stock snapshot is not a reservation. A future substitute requires checking
its electrical ratings and maximum body/lead dimensions against this footprint.

Revision K replaces the generic capacitor models: those previously understated
the two electrolytic heights and overstated the film-capacitor height. C1 moves
1.5 mm left to clear the published mated VH housing envelope; the other
component positions and connectors remain unchanged.

The PR01 model replaces R8's generic 6.3 mm resistor preview. Its end coating
uses the full 2.5 mm diameter as a conservative envelope. Separate solids show
the main body and coating extensions; this is simplified maximum-envelope
geometry, not the manufacturer's exact surface shape. Leads are simplified
and trimmed to 3 mm below the board's top surface. The unchanged footprint
and formed-lead clearance were checked independently.

Insulation, relay markings and connector latches are represented
only sufficiently to identify orientation and occupied space. Models do not
establish mating fit, contact geometry, latch accessibility, or worst-case
component tolerances. The PCB footprints, drills and manufacturer drawings
remain authoritative for assembly.

## KiCad models

The other STEP files are unmodified models copied from the installed KiCad 10
library. Original attribution remains in STEP headers; directory credits are
retained in `licenses/`. They are redistributed under CC-BY-SA 4.0 with KiCad's
library exception, as reproduced in [LIBRARY_LICENSE.txt](../LIBRARY_LICENSE.txt).
Sources are the matching libraries in the
[KiCad 3D models collection](https://gitlab.com/kicad/libraries/kicad-packages3D).

| Files | Upstream library |
| --- | --- |
| D_DO-* | Diode_THT.3dshapes |
| DIP-4_W7.62mm, DIP-8_W7.62mm | Package_DIP.3dshapes |
| JST_XH* | Connector_JST.3dshapes |
| R_Axial* | Resistor_THT.3dshapes |
| TO-220*, TO-92* | Package_TO_SOT_THT.3dshapes |

The two DIP files retain their additional original GPL-3.0-or-later headers
with the embedded-design exception; those notices are not replaced by the
library-level license. The upstream
[Package_DIP credits](https://gitlab.com/kicad/libraries/kicad-packages3D/-/blob/master/Package_DIP.3dshapes/CREDITS.md)
are copied unchanged to `licenses/Package_DIP-CREDITS.md`. They identify
Maurice easyw as the main script author; the STEP file author fields identify
KiCad StepUp and ksu. The DIP files are generic nominal previews, not exact
manufacturer bodies or maximum clearance envelopes.

## Revision L DIP fit

U1 uses `DIP-8_W7.62mm` for LMC7660IN/NOPB; U2 uses `DIP-4_W7.62mm` for the
through-hole TLP627M(E. Both have 2.54 mm lead pitch, 7.62 mm formed row
spacing and a pin-1 mark at the footprint's pad 1. The generic previews must
not replace these manufacturer envelopes during placement review:

| Part | Manufacturer dimensions to reserve | Lead section |
| --- | --- | --- |
| U1 LMC7660IN/NOPB | Maximum 10.16 mm along the lead rows, 6.60 mm across the body, 5.08 mm above the seating plane | Width up to 0.53 mm; thickness 0.25 mm nominal, with no maximum specified in this drawing |
| U2 TLP627M(E | Body 4.58 ±0.25 mm along the lead rows, 6.4 ±0.25 mm across; body height 3.65 +0.15/−0.25 mm, with 0.8 ±0.25 mm between body bottom and lead shoulder | Width 0.5 ±0.1 mm; thickness 0.25 +0.10/−0.05 mm |

Sources: [TI LMC7660, PDF page 21, drawing 4040082/E](https://www.ti.com/lit/ds/symlink/lmc7660.pdf)
and [Toshiba TLP627M, page 13, 11-5B2S](https://toshiba.semicon-storage.com/info/docget.jsp?did=163903&prodName=TLP627M).
The Toshiba drawing gives a conservative 4.85 mm body-top height when its
lead shoulder is at the board surface; assembly standoff adds to that height.
TI's unformed leads may be splayed to 10.92 mm overall; form the two rows to
the footprint spacing before insertion. No socket is included in these models.

Both DIP footprints use 0.90 mm drills instead of the library's 0.80 mm,
retaining the 1.60 mm pads and 0.35 mm nominal annular ring. With
[JLCPCB's −0.08 mm hole tolerance](https://jlcpcb.com/capabilities/pcb-capabilities),
the minimum finished hole is 0.82 mm. U2's maximum rectangular lead diagonal
is 0.695 mm, leaving 0.125 mm diametral insertion clearance. The old 0.80 mm
drill left only 0.025 mm. U1's 0.53 mm width and nominal 0.25 mm thickness
give a 0.586 mm diagonal; this comparison is not a maximum-thickness guarantee.
Lead forming and component tolerances still apply; the drill change does not
alter pad centers or route clearances.

`check.py` rejects missing, disabled, unresolved or wrongly formatted model
assignments. Native STEP export, populated renders and independent solid
parsing provide additional verification; the assignment check alone is not
a STEP geometry validator.
