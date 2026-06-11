# Toska — Full-App Independent Review (AUDIT-3)

**Scope:** Whole-product adversarial review — security, correctness, moderation quality, crisis safety, on-device behavior, performance, App Store readiness, code quality. Broader than a security audit. All prior writeups (`AUDIT.md`, `AUDIT-2.md`, `APP_STORE_READINESS.md`) treated as **claims to verify**, not facts.
**Date:** 2026-06-11
**Method:** Verified by *running* — all three test suites + both live-staging E2E rigs executed; App Check state queried against both GCP projects; the iOS app built Release-clean to `/tmp`; the real PII/crisis classifiers executed directly via the `__test` export and `node`; and — for the headline parity finding — the **actual Swift client detector extracted and compiled standalone (`swiftc`) and run against the same corpus as the server**, so divergence is demonstrated by execution, not by reading. Four scoped sub-reviews (rules-seam, Cloud Functions, iOS on-device, App-Store/perf) were run in parallel and **every concrete claim they returned was independently re-verified against source before inclusion here.**

**Headline:** The app is in strong shape and most of the prior remediation re-verifies as genuinely correct. The deployed state matches the brief exactly (App Check prod=ENFORCED both services, staging=UNENFORCED; suites 175/154/74 green; both E2E rigs 36/36 + 43/43; Release builds clean). The **N-17 first-name relaxation is correct and does not leak PII** in the cases its policy intends to hold — verified by running the real detector. The most important *new* finding is a **three-way client/server moderation-detector divergence**: the recent server-side false-positive fixes (M-2, N-13, N-15) were **never mirrored back into the Swift client**, so the client compose-time warning still fires on exactly the grief content those fixes were built to stop — proven by running both detectors on a shared corpus (client holds 11/16 cases the server allows). Next-most-important: a **reply-moderation PII-visibility window** that re-opens the exact timing bug the post path fixed on 2026-05-31, a **GDPR cleanup-resume gap** (`savedReplies` stranded), and **non-English crisis false-positives that page admins** for normal French/Spanish breakup content.

No finding is *submission-blocking* on the App-Store-rules axes. The items below are quality/safety/correctness work plus a short list of genuinely owner/console-only verifications.

---

## 1. Verified deployed/environment state (all confirmed)

| Claim (brief) | Verdict | Evidence |
|---|---|---|
| Suites green: 175 rules + 154 moderation + 74 functions | ✅ | `firestore-tests`: `154 passing` (moderation) + `175 passing` (rules incl. hostile-user.test.js); `functions-tests`: `74 passing`. (Note: both emulator suites collide on ports if run concurrently — run them serially.) |
| Live E2E: full-e2e 36 + e2e-round2 43 | ✅ | Ran both against staging with the staging web config from `GoogleService-Info-Staging.plist`: `36/36 passed, 0 failed` and `43/43 passed, 0 failed`. |
| App Check: prod Firestore+Auth ENFORCED; staging both UNENFORCED | ✅ | `node functions/setAppCheck.js`: prod `toska-4ebf4` firestore=`ENFORCED`, identitytoolkit=`ENFORCED`; staging `toskastaging` both `UNENFORCED`. `storage` not a supported service (no Storage in app). |
| iOS builds Release-clean to a non-iCloud path | ✅ | `xcodebuild -configuration Release -derivedDataPath /tmp/...` → `** BUILD SUCCEEDED **`. 2 source warnings only (see C-4, C-9). |
| ADC + firebase auth live | ✅ | ADC OK (`salte@saltedevelopments.com`); `firebase login:list` logged in. |

---

## 2. New findings

Format: **ID · Severity · Layers** — summary, repro, fix. Severity = Med/Low relative to a pre-launch anonymity/safety app.

### T-1 · **Medium** · client ↔ server (moderation parity / UX) — Three server-side false-positive fixes were never mirrored to the Swift detector; the client warns on content the server allows

The PII/name detector lives in **both** `functions/moderation.js` (server hold decision, via `containsNameOrIdentifyingInfo` → `computePostFlagReason`) and `toska/FeedView.swift` (`containsNameOrIdentifyingInfo`, the compose-time warning). They are hand-synced and there is **no test pinning them**. Three recent server-only FP-reduction fixes drifted:

1. **M-2 `COMMON_TITLE_WORDS` guard** (`moderation.js:167-168`) — absent from the Swift `looksLikeFullName` equivalent (`FeedView.swift:2240-2248`). So "Pearl Jam", "Central Park", "Last Night", "Empty Promises", "Broken Heart" (two capitalized common words — *extremely* common in breakup posts: song/band/place names, set phrases) trip the client but not the server.
2. **N-13 / M-2 number-list pre-strip** (`moderation.js:566-568`) — absent from the Swift phone heuristic (`FeedView.swift:2256-2275`). So "we dated in 2019 2020 2021 2022 2023" (and any timeline/number list) collapses to a 20-digit run on the client and trips the ≥10-digit rule; the server strips it.
3. **N-13 / N-15 `identifyingPatterns` trims** — the Swift list (`FeedView.swift:2114-2132`) still contains `"works at"`, `"goes to"`, `"lives in"`, `"lives on"`, `"apartment"`, `"apt "`, `"suite "`; the server removed them (`moderation.js:179-199`). So "lives in my head", "adapt to change" (`"apt "` substring), "the suite life", "my apartment is empty now", "he goes to my gym" trip the client but not the server.

**Repro (executed — both real detectors, same corpus):** I ran the actual `moderation.js` detector under `node` and the **actual Swift `containsNameOrIdentifyingInfo` extracted and compiled with `swiftc -enable-bare-slash-regex`**. Result — the client holds 11/16 cases the server allows:

```
                                    server   client
he lives in my head rent free        allow    HOLD   ← diverge
adapt to change is hard              allow    HOLD   ← diverge
the suite life is over               allow    HOLD   ← diverge
my apartment is empty now            allow    HOLD   ← diverge
he goes to my gym still              allow    HOLD   ← diverge
we dated in 2019 2020 2021 2022 2023 allow    HOLD   ← diverge
I still hear Pearl Jam               allow    HOLD   ← diverge
we met at Central Park               allow    HOLD   ← diverge
that Last Night together             allow    HOLD   ← diverge
those Empty Promises                 allow    HOLD   ← diverge
my Broken Heart                      allow    HOLD   ← diverge
```

**Impact:** the client warning is a **soft** warning with a "post anyway" button (`ComposeView.swift:651`), so this is UX noise, **not content loss**. But it re-introduces, at the client layer, the *exact* dominant false-positive class (`APP_STORE_READINESS.md §5`: "bare first-name mentions… 20–40% of real breakup posts" + place/song/phrase context) that the server M-2/N-13/N-15 work was explicitly built to eliminate. Every user who sees "this may contain identifying information" on "I still hear Pearl Jam" or "my Broken Heart" is being told their grief post is doxxing someone when the server disagrees. On a heartbreak app this is a real friction/abandonment cost on the modal post.
**Fix:** port the three server changes into `FeedView.swift` (the title-words guard, the number-list pre-strip, and the keyword trims), and **add an automated parity test** that runs a shared corpus through both detectors (the brief explicitly recommends this; the proof harness in this audit is a starting point — extract the Swift function + helpers and diff against `moderation.js` on CI).

### T-2 · **Medium** · functions + rules (security / privacy) — Held PII replies have a re-opened visibility window; the reply path jitters *before* the hold (the post bug, un-fixed for replies)

Two compounding issues on the M-1 reply-hold surface — the one place that exists specifically to hide real PII:

1. **Replies cannot start hidden.** The reply *create* rule's `hasOnly` (`firestore.rules:807-810`) does **not** include `moderationStatus`, so every reply is created field-less. The reply *read* rule defaults a missing status to `'live'` (`firestore.rules:785`: `resource.data.get('moderationStatus','live') == 'live'`). So a freshly-created reply is directly `get()`-readable by any caller for whom the post is visible, the instant it's written — before any trigger runs. (Posts do **not** have this problem: the post create rule forces `pending_validation`, `firestore.rules:610-611`.)
2. **`validateReply` jitters 1.5–3s *before* applying the hold** (`index.js:2329-2330`: `await moderationDeleteJitter(); await setReplyPendingReview(...)`). This is the **exact ordering the post path was deliberately changed away from on 2026-05-31** (`index.js:2127-2136`: "flip status FIRST, then jitter… the 1.5-3s jitter ran before the flip, widening the PII visibility window"). The reply-path comment (`index.js:2321-2322`) even claims it's "same as validatePost" — it is the **opposite**.

**Net:** a PII-bearing reply (the M-1 hold target) is third-party-readable — to anyone who can see the post and knows/guesses the `replyId` — for the full jitter window (1.5–3s) **plus** trigger latency. The legitimate thread query filters `== 'live'` and won't surface it, but a hostile client doing a direct doc `get` in the window reads the PII text before it's hidden. This exposes exactly what the hold protects.
**Fix:** (a) on the reply hold path, set `pending_review` **first, then** jitter — mirror `validatePost` and its documented rationale (the jitter's timing-oracle purpose is preserved by jittering the no-op log, as the post path does). (b) Optionally close the create-time window too by allowing replies to be created `moderationStatus:'pending_validation'` (add to the create `hasOnly` + a create constraint mirroring the post rule) and have the client write it. Add a hostile-user test for the direct-read window.

### T-3 · **Medium** · functions (GDPR / cleanup correctness) — `savedReplies` deletion-resume continuation is silently dropped; remainder stranded forever

The account-deletion cascade's generic subcollection loop includes `savedReplies` and, on cap-hit/error, queues a resume token `sub_savedReplies` (`index.js:896, 901`). But the resume dispatcher's allow-list omits it (`index.js:3703-3705`: `["saved","liked","notifications","blocked","presence","private","drafts"]`). So `resumeUserCleanup` strips `sub_` → `savedReplies`, fails `ALLOWED_SUB_RESUME.has()`, logs "Unknown sub-cleanup target … dropping queue entry," and **deletes the queue doc** (`index.js:3713-3716`) — permanently stranding any `savedReplies` past the `deleteCollection` cap.

**Repro:** cross-check the two literals — `savedReplies` is in the `subs` write loop but not in `ALLOWED_SUB_RESUME`; conversely `liked` is in `ALLOWED_SUB_RESUME` but never queued (it's owned by `cleanupLikesForUid`), i.e. a dead entry. For a user who saved >5,000 replies (the `deleteCollection` cap), their `savedReplies` survive account deletion = **GDPR Art. 17 residue + storage leak** — the precise failure this resume machinery exists to prevent.
**Fix:** add `"savedReplies"` to `ALLOWED_SUB_RESUME` (`index.js:3704`). (Optionally drop the dead `"liked"` entry.)

### T-4 · **Medium** · functions + client (crisis safety) — Non-English explicit-crisis phrases produce admin-paging false positives the English list carefully avoids

The non-English explicit-crisis additions (Spanish/Portuguese/French, `index.js:2555-2565`, mirrored client-side at `FeedView.swift:1806-1813` — **parity verified, both layers have them**) *do* fire correctly on real crisis input. But several are substring-matched too loosely and trip the **explicit** tier, which both **holds the post** and **pages admins** (`onPostCreated… isPostExplicitCrisis`, `index.js:2922`). The English list was curated to avoid exactly these; the non-English starter set was not.

**Repro (executed — `__test.isPostExplicitCrisis`):**
```
EXPLICIT  tu vas me faire du mal            FR: "YOU will hurt me" (about an ex) — relational, not self-harm
EXPLICIT  j'ai envie de mourir de honte     FR: "die of embarrassment" — hyperbole
EXPLICIT  voy a matarme a trabajar          ES: "work myself to death" — hyperbole
EXPLICIT  esta mejor muerto en la pelicula  ES: "the character's better off dead in the movie"
--- English equivalents, for contrast: ---
clean     he is going to hurt me
clean     I could just die of embarrassment
```
`"me faire du mal"` matches relational "[someone] will hurt me" (common on a breakup app describing an abusive ex); `"envie de mourir"` matches hyperbolic "die of X"; `"voy a matarme"` matches "matarme a [verb]"; `"mejor muerto/muerta"` matches non-self death talk. **Asymmetric harm:** a French/Spanish/Portuguese user's normal breakup post gets **held out of feed and pages a human admin**; the English-speaking user writing the same thing does not. That both fatigues the crisis alert (the soft/explicit split exists precisely to avoid this) and silently suppresses non-English content.
**Fix (safety-owner + native speaker):** tighten the non-English explicit phrases to require first-person/reflexive framing (`"quiero hacerme daño"` / `"je veux me faire du mal"`, not the bare verb), drop or constrain `"envie de mourir"`, `"mejor muerto/muerta"`, and guard `"matarme"` against `"matarme a <verb>"`. Until reviewed, consider demoting the ambiguous ones to the **soft** tier (held, not paged). The code comment already flags "needs native-speaker review per language" — this verifies that caveat is load-bearing.

### T-5 · **Low–Medium** · client (crisis safety coherence) — Crisis *resources* are device-region-keyed (English-only set) while crisis *detection* now fires in Spanish/French/Portuguese

`CrisisLines.resources` switches on `Locale.current.region` (`ToskaTheme.swift:404-450`) with curated lines only for US/CA/GB/AU/IE/NZ; **ES, MX, FR, BR, PT all fall through to the generic `findahelpline` international directory**, and there are **no Spanish/French/Portuguese-language hotline rows at all**. So now that detection fires on non-English crisis (T-4), a detected Spanish/French/Portuguese user in crisis is shown either English-language hotlines (if their device region happens to be US/GB/etc.) or a generic English directory link — never a native-language local line. The region-fallback fix itself is **correct** (unknown region → `findahelpline`, not a dead `988` — `ToskaTheme.swift:400-403, 443-449` — verified).
**Fix (safety-owner):** add curated lines for the regions matching the languages you now detect (ES, MX, FR, BR, PT, etc.), or key resource selection partly on detected post language, so detection and resources cover the same languages.

### T-6 · **Medium** · client (performance) — Unbounded live-replies snapshot listener; unbounded delete-time reads

`PostDetailView.swift:1147-1150` attaches a snapshot **listener** on `replies where moderationStatus=='live' order by createdAt` with **no `.limit()`** (verified). On a viral post this reads the entire reply set on open and re-runs the O(N) client `recombineReplies` rebuild on every new reply — a read-cost and main-thread cost that scales with engagement. Separately, `deletePost` reads **all** likes (`PostDetailView.swift:1023`) and **all** reposts (`~1051`) unbounded in one shot before deleting, though the replies-cleanup block right above already paginates at `.limit(to:500)`. (The *main feed* is well-built: one-shot cursor pagination, `.limit(to:60/20)`, no listener on the growing `posts` collection — verified, no issue.)
**Fix:** `.limit(to: 200)` + "load more" on the live-replies listener; mirror the `.limit(to:500)` paginated pattern for the delete-time likes/reposts reads; `ReplyDetailView` should query `parentReplyId` server-side rather than loading all live replies to find one reply's children.

### T-7 · **Medium** · client (on-device privacy) — App-switcher privacy cover does not cover presented sheets/fullScreenCovers (the rawest grief surfaces)

The N-5 privacy cover is attached as an `.overlay` on `ContentView`'s root `Group`, gated `isLoggedIn && scenePhase != .active` (`ContentView.swift:96-106`, opaque, fires on both `.inactive`/`.background` — base layer verified). But ComposeView, PostDetailView, ShareCardView, ReportSheet and pushed profiles are presented as `.fullScreenCover`/`.sheet` from `MainTabView`/`FeedView`, which SwiftUI renders in a layer **above** `ContentView`'s body — so the overlay does **not** paint over them. The open composer (in-progress grief text), an open thread, and the share card (full post text) are exactly what the app-switcher snapshot captures when backgrounded with one of them open — the primary thing N-5 was meant to stop.
**Fix:** install the cover at the scene/window root (e.g. a window-level overlay in `toskaApp.swift`'s `WindowGroup`) so it sits above all presentations, rather than on `ContentView`'s subtree.

### T-8 · **Low** · client (UX) — Restricted user gets no client gate when replying via the reply drill-down

`ReplyDetailView.canPost` checks only "text non-empty" (`ReplyDetailView.swift:305-307`) — unlike `ComposeView` / `PostDetailView` it does **not** check `UserHandleCache.shared.isRestricted`, and `ReplyDetailView.sendReply` writes via `addDocument` directly. **Server-side this is correctly blocked** — the reply-create rule enforces `notRestricted()` (`firestore.rules:801`, verified) — so a restricted user simply gets a confusing generic failure rather than a real bypass. Pure client UX gap.
**Fix:** add `&& !UserHandleCache.shared.isRestricted` to `ReplyDetailView.canPost` and an early-return in `sendReply()`, matching `PostDetailView`.

### T-9 · **Low** · client (correctness / Swift 6) — Actor-isolation violation in the >400-unread notifications recursion (the build warning)

`NotificationsView.markAllRemainingAsRead()` (`@MainActor`-isolated) calls itself recursively from **inside** the Firestore `batch.commit { … }` completion closure, which runs on a nonisolated callback queue (`NotificationsView.swift:456`) — the source of the build warning "call to main actor-isolated instance method … in a synchronous nonisolated context." Only the >400-unread path hits it; it mostly "works" today but is a real cross-actor call that Swift 6 will hard-error.
**Fix:** wrap the recursive call `Task { @MainActor in self.markAllRemainingAsRead() }` (matching the already-correct scheduled call site at line 555).

### T-10 · **Low** · functions + rules (latent drift / hardening) — Duplicated URL/phone detectors + post-like rule lacks a schema lock

- **Duplicated detectors (N-13-shaped drift waiting to happen):** there are **three** URL detectors (`moderation.js:591` urlRegexes drives the *hold*; `index.js:2459` `containsURL` drives the *label* pii-vs-abuse_link; `index.js:2626` `SPAM_PATTERNS` drives posts-only spam) and **two** phone detectors (`index.js:2383` shape-based vs `moderation.js:547` digit-count). They disagree at the edges: `youtu.be/x` is held-but-mislabeled `pii`; `cash.app/x` and `foo.xyz` are caught by one detector only; bare `site.ru` / `vid.be` / `.info` / `.link` domains **escape every layer** (symmetric across posts/replies, so a coverage gap not a path divergence). The `hasPhoneNumber` comment claiming spaced numbers "fall through to `containsNameOrIdentifyingInfo`" is **false** — a fully-spaced phone strips to zero digits in `moderation.js`. **Fix:** collapse to one shared `containsURL` (export from `moderation.js`, delegate from `index.js`) consulted by both the hold and the label; widen the TLD set; correct the phone comment.
- **Post-like create rule lacks `hasOnly`** (`firestore.rules:905`) while the **reply**-like sibling has `hasOnly(['createdAt'])` (`firestore.rules:888`, verified). A tampered client can attach arbitrary scratch fields to `posts/{p}/likes/{uid}`. No trigger reads like-doc fields today, so storage-scribble only — but mirror the reply-like lockdown for consistency/future-proofing.

### Minor / cleanup (C-series)

- **C-1 · Low · client** — IG-Stories pasteboard write sets `expirationDate` but omits `.localOnly` (`ShareCardView.swift:~814`); the text-copy path correctly sets both (N-6). Add `.localOnly:true` for parity.
- **C-2 · Low · client** — `DraftStore.clearAll()` runs only on explicit sign-out (`ContentView.swift:180`), not on the `.authSessionExpired` path — a token-expiry logout leaves the prior user's drafts on disk (still `NSFileProtectionComplete` + backup-excluded). Clear on session-expiry too for shared devices.
- **C-3 · Low · client** — `reposts`/save optimistic toggles have no listener-suppression window (only `likes` got one in N-7, `FeedView.swift:836`); a feed re-delivery mid-round-trip can flicker the repost/save count.
- **C-4 · Low · client (dead code)** — the N-17 edit gutted the lone-first-name loop in `FeedView.swift` but left `sentenceStarters` (line 2207) and the now-empty `for word in words` loop (2210-2220) behind (the build warns `sentenceStarters never used`). Delete them.
- **C-5 · Info · moderation FN (pre-existing)** — a **sentence-initial lone last name** escapes: `"Rodriguez broke up with me"` → server `allow` (the sentence-starter exemption skips it; `moderation.js:649`). Mid-sentence (`"I dated Rodriguez"`) is held. Narrow, pre-existing (not N-17-caused), and the policy's stated tradeoff is to under-cover surnames; noted for completeness.
- **C-6 · Info · docs** — `APP_STORE_READINESS.md` says to delete a visible "a lawyer should review" note from the policy text. It is a Swift `///` **doc comment** (`ToskaTheme.swift:935`), *above* the displayed `toskaPolicyBody` literal — **not visible in-app**. No compliance action needed (optional tidy-up).
- **C-7 · Info · functions** — `pendingReason` taxonomy doc drift: `setPendingReview` docstring lists `abuse_link` but not `abuse_spam`, which `flagReasonToPendingReason` emits (`index.js:2807`). Confirm `admin.html` labels `abuse_spam`.

---

## 3. N-17 first-name relaxation — independent deep-dive (the requested focus)

**Verdict: the policy is implemented correctly and does not leak PII in the cases it intends to hold.** Verified by running the real server detector (`moderation.js`) on a 35-case corpus spanning the policy:

| Class | Example | Result | Correct? |
|---|---|---|---|
| Plain lone first name | "I miss John", "my ex Sarah", "Jessica's laugh", "this guy Tyler", "she was named Olivia" | **allow** | ✅ intended |
| Full name (two-cap shape) | "my ex Sarah Johnson", "his name is David Smith", "Tess Salinaro" | **hold** | ✅ |
| Lone last name (mid-sentence) | "my ex Johnson", "Johnson's new girlfriend" | **hold** | ✅ |
| Obfuscated first name | "J0hn" (leet), "Mіchael" (Cyrillic), "Ｓａｒａｈ" (fullwidth), "j o h n" (spaced), "haraS" (reversed) | **hold** | ✅ — evasion still flagged |
| Contact / handle / address | "dm me on insta", "@sarahreal", "call me at 555 123 4567", "lives at 123 Main Street", "ig: sarahreal", "apt 4B" | **hold** | ✅ |

The N-17 logic is consistent and defensible: a *plain* lone first name is allowed (Layer-4 `isFirst && !isLast && !isEvasion` skip, `moderation.js:648`); any **evasion** (confusables/leet/fullwidth/combining-mark/reversal/spacing) re-flags it (Layers 4/4.5/5), and last/full names and contact info are unaffected. The mirrored client logic (`FeedView.swift:2380-2386`) matches **for the N-17 paths specifically** (the divergences in T-1 are in *other*, older code, not the N-17 change).

**The one residual gap** (C-5, pre-existing, not introduced by N-17): a sentence-initial lone *last* name (`"Rodriguez broke up with me"`) escapes via the sentence-starter exemption, and a first+lowercase-surname (`"Sarah johnson"`) was always an NER-class miss. These are inherent to the dictionary+capitalization heuristic and acknowledged in code; N-17 did not widen them materially.

---

## 4. Crisis safety — end-to-end (documented for a safety/clinical reviewer)

**Architecture (verified):**
- **Two tiers, single-sourced.** `MOD_EXPLICIT_CRISIS` ⊆ `MOD_CONCERNING` *by construction* (`MOD_CONCERNING = [...explicit, ...soft]`, `index.js:2586-2587`) — the explicit-not-in-concerning bug class is structurally impossible. `matchesCrisisPhrase` is the single matcher, with leet/unicode/spaced-letter evasion normalization (`index.js:2597-2607`).
- **Server behavior:** a *concerning* post (either tier) is **held** at `pending_review` by `validatePost` (start-hidden, author-recoverable). An *explicit* post **additionally pages admins** via FCM — but **only if `system/crisisAlertRecipients` is seeded** (`index.js:2949-2964`); if not configured it silently logs and no human is paged (**owner must confirm this doc is seeded in prod — see §6**). The **soft** tier never pages (by design; relies on the 24h review SLA).
- **Client behavior:** compose-time check-in modal — explicit **always** shows; soft respects the `gentleCheckIn` toggle (`ToskaTheme.swift:903-916`). N-14 held-post banner surfaces region-aware `CrisisLines.resources`. Phrase lists are **client/server in sync** including the non-English additions (verified — `FeedView.swift:1781-1827` vs `index.js:2520-2587`).
- **Hotlines:** region-keyed; unknown region correctly falls through to `findahelpline` (not a dead `988`) — verified.

**Issues found:** T-4 (non-English explicit FPs page admins / suppress FR-ES-PT content), T-5 (resource languages don't cover the newly-detected languages). **Gaps for the safety owner to weigh:** (a) only ES/PT/FR are detected — German/Italian/Arabic/Hindi/Mandarin/etc. are not; (b) the soft tier never pages a human in real time; (c) explicit-tier paging depends entirely on the `crisisAlertRecipients` doc being seeded. **Recommendation stands:** a crisis-intervention professional should review the phrase lists (especially the non-English FPs in T-4) and the soft-tier-never-pages policy before launch.

---

## 5. Prior findings — re-verification (spot-checked, not re-litigated)

The bulk of `AUDIT.md`/`AUDIT-2.md` remediation re-verifies as genuinely correct. Confirmed against current source this pass:

- **Security contract (rules as sole perimeter on staging):** R-1 (post-update `hasOnly`, `firestore.rules:747`), **N-1 (reply-update `hasOnly`, `firestore.rules:849-850` — the byline-spoof-on-update is genuinely closed)**, R-2 (admin user read), N-12 (user-doc denylist; accepted residual). Privilege escalation (self-`confirmedAdult`/`restricted`/`isAdmin`/counters), byline forgery, graph enumeration, block bypass (follow/like/reply/repost/save/profile-read all `!exists(blocked/$(caller))`), notification spam (server-only `message`, pinned `fromHandle`/`createdAt`/`isRead`), audit-log forgery — **all rules-enforced and test-pinned.** The hostile-user suite now actually runs (N-8 fixed). The two new rule-level items this pass are T-2 (reply read window) and T-10 (post-like schema lock).
- **Counters:** all 16 triggers use the atomic `claimedTransaction`+retry with the claim **inside** the tx; no trigger still uses the old non-atomic path; decrements use `increment(-1)`; held-then-deleted replies don't double-decrement (`index.js:1410`). Verified-correct.
- **Deletion cascades:** `clearPostSubtree` (N-2), `onReplyDeletedCleanupReposts` (N-16), `clearRepostsOfPost` (F-6) — bounded, idempotent, resume-queued; held PII replies *are* deleted with the parent. The one gap is T-3 (`savedReplies` resume).
- **Callables:** `confirmAdult`/`giphyProxy`/`reconcileMyCounts` enforce App Check + auth + rate limits; Giphy host fully server-constructed (no allowlist bypass); `reconcileMyCounts` transactional. Verified-correct.
- **iOS:** DraftStore `NSFileProtectionComplete` + backup-excluded + legacy-scrub + sign-out clear (N-4) ✅; held-reply drill-down disabled (N-3, `PostDetailView.swift:1937`) ✅; copy-text pasteboard expiry+localOnly (N-6) ✅; feed like-flicker suppression (N-7) ✅; no leaked Firestore listeners; clean force-unwrap surface; universal-link/auth routing hardened. Open items: T-7 (cover), T-1/C-4 (detector), C-1/C-2/C-3.
- **App Store:** UGC 1.2 all six present and server-enforced; `PrivacyInfo.xcprivacy` consistent and the **ads SDK is NOT linked** into the target (verified in `project.pbxproj` — `NSPrivacyTracking=false` is safe); no `setUserID`; account deletion is a reachable hard delete + GDPR export; 17+ server-enforced; **Terms + Privacy URLs return HTTP 200**; `ITSAppUsesNonExemptEncryption=NO`; no ATS exceptions. **No submission-blocker found.** Optional polish: tappable "Contact us" row (support email is currently plain text in the policy).
- **Indexes:** every composite query across app + `admin.html` + functions has a matching index in `firestore.indexes.json`; **no missing-index runtime-failure risk** (a few unused legacy indexes, harmless).

---

## 6. Console/owner-only — cannot confirm from code (do not guess)

1. **`system/crisisAlertRecipients` seeded in prod?** Explicit-crisis admin paging is a **no-op** if this doc has no admin uids / FCM tokens (`index.js:2949-2964`). This is the single most safety-relevant unverifiable item.
2. **Real-device Release run.** App Attest + the 3 callables (`confirmAdult`/`giphyProxy`/`reconcileMyCounts`) + APNs only work on a physical device — untested here (App Attest doesn't run on simulator). Owner must archive a signed Release build and confirm sign-in (Apple/Google/email), age-gate, GIF picker, push, and a prod round-trip.
3. **Prod ↔ `main` parity** for rules **and** functions (CI auto-deploys rules to staging only; prod is manual). Confirm the T-1/T-2/T-3 fixes, once made, actually reach prod.
4. **`scrubLegacyPII.js` completion %** (drives the R-2 residual-exposure window).
5. **Staging dataset = synthetic only** (it now receives E2E + M-1 test writes; confirm no real PII).
6. **Firestore TTL** on `processedTriggerEvents.expiresAt` and that `repostCleanupQueue`/`postSubtreeCleanupQueue`/`userDeletionCleanupQueue` resume sweeps are draining.

---

## 7. Where I looked and found nothing (stated explicitly)

- Privilege escalation, byline forgery, graph enumeration, block bypass, counter manipulation, notification/push spam, audit-log forgery, reading others' private subcollections, self-publishing moderated content — all rules-enforced; re-read against the functions that own each write. (New rule items limited to T-2, T-10.)
- Counter idempotency/drift, the deletion cascades, the moderation start-hidden model for **posts**, the M-1 `replyCount` integrity across hold↔live↔remove — correct.
- The 3 callables' App Check/auth/rate-limit/input-validation and the Giphy host allowlist — no bypass.
- Crisis tier derivation (explicit ⊆ concerning) and evasion normalization — correct and single-sourced.
- Firestore composite indexes vs all queries — no gap.
- Privacy manifest vs actual collection; ads SDK linkage; `setUserID`; ATS; encryption-compliance flag — all clean.
- Crash/force-unwrap surface and Firestore snapshot-listener lifecycle on the interaction paths — clean (one constant-pattern `try!` is fine).
- Deep links / URL schemes — only Google's reversed-client-id (handled by `GIDSignIn`) and a host/scheme-pinned universal-link handler; no open routing.

---

## 8. Recommended priority order

1. **T-1** — mirror the three server FP-fixes into `FeedView.swift` + add a client/server parity test (biggest user-facing win; directly serves the launch-readiness FP goal).
2. **T-2** — flip the reply hold to status-first-then-jitter (and optionally start-hidden reply create) — closes a real PII window on the one surface built to protect PII.
3. **T-3** — one-line `ALLOWED_SUB_RESUME` fix (GDPR).
4. **T-4 / T-5** — safety-owner + native-speaker review of the non-English crisis phrases and resource-language coverage.
5. **T-6 / T-7** — bound the reply listener; raise the privacy cover to window level.
6. **T-8 / T-9 / T-10 / C-series** — quality/hardening cleanups.
7. **§6** — owner console verifications (esp. #1 crisisAlertRecipients and #2 real-device).

*Artifacts: this file. Proof harnesses used: `/tmp/parity.js` (server detector corpus), `/tmp/parity.swift` (the actual Swift client detector, compiled with `swiftc -enable-bare-slash-regex` and run) — both throwaway. No code was modified, deployed, or pushed.*
