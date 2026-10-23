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
- **iOS:** build **93** on TestFlight (v1.3), installable. Critical paths
  verified in prod on a fresh install: sign-in, feed, GIF post, and the
  crisis flow end-to-end (detection → 988 check-in → hold → crisis page push).
- **Projects:** `toska-4ebf4` (prod), `toskastaging` (staging/dev). Web app
  = Firebase Hosting (app.toskaapp.com). Marketing + legal + admin + prompts
  = GitHub Pages (www.toskaapp.com, from `docs/`). No Cloud Storage anywhere
  (media is Giphy URLs via a server proxy).

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

## ⚠ Active constraint (until B94-MFA ships)

The admin account has TOTP MFA enrolled, but **iOS and the web app (app.js) do
not yet handle the TOTP sign-in step** (admin.html does). Until build 94 ships
MFA handling on iOS + web:
- **Do NOT sign out of the iOS app** on the admin account — you could not sign
  back in (recovery would be an Admin-SDK factor unenroll).
- **Do NOT change the admin account password** or revoke its tokens.
- The current iOS session stays valid and the device's FCM token is live, so
  crisis pages still arrive.

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
