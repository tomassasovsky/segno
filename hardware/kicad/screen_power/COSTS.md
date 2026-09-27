# Screen-power revision M component cost estimate

<!-- cspell:words DigiKey MOSFETs onsemi Littelfuse VHR SXH XHP SVH SUP PXCN FHAC -->
<!-- cspell:words optocoupler MOSFET WIMA ECEA -->

**USD, quantities updated 27 September 2026.** The 50 populated through-hole components
cost **$44.96** using the dated published single-unit prices below. Allow **$45–50
for board components**, including modest price movement and spare small parts.
This excludes the bare PCB, wiring, mounting hardware, assembly labor, tools,
shipping, taxes and import charges. It is an estimate, not a reserved basket.

Revision M adds two TN0702 presence switches and four sensing resistors,
increasing the prior estimate by $3.44. Its four shield-drain solder pads are
bare PCB features and have no purchased component cost. Revision L introduced
the charge pump and gate drive retained here. The table matches
the current [hand-board BOM](hand/bom.csv). The three part types added in Revision M are marked **26 Sep**. Other
prices retain their stated earlier snapshot dates, not new quotations.

The four mounting holes are PCB features, not four purchased components.
No USB-C modules or additional Pi ribbon are required.

## All populated PCB components

Quantity is the number fitted to one board. Identical parts are grouped; the
26 rows below cover every populated reference in the native hand-board BOM.
The relay's manufacturer ordering number 1-1462037-3 corresponds to IM02TS.

<!-- cspell:disable -->

| References | Exact ordering number | Qty | Unit USD | Extended USD | Checked 2026 | Price source |
| --- | --- | ---: | ---: | ---: | --- | --- |
| Q3, Q4 | SUP70101EL-GE3 | 2 | $4.70 | $9.40 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/vishay-siliconix/SUP70101EL-GE3/7622840) |
| K101, K201 | 1-1462037-3 | 2 | $5.10 | $10.20 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/te-connectivity-potter-brumfield-relays/IM02TS/1633979) |
| F101, F201 | 0251004.MXL | 2 | $1.24 | $2.48 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/0251004-MXL/700745) |
| F102, F202 | 0251.750MXL | 2 | $1.37 | $2.74 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/0251-750MXL/776753) |
| J1, J103, J203 | B2P-VH(LF)(SN) | 3 | $0.16 | $0.48 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B2P-VH/926547) |
| J101, J102, J201, J202 | B4B-XH-A(LF)(SN) | 4 | $0.17 | $0.68 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B4B-XH-A/1651047) |
| J2 | B2B-XH-A(LF)(SN) | 1 | $0.10 | $0.10 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B2B-XH-A/1651045) |
| C1, C5, C101, C201 | MKS2C031001A00KSSD | 4 | $0.64 | $2.56 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/wima/MKS2C031001A00KSSD/19251365) |
| C2 | EEU-FR1A221 | 1 | $0.48 | $0.48 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/panasonic-industry/EEU-FR1A221/2433509) |
| C3, C4 | ECE-A1EN100U | 2 | $0.45 | $0.90 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/panasonic-electronic-components/ECE-A1EN100U/227617) |
| C102, C202 | EEU-FR1A151 | 2 | $0.39 | $0.78 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/panasonic-industry/EEU-FR1A151/2433508) |
| U1 | LMC7660IN/NOPB | 1 | $3.13 | $3.13 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/texas-instruments/LMC7660IN-NOPB/32523) |
| U2 | TLP627M(E | 1 | $1.00 | $1.00 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/toshiba-semiconductor-and-storage/TLP627M-E/10492648) |
| Q1 | 2N3904BU | 1 | $0.29 | $0.29 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/onsemi/2N3904BU/1413) |
| Q2 | 2N3906BU | 1 | $0.27 | $0.27 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/onsemi/2N3906BU/1414) |
| Q101, Q102, Q201, Q202 | TN0702N3-G | 4 | $1.52 | $6.08 | 26 Sep | [DigiKey](https://www.digikey.com/en/products/detail/microchip-technology/TN0702N3-G/4902376) |
| D101, D201 | 1N4007-E3/54 | 2 | $0.56 | $1.12 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/vishay-general-semiconductor-diodes-division/1N4007-E3-54/754813) |
| D2 | BAT85S-TAP | 1 | $0.50 | $0.50 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/vishay-general-semiconductor-diodes-division/BAT85S-TAP/3104127) |
| R1 | MFR-25FBF52-1K | 1 | $0.10 | $0.10 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-1K/13011) |
| R6, R7, R102, R202 | MFR-25FBF52-100K | 4 | $0.10 | $0.40 | 26 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-100K/13473) |
| R2, R3 | MFR-25FBF52-4K7 | 2 | $0.11 | $0.22 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-4K7/9138176) |
| R4 | MFR-25FBF52-22K | 1 | $0.10 | $0.10 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-22K/9138098) |
| R5 | MFR-25FBF52-5K6 | 1 | $0.10 | $0.10 | 22 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-5K6/9138195) |
| R8 | PR01000101000FA100 | 1 | $0.45 | $0.45 | 22 Sep | [Mouser](https://www.mouser.com/ProductDetail/Vishay-BC-Components/PR01000101000FA100?qs=17u8i%2FzlE8%252B%252BSN%2FNRC7Xyg%3D%3D) |
| R9 | MFR-25FBF52-2K4 | 1 | $0.10 | $0.10 | 25 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-2K4/9138109) |
| R10, R101, R201 | MFR-25FBF52-10K | 3 | $0.10 | $0.30 | 26 Sep | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-10K/13219) |
| **Total** | **26 unique parts** | **50** | | **$44.96** | | |

<!-- cspell:enable -->

The prices use the quantity-one tier even where the board fits two or more
parts; there are no bulk discounts assumed.

## Cost by function

| Group | USD |
| --- | ---: |
| Power MOSFETs | $9.40 |
| USB data relays | $10.20 |
| Fuses | $5.22 |
| PCB connectors | $1.26 |
| Capacitors | $4.72 |
| Charge pump and optocoupler | $4.13 |
| Small transistors and diodes | $8.26 |
| Resistors | $1.77 |
| **Total** | **$44.96** |

## Availability

On 25 September, DigiKey still listed SUP70101EL-GE3 at $4.70 with zero
immediate stock. The exact
[Mouser part listing](https://eu.mouser.com/fr/ProductDetail/Vishay-Semiconductors/SUP70101EL-GE3?qs=5aG0NVq1C4z46KzHS%252BM%252Bgg%3D%3D)
returned 28,389 available in the search snapshot, crawled the previous month;
a fresh page fetch was blocked. Mouser is a supplier lead for the same part,
not a verified live stock reservation. The table retains DigiKey's USD price
as the allowance rather than converting an older regional quote. No alternate
MOSFET is selected.

The refreshed DigiKey listings showed stock for every added or substituted
part: U1 1,748; U2 29; C3/C4 5,092; the WIMA bypass 8,445; D2 63,266;
TN0702N3-G 4,428; and each new resistor value more than 1,600. Counts are
page snapshots and can change before purchase.

Panasonic's [ECEA1EN100U product page](https://industrial.panasonic.com/jp/eol/pt/aluminum-cap-lead/models/ECEA1EN100U)
marks the C3/C4 bipolar capacitor discontinued, while DigiKey still labels it
active. This small hand-assembled batch uses available distributor stock;
future availability is not assured. Keep the exact bipolar part, or verify a
replacement's electrical ratings and body/lead dimensions before buying it.

The IM02TS relay estimate retains the 22 September 2026 snapshot: DigiKey
listed 2,000 in stock at $5.10 each. That listing and the other table rows
marked 22 Sep were not refreshed for Revision L.

## Required AUX input protection

These two external harness parts are required in addition to the 50 PCB
components. **Single-unit USD prices checked 25 September 2026**; both were
listed in stock. The existing buck is reused.

| Item | Exact ordering number | Qty | Unit / total USD | Price source |
| --- | --- | ---: | ---: | --- |
| Screen input fuse | Littelfuse 028707.5PXCN | 1 | $0.44 | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/028707-5PXCN/2519829) |
| Covered inline holder | Littelfuse FHAC0001ZXJ | 1 | $7.37 | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-commercial-vehicle-products/FHAC0001ZXJ/2004062) |
| **Required input protection** | | **2** | **$7.81** | |

The [wiring instructions](README.md#required-aux-branch-protection) locate this
fuse near the AUX buck on the dedicated screen branch. Its holder includes
the leads; the wire allowance below covers the remaining harness material.

## External wiring and mounting allowance

These are **planning allowances, not supplier quotes**. Together with the
priced input-protection parts above, they cover the external wiring BOM while
the final power-lead termination and enclosure mounting lengths remain
unselected. Do not add a second set of XH4 housings to the ready-made data
cables: their housings are already included.

| Item | Quantity | Estimated total USD |
| --- | ---: | ---: |
| VHR-2N power housings and SVH-41T-P1.1 contacts | 3 housings + 6 contacts | $2–4 |
| XHP-2 control housings and SXH-001T-P0.6 contacts | 2 housings + 4 contacts | $1–2 |
| Short 16 AWG AUX and 22 AWG control wire, sleeving | 2 harnesses; connectors above | $2–4 |
| Selected ready-made USB-A to XH4 data leads | 2 | $6–12 |
| Selected ready-made USB-C and Micro-USB to XH4 data leads | 1 each | $6–12 |
| Main-power lead material / adaptation of existing working leads | 2 | $4–10 |
| M3 screws, nuts and standoffs | 4 mounting points | $2–4 |
| Existing HDMI cables | 2 reused | $0 additional |
| **External wiring and mounting allowance** | | **$23–48** |

That gives **$75.76–100.76 for fitted electronic parts, required input
protection, wiring and mounting**, before the bare PCB, shipping and taxes.
An order with spare electronic parts is closer to **$76–106**.
PCB fabrication is not quoted here: it needs the selected two-layer stackup,
copper weights and order quantity. Existing Pi, screens, buck converter and
HDMI cables are reused and excluded from the new-build component subtotal.

The selected 28 AWG data cables remain for touch only. Keep full screen power
on suitably sized separate leads. Cable pin mapping, fit, USB-C plug
configuration and signal performance still require sample qualification.

If the selected leads prove unsuitable, the optional shielded donor pair in
[the cable assessment](../../../docs/reviews/screen-power-usb-revision-1072/cable-assessment.md)
costs $30.45 before shipping/taxes (26 September snapshot). This replaces the
$12–24 ready-made data-cable allowance; do not add both. Reusing suitable
existing cables avoids that donor purchase. Donor entries have zero default
quantity in the external BOM.
