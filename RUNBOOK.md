# Toska Runbook

Operational playbook for the Toska iOS app. Audience: future-you, an
emergency-recovery contractor, or anyone trying to figure out "where do I
look" when something breaks. Keep this file accurate; outdated runbooks
are worse than missing ones.

---

## Quick reference

| What | Where |
|---|---|
| Firebase Console | https://console.firebase.google.com/project/toska-4ebf4 |
| Cloud Console | https://console.cloud.google.com/?project=toska-4ebf4 |
| Crashlytics | https://console.firebase.google.com/project/toska-4ebf4/crashlytics |
| Cloud Functions list | https://console.cloud.google.com/functions/list?project=toska-4ebf4 |
| Cloud Logging | https://console.cloud.google.com/logs/query?project=toska-4ebf4 |
| Cloud Monitoring alerts | https://console.cloud.google.com/monitoring/alerting?project=toska-4ebf4 |
| Billing budgets | https://console.cloud.google.com/billing/budgets?project=toska-4ebf4 |
| App Store Connect | https://appstoreconnect.apple.com |
| GitHub repo | https://github.com/toskaapp12/toska |
| Live admin dashboard | https://www.toskaapp.com/admin.html |
| GitHub Pages site | https://www.toskaapp.com |

| Identifier | Value |
|---|---|
| Firebase project ID | `toska-4ebf4` |
| Firebase project number | `183467627187` |
| Apple Team ID | `4V9EFWWZ4Q` |
| Bundle ID | `com.toskaapp.toska` |
| Cloud Functions region | `us-central1` |
| Billing account | `01E7A8-459A50-AB1E6E` |
| Notification channel ID | `projects/toska-4ebf4/notificationChannels/17038690850716525077` |
| Support email | `salte@saltedevelopments.com` |

---

## Architecture in one paragraph

iOS SwiftUI app (`toska/`) talks to Firebase: Firestore for data, Auth
for sign-in (Apple/Google/email/anonymous), FCM for push, App Check via
App Attest, Crashlytics for crashes. Backend logic in `functions/index.js`
(~30 Cloud Functions v2 in Node 22). Firestore rules in `firestore.rules`
gate every write; rules tests live in `firestore-tests/`. Public admin
dashboard at `docs/admin.html` is served by GitHub Pages from the `main`
branch (`docs/CNAME` points at www.toskaapp.com).

---

## Local development

### Prerequisites

- Xcode 26+ on macOS
- Node 22 (`brew install node@22`)
- Java 21 (`brew install openjdk@21`) — Firestore emulator requirement
- firebase-tools 15+ (`npm install -g firebase-tools`)
- gcloud CLI (`brew install google-cloud-sdk`)
- Authenticated as `salte@saltedevelopments.com`:
  - `firebase login`
  - `gcloud auth login`

### Run the app

```sh
open toska.xcodeproj
# In Xcode: select an iPhone simulator → Cmd+R
```

### Run rules unit tests

```sh
cd firestore-tests
npm install        # first time only
npm test           # 23 assertions, ~30 sec including emulator boot
```

CI runs the same `npm test` on every PR (see `.github/workflows/ci.yml`).

### Run iOS UI tests

```sh
xcodebuild test -scheme toska \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:toskaUITests
```

Most tests `XCTSkip` based on auth state — that's intentional, not failure.

---

## Deploy procedures

Always deploy in this order: **rules → indexes → functions → iOS**.
Functions can depend on rules; iOS depends on functions; reversing the
order risks calling code paths that don't exist yet.

### Firestore rules

```sh
firebase deploy --only firestore:rules
```

`firebase deploy --only firestore:rules --dry-run` validates the rules
parse without uploading. Always run dry-run before a production deploy
on a Friday afternoon.

### Firestore indexes

```sh
firebase deploy --only firestore:indexes
```

New indexes can take minutes-to-hours to backfill on collections with
existing data. Watch progress at the Firestore Console → Indexes tab.

### Cloud Functions

```sh
firebase deploy --only functions                         # all functions
firebase deploy --only functions:sendPushNotification    # one function
firebase deploy --only functions:rateLimitPosts,functions:rateLimitReplies
```

Single-function deploys are ~30 seconds; full redeploys are ~3-5 minutes
for ~30 functions.

### iOS app to TestFlight

1. In Xcode, select **Any iOS Device (arm64)** as destination
2. Bump `CURRENT_PROJECT_VERSION` in `toska.xcodeproj/project.pbxproj`
   (or in Xcode → toska target → General → Build).
   Apple rejects re-uploads of the same `(MARKETING_VERSION, build)` pair.
3. **Product → Archive**
4. In the Organizer that opens: **Distribute App → App Store Connect → Upload**
5. Wait ~5-15 min for processing in App Store Connect → TestFlight tab
6. Add testers, ship

### docs/ (admin dashboard, terms, privacy)

GitHub Pages auto-deploys on push to `main`. Build takes ~30-60 seconds.
Confirm:

```sh
curl -sS https://www.toskaapp.com/admin.html | grep -c "toska admin"
# Expect 1
```

---

## Rollback procedures

### Rules rollback

The Firebase Console keeps rule history.

1. Firebase Console → Firestore → **Rules** tab → **History** (top right)
2. Find the last-known-good revision
3. **Revert to this version** → Confirm

Faster CLI alternative if you have the prior commit hash:

```sh
git checkout <good-commit> -- firestore.rules
firebase deploy --only firestore:rules
git checkout HEAD -- firestore.rules    # restore working tree
```

### Cloud Functions rollback

No built-in rollback like Cloud Run. Use git:

```sh
git log --oneline functions/index.js              # find good commit
git checkout <good-commit> -- functions/index.js
firebase deploy --only functions
git checkout HEAD -- functions/index.js
```

For a single misbehaving function, the same dance works with
`firebase deploy --only functions:<name>`.

### iOS app rollback

Apple App Store doesn't support rollback. To pull a bad release:

1. App Store Connect → App → Pricing and Availability → set to "Removed
   from sale" (existing installs keep working; no new downloads)
2. Submit a fixed build with a bumped version
3. Phased Release rollout in App Store Connect throttles to 1% / 2% /
   5% / 10% / 20% / 50% / 100% over 7 days — pause if crash-rate spikes

For TestFlight builds, just disable the build in TestFlight or push a
new one.

### Index rollback

You generally don't roll back indexes — extra ones don't hurt. If you
must remove one, edit `firestore.indexes.json` and redeploy. Existing
docs aren't reindexed; new writes use the updated set.

---

## Monitoring — where to look when things break

| Symptom | First place to look |
|---|---|
| App crashing on launch | Crashlytics dashboard |
| App crashing on a specific screen | Crashlytics → filter by issue |
| Pushes not arriving | Cloud Logging, filter `resource.type="cloud_run_revision" resource.labels.service_name="sendpushnotification"` |
| Posts/replies failing to publish | Cloud Logging on `validatepost` or `ratelimitposts` |
| Counters drifting | Cloud Logging on `onlikecreatedupdatecounts`, etc. — call `reconcileMyCounts` HTTPS endpoint to repair the calling user's followerCount/followingCount |
| Account deletion stuck | Cloud Logging on `onuserdocdeleted`, `monitorpendingdeletions`, `resumepostdeletion` |
| App Check rejections | Firebase Console → App Check → Metrics |
| Costs spiking | Cloud Console → Billing → Reports |
| Suspicious user activity | Cloud Logging filter `protoPayload.authenticationInfo.principalEmail="<uid>"` |

### Active alerts (will email salte@saltedevelopments.com)

- **Crashlytics** Basic Alerts: new fatal/non-fatal/trending/regression/missing-dSYM
- **Crashlytics** Velocity Alerts: fatal issue ≥25 users + ≥1%
- **Cloud Functions** error rate: any ERROR severity in `sendPushNotification`,
  `onUserDocDeleted`, or `validatePost` (rate-limited to 1 alert per 5 min)
- **Billing budget**: 50% / 90% / 100% of $50/month

---

## Common operations

### Add an admin user

Admins are determined by the existence of `/admins/{uid}` with
`role: "admin"`. Rules forbid client writes to this collection — only
the Admin SDK (and you, via the Console) can write here.

**Via Firebase Console:** Firestore → `admins` collection → **Add document**
→ Document ID = `<uid>` → field `role` (string) `admin` → Save.

**Via Node script** (faster for batch operations — run from `functions/`):

```sh
cd functions && node -e '
  const a = require("firebase-admin");
  a.initializeApp();
  a.firestore().doc("admins/" + process.argv[1])
    .set({role: "admin"})
    .then(() => process.exit());' <UID>
```

Requires `GOOGLE_APPLICATION_CREDENTIALS` to point at a service-account
key, or run `gcloud auth application-default login` first.

### Restrict (silence) a user

Easiest: admin dashboard at https://www.toskaapp.com/admin.html →
**Restricted Users** tab.

**Via Firebase Console:** Firestore → `users/<uid>` → Edit fields →
add `restricted: true`, `restrictedAt: <server timestamp>`,
`restrictedBy: <your-uid>`. To auto-expire after 48h, also add
`restrictedUntil: <Timestamp 48h from now>`. Without it, the
restriction persists until manually cleared.

**Via Node script** (run from `functions/`):

```sh
cd functions && node -e '
  const a = require("firebase-admin");
  a.initializeApp();
  const FV = a.firestore.FieldValue;
  a.firestore().doc("users/" + process.argv[1]).update({
    restricted: true,
    restrictedAt: FV.serverTimestamp(),
    restrictedBy: "admin",
  }).then(() => process.exit());' <UID>
```

### Force-delete a post (moderation)

Admin dashboard → **Flagged Posts** → Delete.

**Via Firebase Console:** Firestore → `posts/<postId>` → menu (⋮) →
Delete document. Subcollections (replies/likes/reflections) need to
be deleted separately, but the next `cleanupExpiredPosts` sweep will
catch any orphans if they have an `expiresAt`.

The `onPostDeletedUpdateTagCounts` trigger fires automatically;
tag counters self-heal.

### Repair a user's follower counts

The `reconcileMyCounts` HTTPS endpoint lets a user fix their own counts
from inside the app (Settings → Reconcile counts). Server-side
equivalent for an admin — Console: edit `users/<uid>`, set
`followerCount` and `followingCount` to the actual subcollection sizes.

**Via Node script** (run from `functions/`):

```sh
cd functions && node -e '
  const a = require("firebase-admin");
  a.initializeApp();
  const uid = process.argv[1];
  const ref = a.firestore().doc("users/" + uid);
  Promise.all([
    ref.collection("followers").count().get(),
    ref.collection("following").count().get(),
  ]).then(([f, fi]) => ref.update({
    followerCount: f.data().count,
    followingCount: fi.data().count,
  })).then(() => process.exit());' <UID>
```

### Bump iOS build number

```sh
sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = NEW_NUMBER;/g' \
  toska.xcodeproj/project.pbxproj
```

Or in Xcode: toska target → General → Build (text field).

### Update the support email

Three places:
1. `toska/ToskaTheme.swift` — `let toskaSupportEmail = "..."`
2. `docs/privacy.html` — mailto links
3. `docs/terms.html` — mailto links

Update all three together. iOS change ships with next archive; docs
ship via GitHub Pages on push.

---

## Secrets inventory

| Secret | Stored in | Rotation procedure |
|---|---|---|
| `GIPHY_KEY` | Firebase Secret Manager | `firebase functions:secrets:set GIPHY_KEY`, redeploy giphyProxy |
| Firebase service account | Auto-managed by Firebase | None (managed) |
| Apple Developer signing certs | Apple Developer portal + macOS Keychain | Renew via Xcode → Settings → Accounts → Download Manual Profiles |
| App Store Connect API key (if used for fastlane) | None today | n/a |
| `GoogleService-Info.plist` | Local checkout, gitignored | Re-download from Firebase Console → Project settings → iOS app |

The `GoogleService-Info.plist` API key (`AIzaSy...`) is a public client
key; safe to ship in the iOS bundle. Treat all other items as secret.

---

## Known accepted gaps

These were flagged during the 2026-04-26 / 2026-04-29 audits and
deliberately not fixed. Re-evaluate if any of these become exploited
or scale past their current risk model:

- **EditReplyView** lacks a `contentViolation` handler — edited replies
  bypass the client-side moderation precheck (server-side
  `onReplyUpdated` still re-runs moderation, so flagged content gets
  caught at the trigger layer).
- **functions/cleanup.js** missing project-id guard — admin tooling
  that wipes everything; safe because it's run manually on dev DBs only.
- **AppleSignInHelper.revokeTokenIfNeeded** keychain delete query is
  over-broad — could delete unrelated keychain items if an unexpected
  app shares the keychain access group. Bounded by the entitlement.
- **Universal link handler** doesn't validate host beyond path shape —
  `MainTabView` deep-link path validation is permissive.
- **emotional-weather** aggregate query lacks a blocked-user filter —
  blocked users may still appear in the aggregated mood view.
- **App Check on docs/admin.html** is a TODO — to enable, get a
  reCAPTCHA Enterprise site key and uncomment the block in
  `docs/admin.html`. The site key is public and safe to commit.

---

## Disaster recovery

### "I need to roll back everything to the last known good state"

```sh
git log --oneline -20                              # find the last good commit
git checkout -b emergency-rollback <good-commit>
firebase deploy --only firestore:rules,functions   # redeploy that snapshot
# iOS: build that commit, archive, expedited App Store submission
```

### "I lost access to the Firebase project"

Project ownership lives in Google's account system. Recovery path:

1. https://accounts.google.com/signin/recovery (account recovery)
2. If that fails: https://support.google.com/accounts/answer/7682439
3. Last resort: another Owner on the project. Today there is **only
   one Owner** (`salte@saltedevelopments.com`) — see Sprint Item #9
   to add a backup admin.

### "I lost access to the Apple Developer account"

Same shape — Apple ID recovery via https://iforgot.apple.com. Apple
support: https://developer.apple.com/contact. Single-Apple-ID accounts
are recoverable via the recovery key set up at account creation.

### "App Check is rejecting all my legitimate requests"

Symptom: `giphyProxy` and `reconcileMyCounts` returning 401 for
real users, not just attackers.

1. Firebase Console → App Check → check for outage banner
2. If misconfigured, **temporarily disable enforcement**:
   Firebase Console → App Check → APIs → Cloud Firestore /
   Cloud Functions → Unenforced
3. Investigate the root cause before re-enforcing
4. Re-enforce within hours, not days

### "Costs are spiking"

1. Cloud Console → Billing → Reports → group by SKU
2. Most likely culprits: Firestore reads (badly-indexed query),
   Cloud Functions invocations (runaway trigger loop), FCM (mass push)
3. **Killswitch options**:
   - Disable a runaway function: `gcloud functions delete <name> --region=us-central1`
   - Tighten a rule to deny writes: edit firestore.rules, deploy
   - Lower the billing budget cap to throttle aggressively

---

## Contact / escalation

- **Owner**: salte@saltedevelopments.com (you)
- **Firebase support**: https://firebase.google.com/support (Blaze plan support)
- **Apple Developer support**: https://developer.apple.com/contact
- **Security report inbox**: salte@saltedevelopments.com (no separate
  security@ alias yet — set one up if accepting external reports)
