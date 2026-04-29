# firestore-tests

Rules unit tests for `firestore.rules`. Runs against the local Firestore
emulator — no production data touched.

## One-time setup

```sh
cd firestore-tests
npm install
```

The Firebase CLI must be installed globally (`npm install -g firebase-tools`).
Java 11+ must be on your PATH (the emulator is a Java process).

## Run

```sh
cd firestore-tests
npm test
```

This boots `firestore` + `auth` emulators, runs the mocha suite against
them, and tears the emulators down. ~30 seconds end-to-end.

## What's covered

- The four findings closed in the 2026-04-29 security audit (one
  describe-block per finding)
- Regressions for the prior 2026-04-26 audit fixes (handle XSS,
  legacy PII immutability, `notRestricted()` enforcement, post `flagged`
  update lockdown)
- Baseline sanity checks (legitimate writes succeed, malformed writes
  fail) so a typo that breaks every rule shows up as a flood of failures
  instead of silently passing

## Adding a new test

When you tighten a clause in `firestore.rules`, add at least one
`assertFails` test for the previously-permitted bad write and one
`assertSucceeds` test for the still-permitted good write. The convention
is one `describe` block per audit finding so the regression set stays
readable as it grows.

Use the helpers at the top of `firestore.test.js` (`setUserDoc`,
`setBlock`, `setPost`, `setSave`) to seed state via
`withSecurityRulesDisabled` — that lets a test write the precondition
docs without going through rules first.
