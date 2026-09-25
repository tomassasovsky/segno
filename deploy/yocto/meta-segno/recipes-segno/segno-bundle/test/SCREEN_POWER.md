# Screen power lifecycle

The v3 console carries GPIO17 through J25 to the screen board. The appliance
uses the official libgpiod 2 Python binding to keep that line owned. It locates
the Pi 5 RP1 controller by label and GPIO17 by line name, starting low.

Weston depends on the GPIO service. Its start hook enables screen power and
waits one second before display/touch probing. The app remains ordered after
Weston. During stop/restart, the app finishes first; Weston's synchronous stop
hook drives low and waits five seconds before systemd terminates the compositor.
This applies to orderly poweroff, ordinary reboot and update reboot because all
use the same systemd stop transaction. The existing save/goodbye UI stays intact.

The five seconds are a provisional wait, not a measured discharge specification.
The GPIO service has no automatic re-enable on failure. Its cleanup reclaims the
line low even if its main process was killed. Weston is bound to that service;
a failed GPIO owner stops the display session instead of leaving it running.
An abrupt loss of HDMI caused by a compositor/kernel fault is not an orderly
shutdown and cannot be prevented by a userspace stop hook.

Run the host tests with:

```sh
python3 deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py
```

They exercise controller selection, low-before-wait, GPIO errors, socket
acknowledgment, invalid commands, live daemon termination, interrupted re-enable and ownership release.
Production dependencies are pinned by the existing Yocto layer commits:
`python3-gpiod` 2.3.0 plus Python core/I/O modules. The binding request API is
[documented upstream](https://libgpiod.readthedocs.io/en/v2.3/python_line_request.html).

Before device release, install the matching image and controller firmware on
assembled v3 hardware. Capture GPIO17 and both screen supply rails during cold
boot, ordinary halt, restart, update reboot and app restart. Check that both
panels are dark before HDMI disappears and that five seconds covers measured
discharge with margin. Repeat after a warm run. Do not infer this result from
host tests or the owner's separate HDMI-only darkness check.
