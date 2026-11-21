<!-- cspell:words EPROTO memmove unamortised -->
# GitHub issues moved to Jira

On 2026-11-21 the owner's work tracking moved from GitHub Issues to the Jira
project `SEG` (`docs/TRACKING.md`). Each issue that was open that day was
copied to Jira with its labels mapped, and closed on GitHub with a comment
naming its key. Its GitHub comments and history stay on GitHub.

Docs, plans and commit messages written before then cite issues as `#N`. Use
this table to find where an open one went. Issues that were already closed
stay on GitHub only.

| GitHub | Jira | Title |
| --- | --- | --- |
| [#299](https://github.com/tomassasovsky/segno/issues/299) | [SEG-4](https://aquiles-team.atlassian.net/browse/SEG-4) | Harden ALSA duplex patches: exact buffer_size, min-period gate, prepare-fail logging |
| [#504](https://github.com/tomassasovsky/segno/issues/504) | [SEG-6](https://aquiles-team.atlassian.net/browse/SEG-6) | chore(theme): geometry tokens — radius + spacing (DS stage 2) |
| [#710](https://github.com/tomassasovsky/segno/issues/710) | [SEG-9](https://aquiles-team.atlassian.net/browse/SEG-9) | Audible clicks and flickers in performance recordings — umbrella (parked for Pi 5 bench) |
| [#727](https://github.com/tomassasovsky/segno/issues/727) | [SEG-10](https://aquiles-team.atlassian.net/browse/SEG-10) | Crash durability for a capture bundle: sync the sidecar and its PCM together, off the drain cycle |
| [#738](https://github.com/tomassasovsky/segno/issues/738) | [SEG-13](https://aquiles-team.atlassian.net/browse/SEG-13) | chore(update): bound the OTA helper's remaining waits and test it under busybox ash |
| [#740](https://github.com/tomassasovsky/segno/issues/740) | [SEG-15](https://aquiles-team.atlassian.net/browse/SEG-15) | bug(appliance): the Scarlett cycles on the USB bus — 358 enumerations, 90 EPROTO faults |
| [#741](https://github.com/tomassasovsky/segno/issues/741) | [SEG-16](https://aquiles-team.atlassian.net/browse/SEG-16) | fix(appliance): the kernel cmdline carries duplicate, conflicting video= args for both HDMI outputs |
| [#752](https://github.com/tomassasovsky/segno/issues/752) | [SEG-19](https://aquiles-team.atlassian.net/browse/SEG-19) | feat(firmware): the contract console board v2 imposes on firmware |
| [#801](https://github.com/tomassasovsky/segno/issues/801) | [SEG-21](https://aquiles-team.atlassian.net/browse/SEG-21) | tune(appliance): a fan curve for an instrument, not a desktop |
| [#822](https://github.com/tomassasovsky/segno/issues/822) | [SEG-23](https://aquiles-team.atlassian.net/browse/SEG-23) | Verify the coredump half of #438 on a real unit |
| [#826](https://github.com/tomassasovsky/segno/issues/826) | [SEG-25](https://aquiles-team.atlassian.net/browse/SEG-25) | feat(appliance): the image provisions the bootloader EEPROM itself |
| [#853](https://github.com/tomassasovsky/segno/issues/853) | [SEG-26](https://aquiles-team.atlassian.net/browse/SEG-26) | chore(appliance): boot-experience residuals — timeline measurement, weston background, docs |
| [#870](https://github.com/tomassasovsky/segno/issues/870) | [SEG-27](https://aquiles-team.atlassian.net/browse/SEG-27) | perf(engine): harden the deferred lane-trim against premature flag-clear under snapshot polling |
| [#878](https://github.com/tomassasovsky/segno/issues/878) | [SEG-28](https://aquiles-team.atlassian.net/browse/SEG-28) | test(flaky): screenshot fonts bleed into the merged --optimization isolate, breaking overflow tests on author machines |
| [#883](https://github.com/tomassasovsky/segno/issues/883) | [SEG-29](https://aquiles-team.atlassian.net/browse/SEG-29) | Appliance update mirror: fail loudly at publish when the mirror never reaches the new version |
| [#893](https://github.com/tomassasovsky/segno/issues/893) | [SEG-31](https://aquiles-team.atlassian.net/browse/SEG-31) | tune(appliance): find the lowest stable monitor latency, not just the un-regressed one |
| [#909](https://github.com/tomassasovsky/segno/issues/909) | [SEG-34](https://aquiles-team.atlassian.net/browse/SEG-34) | perf(engine): the tuner path costs the callback a per-frame memmove and an unamortised detection burst |
| [#913](https://github.com/tomassasovsky/segno/issues/913) | [SEG-35](https://aquiles-team.atlassian.net/browse/SEG-35) | perf(engine): the octaver's YIN pass is ~640k iterations every 256 samples, and is now trivially sliceable |
| [#1009](https://github.com/tomassasovsky/segno/issues/1009) | [SEG-1](https://aquiles-team.atlassian.net/browse/SEG-1) | feat(console): implement the accepted Segno design throughout the app (handoff 919) |
| [#1026](https://github.com/tomassasovsky/segno/issues/1026) | [SEG-39](https://aquiles-team.atlassian.net/browse/SEG-39) | Slice 4: shared assignments and foot performance |
| [#1037](https://github.com/tomassasovsky/segno/issues/1037) | [SEG-40](https://aquiles-team.atlassian.net/browse/SEG-40) | The row-2 pedestals print as a hollow shell where they should be solid |
| [#1058](https://github.com/tomassasovsky/segno/issues/1058) | [SEG-41](https://aquiles-team.atlassian.net/browse/SEG-41) | Integrate accepted design controls with the current UART console |
| [#1069](https://github.com/tomassasovsky/segno/issues/1069) | [SEG-42](https://aquiles-team.atlassian.net/browse/SEG-42) | feat(appliance): DIN MIDI reaches the app -- persistent UART0 and routing |
| [#1076](https://github.com/tomassasovsky/segno/issues/1076) | [SEG-45](https://aquiles-team.atlassian.net/browse/SEG-45) | feat(firmware): drive all ten pills during normal pedal use |
| [#1077](https://github.com/tomassasovsky/segno/issues/1077) | [SEG-46](https://aquiles-team.atlassian.net/browse/SEG-46) | feat(pedal): Song queue completion and 40-LED ring firmware |
| [#1078](https://github.com/tomassasovsky/segno/issues/1078) | [SEG-47](https://aquiles-team.atlassian.net/browse/SEG-47) | fix(performance): recover large captures without loading entire PCM into memory |
| [#1143](https://github.com/tomassasovsky/segno/issues/1143) | [SEG-50](https://aquiles-team.atlassian.net/browse/SEG-50) | Replay ordinary audio-history changes in performance stems |
| [#1157](https://github.com/tomassasovsky/segno/issues/1157) | [SEG-51](https://aquiles-team.atlassian.net/browse/SEG-51) | Punch-out drain walks Sync-division tracks with the master clock length |
| [#1160](https://github.com/tomassasovsky/segno/issues/1160) | [SEG-52](https://aquiles-team.atlassian.net/browse/SEG-52) | Capture-prep guard gaps: cross-channel launch-grace emptying and ring-full grid clear |
| [#1177](https://github.com/tomassasovsky/segno/issues/1177) | [SEG-53](https://aquiles-team.atlassian.net/browse/SEG-53) | Appliance USB storage service: detect, mount, eject, capacity, and the drive picker |
| [#1179](https://github.com/tomassasovsky/segno/issues/1179) | [SEG-56](https://aquiles-team.atlassian.net/browse/SEG-56) | Pitch and time DSP core for Speed, Transpose, tempo follow and import Adapt |
| [#1197](https://github.com/tomassasovsky/segno/issues/1197) | [SEG-57](https://aquiles-team.atlassian.net/browse/SEG-57) | Instruments: identities, synthesis patches, MIDI note input and the Instruments page |
| [#1198](https://github.com/tomassasovsky/segno/issues/1198) | [SEG-58](https://aquiles-team.atlassian.net/browse/SEG-58) | Recording to USB, long recordings, atomic publication and recovery |
| [#1199](https://github.com/tomassasovsky/segno/issues/1199) | [SEG-59](https://aquiles-team.atlassian.net/browse/SEG-59) | Settings as ten illustrated destinations; retire the settings tray and Bluetooth |
| [#1200](https://github.com/tomassasovsky/segno/issues/1200) | [SEG-60](https://aquiles-team.atlassian.net/browse/SEG-60) | Backing player: prepared list, transport, routing, foot Backing and Mixer strip |
| [#1202](https://github.com/tomassasovsky/segno/issues/1202) | [SEG-64](https://aquiles-team.atlassian.net/browse/SEG-64) | Shared render recipe, foot Bounce and Save selected audio |
| [#1206](https://github.com/tomassasovsky/segno/issues/1206) | [SEG-65](https://aquiles-team.atlassian.net/browse/SEG-65) | Session-owned MIDI and external-pedal assignments and expression ranges (recall ownership) |
| [#1228](https://github.com/tomassasovsky/segno/issues/1228) | [SEG-66](https://aquiles-team.atlassian.net/browse/SEG-66) | MIDI clock: receive, follow Play/Stop, clock loss, send per output and the MIDI Sync page |
| [#1229](https://github.com/tomassasovsky/segno/issues/1229) | [SEG-67](https://aquiles-team.atlassian.net/browse/SEG-67) | Section 10 proposals, foot Tuner, New Loop by foot and the Custom performance face |
| [#1230](https://github.com/tomassasovsky/segno/issues/1230) | [SEG-68](https://aquiles-team.atlassian.net/browse/SEG-68) | Loop settings frame drifts from the pen on every settings page |
| [#1235](https://github.com/tomassasovsky/segno/issues/1235) | [SEG-72](https://aquiles-team.atlassian.net/browse/SEG-72) | Update vendored miniaudio past 0.11.21 (CVE-2024-41147) and re-enable FLAC backing files |
| [#1254](https://github.com/tomassasovsky/segno/issues/1254) | [SEG-73](https://aquiles-team.atlassian.net/browse/SEG-73) | Output buses: zero non-finite frames and reset the chain, with a notice |
| [#1270](https://github.com/tomassasovsky/segno/issues/1270) | [SEG-74](https://aquiles-team.atlassian.net/browse/SEG-74) | Device and appliance pages: Device/latency, Displays, Restart, Updates from USB, Network |
| [#1276](https://github.com/tomassasovsky/segno/issues/1276) | [SEG-75](https://aquiles-team.atlassian.net/browse/SEG-75) | The console encoder drives the interface: turn moves focus or adjusts, press enters and commits |
| [#1298](https://github.com/tomassasovsky/segno/issues/1298) | [SEG-79](https://aquiles-team.atlassian.net/browse/SEG-79) | Appliance bugs: mixer pan, cropped Off checkbox in recording inputs, 4-bar loop length won't apply |
| [#1323](https://github.com/tomassasovsky/segno/issues/1323) | [SEG-80](https://aquiles-team.atlassian.net/browse/SEG-80) | Song and Band modes: one section at a time, as on the Looper X |
| [#1337](https://github.com/tomassasovsky/segno/issues/1337) | [SEG-81](https://aquiles-team.atlassian.net/browse/SEG-81) | feat(appliance): retry Wi-Fi after a runtime drop, holding off while performing |
| [#1342](https://github.com/tomassasovsky/segno/issues/1342) | [SEG-5](https://aquiles-team.atlassian.net/browse/SEG-5) | Ring carrier firmware updates from the console instead of USB BOOTSEL |
| [#1352](https://github.com/tomassasovsky/segno/issues/1352) | [SEG-7](https://aquiles-team.atlassian.net/browse/SEG-7) | Console negotiates the charger's full 20 V current, with a power-cycle prompt |
| [#1367](https://github.com/tomassasovsky/segno/issues/1367) | [SEG-8](https://aquiles-team.atlassian.net/browse/SEG-8) | spike(appliance): start helper programs without forking the app process |
| [#1459](https://github.com/tomassasovsky/segno/issues/1459) | [SEG-11](https://aquiles-team.atlassian.net/browse/SEG-11) | feat(fx): tempo context and the synced kinds (#887 part 10) |
| [#1467](https://github.com/tomassasovsky/segno/issues/1467) | [SEG-12](https://aquiles-team.atlassian.net/browse/SEG-12) | Octaver down voices are weak on bass at 96 kHz |
| [#1494](https://github.com/tomassasovsky/segno/issues/1494) | [SEG-14](https://aquiles-team.atlassian.net/browse/SEG-14) | fix(power): restart and shut down wait for an update install in progress |
| [#1498](https://github.com/tomassasovsky/segno/issues/1498) | [SEG-17](https://aquiles-team.atlassian.net/browse/SEG-17) | fix(power): a restart also waits for RAUC's own install, after an app restart |
| [#1507](https://github.com/tomassasovsky/segno/issues/1507) | [SEG-18](https://aquiles-team.atlassian.net/browse/SEG-18) | fix(update): the Updates page reports an install RAUC finished after an app restart |
| [#1510](https://github.com/tomassasovsky/segno/issues/1510) | [SEG-20](https://aquiles-team.atlassian.net/browse/SEG-20) | chore(appliance): owner's hands-on console checks for builds .204 and .205 |
| [#1515](https://github.com/tomassasovsky/segno/issues/1515) | [SEG-22](https://aquiles-team.atlassian.net/browse/SEG-22) | perf(engine): run effect chains on more than one core |
| [#1540](https://github.com/tomassasovsky/segno/issues/1540) | [SEG-24](https://aquiles-team.atlassian.net/browse/SEG-24) | test(fx): measure and A/B the drive pedals' aliasing at 48 kHz against 96 kHz |
| [#1590](https://github.com/tomassasovsky/segno/issues/1590) | [SEG-30](https://aquiles-team.atlassian.net/browse/SEG-30) | Screen audit: spacing and alignment on every console screen |
| [#1636](https://github.com/tomassasovsky/segno/issues/1636) | [SEG-32](https://aquiles-team.atlassian.net/browse/SEG-32) | feat(performance): show a raw take's conversion progress while Capture waits for it |
| [#1646](https://github.com/tomassasovsky/segno/issues/1646) | [SEG-33](https://aquiles-team.atlassian.net/browse/SEG-33) | feat(audio): control the audio interface's input settings from the console (Inst/Line, Pad, Air, phantom power) |
| [#1658](https://github.com/tomassasovsky/segno/issues/1658) | [SEG-36](https://aquiles-team.atlassian.net/browse/SEG-36) | design: Penpot frames for the interface's input switches (#1646 part 3) |
| [#1664](https://github.com/tomassasovsky/segno/issues/1664) | [SEG-37](https://aquiles-team.atlassian.net/browse/SEG-37) | fx: the Amp's small-signal gain is up to 4.7 dB under the Looper X's at high drive |
| [#1667](https://github.com/tomassasovsky/segno/issues/1667) | [SEG-38](https://aquiles-team.atlassian.net/browse/SEG-38) | fix(power): survive a shared USB-C charger renegotiating, and log power changes |
| [#1672](https://github.com/tomassasovsky/segno/issues/1672) | [SEG-43](https://aquiles-team.atlassian.net/browse/SEG-43) | Screen audit 2: spacing and alignment on the Loop settings tabs, the Interface row and the readout's Loop panel |
| [#1713](https://github.com/tomassasovsky/segno/issues/1713) | [SEG-44](https://aquiles-team.atlassian.net/browse/SEG-44) | fix(fx): a take plays back what you heard, never dry because its effects do not fit |
| [#1724](https://github.com/tomassasovsky/segno/issues/1724) | [SEG-48](https://aquiles-team.atlassian.net/browse/SEG-48) | perf(fx): measure the console's real effects headroom and set the budget from it |
| [#1755](https://github.com/tomassasovsky/segno/issues/1755) | [SEG-49](https://aquiles-team.atlassian.net/browse/SEG-49) | perf(fx): make every effect cheaper without changing its sound |
| [#1763](https://github.com/tomassasovsky/segno/issues/1763) | [SEG-54](https://aquiles-team.atlassian.net/browse/SEG-54) | bench_fx_cpu: one instance's p99 at 32-frame periods moves by up to 200 ns a frame between runs |
| [#1790](https://github.com/tomassasovsky/segno/issues/1790) | [SEG-55](https://aquiles-team.atlassian.net/browse/SEG-55) | fix(library): Export to USB never sees the drive (the Library still uses the no-drive stand-in) |
| [#1795](https://github.com/tomassasovsky/segno/issues/1795) | [SEG-61](https://aquiles-team.atlassian.net/browse/SEG-61) | fix(appliance): the NVMe drive drops off the bus mid-recording (SN770, APST and ASPM on) |
| [#1797](https://github.com/tomassasovsky/segno/issues/1797) | [SEG-62](https://aquiles-team.atlassian.net/browse/SEG-62) | fix(library): an export reported done leaves 0-byte files on a FAT stick pulled without Eject |
| [#1806](https://github.com/tomassasovsky/segno/issues/1806) | [SEG-2](https://aquiles-team.atlassian.net/browse/SEG-2) | epic: rebuild a performance in Live from raw sources, non-destructively |
| [#1816](https://github.com/tomassasovsky/segno/issues/1816) | [SEG-63](https://aquiles-team.atlassian.net/browse/SEG-63) | Console fails to join an ASUS RT-AX89X with 802.11ax on (status 16) until the router's radio restarts |
| [#1825](https://github.com/tomassasovsky/segno/issues/1825) | [SEG-69](https://aquiles-team.atlassian.net/browse/SEG-69) | fix(engine): a lane added after a take keeps length 0, so its overdubs are never exported |
| [#1846](https://github.com/tomassasovsky/segno/issues/1846) | [SEG-70](https://aquiles-team.atlassian.net/browse/SEG-70) | Stems miss a Stop's fade-out at the arm and across a rate change |
| [#1849](https://github.com/tomassasovsky/segno/issues/1849) | [SEG-71](https://aquiles-team.atlassian.net/browse/SEG-71) | fix(appliance): DNS as on Raspberry Pi OS (NetworkManager writes resolv.conf, no systemd-resolved) |
| [#1855](https://github.com/tomassasovsky/segno/issues/1855) | [SEG-76](https://aquiles-team.atlassian.net/browse/SEG-76) | fix(performance): rebuilt master of a September take ignores its master gain and routing |
| [#1856](https://github.com/tomassasovsky/segno/issues/1856) | [SEG-77](https://aquiles-team.atlassian.net/browse/SEG-77) | spike(perf): what a capture keeps of each loop's history, for placing layers as Live clips (#1806 layer 4) |
| [#1865](https://github.com/tomassasovsky/segno/issues/1865) | [SEG-78](https://aquiles-team.atlassian.net/browse/SEG-78) | feat(settings): the Network page shows the wired connection, not only Wi-Fi |
| [#1866](https://github.com/tomassasovsky/segno/issues/1866) | [SEG-82](https://aquiles-team.atlassian.net/browse/SEG-82) | risk(enclosure): the aluminium enclosure may block the console's Wi-Fi, and the rear wall has no Ethernet |
| [#1867](https://github.com/tomassasovsky/segno/issues/1867) | [SEG-83](https://aquiles-team.atlassian.net/browse/SEG-83) | risk(enclosure): the Pi 5 under the monitor deck has 14–17 mm for a cooler and little airflow; no tower cooler fits |
| [#1874](https://github.com/tomassasovsky/segno/issues/1874) | [SEG-84](https://aquiles-team.atlassian.net/browse/SEG-84) | feat(performance): the recorder's Save to is on no screen, so a take can't record to USB |
| [#1877](https://github.com/tomassasovsky/segno/issues/1877) | [SEG-85](https://aquiles-team.atlassian.net/browse/SEG-85) | feat(fx): the Looper X Harmonizer, from the preset parameters and Segno's pitch shifting |
| [#1884](https://github.com/tomassasovsky/segno/issues/1884) | [SEG-86](https://aquiles-team.atlassian.net/browse/SEG-86) | fix(fx): the Dual Octaver's two vocoder voices sum at a phase that moves with tiny input changes |
| [#1894](https://github.com/tomassasovsky/segno/issues/1894) | [SEG-87](https://aquiles-team.atlassian.net/browse/SEG-87) | fix(fx): the LPF across its range, from an s21lpf level ladder at several cutoffs and resonances |
| [#1900](https://github.com/tomassasovsky/segno/issues/1900) | [SEG-88](https://aquiles-team.atlassian.net/browse/SEG-88) | Foot captions that still wrap: track operations and Spanish Hold lines (FT-3) |
| [#1906](https://github.com/tomassasovsky/segno/issues/1906) | [SEG-89](https://aquiles-team.atlassian.net/browse/SEG-89) | verify(readout): tap-tempo latency and Loop panel reach on the console's 7in |
| [#1914](https://github.com/tomassasovsky/segno/issues/1914) | [SEG-90](https://aquiles-team.atlassian.net/browse/SEG-90) | perf(engine): screen changes and take recording make the app's audio callback run late |
| [#1918](https://github.com/tomassasovsky/segno/issues/1918) | [SEG-91](https://aquiles-team.atlassian.net/browse/SEG-91) | verify(pedal): the Sessions face and the session commands on the console (#1910) |
| [#1936](https://github.com/tomassasovsky/segno/issues/1936) | [SEG-92](https://aquiles-team.atlassian.net/browse/SEG-92) | feat(console): track meters follow the input, and a recording take shows its waveform, progress and bars |
| [#1943](https://github.com/tomassasovsky/segno/issues/1943) | [SEG-93](https://aquiles-team.atlassian.net/browse/SEG-93) | feat(fx): export and import presets, to Internal or a USB drive |
| [#1944](https://github.com/tomassasovsky/segno/issues/1944) | [SEG-94](https://aquiles-team.atlassian.net/browse/SEG-94) | feat(loop): choose the Sync/Band timing track in Loop settings, with the stop-and-switch handoff |
| [#1945](https://github.com/tomassasovsky/segno/issues/1945) | [SEG-95](https://aquiles-team.atlassian.net/browse/SEG-95) | feat(fx): try a preset on a rack before keeping it |
