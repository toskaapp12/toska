# App Store Connect Privacy Questionnaire — Answer Sheet

**Derived from the code inventory 2026-07-17. Matches `toska/PrivacyInfo.xcprivacy` (re-verified against the binary in the 2026-07-16 pre-launch audit). If the code changes, change the manifest, this sheet, and the ASC answers together.**

## Top-level questions

- **Do you or your third-party partners collect data from this app?** → **Yes**
- **Tracking (data used to track users across apps/websites owned by other companies)?** → **No** for every data type. No ATT prompt is needed and none is implemented — correct, because nothing in the app tracks. `NSPrivacyTracking = false`, tracking domains empty.

## Data types — item by item

| ASC data type | Collected? | Linked to identity? | Used for tracking? | Purposes |
|---|---|---|---|---|
| Contact Info → Email Address | **Yes** | **Yes** (it's the account) | No | App Functionality |
| Identifiers → User ID | **Yes** (Firebase Auth uid) | **Yes** | No | App Functionality |
| User Content → Other User Content | **Yes** (posts, replies, reflections, drafts, reports) | **Yes** (stored under uid) | No | App Functionality |
| Diagnostics → Crash Data | **Yes** (Crashlytics) | **No** (no setUserID; PII-redacted) | No | App Functionality |
| Diagnostics → Performance Data | **Yes** (Firebase Performance) | **No** | No | Analytics |
| Usage Data → Product Interaction | **Yes** (bounded Telemetry events) | **No** (no Analytics.setUserID; no content/uids in params) | No | Analytics |

## Explicit "No" list (don't check these)

Name; phone number; physical address; **precise or coarse location**; contacts; photos or videos; audio; health & fitness; financial info; browsing history; search history (in-app GIF searches are proxied server-side and never logged against identity); sensitive info; purchases; advertising data; device ID (no IDFA/IDFV collection); "Other Usage Data" beyond product interaction.

## Notes that matter for review

1. **Privacy policy URL in ASC metadata** (App Privacy section + per-locale field) must point at the published policy: `https://www.toskaapp.com/privacy`. Already set per the 2026-07-16 metadata audit — keep it in sync when the policy version bumps.
2. **Analytics opt-out:** the Settings toggle gates both custom events and Firebase's automatic collection (`setAnalyticsCollectionEnabled`). The label answers above describe collection when the (default-on) toggle is on — that's the correct way to answer ASC.
3. **Required-reason APIs** declared: UserDefaults (CA92.1), file timestamps (C617.1), system boot time (35F9.1), disk space (E174.1) — the latter two for Firebase SDK internals. Firebase/GoogleSignIn ship their own SDK manifests.
4. **Age rating:** the app is **18+** as of 2026-08-06 (raised from 17+). The age gate, Terms §2, the underage-disclosure detector, and this rating move together — all four were changed in the same round. **Owner action required: set the age rating to 18+ in App Store Connect**, which is a console change this repo cannot make.
