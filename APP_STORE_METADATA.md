# Toska — App Store Connect submission metadata

Draft. Every field below maps to a real input on App Store Connect (or, where
called out, the Apple Developer portal for bundle-level config). Edit before
pasting; the legal / marketing tone is your call. Items marked **DECISION**
need an explicit choice from you before submitting.

Sections follow the order ASC walks you through.

---

## 1. App identity (already configured — confirm only)

| Field | Value |
|---|---|
| App name | Toska |
| Bundle ID | `com.toskaapp.toska` |
| Apple Team ID | `4V9EFWWZ4Q` |
| Primary language | English (U.S.) |
| Primary category | Social Networking |
| Secondary category | **DECISION** — Lifestyle or Health & Fitness (Health & Fitness only if you stay clear of medical-claim language) |

---

## 2. Subtitle (30 chars max)

Pick one:

- `Reddit, but only for breakups` (28) — exact pitch, slight squat risk on Reddit's brand
- `Anonymous breakup talk` (22)
- `Where breakups talk back` (24)
- `For after the breakup` (21) — intentionally understated

Recommendation: `Anonymous breakup talk` — non-trademark-adjacent, surfaces both the privacy and the topic.

---

## 3. Promotional text (170 chars, editable post-launch without resubmitting)

> a quiet space for the part of the breakup nobody wants to read about. anonymous handles only. no advice, no fixing — just the words you can't say out loud yet.

(167 chars.)

---

## 4. Description (4000 chars max)

```
toska is a place to put the parts of a breakup that don't fit anywhere
else. the part you can't text your friends — they're tired. the part
your therapist already heard last week. the part that wakes you up at
3am.

every account is anonymous. no real names, no photo, no bio. you pick
a handle made of two random words and a number, or you let us pick
one for you. you can change it whenever. you don't have to "build a
following" to be heard.

what's here:

- write what you're feeling. nothing is required to be useful or
  resolved or even coherent. you just say it.
- read what other people are feeling. they're not advice columns.
  they're the same thing you wrote, written by someone else.
- react to a post by feeling it back. no likes, no upvotes — just an
  acknowledgement that someone else recognized what you said.
- send a private message to someone whose post stayed with you. five
  messages each, then it's done. you don't have to be friends.
- follow people you keep recognizing yourself in. unfollow the same
  way.
- write reflections on your old posts when you read them again later.
  what changed? what didn't?
- gather in a feeling circle when you're up late and don't want to be
  alone with it. the circle dissolves at midnight.

what isn't here:

- a follower count next to your name (you can hide yours; we hide
  ours by default)
- a "days since the breakup" tracker (some days you don't want to
  count)
- people trying to match you with someone (this isn't dating)
- people trying to fix you (this isn't therapy)
- people trying to sell you anything (we don't take money from
  advertisers — see in-app subscription, optional)

we built moderation for this carefully. posts that mention someone
else by name get caught before they're visible to anyone. blocking
someone removes their content from your feed AND prevents them from
seeing yours. reports get reviewed within 24 hours. the moderation
queue is not contracted out.

if you are in crisis, please reach out to a person who can help in
real time. we keep the 988 suicide & crisis lifeline in-app and
recommend you use it. toska is not a replacement for a crisis line,
a therapist, or a person who loves you.

we collect the minimum data required to run the app — see our
privacy policy. we do not sell user data. we do not show ads. we
do not share your handle with anyone outside toska.

the name "toska" is from a russian word vladimir nabokov described
as "a sensation of great spiritual anguish, often without any
specific cause." it felt right.
```

(~2,950 chars. Comfortable headroom.)

**DECISION:** does the in-app subscription claim above match your monetization plan? If not, edit/remove.

---

## 5. Keywords (100 chars, comma-separated, no spaces)

Recommendation:

```
breakup,heartbreak,anonymous,journal,grief,divorce,ex,healing,vent,reddit,community,therapy,relationship
```

(99 chars.) Keywords below "the fold" — App Store Search ranks the first 5 hardest, then drops off. Keep `breakup`, `heartbreak`, `anonymous`, `journal`, `grief` first.

**DECISION:** "therapy" is a keyword you should be cautious about — it could attract reviewer scrutiny that you're not a clinical service. If risk-averse, swap with `loneliness` or `feelings`.

---

## 6. URLs

| Field | URL |
|---|---|
| Support URL | https://www.toskaapp.com/support |
| Marketing URL | https://www.toskaapp.com |
| Privacy Policy URL | https://www.toskaapp.com/privacy |

**DECISION:** Confirm these pages exist on the GitHub-Pages site at `docs/`. If `support` doesn't exist, reuse the marketing URL — the field is required but can be the same.

---

## 7. Age rating (Apple's questionnaire — answer EXACTLY these)

App Store Connect → Age Rating → "Edit":

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | **Infrequent/Mild** (user-generated content can include language) |
| Mature/Suggestive Themes | **Infrequent/Mild** (breakup content occasionally references sex / intimacy) |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None (we are not clinical; we point at 988 explicitly) |
| Alcohol, Tobacco, or Drug Use or References | **Infrequent/Mild** (users will mention drinking) |
| Simulated Gambling | None |
| Sexual Content and Nudity | None |
| Graphic Sexual Content and Nudity | None |
| Contests | No |
| Unrestricted Web Access | **No** (we don't embed an open browser) |
| Gambling | No |
| User-Generated Content | **Yes** — this is the load-bearing answer; once you say yes, Apple expects (a) a content moderation flow, (b) a way to report users/content, (c) a way to block users, (d) a published terms of service. We have all four. |

Resulting rating: **17+** (User Generated Content alone forces 17+ regardless of the other answers).

---

## 8. App Privacy (the nutrition label)

The single most-scrutinized section. Be honest — Apple cross-checks against your binary's actual API usage.

### Data linked to the user

These can be tied back to a uid in our data model:

- **Contact Info → Email Address**
  - Used for: App Functionality (account auth, password reset)
  - Linked to user: Yes
  - Used to track: No
- **User Content → Other User Content** (posts, replies, messages, reflections)
  - Used for: App Functionality (the core product)
  - Linked to user: Yes
  - Used to track: No
- **Identifiers → User ID** (Firebase Auth uid)
  - Used for: App Functionality
  - Linked to user: Yes
  - Used to track: No
- **Identifiers → Device ID** (FCM registration token, App Check token)
  - Used for: App Functionality (push notifications, attestation)
  - Linked to user: Yes (FCM token sits in users/{uid}/private/data)
  - Used to track: No
- **Diagnostics → Crash Data** (Crashlytics)
  - Used for: App Functionality (crash debugging)
  - Linked to user: **DECISION** — currently we don't call Crashlytics.setUserID, so we send crash reports without a uid. Mark NO unless you change that. (RUNBOOK / ToskaTheme.swift confirms.)
  - Used to track: No
- **Diagnostics → Performance Data** (Firebase Performance)
  - Used for: App Functionality
  - Linked to user: No (Performance auto-collects without uid)
  - Used to track: No

### Data not collected

- Health & Fitness
- Financial Info
- Location (we don't request CoreLocation; confirm by grepping `CLLocationManager` — no hits)
- Sensitive Info (we don't ask for race, sexual orientation, etc.)
- Contacts
- Photos / Videos (image picker in compose — **DECISION** — declare if user can attach photos to posts; check ComposeView)
- Audio
- Browsing History
- Search History
- Purchase History (until you add IAP)
- Customer Support (you have a support URL but no in-app ticket flow yet)
- Other Data Types

### Data used to track you across other companies' apps and websites

**None** — toska does not enable IDFA, does not use SDKs that track. Confirm: no AdMob, no Facebook SDK, no AppsFlyer, no Adjust. Firebase Analytics is in opt-in mode (`Telemetry.isOptedIn`).

If the above is right, you can answer **No** to the App Tracking Transparency disclosure question and skip the AppTrackingTransparency permission prompt entirely.

---

## 9. App Tracking Transparency

**Recommendation:** declare you do NOT track. This means:

- `NSUserTrackingUsageDescription` should NOT be in `Info.plist`
- You don't call `ATTrackingManager.requestTrackingAuthorization`
- Your privacy nutrition labels above all show `Used to track: No`

Confirm by grepping `NSUserTracking` and `ATTrackingManager` in the iOS code — if either appears, you ARE asking for tracking permission and need to declare it. (Usual case: you don't.)

---

## 10. Encryption / Export Compliance

Standard HTTPS / TLS only — no custom crypto. The relevant `Info.plist` entry:

```
ITSAppUsesNonExemptEncryption = NO
```

Or in App Store Connect → Encryption → "Does your app use encryption?" → answer:

> Yes, but my app uses or accesses encryption only in the following ways: a) within the operating system, b) for authentication purposes, or c) using standard encryption algorithms (HTTPS).

If `ITSAppUsesNonExemptEncryption = NO` is in Info.plist (recommended), App Store Connect skips this question entirely.

---

## 11. Sign in with Apple

Toska supports Sign in with Apple. Apple's rule: if you offer Apple AND any other third-party SSO (Google, in our case), you MUST offer Sign in with Apple. We do — confirmed.

No additional ASC field; the binary's entitlement is what Apple checks.

---

## 12. Demo account for App Review

Apple's review team will ask for a working demo account if any login wall blocks core functionality. Toska does — onboarding requires either Apple, Google, or email signup.

**DECISION** — create a dedicated review-only demo account before submission:

- Email: `appreview@toskaapp.com` (or similar — make it obvious)
- Password: a strong one you'll paste below
- Pre-populate it with: 3-5 sample posts, follow ~2 other test accounts, send 1-2 sample DMs (so the reviewer can see DM UI)
- Pin its handle to something like `appreview_demo` so it's recognizable in your moderation tools

Paste credentials into App Store Connect → App Review → Sign-in Information → Demo Account.

Also paste **Notes** for the reviewer (1000 chars max):

```
toska is an anonymous social app for people going through breakups.
the demo account above is pre-populated with sample posts and one DM
thread you can read.

key flows to evaluate:
- onboarding includes a 17+ age gate (Sign in -> "i'm an adult"
  confirmation is required before you can post)
- compose a post: tap the pencil icon, write, tap "post"
- reply to a post: tap any post, tap reply
- DM: tap a user's handle on a post, "send a message"
- block: tap menu on a post -> "block this person"
- report: tap menu on a post -> "report this post"

content moderation: posts mentioning a real name (e.g. "her name is
Sarah") are auto-deleted at create time. you can confirm by trying to
post "her name is Olivia" — it will not appear.

reports are reviewed by a human within 24 hours via an admin
dashboard at https://www.toskaapp.com/admin.html (admin-only).

if anything fails to load, please check that App Check enforcement
is enabled in our Firebase project. push notifications require a
real device — they will not deliver to the simulator.
```

### Legal entity

Paste into App Store Connect → App Information → General Information (and
Apple Developer account → Membership) at submission time:

| Field | Value |
|---|---|
| Legal entity name | SALTE DEVELOPMENT LLC |
| D-U-N-S number | 145757765 |

Use the same legal entity name on the marketing site footer (`docs/*.html`)
and in the in-app Privacy Policy / Terms of Service publisher line so all
three surfaces agree at review time.

---

## 13. Content rights

App Store Connect → App Information → Content Rights → "Does your app contain, show, or access third-party content?":

**DECISION** — answer **No** unless GIPHY counts. GIPHY content IS third-party but it's reposted from a public CDN with attribution per their TOS. Apple's guidance is "select Yes if your app aggregates or curates content from other sources."

If you answer Yes:
- Sub-question: do you have all necessary rights? Yes (GIPHY's TOS covers redistribution via their API, which is how `giphyProxy` accesses it).

If unsure, lean toward Yes and explain in the rights field.

---

## 14. App Store Server Notifications / In-App Purchases

**DECISION** — does Toska have any IAP at launch?

The description above mentions "in-app subscription, optional" — if that's aspirational and not in the v1 binary, edit the description to remove the line, OR leave it but configure the IAP product in App Store Connect → In-App Purchases first (binary must contain the StoreKit framework, you must configure at least one product, and Apple Review will exercise it).

---

## 15. Pre-submission checklist (run through before clicking Submit)

In order:

- [x] **Email Enumeration Protection** — verified enabled 2026-05-13 on
      both `toska-4ebf4` (prod) and `toskastaging` via the Identity
      Platform admin API (`emailPrivacyConfig.enableImprovedEmailPrivacy:
      true`); wire-level confirmed by sign-in with a non-existing email
      returning `INVALID_LOGIN_CREDENTIALS` (the protection-on response)
      rather than `EMAIL_NOT_FOUND`. Toska's UI text additionally
      collapses 17009/17011 to a neutral message as defense in depth.
      Re-verify if anyone toggles this off in the Firebase console.
- [ ] Run prod scrub `--apply` (or skip — current count is 0)
- [ ] Deploy prod indexes (`firebase deploy --only firestore:indexes --project prod`)
- [ ] Wait for prod indexes to flip Enabled (Firestore Console → Indexes)
- [ ] Deploy prod functions (`firebase deploy --only functions --project prod --force`)
- [ ] Deploy prod rules (`firebase deploy --only firestore:rules --project prod`)
- [ ] Bump `CURRENT_PROJECT_VERSION` in Xcode (build number)
- [ ] Archive in Xcode (Product → Archive) → Distribute → App Store Connect → Upload
- [ ] In App Store Connect → wait for processing → assign build to the version
- [ ] Fill out everything above
- [ ] Confirm screenshots are uploaded (you still owe these — 6.5"/6.7" iPhone required)
- [ ] Tap Submit for Review
- [ ] Walk the manual-QA list on a real device while it's in review

Apple review: 1-3 days typical; longer for first submissions of UGC apps.

---

## Things this document does NOT cover

- **Screenshots.** You owe these; I cannot generate them. App Store requires:
  - 6.5" or 6.7" iPhone (one of those two; the other is auto-derived) — minimum 3, max 10
  - 12.9" iPad Pro (only if you support iPad — confirm in deployment target)
  - Captions: short, scroll-stopping, not feature-list — use the post body of your best test posts
- **App icon.** Should already be in `Assets.xcassets`. Confirm at the right resolutions (1024x1024 for App Store, plus all the sizes for the device).
- **Marketing site updates.** If you change the in-app description, update `https://www.toskaapp.com` to match.
- **Press kit / launch announcement.** Out of scope.

---

## Open decisions (consolidated, in case you skim)

1. Secondary category — Lifestyle or Health & Fitness?
2. Subtitle final pick (recommendation: "Anonymous breakup talk")
3. In-app subscription line in description — keep, edit, or remove?
4. Keywords — keep "therapy" or swap for "loneliness"?
5. Photos in posts — does ComposeView allow image attachment? Decides whether to declare `Photos` in privacy nutrition labels.
6. Crashlytics user ID — currently NOT set; keep that way and answer "No" on linked-to-user for Crash Data.
7. Content Rights — does GIPHY constitute third-party content? Probably yes but borderline.
8. IAP at launch — yes or no? Affects description copy.
9. Demo account — create now and paste credentials at submission time.
