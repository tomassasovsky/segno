# Pedal setup: bug review

Base: `da0c1f70d9815f68f9f5bb43e16f36de01a0b365`.
Incoming setup parent: `f93a4b6d7579bad91a3721a46de2c1b98712e260`.
The reviewed head is the publication commit containing the exact manifest in
[source.json](../../reviews/design-pedal-setup-restack/source.json).
The coordinator checks committed blobs before publication; later changes
invalidate that binding.

No unresolved actionable findings remain in this slice. The independent
source reviewer read the full intended diff and relevant callers, including
removed behavior, persisted identities, load/save ordering, hold admission,
target selection, fixed controls, navigation, focus and disposal. Five
quality roles were performed by that reviewer; a separate adversary froze
behavioral expectations and reproduced four defects with independent probes.
Neither reviewer authored the implementation.

All reproduced failures are repaired. Both final cases replay unchanged:
Arm overdub preserves a pending arm, and malformed saved Hold cannot become
an active default. The broader evidence preserves failed attempts and clearly
separates unchanged-check reuse from fresh final runs. See the
[validation report](../../reviews/design-pedal-setup-restack/README.md) and
its linked source and adversarial reports for scope and limitations.

The full application, Settings package, unchanged package evidence, coverage
floors, strict analysis, formatting and Bloc lint pass. Author screenshots
and the actual desktop journey are explicitly separate from CI. Custom
runtime, final Mode Hold default and physical-appliance checks remain later
work. Remote CI must pass on the published head before readiness; the human
merge gate remains in force.
