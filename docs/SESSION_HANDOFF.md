# Toska — session handoff

Living note for picking up work in a fresh session. No secrets or personal
data here by design (this file is in the public repo and served by Pages).
Credentials live only in the gitignored local file; infra ids live in the
Firebase/GCP consoles.

_Last updated: 2026-10-23._

## Where things stand

- **Production is healthy and launch-hardened.** A full pre-launch audit
  (`AUDIT_REPORT.md`, gitignored, local only) was run and its Phase-2 fixes
  shipped. Latest release tag: **`v1.3-b93`**.
- **iOS:** build **97** on TestFlight (v1.3) — see "Today (2026-10-23)" below.
  Builds 94→97 all shipped today. Earlier critical paths verified in prod on a
  fresh install: sign-in, feed, GIF post, and the crisis flow end-to-end
  (detection → 988 check-in → hold → crisis page push).
- **Projects:** `toska-4ebf4` (prod), `toskastaging` (staging/dev). Web app
  = Firebase Hosting (app.toskaapp.com). Marketing + legal + admin + prompts
  = GitHub Pages (www.toskaapp.com, from `docs/`). No Cloud Storage anywhere
  (media is Giphy URLs via a server proxy).

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
  - **⚠️ PROD RULES PROVENANCE (2026-10-24):** prod firestore.rules = branch
    **`rules-prod-2026-10-24` @ `5fac94c`** (collectionGroup blocked read rule;
    **Option 2 NOT included**). `main@HEAD` contains Option 2 — **do NOT run
    `firebase deploy --only firestore:rules` from main** until the two-account
    retest passes, or you'll ship Option 2 early. Deploy Option 2 from main only
    after owner's go.
  - **Option 2 (rules):** posts `read` split into `list` (unchanged) + `get`
    (+`notBlockedBy(authorId)`), so a blocked user can't directly open/deep-link
    the blocker's post. Rules tests; suite 289 passing. **COMMITTED on main, NOT
    DEPLOYED** (prod runs 5fac94c without it). ⚠️ **Pending owner: deploy from
    main `firebase deploy --only firestore:rules --project toska-4ebf4`
    TOGETHER, after the two-account block retest on build 97 passes.**
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

- **Build 94** (not yet built or uploaded) — three items from
  `issues/BUGS.md`, each reproduced/fixed/tested before an owner-approved
  build:
  1. **B94-MFA** iOS TOTP sign-in handling (BLOCKING — do first).
  2. **B94-1** feed GIF render timing (row should observe `postGifUrls`).
  2. **B94-2** repost optimistic UI update.
  3. **B94-iOS** sign-up sharing choice (SEO-01 wording, unchecked default);
     the default-false flip is already committed.
  Also queued: **B94-W** full web sharing-consent UI (checkbox + web settings
  toggle), and a reminder to re-edit the privacy/terms sharing lines once the
  web toggle + sign-up checkboxes exist.

## Open items (owner / manual)

- Browser checklist A (incognito): sign-in, 8-char signup gate, fresh-signup
  `allowSharing:false` confirmation, password-reset email, admin MFA sign-in,
  reports tab. (Code + staging verified; true prod-browser steps are
  owner-only — the API-key referrer lock correctly blocks headless testing.)
- Normal push receipt (like/reply) on device.
- Glance at Crashlytics + Performance dashboards to eyeball build-93 data
  (restriction can't break them; just visual confirmation).
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
