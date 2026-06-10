# Toska — End-to-End Verification Brief (for a fresh Claude session)

Paste everything below into a new Claude Code chat opened at `/Users/tesssalinaro/Desktop/toska`.

---

You are a principal iOS/Swift + Firebase security engineer doing an **independent end-to-end verification** of the Toska app. Toska is an anonymous breakup-talk social app ("Reddit, but only for breakups") — a SwiftUI iOS client + Firebase backend (Auth, Cloud Firestore, Cloud Functions, APNs/FCM push, App Check via App Attest). Sign in with Apple / Google / email. Two environments: prod `toska-4ebf4`, staging `toskastaging`; Debug builds → staging, Release → prod.

Your job is **not** to re-run the prior audits from scratch. It is to **verify, end to end, that every security measure and every feature actually works — and that the three layers agree with each other.** Treat all prior writeups as *claims to be checked*, not facts.

## Read these first (they are the map, not the truth)
- `AUDIT.md` — the original 18-finding audit + the M-1 reply-hold feature.
- `AUDIT-2.md` — the re-review: 11 new findings (N-1…N-11), their fixes, and **N-11 — the App Check state was misreported by a buggy tool**. The verified truth: **prod Firestore App Check = ENFORCED** (since 2026-04-24), prod Auth = UNENFORCED, staging both UNENFORCED. Confirm this yourself with `node functions/setAppCheck.js` (read-only; needs `gcloud auth application-default login`).
- `firestore.rules` (~1,130 lines), `functions/index.js` (~4,200 lines), `functions/moderation.js`.
- Test suites: `firestore-tests/` (rules + moderation), `functions-tests/` (Cloud Functions). `firestore-tests/full-e2e.mjs` is a live-staging end-to-end rig.
- Client: the `toska/` Swift sources.

## The three layers must AGREE — this is the core of the task
1. **Swift client** — optimistic UI, reads/writes Firestore directly, calls 3 callables.
2. **`firestore.rules`** — whole-doc allow/deny; for prod Firestore, App Check is a *second* gate in front of it (enforced). For staging it is NOT — rules are the sole perimeter there.
3. **Cloud Functions** (Admin SDK, bypass rules) — own every security-critical write: counters, moderationStatus, restriction, confirmedAdult, notification enrichment.

For each invariant, check it holds in **all** the layers that should enforce it, and that a write shape the client produces is accepted by the rule and handled by the trigger. Flag any drift.

## What to verify (functionality + security, and how they work together)

**A. Run the existing suites** and confirm green, and that they actually execute (not skipped):
- `cd firestore-tests && npm test` → expect 142 moderation + 175 rules (the rules suite must include `hostile-user.test.js` — verify it's wired in `package.json`, not orphaned).
- `cd functions-tests && npm test` → expect ~62.
Report exact counts. If any suite skips a file, that's a finding.

**B. Run the live end-to-end rig** (`firestore-tests/full-e2e.mjs`) against staging and read its pass/fail summary. It creates two accounts and exercises: clean post → `validatePost` promotes to live; clean reply → live; **PII reply → HELD at `pending_review` (M-1), not deleted**; counters (like/reply/follow/repost) converging via triggers; held reply NOT inflating `replyCount`; block enforcement; and the adversarial denials (post-as-someone-else, self-grant confirmedAdult, inflate counters, self-unrestrict, read others' `/private`, forge notification, self-publish `moderationStatus=live`, the **N-1 reply-update byline spoof**, read admins/adminAuditLog). Confirm every check passes; investigate any that don't.

**C. The M-1 held-reply state machine** — the highest-complexity feature. Walk these combinations and confirm correct behavior across functions + rules + client:
- held reply that then gets reported / whose parent post is deleted (does the new `onPostDeletedCleanupSubtree` trigger drain held PII replies? — N-2) / by a now-blocked or deleted user;
- race between `setReplyLive` and a concurrent edit/delete; double-promotion; promotion-after-removal;
- `onReplyVisibilityCountAdjust` under rapid hold→live→remove (replyCount must not inflate or go negative);
- the collection-group query and the reply-likes read rule must not leak held content;
- client: a held reply shows the "under review" banner, is hidden from a second account, and **does not** open a normal post-detail page (N-3).

**D. The atomic counter system (F-1)** — `claimedTransaction` + `retry`. Verify idempotency across retries, the "read target first" short-circuit on a deleted parent, and that no path drifts a counter permanently. Confirm all the counter triggers use it (not the old `claimTriggerEvent`).

**E. The deletion cascade (F-2) + `cleanupLikesForUid`** — partial-failure resume, idempotency, the new `onPostDeletedCleanupSubtree` (N-2) draining a deleted post's replies/likes/reflections (incl. held PII replies — GDPR).

**F. App Check reality (N-11)** — confirm prod Firestore = ENFORCED, prod Auth = UNENFORCED, staging both UNENFORCED via `node functions/setAppCheck.js`. Reason about what each state means: on **staging** rules are the sole perimeter (so the rules-level findings matter there and for a tampered build of the real app); on **prod Firestore** App Check is a real second gate. The remaining owner action is narrower than the original audit implied: enforce **prod Auth** + **staging** after a verified-request-rate pre-flight + real-device App Attest confirmation.

**G. iOS / on-device** (needs the Xcode build — build to a NON-iCloud-synced DerivedData path, e.g. `/tmp`, or codesign fails on `~/Desktop`'s file-provider xattrs): confirm the client fixes compile and behave — drafts in the protected `DraftStore` (N-4, NSFileProtectionComplete + backup-excluded, migrates legacy UserDefaults), app-switcher privacy cover (N-5), pasteboard expiry (N-6), feed like-flicker suppression (N-7), held-reply drill-down disabled (N-3). The 3 callables (confirmAdult/giphyProxy/reconcileMyCounts) enforce App Check and need a **real device** (App Attest doesn't work on the simulator).

## How to work
- **Verify, don't just reason.** Run the suites and the E2E rig. Where you suspect a gap, write a failing test that demonstrates it before claiming it.
- Distinguish "confirmed working" from "found a gap." For each gap: ID + severity, repro (ideally a test), the layers affected, and a proposed fix.
- **Separate the unverifiable** (anything needing the Firebase console, IAM, App Check metrics dashboard, or a real device) into its own clearly-labeled section.
- Pay special attention to the **seams**: client write-shape vs rule `hasOnly` vs trigger expectation; the staging-vs-prod App Check asymmetry; and the held-reply state space.
- Write your findings to a new file `AUDIT-3.md` at the repo root. Do not edit `AUDIT.md` or `AUDIT-2.md`.

Begin by reading `AUDIT-2.md` and confirming the App Check state and the test wiring, then run the suites and the E2E rig.
