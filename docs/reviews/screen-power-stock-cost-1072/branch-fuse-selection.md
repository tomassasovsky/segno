<!-- cspell:words Schurter derating -->
# Bel fuse selection — 27 September 2026

Recommended candidate: two **0697H4000-02** 4 A main fuses and two **0697H0800-02** 800 mA touch fuses. Preserve 800 mA protection rather than unnecessarily increasing touch to 1 A. These are candidates for the revised board, not substitutes that fit the existing axial footprints.

| Property | 4 A main | 800 mA touch |
|---|---:|---:|
| Mouser SKU | 530-0697H4000-02 | 530-0697H0800-02 |
| Published DC rating | 72 V | 100 V |
| Typical cold resistance | 0.016 Ω | 0.130 Ω |
| Maximum drop at rated current | 80 mV | 150 mV |
| Nominal melting I²t, <10 ms | 81 A²s | 2.3 A²s |
| Nominal melting I²t, 10× rating | 92 A²s | 3.1 A²s |
| Maximum clearing at 2× rating | 60 s | 60 s |

Primary: [Bel 0697H, November 2025, pages 1–4](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf), also available as a [manufacturer-document mirror at Mouser](https://www.mouser.com/datasheet/3/191/1/ds_cp_0697h_series.pdf). Both ratings support 200 A interruption at 72 VDC. Do not copy Mouser's erroneous 100 VDC attribute onto the 4 A part.

The common rectangular radial body measures 8.35±0.30 ×4.00±0.30 ×7.8±0.3 mm. Pins have 5.08±0.10 mm pitch and diameter 0.6±0.1 mm. The -02 suffix supplies long leads on tape for trimming; -01 supplies 4.3±0.3 mm leads. Allow maximum body size and lead diameter in the footprint, courtyard, model, and hole selection. Tape spacing 12.7 mm is not PCB pin pitch. No exact 0697H footprint was found in the installed KiCad fuse library.

## Price and availability evidence

- **800 mA -02:** root verified the live US product page: **2,861 stock, $0.58 each, plus 30% tariff**. This is newer than the cached category counts. [Exact Mouser part](https://www.mouser.com/en/ProductDetail/Bel-Fuse/0697H0800-02?qs=GtFly9OVs8891kOm2CYGHw%3D%3D).
- **4 A -02:** final root batch quote pending. The freshly opened [4 A -01 page](https://www.mouser.com/en/ProductDetail/Bel-Fuse/0697H4000-01?qs=GtFly9OVs89pMeJrRpoVFA%3D%3D) linked -02 as in stock at **$0.46 each**; that alternate-packaging summary is not the final combined quote. [Exact -02 link supplied by that page](https://www.mouser.com/en/ProductDetail/Bel-Fuse/0697H4000-02?qs=GtFly9OVs8%2F1PnMQKLkfbA%3D%3D).
- Verified fallback **4 A -01:** $0.57 each, 958 immediately available, possible 30% tariff. Same electrical/body/pin specification, shorter leads.
- Verified unused **1 A -01:** $0.57 each, 3,816 immediately available, possible 30% tariff. No need to choose it merely to improve startup margin.

Expected four-fuse cost using the indicated -02 prices is $2.08 before tariffs, around $2.70 with 30% on all four. Use the final live quote, not this estimate, in procurement totals.

## Review boundary

The resistance figures are typical, and the I²t figures are nominal. Neither is a guaranteed minimum for bounding peak current or repeated pulse survival. The engineering review must apply pulse derating and independently check sustained faults in the 28 AWG touch harness: surviving startup does not prove that a long overload clears before the wire overheats. The 800 mA selection improves that concern relative to 1 A while retaining the requested nominal pulse tolerance. Final assembly fit, routing, fabrication export, and production approval remain separate checks.

Read-only research; no source, CAD, BOM, or cart changes.

## Final consolidated quote

The 28 September 2026 Mouser US quote verifies full requested quantities
Ships Now: 2 × 0697H4000-02 = $0.92 + $0.28 estimated tariff; 2 ×
0697H0800-02 = $1.16 + $0.35 tariff. The four branch fuses total **$2.71**.
F1 instead uses Schurter 0001.2513 ($0.91 + $0.26) in holder 0031.8201
($1.20 + $0.11), for **$2.48**. All five fuses and the one holder total
**$5.19**, including estimated tariffs. Do not buy the superseded Bel
0697H8000-02 input fuse.

[Combined quote](https://www.mouser.com/en/price-availability/Edit?bomId=8d557212-bfa8-4ecd-9a90-89cffde392b4).
This records available stock, not a reservation or approval of the pending
PCB revision.
