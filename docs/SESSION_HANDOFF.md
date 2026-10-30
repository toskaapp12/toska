# Toska — session handoff

Living note for picking up work in a fresh session. No secrets or personal
data here by design (this file is in the public repo and served by Pages).
Credentials live only in the gitignored local file; infra ids live in the
Firebase/GCP consoles.

_Last updated: 2026-10-30 (name-list expansion + whisper/midnight normalization on prod; build 107)._

## 2026-10-28 — multi-user audit + A1 fix (PROD)

- **Audit:** an independent, observation-only multi-user functional audit ran on staging 2026-10-27
  (`issues/AUDIT_MULTIUSER_STAGING_2026-10-27.md`, 49 findings, staging restored to its exact
  pre-audit baseline). Owner-set fix order: Tier 1 = A1, A2, crisis replies, B3, A5, C8, then
  C1/C3/C5/C2; product decisions; Tier 2.
- **A1 FIXED + PROD (rules tag `rules-prod-2026-10-28-a1`):** any signed-in user could LIST other
  users' held / crisis-held posts and replies (full text + handle + reason) with any query that did not
  constrain `moderationStatus` — `moderationVisible()` / `postVisibleToCaller()` defaulted a missing
  field to `'live'`, which made unconstrained list queries satisfiable. Fix: default `''`, drop the
  `resource == null` leg from the posts and replies LIST rules (GET keeps it so missing docs still read
  as not-found). Pinned by `firestore-tests/held-content-enumeration.test.js` (43 tests; suite 434/434);
  two legacy "no status defaults to live" tests reversed; fixtures now carry `moderationStatus`.
  Prod has zero status-less posts/replies.
  - **Client fallout:** a `documentId in` query cannot satisfy the live constraint even with the filter
    (denied in emulator and on staging), so web `fetchRefTab` (liked/saved) and iOS ProfileView
    liked/saved + FeedViewModel engaged-tags now read per document (GET allows live, denies held →
    skipped; ProfileView tells deleted from held before self-healing the index). iOS
    PostDetailView author repost sweep pins live. **Web LIVE on prod; iOS rides build 103.**
  - **Verification:** emulator 434/434; staging 73/74 (the one "fail" was a fixture promoted to live by
    validatePost before the read); prod: owner confirmed liked/saved tabs on app.toskaapp.com, then
    24-shape in-page console check PASS (12 deny / 12 allow); released ruleset byte-identical to
    `firestore.rules`; two throwaway prod accounts + content removed (totals back to 40 posts /
    16 replies); no function errors or permission denials in Cloud Logging; watchdog heartbeat nominal.
  - **Headless prod testing is impossible by design** (App Check 403 → "couldn't verify this device");
    do NOT register a prod App Check debug token. Prod browser checks are owner-run; the console
    snippet lives in the audit scratch (`a1-prod-console-check.js`).
- **A2 FIXED + PROD (functions + hosting, 2026-10-28 ~16:40 UTC):** moderation gaps from the audit —
  group-dehumanizing hate (new `dehumanizing` reason, HELD never deleted), explicit sexual detail
  (`sexual_explicit`, HELD, overridable at compose, with "fucked me over/up" + exclamation guards),
  third-person physical threats, underage phrasings (bare age, curly apostrophe, "16f", bare "born in
  YEAR"), spam now checked on replies, and the "54"→"sa" crisis false positive (short algospeak tokens
  match raw text only). Corpus 141/141 + reply cases + crisis-tier 29/29; detector-parity 100/100;
  staging sweep 39/39; prod sweep 34/34 with immediate cleanup. See BUGS.md AUDIT-A2. Accepted miss:
  "dumped in 9th grade" (pinned). iOS mirror (ContentModeration.swift `.sexualReview`, dehumanizing
  patterns, threat additions, short-token fix) rides build 103.
- **Item 3 FIXED + PROD (four reply functions, 2026-10-28 ~17:40 UTC):** explicit-tier crisis replies
  are HELD (`pending_review`/`crisis`); soft-tier stay live + queued; supportive reach-outs (negation
  tied to the self-harm verb + help signal, no directed-abuse token) stay live and no longer trip the
  threat lane; directed abuse ("kys", "go kill yourself") is the abuse lane with no crisis queue entry;
  no strikes from reply holds. admin.html: "mark reviewed" releases a held crisis reply; approve flips
  the queue entry (live on GitHub Pages once this push lands). iOS held-reply banner + crisis support
  line in build 103. Staging 11/11, prod 5/5 (soft/supportive/"kys" only). See BUGS.md AUDIT-3.
- **B3 FIXED + PROD (2026-10-28 ~19:25 UTC, `onReplyDeletedScrubNotifPreview`, deployed with
  `--only functions:<name> --force`; prod function set = index.js exports minus the parked
  sendBrandedPasswordReset = 73, nothing deleted):** a deleted reply (author/admin/hard-delete) no
  longer leaves its text in the recipient's reply-notification preview. Staging 12/12, prod 4/4.
- **A5 (profile-doc exposure) approved as two phases:** Phase 1 = authorization fields
  (confirmedAdult*, restricted*) move to users/{uid}/private/data with that doc's write rule locked,
  rules helpers read private/data, confirmAdult + admin restrict/unrestrict write private only,
  mirror reversed, back-fill (owner approves the prod data write after seeing fields + counts).
  Phase 2 (after build 103 is the floor) = acceptedPolicy*, hasCompletedOnboarding. allowSharing and
  the counters stay public-readable; showFollowerCount stays display-only (wording: "hides the
  count from your profile display"); **Tier 2: server-maintained public follower-count mirror
  behind the toggle.** Policy wording batch gains "what other signed-in users can see" + "post or
  reply" for crisis holds.
- **A5 phase 1 DONE + PROD (2026-10-28 ~21:00 UTC; rules tag `rules-prod-2026-10-28-a5`):** the six
  authorization fields (confirmedAdult*, restricted*) now live only in users/{uid}/private/data;
  public user docs carry none of them (back-fill 11/11). Rules: `canPublish()` single-get gate for
  post/reply create (ceiling-safe), `notRestricted()` time leg for edits/self-delete; private/data
  write rule locks the six keys (owner) with an admin leg for restricted*. Functions: confirmAdult +
  repeat-offender → private/data; mirrorModerationState = relocation shim; onPrivateAuthStateWritten
  (row + audit); clearExpiredRestrictions every 10 min (timed restrictions lift ≤10 min late —
  accepted); auditUserRestriction no-op. admin.html restrict/unrestrict → private/data (live on push).
  Deploy order that worked: functions → pre-check private attestation → rules → owner post/reply →
  back-fill (deletes public keys last). See BUGS.md AUDIT-A5.
- **C8 FIXED + PROD (2026-10-28 ~23:00 UTC, 10 functions via `--only`, prod set 75 → 75):** the
  crisis watchdog is now a retrier + rate-limited alerter instead of a 5-minute repeater. Soft-tier
  posts are ignored (never paged by design); explicit-tier unpaged posts get an `undeliveredCrisisPages`
  record; every record is retried (page payload stored on the record) and, while unresolved, logged
  `crisis_page_undelivered` hourly for the first 6 h after detection, then every 6 h, no ceiling.
  Resolution = delivered page (claim), item deleted (delete triggers drop record + claim), post marked
  crisis-reviewed, or reply queue entry reviewed. Staging 18/19 (one over-strict expectation), prod
  6/6 on the review + deletion paths only (no crisis wording, no page payload). See BUGS.md AUDIT-C8.
- **Four audit bugs FIXED (2026-10-28 ~23:45 UTC; prod functions via `--only`, 14 functions, set
  75 → 75; prod hosting for the web change):**
  - **C1** iOS reply repost: payload now carries `moderationStatus: pending_validation` (rules pin
    added) — build 103.
  - **C2** burst limiter: only the 6th+ post in a 5-minute window is held; a rate-limit call never
    relabels an existing hold; a content reason UPGRADES a `rate_limit` label (owner-confirmed);
    content-vs-content stays first-wins (documented in BUGS.md AUDIT-C2).
  - **C3** totalLikes: plain repost copies are display mirrors — excluded from delete-time settlement
    and the drift job; the mirror no longer touches reply-repost rows. Owner account repaired on
    prod 78 → 2 (dry run re-checked, guarded write).
  - **C5** web: the author can open their own held post (pending banner); iOS detail banner in
    build 103. **Owner check pending on prod web.**
  - Tests: rules 470, functions 122 (two stale A5 mirror tests rewritten to the shim contract);
    staging 17/17 (`c2c3c5-verify-staging.mjs`), prod 6/6 (neutral throwaways, totals restored).
- **Product decisions DONE + PROD (2026-10-29 ~03:40 UTC):** 18+ gate on likes/reply-likes/follows/
  saves/reports; blocked users can't save the blocker's posts (reporting stays); no replies on held
  posts + 2-char minimum (rules + validateReply backstop; composer hidden on web, iOS build 103);
  plus-alias ban normalization; restricted users = wording only. Rules 497 / functions 127; staging
  19/19; prod ruleset byte-identical + validateReply 3/3. See BUGS.md AUDIT-PD.
- **Policy v4.0 LIVE (2026-10-29):** Terms + Privacy v4.0 on the site, support + FAQ updated, web
  `POLICY_VERSION = 5` live (re-acceptance gate verified on staging 5/5), iOS `currentPolicyVersion = 5`
  + label + in-app body in build 103; App Store privacy label unchanged (note added). See BUGS.md
  POLICY-4.0.
- **C5 owner check:** the "held" post was never held (bare first name → no server flag); the profile
  row's "under review." was the `pending_validation` window → now reads "checking your post…" (web).
  Owner re-check pending after accepting v4.0. **Four owner posts from that check are still live on
  prod** ("test 1/2/3", "Sarah broke up with me last week.") — owner said deleted; ask before removing.
- **Owner's `allowSharing` flipped to false 03:22:13Z** — a client write (web profile checkbox or iOS
  Settings save), nothing server-side; see BUGS.md OBS-SHARING-FLIP. Not changed.
- **Build 103 SHIPPED (2026-10-29 04:02 UTC):** archived + uploaded via CLI (ASC key, automatic
  signing; `scratchpad/ExportOptions103.plist` shape: app-store-connect / destination upload), ASC
  state VALID, assigned to the Internal TestFlight group. Carries: B102-1 own-post white card; A1
  per-doc liked/saved + engaged tags + repost-sweep filter; A2 detector mirror; item 3 held-reply
  banner; A5 AdminModerationView → private/data; C1 reply-repost `moderationStatus`; C5 own-held-post
  banner + C6 reply bar hidden on held post; policy v4.0 (`currentPolicyVersion = 5`, label, in-app
  body). **Owner hand-test on device:** re-acceptance cover appears once (v4.0 label), reply repost
  works, own held post opens with banner and no reply bar, liked/saved tabs load, white own-post card.
  Not yet in 103: liked/saved "load more" pagination (still a follow-up).
- **First-name decision (2026-10-29) — PROD (functions 75 → 75, hosting, pages published; featured
  check 11/11 kept + indexable + in sitemap); staging 12/12:** bare first names
  stay allowed; soft compose nudge (web live on staging; iOS in build 104); `likelyFirstName` shared
  detector pinned by parity (116/116); featuring exclusion server-side (onPostUpdated strip +
  publicFeed / sitemap / share-page noindex; prod dry run 11 featured, 0 drop); admin "possible name"
  badge (display only); wording fixes (hold dialog, store description → owner updates ASC, Terms §5,
  no version bump). See BUGS.md FIRSTNAME. Prod plan: `--only functions:onPostUpdated,publicFeed,
  sharePage,postsSitemap` (75 → 75) + hosting; push publishes terms.html + admin.html.
- **Removal notices (2026-10-29) — PROD (functions 75 → 76, hosting, pages published; prod check
  5/5); staging 14/14:** authors get an
  in-app `type: "removal"` notification (statement of reasons, DSA Art. 17) on admin removals (new
  dashboard reason picker + stamps; new `auditReplyDeletion`) and automated hard deletes (slurs,
  too-long, reply-on-held-post); spam / deleted accounts / self-deletes silent; pii/threat previews
  masked, safety variant with region-aware resources on the clients; web row + details live on
  staging; iOS sheet in build 104; Terms §6 + support page updated (no version bump). See BUGS.md
  REMOVAL-NOTICES. Prod: `--only` the five functions (`--force` for the new one, 75 → 76), hosting,
  push.
- **Build 104 SHIPPED (2026-10-29 15:52 UTC):** CLI archive + upload (ASC key), state VALID, Internal
  TestFlight group. Carries on top of 103: first-name compose nudge (`likelyFirstName` mirror),
  hold-dialog copy ("full name or contact detail … try he/she/they"), removal-notice rendering
  (`NotificationItem.removal`, row + `RemovalNoticeSheet` with `CrisisLines.resources` for safety).
  **Owner hand-test:** type "Sarah broke up with me" in compose → inline nudge, × dismisses, post goes
  through; a full-name post shows the new dialog copy; a removal notice row opens the statement sheet.
- **Builds 105/106 (2026-10-29):** 105 was uploaded identical to 104 by mistake (a patch step failed
  silently before the archive; left UNASSIGNED in TestFlight). **106** carries the compose fix: mode
  banners + first-name nudge moved above the editor (visible with the keyboard up); web composer
  reordered to match (staging). Assigned to Internal.
- **Tier 2 triage (owner 2026-10-29):** B4/C8/C11/C12/C14 closed by earlier work; C7, C9, C10, C13, D2
  tag counts, follower-count mirror → POST-LAUNCH (BUGS.md AUDIT-TIER2-STATUS).
- **A4 deletion residue — PROD 2026-10-29 (77 functions, cascade check 5/5, 97 audit rows scrubbed);
  staging 8/8; code 7bf2101:** audit rows only
  for admin removals; others' liked/saved reply snapshots scrubbed on reply delete (new
  `onReplyDeletedScrubSnapshots`) and in the account cascade; 4 CG indexes. Prod plan: indexes →
  3 functions `--only --force` (76 → 77) → throwaway cascade check (`a4-check-prod.mjs`) → audit-row
  scrub `--apply` (97 rows, dry run shown) → logs. See BUGS.md AUDIT-A4.
- **A3 sharing-off propagation — PROD 2026-10-29 (hosting headers + 4 functions, pages published);
  staging 5/5 measured (page/card/feed 122 s, sitemap 304 s):** cache caps cut (page/card 60/120, sitemap 300/300, feed 2-min memo + 120/120); policy
  wording "within a few minutes". Prod plan: hosting + 4 functions `--only`, push. See BUGS.md AUDIT-A3.
  **Next after A4/A3 prod: launch prep; post-launch list in BUGS.md.**
- **Name-list expansion + nudge-only names + whisper/midnight normalization — PROD 2026-10-30 ~16:00 UTC
  (14 detector-dependent functions via `--only`, 77 → 77, nothing removed; hosting; push publishes
  admin.html); staging 15/15 first; code 4d30356 + bbe10bf:** given names 208 → 4,030 (Wikidata CC0),
  surnames 81 → 877 (US Census 2010), ambiguous words 55 → 145 (owner's common-word names + curated;
  accepted: Taylor/Genesis no longer nudge, six occupational surnames no longer lone-surname holds);
  `NUDGE_ONLY_NAMES` (christian, cole, dean, don, earl) nudge but never hold, "don't" stripped first;
  validatePost turns whisper+midnight into a one-hour whisper (3 function tests). Impact gate over
  401 real texts: 0 newly held / un-held / nudged. Parity 129/129, corpus 141, crisis 29, functions
  146. See BUGS.md NAMES-EXPANSION. **Final read-only prod sweep (2026-10-30 ~16:10 UTC):** ruleset
  `9d012ef6…` byte-identical to `firestore.rules`; 77 functions = exports minus the parked reset; 40
  posts all live (0 held / flagged / concerning / status-less), 16 replies all live, 11 users; 0
  undeliveredCrisisPages, 0 unreviewed crisis replies, 0 restricted, 0 open reports, 0 pending
  deletions; watchdog heartbeat every 5 min all zeros; no function errors since the deploy.
- **Build 107 SHIPPED (2026-10-30 16:12 UTC):** CLI archive + upload (ASC key, automatic signing,
  `ExportOptions` app-store-connect/upload shape), ASC state VALID, assigned to the Internal TestFlight
  group. Carries on top of 106: expanded name lists + nudge-only names in `ContentModeration.swift`
  (compose nudge now fires for most non-Anglo first names; "Dean"/"Don" nudge but never hold) and the
  in-app policy body "share pages and the website clear within a few minutes" (A3 wording). **Owner
  hand-test:** type "Olga broke up with me" in compose → inline nudge, post goes through; "my ex Nguyen"
  → held with the full-name/contact dialog; "Don't text him" → no nudge.
- **Bad-actor audit (2026-10-30, STAGING only; report `AUDIT_BADACTOR_STAGING_2026-10-30.md` at the
  repo root, gitignored):** 9 ranked findings — doxxing workarounds, report brigading, false crisis
  pages, post-and-vanish, admin queue burial, block survival, look-alike handles, ban evasion,
  cross-account flooding. **All nine fixed on STAGING in the owner's order (see BUGS.md
  BADACTOR-2026-10-30); PROD PENDING OWNER GO — nothing pushed** (a push publishes admin.html to the
  prod dashboard). Local commits only. Deploy set for prod when approved: `firestore:rules` + the 24
  functions in the staging deploy (`validatePost, validateReply, onPostCreated, onPostUpdated,
  onReplyCreatedModerate, onReplyUpdated, reconcilePostVisibility, publicFeed, sharePage,
  shareCardImage, postsSitemap, auditPostDeletion, auditReplyDeletion, onHandleCreatedScreen,
  notifyAdminsOfNewReport, onPostCreatedAlertAdmins, onReplyCreatedAlertAdmins,
  crisisDeliveryWatchdog, onReportCreatedAutoHide, onReportCreatedSnapshot (NEW → 77 → 78, `--force`),
  rateLimitReports, abuseSpikeWatch, blockBannedSignups, adminDeleteAccount`) + hosting + push, then
  prod Auth config: sign-up quota 10 per IP per hour (anonymous auth is already off on prod). Tests:
  functions 167 (+21), rules 408 (+15), parity 152/152, corpus 141, crisis 29; impact gate 0 real
  texts newly held. **Staging verification 2026-10-30 ~18:50 UTC (`staging-verify.mjs`, 31 checks):**
  all look-alike / leet / anonymous handles denied and a generator handle accepted; anonymous sign-in
  refused; whisper and midnight 2-minute expiries both normalized to 60 min, an honest midnight post
  kept (614 min); crisis text in a report → flagged, 0 pages; snapshot captured and surviving the
  post's deletion; second crisis post within the hour → held + queued with a throttled claim, 0 pages;
  3 fresh sockpuppets → post stays live, 3 ten-day-old reporters → hidden, third hide in 24 h capped;
  9 doxxing variants held as pii, "summer rain" control live; new-account report cap enforced (5 of 7
  stood — my burst wrote 6 in one second so the concurrent triggers dropped two earlier ones rather
  than the last two, a pre-existing ordering artifact of the limiter, not a defect). Fixtures removed,
  staging back to baseline. **Build 108 SHIPPED (18:43 UTC, ASC VALID, Internal group):** detector
  mirror (#1/#6) + generator-shaped fallback handle. **Owner hand-test on 108:** compose
  "sarah johnson broke up with me" → hold dialog; "summer rain on the window" → posts;
  "quiet_ghost_12 lied" → hold dialog.
- **PROD 2026-10-30 ~19:00 UTC — bad-actor fixes shipped (owner go):** rules `1ef1570c…` byte-identical,
  25 functions via `--only --force` (77 → 78, `onReportCreatedSnapshot` added, nothing removed), hosting
  (served vendor detector has the new rules), push (Pages republished admin.html), no function errors,
  watchdog heartbeat nominal; prod Auth sign-up quota **20 per IP per hour** (owner: carriers/campuses
  share IPs). **~19:47 UTC follow-up:** `rateLimitPosts, rateLimitReplies, rateLimitNotifications,
  rateLimitReports, validatePost` (78 → 78) — new-account limits + deterministic limiter ordering
  (BUGS.md BADACTOR-2026-10-30 "Follow-ups"), staging 5/5 first, commit 7c55947 pushed.
- **Launch-readiness review (2026-10-30, read-only):** `LAUNCH_READINESS_2026-10-30.md` (scorecard) +
  `DRAFT_INCIDENT_RESPONSE_PLAN.md` + `DRAFT_CHILD_SAFETY_PROCESS.md` + `DRAFT_RELEASE_PLAN.md`, all at
  the repo root (gitignored, owner review). **Top pre-submission items:** (1) `blockBannedSignups` cold
  start 13–14 s vs Auth's 7 s blocking deadline → first sign-up on a cold instance fails
  (`minInstances: 1` or codebase split — owner decision); (2) iPad/visionOS in the device family +
  landscape enabled, untested; (3) iOS feed listeners `limit(to: 500)` — the one real scaling cost
  (page at 40); (4) demo account + on-call + screenshots (owner); (5) contrast tokens below AA for
  timestamps, fixed-size fonts vs Dynamic Type, web inputs without labels.
- **Launch fixes (owner decisions 2026-10-30 evening; BUGS.md LAUNCH-2026-10-30):** `blockBannedSignups`
  `minInstances: 1` on staging + PROD (min-scale 1 confirmed; owner confirms one real sign-up);
  iPad stays (1.0 shipped with it — device family set 2026-04-16, before the 04-21 upload) with a
  centered ≤ 600 pt column at the root, visionOS removed; feed page 40 + 20 on iOS and web, own-id
  listeners 200/200/100, thread reply listener 100; contrast tokens fixed (web + iOS), 78 fixed fonts
  → `Font.toska(_:relativeTo:)` Dynamic Type on the 8 main screens, 15 web inputs labeled; demo
  password rotated (handed over in chat) + review notes gained the crisis-phrasing paragraph.
  **Staging web deployed; prod hosting pending owner go. Build 110 = all iOS changes (109 superseded by the policy-cover Dynamic Type fix).**
- **Owner next (ASC):** version 1.2 "Cancel Release" → rename to 1.3 → attach build 107 → submit
  (steps in the 2026-10-29 session report; "Cancel Release" discards the July build 82 approval,
  live 1.0 unaffected).
- **Next iOS build (103) batch:** B102-1 own-post white card; A1 per-doc liked/saved + engaged tags +
  repost-sweep filter (ProfileView, FeedViewModel, PostDetailView); A2 detector mirror
  (ContentModeration.swift, ComposeView `.sexualReview` override); item 3 held-reply banner
  (PostModels.MyReply pending fields, ProfileView replyRow, PostDetailView thread banner isCrisis);
  C1 reply-repost `moderationStatus` (PostInteractionManager); C5 own-held-post banner in
  PostDetailView (`ownPendingReview`);
  **follow-up: paginate the per-doc liked/saved reads (30 at a time, "load more") on iOS and web.**
- **Benign prod log noise seen 2026-10-28:** `adminDeleteAccount` "Invalid request" = GET probes from
  Google-range crawler IPs (rejected 400/404); `validateReply` NOT_FOUND ×3 after a slur reply is
  hard-deleted by `onReplyCreatedModerate` (pre-existing race, logged as a LOW follow-up).

## Where things stand

- **Production is healthy and launch-hardened.** A full pre-launch audit
  (`AUDIT_REPORT.md`, gitignored, local only) was run and its Phase-2 fixes
  shipped. Latest release tag: **`v1.3-b93`** (tags lag the builds; prod rules
  pinned at **`rules-prod-2026-10-28-a5`** — supersedes `rules-prod-2026-10-28-a1`).
- **iOS:** build **102** on TestFlight (v1.3) is the launch candidate — owner
  hand-testing on device 2026-10-27. Build 100 was the first "clean" candidate
  (FCM-DIAG stripped); 102 adds the consent cluster, M4/M5 auth fixes, lavender
  own-post tint, and GIF perf (see "Latest (2026-10-26 → 27)"). Critical paths
  verified in prod on earlier builds: sign-in (+TOTP), feed, GIF post, blocking,
  and the crisis flow end-to-end (detection → 988 check-in → hold → crisis page
  push).
- **Web (app.toskaapp.com):** everything through `7a3cd07` is **deployed to
  prod** — sharing-consent UI (B94-W), 8-char password message (WEB-PW-8),
  iOS-parity word-pair handles (WEB-HANDLE-FORMAT), warm App Check + signup
  progress message (WEB-AUTH-LATENCY step 1), own-post tint, WebP GIFs.
- **Functions (prod):** consent render-gate + re-stamp (CONSENT-B/C) deployed
  2026-10-26; crisis watchdog, SEC-UUID lockfile fix, and the parked (un-exported)
  branded-reset callable are all as committed.
- **Projects:** `toska-4ebf4` (prod), `toskastaging` (staging/dev). Web app
  = Firebase Hosting (app.toskaapp.com). Marketing + legal + admin + prompts
  = GitHub Pages (www.toskaapp.com, from `docs/`). No Cloud Storage anywhere
  (media is Giphy URLs via a server proxy).

## Latest (2026-10-26 → 27) — consent cluster, build 102, web parity, test infra

All **LIVE/COMMITTED** unless marked. Details per id in `issues/BUGS.md`.

**1. Sharing-consent cluster (`c246d6a`, 2026-10-26).**
  - **B render-gate (functions, PROD):** `evaluateSharePage` takes the author's
    LIVE `allowSharing` and 404s when it isn't true, on every public surface —
    `/p/` (sharePage), `/og/*.png` (shareCardImage), the sitemap, and
    `publicFeed` (batched author lookup). **B re-stamp:** `validatePost` clears
    `isShareable` on an original post when the author's consent is off.
  - **C (functions, PROD):** `onAllowSharingChanged` queries by `authorId` and
    branches on `isRepost` in code (the old `isRepost == false` filter skipped
    field-less originals, so revocation never retracted them).
  - **D (iOS + web):** consent reads flipped `?? true` → `?? false` (fail
    closed), except the repost-mirror reads that rules pin to the original.
  - **E (web, PROD):** `createPost` excludes midnight posts from `isShareable`.
  - **A (iOS, build 102):** `UserHandleCache.allowSharing` defaults false;
    `ComposeView.postNow` reads the real value from the handle snapshot during
    the post-sign-in window.
  - **Why not rules:** the posts-create rule sits AT the 1000-expression
    ceiling (TECH-DEBT-RULES-CEILING). Verified: `sharePage.test.js` 21/21,
    **staging consent probe 9/9** (`firestore-tests/consent-render-gate-probe.mjs`),
    prod smoke (consenting author renders 200, non-consenting 404s).

**2. Build 102 (iOS, `c246d6a`)** — consent A/D above; **M4** (await
`clearFCMTokenAndWait` before `signOut` on the verify-error escape hatch);
**M5** (Apple Sign-In resumes with an error instead of hanging on a dead
window); own-post lavender tint (prompt-card color, displayed-author based so
reposts of others aren't tinted); GIF perf — off-main decode + decoded-image
cache, URLCache dedupe, WebP rendition with .gif fallback, prefetch of the next
rows. B94-3's neutral placeholder shipped earlier in build 96 (`5ff0121`); 102's
perf work is the rest of that polish — **device-verify on 102**.

**3. Web (`69a01f7`, `c246d6a`, `7a3cd07`, all PROD):** B94-W sharing consent
(signup checkbox + profile toggle; privacy/terms re-worded); WEB-AUTH-LATENCY
step 1 (warm App Check on load, "setting up your space…", un-awaited
`confirmAdult` with in-session retry — 18+ gate is rule-enforced server-side;
**minInstances declined** by owner); WEB-PW-8 (8-char placeholder + client guard
+ error mapping); WEB-HANDLE-FORMAT (`{adjective}_{noun}_{n}` handles ported
from `ContentModeration.swift` word lists — keep in sync; the collision
fallback stays word-based, **never `anonymous_`**; the 3 existing prod
`anonymous_` accounts are owner test accounts, left as-is).

**4. Test infra (`7a3cd07`, `49e2f89`, 2026-10-27 full-app-test pass):**
`fulltest-backend-probe.mjs` (moderation + counters + crisis) and
`fulltest-cleanup.mjs`, both now tearing down `undeliveredCrisisPages/` +
`processedTriggerEvents/` for test posts (CRISIS-TEST-CLEANUP — a probe crisis
post had tripped the staging watchdog once; prod was clean). DELETION-CASCADE
verified clean on staging. A fixed staging-only App Check debug token
(`sim-uitest-fixed`, value in the gitignored creds file) is wired via
`applyAppCheckDebugToken(app)` into every auth UI-test class
(APPCHECK-STAGING-DEBUG). **Authenticated simulator UI tests still don't load
the feed (IOS-SIM-AUTH-FEED) — App Check was ruled out as the cause; deferred
post-launch. Authenticated iOS flows are hand-tested on a real device.**
Non-auth UI tests pass.

**5. Earlier in the window:** FCM-DIAG stripped (build 100); RESET-1 custom
`/auth` page live (unreachable from Firebase's default emails — template
editing is locked for the project, AUTH-05); Option B branded reset via Resend
built, **parked and un-exported** (its secret/param had blocked deploys);
ONB-1 fixed in build 98; SEC-UUID lockfile fix deployed staging + prod; CI
index smoke-probe + staging/prod drift check (`b9d097e`).

## Today (2026-10-23) — MFA, FCM, watchdog, wording, blocking

Chronological, with **LIVE** vs **WAITING** marked.

**1. TOTP MFA sign-in** — the admin account has TOTP enrolled; the clients now
handle the second factor on sign-in. iOS `SignInView` (resolver → TOTP assertion),
web `app.js`, and `admin.html`. **LIVE** (web/admin deployed; iOS in builds 94+).
Verified on device: owner signed out/in with password + TOTP on build 95.

**2. FCM token fix (builds 94→96)** — sign-out calls `deleteToken`; a same-session
sign-in only tried a one-shot `refreshFCMToken()` that fetched nothing before APNs
re-registered, foreground never retried, and the Settings push toggle's
already-authorized branch just wrote the pref. Net: any user signing out/in
silently lost pushes (crisis pages included) until a cold launch. Fix:
`PushNotificationManager.reregisterForPush()` (re-registers APNs + fetch/save),
wired to sign-in, app-foreground-when-signed-in, and the toggle. **LIVE in build
95**, device-verified all 3 paths (see B94-FCM in issues/BUGS.md).

**3. Crisis delivery watchdog + retry fix** — `pageAdminsForCrisis` no-token path
now records to `undeliveredCrisisPages` + relies on email backup instead of
throwing (which had caused a ~103× Eventarc retry storm on a test crisis post).
New `crisisDeliveryWatchdog` (onSchedule every 5 min) flags any crisis page with
no delivery claim after 15 min, with two Cloud Monitoring policies (undelivered +
heartbeat-absence) + a log metric. **LIVE in prod AND staging**, staging tested
end-to-end (alert email confirmed). Scan #2 reuses the existing
(concerningContent, createdAt DESC) index via an explicit orderBy.

**4. Anonymity wording reconciliation** — removed absolute "anonymous for
everyone / is it really anonymous? yes / no one can see who you are / every
account is anonymous" claims (contradicted by the privacy policy's honest
"pseudonymous, not anonymous"), kept true-about-other-users claims, added a
de-anon reminder at onboarding + compose ("posts share one handle, so small
details like places or workplaces can add up"). **LIVE:** website FAQ (Pages),
web app (hosting). **In build 96/97:** iOS copy. App Store description +
promo text finalized in `APP_STORE_METADATA.md` (gitignored) — **owner pastes to
ASC**. Also removed the unsupported "you can change it whenever" line (no
handle-change feature exists — see FEAT-HANDLE-CHANGE). `/p/` share pages verified
to carry no handle/author id/author-post links. Full decision log in AUDIT_REPORT.md.

**5. Blocking hardening (ex-on-a-breakup-app threat)** — before today, a blocked
user could still read the blocker's posts (posts read rule was `isAuth()` only).
  - **Option 1 (client-side filter):** BlockedUsersCache gains a "who blocked me"
    set (collectionGroup on `/blocked` where `blockedUid==me`) + `isHiddenAuthor()`
    used at all 12 content-filter sites; web mirrors it (`blockedBy` set).
    **LIVE on web (hosting); iOS in build 97.** Filters by authorId so it survives
    a handle change. Needed TWO server-side fixes (found via the first retest):
    (a) a single-field COLLECTION_GROUP index on `blocked.blockedUid` (prod only
    had the composite) — **deployed prod+staging**; (b) a collectionGroup READ
    rule `match /{path=**}/blocked/{blockedId}` (the nested rule doesn't cover
    collection-group queries) — **deployed prod+staging**. Both also fix the
    account-deletion cascade's silently-failing block-cleanup query. The web
    `blockedBy` error callback now `console.warn`s instead of swallowing.
  - **✅ PROD RULES PROVENANCE (updated 2026-10-25):** blocking verified on web
    + iOS build 97, so Option 2 was deployed. Prod firestore.rules now =
    **`main@f09ae87`, tag `rules-prod-2026-10-25-opt2`** (collectionGroup blocked
    read rule **+ Option 2 posts-get block check**). This matches `main@HEAD`.
    (Prior pin `rules-prod-2026-10-24 @ 5fac94c` was the interim collectionGroup-only
    state, now superseded.)
  - **Option 2 (rules):** posts `read` split into `list` (unchanged — feed
    unaffected) + `get` (+`notBlockedBy(authorId)`), so a blocked user can't
    directly open/deep-link the blocker's post. Suite 289 passing. **DEPLOYED
    PROD 2026-10-25** (feed-list rule byte-identical to before; no server-side
    permission errors post-deploy).
  - **Option 3 (handle-change suggestion):** DEFERRED post-launch — there is no
    handle-change feature yet; building it (unique registry swap + optional
    past-content backfill + the block suggestion) is logged as FEAT-HANDLE-CHANGE
    in issues/BUGS.md.
  - Confirmed: the blocked party could already read their own `/blocked` docs
    (rules:967) so nothing new is revealed; blocker's replies on others' posts are
    hidden too.

**Build pipeline note:** ASC API Issuer `49354180-…`; upload uses the **Admin**
key `BF6U2B58AQ` (the Developer key `4N8UF433DF` is rejected for cloud signing but
fine for the group-assign API). `scripts/asc_add_build_to_group.js <N>` polls +
assigns to the Internal (me) group.

## What shipped this cycle (2026-10-22 → 23)

Launch-audit Phase 2, all live in prod unless noted:
- **Repo made public by decision** — personal identifiers scrubbed from all
  tracked files (fictional test names), commit identity switched to the
  GitHub noreply address, key-material gitignores added, the former hardcoded
  fallback admin uid moved to a deploy-time param.
- **Auth** (both projects): 8-char password policy ENFORCED; prod `localhost`
  removed from authorized domains; **TOTP MFA enabled + enrolled** on the
  admin account; admin dashboard (`docs/admin.html`) handles the TOTP second
  factor on sign-in, with 30-min idle sign-out + session-only persistence.
- **API keys** tightened from the generic 27-API template to real-usage
  allowlists — browser key (5 referrers + 5 APIs) and iOS key (bundle id + 8
  APIs); both verified, no breakage.
- **Functions:** log lines no longer pair uid with content/post ids;
  crisis-alert email tag now emitted before the empty-recipient return (so a
  config regression still alerts). Deployed prod.
- **Hosting:** reCAPTCHA Enterprise attribution notice on web + admin sign-in.
- **CI/supply chain:** branch protection on `main` (required checks, no force
  push); third-party Actions SHA-pinned and bumped to Node-24 releases;
  Security Watch sitemap check made cold-start tolerant.
- **Backups:** daily (7d) + weekly (56d) schedules confirmed; PITR +
  delete-protection on; a restore drill was performed into a throwaway
  same-project database (cross-project restore is NOT supported) and verified.
- **Docs:** `SECURITY.md` §9 incident log backfilled; `incidents/
  2026-07-credentials.md` post-mortem; `runbooks/data-recovery.md` (restore +
  rollback + the post-restore re-deletion obligation).
- **Prompts SEO section** live (395 pages + tag pages + sitemap) at
  www.toskaapp.com/prompts/.

## Key decisions

- **Sharing is OPT-IN (2026-10-23).** New accounts start with
  `allowSharing: false` on web (live) and iOS (committed, rides build 94).
  Existing accounts unchanged — only creation-time writes changed; all read
  fallbacks (`?? true`) left intact. Privacy policy + Terms updated to match
  ("off for new accounts; change it in the iPhone app Settings → Privacy").
  Full web consent UI + iOS sign-up checkbox are build-94 work (see below).
  Only admin-curated (`webFeatured`) + `isShareable` posts ever reach the
  website/Google; all current `webFeatured` posts are owner demo seeds.
- **HSTS:** not added — Firebase Hosting already injects HSTS on
  app.toskaapp.com; `includeSubDomains` adds nothing on a single-label host.
- **Repo stays public**, with the scrub above, rather than private.
- **minInstances on the sitemap function: dropped** — the only 500s were
  cold-start blips hitting crawlers/health-checks, no real users; the health
  check was made retry-tolerant instead.

## ✅ B94-MFA verified on device (2026-10-23) — sign-out restriction LIFTED

Build 94 is on the owner's device and **TOTP sign-in works**: the owner signed
out and back in with password + 6-digit TOTP code successfully. iOS now handles
the second factor. The earlier "do NOT sign out of the iOS app / don't change
the admin password" constraint is **lifted** — the account is no longer at risk
of lockout. (admin.html + web app.js also handle MFA.)

✅ **B94-FCM fixed + device-verified on build 95 (2026-10-23).** The earlier
token-loss after sign-out/sign-in is resolved: `PushNotificationManager.reregisterForPush()`
now restores the FCM token on sign-in, app-foreground, and push-toggle re-enable.
All three paths verified on-device to write a fresh token to `private/data`;
crisis delivery to the owner device confirmed restored. Build 95 (v1.3) is on
TestFlight in the Internal (me) group.

## Anonymity wording reconciliation (2026-10-23)

Reconciled the "anonymous" promises against the privacy policy's honest
"pseudonymous, not anonymous" stance. User-facing copy avoids "pseudonymous"
(legal keeps it), keeps the warm lowercase voice, drops absolute claims
("anonymous for everyone", "really anonymous? yes / no one can see who you are",
"every account is anonymous"), keeps true-about-other-users claims, and adds a
de-anonymization reminder (onboarding + compose): "posts share one handle, so
small details like places or workplaces can add up." Full decision log in
AUDIT_REPORT.md. Ship: website→Pages (live); web app→staging first, prod on
approval; iOS (7 files)→build 96 w/ B94-3 GIF placeholder; App Store copy→owner
pastes from APP_STORE_METADATA.md (gitignored). #7 verified: /p/ share pages
carry no handle/author id/author-post links.

## In progress

- **Build 102 hand test (owner, on device, 2026-10-27).** Everything in the
  "Latest" section above is committed and deployed; the working tree is clean
  at `49e2f89`. Findings from the hand test get logged in `issues/BUGS.md` and
  fixed for a build 103 if needed. Things worth exercising on 102: compose →
  post right after sign-in / account switch (consent A), own-post tint, GIF
  rows (placeholder → crossfade, no row jump), Apple Sign-In (M5), the
  verify-error "back to login" path (M4), onboarding not re-shown on an
  existing account (ONB-1).
- **Open code items (small, post-launch unless the hand test surfaces them):**
  M3 (cancel the 15s sign-in sweep task on disappear), L1 (start
  BlockedUsersCache on the inline sign-in paths), L2 (handle-registry orphan
  on signup rollback), L3 (feed filter should fail closed on missing
  `moderationStatus`), L5 (`unrepostReply` doesn't broadcast `.postDeleted`),
  M2 (vestigial DM-cleanup step), TEST-ONBTARGET (Swift unit-test target).
- **Deferred features:** FEAT-HANDLE-CHANGE (+ Option 3 block suggestion),
  B94-APPLE post-signup sharing prompt, RESET-EMAIL Option B (Resend),
  TECH-DEBT-RULES-CEILING refactor, IOS-SIM-AUTH-FEED.

## Open items (owner / manual)

- App Store: paste description + promo text from `APP_STORE_METADATA.md`
  (gitignored) into ASC; pick the launch build (102 if the hand test is clean).
- Browser checklist A (incognito, prod): sign-in, 8-char signup gate +
  word-pair handle on a fresh signup, fresh-signup `allowSharing:false`,
  sharing toggle on the web profile, password-reset email, admin MFA sign-in,
  reports tab. (Staging verified; the API-key referrer lock correctly blocks
  headless prod testing, so these are owner-only.)
- Normal push receipt (like/reply) on device.
- Glance at Crashlytics + Performance dashboards (visual confirmation only).
- Firebase Support ticket for the locked email templates (AUTH-05) if branded
  reset emails matter before Option B.
- Manual account hardening from the audit: 2FA + offline recovery codes
  across Google / GitHub / Apple / both Squarespace accounts; domain
  transfer-lock + auto-renew; the off-repo operations document.

## Gotchas worth knowing

- **iOS builds:** archive Release with the Admin ASC key; bump
  `CURRENT_PROJECT_VERSION` before each upload; the group-assign script must
  run after Apple finishes processing (retry loop). `.env.<project>` files
  under `functions/` supply the `FALLBACK_ADMIN_UID` param at deploy time.
- **`/*.md` is gitignored** (post-leak quarantine) — root-level `.md` files
  won't commit; put docs in a subdirectory (`docs/`, `issues/`, `runbooks/`,
  `incidents/`).
- **Prod deploys are owner-approved and explicit-`--project`;** `.firebaserc`
  default is `toskastaging`, so a bare `firebase deploy` hits staging.
- **Firebase JS modular MFA:** `multiFactor(user).getSession()` is a METHOD,
  not a `.session` property (cost a debugging round during TOTP enrollment).
