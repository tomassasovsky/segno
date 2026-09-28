<!-- cspell:words Schurter XIAO GPIO -->
# Independent documentation correction review

Reviewed 28 September 2026. Base: `44edd9483518768506533a3b6fe30e85d6d530c4`; target: the working-tree changes in exactly these three files:

| File | Reviewed SHA-256 |
| --- | --- |
| `hardware/MANUFACTURING.md` | `9dacd32e416a5d3d873f72e3f3a01214f8394694f6ab6a030e15322f9134c01e` |
| `hardware/segno_wiring.md` | `8117501d22a3b277b09fd95df3f1e07ebe515b9f74f9458ada20971abe3afd38` |
| `hardware/kicad/RING_ASSEMBLY.md` | `7df6cb52127c84b71e57e936288cf55edd3b3cae60cd032b5d84bf9729b5a53b` |

**Verdict: clean; no unresolved actionable finding in this documentation delta.**

Read every changed hunk and its surrounding assembly instructions. Compared the claims with the current Revision N board README, BOM and fuse/coil budget, the existing programming-power contract, and the current manufacturing archive selection. No external model verdict or fresh full-board review is claimed here.

- The manufacturing table now selects the Rev N ZIP and current BOM, identifies one onboard removable input cartridge/holder and four soldered branches, and retains the correct two-layer order settings. It no longer combines the withdrawn Rev M PCB with Rev N parts.
- The system diagram and harness table now put F1 between J1 and the protected circuitry, followed by K1 for the switched screen supply. The exact Schurter 0001.2513/0031.8201 selection matches the current BOM. The 15 cm one-way target and 16 AWG incoming pair match the board contract; the statement that F1 does not protect that pair or the J1-to-F1 copper is retained explicitly. Console/ring stay on separate AUX branches.
- The 4.75–5.25 V specification remains at J1 before the fuse/holder. It is correctly scoped as the coil-drive envelope rather than a screen-end voltage guarantee. The removed negative gate circuit is no longer offered as a 4.5 V operating justification. The 800 mA touch fuse is distinguished from the 500 mA normal lead allocation and is not described as an active limiter.
- Independently recomputed all revised totals using decimal arithmetic: screen input = 4.25 + 0.06 + 0.15 = **4.46 A**; contact = 4.25 + 0.06 = **4.31 A**; AUX = 4.25 + 0.06 + 0.15 + 2.40 + 0.498 + 0.120 + 0.140 + 0.200 = **7.818 A**. AUX power = **39.09 W**, total output power = **64.09 W**. At 90–85% assumed efficiency, input is **71.2111–75.4 W**, or **3.56056–3.77 A at 20 V**, matching the displayed rounding. Nominal 10 A headroom is 2.182 A. Replacing the 0.498 A pill indication allowance with 4.8 A unrestricted pill white yields **12.12 A**; it remains explicitly outside the shared supply budget. The separate bleeder is not double counted.
- Ring USB programming now has a consistent sequence in both documents: AUX off, disconnect J1, connect USB, keep the separately fed strip off, remove USB, reconnect J1, then restore AUX. Disconnecting J1 isolates the XIAO's AUX/ground/link connector, and leaving the strip off avoids a powered strip with its controller/buffer supply absent. No simultaneous live AUX/USB path is instructed. The existing console procedure still disconnects J3/J6/J24 before USB and removes USB before reconnecting them; normal in-place programming remains SWD.
- Existing runtime-not-deployed, first-assembly qualification and unfinished enclosure-mounting statements remain in place. The changes do not imply that buying bare boards completes those tasks.

All relative Markdown file targets in these three documents resolve locally. The scoped `git diff --check` passes. No implementation files were changed by this reviewer. The later manufacturing-review link now points directly to the current adversarial record and names the remaining review hold; that link-only addendum is verified in the updated hash above. Aggregate release metadata is covered separately by the final bug-focused publication review; private delivery hashes remain the publishing agent's check.
