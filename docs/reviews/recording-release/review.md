# Segno Transfer free release — build review

## Result

The owner approved publishing the Mac companion on GitHub with free local
signing. The release adds an Apple Silicon disk image, installation instructions,
Applications shortcut, license and checksum. Matching `transfer-vVERSION` tags
test, build and publish the app without changing the firmware release channel.

The source PR retains `autonomy:merge-gate`. Publishing the requested companion
release and merging its source are separate actions.

## Review scope

Base: `848f1337251989f849c7851f72b6126b5c1712ea`. The release reviews cover the
companion source, tests, helper, package scripts, workflow and documentation.
Independent roles completed Architecture, VGV, Test Quality, Simplicity and PR
Readiness. The bug-focused review also traced the complete source through app
state, audio loading, repository, SSH process and appliance helper boundaries.

## Corrections

Review reproduced a quit-time resource leak: cancellation returned before a
streaming worker reaped its child process and removed temporary files. Accepted
quit requests now wait for that cleanup outside the main actor, including
previews already closed or replaced. Ordinary preview closing stays responsive.

The shutdown regression holds two previews' cleanup independently and releases
the newest first. It verifies that shutdown still waits for the older preview.
An isolated mutation that forgets earlier cleanup fails this test. Separate
process-level reproductions confirm both active-preview quit and close-then-quit
exit with the child gone and its exact response/error files removed.

## Validation

- All 25 Swift tests and 14 appliance-helper tests pass locally. The final
  strengthened shutdown test also passes with all four streaming tests.
- Swift formatting and warnings-as-errors compilation pass.
- Nine isolated actual-script packaging failure/version cases pass.
- The corrected app builds and packages successfully. Read-only image inspection
  verifies its signature, exact built executable/helper, shortcut, installation
  instructions, license and checksum.
- Earlier real appliance verification covers selected downloads, custom names,
  matching source hashes, streaming startup and seeking. Native UI acceptance is
  local evidence, separate from hosted CI.

All verified review findings are resolved. See the [raw role reports](raw/) for
their scopes and evidence. Hosted checks must pass on the final pushed source
before tagging; published assets must then be downloaded and verified. The PR
records those final external results and the exact reviewed head.
