# Ten-pill chain check — September 24, 2026

The owner confirmed eight LEDs per pill and a shared 5 V / 10 A AUX buck.
There are 80 pill LEDs plus the separate 24-pixel ring. The input chain is
TRACK4, TRACK3, TRACK2, TRACK1, MODE, UNDO, STOP, REC/PLAY, CLEAR, BANK. Data
enters the first eight pills from the right and the final two from the left.

The temporary [diagnostic](../../../firmware/pill_chain_test/README.md) runs
on the existing console PCB, with the ring held dark. Each pill shows red,
green and blue, followed by a physical left-to-right chase. It illuminates
only one eight-pixel pill and one color channel at 32/255 at a time, an
estimated 20.1 mA of additional channel current. It starts dark, has a
100-second automatic shutoff, and accepts immediate STOP/UART-off commands.

The owner observed the running sequence and reported **“Works well”**, then explicitly confirmed **“All ten work correctly.”** This
confirms the connected ten-pill chain at the diagnostic's low brightness;
it does not validate maximum LED load or fabricated v3 hardware.

## Firmware and verification

Console v3 now uses all 80 pixels, the actual logical-to-physical chain map,
the two row directions, and the eight-point spatial curve
`38,92,201,255,255,201,92,38`. The existing 128 brightness cap remains. The
curve averages 57.45%; the [power budget](../../../hardware/segno_wiring.md)
now includes 104 LEDs and distinguishes the old and new PCB power paths.

- All eight host firmware suites pass, including 54 protocol fixtures.
- Production renderer tests exercise both track banks, each physical pill,
  exact brightness, asymmetric direction probes, dark startup and host loss.
- Diagnostic tests exercise every transition across both passes, bounded
  current patterns, STOP/UART off, repeated-run commands and timer wrap.
- Both Pico 2 builds pass: production 71,080 bytes program / 11,168 bytes RAM;
  diagnostic 57,836 / 10,080 bytes.
- Independent reviews found no unresolved issues in the diagnostic or the
  production harness correction. A recovery race identified during review
  was corrected before flashing: bounded programming commands and recovery
  that stops the test process before restoring the installed image.

The temporary diagnostic ELF SHA-256 is
`fbdda3a6339775ddf1b3679fe375f4978e937eff3af7ff73bf20b24fd1b93326`.
The new production v3 ELF SHA-256 is
`3e085807bac905752c3f84b16375a147aaa261ee1d5932107b2962815c9dce67`;
it was **not** flashed onto the old board.

## Restoration

The original deployed controller is protocol 5, firmware 1.7, SHA-256
`36a6868e79d30beddff3450a7237f2e89ba6efecb7185c36126b9cb4e246afbd`.
Its installed ELF and version marker were preserved. A separate timed
recovery was armed before flashing, with a normal cleanup path that restores
the same image and restarts the application. Both complete pattern passes
were received over UART, followed by automatic off at 100,002 ms. SWD
restoration verified successfully; the restored controller emitted protocol 5 /
firmware 1.7 HELLO, the installed ELF hash remained unchanged, and the app
returned to active. The recovery timer was then disarmed. The filtered
[device transcript](pill-chain-log.txt) preserves this evidence.

No PCB, schematic or Gerber changed for this harness correction. The three
previously verified first-fabrication ZIPs remain applicable.
