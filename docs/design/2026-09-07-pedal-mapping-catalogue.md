# Pedal mapping catalogue

Current target-UX inventory, checked against the main prototype on 2026-09-07.
This is a catalogue of exposed choices and design decisions, not a claim of
production audio-engine or hardware support. Existing code does not limit the
future product; omissions below are work to define and connect.

## Built-in pedals

Settings → Pedals → Custom controls offers **26 choices** for each editable
Press and Hold assignment:

| Choice | Meaning / current design status |
|---|---|
| None | No action for this gesture. |
| Track | Return to normal track controls. |
| Record / Play | Configured record/play/overdub sequence. General Custom dispatch still needs connecting. |
| Stop | Transport stop. General Custom dispatch and precise target scope need completion. |
| Undo | Per-track audio-edit recovery, with grouped Clear All/Bounce recovery. Rules agreed; unified history remains unfinished. |
| Redo | Restore undone audio edits. Rules agreed; unified history remains unfinished. |
| Mute | Enter banked track mute controls. |
| FX | Enter the two banks of four FX controls. |
| Mixer | Enter single-channel level/mute controls for tracks or live inputs. |
| Transpose | Enter track pitch adjustment while preserving timing. |
| Reverse | Toggle selected tracks' playback direction. |
| Fade | Per-track fades with shared default and optional track duration. |
| Speed | Change playback speed/pitch of all recorded tracks together. |
| Multiply | Enter selected-track loop-length multiplication. |
| Divide | Enter direct First half / Last half selection. |
| Peel | Remove latest overdub while protecting original audio; recovery is designed. |
| Bounce | Combine selected sources into a destination, with grouped recovery. |
| Backing track | Enter prepared-audio selection and playback by foot. |
| New loop | Preserve the current session and start empty tracks with the setup retained. |
| Record performance | Start/stop continuous performance capture; recover a pending take. |
| Tuner | Accepted input selection, temporary live mute, A4 reference and foot-operated Exit; interactive readings are simulated. |
| Wave | Show waveform lanes and restore normal track controls; touch selection and pedal selection share the small display. |
| Multi | Listed loop-mode shortcut; transition/confirmation behavior remains undefined. |
| Song | Listed loop-mode shortcut; transition/confirmation behavior remains undefined. |
| Sync | Listed loop-mode shortcut; transition/confirmation behavior remains undefined. |
| Band | Listed loop-mode shortcut; transition/confirmation behavior remains undefined. |

Record / Play, Stop, Undo and Redo now dispatch from Custom, external and MIDI
assignments. Wave opens the main waveform view. The four loop-mode shortcuts
still lack existing-audio transition rules.
Free mode is missing from this shortcut list. These are explicit gaps.

### Normal Track controls

- Mode Press: Mute, Tuner, FX or Custom.
- Mode Hold: None, Mute, Tuner, FX or Custom.
- Default Mode assignment: **Press Mute; Hold Custom**.
- Record / Play Hold: Undo recording or Peel layer. Its Press is fixed.
- Track-pedal Hold, edited as one group: Arm overdub or Clear track. Press remains
  the normal track action.
- Stop, Undo/Redo, Clear and Bank remain fixed in this context.

Custom controls allow Press/Hold editing on Record / Play, Stop, Undo, Clear and
the four track positions. Track positions have separate assignments in banks A
and B. Mode remains the fixed Exit; Bank remains bank switching. Exit means return
to normal track controls, not closing the app. Holding runs only the Hold action.

### FX assignments

Eight performance slots: **A1, A2, A3, A4, B1, B2, B3, B4**. Each can control
multiple rack or single-FX activations. The rack/effect count is not limited to eight.
Each activation rule is On, Off, Held or Released; Always on bypasses pedal control.
On/Off use latched state. Held/Released follow physical contact. LED state follows
the result, with owner-selected colour. Inverted pairings are supported.

## External single and dual switches

Settings → Pedals → External pedals → choose jack and button.

The current **40 action choices**, including None, are grouped as follows:

- Track 1, Track 2, Track 3, Track 4, Track 5, Track 6, Track 7, Track 8.
- Record / Play, Stop, Undo, Redo, Wave, Mute, Custom, FX, Mixer, Transpose, Reverse, Fade, Speed, Multiply, Divide,
  Peel, Bounce, Backing track, Tuner, New loop, Record performance, Exit, Next bank.
- FX A1, FX A2, FX A3, FX A4, FX B1, FX B2, FX B3, FX B4.
- None.

Track actions target a fixed track regardless of the current bank. A dual switch
can therefore access Track 5 and Track 6 while built-in pedals remain on bank A.
Momentary hardware supports separate Press and Hold; latching hardware uses
On change. The [function assignment proposal](2026-09-07-external-function-assignments-ux.md)
adds the completed performance flows through the shared built-in dispatcher.
Loop-mode conversions and complete cross-feature history integration remain gaps.

Each button also has a **Controls** list with multiple mappings:

- Activate an existing rack or single effect when On, Off, Held or Released.
- Set a supported parameter to two chosen values: On/Off or Held/Released.
- Control the mix values listed below in the same way as effect parameters.

Held/Released requires a momentary switch. External assignments live here rather
than in the FX activation picker. One button can affect several controls at once.
The two buttons on a dual pedal are configured independently.

## Expression pedals and button-value targets

Expression mapping uses the same parameter catalogue as external button values.
Each expression pedal can control multiple targets, each with independent heel
and toe values, including inverted ranges. Calibration handles pedal polarity.

| Destination | Parameters exposed |
|---|---|
| Each live input | Live volume; Pan for mono or shared Balance for a stereo pair. |
| Each recorded track | Playback volume and Pan. |
| Each recorded input within a track | Volume and Pan, when that source exists in the recording. |
| All tracks | Recorded-mix volume and Pan. |
| Each output | Output level and Balance. Mono output makes balance ineffective until Stereo returns. |
| Each loaded rack/effect | Parameter entries admitted by the current catalogue, detailed below. |

Live-input volume here controls monitoring, not recording trim. Output volume
shares the new output-level control. Physical input/output aliases do not change
mapping identity.

### Missing mappings and catalogue cleanup

The current parameter picker does **not** expose recording trim; output mute;
Hear live Off/Auto/On; routing; stereo pairing/mono conversion; click/backing level;
tempo, time signature or count-in; per-track loop length, playback Loop/Once,
decay or follow-tempo settings; or arbitrary preset/session loading.

Mode-specific commands such as pitch steps, fade duration and First/Last half
exist inside their performance views. They are not all independently assignable
items in the general picker. This distinction should be preserved in the roadmap.

The raw factory-derived parameter filter still admits switches and enumerated
values (for example Audio Type, Key, Scale and Stereo) as if they were continuous
controls. Several labels also retain factory abbreviations or land under Other
controls. These are inventory findings, not accepted polished mappings. A typed
control catalogue must distinguish continuous values, toggles and choices before
production mapping dispatch is treated as complete.

## Complete factory-derived parameter inventory

This is the union across factory presets, not just the effects loaded in the
current example rig. A parameter appears in the picker only when its target
instance exists. The labels below preserve the current picker, including the
cleanup issues called out above. Enable fields and some Mode/Pattern/Step Length
selectors are excluded by its filter.

136 distinct parameter labels across 29 module groups.

| Module group | Current parameter labels |
|---|---|
| Ambient Reverb | Amb-Dub Mix, Amb-Verb, Amb-Verb Dec, Amb-verb Level |
| Amp | Bass, Drive, Treble |
| Chorus | Chor, Chor Depth, Chor Mix, Chor Rate |
| Compressor | Comp, Comp Attack, Comp Make-Up, Comp Ratio, Comp Release, Comp Thresh |
| Degrade | Degrade Filter, Degrade Frequency, Degrade Mix |
| Delay | Feedback, Frequency, Mix, Time |
| Distortion | Dist, Dist Drive, Dist Tone |
| Doubler | Doubler, Doubler Mix, Doubler Sep |
| Dub Delay | Damp, Feedback, L/R Ratio, Res-Frequency, Resonance, Time |
| Dub Reverb | Dub-Verb, Dub-Verb Dec, Dub-Verb Level |
| Four-band EQ | Hi Mid, Hi Mid Frequency, Hi Mid Q, High, High Cut, High Frequency, High Q, Lo Mid, Lo Mid Frequency, Lo Mid Q, Low, Low Cut, Low Frequency, Low Q |
| Harmonize | Harm Level, Lead Level, Voice 1, Voice 1 Delay, Voice 1 Gender, Voice 1 Level, Voice 1 Pan, Voice 1 Pitch, Voice 2, Voice 2 Delay, Voice 2 Gender, Voice 2 Level, Voice 2 Pan, Voice 2 Pitch |
| HP / Gate | Gate Thresh, HP/Gate |
| Low-pass Filter | Cutoff, Depth, Rate, Resonance |
| Master | Level |
| Modulation | Depth, Mix, Rate |
| Octaver | Oct, Octave 1 Level, Octave 2 Level, Octave Mix |
| Other controls | Audio Type, Auto Source, High EQ, High EQ Frequency, Highpass, Key, Low EQ, Low EQ Frequency, Mid EQ, Mid EQ Frequency, Reference, Scale, Scale Root, Scale Type, Speed, Stereo, Tightness, Tracking |
| Overdrive | Drive, Tone |
| Parametric EQ | Air, High, High Cut, Low, Low Cut, Mid, Mid Frequency, Mid Gain, Mid Q, Para EQ |
| Pitch Shift | Pitch Mix, Pitch Shift |
| Pumper | Depth, Rate |
| Reverb | Bright, Density, ER, Length, Lo/Hi, Mix, Tail/ER |
| Slicer | Mix |
| Spring Reverb | Mix, Time |
| Transient | Attack, Attack Length, Sustain, Transient |
| Vinyl | Vinyl Drive, Vinyl Frequency, Vinyl Noise, Vinyl Noise-Tone |
| Wah | Pedal |
| Whammy | Whammy Pedal, Whammy Range |

[Machine-readable parameter inventory](pedal-mapping-parameters.json).

## Evidence

- `pedal-ux-study.js`: exact Custom and Track-controls pickers and fixed positions.
- `pedal-performance-study.js`: available entry functions and dispatch gaps.
- `external-switch-study.js`: external actions, activation conditions and button values.
- `expression-ux-study.js`: multiple targets and heel/toe mapping.
- `fx-ux-prototype.html`: destination/parameter construction and shared controls.
- [Pedal contracts](2026-09-06-pedal-performance-contracts.md), accepted performance
  slice documents and [input setup](2026-09-07-audio-routing-ux.md).

The factory inventory was extracted from the actual parameter builder in an
isolated browser page using all factory presets. It did not modify the user's rig.
