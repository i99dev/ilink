# Security Policy

iLINK runs on vehicle head units and can dispatch vehicle commands. Please
treat findings in the safety dispatcher, permission grants, mini-app sandbox,
native bridge and update verification as high impact.

## Supported versions

Security fixes land on `master` and ship in the next release. Only the latest
published release is supported; there are no maintained backport branches.

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.** Public issues are visible to
everyone, including on unpatched vehicles.

Use GitHub's private vulnerability reporting on this repository: go to the
**Security** tab and choose **Report a vulnerability**. That opens a private
advisory visible only to maintainers. If that option is unavailable to you,
contact a maintainer privately through a contact method they have published, and
say only that you have a security report — keep the details out of the first
message until a private channel is open.

Please include, as far as you can establish it:

- Affected version, head-unit model and firmware build.
- What an attacker gains, and what access they need to start (physical access,
  an installed mini-app, a crafted archive, a network position).
- Reproduction steps or a proof of concept.
- Whether a vehicle actuator, stored credential or permission grant is reachable.

## What to expect

Reports are acknowledged and triaged as maintainer time allows; this is a small
project without a staffed on-call rotation, so please allow a reasonable window
before disclosing. We will confirm the finding, agree a fix and a disclosure
timeline with you, and credit you in the advisory unless you prefer otherwise.

## Scope

In scope: this repository's application code, the bundled offline command
tables, mini-app archive validation and permission model, the ADB and native
bridges, and update package verification.

Out of scope: vulnerabilities in BYD firmware or head-unit hardware, in
third-party services the app can optionally reach, and in bundled third-party
components — report those to their own maintainers. Findings that require
already-granted administrator scopes, an unlocked developer-enabled unit, or
physical disassembly should say so plainly.

## Safe testing

Test only on a vehicle you own or are authorized to test, parked in a safe
place, and never while driving. Do not test against other people's vehicles.
Do not include VINs, precise locations or other personal data in a report;
redact them from logs and screenshots first.
