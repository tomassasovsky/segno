# Tuner performance

The owner reviewed the Tuner, requested no changes, and asked to continue on
2026-09-07. This accepts the interaction proposal; pitch readings remain simulated.

## Foot journey

Assign Tuner to a built-in Mode or Custom Press/Hold action. The existing default
Custom layout reaches it by holding the second track position. Holding runs only
the Hold action; release does not select an input on the new screen.

| Pedal | Tuner action |
|---|---|
| Track positions 1–4 | Select one physical input, identified by its saved name and jack number. |
| Bank | Next four inputs; select the first input of that page. Up to eighteen inputs is demonstrated. |
| Stop | Toggle temporary live mute of the selected input. |
| Undo / Clear | Lower / raise A4 reference by 1 Hz. Hold either to restore 440 Hz. |
| Mode | Exit to normal Tracks controls. |
| Record / Play | Unavailable in Tuner. Existing recordings and playback continue. |

The reference range is 420–460 Hz. Source selection and reference are appliance
settings and survive reload and session recall. Input paging does not change the
normal track bank. Failed storage writes preserve previous settings and explain
the failure; Exit and temporary mute continue to work.

## Signal and monitoring

The target detector listens to the selected physical input before effects. The
large note and −50 to +50 cents scale remain readable while operating the pedals.
Flat, Sharp, In tune and Play one note distinguish direction, centring and absent
or unreliable detection. The target in-tune interval is strictly within ±3 cents.
No signal or a new input clears the previous reading.

Each entry starts with the selected live input muted. A linked stereo pair is
muted together, although detection uses the selected physical jack. The temporary
gate follows input selection; the previous input returns to its normal monitoring.
Unmuting removes this gate and respects existing Hear live, Auto and Mixer mute
settings. The display states when those settings still prevent live sound.
Tracks, backing, other live inputs and recording capture are unchanged. Existing
downstream effect tails may finish; mute does not flush them.

Exit, Back and leaving for Settings remove the temporary gate. Mute is never
persisted and does not overwrite input monitoring, Mixer levels or output routing.
The physical display allocation remains open; this study uses the shared 1920×1080
canvas and accepted ten-pedal layout.

## Reference and verification

The extracted Looper X `AppUI/Pages/Tuner.qml` supplies the note/cents model,
reference selection, four-input selector and strict ±3-cent visual threshold.
Its input bitmask permits multiple selections and its reference range is native.
Segno's single-input selection, eighteen-input paging, 420–460 Hz reference range,
mute scope and appliance persistence are explicit product choices.

`verify_tuner_performance.cjs` passes in Chrome and Firefox for foot/encoder entry,
exclusive holds, selection, paging, reference reset/limits, signal validity,
mono/stereo mute, transport/capture isolation, Exit, persistence, session recall,
write failure and five layouts. Existing pedal and routing suites also pass.
These checks do not establish detector accuracy, latency, audio processing or
physical touch/foot ergonomics.

The five matching Pen views are saved; 158 text nodes and 437 elements pass native
alignment and dimension checks. Their gallery manifest records the saved hash.

[Browser and Pen review gallery](tuner-previews/index.html).
