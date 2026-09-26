# Processing behavior comparison

September 8, 2026. Authorized prototype work for contracts 6 and 7 in the
[shared behavior proposal](2026-09-08-shared-behavior-proposal.md). This does not
approve the remaining sound or recording-product choices. The accepted FX editor
and production processing remain unchanged.

[Open the silent comparison](processing-behavior-preview.html). Stop and tails
uses simple source rows and existing action names. Bounce and capture compares
selected recorded sources with the continuous Main performance. No additional
settings page or routing diagram is proposed for the accepted application.

## Settled behavior and proposed distinctions

| Action | New recorded feed | Track Post | Shared output |
| --- | --- | --- | --- |
| Stop — accepted | Stops, including captured Pre | Existing tail drains | Receives other routed sources and drains its own tail |
| Clear — proposed | Stops; recorded content removed | Existing tail drains | Same downstream behavior as Stop |
| Mute — proposed | Player continues internally | Entire track is gated after Post | No new contribution from this track; already mixed tail can drain |
| Effect bypass — proposed | Dry signal passes | No new wet feed to the bypassed instance; its existing tail drains | Other processing continues |
| All-sound cut — proposed | Stops recorded and auxiliary playback | Current buffers cleared | Current buffers cleared |

Mute is a gate, not a processor flush. Unmute can reveal the still-running track
and its internal Post state. All-sound cut preserves monitoring preferences;
later live input is new sound and may feed effects again. These details are
explicit proposals for review, not inferred owner decisions.

Live input has a separate Pre/Post chain and Mixer level. Recording trim belongs
only to capture. A captured part copies independent Pre/Post recipes and retains
its original dry source: subsequent live-input changes affect live sound and
future takes. Recorded Pre bypass/edits require a prepared replacement from the
original sources; this model rejects a live bypass of that printed stage.

Track Mono proposes the average of left and right before whole-track Pre/Post,
after recorded-part processing. A subsequent stereo effect can widen that input.
The scalar arithmetic test illustrates the placement and cancellation rule; it
does not validate a production audio mix law.

## Recording products and open choices

Bounce and Save selected audio propose the same selected-track scope, including
individual processing and source levels regardless of current Play, Mute or
Solo. Shared All tracks/output processing, live inputs, backing and click are
excluded. Shared processing applies once when the neutral destination later
plays. Excluding shared All tracks FX is made explicit here for review. The
destination clears prior FX and resets level, pan, Mono, pitch, reverse and fade,
so source processing is not applied twice.

Two- and three-bar sources propose a six-bar common cycle. Independent-time,
Once and fractional material require an explicit finite duration. Wrap and Cut
remain recipe choices, not implemented tail rendering. Continuous performance
capture instead follows elapsed recording time and includes every source routed
to Main, including live input, backing and click through Main output FX.

The capture tap is deliberately unresolved: the earlier
[Output setup proposal](2026-09-07-output-setup-ux.md) puts it before final level,
balance, format and mute; shared contract 7 recommends after them. The comparison
shows both when Main level changes from 100% to zero. The API requires an explicit
choice and has no default. USB export copies a finished file with its existing
duration and provenance; it does not render selected tracks again.

## Existing integration and gaps

The host's `bounceTrack()` supplies recorded sources, individual rack snapshots,
mix, pitch, reverse and fade. Bounce already stores a symbolic recipe and clears
destination processing. Its duration is a common cycle, while the current
`bounceAudioRecipe()` used by Save audio uses the longest selected track. Thus
two plus three bars currently disagree: six in Bounce, three in Save audio.
This proposal gives both selected products the common-cycle contract; no host
behavior was silently changed.

The accepted input capture recipes and audible Post/output tails still require
real processing. The host meters do not prove either. The model intentionally
does not implement the shared All tracks processor, external plugins, render
jobs, audio file writes, phase, tail wrap, clipping or sample-rate conversion.
It never claims PCM exists. Real audio must prove Stop without truncated Post,
muted tracks with mixed output tails, bypass continuity, explicit cut, output
FX over simultaneous routed sources, and replacement preparation without
double-processing or losing the prior working sound.

## Model and host interface

`processing-behavior-study.js` exports `SegnoProcessingBehavior` in a browser and
the same CommonJS API. All outputs are frozen copies. Tail durations are explicit
fixture `tailSteps`; a test step is neither a second nor a promised decay time.

- `create({tracks, inputs, auxiliary, outputs})` creates independent runtime
  state. Each source has `id` and `routes`; effect descriptors have globally
  unique `id`, explicit `tailSteps` and optional `bypassed`. Tracks have `playing`,
  `hasAudio`, `muted`, `mono`, `printedPre`, `pre`, `post` and `level`. Live inputs
  have `signal`, `monitoring`, `pre`, `post`, `level` and `recordingTrimDb`.
  Auxiliary sources have `playing`; outputs have `fx`, `level` and `muted`.
- `action(state, type, id, value)` changes the next observation's intent;
  `advance(state)` produces one source/tail observation without mutating the
  prior state. Ordinary action buttons combine the two. Cut clears the current
  frame and buffers immediately. Actions are `stop`, `play`, `clear`, `mute`,
  `bypass`, `input-signal`, `monitor` and `all-sound-cut`.
- `captureRecipe(input, takeId)` snapshots independent input recipes.
  `monoAverage(left, right)` provides the proposed symbolic channel average.
- `selectedRecipe(tracks, {kind, tails, durationBeats})` consumes selected
  descriptors with stable `id`, `beats`, `follow`, `once`, `capturing`, and their
  processing/level metadata. `kind` is `bounce` or `selected-export`.
  Host adapters should map `trackDurationBeats`, capture state, audio-tempo
  settings, and `bounceTrack` into these fields; effective rack state must be
  captured, not inferred only from a configured switch assignment.
- `performanceFrame(state, outputId, captureTap)` compares the explicit
  `before-final-controls` and `after-final-controls` choices.
  `exportFile(file)` returns a copy operation preserving the finished descriptor.

Review sequences: Stop guitar while voice continues; turn voice off and advance
until tails drain; reset and Mute; reset and Bypass; Cut all sound; compare the
two taps at zero Main level; compare the six-bar selected-source result. The
preview supports native buttons, Tab/Enter and arrow-key encoder simulation.

## Verification

`node docs/design/verify_processing_behavior.cjs` runs the pure behavior checks.
Set `SEGNO_PROCESSING_BROWSER=1` with the configured Playwright runtime to add
Chrome and Firefox preview checks. `SEGNO_PROCESSING_SCREENSHOTS=1` also saves
review images; ordinary reruns do not regenerate them. These are local symbolic
prototype checks, not production CI or audible validation.

Current result: 19 pure checks and both browser journeys pass, 21 total. Chrome
and Firefox verify button/encoder actions, tap comparison, tail policy and
containment at 1920 × 1080 and 1280 × 1024. The final Stop and capture-tap images
were visually inspected in both browsers. Evidence and source hashes are in
[`processing-behavior-previews/verification.json`](processing-behavior-previews/verification.json).

The final pass added separate live-signal and monitoring stop/resume cases plus
the browser Live voice toggle. An independent no-op mutation of those two model
actions fails the added cases. The symbolic proposal does not establish audible
tail quality or hardware performance.
