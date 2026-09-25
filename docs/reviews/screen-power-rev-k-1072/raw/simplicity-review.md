# Simplicity review — Revision K

Reviewed 25 September 2026 against
`9a5798be6c4ea9b0aae2a88fe7168b6751cab441`, including the added front AUX and
rear switched-rail tapers and the explicit permitted-layer map. No implementation
edits were made by this review.

## Core purpose

Finish the visible power routing while retaining adequate continuous copper,
correct the assembly preview to represent the selected capacitor bodies, clear
the mated input connector, and make the wiring/current assumptions usable by
the person assembling the board. Retain the existing two-layer, hand-soldered
37-component circuit and corrected relay wiring.

## Assessment

No actionable unnecessary complexity found. The functional Python changes are
small and remain inside the existing generator/validator structure; the large
diff is principally regenerated KiCad fill/routing and replaced STEP assets.
No new dependency, electrical module, runtime configuration system, board
variant or compatibility path is introduced.

- `route_critical.py` uses one small taper helper for eight actual transitions.
  Its layer argument serves the real rear-layer MOSFET output approach.
  Duplicating the polygon construction at each transition would add maintenance
  work without making the layout easier to understand. The original track
  path remains underneath the taper, keeping electrical continuity explicit.
- The common-source bridge now uses a full-width center and bends, with short
  pin approaches. The C1 feed remains a direct route derived from C1's actual
  location. `film_x` removes a repeated coordinate expression and makes the
  local approach easier to read. No general-purpose routing framework was
  added for these fixed board features.
- `check.py` separates required ground pours from a three-net permitted-layer
  map for named power tapers. This is a bounded exception for the actual board,
  preserving the ground and two-layer rules. The added C1 minimum-width path
  uses the existing physical-connectivity check instead of introducing a
  second validation mechanism.
- `model_geometry.py` shares the simple electrolytic construction between two
  BOM parts; the film model follows the existing part-specific model pattern.
  Polarity marking is useful assembly information, and the stripe stays within
  the body envelope. The dimensions and limitations are documented rather
  than hidden behind a configurable component-model system.
- `pcb.py` assigns the three model types directly to their known references.
  This follows the fixed board's existing structure; a registry or new
  abstraction would not simplify six affected components. The three obsolete
  generic capacitor models are removed rather than retained as fallbacks.
- Layout, schematic and silkscreen changes are limited to the needed C1 move
  and Revision K identity. Component quantities, connector positions, board
  size, power-source architecture and firmware are not expanded by this work.

The wiring/acceptance documents serve different readers: the main wiring plan
defines assembly, the board README explains its circuit, and the review record
retains evidence and limits. I do not recommend removing review documents or
collapsing the assembly contract into a test log. This reviewer authored the
system-wiring/harness edits, so this observation is not an independent approval
of those documents; their independent correctness review belongs to the other
review roles.

## Source checkpoint

| Source | SHA-256 |
| --- | --- |
| `check.py` | `599d9e3b6668e7207996830d4cacf94c5033adaf4258755aa60445655d11ccbd` |
| `route_critical.py` | `ba47c9fb85ba2da6fdac42918545ae67f4dc92b825530ff4f74370a79542be71` |
| `model_geometry.py` | `74cd343174ae8d43507f396184a0d51d90ac2b3c9f56391bfbae815946b5722e` |
| `pcb.py` | `b2d6b95708c174377dd2217086f9642f8c7171e52bb326f95a3b3c28de1c8574` |

The final native board is
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.
The refreshed test-quality review records its independently passing checks;
manufacturing export correspondence is recorded separately. A simplicity review
does not establish assembly clearance or electrical qualification.

## Final assessment

Estimated useful line reduction: **0**. Complexity: **low** for the intended
change. No YAGNI or unnecessary-abstraction finding. Keep the implementation
as reviewed and complete final native-board/export verification.

Critical: 0. Important: 0. Suggestion: 0.
