# MIDI controllers

Segno can be played from any USB MIDI controller: knobs and faders change
parameters, and buttons run the same performance actions the Segno pedal's
footswitches do. A controller does nothing until you map it; there is no fixed
set of CC commands.

MIDI input is captured natively on each desktop OS (CoreMIDI on macOS, the ALSA
sequencer on Linux, WinMM on Windows), so there is nothing extra to install.

## Opening MIDI controls

Open the settings tray, choose **Control**, and press **MIDI controls**.

The page shows a card for every MIDI input. The input in use says **Connected**,
**Connecting…**, **Disconnected** or **Could not open**; the others say
**Available**. Choosing a card makes that input the one in use. Segno listens to
one MIDI input at a time, and the Segno pedal shares it.

Below the cards are the mappings of the input in use. Each row shows the control
("CC 21 · Ch 1"), what it drives, a meter with the last value it received, and a
power button that turns the mapping off without deleting it. A disabled mapping
still keeps its control, so no other mapping can take it.

**MIDI control On / Off** pauses every mapping at once and keeps them all.

## Mapping a control

1. Press **Add mapping**. The editor opens and starts listening.
2. Move the knob, fader or button you want to use. The editor shows the control
   and the value it received.
3. Press **Add control** and choose what it changes: a parameter on a live
   input, a track or an output, or a **Performance action**.
4. Press **Save**.

While the editor is open, the controller being mapped changes nothing on the
rig, and anything it was holding is released. Learn gives up after 15 seconds
with no message, and says so.

### Message formats

Choose the format before Learn, with the format button. One MIDI byte cannot say
which format it belongs to, so Segno never guesses.

| Format | What it reads |
| --- | --- |
| CC, Note or Program | Ordinary 7-bit messages |
| 14-bit CC | A fresh MSB (CC 0-31) and LSB (CC 32-63) pair, within 100 ms |
| NRPN | CC 99 / 98 parameter selection, then CC 6 / 38 Data Entry |
| Bank + Program | Bank MSB + LSB (CC 0 / 32), then Program Change |
| Relative CC | Two's complement steps: 1 is one up, 127 is one down |

14-bit, NRPN and relative controls carry a position, not a press, so they drive
parameters only.

### Knobs and buttons

- A plain CC can be a **Knob / fader** or a **Button**. A Note is a button. A
  Program Change runs on every message and has no release.
- A button is **Momentary** (its values follow the press) or **Toggle** (each
  press flips it).
- A parameter's range is named by the behavior: **From / To** for a knob,
  **Released / Held** for a momentary button, **Off / On** for a toggle, and a
  single **Value** for a Program Change.
- An action runs when the control is **Pressed** or **Released**.

### Pickup

A knob does not change a parameter until it reaches the parameter's current
value, or passes it. Opening a session never makes a value jump. A relative
control moves the parameter from where it is, one step at a time, inside its
range.

### Receive channel

A mapping listens on the channel it was learned on. **Receive · Channel** changes
it, including to **Omni · All channels**.

### Controls that are already mapped

If the learned control reads any of the same messages as a saved mapping on a
channel it shares, the editor says so and Save stays off. **Edit existing
mapping** opens that mapping instead. A disabled mapping counts.

## Disconnects and missing targets

- **Unplugging a controller releases what it was holding.** Momentary values go
  back to Released and held actions end. No action is ever run by a disconnect.
- **A knob value stays where it was** when its controller unplugs.
- **A reconnected controller starts again from nothing**: toggles are Off and
  knobs pick up again.
- **A mapping whose parameter no longer exists** says **Missing control**. It
  does nothing until it is repaired with **Repair control** or removed. It never
  falls back to whatever took the parameter's place.

## Where mappings are stored

Mappings and the MIDI control switch are stored in the app settings, not in a
session.

## Troubleshooting

- **No cards** — the host exposes no MIDI input ports. Plug in the controller
  (on Linux, check it appears under `aconnect -i`).
- **Could not open** — another application holds the port. Close it and choose
  the card again.
- **Learn never hears anything** — check the controller sends Note, CC or
  Program Change messages in the chosen format, and that it is the input in use.
  The Segno pedal's own footswitch notes and encoder are never learned.
