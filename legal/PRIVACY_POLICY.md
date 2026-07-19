# toska — Privacy Policy

**Version 2.0 — Effective July 19, 2026**
**Operator / data controller: SALTE DEVELOPMENT LLC**
**Contact: salte@saltedevelopments.com**

> Changelog
> - v2.0 (2026-07-19): Co-versioned with Terms of Service v2.0 for joint re-acceptance. No reduction in your privacy: added an explicit Global Privacy Control / Do-Not-Track statement (§8), clarified that we honor opt-out preference signals, and confirmed our breach-notification and data-minimization commitments. Data practices are otherwise unchanged from v1.0.
> - v1.0 (2026-07-17): First versioned release. Supersedes the web policy dated April 17, 2026. Substantive corrections from that text: removed references to "messages" (direct messages were removed from the app in May 2026 and no message data is collected), corrected the Giphy description (searches are proxied through our server), added the full data inventory (drafts, mood/stage, usage-streak days, prompt responses), stated exact retention windows, and added the "what anonymous actually means" section.

toska is built around pseudonymity. We collect as little as we can, we never sell your data, and this policy is written to match what the code actually does — no more, no less.

## 1. What we collect

Everything below is collected only because a feature needs it. We collect **no** real name, phone number, location, contacts, photos, camera data, or advertising identifiers, and the app contains no ad SDKs and does no cross-app tracking.

| Data | Why | Where it lives |
|---|---|---|
| Email address | Sign-in, password reset, account recovery, support | Firebase Auth; a copy in your private, owner-only profile area |
| Random handle | Your display identity (generated; never your real name) | Database (public) |
| Posts, replies, reflections, prompt responses | The app itself | Database (visible per feature rules) |
| Drafts | Posts you saved but didn't publish | Database (only you can read them) |
| Likes, saves, reposts, follows, blocks | Core features; blocks also filter what you see | Database (your lists are private to you; like/repost existence is visible on content) |
| Feeling tag, breakup stage, mood (if you set them) | Personalizing your feed and prompts | Stage/mood in your private, owner-only profile area |
| Days you opened the app (date only) | Your streak on your own profile | Database (only you can read it) |
| Push notification token | Delivering notifications you opted into | Your private, owner-only profile area |
| Reports you submit (including the reported text) | Moderation and safety | Restricted database area readable only by moderators |
| Crash reports | Fixing bugs | Firebase Crashlytics — **not linked** to your account (we never attach your user ID), and error text is scrubbed for identifiers before sending |
| Usage analytics (event names only) | Understanding feature use — **opt out any time** in Settings → Privacy | Firebase Analytics — event vocabulary is fixed and never includes what you wrote, your handle, your ID, or search terms |

Timestamps on content are server-assigned and used for ordering and expiration — we don't collect device clocks, time zones, device models, or OS-version analytics of our own.

## 2. What "anonymous" actually means here — the honest version

- **To other users:** you are a random handle. Nothing in the app shows any other user your email, name, or account identifiers, and our database rules — not just the interface — prevent other users from reading your private data (email, mood, stage, settings, drafts, blocks, notification token).
- **To us (the operator):** toska is *pseudonymous*, not anonymous. Your posts are stored against your account ID, and your account ID is connected to your email. That means we — a very small team — *can* technically connect content to an email address, and will do so only for moderation, safety, or valid legal process. We cannot honestly claim otherwise, and we won't.
- **One persistent handle:** all your posts appear under the same handle, so other users can see that the same (pseudonymous) person wrote them. Whisper and midnight posts are *ephemeral*, not extra-anonymous — they show your handle like any post until they expire.
- **Crisis signals:** if our systems detect crisis language in your post, the post is held for human review and crisis resources are shown to you. The review marker is visible only to moderators — since July 2026 our database rules structurally prevent moderation and crisis flags from ever being readable by other users, and content restored after review is scrubbed of all such markers.

## 3. How we use data

To run the app (feeds, threads, notifications), personalize your feed, detect and act on content that violates the Terms, keep the service safe (report review, crisis-content review, abuse rate-limiting), and fix crashes. **We do not sell, rent, or share your personal data with advertisers or data brokers, we do not use your data for advertising at all, and we do not use your content to train AI models or allow anyone else to.**

## 4. Public sharing of posts (your control)

If your **allow sharing** setting is on (default on; Settings → Privacy):

- other users can render a post of yours as a **share-card image** — words and feeling tag only, never your handle or any identifier;
- a small number of posts, hand-picked by us, may appear on **toskaapp.com** and its share pages — same rule: words, tag, and felt-count only, no handle, no identifier, no profile link.

Turning it off ends both, including for existing posts. Deleting a post removes it everywhere, including the website. Letters and expiring posts are never shareable regardless of this setting.

## 5. Third parties that process your data

- **Firebase / Google Cloud** (our infrastructure): authentication, database, serverless functions, push delivery, crash reporting, analytics, and app-integrity checks (App Check) all run on Google's infrastructure, so the data in §1 is processed on Google's servers under their [privacy documentation](https://firebase.google.com/support/privacy). We use them as a processor to run toska, not to advertise.
- **Apple** (push notifications, Sign in with Apple): push payloads are routed through Apple's notification service. **They contain no post content and no handles** — only generic text ("someone felt your words") and routing IDs. Sign in with Apple shares your email with us (or Apple's private relay address if you choose Hide My Email).
- **Google Sign-In** (optional sign-in): shares your Google account email with us.
- **Giphy** (GIF search): when you search GIFs, your search terms are sent to Giphy's API **through our server** — Giphy does not receive your identity, account ID, or IP address for searches. When a GIF is displayed, your device loads the image directly from Giphy's servers, which — like any image host — see your IP address. [Giphy privacy policy](https://support.giphy.com/hc/en-us/articles/360032872931).

No other third party receives user data. There are no ad networks, no data brokers, no tracking SDKs.

## 6. Retention — exact windows

| Data | Kept until |
|---|---|
| Posts, replies, profile | You delete them or delete your account |
| Whisper posts | 1 hour after posting, then hard-deleted from the live database within ~1 more hour by automated cleanup |
| Midnight posts | Your local midnight, then hard-deleted the same way |
| Notifications in your inbox | Pruned after 90 days |
| Drafts | Until you delete them or your account |
| Reports and moderation records | Retained after content deletion for safety, abuse-pattern, and legal-defense purposes |
| Admin action log | Retained (internal accountability record; contains no post content beyond what moderation required) |
| Backups | Point-in-time 7 days; daily backups 7 days; weekly backups 8 weeks — deleted data ages out of all backups within **~60 days** |

## 7. Account deletion — exactly what it deletes

Deleting your account (Settings → delete account) starts an automated server-side cascade that removes: your profile and handle, private profile data (email copy, mood, stage, settings, push token), posts, replies, likes and their effect on counts, saves, reposts, follows/followers, blocks, drafts, streak days, notifications you received, notifications you triggered in other users' inboxes, and your Firebase Auth account. Sign-in-with-Apple tokens are revoked with Apple. The cascade retries hourly until complete if any step fails. What survives: reports about content (for safety), the admin action log, and backup copies until they age out (§6). We aim for the live-database cascade to complete within minutes, not days.

You can also delete or edit any individual post or reply anywhere it appears, and export your data (§8).

## 8. Your rights

Available to **everyone, in-app, today** — no forms, no email needed:

- **Access / portability:** Settings → export my data produces a JSON file of everything you've authored and own (account data, posts, replies, drafts, liked/saved IDs, follower/following handles, notification history).
- **Deletion:** per-item delete everywhere; full account deletion in Settings.
- **Correction:** edit your posts and replies; change email in Settings.
- **Analytics opt-out:** Settings → Privacy.
- **Sharing opt-out:** Settings → Privacy.

**Do Not Track / Global Privacy Control:** because we do no cross-app or cross-site tracking and serve no advertising, there is nothing to track across sites. We do not sell or "share" personal information, so there is no such activity to opt out of; the in-app analytics opt-out (Settings → Privacy) turns off the only optional collection we do. We treat a browser Global Privacy Control (GPC) or Do-Not-Track signal on our websites as a valid opt-out preference.

If you're in the EU/EEA/UK, these mechanisms are how we honor GDPR access, portability, erasure, and rectification requests; if you're in California, they cover CCPA/CPRA access, deletion, correction, and opt-out rights (we do not sell or "share" personal information as those laws define the terms, and we likely fall below the covered-business thresholds — we honor the rights regardless, and we do not discriminate against you for exercising them). You can also email salte@saltedevelopments.com for anything the in-app tools don't cover, and we'll respond within 30 days. toska is US-based and your data is processed on Google Cloud infrastructure in the United States; by using toska from outside the US you understand your data is transferred there.

## 9. Legal requests

We may disclose data when required by law — a valid subpoena, court order, or equivalent legal process. We will notify affected users when legally permitted. We do not voluntarily hand data to law enforcement or governments, with one exception: we may report imminent threats of serious harm.

## 10. Security

Data is encrypted in transit and at rest on Google's infrastructure. Access rules are enforced in the database layer (not just the app), are covered by an automated test suite, and are audited regularly. App Check limits API access to genuine builds of the app. No system is perfect: if we learn of a breach affecting your personal data, we will notify affected users and any required regulators **without undue delay** after confirming it.

## 11. Age

toska is for users 17 and older, and your age confirmation is recorded at signup. We do not knowingly collect data from anyone under 17; if we learn we have, we delete the account and its data. toska is not directed at children under 13, and we never knowingly collect their data (COPPA).

## 12. Changes to this policy

Each version is numbered and dated. Material changes are shown in the app for re-acceptance before continued use, and your accepted version and timestamp are recorded on your account.

## 13. Contact

salte@saltedevelopments.com

© 2026 SALTE DEVELOPMENT LLC
