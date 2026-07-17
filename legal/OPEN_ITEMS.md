# Open Items — Status after best-effort finalization (2026-07-17)

No attorney was available, so v1.0 was finalized with best-practice defaults. Decisions made and applied:

| Decision | Call made | Where |
|---|---|---|
| Age floor | **17+** (consistent with gate copy, attestation, Apple rating) | Terms §2, in-app policy §1 |
| Governing law | **Texas** (SALTE DEVELOPMENT LLC formation state) | Terms §14, in-app policy §10 |
| Arbitration / class waiver | **None** — informal-resolution-first + small-claims instead; a botched template clause is worse than none. Adding one later = material change requiring re-acceptance | Terms §14 |
| Liability cap | Greater of $100 or amounts paid (12 mo) + user indemnity for violating content | Terms §13, in-app §10 |
| GDPR/CCPA posture | Rights honored for everyone via existing in-app tools + 30-day email channel; US-processing disclosure added | Privacy §8 |
| AI training | Explicit promise: content never used to train AI, ours or anyone's | Terms §7, Privacy §3, in-app §6 |
| Contact | salte@saltedevelopments.com everywhere | all docs |

## Applied in code/site this round

- ✅ Onboarding copy fix ("no one **on toska** knows who you are") — claims table #3 closed.
- ✅ Privacy/terms footer links on public `/p/` share pages (sharePage.js).
- ✅ `docs/terms.html` + `docs/privacy.html` regenerated from the v1.0 markdown (stale "messages" claims gone, Giphy proxy accuracy, narrowed license, ~60-day backup window) — claims #12/#15 closed.
- ✅ In-app policy body (`toskaPolicyBody`) aligned: narrowed license + consent-gated sharing, expiring-post honesty, Texas, $100-floor cap.
- ✅ `currentPolicyVersion` bumped **1 → 2** — every existing user re-accepts on their next launch of a build carrying this change (v1.2+). Older builds (1.1 in review) are unaffected.

## Owner checklist (nobody else can do these)

1. ~~Register a DMCA agent~~ — **DONE 2026-07-17**: registration **DMCA-1075752**, pay.gov tracking 2848SPCS, agent Tess Salinaro / salte@saltedevelopments.com, alternate names toska / toska app / toskaapp.com / app.toskaapp.com / saltedevelopments.com. **Renewal due July 2029** (3-year validity — calendar it). Terms §18 now carries the notice-and-takedown clause.
2. **Confirm salte@saltedevelopments.com is monitored** — the docs promise 30-day responses to privacy requests and it's the legal-notice address.
3. When 1.1 clears Apple review and you cut v1.2: the policy re-acceptance will fire for all existing testers once — expected, one-time.

## When you eventually get an attorney (30-minute brief)

Priority order: (1) whether to add arbitration + class waiver (the highest-leverage protection for a solo UGC operator; deliberately omitted rather than botched); (2) Texas venue + minors' (17-year-olds') capacity to accept these terms, and any state social-media age statutes; (3) liability cap enforceability given the mental-health-adjacent context; (4) GDPR representative/transfer-mechanism formality if EU distribution becomes deliberate; (5) confirm the law-enforcement stance (notify-when-permitted + imminent-harm exception). The documents were drafted to be accurate to the code first — have them check law, not facts.
