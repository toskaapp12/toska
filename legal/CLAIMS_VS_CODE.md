# Claims vs. Code — Consistency Sweep (2026-07-17)

Every user-facing claim about privacy, anonymity, expiration, deletion, or safety, checked against actual behavior. Verdicts: **TRUE** (code makes it so), **TRUE\*** (true with a nuance the legal docs now state), **MISLEADING** (needs copy or code change).

| # | Where | Claim | Verdict | Basis / required action |
|---|---|---|---|---|
| 1 | Compose hints + banners | "your post quietly disappears in 1 hour" / "disappears tonight at midnight" | **TRUE\*** | Hidden from every surface instantly at expiry; hard-deleted from live DB ≤1h later (hourly `cleanupExpiredPosts` + TTL backstop); ages out of backups ≤60d. "Quietly disappears" is honest; Terms §8 now states the mechanics. No superlative ("forever") used anywhere — good. |
| 2 | Onboarding: "youre anonymous here … no names. no faces." | Pseudonymity claim | **TRUE\*** | True toward other users; the operator can technically link uid↔email. Privacy Policy §2 now states this plainly. |
| 3 | Onboarding: ~~"nobody knows who you are here"~~ | Absolute anonymity superlative | **FIXED 2026-07-17** | Copy now reads *"no one on toska knows who you are."* — scoped to other users, which is true (OnboardingView.swift:652). |
| 4 | Splash: "for the things you couldnt say to your ex" / Settings toggle: share cards "always without your handle" | Share-card anonymity | **TRUE** | ShareCardView never renders the handle (param unused); web share pages verified identity-free; `isShareable` consent enforced live incl. revocation. |
| 5 | Settings: analytics "never includes what you wrote" | Analytics content claim | **TRUE** | Telemetry facade: bounded event vocabulary, no content/handles/uids/search terms; redactPII on Crashlytics; toggle gates Firebase auto-collection too. |
| 6 | Push primer: "no marketing. no daily nudges." | Push scope claim | **TRUE** | Server sends only 6 interaction types, all pref-gated server-side (index.js:1121); no scheduled/marketing pushes exist. |
| 7 | Delete post alert: "this is permanent. it'll be gone for everyone." | Post deletion claim | **TRUE\*** | Client best-effort + server cascades remove the post, replies, likes, reposts of it; share pages 404. Nuance: backup aging (≤60d) + reported-content copies — now stated in Terms/Privacy. |
| 8 | Delete account alert: "everything you said here goes with it." | Account deletion claim | **TRUE\*** | Full cascade + hourly retry + Apple token revocation, emulator-proven (July audits). Same backup/report nuance, stated in Privacy §7. |
| 9 | Compose PII warnings: "toska is anonymous for everyone." | Anonymity-of-others norm | **TRUE** (normative) | Backed by PII detection at compose/edit/reply + server-side holds. |
| 10 | Blocking dialog: "they wont be notified." | Block silence claim | **TRUE** | No notification is generated on block; block list owner-only; mutual filtering server-checked. |
| 11 | Crisis check-in: resources offered, "crisis language always shows resources" (Settings) | Safety claim | **TRUE** | Explicit-tier check-in shows even when gentleCheckIn is off (ComposeView:60); server holds crisis posts + pages admins; region-aware hotlines with international directory fallback. |
| 12 | Web privacy page (April 17, 2026): collects "messages", "deliver messages" | Stale claim | **MISLEADING (stale)** | DMs were removed 2026-05-28; no message data exists or is collected. Fixed in PRIVACY_POLICY.md v1.0 — web page needs regeneration from it. |
| 13 | Web privacy page: Giphy "your search query is sent to Giphy's API" | Understates our protection | **TRUE\*** (outdated in our favor) | Searches now proxy through `giphyProxy` CF — Giphy never sees user identity/IP for searches; device fetches GIF media from Giphy CDN (IP visible, like any image host). v1.0 policy states both halves. |
| 14 | Web terms (June 16, 2026): "Some data may persist in backups for up to 90 days" | Retention ceiling | **TRUE\*** (loose) | Actual worst case ≈ 60 days (weekly backups, 8-week retention). v1.0 docs state ~60; 90 was safe-direction but imprecise. |
| 15 | Web terms §7 license: "display, distribute, and share … for promotional purposes (such as shareable post cards)" | License scope | **MISLEADING (over-broad)** | "Promotional purposes" is wider than what the app does or the intimacy warrants. v1.0 Terms §7 narrows to: in-service display + the two consent-gated mechanisms (share cards, website featuring), nothing else. |
| 16 | In-app age gate: "toska is for 17 and up" vs. audit brief's "18+" | Age floor | **CONSISTENT at 17+ in all code/copy** | Not a code/copy mismatch — a decision mismatch with the owner's stated assumption. See OPEN_ITEMS. |

### 2026-07-27 full-audit corrections

| # | Where | Claim | Verdict | Basis / action taken |
|---|---|---|---|---|
| 17 | Privacy §1 + §7 (privacy.html + PRIVACY_POLICY.md) | Email stored "in your private, owner-only profile area" / deletion removes an "email copy" | **WAS STALE — FIXED 2026-07-27** | The 2026-07-21 email-minimization stopped copying email into Firestore; it lives ONLY in Firebase Auth (app.js signup writes no email; SettingsView treats Auth as sole source; anonymity-probe prod proved 13/13 user docs + 24/24 posts PII-clean, email present only in Auth). Docs reworded to "Firebase Auth only — never copied into our post/profile database"; the deletion cascade now attributes email to "your Firebase Auth account." |
| 18 | Privacy §4 featuring (privacy.html + PRIVACY_POLICY.md) | Website featuring shows "words, tag, and felt-count **only**" | **WAS IMPRECISE — FIXED 2026-07-27** | publicFeed/index.html also render an approximate age ("3h ago") and share pages a month label. Not an identifier, but "only" over-enumerated. Reworded to add "and an approximate age." |

**Summary: no FALSE claims in the shipping app, and all MISLEADING items are now FIXED** — #3 in app copy (ships with v1.2), #12/#15 via the regenerated web pages (live on next push). The remaining TRUE\* nuances are stated plainly in the v1.0 Terms/Privacy documents.
