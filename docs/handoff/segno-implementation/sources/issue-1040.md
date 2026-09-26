# #1040 bug(control): one MIDI input is captured, and the pedal path reads whatever it is [open]

## What I found

Segno captures **one** MIDI input device at a time, and that one capture feeds
two consumers that both need it.

`MidiControllerSource.open(id)` "opens (or switches to) the device", and there is
one `MidiControllerSource` in the app. Its `activity` stream is what the pedal
transport is built over (`_nativeTransport` in `packages/pedal_repository`), and
its `inputs` stream is what `ControllerRepository` maps learned bindings from. So
whichever device is open supplies both.

Two consequences, neither of them currently surfaced to the user:

**You can have the console board or a MIDI foot controller, not both.** Select
the board and a third-party controller's CCs never arrive, so nothing can be
learned from it while the pedal is connected. Select the controller and the
board's footswitches stop reaching the pedal path.

**Whichever device is open is read as the pedal.** Nothing filters by device, so
a MIDI keyboard's Note 4 presses Track 1, Notes 10 to 13 close an external
contact (#1026 part 4f), and CC 17 or 18 sweeps a CTRL jack's expression
mappings. These are the pedal's own wire numbers, read off whatever happens to be
plugged in.

## Why it has not bitten yet

On the appliance the console board is the only MIDI input in the normal case, and
MIDI learn is a desk-setup feature. The overlap only shows when someone uses both
at once, which the product has not been tested doing.

## The product decision this needs first

Is a third-party MIDI controller meant to work **alongside** the console board,
or instead of it?

- **Alongside** means the native layer opens more than one input, each capture
  carries a device identity, and the pedal path accepts only the bound device's
  traffic. That is native work in `midi_client` plus a device field on
  `RawControllerInput`.
- **Instead of** means the current behaviour is intended, and what is missing is
  only that the UI never says so: choosing a controller should state plainly that
  the console's own footswitches stop working.

The accepted external-pedals design already lists "MIDI controller
discovery/learn" and "multiple-controller arbitration" as unspecified, so this is
the same seam seen from the input side.

## Not in scope

Arbitration between two sources writing one parameter (an expression pedal and a
learned CC on the same FX knob) is a separate question, named as open in the same
design.

