# Known bugs — backlog

Format: severity · surface · status. "Pre-existing" = present before the
2026-10 launch-audit work; not a regression from it.

---

## AUDIT-A1 — held/crisis posts and replies enumerable by any signed-in user via unconstrained queries (FIXED, PROD)

- **Severity:** HIGH (privacy; contradicts P:120) · **Surface:** firestore.rules + 3 client query sites · **Status:** FIXED 2026-10-28 — rules on prod (`rules-prod-2026-10-28-a1`), web live, iOS in build 103
- Found by the 2026-10-27 multi-user audit (`AUDIT_MULTIUSER_STAGING_2026-10-27.md` A1). `moderationVisible()`/`postVisibleToCaller()` used `.get('moderationStatus','live')`; an unconstrained list query (where flagged==true, where pendingReason=='crisis', where authorId==<other>, bare orderBy, replies with no status filter) was satisfiable via the default → other users' held content with full text + handle. Fix: default `''`; posts/replies LIST rules drop `resource == null`; GET unchanged. Tests: `held-content-enumeration.test.js` (43), legacy-defaults-to-live tests reversed.
- **Client change:** `documentId in` + live is also denied (engine limitation), so liked/saved tabs (web `fetchRefTab`, iOS ProfileView ×2), iOS engaged tags (FeedViewModel) read per document; iOS author repost sweep (PostDetailView) pins live. **Follow-up (build 103+/web):** paginate per-doc liked/saved reads 30 at a time with "load more".

---

## AUDIT-A2 — moderation gaps: dehumanizing hate, explicit sexual detail, 3rd-person threats, underage phrasings, reply spam; "54"→"sa" crisis false positive (FIXED, PROD)

- **Severity:** HIGH (contradicts I:323-327 / T:96 / T:84) · **Surface:** functions moderationLogic.js + index.js, web vendor + gates.js, iOS ContentModeration.swift · **Status:** FIXED 2026-10-28 — functions + hosting on prod; iOS in build 103
- **Found by** the 2026-10-27 audit (A2): "all women are worthless trash", "all men are subhuman garbage and should be exterminated", "explicit details about his dick", "going to hurt him so badly", "i am 15 and…", "16f", bare "born in 2012" all published LIVE as posts and replies; replies were never spam-checked; a clean post containing "54" was HELD as crisis because the ≤3-char algospeak tokens (sa/sh/dv/od/kms) were tested against the de-leeted text ("54"→"sa", "5h"→"sh", "0d"→"od").
- **Fix:** `MOD_DEHUMANIZING` (flag `dehumanizing` → pendingReason `abuse_hate`, HELD everywhere, never hard-deleted; slurs keep the reply hard-delete); 3rd-person physical threat phrases (plain "hurt him/her" deliberately NOT included); `MOD_SEXUAL_REVIEW` (flag `sexual_explicit` → `abuse_sexual`, HELD, overridable at compose; guards: "fucked me over/up/around/off", exclamation "fuck me, …", bare "sex"/"dick" absent); underage: curly apostrophe, bare age at a clause boundary, age+gender ("16f", "16 m", "f16"), bare "born in YEAR" (not after my/his/her/daughter/dog…); replies now run `SPAM_PATTERNS` (held `abuse_spam`); `applyReplyModeration` holds the three new reasons (an unknown reason used to fall into the delete branch); short crisis tokens match raw text only, with a joiner so "k.m.s" / "k m s" / "s.a." still hold.
- **Accepted miss (owner):** "being dumped in 9th grade…" — no present-tense first-person marker; pinned null in the corpus. "immigrants should all be deported" stays live (political speech).
- **Pins:** moderation-corpus 141/141 (+ new REPLY_CASES), crisis-tier 29/29, crisis-parity exact, detector-parity 100/100 (Swift matcher compiled), moderation suite 154, functions tests 24. **Staging sweep 39/39; prod sweep 34/34** (Admin-SDK writes under throwaway authors, backdated 2y, deleted 76 s after the first write; no crisis wording on prod).
- **Parity caveats:** iOS reply/edit composers are edit-only for every violation type (pre-existing design), so `.sexualReview` there has no "reply anyway"; iOS has no underage detector (server holds; author sees the banner).
- **Follow-up (LOW):** `validateReply` (retry:true) logs NOT_FOUND and retries when `onReplyCreatedModerate` hard-deletes a slur reply first (3 error lines per deleted reply). Treat NOT_FOUND as done.

---

## AUDIT-3 — explicit-tier crisis replies now HELD for review; supportive reach-outs stay live (FIXED, PROD)

- **Severity:** MED (safety / parity with posts) · **Surface:** functions (onReplyCreatedModerate, validateReply, onReplyUpdated), docs/admin.html, iOS ProfileView/PostDetailView/PostModels · **Status:** FIXED 2026-10-28 — four reply functions on prod; admin.html live on push; iOS banner in build 103
- **Before:** every concerning reply stayed LIVE and was only queued (`crisisReplyQueue`); explicit crisis also paged. Supportive reach-outs ("please don't kill yourself, call 988, you matter") were being HELD as `targeted_threat` because "kill you" is a substring of "kill yourself".
- **Now (owner decisions 2026-10-28):** EXPLICIT-tier crisis replies are held (`pending_review` / `crisis`) like posts; SOFT-tier replies stay live + queued (often empathy: "i can't do this anymore either"); a narrow supportive guard (`isSupportiveReachOut`: negation tied to the self-harm verb AND a help signal AND no hard directed-abuse token) keeps reach-outs live and skips the threat/harassment lanes; directed abuse ("go kill yourself", "kys", "you should kill yourself") routes to the abuse lane (held as abuse) with no crisis queue entry — never the author's own crisis; "don't kill yourself" alone (no help signal) is held as abuse_threat and incurs NO strike (reply holds never write `flagged`; `checkRepeatOffenderPosts` counts posts only). Edits introducing explicit crisis hold too. `validateReply` no longer promotes such replies (idempotent, order-independent with the hold).
- **Admin (docs/admin.html):** crisis-tab "mark reviewed" on a reply also releases a crisis-held reply (same marker scrub as approve); approving a crisis-held reply in the pending-replies tab also marks its deterministic `crisisReplyQueue/{postId}_{replyId}` entry reviewed. iOS admin has no held-reply queue (unchanged).
- **Author-facing (iOS build 103):** profile replies tab now carries the same "under review" banner as posts, with the crisis support line + resources when the reason is crisis; the thread banner passes the crisis flag. Web already showed "under review — crisis language".
- **Pins/verification:** corpus `CRISIS_REPLY_CASES` (20) 141/141; staging 11/11 (explicit holds, soft live+queued, supportive live, crisis-phrase+supportive live+queued, directed abuse → abuse lane, slur deleted, author-only read, replyCount exact, preview never carries held text, admin release, edit-to-crisis hold); prod 5/5 with soft/supportive/"kys" only, fixtures removed in 70 s.
- **Wording follow-up:** privacy P:120 "post" → "post or reply" (policy batch).

---

## AUDIT-B3 — reply text in the recipient's notification preview (FIXED, PROD)

- **Severity:** MED (privacy) · **Surface:** functions · **Status:** FIXED 2026-10-28 (option A) — `onReplyDeletedScrubNotifPreview` on prod
- The preview (`message`) was already filled only from a LIVE reply and scrubbed on hold, and push payloads never carry text. Gap: nothing scrubbed it when a live reply was DELETED (author, admin, or the hard-delete path after an edit), so deleted text lingered in the inbox. New trigger on every reply delete: scrub the sender's preview, then re-backfill from their latest remaining live reply (keeps the "latest reply" semantics). Staging 12/12 (held / author-delete / admin-delete / edit-to-PII / edit-to-slur-hard-delete / two-reply backfill); prod 4/4 (author + admin delete), fixtures removed. Deploy note: a new `retry:true` function needs `--force` (first staging deploy silently failed).

---

## AUDIT-A5 (phase 1) — authorization fields moved off the public user doc (FIXED, PROD)

- **Severity:** MED (privacy: restriction status + age attestation readable by any signed-in user) · **Surface:** rules, functions, admin.html, back-fill · **Status:** PHASE 1 DONE 2026-10-28 — prod rules tag `rules-prod-2026-10-28-a5`; functions deployed; back-fill applied (11/11). Phase 2 after build 103 is the floor.
- **Now:** `confirmedAdult`, `confirmedAdultAt`, `restricted`, `restrictedAt`, `restrictedUntil`, `restrictedBy` live ONLY in `users/{uid}/private/data` (owner-read; server-write; admin-write for the four restricted* keys with `restrictedBy == self`; owner can never touch the six keys — a full overwrite that would drop them is denied, so clients must merge, which every iOS/web write does). Rules: `canPublish()` (ONE `get` on private/data, checks `confirmedAdult` + `restricted`) gates post/reply create — the create rule sits at the 1000-expression ceiling, so the `restrictedUntil` time leg is NOT evaluated there; `notRestricted()` (exact time leg, reads private/data) still gates edits and the self-delete escape. `confirmAdult` and the repeat-offender restriction write private/data. `mirrorModerationState` is now a relocation shim (main-doc writes of the six fields — iOS AdminModerationView until build 103 — are moved to private/data and cleared from the public doc within seconds); `onPrivateAuthStateWritten` maintains `restrictedUsers` + the audit entry; `auditUserRestriction` is a no-op (removed in phase 2). admin.html restrict/unrestrict write private/data.
- **NEW `clearExpiredRestrictions` (every 10 min):** flips `restricted:false` once `restrictedUntil` has passed (closes C14/F6 — the flag used to stay forever). **Consequence (owner-accepted): an expired timed restriction can last up to ~10 extra minutes before CREATE is allowed again; edits honour the exact time.**
- **Verification:** emulator 469/469 with 0 ceiling hits (`private-auth-fields.test.js` +37; fixtures route the six fields to private/data; two legacy expectations updated); staging 28/29 (the one "fail" = same-value owner write, a no-op); prod: functions 73→75 (nothing deleted), pre-check 11/11 attested in private/data, rules released byte-identical, owner posted + replied from the app, back-fill dry-run then apply (11 users: 2 keys deleted from each public doc; private copies pre-existed), post-check 11/11 public docs clean, 11/11 private complete, 0 restrictedUsers rows.
- **Still public on users/{uid} (by decision):** handle, createdAt, totalLikes, followerCount/followingCount (hide toggle is DISPLAY-ONLY → FAQ/privacy wording), showFollowerCount, allowSharing (needed by share-card consent + repost rule), acceptedPolicy*/hasCompletedOnboarding (phase 2).
- **Tier 2:** server-maintained public follower-count mirror behind the hide toggle. **Phase 2:** acceptedPolicyVersion/At + hasCompletedOnboarding → private/data; drop the admin main-doc leg; delete auditUserRestriction.

---

## AUDIT-C8 — crisisDeliveryWatchdog re-logged every soft-tier post every 5 min for 24 h and never retried a failed page (FIXED, PROD)

- **Severity:** MED (ops: alert fatigue hid real delivery failures; an undelivered crisis page was never retried) · **Surface:** functions (`crisisDeliveryWatchdog`, `pageAdminsForCrisis`, delete/review triggers) · **Status:** FIXED 2026-10-28 ~23:00 UTC — staging + prod, deployed `--only` the 10 touched functions (prod set 75 → 75, nothing deleted)
- **Was:** the watchdog scanned `concerningContent == true` posts 15 min–24 h old with no delivery claim and logged `crisis_page_undelivered` on every run. Soft-tier posts are never paged by design, so each one produced ~288 identical lines; `undeliveredCrisisPages` records were written once (with `detectedAt` overwritten on every rewrite) and nothing ever re-attempted the push.
- **Now:** the record is the retry + alert state. `pageAdminsForCrisis` keeps the ORIGINAL `detectedAt`, stores the page payload (`page: {title, body, dataPayload}`), and deletes the record once a page is delivered. The watchdog (still every 5 min) runs scan A = explicit-tier posts (`isPostExplicitCrisis`), unclaimed, unreviewed, 15 min–24 h old → record (`never_paged`); soft tier ignored. Scan B = every record: resolved (claim exists / item deleted / post `crisisReviewedAt` / reply queue `reviewed`) → delete; else retry the page if it has a payload (success → claim + record gone, counted `retriedOk`); else log ONE `crisis_page_undelivered` on the cadence **hourly for the first 6 h after detection, then every 6 h, no ceiling**, stamping `lastAlertedAt` + `alertCount`. `onPostDeletedCleanupSubtree` / `onReplyDeletedScrubNotifPreview` delete the record AND the claim (a redelivered create can't re-page a dead item); `auditPostModeration` (post reviewed) and `auditCrisisReplyReview` (queue reviewed) delete the record immediately. Heartbeat now `{undelivered, alerted, retriedOk, resolved, scanErrors}`.
- **Verification:** staging 18/19 (the one "fail" was an over-strict expectation: scan A re-created a wiped record and alerted once, but the same run's retry relabelled `never_paged` → `no_admin_token` before the read). Covered: explicit post → record with payload; soft post → nothing; explicit reply → `crisisAlertReply_*` record; one alert on first run, none minutes later; simulated age 2 h / last 61 min → alert; age 7 h / last 2 h → silent; age 7 h / last 7 h → alert; review (post + reply queue) → record gone via the audit triggers; post delete + reply delete → record gone; invalid-token recipient → no claim, record alive, one alert. Prod (review + deletion paths only, synthetic records WITHOUT a page payload so nothing was pushed, neutral throwaway text): 6/6, totals back to 40 posts / 11 users / 0 records; first post-deploy heartbeat 0/0/0/0/0; no alert lines; only benign GET probes in the touched functions' logs.
- **Note:** a recipient whose token is invalid makes the create trigger throw (all sends failed) so Eventarc keeps retrying it for its own window — pre-existing behaviour, unchanged; the watchdog covers the same item on the cadence above.

---

## AUDIT-C1 — iOS "repost a reply" denied by the rules (FIXED in code, rides build 103)

- **Severity:** HIGH (feature dead on iOS) · **Surface:** `PostInteractionManager.repostReply` · **Status:** FIXED 2026-10-28 — iOS code committed, ships in build 103
- The reply-repost payload omitted `moderationStatus`; the posts-create rule has REQUIRED `pending_validation` since 2026-10-07 (the post-repost payload and web already send it). Every reply repost from the app was permission-denied: optimistic "+1", then silent rollback. Fix: the field is added to the payload (start-hidden model; validatePost promotes to live). Reply reposts having no `/p/` share target is by design (both clients suppress the link), not part of this bug.
- **Pin:** `firestore.test.js` "rejects the pre-build-103 iOS reply-repost shape (no moderationStatus)" + the existing faithful-reply-repost case. Staging: the build-103 shape accepted, the old shape still denied.

---

## AUDIT-C2 — burst limiter held the whole burst retroactively and relabelled real holds (FIXED, PROD)

- **Severity:** HIGH (every post of a burst "under review"; hate/threat holds mislabelled as rate limit) · **Surface:** functions `rateLimitPosts` / `setPendingReview` · **Status:** FIXED 2026-10-28 ~23:45 UTC, staging + prod (`--only`, 14 functions, prod set 75 → 75)
- **Was:** the limiter counted the author's posts in the 5-minute window at trigger time (`> 5`), so an 8-post burst made every trigger see 8 and hold all 8, including the first five. And because `setPendingReview` merged the extra fields even when it declined to re-hold an already-held post, a hate/PII hold ended up with `flagReason: rate_limit_exceeded`.
- **Now (owner decision 2026-10-28):** `applyPostRateLimit` counts only the author's posts created BEFORE this one inside the window (`BURST_FREE_POSTS = 5`), so exactly the 6th and later are held regardless of trigger order. The rate-limit flag fields are written only when THIS call created the hold — an existing hold's reason is never touched. **Precedence rule (owner-confirmed):** a `rate_limit` hold is the weakest reason — if the limiter wins the race against a content detector, the content reason UPGRADES `pendingReason` (so a threat posted as the 7th of a burst reads `abuse_threat`, not `rate_limit`); never the reverse. **Documented ordering between CONTENT reasons:** first trigger wins — a URL post reads `pii` or `abuse_spam` depending on whether validatePost or onPostCreated landed first; both are takedowns of the same post and the label only affects the author's banner wording and admin triage. Not changed.
- **Verification:** functions tests (`C2 applyPostRateLimit`, 5 cases incl. scrambled trigger order, window edge, no-relabel, upgrade); staging 8-post burst → 1–5 live, 6–8 `rate_limit`; threat as 3rd keeps `abuse_threat`/`targeted_threat`; threat as 7th now reads `abuse_threat`; prod 6-post burst (neutral text) → only the 6th held, one log line.

---

## AUDIT-C3 — totalLikes went negative / inflated through repost mirroring (FIXED, PROD; owner account repaired)

- **Severity:** HIGH (profile "felt" stat wrong; could not self-correct — the drift job wrote the inflated sum) · **Surface:** functions `onPostDeletedAdjustTotalLikes`, `detectCounterDrift` phase 2, `mirrorCountsToCopies` · **Status:** FIXED 2026-10-28, staging + prod; prod repair applied
- **Was:** `mirrorCountsToCopies` stamps the original's `likeCount` onto plain repost copies for display, but (a) un-repost ran `onPostDeletedAdjustTotalLikes`, debiting that mirrored count from the REPOSTER (staging: -8), and (b) `detectCounterDrift` summed the copies back into the reposter's total (prod: the owner's account read 78 with 2 real likes — 42 + 34 mirrored from two reposted demo posts). (c) The mirror query also matched REPLY-repost rows (they carry `originalPostId` = the parent post) and overwrote their real counters with the parent's.
- **Now:** `isPlainRepostCopy()` (isRepost && no originalReplyId). Delete-time settlement skips plain copies; `recomputeTotalLikes(uid)` (used by the drift job) excludes them; the mirror leaves reply-repost rows alone. Reply-repost rows take likes directly (both clients write likes against the repost doc) and stay fully counted. Invariant: `totalLikes == Σ likeCount over the author's posts excluding plain repost copies`.
- **Verification:** functions tests (`C3 totalLikes vs repost mirrors`, 5 cases); staging: un-repost leaves B at 0 (was -2), reply-repost like credits/debits B correctly, a later mirror pass leaves the reply-repost row at its real count, forced `detectCounterDrift` leaves B at 0 with a mirrored copy of 3; prod 6/6 (repost → like → un-repost; totals restored to 40 posts / 11 users). **Repair (owner go, 2026-10-28):** `fading_drift_774` totalLikes 78 → 2 (dry run re-checked immediately before, identical breakdown, guarded compare-and-set). No other prod user drifted; staging 0.

---

## AUDIT-C5 — author could not open their own held post (web FIXED, PROD; iOS banner rides build 103)

- **Severity:** MED (every user whose post is held) · **Surface:** web `postVisible` / `viewPost`; iOS `PostDetailView` · **Status:** web FIXED 2026-10-28 (staging + prod hosting); iOS parity in build 103
- **Was (web):** the profile listed held posts with "under review." but `#/post/{id}` ran `postVisible()`, which drops `flagged` posts before any ownership check → "this post has disappeared." for the author.
- **Now (web):** `postVisible(d, { own })` skips the flagged check for the author only; expiry and block checks still apply; the detail shows the pending banner. Other users still get "this post isn't available." (rules deny the read). **iOS (owner 2026-10-28, build 103):** tapping an own held post already opened it; `PostDetailView` now derives `ownPendingReview` from the live listener (`moderationStatus == pending_review && authorId == me`) and shows the same `PendingReviewBanner` (reason label + crisis support line) above the post.
- **Verification:** staging headless Chrome — author sees the banner + text, another signed-in user sees "isn't available"; prod hosting live. **Owner check (2026-10-29 ~03:23 UTC):** opened the post from the profile fine, but saw NO banner and a live-looking detail. Root cause: the post ("Sarah broke up with me last week.") was never held — the server detector returns no flag for a bare first name (the web compose gate warns, but the server decides) — the profile row said "under review." because it rendered during the few-second `pending_validation` window before validatePost promoted it, and by the time the detail opened the post was live (it still is). Staging re-check with an admin-held post opened from the profile row: banner shown, composer hidden. **Fix shipped with the v4.0 hosting release:** `pending_validation` now reads "checking your post — this usually takes a few seconds" instead of "under review" (profile rows + detail). Owner re-check pending after accepting v4.0.

---

## AUDIT-PD — product decisions after the multi-user audit (FIXED, PROD)

- **Severity:** policy · **Surface:** rules, validateReply, bannedIdentities, web/iOS composer · **Status:** DONE 2026-10-29 ~03:40 UTC — prod rules released (byte-identical to `firestore.rules`, ruleset `9d012ef6…`), 4 functions via `--only` (set 75 → 75), hosting
- **18+ gate on every interaction (audit §2.6 #5):** `hasConfirmedAdult()` now gates post likes, reply likes, `following` + `followers` rows, saves and reports (was publishing-only). In-app flows always attest before these are reachable; this closes the SDK path. Two legacy pins reversed ("allows likes/saves … when confirmedAdult is false", report fixture).
- **Blocked users can't save the blocker's posts (§2.6 #2):** saved create reads the post and denies when its `authorId` — or a repost row's `originalAuthorId` — has blocked the caller; a missing post keeps the old behaviour. Reporting stays allowed both ways.
- **No replies on held posts (C6) + 2-char minimum (C12):** replies create requires the parent's `moderationStatus == 'live'` (held, pending_validation, missing → denied, author included) and `text.trim().size() >= 2`; `validateReply` deletes under-2-char replies and any reply that still lands on a held post. Web + iOS (build 103) hide the composer on an own held post.
- **Plus-alias bans (B7):** `extractIdentities` also emits `local@domain` for `local+tag@domain` (primary + provider emails), so ban rows are written for both forms and `blockBannedSignups` matches any alias of a banned mailbox. Rows already hashed raw keep matching as before.
- **Restricted users (§2.6 #1):** code already matched the decision (like/save/block/report/delete-own allowed; post/reply/repost denied) — wording only (Terms §4 v4.0).
- **Tests/verification:** `product-decisions.test.js` (+27 rules cases; suite 497, 0 ceiling hits), functions +5 (127); staging 19/19 (`pd-verify-staging.mjs`); prod: ruleset byte-check PASS, validateReply 3/3 with neutral throwaways (totals restored), no errors/denials in logs. Rule-level prod checks for the gate/blocked-save are not runnable headlessly (App Check) — covered by the byte-identical ruleset + emulator suite.
- **Not changed (documented):** content-vs-content hold precedence stays first-wins (see AUDIT-C2).

---

## POLICY-4.0 — Terms + Privacy v4.0, policy version 5 (LIVE on web + site; iOS in build 103)

- **Status:** published 2026-10-29 — toskaapp.com/privacy + /terms "Version 4.0 · Effective October 28, 2026", support page + FAQ updated; web `POLICY_VERSION = 5` live (every existing web account gets the "our terms have changed" gate at next sign-in); iOS `currentPolicyVersion = 5` + label + in-app policy body ride build 103.
- **Why a bump (owner):** several items are real privacy disclosures — moderation records kept after deletion, "what other signed-in users can see", the on-device midnight-expiry note — and with no real users yet re-acceptance costs nothing.
- **Content:** what other signed-in users can see (Privacy §2); notification toggles are push-only (§1); midnight expiry computed on-device from local midnight (§1, §6; Terms §8); share pages exist for any shared post while sharing is on, featuring on the site/Google stays hand-picked (§4; Terms §7); sharing-off up to an hour to clear everywhere; crisis holds on posts and replies (§2); reports + moderation records survive content and account deletion (§6, §7; Terms §10; support + FAQ); restricted = no post or reply (Terms §4); holds cover posts and replies, held posts take no replies (§5); blocking also stops saves, reporting stays (§6); follower-count toggle is display-only (§2 + FAQ). In-app iOS body also fixed a stale "sharing on by default".
- **Verification:** staging web gate 5/5 (v4 account gated → accept stamps 5 + timestamp → routes; fresh signup stamps 5); prod web smoke: modules load, served `POLICY_VERSION` 5, no script errors. iOS re-accept cover reads/writes the same `acceptedPolicyVersion` field (ContentView gate, recordPolicyAcceptance) — build 103.
- **App Store privacy label:** unchanged (no new data type/purpose); dated re-check note in `legal/APP_STORE_PRIVACY_LABELS.md`. **A5 phase 2 note:** when acceptedPolicy* moves to private/data, both gates must follow.

---

## OBS-SHARING-FLIP — owner's `allowSharing` went true → false on prod, 2026-10-29 03:22:13 UTC (OBSERVATION, no change made)

- **Facts:** user doc updateTime 03:22:13Z; `onAllowSharingChanged(…): allowSharing=false — updated 13 posts` at 03:22:18Z; it sits between the owner's own web posts "test 2" (03:22:10Z) and "test 3" (03:22:40Z). No server code writes `allowSharing` (checked: functions, back-fill, shim, repair scripts). The only writers are the web profile checkbox (`onchange` only — never programmatic) and the iOS Settings save batch (build 102 writes the whole settings block incl. `allowSharing` on ANY toggle change, from the value it loaded). Firestore data-access audit logs are not enabled on prod, so the client can't be attributed further.
- **Owner to confirm** which of the two it was; nothing was reset by the tooling. If attribution matters later: enable Firestore data-access (DATA_WRITE) audit logs on prod (cost: log volume).

---

## FIRSTNAME — bare first names: allowed, soft nudge, never featured (FIXED, PROD 2026-10-29; iOS nudge in build 104)

- **Decision (owner, 2026-10-29):** keep allowing bare first names (no server hold — N-17 stands); add a soft, non-blocking compose nudge on iOS + web; never feature a post with a likely first name on the public website / sitemap / site feed (in-app feed untouched) even with sharing on; admin "possible name" badge; wording must not imply first names are blocked. No policy-version bump (clarifications only).
- **Detector:** `likelyFirstName(text)` in `functions/moderation.js` (vendored verbatim to web) + `ContentModeration.swift` (the given-names / ambiguous / relationship-prefix lists hoisted to file scope and shared). Rule: a Capitalized token (or Capitalized possessive) whose folded lowercase form is in the 208-entry given-names list and not in the ambiguous-words / safe-capitalized lists; or a lowercase listed name directly after a relationship prefix ("my ex sam"). **Pinned by `detector-parity.mjs`** (new FIRST corpus, 116/116): every "nudge" line is asserted NOT to be a hold on either layer.
- **Nudge:** "you can leave their name out if you'd like — first names are okay." Posts only (not replies). Web: inline note under the composer (`.name-nudge`), 400 ms debounce, × dismisses for the compose session, post button never affected. iOS: `composeModeBanner` row under the mode banners, same dismiss semantics — **build 104**.
- **Featuring exclusion (server-side; `webFeatured` is Admin-SDK/seed-only):** `onPostUpdated` strips `webFeatured` when the text has a likely first name; `publicFeed` skips such posts; `evaluateSharePage` marks them non-indexable (share page still renders for a shared post, per Privacy v4.0) so the sitemap drops them; `seedLaunchContent` refuses to feature them. **Prod dry run (2026-10-29):** 11 featured posts, 0 would drop.
- **Admin badge:** `docs/admin.html` shows "possible name — …" under a post's text when (a) likelyFirstName hits (list generated from moderation.js at edit time — regenerate if the list changes) or (b) any Capitalized word sits mid-sentence (so names the list misses get a look before featuring). Display only.
- **Wording:** hold dialog (web `gates.js` + iOS ComposeView) now says it's a full name / contact detail and that first names on their own are fine, hint "try “he”, “she”, or “they” instead."; App Store description (`APP_STORE_METADATA.md` — **owner updates ASC**): "we screen posts for full names, contact details and other identifying information before they go live; first names on their own are allowed."; Terms §5 "full names" + "A first name on its own is not treated as identifying" + letters bullet "full name" (md + html, changelog line, no version change).
- **Verification:** functions 130, sharePage unit 21, parity 116/116, iOS compiles; staging 12/12 (`firstname-verify-staging.mjs`): nudge wording/dismiss/post-through, guard strips, clean post kept, publicFeed + sitemap exclude, share page 200+noindex vs index.
- **Prod (2026-10-29 ~16:30 UTC):** 4 functions via `--only` (75 → 75), hosting, push (terms.html + admin.html published). Post-deploy read-only check: 11 featured posts, 0 would drop, all 11 still featured, all 11 share pages `index, follow`, all 11 in the sitemap. Served app.js carries the nudge, served vendor/moderation.js carries `likelyFirstName`. Owner's build-103 held-post retest ("Sarah Johnson …") passed: held, opened with banner, no reply box.
- **Known FP logged (LOW, NAME-FP-DEARJOHN):** "Dear John" is a HOLD today (two Capitalized words = full-name shape, "dear" is not in the title-words guard); a "Dear John letter" post is held as if it named someone. Fix candidate: add "dear" to COMMON_TITLE_WORDS on both layers + a parity case. Not changed in this round.

---

## AUDIT-TIER2-STATUS — what the 2026-10-27 audit's Tier 2 items became (owner triage 2026-10-29)

- **Closed by earlier work:** **B4** (own `private/data` writes) — A5 phase 1 locked the six authorization keys against owner writes and made them the source of truth, so a restricted user can no longer hide their banner or self-attest; other keys in private/data stay owner-writable but nothing trusts them. **C8** closed 2026-10-28. **C12** (1-char replies) closed by the product decisions (rules `trim().size() >= 2` + validateReply). **C14** (auto-restriction never clears) closed by A5's `clearExpiredRestrictions`. **C11** (pii vs abuse_link label race) documented as first-wins in AUDIT-C2, not changed. The `undeliveredCrisisPages` residue in A4 closed by C8.
- **In progress (pre-launch):** **A4** deletion residue (proposal below), then **A3** sharing-off propagation.
- **POST-LAUNCH (owner decision 2026-10-29):** **C7** milestone notifications skip under like bursts (equality on a live count; fix = threshold crossing via before/after); **C9** self-block reachable (rule + iOS row); **C10** second reply / re-follow by the same person never notifies (deterministic notif ids); **C13** explicit-crisis edit re-pages and bulk approve publishes crisis text unseen; **D2** `meta/tagCounts` include held posts (Explore shows the stored number); **follower-count mirror** (server-maintained public count behind the hide toggle, so the toggle becomes real privacy rather than display-only).

---

## AUDIT-A3 — sharing-off propagation (FIXED, PROD 2026-10-29)

- **Severity:** MED (policy accuracy: "ends both, including for existing posts" vs up to an hour of public exposure) · **Surface:** hosting cache headers (`firebase.json`), `publicFeed` memo + header, `sharePage` / `shareCardImage` / `postsSitemap` headers, policy wording · **Status:** staging deployed + measured; **prod pending**
- **Was:** share page + card image `max-age=300, s-maxage=600`, sitemap `3600/3600`, public feed `600/600` + 10-min in-instance memo → after sharing off, a post could keep serving for up to an hour (sitemap) and the feed for up to 20 min. There is no CDN purge for hosting rewrites, so cache lifetime is the only lever.
- **Now (owner decision 2026-10-29):** share page + card image `max-age=60, s-maxage=120`; sitemap `300/300`; public feed memo 2 min + `120/120`. Privacy §4 / Terms §7 / in-app iOS policy body: "share pages and the website clear within a few minutes" (was "up to an hour"), changelog lines, no version bump.
- **Measured on staging (warm CDN, polling every 15 s after `allowSharing → false`):** share page 122 s, card image 122 s, public feed 122 s, sitemap 304 s — each exactly at its new cap. Cost: a few more function invocations per minute on three low-traffic endpoints.
- **Prod plan:** hosting (headers) + `--only functions:publicFeed,sharePage,postsSitemap,shareCardImage` (77 → 77), push (policy pages). iOS wording rides the next build.

---

## AUDIT-A4 — account deletion left identifying residue (FIXED, PROD 2026-10-29)

- **Severity:** MED (privacy: a deleted user's uid/handle/text survived in admin audit rows and in other users' saved/liked reply snapshots) · **Surface:** functions (`auditPostDeletion`, account cascade, new `onReplyDeletedScrubSnapshots`), `firestore.indexes.json` · **Status:** code committed 7bf2101; staging deployed + verified; **prod pending**
- **Was:** `auditPostDeletion` wrote a `post.delete` row (authorId + handle) for EVERY post deletion — author self-deletes, whisper/midnight expiry, the account cascade (staging: 830 such rows; prod: 97). Other users' `likedReplies` / `savedReplies` snapshots (reply text, handle, uid) outlived both the reply and the account. The `undeliveredCrisisPages` residue was already closed by C8; reports against the user are retained by policy.
- **Now:** audit rows only when the dashboard stamp (`deletedBy`) is present — the admin log stays an accountability record and nothing else names the user. `onReplyDeletedScrubSnapshots` removes other users' snapshots of a deleted reply (collection-group by `postId`, filtered to the reply id). The account cascade gains `cleanupReplySnapshotsForUid` (collection-group by `authorId`). Four collection-group single-field indexes added (likedReplies/savedReplies × authorId/postId).
- **One-off scrub:** delete existing `post.delete` rows whose actor is "author" — staging applied (832 rows → 0); **prod dry run: 97 of 102 rows (47 of them the owner's own self-deletes), awaiting go.**
- **Verification:** functions 143 (+4); staging 8/8 (`a4-verify-staging.mjs`): snapshots removed on single reply delete (others untouched), self-delete leaves no row, the REAL self-delete path (pendingDeletions + auth delete) cascades and removes the snapshots, no audit row names the deleted uid/handle. **Prod (2026-10-29 ~19:10 UTC):** indexes deployed (4 CG indexes ready after ~3 min), 3 functions via `--only --force` (76 → 77, only `onReplyDeletedScrubSnapshots` added), throwaway cascade check 5/5 (`a4-check-prod.mjs`, totals restored), audit-row scrub applied (97 → 0 non-admin `post.delete` rows), no function errors.

---

## B123-PASS-2026-11-09 — owner device pass on 123 → build 124 (FIXED in code; prod HELD)

- Owner on 123: GIFs instant ✓, profile opens with content ✓, reply spacing notice ✓; **repost undo still needs two taps on the phone** while the simulator stand-in passed → traced ON THE DEVICE (temporary `RepostTrace` → NSLog + Documents/repost-trace.log, read over USB with `devicectl device process launch --console`; log in `~/toska-review-artifacts/2026-11-05-device-perf/repost-console.log`). Three defects, all visible in the trace:
  1. **Queued taps gave no feedback.** The 123 queue was right, but the optimistic flip + haptic only ran when the in-flight write cleared (0.1–0.5 s on the owner's Wi-Fi, longer on cellular) — every undo tap in the trace landed inside a running repost write and the owner tapped again inside the gap. **Fix:** every queued action (repost, undo, felt, save, reply like/save/repost/undo, follow) flips NOW (optimistic state + haptic + `.postInteractionChanged`) and only the write waits; the re-invocation carries `alreadyFlipped: true` and `RateLimiter.skipFirst` swallows its duplicate optimistic callback so counts don't move twice.
  2. **Leftover 2 s rule.** `if let last = lastRepostTime(for:)… < 2 { return }` was still in `repost()` (the 123 removal never applied — unasserted replace); the trace shows three consecutive repost taps dropped silently in the detail and two in the feed. **Fix:** removed (the in-flight queue serializes; validatePost's burst limiter covers abuse).
  3. **Restored row flipped back.** After an undo the original row is restored; a listener snapshot from BEFORE the delete lands ~100 ms later and the fresh row accepts "reposted = true" then "false" (trace: three `ROW ECHO … ACCEPTED`). **Fix:** `FeedViewModel.recentRepostTaps` — the listener keeps each post at its last tapped value for 3 s (`fetchRepostedPostIds` merge), so no row needs its own suppression window.
- **Live re-test on the fixed build (108 taps, feed + detail + profile): every tap registered immediately; queue depth never exceeded one (41 queued / 41 released).** Two more defects surfaced in that run and are fixed: (4) `ProfileView` reloaded `loadMyPosts()` 0.7 s after every repost/undo while the delete was still landing, so the undone repost came BACK on the reposts tab — now the row is removed locally at once and the reload waits for the in-flight write (+0.8 s); likes/saves reload the same way. (5) "2 reposts": `PostDetailView`'s live listener re-applied the server's not-yet-decremented `repostCount` between an undo and the next repost tap, and the optimistic +1 landed on top — a 4 s hold after each tap (latest server value applied when it ends); the row's echo window lengthened 1.5 → 4 s for the same fan-out lag. Also added a "you reposted" line to the post detail (owner: the detail showed nothing after a repost).
- **(6) Stale row state after a swap — the real "feed repost not working" (device trace, 2026-11-10):** the feed swaps the original row for the repost row on repost and back on undo; a row removed and re-added within ~0.5 s came back with its OLD `@State` (three taps show the restored original still `isReposted=true` → the repost tap ran an undo; once the repost row came back `isReposted=false`). Detail and profile never swap rows, which is why they passed. **Fix:** `FeedColumn.feedRow` identity = `post.id` + the time of the last repost/undo tap on that post (`FeedViewModel.recentRepostTaps`), so every tap mints a new row that seeds from the store. Verified live: 20 consecutive feed taps, button state == store state on every one.
- Open question from the owner: "repost goes to the top of the feed" — on tap the row updates in place; after any refresh your repost (new createdAt) ranks at the head of for-you by score, so the original's position moves. Owner to say whether the scroll jumps or the post moves.
- **(7) 124 regression + the last stale-state root (owner on 124: "some taps don't show the increase or turn it white", 2026-11-10):** the per-tap row identity from (6) rebuilt the row and re-seeded its count from the stored server value, wiping the optimistic +1; and the highlight still depended on per-row `@State`. **Fix (build 125):** `FeedPostRow.isReposted` is no longer row state — it reads `InteractionStateStore.repostedPostIds` (updated synchronously by every tap, late echoes filtered 3 s by `recentRepostTaps`), so no copy can go stale on any screen; row identity back to `post.id`; result closures no longer assign the flag. Simulator: test14 (immediate / quick / settled undo + chain) and test15 (felt / save / follow) pass with and without the latency stand-in.
- Temporary `RepostTrace` removed before the 124 archive (`remove-repost-trace.sh`).
- Simulator regression (`test14`/`test15`, 2 500 ms stand-in) re-run on the 124 code; temporary trace removed before the TestFlight archive.

---

## B122-PASS-2026-11-05 — owner device pass on 122 → build 123 (FIXED in code; prod web + validatePost DEPLOYED 2026-11-05; commits PUSHED)

- **Prod go (owner 2026-11-05):** `firebase deploy --only hosting` + `functions:validatePost --force` on toska-4ebf4 — both "Deploy complete"; app.toskaapp.com serves `repostCollapse.js` and `collapseReposts` (5 call sites); validatePost logs clean (no errors). `git push origin main` 62e6fcf..325923b (118–122 commits).
- **1 GIFs blank for ~1 s before appearing:** the full-frame decode (now off-main) finished before anything was shown. **Fix:** `StableGifPreview` downloads, decodes frame 0 as a 480 px thumbnail (≈10 ms, off-main) and shows it at once, then swaps in the animation when all frames are ready; `GifLoadGuard.firstFrameCache` (200 entries) alongside the decoded cache so revisits are instant; feed rows prefetch the GIFs of the next 4 rows on appear (download + first frame + frames, cached by URL); the soft placeholder stays until the first frame exists. All decoding `nonisolated` → never on the main actor.
- **2 Profile blank for a second on open:** on a cold launch the header/posts arrive from Firestore only; the eager list then lays out 30+ rows at once. **Fix:** `ProfileSnapshotCache` (JSON in Caches/, keyed by uid) saves header + up to 50 posts after every successful fetch and is painted on the first appear before the refresh; the posts tab shows `SkeletonFeed` until the first paint instead of empty space; cleared on sign-out.
- **3 Repost undo needed two taps (owner, 122):** two silent-drop windows right after a repost — (a) `PostInteractionManager.unrepost` `guard !isRepostInFlight else { return }` while the repost's four round trips (dedup query, post read, author read, transaction) were still running (1–3 s on cellular); (b) the reposted-ids listener's pending-write snapshot can omit the just-written doc (serverTimestamp unset, query ordered by it), flipping the fresh in-place row back to "not reposted" until the server ack. Simulator (fast Wi-Fi) never hits either window — single-tap undo passed at +0.2 s / +1 s / +6 s. **Fix:** `RateLimiter.whenClear` queues a tap behind the in-flight write (polls 100 ms, ≤ 8 s) instead of dropping it — applied to like, save, repost, unrepost and the four reply variants; the 2 s / 1 s "last action" rules on repost / reply-save / reply-repost removed (they dropped repost → undo → repost); follow/unfollow queued the same way (`followInFlight`) instead of the 1 s rule; the reply 5 s spacing shows the gentle notice "one reply at a time — give it a few seconds." instead of returning silently; posting keeps its visible "posting…" state (not a drop). Listener merges (`formUnion`) while `hasPendingWrites`, replaces on server snapshots.
- **Slow-network reproduction:** Network Link Conditioner isn't installed and `sudo` needs a password here, so a DEBUG-only stand-in does the job: `TOSKA_SIM_LATENCY_MS` (launch env) keeps each in-flight flag set that long after the write completes (`RateLimiter.afterDebugLatency`), and `TOSKA_SIM_LEGACY_DROP=1` restores the pre-123 drop for a true before/after. `test14_repostUndoSingleTap` (immediate / quick / settled undo + repost→undo→repost chain) and `test15_actionsUnderLatency` (felt, save, follow, reply spacing) run with 2 500 ms; results in `~/toska-review-artifacts/2026-11-05-device-perf/undo*/lat15*`.
- Not a bug: a brand-new post can show below a slightly older one in for-you until its score lands (ranked feed); the profile tab is strictly newest-first.

---

## PERF-2026-11-05 — device profiling on the owner's iPhone 15 Pro Max → build 122 (FIXED in code; prod HELD)

Measured with Instruments on build 121 (Release, dev-signed) — traces + exports in `~/toska-review-artifacts/2026-11-05-device-perf/`, write-up in local `DEVICE_PERF_2026-11-05.md`. App Store Connect had no hang/crash diagnostics for 116–121.

- **1 GIF frames decoded on the MAIN thread by Core Animation — one 3.27 s severe hang (feed), same path froze post detail:** `CGImageSourceCreateImageAtIndex` returns lazy images, so the "off-main decode" decoded nothing; CA decoded every WebP frame at commit when the image view started animating (3,196/3,319 samples in ImageIO under `CAKeyframeAnimation CA_prepareRenderValue`). **Fix:** `AnimatedGifImageView.animatedImage(from:)` now builds frames with `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceShouldCacheImmediately` + 480 px max (decoded + downsampled on the detached task); stills go through `preparingForDisplay()`. Feed row, post detail, compose preview all route through `StableGifPreview`, so one change covers them.
- **2 SwiftUI scroll load — 22 hitches (425 ms) + 13 interaction delays of 48–107 ms per minute of scrolling; main thread 22 % busy, 35 % peaks:** (a) every `FeedPostRow` carried 2 `.fullScreenCover` + 2 `.confirmationDialog` → ~14k presentation-preference updates per 10 s of scrolling (`HostPreferencesTransform<ConfirmationDialog.PreferenceKey>` 8,250, `SharingActivityPickerPresentation.Key` 4,125, `SheetPreference.Key` 1,664; one second had 49,740 updates). **Fix:** rows set ONE request on `RowPresenter.shared` (share / report / block / admin-delete); `MainTabView` hosts the covers and dialogs once via `.rowPresentationHost()` (covers rows in pushed screens too). Context menu unchanged. (b) `FeedViewModel` publish storms — every `@Published` change re-ran FeedView, both FeedColumns, FeedHeaderCard and ReconnectReconcile (1,712 updates each in ~10 s; bursts of 63 publishes in 1 ms from the liked/saved/reposts listeners + didSet mirrors). **Fix:** `likedPostIds` / `savedPostIds` / `repostedPostIds` live ONLY in `InteractionStateStore` (vm properties are pass-throughs; `FeedColumn` observes the store); `ReconnectReconcile` holds a plain `vm` reference and listens to `$reconnectNewPosts` / `$isFetchingPosts` (now `@Published`) only.
- **3 Launch work on the main thread (warm launch: brief hangs 118 ms + 180 ms):** paper-grain Core Image generation ≈ 140 ms at first body; `prewarmKeyboard()` from `dismissKeyboardOnTap()` ≈ 1 s of main-thread time spread over the first seconds. **Fix:** `ToskaPaperGrain` generates its tile on a utility task and fades it in; the prewarm now waits for `.feedDidFirstPaint` (posted by FeedView when `hasLoadedOnce` flips) + 1.5 s, at utility priority.
- **Not causes (measured):** Firestore on main 10 samples / 120 s; per-document liked/saved reads off-main; no listener storms; no layout loops; no thermal throttling.
- **Gotcha found on the phone (first 122 cut still hung 3.17 s):** `animatedImage(from:)` is a `static func` on a SwiftUI `View` type → main-actor isolated → the `Task.detached` decode hopped back to the main thread. Fixed with `nonisolated` on `animatedImage(from:)` / `frameDelay(at:source:)`.
- **Acceptance (owner's phone, corrected 122, same sessions):** A: 0 hangs ≥ 250 ms (121: one of 3.27 s), scrolling busy 17.7 % → 11.8 %, busiest second 100 % → 34 %, ImageIO on main 3 373 → 0 samples (12 591 on background threads); B: view-body updates/s ~900 → ~220, FeedView/FeedColumn/ReconnectReconcile observer updates 1 712/1 142/1 712 → 0; C: hitches 22 → 14 per minute (425 → 329 ms), interaction delays unchanged at ~12–13/min (≤ 102 ms); the one 3.45 s "hang" in C-122 has zero main-thread samples (app suspended while the owner switched away) followed by a 446 ms scene re-activation microhang — not scrolling. Full table in `DEVICE_PERF_2026-11-05.md`.
- **Follow-up (owner, 122):** repost on a row "makes me double click it for it to work" — not yet reproduced; check the stats-line repost button vs the row's NavigationLink press and the server-truth guard's async path. Row actions re-verified on staging by `test13_rowActions` (feed, search, profile, most felt → detail); hidden columns by `test12`.

---

## B120-PASS-2026-11-04 — owner device pass on 120 → build 121 (FIXED in code; prod HELD)

- **2 Profile list "freezes partway, last post cut off by the bottom bar, only after scrolling up and down several times does it reach the end" (iPhone 15 Pro Max, standard text; build 120):** structural, not tunable. The profile was a lazy list inside a lazy pager — `SwipePager` (horizontal ScrollView + LazyHStack + GeometryReader-measured page frames) → per-page vertical ScrollView → LazyVStack — so the list's scrollable height came from whatever the lazy stack had materialised inside a lazy page, and every row was one whole-row `Button` that swallowed felt/save/repost taps. The feed had already needed the eager-14-row workaround for the same family (FeedView.swift "blank-feed bug"). Not reproducible on an iPhone 15 Pro Max simulator (iOS 26.0 and 17.5, 30-post account, `test09_profileDepth`: flicks, slow drags and 90/160 pt diagonal drags all reached the end in 10–15 passes with no stall), so the fix removes the nesting rather than tuning it. **Build 121:** ProfileView is one plain vertical ScrollView — identity section scrolls away, tab selector sticks under the header as an overlay once the identity section's bottom edge passes the scroll view's top (global-coordinate GeometryReader + onChange; a PreferenceKey version never fired, and a `LazyVStack(pinnedViews:)` version with the list as one 6 000 pt child jumped the offset back ~4 000 pt past ~5 000 pt — both rejected by the depth test), tabs switch in place (horizontal swipe gone, as on the web), rows are an eager VStack with NO outer Button: `FeedPostRow`'s own link opens the (original) post and felt / save / repost / share / own-row repost notice work from the profile like the feed; reposts tab rows draw "you reposted" via `reposterHandle`. `openMyPost`/`openSavedPost` removed (deleted posts are pruned via `.postDeleted` from PostDetailView; stale saved/liked entries are already cleaned on load). Acceptance on the final code: 10 flicks / 13 drags / 11 diag-90 / 15 diag-160, monotonic, selector pinned (`test11_profilePinProbe` asserts it).
- **Feed "similar stuck/freezing feeling" (owner 2026-11-05):** same shape (FeedColumn's lazy tail inside the lazy pager, measured page frame). Simulator baseline (`test10_feedDepth`, 150-post staging feed): 30 passes each of flicks / drags / 120 pt diagonal drags, monotonic, 0 stalls — device-only, like the profile. **Build 121:** for-you / following are two kept-alive `FeedColumn`s in a ZStack (opacity + allowsHitTesting + accessibilityHidden on the hidden one; following created on first visit) — separate scroll positions survive switching, pull-to-refresh / load-more / prefetch / reconnect badge / deleted-post handling untouched, home-tap scroll-to-top unchanged. Most felt: same keep-alive ZStack for today / this week / all time. `SwipePager` deleted. `test12_hiddenColumnsAccessibility` checks the hidden column never resolves in the accessibility tree on both feed tabs and all three periods.
- **Acceptance (2026-11-05, final code):** iOS 26.0 iPhone 15 Pro Max — `test12` hidden-column accessibility ✓, `test10` feed depth ✓ (30 flicks / 30 drags / 30 diagonal, 0 stalls, following column never leaks), `test08` build-120 checks ✓ (own-row repost notice now shows IN PLACE on the profile row), `test09` profile depth ✓ (10/13/11/15 passes), `test11` pin ✓. iOS 17.5 iPhone 15 Pro Max — `test12` ✓, `test09` flick phase ✓ (end in 10) then the TEST RUNNER died inside the app process: `XCTAutomationSupport` → `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__` → `_platform_strcmp` SIGSEGV (`toska-2026-11-05-110513.ips`) — the accessibility snapshotter of the 17.5 runtime logging itself into quarantine on the 30-row eager tree, not app code (no app frames in the faulting thread); the same driver timed out repeatedly on 17.5 before this change. `test01_light` tour re-run on 17.5 for rendering.
- Owner-confirmed on 120: own-row repost notice ✓ (feed row, detail), prompt card top ✓, responses empty state + starter answers ✓, most felt ✓.
- Staging: 30-post account `waiting_ember_410689` (seed-121) used for acceptance; its rows show the "may contain names or contact info" review banner because the validator reads the "b121 #N" marker as contact info (seeding artefact only). Cleaned after the acceptance run (`cleanup-121.mjs`).

---

## B119-PASS-2026-11-04 — owner device pass on 119 → build 120 (FIXED in code; prod HELD)

- **3 "your own words can't be reposted." never showed:** the guard was never reached — on your own rows the repost count is plain text (feed row, profile row, post detail) and the context menu hides "repost" for own posts, so a tap did nothing and said nothing. Fix: the count on own rows is now a tappable control that posts the gentle notice (warning haptic + capsule above the tab bar) with no network; the manager guards stay as a backstop. Screenshot-verified on the simulator (`test08_build120`) on the feed row and in post detail. On the profile tabs the whole row is one Button (open the post) and swallows every nested control — Button, `.borderless`, and a high-priority tap gesture were all tried — so there the tap opens the post, where the count shows the notice.
- **4 Profile list cut off + glitchy + jumps back to the top (owner's phone, standard text):** caused by the build-119 pager change — `containerRelativeFrame([.horizontal, .vertical])` CENTRES a page whose natural size differs from the frame, so the list was shifted and re-laid-out while scrolling. Replaced with an explicit top-aligned frame measured from the pager's own geometry (`SwipePager` now wraps a GeometryReader; pages are `frame(width:height:alignment: .top).clipped()`). Same code path serves the feed and most-felt pagers.
- **7 Prompt card top clipped under the tabs (NEW on 119):** same root cause as 4 — the feed column was centred in its page, pushing the card's 14 pt top padding under the divider. Fixed by the same change.
- **6 "what others said" looked empty:** prod had no answers to that day's prompt (only one answer in the last four days). The empty state existed but had no call to action; it now reads "no one has answered yet. / be the first." with a "write yours" button that opens the prompt compose and refreshes the list when the answer lands. Starter answers seeded on prod (today ×2, yesterday ×2, two days ago ×1, five different App Review accounts; see `PROD_SEED_2026-11-04.md`).
- **5 most felt:** works on device with the starter content.

---

## B118-PASS-2026-11-04 — owner device pass on 118 → build 119 (FIXED in code; prod web unchanged; prod HELD)

- **1 "you reposted" label missing after a repost (iOS):** reposts never refetched the feed (`.newPostCreated` only refetches for composed posts), so after the tap the viewer kept the plain original row with the repost icon lit; the labelled repost row only appeared after a pull. Fix: `FeedViewModel.showRepostInPlace(of:)` — the mirror of the undo swap — replaces the original row in place with my repost row (deterministic id, "you reposted", same position, no scroll jump). Prod check: 0 repost docs on prod at the time (the owner had undone it).
- **3 Reposting my own post — no message (iOS):** the 118 guard was silent (warning haptic only) and only covered callers that pass an authorId (PostDetailView passes `authorUserId`, empty on some paths). Prod check: no self-repost document was ever created (0 reposts total). Fix: the manager now also checks the ORIGINAL's author after the fresh read (server truth) and rolls the flip back, and every refusal posts a gentle notice — new `Notification.Name.gentleNotice` + a self-dismissing capsule above the tab bar in MainTabView ("your own words can't be reposted.").
- **5 Profile list cut off behind the tab bar (owner device):** NOT reproduced on iPhone 15 / iOS 17.5 nor iPhone 16 / iOS 26.0 simulators with 9 posts on every tab (`test07_scrollToBottoms` screenshots: last row fully above the bar). Two changes anyway: `SwipePager` pages are pinned to the pager's full size (`containerRelativeFrame([.horizontal, .vertical])`) so each tab's ScrollView has a bounded height on every runtime, and **prompt responses** — the one scrolling screen that really was covered by the bar (pushed screen that never hid it) — now hides the tab bar like explore / other profile / detail. All other screens verified by screenshot at their bottom: feed, following, most felt, notifications, post detail (bar hidden), settings (bar hidden).
- **4 Prod starter content (KEPT, owner 2026-11-04):** 13 posts spread across the six App Review accounts (demo + 5 buddies), see local `PROD_SEED_2026-11-04.md` + `~/toska-review-artifacts/prod-seed-2026-11-04.json` (delete script alongside).
- **6 lowercase prompt:** confirmed on device.

---

## LISTS-2026-11-03 — list-integrity + visual review → repost duplicates and 11 follow-ups (FIXED in code; STAGING web verified; build 118; prod HELD for owner go)

- **Review (read-only, staging, 2026-11-03):** 20 seeded users / 66 posts over 5 simulated days; every list on iOS and web rebuilt from its exact query+filter+sort and checked for duplicates (id and original), hidden items, ordering, page boundaries, refresh stability and iOS↔web parity (62 checks); real web lists scraped headless and matched 19/19; 92 web screenshots + iOS simulator tour. Write-up: local `LIST_INTEGRITY_REVIEW_2026-11-03.md` (gitignored); artifacts in `~/toska-review-artifacts/`.
- **F1 FIXED (both):** original + repost shown as separate rows in for-you (2 on page 1, 5 across pages), following (3 rows for one post), search. Rule: one row per original (`originalPostId ?? id`); the repost wins (label, its own time); later reposts dropped; **own-original exception** — the viewer's own words keep their original row and reposts of them are dropped; across pages a key already on screen is dropped (no reorder). Pure logic in `toska/RepostCollapse.swift` ↔ `webapp/js/repostCollapse.js`, pinned by `firestore-tests/repost-collapse-parity.mjs` (10 cases, Swift compiled, in `test:pins`). Applied on iOS in fetchPosts, loadMorePosts (seed = keys on screen), following, server search, reconnect reconcile and OtherProfileView; on web in fetchForYou (+ "more" via `cache.seen`), fetchFollowing, server search, fetchOtherPosts. **Undo in place (iOS):** withdrawing my repost swaps my row for the original rebuilt from the copy (no refetch, no scroll jump). **Self-repost blocked on iOS** (web parity): manager returns the unchanged state, row gives a warning haptic.
- **F0 FIXED (iOS 17):** the trending tab crashed 2/2 on the iOS 17.5 simulator (`EXC_BAD_ACCESS` in swift_getTypeByMangledNode on AttributeGraph's layout thread for `TopPeriodColumn`) and passed on iOS 26 — the iOS 17 runtime can't demangle the `() async -> Void` field the Xcode 26 toolchain emits. `TopPeriodColumn.onRefresh` is now a completion-style sync closure. Deployment target stays 17.0. Repro + regression: `toskaUITests/ListReviewTourTests` (`test05_trendingOnly` and the full tour, iOS 17.5 simulator), added to `build/ios-uitest.sh`.
- **F2 FIXED (web):** most-felt today/week ranked every repost copy (mirrored likeCount) → one post filled ranks 01–03; `viewTop` now drops `isRepost`, like iOS.
- **F3 FIXED (web):** "replies" heading and the compose footer note sat on the page edge; both now carry the row inset (28px).
- **F4 FIXED (iOS):** felt/saved tabs showed auto-hidden (flagged, status live) posts → `profileSavedPost` drops `flagged`.
- **F5 FIXED (iOS):** another user's profile showed their repost of someone I blocked → `originalAuthorId` hidden-author check.
- **F6 FIXED (iOS):** a reply whose parent is gone was promoted to a root; now dropped like web.
- **F8 FIXED (web):** a user I blocked showed a header + "nothing shared yet."; now "this profile isn't available." like a user who blocked me (iOS closes the view).
- **F11 FIXED (iOS):** prompt text no longer capitalised on the feed card / responses header — lowercase everywhere, matching web and the "answering:" line.
- **F12 FIXED (iOS):** profile header "N posts" counted reposts while the posts tab excluded them; header = all − reposts (two count queries).
- **F9/F10:** owner device check on 117 — no overlap, tab row stays put; no change.
- **Verification:** pins green (incl. the new parity pin); staging web verified headless (for-you page 1 + more one row per original, own-original wins, viewer's own repost wins, blocked author hidden, following clean, most-felt week no repost rows, blocked profile message, alignment by text position, search clean); iOS 17.5 simulator tour on build 118 (fresh install, light + night, every main screen incl. trending, compose, search, prompt responses, notifications, profile tabs, settings): all tests pass, **no crash reports** during the run (the only reports on the machine are yesterday's two from the unfixed 117). One earlier tour failure was the test driver (an edge-swipe fallback after the settings screen left SwiftUI animating so XCUITest never got an idle snapshot); a 90-second compose hold with host-side `sample` showed the main thread idle — not an app issue. Driver fixed (reliable back tap, late "Save Password?" sheet).
- **Post-launch log:** F7 reply counts include replies hidden from the viewer; orphan-reply behaviour now matches web; the repost collapse hides a stranger's repost row when it is the viewer's own words even if their original is off-page (their post stays on their profile).

---

## PROMPT-2026-11-03 — daily-prompt automated check (FIXED in code; STAGING verified; build 116 on TestFlight; prod web + validatePost HELD for owner go)

- **Check (read-only, staging):** fake-clock runs of the real web `dayOfYear`/`todaysPrompt`/`todaysPromptDate` and a Swift mirror of the iOS selection code (392 instants, LA/Tokyo/London/Auckland); 26 client-SDK posts through rules + `validatePost`; headless Chrome signed in to `toskastaging.web.app` with per-zone timezone emulation and a fixed clock across midnight; `docs/prompts` parsed against the list (395 pages, 6430 links, generator diff identical, live site byte-identical); parity pin + deployed indexes on both projects. Throwaway accounts removed afterwards (verified 0 left). Full write-up: local `DAILY_PROMPT_CHECK_2026-11-03.md` (gitignored).
- **F1 (web) FIXED:** `dayOfYear()` divided `(now − Dec 31 00:00) / 24h`, an hour short during DST — the card showed yesterday's prompt 00:00–01:00 in LA/London (DST months) and tomorrow's 23:00–24:00 in Auckland (NZ standard time); iOS was right, so the platforms disagreed for that hour. Now the ordinal of the local calendar date via `Date.UTC`. Verified: 392/392 fake-clock cases agree with iOS; Chrome at 2026-10-31 00:30 PDT shows #304 (was #303).
- **F2 (web + iOS) FIXED:** the prompt card did not roll over while open, and "write yours" re-read the date at click → yesterday's prompt text/tag filed under today's date (reproduced 4/4 zones). Web: text, tag and date come from one render; the card and an open prompt compose re-evaluate every minute and on `visibilitychange` (banner, stamped date and auto-picked tag move together; typed text stays). iOS: `FeedViewModel.promptDayKey` + `refreshPromptDay()` on `UIApplication.significantTimeChangeNotification` and foreground return (re-renders the card, re-fetches the user's answer); `ComposeView` follows the day the same way (`promptDayOverride`/`effectivePromptDate`, tag swapped only if it was still the old prompt's). Verified on staging web: card #306 → #307 after a poke across midnight; post after rollover = `2026-11-03` + the Nov 3 tag; compose opened at 23:59:30 and posted at 00:00:30 = new banner, new date, new tag.
- **F3 (functions) FIXED:** `validatePost` accepted any `yyyy-MM-dd`-shaped promptDate (`2099-01-01`, `1999-12-31`, `2026-13-45` all stored live). New `promptDateIsPlausible`: real calendar date within `[UTC today − 2, UTC today + 1]` (UTC+14 … UTC−12 plus the cross-midnight compose); anything else stripped as before. Tests: `functions-tests` 180/180 (4 new). Staging after deploy: 2099 and today−3 stripped; today and today−2 kept.
- **F4 (iOS) FIXED:** `PromptResponsesView` hid only blocked/blocked-by authors; auto-hidden answers (`flagged == true`, status still live) and expired whispers/midnights (until the 10-min cleanup) showed. Now the same two checks as the feed. Web already had both.
- **F5 (web) FIXED (owner: one answer per day on both platforms, UI-level):** the web card now looks up my post for today's promptDate (`(authorId, promptDate)` index, same query as iOS) and shows "✓ your response" (opens the post) instead of "write yours"; delete the post and the card returns to "write yours". Verified on staging. No server enforcement.
- **Build 116** (all iOS changes) uploaded + processed + internal group 2026-11-03 18:40 UTC. Owner device pass pending; prod web/functions deploy and push held.
- **"answering:" context line (owner 2026-11-03, build 117 + web):** answers showed their prompt only on the iOS feed/own-profile rows (plum line, not tappable); web showed nothing anywhere, and no surface could open a past day's answers. Now both platforms render `✦ answering: <prompt>` above an answer's text on feed rows, profiles (own + others, liked/saved tabs), explore/search results and post detail (rows clamp to two lines, detail full), tappable to that day's "what others said" — iOS `PromptContextLine` → `PromptResponsesView(promptDate:)`, web `promptLine()` → `#/prompt/yyyy-MM-dd`. The responses page is date-aware ("today's prompt" vs "prompt for 1 nov"; "no one answered that day."), runs the same query + filters for every date, and the prompt is derived from promptDate with the card's own day-of-year pick. Reposts of answers stay as they are (no promptDate). Verified headless on staging: row line + clamp, plain posts untouched, tap → `#/prompt/<today>`, detail full line → past-day page with only the live, unblocked, unflagged, unexpired answer, derived text == the card on that date, bad date route → `#/prompt`. Build 117 uploaded + internal group 2026-11-03 19:3x UTC. Owner device pass pending; prod web/functions + push held.
- **Post-launch log (owner 2026-11-03):** (a) 29 prompts can never be "today" — indices 0 and 367–394 (day-of-year runs 1–366, `% 395`), and the sequence repeats on the same calendar dates every year; (b) both "what others said" lists cap at the 100 newest answers with no load-more.

---

## BREAKIT2-2026-11-02 — deleted-post handling (LIVE: build 115 = launch candidate; prod web deployed 2026-11-03 15:51 UTC)

- **Found (owner batch 2 on 111):** opening a post deleted elsewhere flashed blank and dismissed silently; the row stayed in the feed even after pull-to-refresh; replying while the post was deleted dismissed too, and the reply text was unreachable. Root causes: the detail view's live listener called `dismiss()` on `exists == false` (and on expiry) without any message and without the app-wide `.postDeleted` broadcast (only an own-delete posted it); the feed refetch could keep a stale list three silent ways — a failed query only showed an error when the list was empty, an in-flight fetch that never completed pinned `isFetchingPosts` so every later refresh was skipped, and a `.default`-source query served from the local cache while the server was briefly unreachable still contained the deleted doc. The typed reply was saved to a per-post reply draft that no longer had a post.
- **Fixed (iOS):** `markPostUnavailable()` — stays on screen with "this post isn't available anymore." (`PostUnavailableBanner`), hides the reply bar, broadcasts `.postDeleted` so the feed, following list, server search results, profile/saved/liked tabs and the prompt/anniversary cards drop the row immediately; only a server-confirmed absence counts (cache events ignored). A typed reply is shown as "this post was removed, so your reply couldn't be sent." with the text selectable + a copy button, and moved into the compose draft; a reply write denied because the post is gone takes the same path. Feed refresh: a new fetch supersedes an in-flight one (generation-guarded) instead of being skipped; `getDocumentsAsync(source:timeoutSeconds:)` (12 s, resolves exactly once); a cached result while online triggers one `.server` retry; a failed refresh with a populated list shows "couldn't refresh — pull to try again". Expiry while open uses the same in-place path. Reposts of a deleted original (cascade-deleted copies) and admin deletions hit the same listener → same fix.
- **Fixed (web):** a post found missing on open is dropped from every cached feed tab (`dropFromFeedCache`) and the message reads "this post isn't available anymore."; a reply denied because the parent is gone says "this post was removed, so your reply couldn't be sent — your words are still in the box." and keeps the text; profile empty state → "nothing here yet. when you're ready, write." (iOS already said "nothing here yet.").
- **Build 112 retest (owner 2026-11-02):** deleted post → in-place message + row gone ✓; reply while deleted → message, text kept, in draft ✓; **refresh after airplane mode OFF did NOT refresh.** Root cause: the phone's monitor reports connected within seconds, but the Firestore SDK reconnects its own stream with exponential backoff (seconds to ~1 min); inside that window a `.default` query is answered from the on-device cache (stale, deleted post included), the single `.server` retry fails because the SDK still considers itself offline, and the failure was swallowed — cached list redrawn, no message. **Build 113:** (1) patient server retry — up to 4 attempts 2 s apart inside the budget; (2) never silent while online — if every server attempt fails the cached list stays with "couldn't refresh — pull to try again" (offline stays quiet; the app-wide banner covers it); (3) `NetworkMonitor` cycles Firestore's network off/on on the offline→online transition, which resets the SDK's backoff (queued writes survive, listeners only get cache-flagged snapshots meanwhile — the detail view ignores cache-based absence — and the banner is NWPath-driven, so no false states); (4) `reconcileAfterReconnect()` 3 s after reconnect: server-only first page, removes only rows the server no longer serves **inside that page's time range** (older paged-in posts untouched), never reorders/replaces the visible list, and routes genuinely new posts to the existing "new posts" badge; tapping the badge does the full refresh + scroll-to-top. Reconnect modifiers live in `ReconnectReconcile` (FeedView's body chain hit the type-checker limit).
- **Build 113 retest (owner 2026-11-03): the row still did not clear on its own after reconnect** (pull-to-refresh did clear it). Cause: a server read while the Firestore client still thinks it is offline fails *immediately*, so the reconcile's "4 attempts, 2 s apart" covered only ~6 s from t+3 s — shorter than the stream handshake + App Check token refresh after airplane mode; the loop also aborted silently on the OS path's post-airplane flicker; and the trigger relied on SwiftUI observing the `@Observable` monitor inside an `onChange`. **Build 114:** `NetworkMonitor` posts `.networkDidReconnect` on the offline→online transition (after the Firestore cycle) and the feed subscribes with `onReceive`; one shared patient loop (`serverSnapshot`, server-sourced reads every 2 s for up to 15 s, flicker-tolerant) for both the reconcile (starts t+2 s) and pull-to-refresh; if the window passes with no server result while online → "couldn't refresh — pull to try again". **TEMPORARY, MUST REMOVE BEFORE THE LAUNCH BUILD:** `ReconnectDiagnostics.enabled = true` (FeedViewModel.swift) shows a small status line in the feed ("reconnected — checking the feed…" → "feed up to date" / "removed N posts…" / "couldn't reach the server in 15 s") so the owner can confirm the reconcile fired from a TestFlight build. Owner decision: if 114 still doesn't clear the row on its own, pull-to-refresh is the accepted behavior and launch is not blocked on it.
- **Build 114 retest (owner 2026-11-03): all pass** — the deleted post cleared on its own after reconnect, the pull right after reconnecting removed it, and a new post while scrolled stayed in place with the "1 new post · tap to see" badge. **Build 115 (launch candidate):** the temporary `ReconnectDiagnostics` flag and status line are REMOVED (binary checked for the strings); the "cached result then every server retry failed → couldn't refresh" line was already in. Badge polish: when the reconnect reconcile finds new posts it prefetches the ranked first page in the background (`deferredFeed`), so tapping the badge applies it instantly; if a fetch is still needed the badge shows a spinner until it lands; a pull-to-refresh always publishes (clears any deferred page). **Prod web deployed 2026-11-03 15:51 UTC** (served files verified; no errors; watchdog nominal). **Test account `tired_moon_193` deleted 2026-11-03** (user doc + cascade, auth user, its 1 post; verified: 0 posts, 0 replies, 0 notifications, 0 reports, no handle row, no auth user; prod totals 42 posts / 11 users / 11 handles).
- **Also checked:** sharing on the owner's test account `tired_moon_193` was set at sign-up (doc create time = update time, the sign-up writes the checkbox state, no default-checked attribute, no sharing-change run) — the opt-in default is correct. The test account is kept until the owner finishes batch 2 on 112.

---

## BREAKIT-2026-11-02 — owner break-it test fixes (LIVE: build 111 = launch candidate; prod web deployed 2026-11-02 17:56 UTC)

- **Compose footer under the keyboard (#1).** The promise line ("no name, no photo. read by a safety check before it goes live.") moved from the footer to the note stack above the editor on iOS and web; the web footer keeps only the length note.
- **Duplicate posts after a mid-post disconnect (#2).** Found: the draft buffer was cleared only when the server confirmed the write, so a disconnect mid-post left the text in the draft while the SDK's queued write landed later → next compose re-offered the same words → second post. Fixed: (a) the buffer is cleared the moment the write is issued and restored only on a definite error (the editor keeps the text either way); (b) **one stable client-chosen post id per compose session** (`toska_composeDraftPostId`, 32-hex; an edited draft uses `fromdraft_{draftId}`) used as the document id, so a second submission targets the same doc and the rules deny it as an update (authors may only change `text`/`editedAt`; `create` has no id constraint — client ids were already used for reposts). The client treats "permission denied + the doc exists with my authorId" as success. Web: `draft_{uid}_compose_id` in localStorage, `createPost({ clientId })` → `setDoc`, same dedupe; cleared on success and by `clearDrafts`. Reconnect: `NetworkMonitor` is `@Observable`, so the post button re-enables on its own and the text stays.
- **Offline wording + cancel (#3).** Confirmed: cancel dismisses with no prompt and the dismiss handler writes the editor text to the encrypted on-device draft store, online or offline, restored on the next compose — so the banner's promise is true (device-local). New banner: "you're offline. your words are saved here — leave or close the app and they'll be waiting." (web offline error box uses the same line). The first keystroke after going offline writes immediately (no 0.5 s debounce), closing the force-close window.
- **Dark mode mixed palettes (#4).** Root cause: toska paints its own light/night backgrounds while anything using SwiftUI defaults (unstyled text, keyboard, cursor, alerts, sheets, chrome) followed the phone's dark mode; plus one bug — the feed row passed `nil` as the handle color for other people's handles, which resets to the system default instead of inheriting → white handles on the light background. Decision (owner): **palette = night when the phone is in dark mode OR during night hours (< 5), light otherwise; the window's color scheme is pinned to that palette** (`ToskaColorSchemePin`, `LateNightThemeManager.systemPrefersDark` from the screen's trait collection, re-checked on activation and every 60 s). Handle color fixed. Web: night palette when `prefers-color-scheme: dark` OR night hours (`applyTheme`, media-query listener + 60 s tick); the night block's duplicate `--faint`/`--dot` removed and the real values raised (6.9:1). Simulator: iPad in dark mode renders the full night palette; SE policy screen consistent in both modes. **Owner device pass on build 111 (2026-11-02): all screens readable in dark and light, handles visible; footer above the keyboard; offline message shows and the post button returns on reconnect; compose empty after posting. Prod web deployed 17:56 UTC (served files verified cache-busted; no function errors; watchdog nominal). Build 111 is the launch candidate.**

---

## LAUNCH-2026-10-30 — launch-readiness fixes (owner decisions 2026-10-30; server on prod, clients in build 110 + staging web; prod web pending owner go)

- **Sign-up cold start (review item 1) — PROD.** `blockBannedSignups` now runs with `minInstances: 1` (`--force`, raises the minimum bill ≈ $6/month). Evidence: 13.7 s (prod) / 14 s (staging) cold start vs Auth's 7 s blocking deadline → `auth/internal-error` on the first sign-up after idle. Staging: min-scale 1, sign-up 3 s right after deploy. Prod: min-scale 1, instance ready 20:07 UTC. Headless prod sign-up is impossible (referrer lock + App Check) — **owner confirms one real sign-up.** Long-term: move the blocking function to its own small codebase so the deadline has margin without a warm instance.
- **iPad (item 2).** ASC: 1.0 is Ready for Sale (build 1, 2026-04-21); the device family `1,2,7` dates from the first project commit (2026-04-16) → 1.0 shipped WITH iPad, so iPad support stays (Apple rejects updates that drop it). Build 110 (109 superseded) renders the whole app in a centered ≤ 600 pt column on the themed background (root `.frame(maxWidth: 600)` in `toskaApp.swift`), portrait and landscape; iPhone unchanged. visionOS (`7`) removed from the device family. iPad mini screenshot taken.
- **Feed paging (item 3).** Correction to the review: the iOS main feed was already a one-shot paged query (60 + 20), not a 500-doc listener; the 500s were the user's own liked/saved id listeners and the thread reply listener. Now: iOS + web first page 40, 20 per load-more; own-id listeners 200/200/100; thread reply listener newest 100 (iOS), thread fetch 200 (web). Cost model re-run in `LAUNCH_READINESS_2026-10-30.md` §2 (≈ $8 / $30 / $250 per month at 1k / 10k / 100k users).
- **Demo account (item 4).** Password rotated via Admin SDK (handed to the owner in chat, not stored anywhere in the repo); account enabled, 3 seeded posts, `confirmedAdult`, policy v4 → the v5 re-accept screen will show once (documented). `APP_REVIEW_NOTES.md` gained the "if you test with crisis phrasing" paragraph. **Owner verified 2026-11-01: signed in with the new password and accepted v4.0 (`acceptedPolicyVersion` 5 on prod), so the reviewer goes straight to the feed; review notes updated accordingly. Owner still to paste the password into ASC Sign-in Information.**
- **Accessibility (item 5).** Web `--faint` / `--dot` → L 0.50 (5.7:1 on paper) with dark-mode overrides (0.70 / 0.68, 6.9:1); iOS `tertiaryText`, `timeText`, `dotSeparator` → `#6E6B76` day (4.9:1) / `#8A8791` night (5.3:1). `Font.toska(_:weight:design:relativeTo:)` (UIFontMetrics-scaled, root cap `.accessibility3` unchanged) replaces 78 `.font(.system(size:))` calls on FeedView, ComposeView, PostDetailView, ProfileView, SettingsView, SignInView, SplashView, CreateAccountView. 15 web inputs/textareas gained `aria-label`s (sign-in, sign-up, checkboxes, search, GIF search, compose, reply, edit, sharing toggles, re-accept). Found while verifying at the largest accessibility size on an iPhone SE: `PolicyAcceptanceView` is a `fullScreenCover`, outside the root view's Dynamic Type cap, so it rendered at AX5 and truncated its title, checkbox label and button — it now re-applies the a3 cap and the three labels wrap/shrink (build 110; screenshot verified). Remaining a11y items (VoiceOver pass, hints, tap-target audit, Reduce Motion) → post-launch.
- **Staging web deployed** (feed 40, labels, tokens). **Prod hosting + push pending owner go.**

---

## BADACTOR-2026-10-30 — adversarial audit fixes (STAGING 2026-10-30; prod pending owner go; iOS in build 108)

- **Source:** `AUDIT_BADACTOR_STAGING_2026-10-30.md` (repo root, gitignored — local only until prod ships): 9 ranked findings from a staging-only bad-actor audit (67 throwaway accounts, real client write shapes, everything removed). Owner fix order 2026-10-30: #3, #2, #1, #4, #5, #7, #8, #6, #9.
- **#3 false crisis pages — FIXED.** `notifyAdminsOfNewReport` no longer pages on crisis phrasing in the reporter's free text (attacker-controlled; 20 pushes/h per account): it stamps `reporterTextCrisis: true` on the report (dashboard badge "crisis wording in note") and logs `report_text_crisis`. `pageAdminsForCrisis` now takes `authorId` and pushes at most once per author per hour (`crisisPageThrottle/{uid}`, stamped only after a delivered push); a throttled item writes its claim with `throttled: true` so the watchdog treats it as handled. Every item still enters the queue (held post / `crisisReplyQueue` entry). Tests: 3.
- **#2 report brigading — FIXED.** `onReportCreatedAutoHide` counts a reporter only when `users/{uid}.createdAt` is ≥ 72 h old (missing doc / field → does not count; younger accounts' reports still reach the queue; log `auto_hide_skipped_new_reporters`), and reserves one of **2 auto-hide slots per author per rolling 24 h** (`autoHides/{authorId}`, transaction; log `auto_hide_cap_reached`; replies count toward the same cap). Tests: 6 (incl. "two established + one new do not hide; a third established hides").
- **#1 doxxing workarounds — FIXED (server `moderation.js` → vendored web copy → `ContentModeration.swift`, parity 152/152).** New block after the Capitalized full-name rule: lowercase given + surname (`sarah johnson`, any case; also `sarah (johnson)`), dotted initial + surname (`s. johnson`), given + dotted initial (`Sarah J.`), concatenated given+surname (`SarahJohnson`, `sarahjohnson22`; both halves ≥ 4 letters, a token that is itself a name never splits), ≥ 7 number-words in 12 tokens (spelled-out phone), `(her|his|…) (ig|insta|snap|sc|tt|tiktok) (is|was|:) …`, `on the gram`, `gram: …`, license plate `plate ABC 1234`, and a bare `{adjective}_{noun}_{n}` handle token (#6, treated like `@handle`). Given names that are ordinary lowercase English words are excluded from the lowercase/compact rules only (`LOWERCASE_EXCLUDED_GIVEN`, 92 curated from the 359-word dictionary overlap — the gate caught "then made tea. small acts" as tea + Small); nudge-only and ambiguous names never count. **Impact gate (HEAD vs working, 366 texts = all 154 staging posts + 46 replies, all 40 prod posts + 16 replies, 237 corpus lines): newly held 11 — all of them the new corpus attack cases; 0 real posts/replies newly held, 0 un-held, 0 nudge changes.** Controls pinned allowed: "summer rain", "grace kelly", "rose garden", "will smith", "one more day, two more weeks, three months", "mrs. johnson", "love u.", "harrison ford", "a quiet_night out", "the plate was full of food", "she drives a red civic". Known remaining gaps (by design): split details across posts; lowercase given + a surname that is also a given name ("sarah taylor"); workplace/car prose without a name.
- **#4 post-and-vanish — FIXED.** `validatePost` → `normalizeEphemeralExpiry`: whisper `expiresAt = createdAt + 60 min` exactly (±60 s tolerance avoids a rewrite on every honest whisper); midnight `expiresAt` floored at `createdAt + 60 min` (the server has no timezone, so the real local midnight cannot be recomputed — the floor is what stops a 2-minute flash post; a 23:30 midnight post now clears at 00:30 instead of 00:00, accepted); both flags → whisper (2026-10-29). New `onReportCreatedSnapshot`: a server-verified copy of the reported post/reply (`snapshot {text, authorId, authorHandle, createdAt, isWhisper, isMidnightPost, gifUrl, moderationStatus}`) lands on the report, and a missing `reportedUserId` is filled from the real author; `update()` so a report the rate limiter already deleted is never recreated. Dashboard renders the snapshot as a verified copy when the content is gone and keeps "restrict user" (remove needs live content). Tests: 6.
- **#5 admin queue — FIXED.** `docs/admin.html` reports tab: oldest-first, 50 per page with "load more", one collapsed card per reporter with > 5 pending on the page ("show all"), "new reporter (<7d)" badge, "crisis wording in note" badge, pending + overdue counters from aggregates; `?project=staging` switch (no App Check init) for checking against staging. `rateLimitReports`: accounts younger than 7 days (or unreadable) get 5 reports/h instead of 20; `system_*` reporters (handle screen) are never rate-limited. Tests: 3.
- **#7 look-alike handles — FIXED (rules).** `generatorHandle()` on users-create and handles-create: exactly `{adjective}_{noun}_[1-9][0-9]{0,5}` from the two fixed 30-word lists; rejects confusables, hyphens, leading zeros, trailing underscores, digits inside words, leet reserved words, invented words, mixed case and the old `anonymous_` fallback (both clients' fallback now re-rolls a word-pair with a 4–6 digit number; the rule is create-only so existing `anonymous_…` accounts are untouched). Rules suite 408 (+15).
- **#8 ban evasion — FIXED / CONFIG.** `normalizeEmailAlias` strips dots and folds `googlemail.com` for Gmail only (plus-tags everywhere). Staging Auth: anonymous provider disabled; sign-up quota set to 50 per IP per hour (my own verification runs need ~20). **Prod recommendation: 10 per IP per hour** (Firebase's default is 100; a household NAT never signs up 10 accounts an hour; raise if support tickets say otherwise). Tests: 2.
- **#6 bare handle mentions — FIXED** via the detector (above): `numb_stone_99 is a liar` is held as pii like `@numb_stone_99`. Applies to everyone, not only blocked pairs (the server cannot see blocks in the detector; the shape is unambiguous).
- **#9 flooding — alert FIXED, limits PROPOSED.** `abuseSpikeWatch` gains `watchNewAccountLiveSpike`: ≥ 20 LIVE non-repost posts in the last hour from accounts younger than 24 h → `abuse_spike_global` with `lane: live_new_accounts` (same tag as the existing alert policy, no infra change). Proposed tighter limits for accounts < 24 h old (not implemented): 3 posts / 5 min (vs 5), 5 replies / 5 min (vs 10), 10 notifications / 5 min (vs 20), 3 reports / h (vs 5 for < 7 d), and no reposts in the first hour. Test: 1.
- **Follow-ups (owner-approved 2026-10-30, STAGING 5/5 → PROD ~19:35 UTC, 5 functions `rateLimitPosts, rateLimitReplies, rateLimitNotifications, rateLimitReports, validatePost`):** accounts younger than 24 h get 3 posts / 5 min, 5 replies / 5 min, 10 notifications / 5 min, 3 reports / h, and no reposts in their first hour (`NEW_ACCOUNT_LIMITS`; a missing `createdAt` keeps the established posting limits, reports stay strict). Every limiter is now deterministic by `(createdAt, path)` (`countEarlierInWindow`): a trigger deletes its own doc only when the docs that sort strictly before it already fill the cap, so a same-second burst always keeps the earliest and drops the latest — a genuine report can no longer be the one dropped. Tests +9 (functions 176). Staging: 3 free posts then `rate_limit`, repost by a 10-minute-old account deleted, 7 replies → earliest 5 kept, 5 reports (cap 3) → earliest 3 kept. **Prod Auth sign-up quota set to 20 per IP per hour** (owner: carriers and campuses share IPs); staging stays 50. **Found during verification: the sign-up blocking function `blockBannedSignups` cold-starts in 13–14 s (whole-codebase module load) against Auth's 7 s blocking-function deadline → the first sign-up on a cold instance fails with `auth/internal-error`. Reproduced on staging; one cold start observed on prod this week. Fix candidates: `minInstances: 1` on that function, or move it to its own lightweight codebase. Listed in LAUNCH_READINESS_2026-10-30.md as the top pre-submission item.**
- **Staging (2026-10-30 ~18:40 UTC):** rules + 24 functions (`onReportCreatedSnapshot` new, 77 → 78) + hosting; verification 31 checks (handles ×9, anonymous auth, expiry ×3, report crisis text, snapshot ×2, throttle, brigade ×3, new-account report cap, doxxing ×9 + control) — all behave as designed; fixtures removed, staging back to baseline. Build 108 carries the iOS mirror. **Prod: pending owner go.**
- **ACCEPTED, not fixed:** a blocked user can still LIST the victim's live posts and replies with raw SDK queries (profile/feed/thread list rules cannot check blocks per author without constraining the query; `get` by id and the user doc are denied — Option 2, 2026-10-25). Hiding is client-side (BlockedUsersCache / web `blockedBy`), the feed is pseudonymous, and the real protection is the detector (#1/#6). Also accepted: a new account after a block is a new uid by design.

---

## NAMES-EXPANSION — bigger given/surname lists, nudge-only names, whisper+midnight normalization (LIVE, PROD 2026-10-30; iOS in build 107)

- **Decision (owner, 2026-10-29/30):** the hand-written name lists missed most non-Anglo names ("Olga broke up with me" never nudged; "my ex Nguyen" was never a lone-surname hold). Expand from open sources, keep bare first names allowed (N-17), and gate the change on a real-text impact report.
- **Sources:** given names = original 208 ∪ top ~4,000 Latin-script Wikidata given-name items (CC0, sitelinks ≥ 4, ranked by sitelink count) → **4,030**; surnames = original 81 ∪ US Census 2010 top-1,000 (public domain) minus anything that is also a given name (Tyler, Taylor, Jordan stay given names) → **877**; ambiguous words = original 55 ∪ the owner's common-word surnames (brown, white, young, hill, green, king, black, long, wood, rose, gray, wells, rich…) ∪ a curated set (bill, mark, will, joy, faith, summer, dawn, hope, grace, april, june, crystal, jade, love, star, snow, stone, price, best, the occupational surnames baker/cook/fisher/miller/carter/parker/turner/walker/taylor…) → **145**. A dictionary-intersection approach was tried and rejected (the macOS word list silenced 38 real given names: steven, laura, emma, maria, mike, sam…).
- **Accepted trade-offs:** Genesis and Taylor no longer nudge; Carter/Miller/Parker/Taylor/Turner/Walker no longer trigger the lone-surname hold ("my ex Miller" is allowed; "Sarah Miller" is still a full-name hold).
- **Nudge-only names (owner 2026-10-30):** `NUDGE_ONLY_NAMES` = christian, cole, dean, don, earl. They stay in `AMBIGUOUS_WORDS`, so no HOLD rule treats them as a name ("my ex Dean", "Dean Miller", "Earl Grey" all allowed), but `likelyFirstName` nudges on them when Capitalized or right after a relationship prefix. "earl" is not in the given list, so the set drives the nudge on its own. "don't" / "don’t" is stripped before matching (the contraction used to tokenize as the name Don). Mirrors: `ContentModeration.swift` `nudgeOnlyNames`, `docs/admin.html` `ADMIN_NUDGE_ONLY`. Known soft FP: "Even" is a Norwegian given name, so "my ex even…" nudges (soft, not a hold; not changed).
- **Whisper + midnight normalization (owner 2026-10-29):** the two modes are mutually exclusive on both clients, but the create rule (at the expression ceiling) only type-checks the flags. `validatePost` now treats both-flags as a whisper: drops `isMidnightPost`, pins `expiresAt` to ≤ 1 h (keeps a shorter one). 3 function tests.
- **Impact gate (git HEAD lists vs new, 401 texts = moderation corpus + parity corpora + all 153 staging posts + 46 replies + all 40 prod posts):** newly held 0, newly un-held 0, newly nudged 0, newly un-nudged 0 — so the full-mode expansion shipped (the fallback "expanded list for the nudge and sentence-start exemption only" was not needed). Probes: "Olga broke up with me" / "my ex Khatun" nudge; "my ex Smith" / "my ex Nguyen" / "Patel's laugh" hold; "Brown left me" allowed.
- **Pins:** detector-parity 129/129 (FIRST corpus +10 nudge-only cases, CORPUS +3 hold-side allows), moderation-corpus 141, crisis 29, crisis-list parity exact, functions 146, iOS compiles. App size: ~60 KB of source in the Swift file + vendored JS.
- **Deploy:** staging 14 functions (`validatePost, validateReply, onPostCreated, onPostUpdated, onReplyCreatedModerate, onReplyUpdated, reconcilePostVisibility, publicFeed, sharePage, shareCardImage, postsSitemap, auditPostDeletion, auditReplyDeletion, onHandleCreatedScreen` — every export that reaches `containsNameOrIdentifyingInfo` / `likelyFirstName`; the crisis lane only uses the unchanged normalizer) + hosting, 77 → 77; live check 15/15 (expanded names nudge-side allowed, expanded surnames held `pii`, nudge-only names never held, "Don't…" allowed, both-flags post → live whisper expiring in 59 min, replies same, fixtures removed). **Prod 2026-10-30 ~16:00 UTC:** same 14 via `--only`, 77 → 77, nothing removed/added; hosting; served `vendor/moderation.js` carries the new lists; no function errors or warnings after the deploy. iOS mirror rides build 107.

---

## REMOVAL-NOTICES — tell the author when their post/reply is removed (LIVE, PROD 2026-10-29; iOS in build 104)

- **Decision (owner, 2026-10-29):** in-app notification only (no push), calm voice, reason category chosen by the admin, never who reported; gentler safety variant leading with region-aware crisis resources; nothing for deleted accounts or spam; EU DSA Art. 17 statement of reasons (what / why / how found / who decided / redress); automated removals get the same notice saying "our automated screening"; pruned with other notifications.
- **Server (`sendRemovalNotice` in functions/index.js):** writes `users/{author}/notifications/removal_{post|reply}_{id}` with `type: "removal"`, `reasonCode` (pii, hurtful, threat, sexual, safety, other, too_long, held_parent; spam → silent), `source` (admin | automated), `safety`, one-line `message`, `preview`, `removedDate`, `statement {what, why, guideline, how, who, redress}`, guidelines URL + support email. Skips when the author's user doc is gone (deletion cascade / ban). Preview rules: pii/threat → beginning with names, numbers, emails, @handles and street addresses masked ("… broke up with me last week and i still have her number …"); safety → no preview (date only); others → first ~80 chars of the author's own words.
- **Hooks:** `auditPostDeletion` (admin stamp `deletedBy` + new `removalReason` + `removalVia`) and new `auditReplyDeletion` (replies now get the stamp + a `reply.delete` audit entry); automated: `applyReplyModeration` hard deletes (slurs etc. → code via `flagReasonToRemovalCode`), `validateReply` too-long and reply-on-held-post. **Not noticed (nothing meaningful removed / not moderation):** blank or under-2-char replies, invalid repost/reply-repost copies deleted by validatePost, expiry cleanup, account-deletion cascades.
- **Admin dashboard:** every remove flow (reports: post + reply; pending replies; crisis replies; queue post delete) opens a reason picker (pii / hurtful / threat / sexual / spam (silent) / safety / other; crisis tab defaults to safety) and stamps `deletedBy / deletedAt / removalReason / removalVia` before deleting. Rules unchanged — the admin update legs are unconstrained apart from the deletedBy self-pin.
- **Clients:** web — `removalRow` on the notifications tab (not a link; "details" expands the statement; safety rows list the app's region-aware crisis lines via gates `crisisLines()`); iOS — `NotificationItem.removal` (RemovalNoticeInfo), row "toska + message", tap opens `RemovalNoticeSheet` (safety → `CrisisLines.resources`), build 104. Unknown-type fallback on older builds shows the one-liner.
- **Wording:** Terms §6 new paragraph (we tell you in-app: what/why/how/who, never who reported, email to ask again, no notice for spam or deleted accounts) + changelog line, no version bump; support page "About a removal" section.
- **Verification:** functions 139 (9 new: preview masking, code mapping, admin post pii via report, safety, self-delete/spam/ghost skips, admin reply + audit, automated slur reply, held_parent + under-2-char skip, prune); iOS compiles; staging 14/14 (`removal-verify-staging.mjs`): dashboard-shape stamps → notices with masked preview, report-anonymous + person wording, safety variant, reply notice + audit, skips, automated slur + held_parent, web rows/details/safety row.
- **Prod (2026-10-29 ~18:00 UTC):** five functions via `--only --force` (set 75 → 76, only `auditReplyDeletion` added, nothing removed), hosting, push (terms §6 + support "About a removal" + admin reason picker published). Prod check 5/5 with a neutral throwaway removed in the dashboard shape (reason "other"): notice present with the person / own-review wording and the redress line, `post.delete` audit carries the reason, totals restored (40 posts / 11 users). No crisis wording used.

---

## B102-1 — own-post lavender tint blends into the prompt card (build 102 hand test)

- **Severity:** LOW (visual) · **Surface:** iOS feed + post detail, web · **Status:** FIXED 2026-10-27 — **web on STAGING** (prod pending owner OK); **iOS code committed, rides build 103** (batched with the other build-102 findings)
- **Finding (owner, build 102):** the own-post tint reused `promptBg`, so an own post directly under the daily prompt merged with it into one purple block.
- **Fix:** own posts become a **white card** (`#FFFFFF`) on the stone paper by day, with the standard bottom hairline and a faint lift shadow (1px/2px, ink-violet 7%); at night a slightly lifted **neutral** surface (`oklch(0.265 0.012 298)` ≈ `#26242A`, no shadow, hair-2 bottom hairline) so it sits apart from the purple-tinted prompt band. Tokens: web `--own-bg/--own-hair/--own-shadow`; iOS `LateNightTheme.ownPostBg/ownPostHair/ownPostShadow` (ToskaColor aliases). Scope unchanged: displayed author == me only; reposts of others untouched; own-handle accent color kept.

---

## SEC-UUID — HIGH uuid advisory (GHSA-w5hq-g745-h8pq) via gaxios in Cloud Functions

- **Severity:** HIGH advisory, but **not reachable** in our usage · **Surface:** functions (CI Security Watch "Dependency vulnerability scan") · **Status:** RESOLVED — lockfile fix committed (c2f0dcf) + functions deployed to staging + prod 2026-10-25; Security Watch green
- **What triggered it:** `npm audit --omit=dev --audit-level=high` in `functions/`
  found uuid GHSA-w5hq-g745-h8pq ("missing buffer bounds check in v3/v5/v6 when a
  `buf` arg is provided") — HIGH — pulled in transitively via **gaxios** (the HTTP
  client under google-auth-library / @google-cloud libs that firebase-admin uses).
  Also 2 moderate (gaxios 6.x → old uuid). The job fails on HIGH, hence red.
- **Reachability (plain language):** NOT reachable. The flaw only bites when uuid
  is called with a caller-supplied output buffer (v3/v5/v6 + `buf`). Google's libs
  use `uuid.v4()` with no buffer to mint request ids; our code never calls uuid
  with a buffer. No exploit path in Toska.
- **Fix:** `npm audit fix --omit=dev` in functions/ — lockfile-only bump that
  clears the HIGH (re-audit at `--audit-level=high` exits 0). 2 moderate remain
  (gaxios 6.x, below the gate; the documented "needs firebase-admin major" set).
  No Dependabot PR exists. 112 functions tests still pass.
- **Deploy:** functions dep change → **staging first, then prod on owner approval.**
  Currently applied to the working tree only; CI clears once the lockfile is committed.

---

## FCM-DIAG — REMOVED before launch ✓ (build 100, 2026-10-26)

- **Severity:** BLOCKING for launch · **Surface:** iOS (PushNotificationManager, toskaApp) · **Status:** RESOLVED — stripped in build 100 (0915117, 2026-10-26)
- Build 99 adds `recordFcmDiag()` which appends status strings (no user content)
  to the signed-in admin's own `private/data.fcmDiag` at each push-registration
  step, to diagnose the FCM account-switch token loss on a release TestFlight
  build (debugLog is stripped in release). Gated to admins (AdminManager) = the
  owner only. **MUST be removed before public launch:** delete `recordFcmDiag` +
  all its call sites (PushNotificationManager saveFCMToken/refreshFCMToken/
  reregister/didReceiveRegistrationToken, toskaApp didRegister/didFail), and
  one-time clear the owner's `fcmDiag` field. Diagnostic-only; not for prod users.

---

## TEST-ONBTARGET — wire a Swift unit-test target (follow-up)

- **Type:** test infra follow-up · **Surface:** Xcode project · **Status:** OPEN 2026-10-25
- The repo has only a UI-test target (`toskaUITests`, black-box, no `@testable`
  access). `toskaTests/OnboardingGateTests.swift` (ONB-1 matrix) needs a **Unit
  Testing Bundle** target with `@testable import toska` to run in Xcode/CI. Build
  98 shipped without waiting for it (ONB-1 logic matrix-verified 6/6 standalone).
  Add the target and include that file; then it runs with the suite.

---

## ONB-1 — existing accounts re-shown new-user onboarding on sign-in

- **Severity:** MED (UX + minor data-loss risk) · **Surface:** iOS (ContentView.verifyUserDocumentAsync) · **Status:** FIXED + shipped in build 98 (shouldShowOnboarding server/explicit-false/confirmedAdult gate; matrix 6/6)
- **Finding:** the gate is `data["hasCompletedOnboarding"] as? Bool ?? false; if
  !hasCompletedOnboarding { showOnboarding = true }` (ContentView:428-431). It's an
  ACCOUNT flag (user doc), not a device flag (owner's guess was close). Both accounts
  involved have `hasCompletedOnboarding=true` in Firestore, yet onboarding re-showed
  during rapid account-switching — so the `?? false` default fires onboarding on a
  stale/empty/cached read of the just-switched-to user doc (false negative), not a
  persistence failure.
- **Overwrite check:** onboarding completion writes only `hasCompletedOnboarding`,
  `selectedMood`, `breakupStage` (all merge). It does NOT write `allowSharing`,
  `handle`, or `confirmedAdult`, so re-running can't clobber those. The only data
  risk is overwriting `selectedMood`/`breakupStage`; the main harm is the UX.
- **Proposed fix (existing accounts skip onboarding entirely):** in verifyUserDocument
  (a) read the user doc from SERVER for the onboarding decision (no cache), (b) show
  onboarding ONLY on an explicit `hasCompletedOnboarding == false` from an existing
  doc — never default a missing/unknown read to false, and (c) treat any established
  account as onboarded (e.g. `confirmedAdult == true`), since attestation only
  happens at creation/onboarding. New accounts still onboard via the creation paths
  that post `.showOnboarding` (Splash/CreateAccount/AppleSignIn).

---

## RESET-1 — custom /auth page — DONE

- **Status:** SHIPPED to prod 2026-10-25. `webapp/auth.html` + `webapp/js/auth.js`,
  route `/auth` (firebase.json). Handles resetPassword (two fields, 8-char, eye
  toggles), verifyEmail, verifyAndChangeEmail, recoverEmail, fallback; reuses the
  app design system; dark mode; expired/used-link resend; App Check on prod.
  Verified in a real browser. NOTE: not reachable from real reset emails until the
  email action URL points at it (blocked — see below).

## AUTH-05 — email branding — RESOLVED (good enough for launch)

- **Status:** public-facing name set to **"Toska"** (verified: project displayName
  = "Toska"), so `%APP_NAME%` renders "Toska" in the default reset/verify/change
  emails. **Template text + action-URL editing is LOCKED for this project** (console
  banner "Email template updates are currently unavailable… contact Firebase
  Support"; admin API returns `EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED`). So the default
  emails stay (now "Toska"-branded) and the custom /auth page isn't reachable from
  them until unlocked or Option B ships. Support ticket text is in chat 2026-10-25.

## RESET-EMAIL / Option B — branded sending via Resend (POST-LAUNCH, parked)

- **Severity:** post-launch polish · **Surface:** functions + iOS + web + DNS · **Status:** PARKED 2026-10-26 (default emails are fine for soft launch)
- **NOT EXPORTED (2026-10-26):** the `sendBrandedPasswordReset` block in
  functions/index.js is wrapped in a `/* PARKED … */` block comment, including
  its `defineSecret("RESEND_API_KEY")` + `defineString("RESET_FROM")`. This is
  deliberate: those param declarations ran at module load and made EVERY
  `firebase deploy` demand a RESEND_API_KEY secret + RESET_FROM value (it blocked
  the consent-fix staging deploy). **To resume:** uncomment the block and restore
  the `exports.` prefix (step 1 below). Confirmed never deployed to staging or prod.
- **Built, committed, UNDEPLOYED:** `sendBrandedPasswordReset` callable (functions/
  index.js, commit 91498b3) — App Check-enforced, enumeration-safe, rate-limited
  (3/h per email + 10/h per IP), `generatePasswordResetLink` → rewrite to
  `app.toskaapp.com/auth` → branded HTML via **Resend**. `RESET_FROM` defaults to
  Resend's onboarding domain. Clients NOT wired yet.
- **To resume (owner setup):** 1) create a Resend account; 2) make an API key;
  3) set it as a secret yourself (`npx firebase-tools functions:secrets:set
  RESEND_API_KEY --project toskastaging`, then prod) — Claude never sees it;
  4) add domain `toskaapp.com` in Resend → it shows the exact DKIM CNAMEs + SPF
  value + return-path; 5) add those in Squarespace (merge the SPF include into the
  single SPF TXT before `-all`; DKIM CNAMEs; return-path), keeping DMARC `p=reject`.
- **Then Claude:** deploy callable to staging + test to the owner's address; after
  Resend verifies the domain and a test shows spf=pass/dkim=pass/dmarc=pass, flip
  `RESET_FROM` → `noreply@toskaapp.com`, wire iOS (new build) + web "forgot
  password" to the callable, deploy prod. **Do NOT switch prod clients before DNS
  verification** (onboarding domain only delivers to the account owner).

---

## FEAT-HANDLE-CHANGE — post-signup handle change + backfill + block suggestion (post-launch)

- **Type:** FEATURE (post-launch) · **Surface:** iOS + web + rules + functions · **Status:** DEFERRED 2026-10-23
- **Why:** there is NO post-signup handle-change today (handles are set only at
  signup via the "shuffle" flow + `commitUserDocClaimingHandle`). Block hardening
  Option 3 (a gentle "want a fresh handle?" suggestion after blocking) depends on
  this, so Option 3 is deferred with it. The App Store "you can change it
  whenever" claim was removed because nothing backs it (2026-10-23).
- **Scope to build:**
  1. **Change mechanism:** generate a unique handle (`generateUniqueHandleAsync`),
     then ATOMICALLY release `handles/{oldLower}` + claim `handles/{newLower}` and
     update `users/{uid}.handle` in one batch/transaction (prevents squatting +
     uniqueness races). New rules path for a handle *update* (today the registry
     rule is create/delete only). Add a rate-limit (e.g. once per N days) and
     respect `bannedIdentities`/restricted-user checks.
  2. **Past-content backfill:** `authorHandle` is denormalized on every post,
     reply, and reflection with no backfill, so a change leaves old content under
     the old handle. A callable Cloud Function would paginate the user's `posts`
     (`where authorId==uid`), `replies` (collectionGroup `where authorId==uid`),
     reflections, and the follow-graph `handle` mirrors and batch-update
     `authorHandle`. Bounded + idempotent, but non-trivial (hundreds of docs,
     collectionGroup over replies, Admin SDK server-side). Decide forward-only vs
     backfilled at build time.
  3. **Option 3 block suggestion (the trigger):** after a block (on
     `.userBlocked`), show a calm, optional, dismissible sheet with a one-tap
     "give me a new handle". Approved wording (variant 2):
     > **a fresh handle?** they won't see your posts in their feed anymore. if
     > you'd feel more at ease, you can switch to a new random handle for anything
     > you write from now on. your older posts keep the handle they were written
     > under.  [ give me a new handle ] [ not now ]
     (If backfill ships, soften "older posts keep…" accordingly.)

---

## B94-MFA — iOS sign-in can't complete a TOTP second factor (BLOCKING) [FIRST]

- **Severity:** HIGH (blocking) · **Surface:** iOS sign-in (`toska/SignInView.swift`) · **Status:** FIXED 2026-10-23 (compiles; on-device verify after build 94)
- **Why blocking:** the owner's admin account now has TOTP MFA enrolled. iOS has
  no multi-factor sign-in handling, so signing out of the app = locked out of
  that account (the account crisis pages go to). The current iOS session stays
  valid (sessions persist through enrollment), so there's no live outage — but
  until this ships, DO NOT sign out of iOS on that account or change its
  password/revoke its tokens.
- **Fix:** implement the MFA resolver in the Swift sign-in path — catch the
  multi-factor-required error, get the `MultiFactorResolver`, prompt for the
  6-digit code, build `TOTPMultiFactorGenerator.assertionForSignIn(enrollmentID,
  code)` and `resolver.resolveSignIn(assertion)`. Mirror of the admin.html + web
  app.js web flow. Clear errors for wrong/expired code.
- **Recovery if locked out meanwhile:** Admin-SDK unenroll (ops doc) → sign in
  with password → re-enroll.

---

## B94-3 — Feed GIF shows a brief blank before loading (minor polish)

- **Severity:** LOW (polish, not a blocker) · **Surface:** iOS feed · **Status:** FIXED — neutral placeholder (stable reserved height + crossfade, `StableGifPreview` in ComposeView.swift) shipped in build 96 (5ff0121); build 102 (c246d6a) added off-main decode + decoded-image cache, WebP rendition w/ .gif fallback, and next-row prefetch. **Device-verify on 102.**
- **Reported:** 2026-10-23, owner device test on build 94. The B94-1 render-timing
  bug is fixed (GIF now appears without tapping in), but there's still a slight
  load delay where the row shows empty space before the GIF paints.
- **Quick idea:** render a placeholder while the GIF loads — a neutral
  rounded-rect at the GIF's aspect ratio (or a low-res thumbnail / first-frame
  still if the host exposes one), swapped for the animated GIF on load. Prevents
  the empty-gap flash and the row-height jump. `StableGifPreview` (FeedView.swift
  ~868) is the place; it already has the URL by value now.

---

## B94-FCM — FCM token not restored after sign-out/sign-in (crisis delivery)

- **Severity:** HIGH · **Surface:** iOS push registration · **Status:** FIXED + DEVICE-VERIFIED on build 95, 2026-10-23
- **Device verification (build 95):** all three recovery paths confirmed to write a
  fresh token to `private/data` — (1) sign-out → sign-in w/ TOTP, (2) Settings push
  toggle off → on, (3) foreground after a server-side token drop. Crisis delivery
  to the owner device confirmed restored.
- **Finding:** after the owner's build-94 sign-out → sign-in, `users/{ownerUid}/private/data`
  had **no `fcmToken`**; toggling in-app notifications back on set `pushEnabled:true`
  but STILL wrote no token (`fcmTokenUpdatedAt` stayed at the sign-out time), and
  reopening the app didn't help. Crisis pages would not reach the device.
- **Root cause (two gaps):**
  1. Sign-out calls `Messaging.deleteToken` (invalidates the token). On a
     same-session sign-in, `refreshFCMToken()` fires once via `.userDidSignIn` but
     the token isn't minted yet (no APNs re-registration), so it fetches nothing;
     `didReceiveRegistrationToken` never re-fires. Self-heals only on cold launch —
     and foreground (scenePhase `.active`) only cleared the badge, never retried.
  2. `SettingsView.requestPushPermissionIfNeeded()` `.authorized` branch did `break`
     — re-enabling the toggle wrote the pref but never re-registered/fetched a token.
  This hit ANY user who signed out and back in, not just MFA accounts.
- **Fix:** new `PushNotificationManager.reregisterForPush()` — re-registers APNs
  (so the delegate re-fires with a fresh token) + best-effort fetch+save, gated on
  granted permission. Wired to: `.userDidSignIn` (ContentView), app-foreground when
  signed in (ContentView scenePhase), and the Settings toggle `.authorized` branch.
- **Verify on build 95:** sign out → sign in → `fcmToken` present in private/data;
  toggle off/on restores it; foregrounding after a drop restores it.

---

## B94-1 — Feed GIF doesn't render until the row is re-laid-out (tap-in / scroll)

- **Severity:** LOW (cosmetic) · **Surface:** iOS feed · **Status:** FIXED 2026-10-23 — gifUrl now on the FeedPost model, set in feedPost(from:), row reads post.gifUrl (side-dict fallback kept). Compiles. Verified on device build 94 (renders without tapping; residual load-delay = B94-3).
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (established by code reading, not by running those builds — build 93's only iOS deltas were logging/wording/comments, which don't touch this path).

**Repro:**
1. Post a GIF, or open a fresh feed containing a just-created GIF post.
2. The post row appears with text but no GIF.
3. Tap into the post → the GIF shows. Back out → it now shows in the feed too. (Scrolling the row off/on screen also makes it appear.)

**Diagnosis:**
The feed row renders GIFs via `StableGifPreview` (FeedView.swift ~868), but the
row receives its URL *by value* at construction: `gifUrl: vm.postGifUrls[post.id]`
(FeedView.swift ~1880). `postGifUrls` is filled by
`FeedViewModel.extractPostMetadata(from:)` (FeedViewModel.swift ~1169-1171) from
the feed snapshot — which can populate *after* the rows first lay out. Because
the URL is captured at row-build time (nil then), the row doesn't rebuild when
`postGifUrls` later gains the entry, until SwiftUI re-lays the row for another
reason (scroll, or returning from PostDetailView, which reads the doc directly).

**Proposed fix (build 94):**
Make the row read `gifUrl` reactively instead of by captured value — e.g. have
`FeedPostRow` take the `postId` and look up `vm.postGifUrls[id]` inside its own
`body` with `vm` as an `@ObservedObject`, so a `@Published` change to
`postGifUrls` re-renders it. Alternatively, carry `gifUrl` on the `FeedPost`
model itself and set it during the same snapshot parse that builds the row data
(single source of truth), avoiding the side-dictionary timing entirely. Verify
with a GIF post appearing in a live feed without any tap/scroll.

---

## B94-2 — Repost not reflected in the feed until manual refresh

- **Severity:** LOW–MED · **Surface:** iOS repost + feed · **Status:** FIXED 2026-10-23 — repost() now posts .postInteractionChanged (unrepost already did); the dead handleInteractionChanged 'repost' case now fires so all copies + the shared store flip immediately. Compiles.
- **Reported:** 2026-10-23, owner device test on build 93
- **Regression?** No. Pre-existing on 91/92 (same basis as B94-1).

**Repro:**
1. Repost a post.
2. The feed doesn't show the repost / updated state immediately.
3. Pull-to-refresh → it appears.

**Diagnosis:**
Reposting writes a new post doc (`{uid}_repost_{postId}`). The feed uses a
snapshot listener (FeedViewModel `addSnapshotListener`, ~1021/1038/1057), so the
new doc *does* arrive on the next snapshot — but the **optimistic** UI update at
action time isn't applied, so there's a visible gap until the listener delivers
(or the user refreshes). The reposted-state set (`repostedPostIds`,
InteractionStateStore) and/or the inserted repost row aren't updated in the same
turn as the tap.

**Proposed fix (build 94):**
On a successful repost, optimistically (a) add the id to `repostedPostIds` so the
button flips immediately, and (b) insert/refresh the repost entry locally rather
than waiting for the snapshot — mirroring how like/save optimistic updates are
handled. Reconcile with the listener's authoritative copy when it arrives (guard
against a double-insert when the snapshot delivers the same doc). Verify a repost
shows in the feed with no manual refresh, and that the count/state stays correct
after the listener catches up.

---

*Both found during the build-93 production verification pass. Critical paths
(sign-in, feed load, GIF post, crisis detection + 988 + crisis page push,
moderation) all confirmed working on 93; these two are cosmetic/feedback polish.*

---

## B94-W — Full web sharing-consent UI (checkbox at sign-up + web settings toggle)

- **Severity:** MED (consent/privacy) · **Status:** OPEN — build 94 / web
- **Context:** As of 2026-10-23 web sign-up sets `allowSharing: false` (opt-in; stops the silent opt-in that had no wording and no control). But web still has NO way for a user to turn sharing *on* later, and no wording is shown. iOS has a Settings toggle; web has nothing.
- **Proposed:** (a) add an optional checkbox at web sign-up with the SEO-01 wording ("share publicly — your post may be featured on the toska website and appear in Google search. your handle is never shown."), unchecked by default, writing `allowSharing` accordingly; (b) add a sharing toggle to the web app (settings/profile) so web users can see and change it, matching iOS. Reuse `showSharing` wording verbatim from iOS SettingsView.
- **Policy wording re-edit (when this ships):** update privacy.html:127 and terms.html:113 — they currently say "new accounts start with it off; turn it on/off in the toska iPhone app under Settings → Privacy." Once the web sharing toggle exists, drop "iPhone app" and mention the web setting; once sign-up checkboxes exist (both platforms), mention the at-sign-up choice.
- **Do not** change existing accounts.

## B94-iOS — Sharing opt-in on iOS (defaults done; sign-up choice pending)

- **Severity:** MED (consent/privacy) · **Status:** FIXED 2026-10-23 — defaults false at all 3 paths + opt-in checkbox on the email sign-up form (CreateAccountView). Apple/Splash button flows keep default-off + Settings opt-in (no form to host a checkbox — owner to decide if a post-Apple-signup prompt is wanted).
- **Done (2026-10-23):** creation default flipped to `allowSharing: false` at all three paths — CreateAccountView, AppleSignInHelper, SplashView. Settings toggle unchanged (still the opt-in control). Read-fallbacks (`?? true`) deliberately left so existing/legacy accounts are unchanged.
- **Pending (build 94):** add an optional choice at sign-up (CreateAccountView + Apple/Splash onboarding) showing the SEO-01 wording, unchecked by default, that sets `allowSharing` at creation. Keep the Settings toggle.
- **Do not** change existing accounts.

---

## B94-APPLE — one-time post-signup sharing prompt for Apple/Splash (deferred)

- **Status:** DEFERRED (owner decision 2026-10-23). Apple/Splash button flows keep allowSharing:false at creation + Settings opt-in. Future nicety: a one-time "share publicly?" prompt (SEO-01 wording) after an Apple/Splash first sign-up so those users see the choice without opening Settings.

---

## TECH-DEBT-RULES-CEILING — posts-create rule is AT the 1000-expression limit (post-launch refactor)

- **Severity:** tech debt (blocks future rule-layer security changes) · **Surface:** firestore.rules · **Status:** OPEN, logged 2026-10-26
- The `allow create` on `match /posts/{postId}` evaluates right at Firestore's hard **1000-expression ceiling**. Confirmed empirically: adding consent binding B (one `||` clause + a `get()`) made the emulator reject even the happy path with `Unable to evaluate ... maximum of 1000 expressions ... for 'create'`. The clause was reverted; B now lives in Cloud Functions + render-gates instead (see CONSENT-B below).
- **Impact:** any NEW post-create security constraint cannot be added at the rule layer until expressions are freed. New checks must go into `validatePost`/render gates, which carry a brief visibility window the rule layer doesn't.
- **Fix direction (post-launch):** either (a) split the posts-create rule (factor repost vs original into separate `match` legs or helper functions to shrink the evaluated chain), or (b) move some existing checks into `validatePost` to reclaim headroom. Measure with the emulator after each change.

---

## CONSENT-B/C — sharing opt-in enforced server-side (render-gate + re-stamp)

- **Severity:** MED (consent/privacy) · **Surface:** functions · **Status:** DEPLOYED PROD 2026-10-26 + committed (c246d6a) — staging probe 9/9 (`consent-render-gate-probe.mjs`), prod smoke: consenting author renders 200, non-consenting 404s
- **Why not in rules:** B (bind isShareable→allowSharing at post-create) couldn't fit the create rule (see TECH-DEBT-RULES-CEILING). Enforced instead at every public render surface + a server re-stamp.
- **B render-gate:** `evaluateSharePage` now takes the author's LIVE `allowSharing` and 404s when it isn't true — covering `/p/` (sharePage), `/og/*.png` (shareCardImage), the sitemap, and publicFeed (batched author lookup). Closes tampered self-stamps, stored-flag drift, and "turned sharing off after sharing."
- **B re-stamp:** `validatePost` clears `isShareable` on an ORIGINAL post when the author's live consent is off (so the in-app share button respects it too). Reposts untouched (rule-pinned to the original author's consent).
- **C:** `onAllowSharingChanged` now queries own posts by `authorId` only and branches on `isRepost` in code — the old `.where("isRepost","==",false)` silently skipped field-less originals, so revocation never retracted them.
- **Tests:** sharePage.test.js +3 consent cases (21/21 pass). Staging probe pending (post w/ allowSharing false, and author-turns-off-after-sharing, must 404 on every public surface).

---

## CONSENT-A/D/E — client opt-in hardening (iOS + web)

- **Severity:** MED (consent/privacy) · **Surface:** iOS + web · **Status:** FIXED + committed (c246d6a) — web live in prod; iOS in build 102 (on TestFlight, hand-test 2026-10-27)
- **A (iOS):** `UserHandleCache.allowSharing` now defaults **false** (was true) + reset to false in `stopListening`; `ComposeView.postNow` reads the real `allowSharing` from the same user-doc snapshot it fetches for the handle when the cache is still unloaded — so a post composed in the post-sign-in/account-switch window is never over-shared, and a genuine opt-in isn't dropped.
- **D:** flipped the `?? true` consent reads to `?? false` (fail closed) — UserHandleCache:87, FeedView:561, PostDetailView:1152, ProfileView:973/1068, ShareCardView:48, SettingsView:611, PostInteractionManager reply-repost author read:1032, and web writes.js createPost. LEFT `?? true` on the repost-mirror reads (PostInteractionManager:414, web writes.js:229) — rules pin a repost's isShareable to `== original.get('isShareable', true)`, so flipping only that side would reject reposts of field-less originals.
- **E (web):** `createPost` adds `&& !isMidnight` to isShareable, matching iOS (ComposeView excludes expiresAtMidnight).

---

## WEB-AUTH-LATENCY — slow web sign-in/sign-up (step 1 FIXED; minInstances DECLINED)

- **Severity:** perf · **Surface:** web (app.js) + functions · **Status:** step 1 SHIPPED prod 2026-10-26 (c246d6a); minInstances **decided AGAINST** (owner, 2026-10-26)
- **Symptom:** web sign-in paused a beat; sign-up sat ~10s on the same screen.
- **Root cause:** reCAPTCHA Enterprise App Check token was minted lazily on the
  first attested call (the submit click), not on page load; signup additionally
  waited on two cold-start functions in the account-creation critical path
  (`blockBannedSignups` beforeUserCreated, `confirmAdult` callable).
- **Step 1 shipped:** (a) warm App Check — mint a token at page load so it's
  ready by submit; (b) "setting up your space…" progress message on signup;
  (c) un-await `confirmAdult` and retry it in-session (safe: the 18+ gate is
  enforced server-side — posts AND replies create rules require
  `hasConfirmedAdult()`, firestore.rules:1154/1615, and `confirmedAdult` is
  server-owned, so routing can't bypass the age check).
- **minInstances — DECLINED (owner 2026-10-26):** after the warm-up, sign-in is
  noticeably faster, so the App Check mint was the dominant cost, not function
  cold starts. Not worth ~$6–12/mo for always-warm `blockBannedSignups` +
  `confirmAdult`. **Revisit only if** signup feels slow again in the 5–10s range
  (that would point back at those two cold starts); then `minInstances: 1` on
  just those two is the fix. Sign-in is unaffected by minInstances (no blocking
  function on that path).

---

## WEB-PW-8 — web signup accepted 7-char passwords / unclear message (FIXED)

- **Severity:** MED (auth policy mismatch) · **Surface:** web (app.js) · **Status:** FIXED 2026-10-27 — staging-verified, DEPLOYED PROD hosting + committed (7a3cd07)
- Found in the 2026-10-27 full-app-test pass: web signup had no client length check, the placeholder said "at least 6 characters", and the weak-password error mapped to "…at least 6", contradicting the server's 8-char policy.
- **Fix:** placeholder → "at least 8 characters"; client-side `pw.length < 8` guard with "password must be at least 8 characters."; weak-password / password-does-not-meet-requirements error mapped to the same 8-char message. Staging-verified: 7-char blocked with the correct message.

---

## WEB-HANDLE-FORMAT — web accounts got anonymous_<uuid> instead of word-pair handles (FIXED, new accounts)

- **Severity:** MED (cross-surface parity / brand) · **Surface:** web (app.js) · **Status:** FIXED 2026-10-27 for NEW accounts — staging-verified (`sadly_wound_916`), DEPLOYED PROD hosting + committed (7a3cd07)
- Web `claimHandleAndCreateUserDoc` generated `anonymous_<uuid8>`; iOS generates `{adjective}_{noun}_{1-999}`. Fix ports the EXACT iOS word lists (ContentModeration.swift handleAdjectives/handleNouns, 30+30 — keep in sync) to app.js `HANDLE_ADJECTIVES`/`HANDLE_NOUNS` + `randomWordHandle()`; same batched handles/{h} registry claim; the last-resort fallback after 4 collisions (≈900k combos) stays WORD-BASED with a wide 6-digit number (`randomWordHandle(999999)`) — **never anonymous_** (owner 2026-10-27) — so signup can't hard-fail and no anonymous_ handles are ever minted.
- **Existing prod `anonymous_` handles: 3 of 11 users** (3 registry rows) — the web-created accounts. **NOT migrated** — only new accounts change. Migrating the 3 would ripple through the handle registry + byline pins; left for a separate owner decision.

---

## APPCHECK-STAGING-DEBUG — iOS simulator App Check debug token registered (STAGING ONLY)

- **Severity:** test infra · **Surface:** iOS UI tests vs staging · **Status:** DONE 2026-10-27 (fixed-token setup)
- The iOS simulator uses `AppCheckDebugProviderFactory` (toskaApp.swift:87, `#if DEBUG` only — Release uses AppAttestProviderFactory and NEVER reads FIRAAppCheckDebugToken). Authenticated UI tests stalled at "Feed didn't load after sign-in" because the debug token wasn't registered — and `xcodebuild test` reinstalls the app each run, rotating the token, so a one-off captured token never sticks.
- **Repeatable setup (fixed token):**
  1. A fixed UUID lives in the gitignored `~/Desktop/toska/.local-credentials.md` as `TOSKA_STAGING_APPCHECK_DEBUG_TOKEN=<uuid>` (NOT committed — repo is public).
  2. It's registered as a debug token on the **staging** iOS app ONLY: `projects/260913424323/apps/1:260913424323:ios:a6631554b2614bed01ff76/debugTokens` (displayName `sim-uitest-fixed`). **Never prod.** (The old rotating `sim-uitest-2026-10-27` token was deleted.)
  3. `build/ios-uitest.sh` exports `TEST_RUNNER_FIRAAppCheckDebugToken` (read from the creds file); XCTest forwards `TEST_RUNNER_`-prefixed vars to the runner, and each auth test class's `setUpWithError` calls `applyAppCheckDebugToken(app)` (WalkthroughUITests.swift) to put it in `app.launchEnvironment["FIRAAppCheckDebugToken"]` for the DEBUG debug-provider.
- Also: run `-parallel-testing-enabled NO` (clone keychain -34018) and pass staging creds as `TEST_RUNNER_TOSKA_EMAIL` / `TEST_RUNNER_TOSKA_STAGING_TEST_PW`.

---

## IOS-SIM-AUTH-FEED — authenticated iOS UI tests don't load the feed on the simulator (post-launch test-infra)

- **Severity:** test-infra (NOT a product bug) · **Surface:** iOS XCUITest vs staging · **Status:** OPEN, deferred post-launch 2026-10-27. **Authenticated iOS flows are tested BY HAND on a real device for now.**
- **Symptom:** every authenticated UI test (`WalkthroughUITests.test02_login`, `test02z_coldLaunchFeedRenders`, all `CrossSurfaceTests`, `ShareCardInteractionTests`) fails at "Feed didn't load after sign-in." Sign-in (Auth) succeeds; the feed never populates in the simulator. Web sign-in loads the feed fine on the same staging backend, so **the data/rules are correct — this is simulator-specific.**
- **What I learned (2026-10-27), ruling out App Check:**
  - The simulator's debug token does NOT rotate — it persists in the app container (`D1C03947…`) across `xcodebuild test` reinstalls.
  - Registering that exact token for staging (run `by759021c`) did **not** fix the feed load.
  - A fixed injected token (`FIRAAppCheckDebugToken` via `launchEnvironment`) was **ignored** — the persisted UserDefaults token wins unless the container is erased first.
  - Both paths → identical "Feed didn't load." **So App Check registration is not the fix**; the blocker is deeper (matches the long-standing "simulator has ~4 stacked App Check issues" note).
- **Non-auth iOS tests pass** (splash, logged-out feed, sign-in/create-account flow existence, launch, perf, sign-out, probe) — those remain useful CI/local signal.
- **Next steps (post-launch):** either run the auth UI tests on a **registered real device** (reliable), or, to make the simulator path work, `simctl erase` before the run so the injected fixed token is used AND dig into why the feed listener doesn't populate under the debug App Check provider. The harness is ready for a real device (fixed token registered; `applyAppCheckDebugToken` hook wired into every auth test class).

---

## DELETION-CASCADE — §11 GDPR cascade verified clean (2026-10-27)

- **Severity:** verification · **Surface:** functions (staging) · **Status:** PASS 2026-10-27
- `firestore-tests/deletion-cascade.mjs` (live staging): after deleting users/V, NO residue — V's post, reply, like, repost, user subtree, O's follower/following entries for V, and V's report all removed; O.followerCount correctly decremented to 0.

---

## CRISIS-TEST-CLEANUP — automated crisis test tripped the staging watchdog (FIXED)

- **Severity:** test hygiene (false crisis alert) · **Surface:** staging crisis watchdog · **Status:** FIXED 2026-10-27
- **What happened:** the 2026-10-27 full-app-test `fulltest-backend-probe` created a crisis post to verify it's held. The crisis trigger wrote an `undeliveredCrisisPages/crisisAlert_<postId>` record; the probe deleted the POST but not that record. Staging has no real `crisisAlertRecipients`, so the record stayed unclaimed, and `crisisDeliveryWatchdog` paged "[STAGING] crisis page UNDELIVERED" ~15min later (04:17 UTC, post `ftpost_crisis_mvq5ni4e`). **Prod was clean** (undeliveredCrisisPages = 0 in that window).
- **Fix:** (1) deleted the stray staging record; (2) `fulltest-backend-probe.mjs` teardown now waits for the trigger, then deletes `undeliveredCrisisPages/crisisAlert_<id>` + `processedTriggerEvents/crisisAlert_<id>` for every test post; (3) `fulltest-cleanup.mjs` sweeps the same records for test-post patterns. Any future automated crisis test cleans up after itself, so the staging watchdog won't false-alarm.
- **Note:** the crisis *hold* behavior is correct — the watchdog did its job; the gap was test teardown, not the safety path.

---

## M5 — Apple Sign-In silently no-ops when no presentation window (FIXED)

- **Severity:** MED (auth) · **Surface:** iOS (AppleSignInHelper) · **Status:** FIXED + committed (c246d6a), in build 102
- `presentationAnchor` returned a throwaway `UIWindow()` when no foreground key window was found → the Apple sheet presented over an invisible window and the continuation hung ("button does nothing"). Fix: try the active scene's key window, then any scene's key window, then any window; if truly none, resume the continuation with an error ("Couldn't start Sign in with Apple. Please try again.") so the UI surfaces it, then return a detached anchor only to satisfy the non-optional API.

---

## M4 — "back to login" raced clearFCMToken against signOut (FIXED)

- **Severity:** MED (push/account hygiene) · **Surface:** iOS (ContentView verify-error escape hatch) · **Status:** FIXED + committed (c246d6a), in build 102
- The escape-hatch button called fire-and-forget `clearFCMToken()` then `signOut()` immediately; `clearFCMTokenAndWait` reads `currentUser?.uid`, which `signOut()` clears first, so the Firestore `fcmToken` delete could be skipped (stale token → pushes to the wrong account). Fix: wrap in a `Task { @MainActor }` and `await clearFCMTokenAndWait()` before `signOut()`, matching every other sign-out path.

---

## M3 — uncancelled 15s sign-in sweep Task can complete after the user leaves (OPEN)

- **Severity:** MED (auth lifecycle) · **Surface:** iOS (SignInView ~296) · **Status:** OPEN, logged 2026-10-26
- On a 30s email-sign-in timeout, a bare `Task` polls `currentUser` for 15s with no cancellation on disappear. If the user backs out, it can still complete sign-in and `dismiss()` out from under them. Not a cross-account leak (the late `signIn` only sets the just-submitted credential). Fix: store the task, cancel in `.onDisappear`, and require `currentUser` was nil at call start.

---

## M2 — dead DM-cleanup step still runs each account-deletion cascade (OPEN)

- **Severity:** LOW (vestigial) · **Surface:** functions (cleanupUserConversationsForUid ~501) · **Status:** OPEN, logged 2026-10-26
- DMs were cut (conversations/messages denied in rules), so no convo docs exist, yet every deletion pays a `participants array-contains uid` query, and the comment block still asserts live DM-cleanup semantics. Harmless; drop the step or mark it vestigial.

---

## LOW-BATCH-2026-10-26 — minor review findings (OPEN)

- **Severity:** LOW · **Surface:** iOS/functions · **Status:** OPEN, logged 2026-10-26
- **L1** — BlockedUsersCache not started on the inline sign-in success paths (SignInView/AppleSignInHelper/SplashView/CreateAccountView start only UserHandleCache; block cache starts via toskaApp.swift:181 auth-state callback). Ordering window where a feed can render before blocks load. Fix: start BlockedUsersCache alongside UserHandleCache on each path.
- **L2** — New-account rollback orphans the claimed handle-registry entry (AppleSignInHelper ~165/211, parallel Google/email paths): rollback deletes the auth user but not the handle claim, slowly burning handles.
- **L3** — `FeedViewModel` client filter defaults missing `moderationStatus` to `"live"` (fail-open). Low risk (all posts created with an explicit status); prefer fail-closed.
- **L5** — `unrepostReply` (PostInteractionManager ~1150) only deletes the deterministic doc and doesn't broadcast `.postDeleted`, unlike `unrepost`; a legacy reply-repost row could linger until refresh.
- **L4 (nit)** — `SettingsView` ~1060 `var url` should be `let` (compiler warning only).
