# Toska — Full App Review Brief (for a fresh Claude Code session on Fable 5)

> **Run this on Fable 5** (the latest Claude model). In the new Claude Code session: `/model` → select **Fable 5** (`claude-fable-5`) before pasting the prompt below. Open the session at `/Users/tesssalinaro/Desktop/toska`.

Paste everything under the line into a new chat.

---

You are a principal engineer doing a **complete, independent, adversarial review of the entire Toska app** — security, correctness, moderation quality, crisis safety, on-device behavior, performance, App Store readiness, and code quality. This is broader than a security audit: review the *whole* product, including parts that prior audits may not have touched. Treat all prior writeups as **claims to verify, not facts**, and **verify by running things**, not just reading.

## What Toska is
An anonymous breakup-talk social app — "Reddit, but only for breakups." SwiftUI iOS client (~22k lines, ~41 files) + Firebase backend (Auth [Apple/Google/email], Cloud Firestore, Cloud Functions [~4,200 lines], APNs/FCM push, App Check via App Attest). Surface: posts ("moments"), threaded replies, feed/explore, follow, block, drafts, likes/saves (of posts and replies), reposts (incl. reply-reposts), reports, anniversary/daily/weekly memory cards, a content-moderation pipeline, and a crisis-detection/safety system. DMs and "feeling circles" were cut. Pre–App Store launch.

**Three layers that must agree:** (1) the Swift client (optimistic UI, direct Firestore reads/writes, 3 callables); (2) `firestore.rules` (~1,130 lines, whole-doc allow/deny); (3) Cloud Functions (Admin SDK, bypass rules, own every security-critical write — counters, moderationStatus, restriction, confirmedAdult, notification enrichment, crisis handling). The moderation **name/PII detector exists in BOTH `functions/moderation.js` and the Swift client** (`FeedView.swift`) and they are hand-kept-in-sync — verify they actually agree.

**Two environments:** prod `toska-4ebf4`, staging `toskastaging`. Debug→staging, Release→prod.

## Current deployed/verified state (as of 2026-06-11 — confirm it)
- **App Check: prod Firestore = ENFORCED, prod Auth (identitytoolkit) = ENFORCED; staging = UNENFORCED** (so on staging, rules are the sole perimeter; the node E2E rigs rely on that). Confirm with `node functions/setAppCheck.js` (needs `gcloud auth application-default login`, separate from `firebase login`).
- **Tests (all should be green):** `cd firestore-tests && npm test` → 175 rules + 154 moderation; `cd functions-tests && npm test` → 74 functions. Live-staging E2E rigs: `firestore-tests/full-e2e.mjs` (36 checks) and `firestore-tests/e2e-round2.mjs` (43 checks) — both need the staging web config (pull from `toska/GoogleService-Info-Staging.plist`) + ADC. Run them.
- The iOS client builds **Release-clean**, but must be built to a **non-iCloud-synced DerivedData path** (e.g. `/tmp`) or codesign fails on `~/Desktop`'s file-provider xattrs.

## The record of prior work (read as claims, verify)
- `AUDIT.md` — original 18-finding security audit + the M-1 reply-hold feature.
- `AUDIT-2.md` — re-review: findings **N-1 … N-16** (incl. N-11: App Check state was misreported by a buggy tool; N-13: a phone false-positive; N-14: crisis-hold/resources; N-15: apt-suite FP; N-16: reply-repost stranding).
- `APP_STORE_READINESS.md` — UGC Guideline 1.2 compliance, privacy/data + nutrition labels, account deletion, crisis safety, moderation FP/FN, App Check.
- `VERIFICATION_BRIEF.md` — the prior verification prompt.
- Most-recent, least-reviewed changes (give these EXTRA scrutiny — they're newest): **N-17** (allow lone first names — a deliberate relaxation of the PII detector across 7 paths, mirrored client+server), **non-English crisis detection** (Spanish/PT/FR phrase lists, server+client), **App Check prod-Auth enforcement**, an **admin-dashboard bulk-approve**, and a **crisis-region fallback** fix.

## Your mandate — review the whole app across these dimensions

**1. Security (the perimeter + the seams).** Re-threat-model the tri-layer contract. For every invariant a function or the client enforces, is it ALSO enforced in `firestore.rules` where it must be (esp. on staging, where rules are the sole perimeter)? Hunt for: privilege escalation, byline forgery, graph enumeration, block bypass, counter manipulation, notification/push spam, audit-log forgery, reading others' private data, self-publishing moderated content, and anything reachable by a tampered client. Re-run the rules suite (incl. `hostile-user.test.js`) and the live E2E rigs; write a failing test for any gap before claiming it.

**2. The moderation system — quality AND correctness.** This is the highest-risk subsystem for this app. Run the real classifiers directly (`cd functions && node -e 'process.env.GCLOUD_PROJECT="toska-test"; const {__test}=require("./index.js"); console.log(__test.computePostFlagReason("…"))'` and `const m=require("./moderation.js"); m.containsNameOrIdentifyingInfo("…")`). Specifically:
   - **Independently verify N-17** (lone first names now allowed): does ANY edge case now **leak real PII / de-anonymize** someone? Test full names, obfuscated names (Cyrillic/leet/fullwidth/separator/reversal/combining-mark), last names, contact info, addresses, handles, mixed cases ("my ex John, he lives at…"), and non-English names. Confirm the *intended* policy (plain first → allowed; full/last/obfuscated/contact → held) and find where it's violated either way.
   - **Client/server detector PARITY:** the Swift `containsNameOrIdentifyingInfo` (FeedView.swift) and `functions/moderation.js` are hand-synced. Build a shared corpus and confirm they agree case-by-case — any divergence is a UX bug (client warns / server allows, or vice versa). There is no automated test pinning them in sync; consider adding one.
   - **False-positive / false-negative profile** on a realistic grief corpus (names, dates, places, song/band titles, venting). Quantify what legit content still gets held and what harmful content slips.

**3. Crisis safety.** Document and stress-test end-to-end: the tiers (explicit vs soft), what the server does (hold? page admins?), the client compose-time check-in, the held-post crisis-resources banner (N-14), and the locale-aware hotlines. Specifically verify the **non-English additions** (Spanish/PT/FR) actually fire and don't introduce false-positives in those languages, and find remaining gaps (other languages, the `findahelpline` fallback, soft-tier never paging). Flag anything a crisis-intervention professional should weigh — this is a vulnerable-user feature.

**4. The Cloud Functions.** Counter triggers (atomic `claimedTransaction` + retry — idempotency, no drift, no double-count), the deletion cascade + the post-subtree cleanup (`onPostDeletedCleanupSubtree`, `onReplyDeletedCleanupReposts`), the moderation triggers (validatePost/validateReply, the start-hidden model, the M-1 reply hold), rate limiting, and the 3 callables. Hunt for divergent/duplicated logic (the kind that caused N-13: the same concept implemented in multiple places that drift).

**5. iOS / on-device.** Token/PII local storage (the `DraftStore` — NSFileProtectionComplete + backup-excluded), the app-switcher privacy cover, pasteboard, push payload contents on a normal lock screen, the held-reply drill-down, optimistic-UI/listener data races, crash/force-unwrap surface, listener lifecycle/leaks, deep links, and the auth flows (Apple/Google/email link/unlink, token refresh, the age gate, what a restricted/blocked user can still reach). The App-Check-enforced callables need a **real device** (App Attest doesn't work on the simulator) — call that out as owner-verification.

**6. App Store readiness.** UGC Guideline 1.2 (report/block/EULA/content-filter/contact/act-on-reports), privacy nutrition labels vs `PrivacyInfo.xcprivacy` (note the unused ads SDK), in-app account deletion, the 17+ age gate, and live Terms/Privacy URLs. Flag anything that would cause a rejection.

**7. Performance, quality, and product.** Feed pagination/listener efficiency, Firestore read costs, query/index correctness (`firestore.indexes.json` vs the queries the app + admin dashboard run), N+1 patterns, accessibility, and obvious UX bugs. Also: anything that just looks wrong, fragile, or like a latent footgun.

## How to work
- **Verify, don't reason.** Run the suites, run the E2E rigs against staging, run the classifiers, build the iOS app (to `/tmp`). Where you suspect a bug, demonstrate it with a failing test before claiming it.
- **Adversarial.** Assume prior auditors (and the most recent changes) missed things. Look in the seams between layers, in the newest/least-reviewed code (N-17, non-English crisis, App Check), and in the moderation edge cases.
- **Separate the unverifiable** (anything needing the Firebase/App Store console, IAM, App Check metrics, or a real device) into its own clearly-labeled section — do not guess.
- For each finding: **ID + severity**, one-line summary, **repro (ideally a test)**, the **layers affected**, and a **proposed fix**. Distinguish "verified correct" from "found a gap." Explicitly say where you looked and found nothing — that's a useful result too.
- **Deliverable:** write everything to a new file **`AUDIT-3.md`** at the repo root. Do **not** edit `AUDIT.md`, `AUDIT-2.md`, or `APP_STORE_READINESS.md`. Don't deploy or push anything without explicit approval.

Begin by reading `AUDIT-2.md` + `APP_STORE_READINESS.md`, confirming the App Check state and the test wiring, then run the suites and the two E2E rigs — and pay special attention to independently re-verifying the **N-17 first-name change** and the **client/server detector parity**, since those are the newest and the most safety-sensitive.
