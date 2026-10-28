# Multi-user functional audit — STAGING (toskastaging) — 2026-10-27

> **Status 2026-10-28:** A1 (held/crisis content enumerable through unconstrained SDK queries) is **FIXED
> and deployed to prod** — rules `main` → tag `rules-prod-2026-10-28-a1`, byte-identical to the released
> ruleset; 43 new emulator tests (`firestore-tests/held-content-enumeration.test.js`), 73/74 staging checks,
> and a 24-shape in-browser prod check all pass. Clients that fetched posts by id without a status filter
> (web liked/saved tabs, iOS liked/saved tabs, iOS engaged tags, iOS author repost sweep) now read per
> document / pin live; web is live, iOS rides build 103. Remaining findings are being worked in the order
> set by the owner (A2 next). This report was held out of the public repo until A1 shipped.

Independent, observation-only audit of how toska behaves when several people interact. No app code was
changed. Everything below was observed on staging with real client-SDK sessions (rules + triggers ran for
real), a headless Chrome pass over the staging web app, and Cloud Logging / Admin-SDK inspection. iOS
behaviour comes from reading the build-102 code paths and testing their exact write shapes against the
deployed staging rules (the simulator cannot sign in — see IOS-SIM-AUTH-FEED).

Sources of intended behaviour: docs/privacy.html (P), docs/terms.html (T), docs/support.html (S),
docs/index.html (I), APP_STORE_METADATA.md (M), in-app copy, firestore.rules, functions/index.js,
issues/BUGS.md. Each finding says whether it **matches**, **contradicts**, or is **undefined** by them.

Harness and raw log: scratchpad `audit/` (lib.mjs + 01…14 phase scripts, results/log.jsonl, screenshots).
Audit run id `mua_mvr1058n`.

---

## 1. Coverage summary

**Accounts used.** U1 (sharing on, all notifications on), U2 (sharing off, all on), U3 (likes/follows
notifications off), U4 (restricted by the system after 12 bad posts, lifted by admin, re-restricted by
admin, finally banned), U5 (self-deleted near the end), U6 (bystander: followed U1/U2/U4/U5, observed),
plus throwaway accounts for sign-up edge cases, a real-UI web sign-up, 32 synthetic moderation authors,
and 60 synthetic scale authors. Admin actions were performed with the Admin SDK using the exact document
writes docs/admin.html makes, stamped with the staging admin uid.

**Tested.**
- Sign-up (email, real web shape through rules, incl. `blockBannedSignups`), 7-char password, duplicate
  email, handle registry, handle screening, 18+ attestation path, prefs, sharing flag, policy stamps.
- Every post type (plain, tagged, GIF, GIF-only, whisper, midnight, letter, prompt response), 33
  moderation-category posts and 11 category replies (one author each so the rate limiter could not mask
  results), edits adding PII/crisis then removing them, deletes, reposts of every content state, reply
  reposts (iOS shape), nested replies, 1-char reply, rapid posting (7 in 2 s) and rapid replying (12 in 5 s).
- Action × relationship matrix: like, save, repost, reply, report post, report user, follow, reflect,
  read profile, get post, list posts — for none / actor follows / target follows / mutual / actor blocked
  target / target blocked actor / both blocked / after unblock / actor restricted / target restricted /
  target deleted / target banned+re-signed-up (alias). Observers: actor, target inbox, U6 feeds,
  logged-out public surfaces, admin collections.
- Privacy read matrix (U6 and logged-out vs 20 document paths and 25 query shapes) and 60 tampered
  writes (server-owned fields, forged identities, counters, flags, cross-user writes, schema abuse, XSS
  text, self-block, backdating, 30 h whisper, non-Giphy GIF, bad tag, handle squatting…).
- Admin: approve (publish, incl. bulk), restrict / unrestrict (system and admin), feature for the public
  site, mark crisis reviewed (code), delete, dismiss/resolve reports (code), emulated ban + re-sign-up.
- Public surfaces: /p/, /og/, /sitemap.xml, publicFeed for every content/consent/featured state,
  consent revocation and re-grant, deletion propagation, headers, GPC/DNT presence.
- Counters after every scenario; 60 simultaneous likes / 43 replies / 23 reposts on one post; 10× rapid
  like toggles; follower counters through block/unfollow/deletion.
- Jobs actually running: cleanupExpiredPosts (3-minute whisper swept 2 min after expiry),
  crisisDeliveryWatchdog (log lines every 5 min), reconcilePostVisibility, resume* queues, SLA/spike
  watchers (Cloud Logging); detectCounterDrift / pruneOldNotifications only by last-run evidence.
- Web UI in headless Chrome as logged-out, fresh sign-up, U6, U3, U5, U4 (incl. restricted compose and
  reply), two simultaneous sessions of U1, rendered share page.
- Account deletion (U5) footprint before/after with ~20 s cascade timing; ban emulation for U4 with the
  real staging pepper and re-sign-up with same / upper-case / plus-alias email.

**Skipped or only reasoned from code (and why).**
- App-Check-gated callables (`confirmAdult`, `giphyProxy`, `adminDeleteAccount`, `reconcileMyCounts`)
  cannot be invoked from Node or from the staging web app (no App Check provider on staging). The ban was
  emulated step-for-step with the real pepper (no plaintext ever logged). Age attestation was set with
  the Admin SDK for the six main users; the gate itself was then tested on a fresh un-attested account.
- Push delivery (no device). Preference gating was verified from the function code: it gates the FCM
  send only; inbox documents are always written.
- Apple/Google sign-in, TOTP sign-in, iOS offline queue, iOS data export, weekly recap, anniversary
  cards: iOS-only client logic, reasoned from code (build 102 and tag v1.3-b93).
- Daily jobs (detectCounterDrift, pruneOldNotifications, cleanupProcessedTriggerEvents) were not forced;
  last-run timestamps and the drift report document were read instead. The 90-day prune and the
  hourly re-restriction expiry were not waited for.
- Midnight expiry in three time zones was set up (posts created with each zone's `expiresAt`) but the
  expiries fall tomorrow; the whisper path proves the sweep mechanism.
- "Target banned and re-signed up" was created (plus-alias account) but not driven through the full
  action matrix.
- Admin dashboards (docs/admin.html targets prod) were not driven; their writes were replicated.
- Relationship × content-state combinations not individually run: reacting to an *expired* post (rules
  ignore expiry, clients filter — covered by read tests), reporting a deleted post, saving a held post
  (saves are own-tree and succeed for any id — covered by "blocked user can save").

---

## 2. Findings

Severity: HIGH / MED / LOW. Likelihood = how likely a real user meets it (★★★ common … ★ rare).

### 2.1 Contradicts a public promise

**A1 · HIGH · ★★ — Held and crisis-held posts/replies are readable by any signed-in user through the SDK.**
Scenario: U6 (ordinary user) runs `posts where flagged == true`, `where concerningContent == true`,
`where pendingReason == "crisis"`, `where authorId == <U4>` (no status filter), or just
`orderBy createdAt` with no filter; also `posts/{id}/replies` with no status filter and
`replies where pendingReason == "pii"`. Observed: full text, `authorHandle`, `pendingReason`,
`flagReason`, `concerningContent` of other users' `pending_review` posts and replies — including a
pre-existing staging post whose text is "Suicidal". Logged-out: denied. Queries that *do* filter on
`moderationStatus != live` / `in [pending…]` are denied. Cause (code): the posts/replies list rule is
`resource == null || moderationVisible(resource.data)` and `moderationVisible` uses
`.get('moderationStatus','live')`; for a query that does not constrain the field the engine treats it as
possibly absent → default `live` → allowed. The shipped clients always add `moderationStatus == live`, so
the UI does not show them; a tampered client or any script does. **Contradicts P:120** ("rules
structurally prevent moderation and crisis flags from ever being readable by other users") and P:117.
Repro: sign in as any user; `getDocs(query(collection(db,"posts"), where("pendingReason","==","crisis")))`.

**A2 · HIGH · ★★★ — Moderation misses several categories the site says it screens.** One author per case
(so the rate limiter could not interfere). Went **live** as posts: "all women are worthless trash and
deserve nothing"; "all men are subhuman garbage and should be exterminated"; "the sex was the only good
part, explicit details about his dick"; "i am going to hurt him so badly when i see him next";
"i am 15 and my first boyfriend just broke up with me before homecoming"; "being dumped in 9th grade…";
"born in 2012 and already heartbroken". Went live as replies: both hate lines, the sexual line, the
underage line, the spam line (spam is not checked on replies by design). U6's web feed showed the hate and
underage posts (UI confirmed). Caught correctly: full names, phones (digits and spelled out), e-mails
(plain and spelled), street address, workplace, `ig: @handle`, links (as spam), dox/harassment, "i will
kill him", explicit/soft/Spanish/leet crisis, "sophomore… senior" underage, one quoted slur
("retard" → held as hate). **Contradicts I:323-327** ("layered content moderation — for harassment,
slurs, sexual content…"), **T:96/T:84** (identifying content, underage removal) as far as these phrasings
go; detection is pattern-based, so this is a recall gap, not a pipeline failure. Also: a benign seeded
line "the playlist still feels like theirs" was **held as crisis** (false positive).

**A3 · MED · ★★ — Turning sharing off does not end public exposure immediately.** U1 (featured post)
set `allowSharing:false`: stored `isShareable` flipped within 8 s (good), but `/p/{id}` and `/og/` still
returned 200, the sitemap still listed it and publicFeed still contained the text at the next fetch.
Headers: `/p/` `max-age=300, s-maxage=600`; sitemap `max-age=3600, s-maxage=3600`; publicFeed
`max-age=600` plus a 10-minute in-instance memo. **P:128** says turning sharing off "ends both,
including for existing posts" and gives the ~10-minute cache caveat only for *deletion*; the sitemap can
lag up to **1 hour**. Deletion propagation: a deleted featured post still served 200 after 60 s (cache),
consistent with the stated ≤10 min but not verified at the 10-minute mark.

**A4 · MED · ★★ — Account deletion leaves identifying residue.** U5 self-deleted. Cascade removed posts,
replies, likes (and their counter effects), saves, follows (and counters), blocks naming U5,
notifications U5 caused, pending reports U5 filed, drafts, private data, handle row, auth user — in
~20 s. Left behind: **8 `adminAuditLog` `post.delete` rows, one per post, each with `authorId` and
`targetHandle`** (written by `auditPostDeletion` for *every* post delete, including author self-deletes
and whisper/midnight expiry — the expired 3-minute whisper also produced one); **other users'
`likedReplies` / `savedReplies` snapshots** of U5's reply text, handle and uid (U6's survived); reports
filed against U5 (3, disclosed in P:153); the `undeliveredCrisisPages` record for a deleted user's post.
**Contradicts S:90 / I:363-364** ("permanently removes your profile, posts, replies, and personal data"
with no caveat) and the spirit of T:123 ("stops appearing… permanently deleted"); **P:153** discloses the
moderation-log retention but frames it as a moderation record for removed posts, which an expired
whisper or a self-deleted post is not.

**A5 · MED · ★★ — Another user's profile doc exposes settings and status.** Any signed-in user reading
`users/{uid}` of a non-blocking user gets: `allowSharing` (sharing setting), `confirmedAdult` +
`confirmedAdultAt`, `acceptedPolicyVersion/At`, `hasCompletedOnboarding`, `createdAt`,
`followerCount`/`followingCount` regardless of `showFollowerCount`, and for restricted users
`restricted`, `restrictedAt`, `restrictedUntil` (observed `restricted:true` on U4 as U3). E-mail is not
exposed (good). **P:117** promises rules prevent reading "private data"; the policy never lists these
fields as public, and I:298 calls follower counts "private by default" while the count is readable via
SDK whenever the doc is. Restriction status and the sharing setting are the sensitive ones.

**A6 · LOW · ★★ — Blocking wording vs behaviour.** After U1 blocked U3: U3 cannot get U1's post, profile,
like, reply, repost or follow (good, server-enforced); U3 **can still list U1's posts** (`where
authorId == U1` and the feed list have no block check — matches T:109's "one honest limit", contradicts
S:84 "never see their content again"), **can still save** U1's post (own tree) and **report** U1, and
can **see who blocked them** via the collection-group query (T:109 says the blocked person "is not
notified"; the data is readable, UI hides it — a known design choice). The blocker (U1) can still `get`
the blocked user's post and profile via SDK (the block rule only checks author-blocked-caller); the web
feed hides it client-side and the deep link shows "this post has disappeared."

**A7 · LOW · ★ — In-app policy text vs defaults.** The iOS policy body (`toskaPolicyBody`) says allow
sharing is "on by default"; every sign-up path writes `allowSharing:false` and the web/ iOS checkboxes
default off. Web sign-up copy says "change this any time on your profile", iOS says Settings → Privacy
(both true per platform).

**A8 · MED · ★★★ (staging) — A fresh staging web sign-up can never post.** Real-UI sign-up succeeded
(handle `still_echo_818`, policy 4, sharing off); console: `confirmAdult attempt 1-4 failed
functions/unauthenticated` (callable is `enforceAppCheck:true`, staging web has no App Check provider);
`confirmedAdult` never set; compose → "something went wrong." Prod has App Check, so this is a staging
configuration gap, but it also shows the unconfirmed-adult UX: a generic error with no explanation (W5).

### 2.2 Privacy or security exposure

- **B1 = A1** (held/crisis content enumerable). **B2 = A5** (status fields).
- **B3 · MED · ★★ — Victim's inbox carries the attacker's text.** The live hate reply ("all men are
  subhuman garbage…") was copied into U1's reply notification `message` (web list shows it quoted). Held
  replies have their preview cleared; misses (A2) do not.
- **B4 · LOW · ★ — Users can write anything into their own `private/data`** (`restricted:false`,
  `confirmedAdult:true`, `isAdmin:true`, `email`). Rules authorise from the main doc, so nothing server-side
  trusts it, but web `isRestricted()` and iOS `ContentView` read private first → a restricted user can hide
  their own "under review" banner (server still denies the write).
- **B5 · LOW · ★ — `config/clientPolicy` is readable logged-out** (kill switches, minBuild, notice).
  `meta/tagCounts` and `meta/breakupStageCounts` are readable by any user (aggregates only; tagCounts still
  carries legacy keys grief/honesty/lonely/rebuilding/small_wins).
- **B6 · LOW · ★ — HTML/script in post text is stored verbatim** (`audit xss <img src=x onerror=alert(1)>`
  went live). Web renders via textContent; iOS via Text; admin.html must keep escaping.
- **B7 · LOW — Ban hash covers e-mail and provider ids only.** Same e-mail (any case) is rejected at
  sign-up (`auth/internal-error` surfaces to the user with no message); `user+alias@` is accepted (P:148
  does not claim otherwise → undefined).

### 2.3 Likely bugs

- **C1 · HIGH · ★★ — iOS "repost a reply" is denied by the rules.** The iOS payload
  (`PostInteractionManager.repostReply`) has no `moderationStatus`; the posts-create rule requires
  `pending_validation`. Tested with the exact shape on staging: **permission-denied**; with the field:
  accepted. On device the optimistic "+1" shows, then rolls back. Reply reposts also 404 on `/p/`.
- **C2 · HIGH · ★★ — Rate limiter holds the whole burst retroactively and relabels reasons.** 8 posts in
  2 s by U1 → all 8 `pending_review / rate_limit / flagged:true`, not just the 6th+ (`rateLimitPosts`
  counts posts in the window at trigger time). Because "first reason wins", bursts also mislabel: U4's
  hate post ended as `rate_limit`, and `pendingReason` for a URL post is `abuse_spam` or `pii` depending on
  which trigger landed first (F12). Nothing in the docs defines this; a user who posts 6 short thoughts in
  5 minutes sees all of them "under review".
- **C3 · HIGH · ★★ — `totalLikes` goes negative through repost mirroring.** U3 reposted U2's post, two
  people liked the original (copy's `likeCount` mirrored to 2), U3 un-reposted → U3 `totalLikes` -6 → -8;
  U2 was at -1 at one point; staging now shows `sadly_fog_164: -8`. `mirrorCountsToCopies` +
  `onPostDeletedAdjustTotalLikes` subtract mirrored likes from the reposter. The profile "felt" stat is
  wrong, and `detectCounterDrift` phase 2 sums copies into the reposter's total.
- **C4 · MED · ★★ — Reposting an admin-approved post re-moderates it and strikes the reposter.** Admin
  approved the full-name post (markers scrubbed, live). U6 reposted → copy `pending_review / pii /
  flagged:true / personal_information` (`onPostCreated` has no `isRepost` guard). Same for a reply repost
  of a live crisis reply → held.
- **C5 · MED · ★★★ — Web: an author cannot open their own held post.** U4's profile lists held posts with
  "under review." but the detail route shows "this post has disappeared." (`postVisible` drops
  `flagged` posts even for the author). A held post deep-linked by *another* user shows "this post isn't
  available."
- **C6 · MED · ★ — Replies can be created on a held, invisible post.** U2/U3/U6 replied to U1's
  `pending_review` post by id (replies-create has no parent-visibility check); only the notification was
  denied. The author then sees replies on a post nobody else can see.
- **C7 · MED · ★★ — Milestone notifications skip under bursts.** 60 likes in 0.6 s produced no
  `milestone_*` doc (10/25/50 thresholds use equality on a live count).
- **C8 · MED · ★ (ops) — Crisis watchdog re-alerts forever.** Cloud Logging shows the same post ids
  (`RJ6Buq…` soft crisis, `zSceIb…`, the mod sweep posts, a `crisisAlertReply_…` id) in
  `crisis_page_undelivered` at 18:57 and 19:02 and every run after: soft-crisis posts are never paged so
  never get a claim, and `undeliveredCrisisPages` records are never retried or claimed. In staging every
  crisis page is "undelivered" (no admin token). Deleting the author's account does not remove the record.
- **C9 · LOW · ★ — Self-block is allowed and reachable.** Rules accept `users/{me}/blocked/{me}`; the iOS
  feed row offers "block {your own handle}" on someone's repost of your post (I7). After self-block the
  client filter hid U3's own posts from U3's feed.
- **C10 · LOW · ★★ — Second reply / re-follow by the same person never notifies.** Deterministic ids
  (`reply_{post}_{uid}`, `follow_{uid}`) exist → create denied for non-owners; observed `follow: OK
  notif:permission-denied` on re-follow. Code-level for the reply case.
- **C11 · LOW · ★ — Link reply labelled `pii` in one run and `abuse_link` in another** (trigger race).
- **C12 · LOW · ★ — 1-character replies accepted by rules** ("k" went live); both UIs require 2.
- **C13 · LOW · ★ — Explicit-crisis edit pages admins again and `bulk approve` published it.** Editing a
  live post to add explicit crisis text created a new undelivered page; the admin "approve selected"
  path then published the crisis text as-is (an admin decision, but bulk approve shows no text).
- **C14 · LOW (code) — System auto-restriction never clears `restricted:true`** after `restrictedUntil`
  (F6); not waited for (48 h).

### 2.4 Counter drift

- **D1** `totalLikes` negative (C3) — does not self-correct; the daily job would write the inflated sum.
- **D2** `meta/tagCounts.longing` 91 vs 90 live posts: held posts are counted (+1 on create regardless of
  status) and Explore shows the stored number. Minor, permanent while a post is held.
- **D3** Everything else was exact: `likeCount`/`replyCount`/`repostCount` matched the documents after
  every scenario and settled 7–13 s after 60/43/23 simultaneous operations; 10 rapid like toggles ended
  consistent in 0.2 s; follower/following counters matched through block cleanup, unfollow and deletion;
  deletion decremented `likeCount` 2→1 and `replyCount` 10→0 correctly.
- **D4** `detectCounterDrift` last ran 2026-10-27 00:38 UTC and corrected 1 drift; queues
  (`userDeletionCleanupQueue`, `postDeletionQueue`, repost/subtree queues, `pendingDeletions`) were empty
  after all cascades.

### 2.5 iOS vs web inconsistency

- Web lacks: follow/unfollow (yet shows a "following" tab), report user, block from profile, reply
  like/save/repost, notification preferences, analytics opt-out, data export, account deletion, password
  or e-mail change, explore/tags, drafts list, onboarding (`hasCompletedOnboarding:false` forever).
- Block: web = block doc + best-effort unfollow + navigate home; iOS feed row = block doc only with a
  confirmation; iOS post-detail and other-profile = no confirmation, plus notification/follow cleanup.
- Report: web always shows the reason sheet; iOS post-detail and profile file a one-tap "other".
- Restricted user: web compose shows "your account is under review…"; web reply shows "something went
  wrong." (no client gate); iOS reply silently returns.
- Own held post: web detail "disappeared" (C5); iOS row not openable (banner only).
- Self-felt: web disables the button on own posts; iOS allows it; rules allow it.
- GIF reply: web impossible (needs 2 chars of text); iOS picker unreachable (dead code).
- Ephemeral "whisper · fades in Nm" chip is web-only; own-post tint both.
- `POLICY_VERSION` 4 on web and `< 4` gate on iOS agree (the web comment saying iOS = 3 is stale).

### 2.6 Undefined behaviour needing a product decision

1. **Restricted users** can still like, save, follow, block, report, draft, delete their own posts and
   change sharing (observed); repost and reply are denied. T:109 says "ability to post".
2. **Blocked users** can save and report the blocker's posts and can list them; they can read who blocked
   them (T:109 only promises "not notified").
3. **Notification preferences** gate push only; the in-app list still shows every type (code).
4. **Burst posting**: should the first five of a six-post burst be held? (C2)
5. **18+ gate** covers posting and replying only; likes, saves, follows, reports work before
   `confirmedAdult` (observed on a fresh account).
6. **Ban coverage** excludes plus-aliases and new e-mails (B7).
7. **Local midnight**: `expiresAt` is computed on the device; a Tokyo user's midnight post lives 8 h longer
   than a Los Angeles user's and the stored instant reveals the device's UTC offset (P:113 "we don't
   collect time zones" vs T:123 "your local midnight" — C8 in the policy conflicts).
8. **Share pages are not "hand-picked"**: `/p/` renders any live, shareable, consenting post (200 for an
   unfeatured post); `webFeatured` only controls `index,follow` vs `noindex` and the sitemap/publicFeed.
   P:127/T:116 describe hand-picking.
9. **Replies on held posts** (C6) and **1-char replies via SDK** (C12).
10. **Reports and audit rows survive deletion** (P:153 discloses; S/I do not).
11. **Crisis replies stay live** (queued for review, visible in the thread) — by design in code; not in docs.
12. **Second reply never notifies** (C10) — by design or bug.

### 2.7 Working as documented (verified on staging)

- E-mail never written to Firestore (P:100); `private/data`, liked/saved/blocked/following/followers/
  notifications/drafts/presence are owner-only; reports admin-only; handles not listable; likers not
  enumerable; admin collections, `bannedIdentities`, queues, rate-limit buckets denied; logged-out reads
  nothing but `config`.
- 60 tampered writes denied as designed: own counters, `confirmedAdult*` (fresh account), `restricted*`,
  handle change, `isAdmin`, `admins/`, others' posts/replies/likes/follows/blocks/private/notifications,
  forged `authorId`/`authorHandle`/`fromUserId`, notifications without the backing event, `moderationStatus:
  live` on create, `webFeatured`, client `createdAt`, 30-h whisper, non-Giphy GIF, bad tag, extra fields,
  altered-text repost, non-deterministic repost id, forced-shareable repost of a non-consenting author,
  handle squatting, others' `pendingDeletions`, `config`/`meta` writes, follow-self, deleting presence.
  Server re-stamps: forced `isShareable:true` by a sharing-off author → false; forged `parentPostText/
  Handle` on a reply → re-pinned; garbage `promptDate` → stripped; >2000 chars → deleted.
- Blocking is server-enforced in both directions for like/reply/repost/follow/profile/get; follow edges
  are removed by `onBlockCreatedCleanupFollows` within seconds with correct counters; unblock restores
  everything; a blocked actor's pre-block likes/replies/notifications remain (undefined but consistent).
- Deletion cascade complete in ~20 s (users doc deleted 15 s after the request), auth user gone,
  follower counters corrected, deleted user's profile denied to others; cancel path (`cancelled:true`
  before Auth delete) leaves the account intact.
- Ban: same e-mail rejected at sign-up, case-insensitive.
- Public surfaces: no handle/uid/e-mail in `/p/`, `/og/`, publicFeed (`text, tag, felt, ageHours`);
  non-consenting author, letter, whisper, midnight, GIF-only, held, tampered-shareable → 404; repost ids
  → 404/redirect; sitemap excludes non-consenting and letters; `noindex` unless featured; CSP
  `default-src 'none'`, `X-Frame-Options: DENY`, HSTS.
- Expiry: 3-minute whisper swept by the 10-minute job 2 min after expiry; whisper chip and disabled repost
  on web; `isShareable:false` on letters/whispers/midnights and not re-granted when sharing is turned on.
- Admin approve publishes and scrubs every marker; audit rows record before/after; unrestrict clears the
  main doc, private mirror and `restrictedUsers` row; admin restrict mirrors correctly.
- Race: reply and like issued at the instant of deletion were denied; no orphan subdocuments.
- Two web sessions of one account are independent (sign-out in one keeps the other), state syncs on
  reload.
- Edits fan out to repost copies (text updated).
- Counters under concurrency (D3); feed first page 144–210 ms, most-felt 84 ms, explore tag 78 ms with
  ~500 live posts.

---

## 3. Ranked by likelihood a real user meets it

1. A2 moderation misses (hate/sexual/threat/underage live) — any reader of the feed.
2. C5 author cannot open own held post on web — anyone whose post is held.
3. C2 burst posting holds everything, mislabels reasons — anyone posting several thoughts quickly.
4. A5 settings/status readable from profile doc — any tampered client; needs intent.
5. C3 negative totalLikes — anyone who reposts a post that then gets liked, then un-reposts.
6. C1 iOS reply repost denied — anyone tapping repost on a reply.
7. B3 attacker text in victim's notification preview — target of a missed hate reply.
8. A3 sharing revocation lag (sitemap 1 h) — anyone revoking after being featured.
9. C4 repost of approved post re-held + strike — reposters of approved borderline posts.
10. A4 deletion residue (audit rows, reply snapshots) — everyone who deletes, invisible to them.
11. C7 missed milestones — popular posts.
12. A1 held/crisis enumeration — requires a script; highest *impact* if used.
13. A6 blocking edge cases; C6 replies on held posts; C9 self-block; C10/C12/C11; B4-B7; C8 (ops only).

---

## 4. Code-level notes verified or refuted on staging

Verified: F1/F2 (watchdog re-alerting), F3 (repost re-moderated), F4 (negative totalLikes), F5
(audit row per delete incl. expiry/self-delete), F11 (snapshots survive deletion), F12 (reason race),
F14 (restricted can like/follow/save/block/report/draft), F16 (tag count on held), F19 (config
logged-out), F20 (who-blocked-me readable), F22-24 (public surface gates; unfeatured renders), F25
(crisis reply live), F27 (reports retained), F29 (removing bad text never releases — the post stayed
held), W4/W5/W9, I4 (reply repost shape), I7 chain (self-block), rate-limit retroactivity (new).
Refuted/not reproduced: F26 (hate replies were *not* deleted — the classifier missed them; the sexual
reply in phase 03 was deleted, the one in the sweep was not), "sexual_content" detection on posts.
Not observable in the window: F6, F9, F10, 90-day prune, TTL backstop.

---

## 5. Staging cleanup — confirmed clean

Two passes (`14-cleanup.mjs`, `15-cleanup2.mjs`, `16-last.mjs`). Deleted:

| What | Count |
|---|---|
| Auth users (U1–U6, sign-up edge cases, UI sign-ups, fresh/alias accounts) | 8 |
| User documents (6 audit users + 32 moderation authors + 60 scale authors + 6 misc) recursively, incl. private/data, drafts, liked/saved, blocked, following/followers, notifications, presence | 104 |
| Posts (deep: replies, reply likes, likes, reflections first) | 366 |
| Replies | 69 |
| Like documents | 68 |
| Handle registry rows | 0 left (all removed by the deletion cascade) |
| Reports (filed by / about audit users or audit posts) | 0 left (removed by cascade and admin sweep) |
| `undeliveredCrisisPages` + `processedTriggerEvents` claims for audit posts/replies | 7 + 7 |
| `crisisReplyQueue` entries | 2 |
| `bannedIdentities` test hash (emulated U4 ban) | 1 |
| `adminAuditLog` rows written by audit actions (approve/restrict/delete) | 454 |
| `processedTriggerEvents` claims generated during the audit window | 1,309 |
| Rate-limit buckets, `restrictedUsers`, `pendingDeletions`, queue docs | 0 left |

Baseline (before) → after, every collection and group:

| Collection | Before | After |
|---|---|---|
| users | 41 | 41 |
| posts | 152 | 152 |
| handles | 20 | 20 |
| adminAuditLog | 777 | 777 |
| processedTriggerEvents | 1232 | 1232 |
| crisisReplyQueue | 1 | 1 |
| undeliveredCrisisPages | 0 | 0 |
| rateLimits / system / meta / config / admins / conversations | 5/1/2/1/1/2 | unchanged |
| Auth users | 27 | 27 |
| replies / likes / notifications / blocked | 46/28/18/1 | 46/28/18/1 |
| following / followers / saved / liked / reflections / private / drafts | 13/13/20/17/0/42/32 | unchanged |

Residue scan for the run prefix, audit uids, handles and "audit…" text across posts, users, replies,
reports, crisis records, bans, audit log, auth and all user subcollections: **0 everywhere**.
`meta/tagCounts.longing` and `.unsent` returned to their pre-audit values (12, 1). The tag counter
document still shows a pre-existing `grief: -2`, not caused by this audit. The staging pepper was read
once into a scratch file to emulate the ban hash and that file has been deleted.
