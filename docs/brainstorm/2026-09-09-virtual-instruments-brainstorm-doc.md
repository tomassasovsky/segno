---
date: 2026-09-09
topic: virtual-instruments
issue: 919
status: product requirement recorded; UX proposal
---

# Virtual instruments as input sources

## What We're Building

The owner requested virtual instruments played through controls or MIDI, with
their generated audio routable like a normal input. This adds an internal sound
source to Segno. It extends the previous effects-only plug-in scope. It does not
relax the separate requirement for matching Looper X racks, effects and parameters.

Proposed journey: **Inputs → Add instrument → choose sound → choose controller
and MIDI channel → route it**. The named instrument then appears alongside the
other audio sources for live monitoring, input effects, output routing and track
recording. The setup path is a proposal, not a new implemented screen.

## Why This Approach

Three placements were considered:

- **A named instrument input — recommended:** separate note triggering from the
  resulting audio. Reuse the accepted input routing and monitoring controls.
  One instrument can supply multiple recording destinations without occupying
  a recorded-track slot just to produce sound.
- **An instrument attached directly to each loop track:** useful if Segno later
  records editable MIDI clips, but it introduces a new track type and leaves
  shared live routing unclear for the owner's current request.
- **An instrument placed as an ordinary FX card:** resembles the current effect
  browser, but an instrument creates audio from notes rather than simply
  processing incoming audio. Its controller and record destinations would be
  harder to explain in that location.

The recommendation applies the established MIDI-to-instrument-to-audio pattern.
Ableton documents that instruments receive MIDI and produce audio for downstream
effects: [Working with Instruments and Effects](https://www.ableton.com/en/manual/working-with-instruments-and-effects/).
Segno's proposed input-source placement adapts that pattern to the appliance;
it is not a claim that Ableton uses this exact setup screen.

## Key Decisions

- **Owner requirement:** virtual instruments, triggerable through controls or
  MIDI, with audio routable like a normal input.
- **Owner follow-up:** custom computer keystrokes or incoming MIDI can trigger
  whichever instrument notes the player chooses. The HTML proposal now supports
  one or several destination notes per learned source, including notes outside
  the currently visible octave.
- **Owner requirement preserved:** Segno's racks, effects and their parameter
  lists must match Looper X; the resulting sound may differ.
- **Proposed setup:** name the instrument, choose its sound, bind a MIDI device
  and channel, and reuse input routes. Do not show physical-jack pairing,
  hardware gain or phantom-power controls for a software source.
- **Proposed performance:** a MIDI keyboard or pads play notes with velocity;
  configurable buttons can trigger a chosen note or drum sound. Expression and
  continuous MIDI controls can target exposed instrument parameters. Performing
  an assignment must not require opening a touch screen.
- **Proposed audio behavior:** instrument audio uses the existing Hear Live,
  Mixer, input-FX placement and track-recording rules. Turning down live
  monitoring must not change the recorded level. Output effects remain on the
  routed output. Do not introduce a second instrument-only routing system.
- **Proposed recording boundary:** the first journey records generated audio
  into ordinary loop tracks. MIDI clip recording/editing is a separate, open
  product decision, not silently included or permanently excluded.
- **Proposed persistence and recovery:** save sound, parameters, controller
  bindings and routes with the session. Preserve captured audio if an instrument
  or controller is unavailable. Release active notes on lost control connections
  or instrument removal; the existing Cut sound action must silence instruments.
- **Scope:** record and prototype this product direction before native hosting
  work. Production remains excluded from the current design pass.

## Existing Evidence and Boundaries

The [existing plug-in plan](../plan/2026-06-23-feat-vst3-clap-plugin-hosting-plan.md)
explicitly scopes audio effects and excludes instrument and MIDI-driven plug-ins.
The current `packages/midi_client/lib/src/midi_client_base.dart` supplies a native
MIDI capture wrapper; it is not proof of instrument event delivery or synthesis.
Neither the plan nor MIDI Learn alone establishes playable instrument support.
Implementation must verify event timing and note lifetimes in the audio engine.
No new instrument engine, dependency, format support or sound collection is
claimed by this brainstorm.

## Open Questions

- Initial instrument collection: sampler/drum sounds, pitched instruments,
  synthesizers, or some combination; built-in and third-party formats are not
  chosen yet.
- The owner requested arbitrary destination notes. The HTML proposal now maps
  computer keys and MIDI notes/buttons to one or more notes, including chords.
  Foot assignments offer Play a note or Sustain with momentary/latch behavior.
  Variable button velocity and the final shared-controller integration remain
  open. Preserve the accepted exclusive Press/Hold rules.
- Whether one controller can intentionally play several instrument sources,
  and how mappings shared with transport avoid accidental double actions.
- Whether editable MIDI loop recording is wanted beyond ordinary audio capture.
- Resource limits, loading progress and recovery when an instrument cannot load.

The owner requested and reviewed an [interactive HTML proposal](../design/fx-ux-prototype.html?review=instruments),
then requested integration into the main prototype. Instrument setup belongs
under Audio routing; recording belongs in Tracks using the ordinary pedal.
Instruments are internal inputs, not physical ports. The catalogue now shows
seven families and 19 illustrative patches, and the controls use the main theme.
MIDI, foot control and computer keys can be enabled independently without losing
assignments. Removal keeps recorded loops; empty libraries allow adding again.

The [delivery note](../design/2026-09-09-virtual-instruments-ux.md) records the
working UX, shared session ownership, browser evidence and simulation boundaries.
Native hosting, final sounds and physical controller/output integration remain
separate work. These prototypes do not claim audio is captured into native tracks.
