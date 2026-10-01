# M2.6 native frozen-v1 independent review

Base a52fe34d42a719624762f7756518a7e54cf7fd0c; working native candidate frozen by root. Exact path hashes are in review-source-hashes.json. All651 build-manifest inputs matched before and after the probes/review. Pump SHA 31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8; header 5f2daab823a49d4224fc290024f68646dfbc5b7ead6bcc1061d5abec3eff083a. Full library d76e39a4f43755f550d966d07fb637778060d024e2c80767808cc2dc3240406c supplied by root; probes use pump.

## Independent behavior

Five previously prepared C sources copied byte-for-byte and recompiled against the frozen64-slot header, linked to the immutable pump; all exit0 with zero CHECK failures. No mechanical fixture correction and no numeric expectation change was required. Commands, logs and source hashes are in results.json.

- Original full arithmetic oracle: unequal-part nonlinear whole-track Pre, independent gain once, additive source/track pan, original PCM preservation; disabled-side tails and31/32 physical channel bounds; part-Post obstruction removal; arm cancellation and caller-memory recipe ownership. Passed.
- Original capture-boundary:64 versus16+48 frames, sample40 .1579 both; passed.
- Cached recipe capture-boundary: same partition, sample40 .18731 both; passed.
- Cached image-only domain neighbor: same partition, sample40 .176499 both; passed.
- Invalid compound channel refusal: -1, before/after .197375/.099668; passed.

Stock-library run uses plugin_fixture=0. It does not re-prove deterministic hosted-plugin obstruction or arbitrary installed plugins. Root's separate hosted lifecycle gate is distinct evidence. Original failing 3e artifacts remain preserved.

## Source review and test quality

Read the entire changed native/header/generated-binding/test diff and relevant recipe, snapshot, enable-ramp and command-ring callers. The64-slot expansion changes all recipe/output-snapshot generated arrays coherently; parameter width remains4. Recipe command77 still carries an owned prepared pointer, with control-side retained bundle allocation/retirement; the ring payload does not embed expanded recipes. No new callback heap allocation/free, locks or blocking I/O were introduced by this delta.

The relocated scratch is engine-owned, read/written only by its callback, filled for active tracks/lanes/inputs/output buses before corresponding uses. Aliases preserve dimensional strides and dirty-track refresh consumers. Both lane re-snapshot and whole-track enable restoration are retained at deferred capture boundaries, and the independent cached/image-only probes exercise them. Cross-block cached scratch is not used as an ownership source or retained by cache workers. The new settled-bypass shortcut checks exactly the five fields the skipped force-bypass would overwrite; it skips only an already-equivalent state, retaining non-settled ramp handling. No deleted behavioral guard was found without an equivalent surviving boundary.

Author tests were read after independent sources were fixed. Full64 drives use successive tanh to make all processed slots observable; the prepared-recipe test also checks final slot channels, exact last parameter storage, power and65 refusal retaining sound/revision. These expectations have an independent arithmetic basis, not only setter counters. They do not by themselves prove hosted plugins or callback stack bounds; those remain respective lifecycle/mechanical evidence.

## Verdict and limits

No actionable finding in this bounded frozen native/header/generated-binding delta. This is not a clean whole-M2.6 gate: domain/app remain moving and awaiting review as final source, root native configuration/sanitizer/export gates are separate, and current-head CI/commit binding are later gates. No broad suite or shared library was rebuilt. No source, Git or public report was edited.
