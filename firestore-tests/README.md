# firestore-tests

Two test surfaces for the Firestore layer:
- **`npm test`** — rules unit tests against the local emulator. No live
  data touched. ~30s.
- **`npm run e2e`** — end-to-end smoke test against live `toskastaging`.
  Creates and deletes a throwaway user. ~10s.

## One-time setup

```sh
cd firestore-tests
npm install
```

For `npm test`: Firebase CLI installed globally
(`npm install -g firebase-tools`) and Java 21+ on PATH (the emulator is
a Java process).

For `npm run e2e`: `gcloud auth application-default login` so the
firebase-admin SDK can resolve credentials.

## Rules unit tests — `npm test`

Boots `firestore` + `auth` emulators, runs the mocha suite, tears them
down. Each test exercises a single rule clause via `assertSucceeds` /
`assertFails`.

Coverage:
- The findings closed in the 2026-04-29 security audit (one describe
  block per finding)
- Regressions for the prior 2026-04-26 audit fixes (handle XSS, legacy
  PII immutability, `notRestricted()` enforcement, post `flagged`
  update lockdown)
- Baseline sanity (legitimate writes succeed, malformed writes fail)
- The 2026-04-30 `hasConfirmedAdult()` gate

## End-to-end test — `npm run e2e`

Creates a real Auth user in `toskastaging`, writes a complete user doc
via Admin SDK (mimicking what a successful signup + confirmAdult call
produces), signs in as that user via the Firebase Web SDK, attempts a
post write (asserts success), strips `confirmedAdult` from the user
doc, attempts another post write (asserts denial), then cleans up.

Self-cleaning even on partial failure. Refuses to run against any
project other than `toskastaging` via the `GCLOUD_PROJECT` env var
guard at the top of the script.

What this proves that `npm test` alone doesn't:
- Real Auth + real Firestore + real deployed rules all align with
  what the emulator-based unit tests claim.
- The `hasConfirmedAdult()` rule actually denies writes against the
  live ruleset, not just the local emulator copy.

What this still doesn't prove:
- The iOS-side `confirmAdult` callable invocation. For that, sign up
  in the simulator and verify
  `users/{uid}.confirmedAdult` afterward.

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
