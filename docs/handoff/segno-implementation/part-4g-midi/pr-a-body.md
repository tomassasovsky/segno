Part of #1026 (part 4g, the fourth and page PR). Stacked on #1049.

## What this adds

**The MIDI controls page**, reached from a new "MIDI controls" row on the Control face, under Pedal setup.

- **The list.** A card for every MIDI input: the one in use says Connected, Connecting, Disconnected or Could not open, and the others say Available. Choosing a card makes that input the one in use.
- **Mapping rows.** The mappings of the input in use, each with its source ("CC 21 · Ch 1"), what it drives, a signal meter, a warning (Missing control or Disconnected) and a power button that saves at once.
- **Page controls.** MIDI control On / Off and Add mapping. A controller with no mappings says No mappings.
- **The editor, left column.** The device, the learned control, the message format, what Learn received ("Received 8193 / 16383", "Received -1 step"), the receive channel, and Learn / Learn another control. While listening it shows the listening box and Cancel Learn.
- **Overlaps.** An overlapping control shows the overlap text and Edit existing mapping.
- **Behavior choices.** Knob / fader or Button for a plain CC, and Momentary or Toggle for a button.
- **The editor, right column.** Every control it drives: parameters with From / To, Off / On, Released / Held or a single Value; actions with When: Pressed | Released. Each card has Change control, which becomes Repair control when the parameter is gone, and a remove button.
- **The pickers, as whole views.** Choose a destination, with Performance actions, which is disabled for 14-bit, NRPN and relative controls. Then the destination's parameters, the receive channel (Omni or 1-16) and the message format; choosing a format starts Learn.
- **Notices.** Saved, Mapping removed, Could not save (the draft stays), Actions need a button, the refusal to learn a high-resolution control while actions are mapped, MIDI controls enabled / paused, and the two Learn timeout messages.

**What the page needs from the control interpreter.**
- **Editing pauses the controller.** `beginMidiEdit` / `endMidiEdit` pause the controller while a mapping is open, with or without Learn, as the design requires. This is the #1049 review note.
- **The paused-after-disconnect bug is fixed.** A controller that disconnected during Learn used to stay paused forever. The editor now stays open across a disconnect, Learn hears the controller when it returns, and closing the editor always resumes it.
- **Learn times out.** After 15 seconds it stops and says why.
- **Failed writes change nothing.** MIDI settings are written before they take effect, so a failed write changes nothing. Writes run one after another, so quick edits cannot lose each other.
- **Meters stay off the control state.** They read the repository's message stream through `MidiSignalLevels`, not the control state, so a moving fader redraws only the meters.

## Review

An independent review, run as five parallel reviewers, found 26 candidates, and I checked each against the code. The fixes are in the third commit, each with a test that fails without it:
- **Actions and formats.** Every Learn start refuses a press-less format while the mapping drives actions, not only the format picker.
- **Pickers and Learn.** Opening a picker stops a listening Learn, so a stray control cannot become the source out of sight.
- **Save and the power button.** Save keeps whether a mapping is enabled.
- **Late writes.** A write that lands after the performer moved on leaves the new editor alone.
- **Toggle buttons.** Tapping Button again keeps a Toggle a Toggle.
- **Meters.** They survive a visit to the editor and drop a half pair when the controller goes away.
- **Screen readers.** They can press the page's own controls.
- **Smaller fixes.** The repair notice, None in the action picker, the notice placement, the theme disabled opacity, and names for the two behavior groups.

## Where this departs from the pen

Recorded on #1026 as well.

1. **Entry point.** A Control face row replaces the Settings grid tile, because the app has no ten-tile Settings home.
2. **Top bar.** The crumb reads "SETTINGS / MIDI" instead of the Controls | Sync tabs, because MIDI Sync is not built.
3. **Device cards.** They show the input's status rather than USB or DIN, which the MIDI backend does not report. Choosing one switches the single input in use (#1040); the prototype instead filters several open inputs.
4. **Performance actions.** They open the shared action picker, the one every other picker uses, instead of an in-page grid.
5. **Parameter values.** They read as a percentage of the range, as on External pedals, instead of in the parameter's own units.

## Not built here, recorded

- **Encoder editing and double-tap reset** of a range. There is still no shared encoder-focus model.
- **The held-instrument rule.** Instruments are not built.
- **Pan and balance** are not in the parameter catalogue.
- **The Program-only "Value" slider** is built. No pen screen draws it.

## Next

The old model comes out in the next PR: `ControllerBinding`, the Control tray's MIDI tab, `midi_learn_section`, the fixed CC 80-86 scheme and `ControllerRepository`. It also adds a tap tempo action to the shared catalogue, since the fixed scheme is today's only external path to it.

## Verification

- `flutter test`: the root suite (2468) and `packages/controller_repository`.
- `dart analyze --fatal-infos`: the app is clean. Ten pre-existing infos in `packages/looper_repository/test/models/fx_chain_group_test.dart` come from a file this branch does not touch.
- `bloc lint lib`: clean.
- New tests:
  - the cubit session, timeout, write failures and write ordering;
  - the editor draft rules and the labels;
  - `MidiSignalLevels`;
  - 41 page widget tests;
  - 13 screenshots at 1920x1080, compared by eye with pen sections 26 and 53.
- Mutation checks, each confirmed to fail a test:
  - the session (resume on close, pause on open, the other device resumed);
  - write-first and serialized writes, and the decoder reset on Learn;
  - timer cancel on capture;
  - Learn start, applying the learned control, Save while listening;
  - resume on Cancel and on leaving the page;
  - save and delete failure handling, the action and format refusals;
  - the device filter, the action offer, the missing warning, the timeout message;
  - Edit existing, Change control, the card tap;
  - the channel copy, the next id, and the signal levels.
