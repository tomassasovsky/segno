<!-- cspell:words IRLZ Omron Schurter derating postfuse prefuse unfused -->
# Superseded soldered-input-fuse assessment

**Historical proposal only.** F1 now uses Schurter SPT 0001.2513 in OGN 0031.8201; the Bel input fuse, 80 mV input allowance and its resulting margins below are not current. Use [the holder/coil assessment](holder-coil-budget.md). The four Bel output fuses remain selected.

27 September 2026. Read-only proposal assessment; no CAD, code, cart or released delivery was changed.

## Decision

**Use Bel 0697H8000-02, 8 A, as F1 immediately after J1.** It is a practical replacement for the separate inline holder when the incoming lead is a short, insulated and secured 16 AWG pair. It gives adequate normal-load derating and supports the relay pickup model while retaining **4.75 V at J1** as the input reference. No new blocking electrical issue was found for this placement within the explicit operating envelope below.

F1 must precede the input reservoir/bypasses, power-contact feed and all coil/control feeds. Do not create an unfused AUX branch around it. Keep the J1-positive-to-F1 trace short and wide. Grounds remain continuous. The input cable and that short prefuse trace are upstream of F1 and are not protected by F1; see the protection boundary below.

## Exact evidence and current loading

[Bel primary November 2025 datasheet, manufacturer URL](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf) and [manufacturer document on Mouser](https://www.mouser.com/datasheet/3/191/1/ds_cp_0697h_series.pdf): 0697H8000 has a typical cold resistance of 7 mΩ, a maximum voltage drop of 80 mV at 8 A, nominal melting I²t of 273 A² s below 10 ms and 303 A² s at 10 × rated current. It is rated 72 VDC with 200 A interrupting capacity. These are published specifications at their stated conditions; nominal melting energy is not a guaranteed total clearing integral.

The November 2025 graph is indexed with the same downward curve as the visually inspected [February 2025 manufacturer PDF mirror](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7179/PdfFile_121978.pdf), page 3. The graph reads approximately 91–92% at 60 °C and 75% at 125 °C. Use **90% at 60 °C** as a conservative rounded graph reading. A further 75% continuous-loading design factor gives 8 × 0.90 × 0.75 = **5.40 A**, exceeding the rounded 4.40 A board allowance by 1.00 A. This 75% factor is an engineering loading margin, not a second guaranteed rating printed on the Bel graph. The corresponding 6.3 A choice gives 4.2525 A and is unnecessarily close.

The 4.40 A allowance comprises 4.25 A for the switched screen system including its bleeder, approximately 80.5 mA of worst-case cold USB-coil current, 46.7 mA of cold G6C current, a 2 mA TVS leakage allowance and modest control current. The resulting total of approximately 4.38 A is rounded upward. The 40-pixel ring uses a separate AUX branch and does not pass through F1.

## Keep 4.75 V at J1: 105 mV coil-feed budget

Define 4.75 V **across the J1 PCB input terminals**, before F1. Do not relabel the postfuse rail as J1. The mating input-connector and incoming-wire losses therefore belong upstream of this reference and must not be counted twice.

| J1 to G6C coil loss | Working allowance | Basis |
|---|---:|---|
| F1 | 80 mV | Published maximum drop at rated 8 A, conservatively carried as a working allowance at 4.4 A; ambient caveat below |
| Shared positive/ground copper and local coil feed/return | 20 mV | Explicit layout target, to be calculated from final routed geometry |
| IRLZ44N | 5 mV | Exceeds the doubled-hot resistance estimate: 50 mA × 70 mΩ = 3.5 mV |
| Total | 105 mV | Leaves 4.645 V at the coil |

The fuse's 80 mV rating is not an independent guarantee of its drop at 60 °C: the datasheet does not give a temperature-bounded maximum resistance curve. At 4.4 A, its typical cold drop is 30.8 mV and its dissipation is 0.1355 W. Thus 80 mV corresponds to 18.2 mΩ, approximately 2.6 times typical cold resistance, while operating at 55% of rated current. It is a defensible conservative working allowance, not a fabricated manufacturer hot-limit guarantee.

Keep the previous 100 °C winding sensitivity: 3.5 × [1 + 0.004 × (100 − 23)] = **4.578 V** pickup estimate. With 4.645 V available, margin is **67 mV**. At 90 °C winding, the 4.438 V pickup estimate leaves 207 mV of margin. For a stress case, increase the F1 drop to 120 mV while holding other losses at 25 mV: 4.605 V remains, 27 mV above the 100 °C estimate. An F1 drop of 147 mV exhausts that 100 °C margin. These are transparent engineering sensitivities; 100 °C winding is the prior 40 °C rise allowance over 60 °C local air, not a newly measured temperature.

Q2's conservative gate rail is at least 4.75 − 0.080 − 0.020 − 0.4 = **4.25 V**, above the IRLZ44N's 4 V Rds specification point and the USB TN0702's 3 V point. R7 remains 10 kΩ. Clamp voltage does not become worse: retain 5.25 V as the upper rail bound for TVS and drain stress.

The 20 mV copper target must be substantiated after routing, not asserted because the traces look wide. At 4.4 A it corresponds to 4.55 mΩ total if all the allowance were in shared high-current copper. For reference, 35 µm copper at 60 °C has approximately 0.570 mΩ per square, or about 8 squares before allocating return/pad/via resistance. Use the actual net paths, widths, lengths, layer sharing, finished copper and ground return. The local coil-only path carries under 50 mA; weigh it accordingly. Put F1 close to J1 and branch the coil feed close to the protected side of F1 so the long switched-load bus does not consume this allowance.

## Both USB coils remain within their hot-pickup model

Reuse the existing TE IM02TS model from the checked circuit assessment: minimum room-temperature coil resistance of 130.5 Ω, thermal resistance of 150 K/W, copper coefficient 0.00393/K, preheat from 5.25 V while ignoring driver loss, and 60 °C local air. This deliberately ignores F1's heating-supply drop while preheating, retaining the adverse initial winding temperature.

It gives a winding temperature of **85.44 °C**, a coil resistance of **162.52 Ω**, and a required pickup voltage of **4.2094 V**. With 80 mV across F1 plus 20 mV across copper, each USB stage receives 4.65 V. The two drivers, each estimated at 5 Ω when hot, leave **4.3805 V across the coil**, or **0.1711 V margin**. For initial pickup at 23 °C, 4.319 V is available versus the required 3.38 V. Therefore moving the input fuse onto the PCB reduces the previous margin but does not erase it. Update the validator to use fused AUX, not the unchanged 4.75 V supply value directly.

## Complete voltage accounting, without an invented screen-voltage guarantee

The following is an explicit conservative working budget at 4.25 A combined screen current. Branch allocations are considered individually, not added as simultaneous independent maxima. Primary contact references are [JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf), [JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf), and the selected [Omron G6C](https://components.omron.com/us-en/system/files/2026-03/datasheet_pdf/K018-E1.pdf). Cold cable estimates use the existing documented copper resistance model; a 1.157 factor models 60 °C rather than 20 °C copper.

| Segment | Main path at 3 A | Touch path at 0.5 A | Status |
|---|---:|---:|---|
| F1, shared positive/return feed | 100 mV | 100 mV | 80 mV across the fuse + 20 mV across copper working budget |
| G6C contact | 127.5 mV | 127.5 mV | 4.25 A × 30 mΩ initial maximum; not an aged/hot maximum |
| Shared switched-output bus | 20 mV | 20 mV | Additional layout target; does not belong in the coil-feed budget |
| Branch fuse | 80 mV | 150 mV | Conservative use of full-rated-current drop, not a guaranteed hot lower-load maximum |
| Branch PCB positive/return | 20 mV | 20 mV | Layout target to check on routed copper |
| Board-to-cable connector pair | 60 mV | 10 mV | Two 10 mΩ initial contacts; after-test 20 mΩ/contact doubles this row |
| Cable copper | 69.4 mV | 74.0 mV | 30 cm main 20 AWG pair / 30 cm touch 28 AWG pair at 60 °C; 25 cm touch is lower |
| Screen USB termination | Not characterized | Not characterized | Its exact contact resistance is not in the retained harness evidence |

These deliberately conservative rows sum to approximately **0.477 V main** and **0.502 V touch**, before the screen USB termination, leaving about 4.273 V and 4.248 V from the 4.75 V J1 corner. They must not be advertised as proof that every screen works at that corner. Actual drops are likely smaller because several rows carry full-current or initial maxima at lower actual branch load, but that is not a measured guarantee either. At a nominal 5.00 V at J1, add 0.25 V to those estimates. The existing documentation already distinguishes relay-pickup input requirements from an unqualified screen minimum operating voltage.

This is not a newly introduced voltage-deficiency finding caused by F1: 80 mV across F1 plus 127.5 mV across the contact totals 207.5 mV, slightly below the old pair's modeled 216.75 mV hot drop at 4.25 A, before the new branch fuses' lower typical resistance. The redesign therefore preserves or improves the prior conservative distribution model if the copper targets are met. Do not strengthen the old conditional screen-operating claims merely because relay pickup passes.

For the incoming short 16 AWG pair, a 15 cm one-way design target means 0.30 m loop; typical 13.2 mΩ/m gives 17.4 mV at 4.4 A before heating. The J1 VH pair contributes at most 88 mV initially or 176 mV at JST's after-test 20 mΩ/contact limit. A nominal 5 V buck can plausibly maintain the 4.75 V J1 floor with that short feed, but its fixed output tolerance, splices and actual connector condition remain part of the source budget. This is why 4.75 V stays specified at J1, not assumed from a 5 V label.

## Protection boundary and faults

An 8 A slow fuse is supplementary board/input protection, not an 8 A electronic current clamp or a promise to open promptly from a nominal 10 A buck. Bel specifies a maximum 60 s opening time at 2 × rated current; the actual buck's current limiting may prevent such current. The retained eleUniverse B0GGHN97TK supply advertises protection without a public threshold/response curve, and the upstream 20 V T5A fuse does not establish a particular 5 V clearing time.

F1 protects the board downstream of its protected terminal. It does **not** protect a positive-to-ground/chassis short in the incoming cable or J1-to-F1 trace. Keep that prefuse path short, 16 AWG, insulated, strain relieved and away from abrasion; the user can remove the inline holder without pretending its coverage is unchanged. No hidden pre-PCB test or new prototype build is required by this assessment.

Implementation gates remain: exact 0697H footprint/holes and all after-F1 net ownership; measured-from-geometry copper resistance budgets; updated USB and G6C hot-pickup calculations; circuit/fault checks, KiCad/ERC/DRC/fabrication checks and independent final review. No guarantee of upstream-wire protection or manufacturer-specified hot-fuse performance is claimed.
