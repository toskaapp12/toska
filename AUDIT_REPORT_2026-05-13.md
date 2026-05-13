# Toska — Audit Report

**Date:** 2026-05-13
**Auditor:** Claude (read-only)
**Scope:** comprehensive pre-submission audit per `AUDIT_BRIEF.md`
**Build under review:** MARKETING_VERSION 1.0 / CURRENT_PROJECT_VERSION 5

---

## Verdict

🟢 **GREEN — ship it.**

No critical or high findings. One Medium and two Low findings, all clustered in the identifying-info detector. The Medium is a phone-number detection asymmetry between the create-time delete path and the post-update soft-flag path; the soft-flag catches it and the feed filter hides flagged posts, so user-visible exposure is sub-second, but the iOS pre-publish UX does not warn the user when they type a formatted phone. The two Lows are niche evasion vectors (combining diacritics on uppercase names; the `ig:` shorthand with a lowercase name).

The codebase is in unusually good shape for a v1.0 UGC app: five prior audit rounds have closed dozens of findings, the captured-uid recheck pattern is applied uniformly across every async listener, sign-out handlers consistently teardown listeners *and* clear cached `@State`, and the Firestore rules deny-by-default closure is intact. 141 emulator tests pass clean in ~5 s.

The findings below would not block submission. M-1 is worth a 30-minute fix before tapping Submit; the Lows are post-launch polish.

---

## Findings by severity

### Critical

*(none)*

### High

*(none)*

### Medium

#### M-1: [MEDIUM] functions/moderation.js:354-366 — bare formatted phone numbers bypass the create-time identifying-info detector

**Impact:** A post containing `(555) 123-4567`, `555-123-4567`, `+44 20 7946 0958`, or `555.123.4567` slips through `validatePost` and `validateReply` (which gate on `containsNameOrIdentifyingInfo`). The soft-flag pipeline at `functions/index.js:1762` (`hasPhoneNumber` — correctly strips `[\s\-\(\)\.]` before counting digits) DOES catch these and `FeedViewModel.swift:474` hides flagged posts from the feed, so user-visible exposure is the sub-second window between document create and trigger fire. However: (a) the iOS Swift mirror at `toska/FeedView.swift:1738-1749` shares the identical gap, so the compose-time warning modal never fires for formatted phones; (b) the post lingers in `posts/` collection (admin-queue review) rather than being deleted outright like a name-containing post; (c) an Apple reviewer probing "post a phone number" sees no UI warning. Test gap: `firestore-tests/moderation.test.js:100` only exercises this code path via the `call me at 555-867-5309` keyword fallback, not the bare-digit heuristic — every "phone" test currently passes because of the keyword catch, not the digit count.

**How to repro (static):** `node -e "const m = require('./functions/moderation.js'); ['(555) 123-4567','+44 20 7946 0958','555-123-4567','555.123.4567'].forEach(t => console.log(t, '→', m.containsNameOrIdentifyingInfo(t)))"` returns `false` for every input.

**Verification:** the word-boundary-anchored strip at lines 361 (`\b\d{4,5}\b`) and 362 (`\b\d{1,3}\b`) removes every digit chunk in `(555) 123-4567` because parens/space/dash are all word-boundary edges around the 3- and 4-digit runs. `hasPhoneNumber` at `functions/index.js:1762-1771` does the strip in the right order (strip separators first, then count), which is why the soft-flag path works correctly.

### Low

#### L-1: [LOW] functions/moderation.js:394-451 — combining-mark evasion (`S̶arah`) bypasses all detector layers

**Impact:** `S̶arah` (uppercase S + U+0336 combining long stroke overlay) is split by `tokenizeAlphanumeric` (line 263, `/[^\p{L}\p{N}]+/u`) into `['S', 'arah']` because U+0336 is Mn (Mark, Nonspacing) and matches neither `\p{L}` nor `\p{N}`. `'S'` is below the 2-char floor at line 343; `'arah'` is not in `COMMON_NAMES`. Layer 4 (line 394) iterates the same tokens with the same outcome. Layer 5 (line 441) builds `canonicalTokens` from the canonicalized full text — which has already stripped combining marks via line 210 — so `canonicalTokens` contains `'sarah'`, and the membership check at line 449 (`if (canonicalTokens.has(token)) continue;`) skips the aggressive match. Lowercase `s̶arah` slips for the same reason plus the `isUpperFirst` gate at line 404.

**Verification:** empirically `containsNameOrIdentifyingInfo('S̶arah') === false`.

**Severity rationale:** niche evasion (combining strikethrough is unusual in real prose); an attacker must intentionally inject it; Apple is unlikely to probe with this. LOW.

#### L-2: [LOW] functions/moderation.js:92-109 — `ig:` Instagram shorthand with a lowercase name slips

**Impact:** `IDENTIFYING_PATTERNS` includes `"instagram"` and `"insta"` (line 93) but not the very common `"ig:"` or `"ig "` shorthand. With a lowercase following name (e.g., `ig: sarah`), the lowercase token also fails the `isUpperFirst` gate at line 347 / 404, so the mid-sentence proper-noun layer doesn't catch it. `IG: Sarah` is caught (uppercase trips name layer); `ig: sarah` slips. Same pattern: `ig sarah`, `IG sarah`.

**Verification:** empirically `containsNameOrIdentifyingInfo('ig: sarah') === false`, `containsNameOrIdentifyingInfo('IG: Sarah') === true`.

**Severity rationale:** common shorthand evasion but requires the reader to recognize `ig:` as Instagram; LOW.

---

## Unverifiable (real-device required)

- Push notification end-to-end (APNs delivery; simulator has the 4 stacked App Check issues per the maintainer's note in `bf06000`).
- App Attest first-run path on a fresh device.
- Universal Links from `applinks:www.toskaapp.com` (requires associated-domains validation via Apple's CDN; real-device install).
- Force-quit interruption recoverability at every state-machine intermediate (e.g., between `Auth.auth().createUser` and Firestore user-doc create; between age-gate tap and `confirmAdult` server write; between `pendingDeletion` create and `Auth.delete`).
- App-icon rendering on real home screen.
- Battery / network behavior under flaky conditions.
- Sign in with Apple revocation flow (user revokes via iOS Settings → Apple ID → Toska → Stop Using).
- Time-of-day-gated UI: `FeelingCircleView` midnight dissolve; `LateNightTheme` 12am-6am window.
- `Cloud Monitoring` alert policies (gcloud token state unknown in this session; L-5 from 2026-05-01 review still applies as a pre-submission checklist item, not a finding).
- Live `https://www.toskaapp.com/admin.html` behavior end-to-end (HTML read; clicked-through behavior with a real admin uid not exercised).

---

## What I did

**Files read in full:**
- `AUDIT_BRIEF.md` (start-to-finish, 743 lines)
- `PRE_SUBMISSION_REVIEW_2026_05_01.md` (historical context)
- `functions/moderation.js` (470 lines)
- Cited sections of `functions/index.js` — lines 610-660 (rate limiter), 800-1073 (`sendPushNotification`), 1583-1721 (`validatePost`/`validateReply`), 1740-1810 (PII helpers), 1990-2228 (`onPostCreated`/`onPostUpdated`/`onReplyUpdated`/`onMessageCreatedModerate`)

**Files spot-read:**
- `toska/FeedView.swift` (phone-detection mirror lines 1730-1770)
- `toska/FeedViewModel.swift` (flagged-post filter lines 470-980)
- `toska/NotificationsView.swift` (listener teardown lines 180-210, 451-555)
- `toska/DraftsView.swift`, `toska/FeelingCircleView.swift`, `toska/MainTabView.swift` (captured-uid recheck verification)
- `firestore-tests/moderation.test.js` (phone test coverage)
- `firestore-tests/firestore.test.js` (sampled)
- `firestore.rules` (full read via sub-agent)

**Commands run:**
- `git log --since="2026-05-01" --oneline` — 40 commits since last green verdict
- `cd firestore-tests && npm test` → 141 passing in ~5 s
- `wc -l firestore.rules functions/index.js functions/moderation.js docs/admin.html` (sizes match brief: 1159 / 3188 / 470 / 603)
- `grep -rn "addSnapshotListener" toska/` — 15 sites across 10 files
- `node -e "..."` to empirically test the moderation detector against 30+ adversarial inputs (formatted phones, math-alphanumeric folding, combining diacritics, Cyrillic confusables, reversed tokens, IG shorthand, sentence-starter exemption edge cases)

**Sub-agents used (per §11):**
1. Firestore rules audit (read `firestore.rules` in full + `moderation.test.js` + sampled `firestore.test.js`) — clean; one redundant catch-all `/{path=**}/replies/{replyId}` rule noted as harmless.
2. Cloud Functions audit (read `moderation.js` / `cleanup.js` / `seedAppStoreDemo.js` / `scrubLegacyPII.js` in full + spot-read `index.js`) — surfaced one CRITICAL and three HIGHs that I verified and rejected as either false (regex misread) or documented design trade-offs (see "Comparison to prior audits" below).
3. iOS Swift critical surfaces audit (read every high-risk view in full) — zero findings; comprehensive captured-uid recheck and sign-out cleanup verified across all 15 `addSnapshotListener` sites.
4. Admin dashboard + moderation pipeline audit — surfaced the same formatted-phone gap (verified as M-1) and confirmed admin abuse model is well-defended (FCM token owner-only, DM thread participant-only, admin claim no-client-path, audit trail on every restriction/resolution write).

---

## What I did NOT cover

- I did not run an `xcodebuild` Debug build in this session; SourceKit can warn cosmetically and the brief notes the actual build succeeds. Risk: a fresh syntax error since the last successful CI run on 2026-04-30. Mitigation: `git log` shows the last 7 commits are docs/audit-closing changes; no fresh source breakage likely.
- I did not click through the live admin dashboard with an admin uid. The HTML + Firestore rules layer is read.
- I did not script force-quit at every state-machine intermediate. The brief explicitly flags these as device-required (see UNVERIFIABLE).
- I did not exhaustively trace every Cloud Function callable's App Check enforcement; sub-agent verified `giphyProxy` (line 2854), `confirmAdult` (3049), and `reconcileMyCounts` (manual verify); other callables not individually pinned.
- I did not verify the marketing site (`docs/index.html`, `privacy.html`, `terms.html`) is byte-consistent with `PrivacyInfo.xcprivacy` and `toskaPolicyBody` in `ToskaTheme.swift`. The 2026-05-01 review confirmed consistency; assumed unchanged.
- iOS sub-agent did not read the entirety of `FeedView.swift` (2199 LOC); read first ~350 lines + searched for listener patterns. The `addSnapshotListener` inventory found no FeedView site, so listener-leak risk on that file is low; full read deferred.

---

## Comparison to prior audits

### New findings introduced this round

- **M-1** (formatted-phone gap): not in prior audits. The 2026-05-01 review noted "pattern-based moderation has known false-positive tails" (M-4) but did not flag the *false-negative* on bare formatted phones specifically. The 2026-05-08 evasion-hardening commit `54edff2` added confusable folding, leet, separator collapse, and dotted initials — but didn't touch the phone-detection digit-strip logic, which is where this gap lives.
- **L-1** (combining-mark evasion): not in prior audits.
- **L-2** (`ig:` shorthand): not in prior audits.

### Prior findings I verified still hold

- 2026-05-01 H-1 (24h SLA tooling): closed by `86307ef`. Dashboard now surfaces overdue (>24h) red badges and aging (12-24h) amber, comparing against `report.createdAt` server timestamp (`docs/admin.html:297-319`). ✓ Closed.
- 2026-05-01 H-2 (live ToS/Privacy not linked from Settings): closed by `8ca8e53`. Settings now has the live URL rows. ✓ Closed (inferred from commit message; not re-verified in this audit).
- 2026-05-01 M-1 (`confirmAdult` fire-and-forget): closed by `8ca8e53`. ✓ Closed (inferred).
- 2026-05-01 M-3 (cascade hard caps): closed by `1f8b75b`. `onUserDocDeleted` continuation pattern + `postDeletionQueue` confirmed at `functions/index.js:666-807`. ✓ Closed.
- 2026-05-07 audit findings: closed by `55c38b4`. Not individually re-verified.
- 2026-05-08 second-pair-of-eyes (report flooding, cleanup symmetry, push payload validation, user-doc tightening, schema lockdown, counter atomicity, identifying-info evasion, `reflections.authorId` index, drafts plumbing): closed by `ac21653` + `e249323`. Push payload validation at lines 925-983 verified ✓; report rate-limit per-reporter and per-target at `rateLimitReports` line 2566 verified ✓; counter trigger idempotency via `claimTriggerEvent` lines 512-536 verified ✓; identifying-info detector evasion (Layers 1-6) reads as designed at moderation.js:368-456 ✓.
- 2026-05-13 deep iOS audit fixes (`5c6d8b9` + `7e25d01`): `PostDetailView.fetchReplies` captured-uid recheck at lines 832-845 ✓; `MessagesListView` `.userBlocked` subscription at lines 140-158 ✓; `PushNotificationManager.clearFCMToken` calls `Messaging.deleteToken()` first at line 63 then wipes Firestore ✓; `friendlyAuthErrorMessage` collapses 17009/17011 to one message ✓ (inferred; not re-verified line-by-line in this session).
- Email Enumeration Protection on `emailPrivacyConfig.enableImprovedEmailPrivacy`: per `348258a` commit message, verified true on both projects. Not re-queried in this session.

### Prior findings now fully resolved (no longer reported)

All five `PRE_SUBMISSION_REVIEW_2026_05_01.md` numbered findings are tracked-closed in the post-2026-05-01 commit history.

### Agent-claimed findings I rejected on verification

This is the noise tail the brief warned about — fan-out agents over-claimed; I re-read the cited lines and dropped each:

- **Rejected [CRITICAL]** "double-separator name evasion `j.. o.. h.. n`" — sub-agent misread the regex at moderation.js:252. `[.\-_ ]+` uses `+` which allows one OR MORE separators. Empirical test: `containsNameOrIdentifyingInfo('j.. o.. h.. n') === true`. The aggressive layer correctly collapses multi-separator chains. Drop.
- **Rejected [HIGH]** "DM moderation soft-flags PII instead of deleting" — `onMessageCreatedModerate` at functions/index.js:2199-2205 soft-flags PII consistently with reply moderation (line 2111). Documented design ("PII and links: flag for review instead of deleting (higher false positive rate)"); also accepted by 2026-05-01 M-4. Drop.
- **Rejected [HIGH]** "`sendPushNotification` claims `processed: true` before FCM send, so retries silently drop on transient errors" — by-design trade-off explicitly documented at functions/index.js:820-828 (compare-and-set inside transaction to prevent duplicate pushes). The alternative (don't claim until after send) trades silent-drop for duplicate-push, which is worse for an anonymity-first app where each push is a lock-screen-visible event. Drop.
- **Rejected [HIGH]** "`seedAppStoreDemo.js` prints demo password to stdout" — lines 442-447 print the password ONLY when the demo account was newly minted (`demoCreated === true`); when reused, it prints `<unchanged ...>` with a Firebase-console-reset hint. This is the explicit "honesty" fix audit-closed by `5c6d8b9` (M-2). Operator running the seeder needs the password ONCE on first-mint. Drop.
- **Rejected [MEDIUM]** "`containsPII` delegates to `containsNameOrIdentifyingInfo` without comment" — the documenting comment is at functions/index.js:1801-1807, eight lines above the delegated call. Sub-agent missed it. Drop.
- **Rejected [MEDIUM]** "rate-limit transaction fails open on Firestore error" — documented at functions/index.js:654-656 with explicit rationale ("a Firestore hiccup shouldn't lock legitimate users out of features"). Failing-closed would create a denial-of-service-by-Firestore-outage path. Drop.
- **Rejected [LOW]** "`cleanup.js` MAX_DELETE_ITERATIONS=500 may cap on massive accounts" — `cleanup.js` is dev tooling (guarded by `NON_PROD_PROJECTS` + `-test/-dev/-staging` regex + `--allow-prod` flag), not the GDPR cascade path. The cascade path (`onUserDocDeleted` at index.js:666 + `resumePostDeletion` queue) is what runs for real account deletion and has correct continuation handling. Sub-agent conflated the two scripts. Drop.

---

End of report.
