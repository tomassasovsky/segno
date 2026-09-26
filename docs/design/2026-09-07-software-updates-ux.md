# Software updates

Status: owner accepted on 2026-09-07. Versions, packages, download, verification,
installation and recovery are simulated. The preview installs no real software.

Settings → Updates shows the installed version, Check for updates and Load from
USB. Check automatically performs only a read-only availability check; it never
downloads, installs or restarts. Download is explicit, cancellable and separate
from installation. The current software and performance remain active while an
update is prepared.

USB selection uses update packages, with an invalid example for testing rejection.
Verification failure cannot become success merely by retrying the same package.
USB removal immediately cancels verification, including a quick remove/reconnect.
Once verified, the package is staged internally and USB is no longer needed.
Storage refuses eject while a package is being read. New USB reads are blocked
while eject is pending.

Ready to install retains the current running version. Install and restart opens
the accepted save-before-restart confirmation. Cancel keeps the staged package and
playback. Confirmation finishes recording and saves the session before restart.
A simulated failed boot returns to the previous version and exposes Retry; this
is a target recovery contract, not proof that hardware rollback is implemented.

Network loss, absent USB, invalid packages and persistence failures retain the
running software. Download/check retries remain distinct. Staged packages and the
automatic-check preference belong to the appliance, outside musical sessions.

The existing `lib/update/cubit/update_state.dart` and
`lib/update/view/updates_settings_section.dart` provide the established
check → download → staged → explicit restart sequence. The Looper X inventory
also establishes disk-based firmware update entry points, but does not establish
package authentication or power-failure guarantees. Segno's target adds those
verification and recovery states explicitly.

Chrome and Firefox cover playback continuity, cancel, disconnect/retry, invalid
USB packages, staging without installation, safe restart, prior-version recovery,
persistence and canvas bounds. Pen holds six accepted update references alongside
the accepted power states. Whole-session USB backup is the next UX slice.

Production work includes authenticated manifests/packages, compatibility checks,
real download and free-space accounting, durable staging, boot-health confirmation
and tested rollback. USB package browsing must use actual removable-volume
identities. Independent controller-firmware updates, release channels, and
power-loss recovery remain further design/implementation work.
