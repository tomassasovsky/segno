# Displays and touch calibration

Status: owner accepted on 2026-09-07. Track display comes first because it is
physically on the left of the appliance. The main display is second. This is the
interactive design target, with simulated brightness and touch calibration.

Settings → Displays contains both displays, independent brightness controls,
Calibrate touch for each screen, and one shared Dim while idle choice. Brightness
uses the accepted FX slider treatment, from 20–100%, with an 80% default. Encoder
press starts editing, rotation changes the draft, press commits and Back cancels.
Double-tapping a slider restores its default.

Idle dimming offers Never, 2, 5 or 10 minutes. Neither display blanks. Playback,
backing playback, loop capture and performance recording keep both awake. A new
idle period begins after performance ends; touch, encoder and pedal activity wake
them. In this prototype brightness is illustrated on the miniature previews.

## Touch calibration

Choose Calibrate touch beside the relevant display. If audio is playing, Cancel
or Stop loops and calibrate makes the interruption explicit. Recordings remain
intact. Calibration is unavailable during capture, or for a disconnected display.

Tap five targets on the chosen screen. The prototype fits an affine correction
from those contacts, then presents three test targets. Keep calibration becomes
available only after those tests pass. Until Keep succeeds, the previous saved
calibration remains authoritative. Cancel, inactivity timeout, disconnect and
failed saves preserve it. Degenerate contacts offer Restart. A new playback or
capture command cancels calibration and leaves the music running.

The test phase has a visible 30-second timeout. Target collection allows 60
seconds between touches. Cancel remains encoder-accessible even when touch is
misaligned; test targets themselves cannot be activated by the encoder.

Display preferences belong to the appliance. Session recall and New Loop do not
change brightness, dimming or touch calibration.

## Evidence and implementation boundary

`verify_display_settings.cjs` passes in Chrome and Firefox, including pointer
contacts with a deliberate offset, alignment testing, recovery, encoder editing,
independent persistence, performance protection and canvas geometry. Native Pen
has six references grouped in Displays & touch calibration. Text and element
alignment checks pass, and the settings and test views were visually inspected.

The target follows the established touch-calibration pattern of calibration
points followed by verification and explicit retention. Production must bind each
profile to the correct physical display and touch controller, render its targets
on that actual screen, and provide encoder cancellation independently of touch.
The browser preview does not change OS touch mapping, backlights or hardware.
Actual panel brightness limits and calibration accuracy require appliance tests.
