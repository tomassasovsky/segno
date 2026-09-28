<!-- cspell:words Littelfuse Omron desoldered BXHALFSN -->
# Screen-power revision O component costs

**28 September 2026, USD, Mouser US.** Revision O replaces four screen-board
headers with five-pin XH parts and adds four mating housings and 20 USB-tail
contacts. The updated consolidated list is **55 part lines, 192 units**.
The connector changes add **$1.22 in parts and about $0.44 in estimated
tariffs** to the earlier quote. Carrying forward its other prices and shipping
gives **$88.22 estimated before tax**: $69.81 parts, $9.92 estimated tariffs
and $8.49 estimated shipping. This is an incremental estimate, **not a new
complete Mouser quote** or a complete build cost.

The [historical Revision N quote](https://www.mouser.com/en/price-availability/Edit?bomId=8d557212-bfa8-4ecd-9a90-89cffde392b4)
was $86.56 before tax, with all 53 lines / 168 units marked Ships Now at its
September 28 check. Its four-pin screen headers and omitted USB-tail crimps
do not match Revision O. Only the three connector/contact products below
were checked again for this update. Stock is not reserved; shipping has not
been rated against a specific Miami street address. No cart or order was changed.
Use the manufacturing revision identified by the current board documentation.

## Revision O connector purchase changes

Live Mouser US product pages on September 28 showed the following availability.
Quantities are combined with the other two boards for one Mouser shipment to
Miami; do not place a separate connector order.

| Part | Required change | Unit USD | Availability at check |
| --- | --- | ---: | --- |
| [B5B-XH-A(LF)(SN), 306-B5BXHALFSN](https://www.mouser.com/en/ProductDetail/JST-Commercial/B5B-XH-ALFSN?qs=cdbOS8ANM9ApoXpxtybURg%3D%3D) | Buy 4; reduce B4B-XH-A from 8 to 4 | $0.20 | 46,461 can ship immediately |
| [XHP-5, 306-XHP-5](https://www.mouser.com/en/ProductDetail/JST-Commercial/XHP-5?qs=QpmGXVUTftFWFYWMIpK8uw%3D%3D) | Add 4; retain all 4 XHP-4 housings used elsewhere | $0.10 | 156,710 can ship immediately |
| [SXH-001T-P0.6, 306-SXH-001T-P0.6](https://www.mouser.com/en/ProductDetail/JST-Commercial/SXH-001T-P0.6?qs=QpmGXVUTftHVe8yFBLIwfA%3D%3D) | Increase 15 to 35: 15 other harness contacts + 20 USB contacts | $0.041 at 25+ | 963,813 can ship immediately |

The headers total $0.80, housings $0.40 and all 35 contacts $1.44 after line
rounding. Mouser showed possible US tariffs of 30% on the new headers/housings
and 11% on contacts. The previous quote included only 15 contacts for other
harnesses: adding just four would leave the four USB plugs incomplete. Within
the USB harness, the fifth shield position itself adds four contacts (about
$0.16 at the combined price break) over a four-wire DIY harness. Quantities
exclude spare crimps and assume the actual donor wires fit the specified contacts.

Only the main input fuse is removable. F1 cartridge and holder cost $2.48
including estimated tariffs. Four soldered Bel branch fuses cost $2.71.
The historical Revision N quote saved $11.06 over making all five fuses
removable and added $1.93 to the all-soldered $84.63 proposal. Those comparisons
predate the Revision O USB harness additions.

## Components fitted to one screen board

The table accounts for 42 electrical references and the separately purchased
F1 holder, with no duplicate footprint or extra inline holder. Prices use
quantity breaks from the consolidated three-board purchase. The attribution
below uses the historical prices except for the new five-pin headers and
excludes tariffs, shipping and spare resistors; it is not a separate
screen-only cart quotation. The total is calculated before row rounding,
which can make the displayed rows differ by one cent.

<!-- cspell:disable -->

| References | Exact manufacturer part | Qty | Unit USD | Fitted USD | Mouser |
| --- | --- | ---: | ---: | ---: | --- |
| F102, F202 | 0697H0800-02 | 2 | $0.58 | $1.16 | [530-0697H0800-02](https://www.mouser.com/en/ProductDetail/Bel/0697H0800-02?qs=GtFly9OVs8891kOm2CYGHw%3D%3D) |
| F101, F201 | 0697H4000-02 | 2 | $0.46 | $0.92 | [530-0697H4000-02](https://www.mouser.com/en/ProductDetail/Bel/0697H4000-02?qs=GtFly9OVs8%2F1PnMQKLkfbA%3D%3D) |
| K101, K201 | 1-1462037-3 | 2 | $5.02 | $10.04 | [655-IM02TS](https://www.mouser.com/en/ProductDetail/TE-Connectivity/IM02TS?qs=zhuCMSiDrbKPl9KcuMmVpA%3D%3D) |
| D101, D201 | 1N4007G | 2 | $0.23 | $0.46 | [863-1N4007G](https://www.mouser.com/en/ProductDetail/onsemi/1N4007G?qs=y2kkmE52mdOJ200gEKhp%2FQ%3D%3D) |
| Q1 | 2N3904BU | 1 | $0.29 | $0.29 | [512-2N3904BU](https://www.mouser.com/en/ProductDetail/onsemi/2N3904BU?qs=or4AE2qAS%252Bd0Jdpn%2F8ktKg%3D%3D) |
| Q2 | 2N3906BU | 1 | $0.26 | $0.26 | [512-2N3906BU](https://www.mouser.com/en/ProductDetail/onsemi/2N3906BU?qs=iN0KuJO79Kbn9o7a2lB4uA%3D%3D) |
| J2 | B2B-XH-A(LF)(SN) | 1 | $0.087 | $0.09 | [306-B2BXHALFSNP](https://www.mouser.com/en/ProductDetail/JST/B2B-XH-ALFSN?qs=cdbOS8ANM9DdcSn9qRmfCw%3D%3D) |
| J1, J103, J203 | B2P-VH(LF)(SN) | 3 | $0.16 | $0.48 | [306-B2P-VHLFSN](https://www.mouser.com/en/ProductDetail/JST/B2P-VHLFSN?qs=QpmGXVUTftEIUcnoKC896A%3D%3D) |
| J101, J102, J201, J202 | B5B-XH-A(LF)(SN) | 4 | $0.20 | $0.80 | [306-B5BXHALFSN](https://www.mouser.com/en/ProductDetail/JST-Commercial/B5B-XH-ALFSN?qs=cdbOS8ANM9ApoXpxtybURg%3D%3D) |
| C102, C202 | EEU-FR1A151 | 2 | $0.38 | $0.76 | [667-EEU-FR1A151](https://www.mouser.com/en/ProductDetail/Panasonic/EEU-FR1A151?qs=ob%252BdNz2%252BYEgPJYp97cyKrA%3D%3D) |
| C2 | EEU-FR1A221 | 1 | $0.48 | $0.48 | [667-EEU-FR1A221](https://www.mouser.com/en/ProductDetail/Panasonic/EEU-FR1A221?qs=ob%252BdNz2%252BYEhkWgEESuSfIA%3D%3D) |
| C1, C101, C201 | K104K10X7RF53H5 | 3 | $0.26 | $0.78 | [594-K104K10X7RF53H5](https://www.mouser.com/en/ProductDetail/Vishay/K104K10X7RF53H5?qs=fflMSwnno4x9bs4LC2tdMA%3D%3D) |
| R6, R102, R202 | MFR-25FBF52-100K | 3 | $0.042 | $0.13 | [603-MFR-25FBF52-100K](https://www.mouser.com/en/ProductDetail/YAGEO/MFR-25FBF52-100K?qs=oAGoVhmvjhxAqZbyE%2Fs9bg%3D%3D) |
| R101, R201, R7 | MFR-25FBF52-10K | 3 | $0.042 | $0.13 | [603-MFR-25FBF52-10K](https://www.mouser.com/en/ProductDetail/YAGEO/MFR-25FBF52-10K?qs=oAGoVhmvjhxY0mVN9GL5Pg%3D%3D) |
| R1 | MFR-25FBF52-1K | 1 | $0.10 | $0.10 | [603-MFR-25FBF52-1K](https://www.mouser.com/en/ProductDetail/YAGEO/MFR-25FBF52-1K?qs=oAGoVhmvjhwCAC47ReWjsQ%3D%3D) |
| R2 | MFR-25FBF52-4K7 | 1 | $0.044 | $0.04 | [603-MFR-25FBF52-4K7](https://www.mouser.com/en/ProductDetail/YAGEO/MFR-25FBF52-4K7?qs=oAGoVhmvjhyEuU2iU0uA4w%3D%3D) |
| R5 | MFR-25FBF52-5K6 | 1 | $0.10 | $0.10 | [603-MFR-25FBF52-5K6](https://www.mouser.com/en/ProductDetail/YAGEO/MFR-25FBF52-5K6?qs=oAGoVhmvjhxL79DuPEfHMw%3D%3D) |
| R8 | PR01000101000FA100 | 1 | $0.45 | $0.45 | [594-PR01000101000FA1](https://www.mouser.com/en/ProductDetail/Vishay/PR01000101000FA100?qs=17u8i%2FzlE8%252B%252BSN%2FNRC7Xyg%3D%3D) |
| Q101, Q102, Q201, Q202 | TN0702N3-G | 4 | $1.52 | $6.08 | [689-TN0702N3-G](https://www.mouser.com/en/ProductDetail/Microchip/TN0702N3-G?qs=b1HjDA41YmFb%2FZmSTijIVQ%3D%3D) |
| K1 | G6C-1117P-US-DC5 | 1 | $6.91 | $6.91 | [653-G6C-1117P-DC5](https://www.mouser.com/en/ProductDetail/Omron/G6C-1117P-US-DC5?qs=HDDQUw%2F3Phpg0slquElzvg%3D%3D) |
| D3 | P6KE6.8CA | 1 | $0.70 | $0.70 | [576-P6KE6.8CA](https://www.mouser.com/en/ProductDetail/Littelfuse/P6KE6.8CA?qs=zHiv0nsVGmrBoLtZ6Umrjg%3D%3D) |
| Q5 | IRLZ44NPBF | 1 | $1.70 | $1.70 | [942-IRLZ44NPBF](https://www.mouser.com/en/ProductDetail/Infineon/IRLZ44NPBF?qs=9%252BKlkBgLFf15OZZk%252BD0ibg%3D%3D) |
| F1 | 0001.2513 | 1 | $0.91 | $0.91 | [693-0001-2513](https://www.mouser.com/en/ProductDetail/Schurter/0001.2513?qs=WtG364jHAdzldSgYj55SVw%3D%3D) |
| F1 holder | 0031.8201 | 1 | $1.20 | $1.20 | [693-0031.8201](https://www.mouser.com/en/ProductDetail/Schurter/0031.8201?qs=A0AD9A9uYPZ%2F5Y96FqMyAQ%3D%3D) |
| **Total** | **24 part types** | **43** | | **$34.96** | |

<!-- cspell:enable -->

The PCB BOM spells the Omron ordering code `G6C-1117P-US DC5`; Mouser prints
`G6C-1117P-US-DC5`. These identify the same chosen 5 V, one-normally-open
relay. Its 10 A contact rating must not be confused with the two-pole variant.
Four mounting holes are bare PCB features with no separate parts. The four
former shield solder pads are removed; their connection is inside the USB plugs.

## Reuse and exclusions

The combined list reuses the owner's SparkFun PD module, intact transferable
v2 switches, jacks and looms, Pi, screens, buck converters, LED strip/pills,
HDMI and suitable existing USB donor cables. It does not assume the earlier
ready-made four-pin USB cables were purchased. A fresh Pico 2 is included; the old one
need not be desoldered. The retained upstream 20 V fuse is not purchased
again. Spare resistors appear only when their quantity break lowers the
actual line cost.

The revised list includes the specified connector housings and contacts. Wire,
insulation, screen-end power-lead adaptation, mounting hardware, solder,
assembly tools, PCB fabrication and sales tax are outside it. Use the
[external wiring BOM](external_bom.csv) and [wiring instructions](README.md#wiring)
for gauge and termination requirements. Four XHP-5 housings and 20 USB crimps
are now required. Existing donor gauge, insulation diameter and shielding
remain to be established during harness construction. Replacement donor cables,
if the existing ones are unsuitable, are not priced in this estimate.

Do not buy the removed SUP70101EL pair, charge pump/optocoupler parts,
Littelfuse inline holder, Bel 8 A input fuse, or abandoned branch-fuse holders
for Revision O. Older cost tables remain historical evidence only.
