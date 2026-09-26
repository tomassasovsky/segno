# Wi-Fi setup

Status: owner accepted on 2026-09-07, including the compact connection row, IP
address and simplified Manage popup. This is the HTML study;
connections, signal strength and reachability are simulated. No real credentials
or network interfaces are accessed.

## Path and behavior

Settings → Network opens Wi-Fi. The current connection occupies a compact status
row with Manage; other networks occupy one full-width scrollable list below it.
The connected network is not repeated in that list. Saved networks stay first.
The initial large connection card was rejected because it wasted half the page.
The connection row shows the current IP address. Manage uses aligned rows for
automatic connection and password changes, with Forget and Disconnect below;
the original scattered-button popup was replaced. Selecting a network opens its password or connection controls.

One password editor supports touch keys, the encoder and physical typing, with
lowercase, uppercase, numbers and punctuation. Passwords start masked. Show/Hide
only affects the current editor. Cancel, successful connection and leaving clear
the password. The study never puts it in storage or its public state snapshot.

Connect shows progress and Cancel. A previous connection remains in place until
the new connection succeeds. Incorrect password keeps the editor available for
correction; network unavailable is a separate error. Failed or cancelled attempts
cannot replace the previous connection or remember an unsuccessful network.

Saved network controls are Connect/Disconnect, Connect automatically, Change
password and Forget network. Forget removes that profile and disconnects it if
active. Wi-Fi off cancels connection/scan work and disconnects; turning it back on
scans and reconnects the preferred saved network if automatic connection is on.
Scan refreshes the list without interrupting the current connection.

Connection loss tries the saved connection once when automatic connection is on.
If unavailable, Connection lost and Reconnect remain visible. Internet reachability
is distinct: Connected · No internet means Wi-Fi is associated but internet access
is unavailable. Neither condition interrupts recording, playback, effects, MIDI
over physical connections, or the local Library.

Wi-Fi preferences belong to the appliance, outside saved musical sessions. New
Loop and session recall cannot change the radio or remembered profiles. A storage
failure keeps the previous configuration and connection.

## Reference and validation

The existing Segno Wi-Fi flow provides the established interaction reference:
`lib/wifi/wifi_tray_body.dart`, `lib/wifi/wifi_state.dart` and
`lib/network/wifi_join_sheet.dart`. The target presentation uses the accepted
1920 × 1080 prototype scale, simple rows and the shared encoder focus treatment.

`verify_network.cjs` exercises joining, cancellation, errors, saved controls,
reconnect, radio state, scrolling, password handling, persistence and recording
continuity in Chrome and Firefox. Browser and native reference images live in
`network-previews/`. The simulated controls sit below the appliance canvas.

Production work remains: connect these states to the Linux Wi-Fi service, handle
real scan/authentication events, and validate on the appliance. Hidden networks,
enterprise authentication, captive portals, manual addressing and Bluetooth are
not covered by this proposal. Do not report this study as working hardware Wi-Fi.

## Channel names

Tracks, inputs and outputs display a custom name when it contains text; otherwise
they display Track N, Input N or Output N. Whitespace-only names count as empty.
Clearing an input/output alias and saving restores that numbered display name.
Persist empty aliases as empty so reload does not restore an example instrument
name. Display names never alter routing identities or recorded audio.
