# Engine numbering ledger (authoritative, kept by the main session)

On the trunk, commands run up to 83 (`LE_CMD_REVERSE`).

| Owner | Commands | Facts (perf log) | LE_ERR |
|---|---|---|---|
| Multiply/Divide (#1168) | 84 | 326 | — |
| Pitch/time Speed (#1179 P2a) | 85 | 327 | -10 TRANSFORMED |
| Pitch/time later parts (Transpose, Audio & tempo) | 86–87 | 328–331 | -11 |
| Backing player (#1200) | 88–95 | 340–343 (only if needed; backing is excluded from the log) | -12, -13 |
| Instruments (#1197) | 96–111 | 336–339 | -14, -15 |
| Render recipe / Bounce (#1202) | 112–115 | 332–335 | -16, -17 |
| Recording / recovery (#1198) | 116–119 | 344–347 | -18, -19 |

## Rules

- **Version-number bumps are assigned in landing order.** This covers the events.log version (8 = pitch/time P2a) and the Session schema (12 = Peel P2, 13 = Reverse P2). A branch that bumps a version takes the next free number when it merges into the trunk, and every Session bump adds its step to the #1196 migration chain.
- **Need more than your range?** Ask the main session. Never take numbers outside your range.

## History kinds (`LE_HIST_*`)

On the trunk: 0–3.

| Kind | Owner |
|---|---|
| 4 `LENGTH` | Multiply/Divide |
| 5 `BOUNCE` | Render/Bounce (#1202) |
| 6–7 | reserved; ask the main session |

## Extensions

- Pitch/time, for Audio & tempo follow and later parts: commands 120–123. (3a used 86–87.)
- MIDI clock (#1228): commands 124–131, facts 348–351, LE_ERR -20/-21.
- Foot surfaces (#1229): commands 132–135, facts 352–355.
- Library audition (#1178 p6a): commands 136–137 (moved from 96/97, which belong to instruments). Foot surfaces released 133-135; facts unchanged.
- Session schema assignment: 13 = Reverse P2 (landed); 14 = M/D P2; 15 = backing P5. Later bumps take the next free number at landing.
- Session schema: 16 = pitch/time 4b (Audio & tempo fields).
- Device pages (#1270): commands 140–143, facts 356–359.
