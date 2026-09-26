# Safe shutdown and restart

Status: owner accepted on 2026-09-07. This is a silent UX prototype; no operating
system shutdown or reboot commands run on the development computer.

Settings → Power opens one choice with the current session name, Cancel, Restart
and Shut down. It explains that playback stops and the session is saved. If
recording is active, the copy says recordings will finish first. An active file
transfer or USB eject blocks starting the shutdown flow.

Shut down/Restart finishes loop capture and performance recording, stops playback,
and saves the current session. Stay on can cancel during preparation; already
finished recordings stay finished and saved. A failed recording or session write
leaves Segno on, with Retry and Stay on. There is no discard-and-power-off action.

After successful saving, shutdown shows Safe to switch off. Restart returns to
the same session with tracks stopped. Prototype hardware entry points cannot start
new performance operations while shutdown is preparing or complete. The simulator
outside the appliance canvas can return to the prototype without reloading.

The Looper X shutdown workflow also coordinates recordings, session save and
storage state; see [the extracted UX paths](../research/sheeran-looper-x-1.0.2/ux-paths.md).
Segno follows the previously accepted automatic-preservation rule instead of
introducing another save/discard decision.

Chrome and Firefox verify cancel, failed-save retry, real browser-storage failure,
finishing initial loop takes and performance recordings, recovery of failed capture
saves, stopped restart, session reload and layout bounds. Native Pen contains five
reference states grouped under Safe shutdown & restart.

Production must await durable audio/session writes, release devices and filesystems,
and then acknowledge OS shutdown/restart. The physical power-control circuit and
last visible screen require appliance validation. The prototype does not prove
power-loss safety, filesystem durability or actual hardware shutdown.
