# Screen-power revision K component cost estimate

<!-- cspell:words DigiKey MOSFETs onsemi Littelfuse VHR SXH XHP SVH SUP -->

**USD, checked 22 September 2026.** The 37 populated through-hole components
cost **$33.66** using published single-unit distributor prices. Allow **$35–40
for board components**, including modest price movement and spare small parts.
This excludes the bare PCB, wiring, mounting hardware, assembly labor, tools,
shipping, taxes and import charges. It is an estimate, not a reserved basket.

Revision K uses the same 37 components and quantities as Revision J. The
prices below retain the dated September 22 snapshot; they were not refreshed
by the routing and model corrections.

The four mounting holes are PCB features, not four purchased components.
No USB-C modules or additional Pi ribbon are required.

## All populated PCB components

Quantity is the number fitted to one board. Identical parts are grouped; the
21 rows below cover every populated reference in the native hand-board BOM.
The relay's manufacturer ordering number 1-1462037-3 corresponds to IM02TS.

<!-- cspell:disable -->

| References | Exact ordering number | Qty | Unit USD | Extended USD | Price source |
| --- | --- | ---: | ---: | ---: | --- |
| Q3, Q4 | SUP70101EL-GE3 | 2 | $4.70 | $9.40 | [DigiKey](https://www.digikey.com/en/products/detail/vishay-siliconix/SUP70101EL-GE3/7622840) |
| K101, K201 | 1-1462037-3 | 2 | $5.10 | $10.20 | [DigiKey](https://www.digikey.com/en/products/detail/te-connectivity-potter-brumfield-relays/IM02TS/1633979) |
| F101, F201 | 0251004.MXL | 2 | $1.24 | $2.48 | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/0251004-MXL/700745) |
| F102, F202 | 0251.750MXL | 2 | $1.37 | $2.74 | [DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/0251-750MXL/776753) |
| J1, J103, J203 | B2P-VH(LF)(SN) | 3 | $0.16 | $0.48 | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B2P-VH/926547) |
| J101, J102, J201, J202 | B4B-XH-A(LF)(SN) | 4 | $0.17 | $0.68 | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B4B-XH-A/1651047) |
| J2 | B2B-XH-A(LF)(SN) | 1 | $0.10 | $0.10 | [DigiKey](https://www.digikey.com/en/products/detail/jst-sales-america-inc/B2B-XH-A/1651045) |
| C1, C101, C201 | MKS2C031001A00KSSD | 3 | $0.64 | $1.92 | [DigiKey](https://www.digikey.com/en/products/detail/wima/MKS2C031001A00KSSD/19251365) |
| C2 | EEU-FR1A221 | 1 | $0.48 | $0.48 | [DigiKey](https://www.digikey.com/en/products/detail/panasonic-industry/EEU-FR1A221/2433509) |
| C102, C202 | EEU-FR1A151 | 2 | $0.39 | $0.78 | [DigiKey](https://www.digikey.com/en/products/detail/panasonic-industry/EEU-FR1A151/2433508) |
| Q1 | 2N3904BU | 1 | $0.29 | $0.29 | [DigiKey](https://www.digikey.com/en/products/detail/onsemi/2N3904BU/1413) |
| Q2 | 2N3906BU | 1 | $0.27 | $0.27 | [DigiKey](https://www.digikey.com/en/products/detail/onsemi/2N3906BU/1414) |
| Q101, Q201 | 2N7000 | 2 | $0.65 | $1.30 | [DigiKey](https://www.digikey.com/en/products/detail/onsemi/2N7000/244278) |
| D101, D201 | 1N4007-E3/54 | 2 | $0.56 | $1.12 | [DigiKey](https://www.digikey.com/en/products/detail/vishay-general-semiconductor-diodes-division/1N4007-E3-54/754813) |
| D1 | 1N4148-TAP | 1 | $0.26 | $0.26 | [DigiKey](https://www.digikey.com/en/products/detail/vishay-general-semiconductor-diodes-division/1N4148-TAP/3104053) |
| R1 | MFR-25FBF52-1K | 1 | $0.10 | $0.10 | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-1K/13011) |
| R2, R6, R7 | MFR-25FBF52-100K | 3 | $0.10 | $0.30 | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-100K/13473) |
| R3 | MFR-25FBF52-4K7 | 1 | $0.11 | $0.11 | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-4K7/9138176) |
| R4 | MFR-25FBF52-330K | 1 | $0.10 | $0.10 | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-330K/9138135) |
| R5 | MFR-25FBF52-5K6 | 1 | $0.10 | $0.10 | [DigiKey](https://www.digikey.com/en/products/detail/yageo/MFR-25FBF52-5K6/9138195) |
| R8 | PR01000101000FA100 | 1 | $0.45 | $0.45 | [Mouser](https://www.mouser.com/ProductDetail/Vishay-BC-Components/PR01000101000FA100?qs=17u8i%2FzlE8%252B%252BSN%2FNRC7Xyg%3D%3D) |
| **Total** | **21 unique parts** | **37** | | **$33.66** | |

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
| Capacitors | $3.18 |
| Small transistors and diodes | $3.24 |
| Resistors | $1.16 |
| **Total** | **$33.66** |

## Availability

DigiKey listed SUP70101EL-GE3 at $4.70 but had no immediate stock at this
check, with 50 expected on 6 November 2026. Its $9.40 line is therefore a
budget allowance at the published price, not a currently available purchase.
Confirm supply before placing a board order. An alternative needs its
electrical characteristics, pinout and footprint checked before substitution.

The IM02TS relay update adds $1.24 per board for greater pickup margin.
DigiKey listed 2,000 in stock at $5.10 each on 22 September 2026. The other
line items retain the earlier same-day price snapshot; they were not refreshed
by this relay change.

## External wiring and mounting allowance

These are **planning allowances, not supplier quotes**. They cover all rows
of the external wiring BOM while the final power-lead termination and enclosure
mounting lengths remain unselected. Do not add a second set of XH4 housings
to the ready-made data cables: their housings are already included.

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

That gives **about $57–82 for fitted electronic parts, wiring and mounting**,
before the bare PCB, any upstream protection not already present, shipping
and taxes. An order with spare electronic parts is closer to **$58–88**.
PCB fabrication is not quoted here: it needs the selected two-layer stackup,
copper weights and order quantity. Existing Pi, screens, buck converter and
HDMI cables are reused and excluded from the new-build component subtotal.

The selected 28 AWG data cables remain for touch only. Keep full screen power
on suitably sized separate leads. Cable pin mapping, fit, USB-C plug
configuration and signal performance still require sample qualification.
