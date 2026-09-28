<!-- cspell:words DeepSeek OpenCode MCP netclass IOVDD -->
# DeepSeek advisory closeout

27 September 2026. OpenCode used `opencode-go/deepseek-v4-flash` with high
reasoning and read-only supplied evidence. Tools, MCP connections, plugins and
sharing were disabled. No source files or persistent settings were changed.

**The bounded closeout is clean: all four claims were withdrawn after checking
the actual code, calculations and reproduced tests. No new concrete defect was
identified.** The initial 129,795-byte attachment was truncated by the CLI, so
this is not a complete full-board or full-source DeepSeek approval. The complete
independent source/native correction reviews remain the primary review evidence.

An initial argument-parsing error occurred before a model response. The corrected
invocation returned a substantive review; one same-session follow-up used a
12,618-byte packet containing the exact missing evidence. Both model invocations
completed successfully. Raw responses and run records were retained privately.
The model reviewed supplied reproductions; it did not run native tools itself.

## Verified dispositions

| Claim | Evidence and disposition |
| --- | --- |
| Ring clearance fault test corrupts later tests | Disproved by all 13 actual controls and a separate two-load experiment: changing board A's scalar clearance to 0.13 mm leaves newly loaded board B at 0.20 mm. Shared nested netclass objects do not imply a shared scalar. Withdrawn. |
| Ring return-via guard omits a newly required minimum | The new 0.8/0.4 mm minimum belongs to the console. Ring project changes only enforce 0.20 mm clearance; all 21 actual ring vias are 0.8/0.4 mm. No manufactured defect or correction regression. Withdrawn. |
| Faster encoder filters lack software bounce handling | Current runtime cancels reversed quarter-steps, resets invalid diagonal jumps and emits only complete cycles at idle. Existing tests exercise bounce on every edge, reversals and invalid jumps. The actual 10 nF filter has a conservative 0.123734 ms release bound. Withdrawn. |
| Ring-normal presence wiring leaves the ring node undefined | With 3.3 V, 36 kΩ pull-down and both resistors at +1%, ring contact voltage is 3.220 V and presence input is 2.845 V, above 2.0 V HIGH. The extra ring-sense pull-up helps; runtime skips ring/ADC processing while empty. Insertion opens the normal contact. Withdrawn. |

The follow-up also corrected the initial screen arithmetic: conservative base
current is 1.23147 mA, collector bound 3.15657 mA and forced beta 2.563. R2 draws
0.204 mA at 0.95 V. A 47 kΩ source is outside the declared at-least-50 kΩ
engineering envelope but does not itself establish failure of its 0.35 V bound.
No RP1 pull-resistance guarantee or guaranteed transistor cutoff is claimed.

No further circuit, routing or runtime changes were indicated by this advisory
closeout. Its limited coverage does not replace native DRC, fabrication checks,
the completed independent delta reviews or assembled qualification.
