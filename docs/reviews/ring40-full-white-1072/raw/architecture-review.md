# Architecture review — 40-LED full-white power

Base: `f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`; target: final working-tree
implementation, including the new power-path helpers. Reviewed source and native
board hashes are recorded in [independent-artifact-parity.json](independent-artifact-parity.json).
This is the scoped follow-up to the earlier full hardware review, not a review
of unrelated application or firmware changes.

## Stack and applicable boundaries

The changed stack is Python/SKiDL/pcbnew KiCad generation and fabrication,
with shell entrypoints and a pure-Python clearance helper. Read the project
instructions, hardware dependency manifest, applicable workflows and complete
architecture role. Applied modularity, simplicity, established-dependency and
working-end-to-end rules to these CAD layers. Flutter presentation, Bloc and
repository boundaries are unaffected.

## Layer separation

Violations found: 0. Circuit generators own component/net contracts. Board-specific
power helpers own critical geometry, coordinate anchors and acceptance guards.
Placement/routing entrypoints install critical power before the remaining routes;
actual-board checks run before manufacturing export. The generic width helper
continues to measure geometry and only grows narrower segments, so it cannot
shrink a high-current branch to a lower-current net minimum.

## State and dependency direction

Violations found: 0. Helpers mutate an explicitly passed pcbnew board; they do not
hide a global loaded board. Fixed geometry is paired with anchor checks, so a
moved connector requires revisiting its supply route. The width helper remains
independent of pcbnew and retains self-tests runnable without KiCad. No circular
imports, new package layer or dependency were introduced.

The caller order is explicit: assign nets and place parts, install critical power,
route remaining connections, grow widths, fill zones/run DRC, check the actual
critical path, then export. Console ground-via keepouts reuse the required-path
definition. The two small board helpers remain separate because their topology
differs; no speculative generalized routing framework is added. Critical copper
is locked before DSN export, and failed checks stop fabrication output.

## Artifact boundary and verdict

Independent fresh native exports match every console and ring archive member
apart from creation timestamps: 12 console and 10 ring files. The unchanged
screen-power ZIP hash was confirmed. Source/native hashes and precise comparison
normalization are retained in the linked parity record.

No architectural findings. This completes the architecture role for the recorded
delta. It does not establish whole-PR CI status or replace assembly, voltage-drop
and thermal validation.
