# Secondary display ownership

Issue #1115, following #1114. Implementation is authorized; merging remains
human gated.

Move secondary-window lifecycle, waveform delivery and readout retry out of App
into one application owner. App supplies selected-track identity, pedal mode and
bank, device connectivity and shutdown presentation. Preserve the accepted
selected-track waveform and existing failure notices without changing layouts.

Keep waveform delivery driven by repository events with a trailing rate limit;
do not introduce a second clock that resamples moving playback positions. Retain retries
for failed delivery and reject stale failures after selection or lifecycle
changes. Reopening a window must send its current waveform and readout again.

Serialize window transitions and honor the latest enable/disable intent. Await
an opening already in progress before completing disposal. A platform close
failure must not create a recursive retry loop, strand cleanup or escape as an
unhandled disposal error. Preserve the existing AppRuntime teardown handler.

Use the existing window service and repository seams. No generic lifecycle
framework, dependency, native change or hardware validation claim. Verify the
owner failure cases and unchanged App/LooperPage behavior, then app coverage,
strict analysis, explicit formatting and a nonempty Bloc scan. Independent
review, including read-only Claude, and current-head CI gate publication readiness.
