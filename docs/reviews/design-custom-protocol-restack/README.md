# Custom mode console protocol

The current UART console now recognizes Custom as mode value 3 and renders
its Mode indicator amber. Protocol version 6 retains the 19-byte STATE and
three-byte HELLO. Other mode values, bank selection, track LEDs, ring activity
and external CTRL contacts keep their existing wire meaning.

Base: `45ec78fb8b2b5e2e118b910677c172646ca4f761`.
Original proposal parent: `3fd9bf050c420df19d01023c390a8fd5d546ac7e`.
The [source binding](source.json) records all 15 changed source, test and fixture
paths. The old proposal used retired MIDI pedal firmware; this reconstruction
ports its Custom-mode intent to the current console instead.

## Connection behavior

Only a matching version 6 HELLO admits controls and outbound STATE. Older or
newer firmware remains explicitly incompatible. Reconnection sends the current
state without replaying input edges. No protocol fallback or retired firmware
path is restored. The existing connection-loss and CTRL ownership rules remain.

## Verification

- Application suite: 2,310 passing tests and six existing skips; 90.41% coverage
  with the CI exclusions, above the 90% requirement. Source stayed unchanged.
- Full pedal repository: 202 passing tests; 97.71% coverage, above 96%.
- Firmware contract: 47 fixtures pass. The C++ host test compiles the actual
  console sketch and inspects rendered Custom, track and Bank indicators.
- Formatting, strict analysis, actual Bloc lint over 663 files and whitespace
  checks pass. Unchanged native audio and other-package evidence is reused only
  after checking source and dependency hashes.
- Independent literal byte expectations check both C and Dart. They are separate
  from generated fixtures, so agreement between two encoders is not the oracle.
  The original 44 unaffected fixtures are unchanged; HELLO changes only its
  version and checksum, and two Custom fixtures are added.

One independent reviewer covers the complete source and five quality roles;
a separate adversary checks the frozen wire and connection contract. Review
reports identify their exact source binding and any limits. Publication, CI and
the existing human merge gate are separate steps.

## Scope

This is the console protocol prerequisite. Custom action dispatch and its setup
entry follow in PR #1030; this slice does not advertise a working Custom app
mode. It implements the accepted amber mode color without a design departure.
Physical UART behavior, LED appearance and appliance deployment remain device
checks. No hardware was flashed, no build deployed, and no PR merged.
