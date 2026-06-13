# Toska — Pre-Launch Review Brief (for a fresh Claude Code session)

> Paste this whole file as your first message, then execute it. You are doing a
> **pre-launch, App-Store-submission-readiness review** of the Toska iOS app.
> Your job is to find anything that would (a) crash, (b) leak/de-anonymize a
> user, (c) get rejected by App Review, (d) break the crisis-safety path, or
> (e) violate the brand wedge — and to VERIFY each finding against the running
> code, not assume. Be adversarial. Default to "prove it's broken," not "looks
> fine."

---

## 0. What Toska is (so you judge the right things)

Anonymous peer-support app for people going through breakups — short written
reflections, no real names, no profile photos, **no follower-count-as-status,
no DMs/chat, no dating/matching, no days-since-breakup counter**. Those four
absences are deliberate brand decisions; if you find code re-introducing any of
them, that is a FINDING, not a feature. SwiftUI + Firebase (Auth, Firestore,
Cloud Functions, App Check via App Attest, FCM).

## 1. Ground truth & traps (read before touching anything)

- **`IMPROVEMENTS.md` is a STALE snapshot.** ~95% of its 126 findings are
  already fixed. Treat it as a checklist of *things to verify*, never as a list
  of open bugs. Confirm each against current code before acting.
- **SourceKit shows false "No such module 'FirebaseAuth/FirebaseCore'" and
  bare-slash-regex errors.** These are PERSISTENT FALSE POSITIVES. The build
  succeeds. Never report them; never "fix" them.
- **Projects:** prod = `toska-4ebf4`, staging = `toskastaging`. Debug build →
  staging, Release build → prod.
- **App Check:** prod ENFORCES on Firestore AND Auth; staging UNENFORCED (so on
  staging, firestore.rules is the *sole* perimeter — judge rules accordingly).
  Callables enforce App Check regardless of project.
- **Auth for tooling expires constantly.** `firebase` CLI and gcloud ADC both
  need periodic interactive re-login (`firebase login --reauth` /
  `gcloud auth application-default login`). You CANNOT do these — they need a
  TTY/browser. If you hit an auth wall, tell the user to run it with a leading
  `!` in their prompt. There is no service-account key in the repo (by design).
- **firebase-admin only resolves from `functions/node_modules`.** Run admin
  scripts as: `NODE_PATH="$PWD/functions/node_modules" node scripts/<x>.js`.
- **Builds:** to RUN signed on device/sim, build SIGNED (NOT
  `CODE_SIGNING_ALLOWED=NO`, which causes keychain -34018 login failures).
  For a pure compile check, `CODE_SIGNING_ALLOWED=NO` is fine. Build to `/tmp`,
  never the iCloud Desktop path (codesign chokes). Device install needs the
  hardware UDID via `xcodebuild -showdestinations`, `-allowProvisioningUpdates`.

## 2. The security model you are auditing (three layers)

1. **Client** (SwiftUI) — optimistic, NEVER trusted. May warn the user.
2. **firestore.rules** — whole-document perimeter; schema locks; ownership;
   block-visibility; moderation-visibility. Helpers: `notBlockedBy`,
   `moderationVisible`, `validHandle`.
3. **Cloud Functions** (Admin SDK) — OWNS counters, `moderationStatus`,
   user `restriction`. Clients can never write these. Idempotency via
   `claimedTransaction` / `claimTriggerEvent`. Deletion cascade = GDPR.

The PII/name detector is DUPLICATED on purpose: `functions/moderation.js`
(server HOLD decision) and `toska/ContentModeration.swift` (client warning),
kept in sync and PINNED by `firestore-tests/detector-parity.mjs` (compiles the
Swift detector standalone via swiftc and diffs verdicts). If you change one
detector, the other must match or parity fails.

## 3. Run the existing verification (do this FIRST, before reading code)

```bash
cd <repo>
# Moderation unit tests (PII/crisis/abuse detector — server):
cd firestore-tests && npm run test:moderation        # expect ~154 passing
# Rules + hostile-user (needs Java/emulator):
npm run test:rules                                    # expect ~191 passing
# Client↔server detector PARITY (needs macOS + swiftc):
npm run test:parity                                   # expect 31/31
# Adversarial corpora (run each; they encode prior attacks):
for f in crisis-redteam crisis-parity detector-fuzz tampered-client-sweep \
         ratelimit-burst hostile-user; do echo "== $f =="; done
# (inspect firestore-tests/*.mjs / *.test.js for the full set + how to run)
```
Then compile the app (expect **BUILD SUCCEEDED**, ignore SourceKit):
```bash
xcodebuild -project toska.xcodeproj -scheme toska -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```
A red suite or a failed build is your highest-priority finding. If all green,
proceed to the dimensional review.

## 4. Review dimensions (each must end in a VERIFIED verdict)

For every finding: `file:line`, what's wrong, how it's reachable by a real
user (not just a tampered client), severity, and a concrete repro or test.
Then ADVERSARIALLY verify it — try to refute your own finding before reporting.

**A. App Store rejection risk (highest leverage — this is what blocks launch)**
- Guideline 1.2 (UGC): is there content filtering (the moderation gate), a
  Report action on every post/reply/profile, Block (Settings → Blocked Users),
  and a EULA/Terms accepted at signup with a zero-tolerance clause? Confirm the
  Terms/Privacy URLs return 200 (`curl -sI https://www.toskaapp.com/terms`).
- 5.1.1(v): in-app account deletion reachable (Settings → Delete Account)?
- 4.8: is `SignInWithAppleButton` (official) used, not a hand-drawn button?
  Is the Google button branding-compliant?
- Age gate: 17+, server-enforced (`confirmAdult` Cloud Function), not just a
  client checkbox.
- Privacy: nutrition labels match the privacy policy (you can't see ASC — flag
  it as an owner checklist item).

**B. Anonymity / de-anonymization (the core promise)**
- Can a real name publish? Re-run the detector against fancy-text
  (Mathematical Alphanumeric `𝐒𝐦𝐢𝐭𝐡`), fullwidth, Cyrillic/Greek confusables,
  leetspeak, spaced-out (`s a r a h`), zero-width joiners. Parity must hold.
- Do push notifications or share-card pasteboard leak post text / handles?
  (Pushes must be neutral; pasteboard copies must be `.localOnly` + expiring.)
- Does any new feature expose a stable cross-post identity?

**C. Crisis-safety path (the differentiator — treat as P0)**
- Does the in-app gentle check-in fire on the SAME (normalized/evasion-hardened)
  inputs the server holds on? (`crisisLevel(for:)` ↔ `matchesCrisisPhrase`.)
- Crisis-alert DELIVERY: is `system/crisisAlertRecipients` seeded in prod AND
  does at least one recipient have an `fcmToken`? Run:
  `NODE_PATH="$PWD/functions/node_modules" node scripts/setupCrisisAlerts.js`
  (needs fresh ADC). No token = alerts silently DROP = critical for a crisis app.
- Admin crisis queue must not hide old unreviewed posts behind newer reviewed
  ones (loadCrisis paginates — confirm it still does).

**D. Backend integrity**
- Counters: can a client write `likeCount`/`replyCount`/`moderationStatus`/
  `restriction` directly? (Rules must forbid; functions own them.) Test via
  `tampered-client-sweep`.
- Idempotency: double-delivery of a trigger increments once? deletion cascade
  leaves no residue (GDPR)? rate limiters fail CLOSED on Firestore error?
- Admin side: are all admin reads `isAdmin()`-gated, the audit log
  append-only/unforgeable, admin.html XSS-safe (no `innerHTML` with user text)?

**E. Crash / data-loss**
- Force-unwraps on network/optional data; array index math; draft persistence
  on background; onboarding rollback if one of two writes fails; thread-build
  pure functions (`buildThreadedReplies`/`flattenReplies`) on malformed trees.

**F. Brand-wedge regressions**
- Any re-introduction of DMs, follower-count-as-status, days-since counter, or
  matching/dating. Any chat affordance. These are findings.

**G. Accessibility (review point for a "reading app")**
- Dynamic Type on content text (`Font.custom(..., relativeTo:)`), VoiceOver
  labels on icon-only buttons/toggles. Lower severity but real for 1.x review.

**H. Cost (lower priority pre-launch)**
- Read-amplifying paths (profile eager-loads all tabs? feed refresh query count?).
  Note but don't block on these.

## 5. Output format

Produce a single ranked report:
- **🔴 Blockers** (crash / de-anon / rejection / crisis-path broken) — each with
  file:line, reachable-by-real-user proof, repro, and fix recommendation.
- **🟠 Should-fix-before-launch** (safety/correctness, not strictly blocking).
- **🟡 Post-launch** (maintainability/cost/polish).
- **✅ Verified-solid** — explicitly list the perimeters you tested and found
  holding, so the owner knows what was actually checked vs skipped.
- **Owner-only checklist** — things you can't verify from code (ASC privacy
  labels, prod demo account, device FCM-token registration, real-device sign-in).

State plainly what you did NOT test and why. Do not claim "fully secure" or
"unhackable" — no app is. Report what holds and what you couldn't reach.

## 6. Known-current state (as of last review — verify, don't trust)

- Backend security fixes deployed to prod+staging (math-alpha de-anon fix,
  reconcile fail-closed, report field caps). Suites green: 154/191/74, parity 31/31.
- `system/crisisAlertRecipients` seeded in prod BUT admin had no `fcmToken`
  (alerts undeliverable until admin signs in on a real device w/ notifications).
- Admin crisis queue paginates (coverage fix). Block copy says "posts or replies".
- Official `SignInWithAppleButton` in use; Google button uses a placeholder "G"
  glyph (low-risk branding gap; official asset not yet bundled).
- Outstanding owner items: prod demo account, privacy nutrition labels, 17+
  rating, real-device sign-in smoke test, device FCM-token registration.
