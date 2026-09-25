# Architecture Review

Reviewed the firmware 1.11 ring changes against the saved 1.10 sketch baseline. The reviewed sketch SHA-256 is `765594ca92e2ff0484517a381153a86f8d207f5ffe045bfc0d90588acf40edd8`. Earlier Song queue, pill, app, and native-engine changes were excluded from this review.

## Layer Separation

- Violations found: 0.
- The project is a Flutter/native audio application with a separate Arduino C++ console firmware. This change remains wholly inside the existing firmware rendering layer; no Flutter architecture or application logic changed.
- The firmware remains a thin client. The received state determines activity, color, volume overlay, queue state, and shutdown behavior. The comet's local phase only supplies the established activity animation.
- New helpers have separate duties: `ambientRingColor` reproduces the existing ambient output scale, `paintComet` supplies the spatial pattern, and `showRing` applies a single transfer-boundary channel budget.

## State Management Assessment

- Ring frame rendering: correct. The duty table specifies physical output brightness, while the existing gamma correction affects hue only. This avoids passing the sustained tail through a second nonlinear brightness curve.
- Motion: correct. Interpolation between adjacent circular table entries moves the head toward increasing LED indices and remains continuous across pixel 39 to 0. The existing elapsed-time phase calculation now uses the selected 1100 ms revolution.
- Freeze and overlay restoration: correct. The existing view cache is unchanged. Active frames always repaint; the stopped state repaints once with the saved phase/color, then retains the pixels. A volume overlay changes the view key, so ending it restores the appropriate comet or breathe state.
- Link loss and goodbye: correct. The existing dark view clears all 40 pixels, and output passes through the same transfer helper.
- Output scaling: correct. The installed Adafruit driver implements brightness 255 as direct channel output, so `getPixelColor` returns the actual stored duties. `ambientRingColor` uses the driver's previous exact `(channel * 97) >> 8` calculation, preserving startup, volume, and breathe output.
- Current budget: correct at the software model level. Every production ring transfer now uses `showRing`; only that helper calls `ring.show`. Summing actual channel duties and scaling only above 11520 preserves the former 40 × 3 × 96 full-white ceiling. Integer division cannot exceed the limit. Subsequent refreshes do not progressively dim a limited frame because its sum is already within budget. The independent pill budget remains unchanged.
- Runtime behavior: no new allocation, blocking operation, interrupt masking, or device I/O was added to rendering. The extra bounded buffer pass covers 40 pixels; the existing Adafruit transfer and encoder/link servicing remain in place.

## Dependency Direction

- Direction violations: 0.
- No includes, libraries, packages, or cross-module dependencies were added.
- The sketch still uses the existing Adafruit ring driver and NeoPixelBus pill driver. No second driver or configuration mechanism was introduced.
- The sketch diff changes its advertised firmware minor version only; the protocol remains version 7 and no message encoding or decoding changes appear in this update. The provided baseline contains the sketch and README, not a second copy of protocol files, so this review does not claim a separate byte-for-byte protocol-file comparison.

## Package Structure

- Console firmware: complete for this scope. The update extends the existing renderer without creating unnecessary modules or abstractions.
- Test and documentation updates were still being completed by other agents during this source review and are outside this architecture verdict. No tests or device actions were performed by this reviewer.

## Verdict

Architecture is clean. No actionable findings in the reviewed firmware changes. This source review establishes software behavior and the configured current model; physical appearance and electrical consumption require device observation and are not claimed here.
