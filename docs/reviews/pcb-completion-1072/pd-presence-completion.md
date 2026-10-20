<!-- cspell:words STUSB IOVDD SDA SCL RDO PDOs UM millis -->
# Console CTRL presence and PD status completion

Implemented and verified locally on September 22, 2026, then published in
[runtime PR #1082](https://github.com/tomassasovsky/segno/pull/1082) at
`92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d`. The files described below belong
to that runtime revision, not to the firmware snapshot on the hardware branch.
Use that runtime's E9 workaround for an A2 Pico 2; the hardware branch's old
presence implementation is unsuitable. Later silicon also works with the
workaround. This closes the software omissions in the earlier console audit.
No device was flashed or reconfigured. Runtime integration and assembled
verification remain open; these results do not establish physical operation.

## CTRL presence

`firmware/console_board/console_presence.h` applies Raspberry Pi's E9
workaround: the input buffer is disabled between samples and enabled only
around the actual input read. Interrupt state is saved/restored across that
short sequence, so a UART interrupt cannot accidentally extend the enabled
window. Initialization leaves the pin as an input with its pull-down enabled,
then allows 1ms to clear a latch left by a warm restart. It never drives the
jack contact low. The console retains 50ms presence debounce and a 10ms sample
cadence.

The host model first reproduces the old held-high behavior, then checks a
warm restart and empty-to-plugged transitions on both inputs. It also checks
that input enable ends disabled, an already-masked caller remains masked,
and neither pin is ever driven. This verifies software sequencing, not the
physical jack/cable settling time. The assembled A2 unit still needs an
insert/remove test. Primary source:
[RP2350 datasheet, erratum E9](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf).

## PD observations, without configuration writes

`console_pd.h` uses the installed Arduino core's bounded I2C interface on
J23 GP0/GP1, at 100kHz and address 0x28. It reads only the attachment,
VBUS/policy status and requested-data-object registers. Every transaction
has a 2ms timeout. An initial/attachment settling interval of 500ms precedes
the contract check; polling runs every 250ms. Two matching RDO snapshots,
with attachment and readiness rechecked, reject a contract that changes
during the read. A read failure clears old electrical values immediately.
Reads recover on a subsequent settled attachment; no indefinite retry loop
holds up controls.

The installed SparkFun 1.1.5 library was inspected before choosing direct
core reads. Its `begin()` calls its NVM reader, which also writes volatile
configuration and contains waits without a bound. Its configured PDO getters
do not report an accepted source contract. Reusing those calls would change
the required status-only behavior. Sources:
[SparkFun library](https://github.com/sparkfun/SparkFun_STUSB4500_Arduino_Library),
[Arduino-Pico Wire implementation](https://github.com/earlephilhower/arduino-pico/blob/6.0.0/libraries/Wire/src/Wire.cpp).

**Voltage remains unknown.** ST's current UM2650 reserves register 0x21.
Although one ST demo printing function uses it, that demo's `Get_RDO` path
disables this interpretation and derives voltage from captured source PDOs.
Those are negotiated before this AUX-powered Pico has booted, and can be
overwritten before it reads them. RDO indexes source PDOs, not the three
configured sink PDOs. The monitor therefore never treats configuration or an
undocumented byte as evidence of 20V. A meter/PD analyzer must establish the
actual voltage; a reported 5A request alone does not establish 100W.
Sources: [ST UM2650](https://www.st.com/resource/en/user_manual/dm00664189-the-stusb4500-software-programing-guide-stmicroelectronics.pdf),
[ST reference driver](https://github.com/usb-c/STUSB4500/blob/master/Firmware/Project/Src/USB_PD_core.c).

## End-to-end reporting and validation

Pedal protocol 6 adds type 0x05, with six bytes: state, flags, voltage in
millivolts (little endian), operating current in milliamps (little endian).
States are unknown, unattached, negotiating, contract, read error and stale.
Only a contract can carry current or mismatch. Zero voltage means unknown
and becomes `null` in Dart. Current is requested operating current, not
measured consumption. C and Dart both reject contradictory states and
out-of-range units.

The console emits status once per second. `PedalRepository` exposes a
deduplicated status stream and current getter, and writes changes to the
existing diagnostics log. A status report only counts after a compatible
hello. Three missing reports invalidate the observation independently of
hello traffic; disconnects, firmware changes and failed reads clear old
values. No PD observation controls a power cutoff.

- All seven firmware host suites pass, including 54 shared C/Dart fixtures.
- PD tests cover startup, attachment, partial reads, errors at every snapshot
  transaction, reset/negotiation, disconnect during a read, changed RDO,
  mismatch, invalid fields, recovery, staleness and 32-bit clock rollover.
- All 228 pedal-repository tests pass. Coverage is 602/613 lines, **98.21%**,
  above the package's 96% requirement. Analyzer and formatting pass.
- Bloc lint reports zero issues across 30 files. The CLI skips hidden
  worktree paths, so it ran on a byte-verified temporary copy of package
  sources, tests, lockfile and analysis options. No lint rules were disabled.
- The integration agent compiled both real RP2350 MCU targets with the
  pinned core/dependencies recorded in the console README.

Host tests do not emulate I2C electrical edges, USB-PD source behavior or E9
analogue leakage. Hardware acceptance remains necessary for J23 wiring,
actual negotiated power and CTRL hot-plug behavior.
