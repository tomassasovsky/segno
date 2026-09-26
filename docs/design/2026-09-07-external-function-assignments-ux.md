# External pedal function assignments

This proposal follows acceptance of Tuner. The mapping audit found that external
buttons could enter only Mute, Custom and FX, despite other completed performance
flows being assignable to built-in pedals.

## Choose an action

Settings → Pedals → External pedals → jack → button → Press, Hold or On change.
The action picker has three groups:

- **Functions:** None, Mute, Custom, FX, Mixer, Transpose, Reverse, Fade, Speed,
  Multiply, Divide, Peel, Bounce, Backing track, Tuner, New loop,
  Record performance, Exit and Next bank.
- **Tracks:** Track 1–8, with fixed targets independent of the current bank.
- **FX pedals:** A1–A4 and B1–B4, operating the existing assignment states.

There are 35 choices. Functions scroll vertically with the existing centred,
non-selectable continuation arrow. Encoder focus reveals offscreen choices.
The picker opens in the group containing the current assignment. Selecting an
action edits the draft; Save commits and Cancel restores the saved assignments.

Momentary switches retain independent Press and Hold, with Hold consuming Press.
Latching switches use On change. Multiple parameter and activation mappings remain
under Controls, alongside Actions, with their accepted On/Off and Held/Released
rules. They are not duplicated inside the function picker.

## Performance behavior

External entries use the same function dispatcher as built-in assignments. Each
mode keeps its accepted ten-pedal workflow and Exit. New loop preserves the current
session before starting fresh; Record performance starts or finishes the existing
capture workflow. Assigning one of these commands does not execute it.

The review example gives Button 1 Mixer on Press and Tuner on Hold, with Button 2
as Exit. On Stage, the entire entry/operation/exit journey is available by foot.
When auditioning assignments while setup remains open, mode changes keep setup
visible; the Stage button returns to the active performance view. Direct New loop
uses its existing immediate transition and does not require touch confirmation.

Unfinished Wave and loop-mode conversion shortcuts are not included. General
Record/Play, Stop, Undo and Redo commands still need their shared target/dispatch
contracts completed. Their absence is not a hardware restriction or a product
decision to exclude them permanently.

## Validation

The focused browser suite exercises every shared mode through saved external
assignments, direct New loop and Record performance, an external-only
Mixer/Tuner/Exit journey, exclusive holds, latching transitions, draft cancellation,
encoder scrolling and all four review layouts. The existing external-switch and
Tuner suites cover cancellation, disconnect, parameter mappings and monitoring.
These are silent prototype checks; physical jacks and audio processing are not
implemented by this change.

Chrome and Firefox pass the focused and regression suites. Four matching Pen
views are saved; 144 text nodes and 274 elements pass native alignment and
dimension checks. Their gallery manifest records the saved design hash.

[Browser and Pen review gallery](external-functions-previews/index.html).
