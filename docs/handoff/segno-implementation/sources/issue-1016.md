# #1016 Slice 3: inputs, outputs, Mixer and FX [open]

Third slice of epic #1009 (implementation-map.md item 3), built on slice 2 (#1012, PRs #1013, #1014, #1015).

Accepted contract: docs/handoff/segno-app/accepted-behavior.md (inputs, outputs, Mixer, FX), docs/design/2026-09-07-audio-routing-ux.md, docs/design/2026-09-07-output-setup-ux.md, docs/design/2026-09-07-mixer-performance-ux.md, docs/design/2026-09-06-fx-ux-design.md, docs/design/2026-09-06-fx-simplicity-review.md, docs/design/2026-09-08-fx-parity-correction.md, docs/design/2026-09-09-fx-reference-completion.md, docs/design/2026-09-08-looper-x-mixer-analysis.md.

Scope from the map: build the typed source/bus/parameter identities later assignments need; extend routing capacity, naming fallbacks, stereo/mono/pan, trim and live-only monitoring; replace the Signal-era surfaces with the accepted rack and single-FX editing, shared descriptor controls and output destinations. Accept: 18 inputs remain selectable, Mixer live-input gain does not change captured audio, Solo, mute and gain stay distinct, reorder preserves assignments, Pre is printed once, and downstream tails follow the accepted Stop/Mute/Bypass/Cut contract. Sample comparisons and impulse tests, not screenshots alone; interface ports and clipping on hardware. No invented Looper X descriptors.

## Parts (each its own PR, in order)

- [x] 3a. The mix model (PR #1017, stacked on #1015) (engine + repository + settings + session): per-lane pan with a unity-centre balance law, per-track Solo beside mute, per-input software trim on the capture branch only, per-input pan/balance on the monitor branch seeded onto the lane at record, stereo input pairs as two lanes with a shared balance, monitoring for every hardware input (the 8-input ceiling goes), and the meters the Mixer needs (per-track post-fader stereo peaks, per-input, per-monitor and per-output-channel peaks); typed mix targets (track level/pan, input level/pan, output level/balance) with canonical identities for slice 4.
- [x] 3b. Output destinations (PR #1018, stacked on #1017) (engine + repository): output buses over stereo pairs with level, mute, Stereo/Mono and balance, a true post-sum output chain per bus (the master insert becomes bus 0's chain), independent output selection per source (live inputs, tracks, backing, click), the Stop/Mute/Bypass/Cut tail contract with the Cut operation, and the performance capture tap choice made explicit.
- [x] 3c. Audio routing and Output setup surfaces (PR #1020, stacked on #1018) (app): Recording inputs, input names and pairs, Mono pan & trim, Stereo balance & trim, Hear live, clipping and locks, Live/Track output routing, Backing & click, Main/Monitor output setup and output names; the Signal-era Audio and Tracks routing surfaces and the interim click card retire.
- [x] 3d. Mixer (app, PR #1021, stacked on #1020): the third main view with four channel strips per bank (Mute, multi Solo and clear Solo, FX edit and FX bypass, pan, stereo peaks and clipping, level with the gain marker over the meter, double-tap resets, Reset mixer, Backing & click), the foot Mixer (Tracks / Inputs, one channel, 5% steps, holds), and the Track/Wave/Mixer view menu.
- [x] 3e. FX placement and printing (PR #1022, stacked on #1021) (engine + repository): Pre/Post placement per instance (inputs default Pre, recorded destinations Post, outputs and All tracks fixed), Pre printed once from the dry originals at an audio-safe boundary, the All tracks recorded-mix chain, rack channel handling (input Stereo/L/R/Mono sum, output Stereo+Balance or Mono+Pan, rack level), and stable instance identities that survive rename, reorder and placement.
- [x] 3f. FX surfaces (PR #1024, stacked on #1022) (app): the destinations (Live inputs, Recorded tracks with parts and All tracks, Outputs), the rack chain editor with connected pedals, the single-effect editor, the shared descriptor controls for built-ins and plugins, Add effects, rack options, presets and the library, the Pre/Post switch; the Signal tray domain retires.

## Gates

Native suites (plus ASan and telemetry-off variants), ffigen regen and format after API edits, package and root tests at the CI coverage floors, dart analyze in each touched package, bloc lint, cspell; sample-level and impulse tests for the sound contract; /code-review clean and CI green before ready-to-merge. Hardware ports and clipping proof is out of reach here and stays listed as not verified.


---
## comment 2026-09-10T05:25:00Z

## Part 3d splits, and its foot half has a prerequisite

The **Mixer view** is built and pushed on the slice-3c branch ([PR #1020](https://github.com/tomassasovsky/segno/pull/1020)): the stage's third view, four channel strips per bank, dispatching only the owners slice 3a built.

The **foot Mixer** is not a remainder of that work. Surveying the pedal surfaces found:

- **No pedal performance mode exists in this product at all.** Transpose, Reverse, Fade, Speed, Multiply and Bounce are pen sections with no code behind them. What exists is one three-member interaction mode: record, mute, FX.
- **The accepted Mixer design enters the Mixer from a custom pedal assignment** — "Custom pedal assigned Mixer: press enters Mixer, hold runs its separately configured action". That is the custom binding vocabulary of #763, not a mode of its own.
- **The wire has exactly one free mode value**, and #763's approved direction spends it on `custom`: version 0x04, unreserve mode 3, custom joins the MODE cycle and is boot-excluded. A separate Mixer mode would need a fifth value and a second protocol version, against a direction the owner already approved on 2026-08-26.

So the foot Mixer is a Mixer **action** in #763's vocabulary, and it waits on #763 being implemented. That issue is `stage:plan` with its direction approved and no implementation yet; it sits outside this epic.

Part 3d is therefore complete as far as this slice can take it. I am continuing with 3e.


---
## comment 2026-09-10T07:32:39Z

Part 3e is built and open as https://github.com/tomassasovsky/segno/pull/1022. One thing in its scope line I could not deliver as written, and it needs a product answer before 3f draws the control.

**A whole track's Pre/Post switch.**

The accepted design gives a Pre/Post switch to "a recorded input part or whole track" (`2026-09-06-fx-ux-design.md:654`). A recorded part is a lane, and a lane owns a dry recording, so its Pre entries print from that original exactly as the design describes. A whole track's chain is a different thing: it processes the SUM of the track's parts, computed live from lanes that each own their own recording. There is no dry original at that stage to print from.

Two ways to give it one, both real changes:

1. **Fan the whole-track Pre run out onto the parts.** Each part's print then carries the lane's own Pre entries followed by the track's, and the track's live chain skips its Pre prefix exactly when every active part is printed with it. Faithful for a track with one recorded input, which is most of them. For a multi-part track it is NOT the same DSP as processing the sum, and one instance would exist as N engine slots, which needs an identity answer for bindings.
2. **Treat it as a bounce.** Printing a track's sum produces a single-part take, which is what Bounce already is — and the design keeps Bounce as its own journey with its own render recipe.

Rather than store a placement the engine cannot honour, part 3e forces a whole-track chain wholly Post at the repository write boundary, with the reason stated in code, and its surface omits the control the way Outputs and All tracks do. Live inputs and recorded parts have the switch and it works end to end.

Everything else in 3e's scope line landed: placement per instance with identity preserved across rename, reorder and placement; Pre printed once from the dry originals and swapped at the lane's loop boundary; the All tracks recorded-mix chain, one config with one instance per destination; and channel handling and level per instance on every chain owner.

I am continuing with 3f, which will draw the destinations, the rack chain editor and the Pre/Post switch over what 3e built. The whole-track switch stays out of 3f's scope until this is answered.


---
## comment 2026-09-10T21:47:28Z

The whole-track Pre/Post switch is built, on the same branch as part 3e (https://github.com/tomassasovsky/segno/pull/1022). The forced-Post restriction is gone.

**What it is.** A track's Pre run is a rendered copy of its combined material: every part's own printed material at its level, mute and pan, summed, then the track's Pre run, swapped in at the track's loop top without touching the transport. The combination is processed as one signal. The parts' prints are the render's input rather than something it re-renders, so the job costs one stereo buffer and a part that has already settled is simply read.

**One condition, and it carries the whole design.** It renders only while every part's chain is wholly Pre. A part carrying a Post entry keeps the track's Pre run live, with the reason reported. Nothing is disabled and nothing sounds different — the live path computes the same function the render materializes.

That condition is what keeps a part's Post tail draining past a Stop, which the design you approved requires. My first boundary put the parts' whole chains inside the render, which would have made a part's Post tail into captured material. An adversarial review of that design confirmed twenty-six objections; the decisive one is that flipping a switch in the Whole track editor would change what a part's own editor promises, on the default configuration, since a new instance on a recorded destination is Post. Rendering a tail region to play at the Stop edge does not rescue it: the tail a Stop needs depends on where the player stopped, and one stored region encodes one position.

**Your verification list**, each a native test:

- Combined-signal processing with a nonlinear effect. Two parts at 0.5 through a unity drive on the track give tanh(1.0). A per-part fan-out would give twice tanh(0.5). The test asserts the first and checks the two are far apart, and it runs live and printed and requires them to agree.
- Edits from originals. A Pre parameter moved twice lands exactly where a fresh engine with the final value lands, which compounding could not produce.
- Source and layer recovery. An overdub under an engaged render drops it, the new material plays, and Undo returns the take and lets the render describe it again. Nothing is written back into any recording.
- Assignment identity. A whole-track instance moves to the end of its new stage keeping its slot id, and the move is made by identity rather than index.
- Failure retention. A part with a Post entry, a hosted plugin, a budget that does not fit and a repeated render failure each keep the track live and say so.
- Boundary swaps. The render engages at the track's read position zero, and the test fails unless it actually engaged.
- Stop and tails. The track's Pre run stops with the recording, its Post run drains, and a part's Post tail is untouched.

Four mutations each fail exactly the test that names them. One test was rewritten after a mutation survived it.

**A defect in shipped code, fixed on the way.** The idle-track lane skip left a stopped track out of the lane loop when none of its parts carried a chain. The track's own chain kept running but the routing mask is built inside that loop, so a Track-stage Post reverb drained into nothing. Stop drained Post tails for a track whose parts had effects and silently did not for a track with all its effects on the track itself.

**Not verified.** Playback transforms. Speed, Reverse, pitch preservation and Follow tempo do not exist in this engine. The accepted direction for Speed is to stream from originals inline, which composes with a render from originals since both read the same recordings, but nothing tests that until Speed exists.

The boundary is recorded in `docs/design/2026-09-10-whole-track-pre-render.md` and the results in the implementation ledger. The Pre/Post control itself is unchanged and lands with the FX surfaces in part 3f.


---
## comment 2026-09-11T03:45:13Z

## Slice 3f progress, and two decisions taken

Three parts are pushed on `claude/segno-slice3f-fx-surfaces` ([PR #1024](https://github.com/tomassasovsky/segno/pull/1024), stacked on #1022).

**Part 1, the destination model.** `FxStage` is `input / loop / track / allTracks / output`; the `master` stage is gone, since slice 3b had already made an output chain per destination. The repository, the settings keys, the session manifest (schema v9) and the performance arm snapshot all hold one chain per destination now. All tracks became an addressable binding target, which it had never been.

**Part 2, the Effects destinations surface.** The pen's `01 Effects · destinations`: one page for every destination, the Sound type row picking the strip, and the chain underneath drawn as the pen's horizontal strip — a card per effect, a plain line between consecutive cards, and a break with no line where the Pre run hands over to the Post run. Live inputs carry Hear live; recorded tracks carry the part picker with All tracks beside the last track; outputs carry neither, because their stage is fixed.

**Part 3, the chain ceiling.** Raised from 8 to 64.

### The two decisions

I asked about them because both changed what the remaining surfaces could be, and both are settled:

1. **The Looper X factory catalogue ships.** The 159 preset files and 66 artwork images get committed and used as the design draws them.
2. **The engine ceiling goes up first.** Done, in part 3.

### What raising the ceiling actually cost

The cap was never a CPU limit: the audio path iterates the active count, and an unused slot allocates no DSP state. Two things scaled with it, and only one mattered.

| Ceiling | Callback stack frame | Engine struct |
| --- | --- | --- |
| 8 (before) | 32,048 B | 1.27 MB |
| 64 (naive) | 194,672 B | 4.73 MB |
| 64 (shipped) | 7,200 B | 4.92 MB |

The per-buffer FX snapshot arrays were locals of the audio callback. At 64 slots they would have put 195 KB in one frame of the one budget in this engine that is neither ours to set nor reported by the host. They now live in the engine struct as `le_fx_snapshot`, which took the frame from 32 KB to 7.2 KB and left it there — it barely moves with the ceiling now, and the cost is an allocation whose size is known.

The per-buffer sweep that parks an unprocessed slot's enable ramp also walked every slot of every chain. It now skips a slot already parked at bypass, which is where almost every slot past a chain's count sits.

Verified: the native suite in all five variants plus AddressSanitizer, telemetry-disabled and the C++ header shim; a new test that fills a chain to the ceiling and asserts tanh applied that many times over, mutation-checked against leaving the old clamp in place; root 2278 Dart tests, `looper_repository` 501, `segno_engine` 283.

### What is left in 3f

The rack chain editor with its connected pedals, the single-effect editor, the shared descriptor controls, the channel-handling footer and the Pre/Post switch itself, then Add effects, rack options, presets and the library over the committed catalogue. The Signal tray domain retires with the last of them.

---
## comment 2026-09-11T03:54:42Z

## The catalogue is in, and the module model is the next real problem

`packages/fx_catalogue` is committed: nine families, 159 presets, 66 images, a loader, eleven tests against the real files at 100% coverage, and its own CI job.

Reading the data end to end surfaced the thing that has to be decided before Add effects can instantiate anything, so recording it here while it is fresh.

**A preset does not say what modules it holds.** It is a flat map of parameter names to normalized values. The modules are implied, and the implication is not derivable:

- The enable key and the parameter prefix are usually DIFFERENT words. `Compressor` enables `Comp *`, `Delay` enables `Del *`, `Reverb` enables `Rev *`, `OvDrive` enables `OD *`, `Oct` enables `Octave *`.
- Splitting parameter names at the first space yields 59 distinct prefixes across the catalogue, and many are not modules at all: `High`, `Low` and `Mid` are the four-band EQ's own bands, and `Mode`, `Attack`, `Speed`, `Tracking` and `Tightness` are parameters.
- The stomp artwork names a third vocabulary again: `Compressor2`, `Delay3`, `Reverb5`, `Overdrive2`, `Octaver3`, `Chorus3`.

So the module identities need an explicit table, and the accepted design already says the grouping in the study was a design proposal rather than a recovered signal chain. I will write that table by hand from the three vocabularies, and mark what cannot be resolved as an evidence gap rather than inventing a schema for it.

**Separately, most of these modules have no DSP here.** The engine builds seven effects; the catalogue names Pumper, Slicer, SmartTune, Doubler, Whammy, Vinyl, Degrade, Cab, Harmonize and more. The accepted design already anticipates this: per-effect readiness states and truthful partial support, and no silent substitution of another effect called exact parity. So a rack will carry every module and its parameters, run the ones this engine can build, and say plainly which do not process yet.

Neither needs a decision from you — they follow from the design you have already accepted. Flagging them because they set what Add effects can honestly offer on the first pass.
