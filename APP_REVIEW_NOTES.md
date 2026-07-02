# Toska — App Store Review Notes

> Paste the **"Review Notes"** section below into App Store Connect →
> your version → **App Review Information → Notes**. Fill the two
> `<<FILL IN>>` fields first (prod demo account + support email).

---

## REVIEW NOTES (paste this block)

**What Toska is**
Toska is an anonymous peer-support space for people going through breakups
and heartache — think short written reflections people are afraid to say out
loud, shared without real names, profile photos, or follower counts. There is
no DMs/chat, no dating/matching, and no public metrics that turn support into
a popularity contest. The product is intentionally low-stakes and anonymous.

**Demo account (sign-in required to see content)**
- Email: `appreview@toskaapp.com`
- Password: (NOT in this repo — the repo is public and serves GitHub Pages.
  The old committed password is burned and must be rotated; keep the live
  one only in App Store Connect's review-notes field and a password manager.)
- This account is pre-seeded with posts so the feed, profile, reactions,
  reporting, and blocking flows are all immediately exercisable.
- Sign in with Apple is also offered on the first screen if you prefer.

**Age rating: 17+**
Account creation includes an age gate; users must confirm they are adults
before any content is shown or created (server-enforced via a Cloud Function,
not just a client checkbox). The app discusses adult emotional topics
(relationships, heartbreak, and — handled carefully — mental-health distress),
hence the 17+ rating.

**User-generated content & safety (Guideline 1.2)**
All four UGC requirements are implemented and reachable in-app:
1. **Content filtering** — every post/reply passes an automated moderation
   gate (profanity, harassment, threats, and personally-identifying info such
   as full names / handles / phone numbers / addresses) *before* it can become
   visible. Concerning content is held for human review, not auto-published.
2. **Report mechanism** — every post, reply, and profile has a Report action.
   Reports auto-hide the content pending moderator review and feed a
   moderator dashboard.
3. **Block** — users can block any author from a post/profile; blocked users'
   content disappears both directions. Blocked list is managed in
   Settings → Blocked Users.
4. **EULA / terms** — users accept Terms of Service and Privacy Policy at
   signup; both are linked in-app (Settings) and published at
   https://www.toskaapp.com/terms and https://www.toskaapp.com/privacy.
   Our terms include a zero-tolerance policy for objectionable content and
   abusive users; we act on reports within 24 hours.

**Responsible handling of mental-health content**
Because the subject matter is heartbreak, the app includes crisis-aware
support: when a post appears to express self-harm or crisis, the author is
shown a gentle, non-judgmental check-in with region-appropriate hotline
resources (e.g. 988 in the US). This is supportive, never punitive, and does
not block the user from posting. We do not provide medical advice.

**Account deletion (Guideline 5.1.1(v))**
Full in-app account deletion is available at **Settings → Delete Account**
(requires re-authentication). It permanently removes the account and the
user's content.

**Authentication**
Sign in with Apple, Sign in with Google, and email/password are offered.
Sign in with Apple is presented as a first-class option per Guideline 4.8.

**How to exercise the core flows quickly**
1. Sign in with the demo account above.
2. Feed → open a post → tap a reaction; tap **•••** → **Report** to see the
   report flow; tap a profile → **Block** to see blocking.
3. Compose (＋) → try posting text containing a phone number or full name to
   see the pre-publish moderation gate hold it.
4. Settings → Blocked Users, Privacy Policy, Terms of Service, Delete Account.

**Contact for review questions**
`salinarotess@gmail.com`

---

## INTERNAL CHECKLIST (do NOT paste — for you)

Operational items to finish in App Store Connect / ops before submitting:

- [ ] **Seed `system/crisisAlertRecipients` in PROD** — without it, crisis
      admin-alerts have no destination. (Owner action; needs recipient list.)
- [ ] **Create a PROD demo account**, seed it with a few posts, put creds in
      the notes above. (Release build points at prod Firebase; the staging
      test account will NOT work for the reviewer.)
- [ ] **Privacy "nutrition" labels** in App Store Connect — declare data
      collected (email for auth, user content), linkage, and tracking (none).
      Must match the privacy policy.
- [ ] **Age rating questionnaire** → 17+ (mature/suggestive themes; infrequent
      medical/treatment references handled supportively).
- [ ] **Real-device sign-in smoke test** — confirm Apple + Google + email
      login all succeed on a clean device against the prod build (simulator
      has known App Check quirks; don't trust it for this).
- [ ] **Screenshots** for required device sizes.
- [ ] Optional polish before submit: swap the placeholder blue "G" glyph for
      the official Google "G" asset (low rejection risk, but closes the last
      branding-guideline gap).
