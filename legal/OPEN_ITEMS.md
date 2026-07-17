# Open Items — Owner Decisions & Lawyer Review (2026-07-17)

## In-app wiring status (§3 of the audit brief) — mostly already built

Verified present in code, nothing to implement:
- ✅ ToS + Privacy links on the splash screen **before** account creation (SplashView:163-177) and always in Settings.
- ✅ Acceptance recorded **server-side with version + timestamp**: `acceptedPolicyVersion` / `acceptedPolicyAt` on the user doc, written at signup (CreateAccountView) and at gate acceptance (OnboardingView); clients cannot forge the adult fields (rules deny; `confirmedAdult`/`confirmedAdultAt` are written only by the `confirmAdult` Cloud Function).
- ✅ **Version bump → forced re-acceptance**: `currentPolicyVersion` (ToskaTheme.swift:1010, currently 1) vs. stored version is checked on every launch (ContentView:409-412); a blocking, non-dismissable cover shows until accept; decline = sign-out with account preserved. **To ship new terms: bump `currentPolicyVersion` to 2 and update PolicyAcceptanceView's text/link.**
- ✅ 17+ attestation recorded alongside acceptance, un-skippable (gates are non-dismissable covers; fast-tap race closed; re-shown if the server write didn't land).
- ✅ ASC metadata privacy-policy URL set (verified 2026-07-16).

Gaps needing changes (awaiting your approval):
1. **Share pages (`/p/{id}`) have no privacy/terms links** — add a one-line footer in `functions/sharePage.js` linking both. Small, worth doing for the public-facing surface.
2. **Claims table #3**: one-line copy change in OnboardingView:652 ("nobody knows who you are here" → "no one on toska knows who you are").
3. **Regenerate `docs/terms.html` + `docs/privacy.html` from the v1.0 markdown** (removes stale "messages" refs, fixes Giphy description, narrows the license, corrects backup window) — after your/attorney review of the drafts.
4. On the same release: **bump `currentPolicyVersion` to 2** so existing users re-accept the corrected terms.

## [OWNER DECISION]

1. **Age floor: 17+ or 18+?** Everything (gate copy, attestation, Terms, Apple rating) is consistently 17+ today; your brief said 18+. Moving to 18+ = 3 copy changes + Terms §2 + no App Store rating change needed (17+ is the highest tier). Stakes: consistency; there is no legal magic at 18 vs 17 for most of this [confirm with counsel].
2. **US-focused distribution?** (Privacy §8 scoping.) Territory list at launch decides how much GDPR formality matters in practice. Current draft honors GDPR/CCPA rights mechanically for everyone — the cheap, safe posture.
3. **Published contact email**: drafts use salte@saltedevelopments.com (matches live pages). Confirm this is monitored, or set up privacy@ / legal@ aliases.
4. **DMCA agent registration** ($6, copyright.gov): text-only UGC makes copyright claims unlikely but possible (poems, lyrics). Registering preserves the DMCA safe harbor; skipping is a real (small) exposure. Recommend: register.
5. **Formal GDPR posture vs. best-effort**: drafts commit to honoring rights via existing in-app tools + 30-day email response. Formal posture (EU representative, DPA) only matters if you market into the EU.

## [LAWYER REVIEW] — brief these with the drafts

1. **Governing law + venue** (Terms §14 placeholder — Texas assumed from LLC formation; confirm).
2. **Arbitration clause / class-action waiver**: none included in v1.0. For a UGC app whose failure mode is "user harmed by another user's content," this is the single highest-leverage question for a solo operator.
3. **Liability cap** (Terms §13, $100): enforceability and whether the mental-health-adjacent context needs additional disclaimer language.
4. **Minors**: enforceability of terms accepted by 17-year-olds in the chosen state; any state social-media-age statutes (TX HB18-style laws) that could apply to a 17+ confessional app.
5. **GDPR/CCPA scoping language** (Privacy §8): representative requirement, transfer-mechanism reference for Google Cloud, CCPA "covered business" framing.
6. **Crisis-service disclaimer** (Terms §9): adequacy given the app deliberately surfaces mental-health resources — the good-Samaritan line for a non-provider.
7. **Law-enforcement policy** (Privacy §9): confirm the "notify when permitted + imminent-harm exception" stance.
8. **Backup-retention statements** (Terms §12 / Privacy §6): confirm stating exact windows is preferable to "up to 90 days" vagueness (drafts say yes).

## Suggested sequencing

Attorney review of `/legal` drafts → apply their edits → regenerate web pages + in-app policy text from the final versions → bump `currentPolicyVersion` to 2 → ship with the next app update (existing users re-accept in place; the mechanism is already live).
