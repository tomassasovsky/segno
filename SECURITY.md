# Security policy

## Supported versions

Segno has no stable release yet. Security fixes go into the development
branch and ship in the next appliance image. Only the latest published image
is supported.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:
[Report a vulnerability](https://github.com/tomassasovsky/segno/security/advisories/new).
Do not open a public issue for a security problem.

Include what you found, the affected component (application, audio engine,
appliance image, update service, console firmware), the steps to reproduce it,
and the version from **Settings > About** or `/etc/segno/build-version` on the
appliance.

Segno is maintained by one person, so responses are best effort. Once a fix
is available, the advisory can be published with credit to the reporter if you
want it.

## Scope

The appliance is designed to run on a private network that the musician
controls. Reports are most useful when they concern:

- The update path: how images are fetched, verified and installed.
- Services the appliance exposes on the network, such as the recording
  download used by Segno Transfer.
- Files the appliance reads from USB drives or imports into its library.
