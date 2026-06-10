# Toska — App Store Readiness Review (2026-06-10)

Scope: the six pre-submission axes beyond the security re-review (`AUDIT-2.md`). Verdict per axis, what was verified, what was fixed this pass, and what only the owner can close.

**Bottom line:** No *submission-blocking* gaps found on the App-Store-rules axes (UGC compliance, privacy/data, account deletion, legal links all pass). The real remaining work is **operational/owner**: a real-device Release test, a lawyer pass on the policy, a safety-owner decision on the non-English crisis gap, and enforcing App Check on Auth. The app is *close*, but "submit today" is not something I'd certify without those.

---

## 1. The actual submission build — ⚠️ PARTIAL (needs a real device)
- **Release config compiles** (`-configuration Release`, prod `GoogleService-Info.plist` present) → `BUILD SUCCEEDED`. The `#else`/prod code path builds.
- **Not verified (cannot, here):** a **signed device archive** (needs the Apple Developer distribution cert/profile) and a **real-device run**. App Attest, the callables (`confirmAdult`/`giphyProxy`), and APNs push **only work on a physical device** — all untested. I've only run Debug→staging on a simulator.
- **Owner must:** archive a Release build, install on a real device, and confirm: sign-in (Apple/Google/email), age-gate `confirmAdult` succeeds (App Attest), GIF picker works (giphyProxy), push arrives, and a post round-trips against **prod**.

## 2. App Store Guideline 1.2 (UGC) — ✅ PASS (all six requirements)
Apple's UGC checklist, each implemented and **server-enforced**:
- **(a) Filter objectionable content:** fail-closed "start-hidden" model — posts created `pending_validation`, rules force it (`firestore.rules:610`), feed requires `moderationStatus=='live'`; `validatePost`/`validateReply` moderate server-side. Stronger than Apple's minimum.
- **(b) Report:** users can report a **post, reply, AND user** (`ReportTarget` in `ToskaTheme.swift`; call sites in Feed/PostDetail/ReplyDetail/OtherProfile). Persists to `reports` (schema-locked, admin-read).
- **(c) Block:** server-enforced via `!exists(.../blocked/$(caller))` on follow/like/reply/repost/save/profile-read (`firestore.rules`) — not client-only (the common rejection cause).
- **(d) Contact:** support email published in the in-app Content Policy (§10). *Polish:* it's text, not a tappable `mailto:` Settings row.
- **(e) EULA:** blocking `PolicyAcceptanceView` at signup + version-bump re-prompt; acceptance recorded (`acceptedPolicyVersion`). Terms/Privacy links in Settings + Splash.
- **(f) Act on reports:** admin dashboard (`docs/admin.html`) removes content + restricts users (server-enforced `notRestricted()`); `onReportCreatedAutoHide` hides a post on 3+ distinct reporters/24h; actions audit-logged.
- **Before submit:** (i) resolve the policy's self-flagged *"a lawyer should review before submission"* note; (ii) optionally add a tappable "Contact us" row; (iii) confirm `toskaapp.com/terms` + `/privacy` resolve (they returned **200** at audit).

## 3. Privacy & data — ✅ PASS (mirror the manifest on the ASC form)
- **Account deletion:** present, reachable in Settings, **hard delete** — `Auth.delete()` + the `onUserDocDeleted` cascade erases posts/replies/drafts/follows/likes/saved/notifications/etc. (Apple requires this; satisfied.) GDPR data-export also present.
- **Privacy Policy + Terms URLs:** live (HTTP 200), linked in-app.
- **Age gate:** 17+, server-enforced (`confirmAdult` is the sole writer of `confirmedAdult`; `hasConfirmedAdult()` gates posting). Implies a **17+** App Store age rating.
- **Data map / nutrition labels:** `PrivacyInfo.xcprivacy` present and consistent — Email/UserID/UserContent **Linked**; Crash/Performance/ProductInteraction **Not-Linked**; `NSPrivacyTracking=false`. **No tracking, no ad attribution.**
  - **Watch-outs:** Analytics/Crashlytics/Performance **are** wired (de-identified — no `setUserID`); keep it that way or the labels change. `google-ads-on-device-conversion` is resolved in SPM but **NOT linked/used** — don't link it, or `NSPrivacyTracking` must flip to true.
- **Third parties:** Giphy receives only the search string, server-to-server (key in Secret Manager); Firebase/Google + Apple Sign-In standard.

## 4. Crisis / safety — ⚠️ NEEDS A SAFETY OWNER (engineering is sound; policy isn't mine to sign off)
Current behavior (documented end-to-end for a clinician in this pass):
- **Tiers:** explicit suicidal intent vs soft hopelessness, with leet/unicode/spaced-letter evasion-resistant matching. Both tiers **hold** the post (recoverable, author-visible); **explicit also pages admins** (neutral push, no content). Crisis hotline numbers whitelisted from PII.
- **Client:** compose-time check-in modal (explicit always; soft respects the documented opt-out) + the **new N-14 held-post banner** that surfaces region-aware `CrisisLines.resources`.
- **Fixed this pass:** unknown-device-region users no longer get shown US `988` (dead abroad) — they now fall through to the international `findahelpline` directory.
- **Owner/safety-owner must decide:**
  1. **Non-English crisis content is NOT detected** (Spanish *"quiero morir"* → no hold/banner/page). Biggest clinical gap for an internationally-available app with curated foreign hotlines. Needs non-English phrase lists (or NER) — a real decision, not a quick fix.
  2. **Soft tier never pages** a human in real time (relies on the 24h review SLA).
  3. Client/server crisis phrase lists are hand-synced with no test pinning them — add a parity test to prevent drift.
- **Recommend:** a person with crisis-intervention expertise reviews the policy before launch.

## 5. Moderation quality (FP/FN) — ⚠️ KNOWN TRADE-OFF (not a blocker)
The detector is deliberately tuned to **over-hold** (safe direction for an anonymity app). Measured on a realistic grief corpus:
- **False positives (legit posts held):** the dominant class is **bare first-name mentions** ("I miss John", "my ex Sarah") — plausibly **20–40%** of real breakup posts, since naming an ex is the modal post. Plus place/location context ("works at the hospital", "from Brooklyn"). Held posts are **recoverable** (author-visible banner, not deleted), so this is a UX + review-queue-load cost, not data loss — but at launch volume it can swamp the solo admin and frustrate users.
- **Fixed this pass:** removed the loose verb substrings (`"works at"/"goes to"/"lives in"/"lives on"`) from `moderation.js` that `index.js` had already dropped — cleared "lives in my head", "goes to my gym", etc. (142 moderation tests still green; real PII still caught).
- **Inherent / product-tuning (not changed):** the first-name FP is core to PII detection and can't be fixed without NER; the place/location-context FP is a tuning call. **Recommend** the team decides the FP↔FN balance and, ideally, plans the review-queue load for launch volume.
- **False negatives (narrow):** spelled-out emails ("john dot smith at gmail dot com"), `ig is X` shorthand without a separator, all-lowercase real full names. Acknowledged in code; NER-class problem.

## 6. App Check enforcement — ⚠️ OWNER CONSOLE ACTION
Verified current state (corrected per N-11): **prod Firestore = ENFORCED** ✓; **prod Auth (identitytoolkit) = UNENFORCED**; **staging Firestore + Auth = UNENFORCED**.
- **Owner should:** enforce **prod Auth** and **staging** after the standard pre-flight (verified-request rate ≈ 100% in the UNENFORCED metrics + a real-device App-Attest confirmation). `functions/setAppCheck.js` reads state and can flip it (`--apply --mode=ENFORCED --project=... [--yes-prod]`); it's a careful, deliberate flip (naive enforcement can lock out legit users).
- Staging's two **scheduled** functions (`cleanupExpiredPosts`, `cleanupProcessedTriggerEvents`) fail to deploy because Cloud Scheduler isn't set up on staging — a staging-infra gap, harmless to prod.

---

## What I fixed in this pass
- **Crisis (safety):** unknown-region fallback → international directory instead of a dead US number (`ToskaTheme.swift`).
- **Moderation FP:** removed the loose verb substrings from `moderation.js` (aligns the two detectors; 142 tests green).

## The owner's pre-submission must-do list
1. **Archive a Release build and test it on a real device** (App Attest, callables, push, prod round-trip). — the single biggest unverified item.
2. **Lawyer review** of the Content Policy / Terms / Privacy (the policy itself asks for this).
3. **Safety-owner decision** on the non-English crisis gap (#4.1) — and ideally a clinician review of the crisis policy.
4. **Enforce App Check** on prod Auth + staging (#6), post pre-flight.
5. Fill the **App Privacy** form to mirror `PrivacyInfo.xcprivacy`; answer **No** to tracking; don't link the unused ads SDK.
6. Confirm the live **Terms/Privacy URLs** resolve, set the **17+** age rating, and (optional) add a tappable in-app "Contact us" row.
7. Plan for the **moderation review-queue load** at launch volume given the over-hold tuning (#5).
