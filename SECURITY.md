# toska — Security Overview, Threat Model & Incident Response

_Last reviewed: 2026-09-29. Owner: SALTE DEVELOPMENT LLC._

toska is an anonymous space for heartbreak. The product's core promise is
**anonymity** — a user's public identity (a random handle like
`quiet_moon_882`) must never be linkable to their real identity (email,
device, name). This document is the written form of the threat modeling and
operational security the app is built around.

---

## 1. Assets (what we protect, in priority order)

1. **User anonymity** — the mapping between a public handle and a real
   person (email, uid, device token, IP-adjacent metadata). Highest severity.
2. **User-authored content** — posts, replies, drafts. Drafts especially:
   the rawest, unsent words.
3. **Account integrity** — no one can post/act as another user.
4. **Safety pipeline** — crisis detection, moderation, blocking must work.
5. **Availability** — the service stays up and affordable.

## 2. Trust boundaries

- **The client is untrusted.** iOS app and web app both. All security is
  enforced server-side (Firestore Security Rules + Cloud Functions). A
  tampered client that talks directly to the backend gets no more than a
  normal user.
- **Firestore Security Rules** are the primary authorization boundary,
  covered by 375+ automated tests including a hostile-user suite and a
  de-anonymization red team.
- **Cloud Functions (Admin SDK)** are the only trusted writers of
  server-owned data (counters, moderation status, search tokens,
  notifications, banned-identity records).
- **Admin surface** (moderation dashboard) is gated at both the rules layer
  and inside every admin callable on `admins/{uid}.role == "admin"`.

## 3. Primary threats & mitigations (STRIDE-ish)

| Threat | Vector | Mitigation |
|---|---|---|
| **De-anonymization** | Read another user's email/token | Private data in owner-only `users/{uid}/private/data`; public user doc carries handle only |
| | Enumerate who liked/followed a post | likes are own-doc-or-admin (2026-09-29 fix); followers/following/liked/saved owner-only |
| | Cross-reference engagement rosters | same as above — no roster is listable |
| | PII inside post text | server-side name/contact detector holds posts for review |
| **Spoofing** | Post as another user | rules pin `authorId == auth.uid`, `authorHandle == users/{uid}.handle` |
| **Tampering** | Inflate counts, self-publish, edit others | counts server-only; `moderationStatus` client-settable only to `pending_validation`; field allowlists (`hasOnly`) on every write |
| **Elevation** | Become admin | `admins/{uid}` write:false; admin callables re-check role |
| **Repudiation / abuse** | Spam, ban evasion | App Check attestation on writes/callables; server-side rate limits; banned-identity HMAC blocks re-signup |
| **Info disclosure** | Read held/deleted content | reads gated on `moderationStatus`; crisis/report/audit queues admin-only |
| **DoS / cost** | Runaway reads/writes | rate limits; bounded queries; billing budget alert (owner-configured) |
| **Client bug shipped** | No remote remedy | kill switch (`config/clientPolicy`: minBuild + per-feature flags) |

## 4. Anonymity-specific invariants (re-proven each release)

- No world-readable document carries email, fcmToken, or real-identity data.
- Email lives only in Firebase Auth + owner-only private doc.
- Share cards never render the handle; share-page endpoints expose only
  text/tag/count, never author identity.
- Notifications carry a handle + type, never identity-linking data.
- `gifUrl` is host-locked to Giphy (no attacker-controlled beacon URLs).
- Logs (Cloud Logging) avoid user content and identity where practical.

## 5. Security testing program

- **SAST**: Semgrep (js + security-audit rulesets) + a custom web audit,
  every push.
- **Authorization**: 375+ Firestore-rules tests incl. hostile-user +
  de-anon red team, every push.
- **Dependency / SCA**: `npm audit` fail-on-high every 6h + Dependabot
  advisories + CycloneDX SBOM per build.
- **Secret scanning**: gitleaks in CI + GitHub native secret scanning.
- **DAST-equivalent**: live web audit (headers, deployed-bundle, /p/ 404)
  every 6h; hostile-client probes against the rules.
- **Internal pentest**: adversarial red-team passes (this doc's owner +
  AI-assisted). **External paid pentest recommended before public launch**
  for novel attack chains, on-device network interception, and independent
  attestation.
- **Peer review**: `/code-review ultra` before major releases.

## 6. Incident response runbook

**Detection sources:** Crashlytics, the 6-hour Security Watch workflow,
abuse-spike + crisis-email alerts, the de-anon/consistency probes, and
inbound reports to `salte@saltedevelopments.com`.

**On a suspected security or privacy incident:**

1. **Contain first, diagnose second.** If a feature is leaking or being
   abused, flip its kill switch immediately:
   `node scripts/set_client_policy.js toska-4ebf4 kill.<feature>=true`
   For a bad client build: `... minBuild=<next>`. For a full pause:
   set a `notice` and kill the write features.
2. **Assess scope.** What data, how many users, is it still ongoing? Use
   the data-consistency + anonymity probes to bound it.
3. **Fix at the enforcement layer** (rules/functions), add a regression
   test that reproduces the issue, deploy staging → verify → prod.
4. **Verify closed** with a hostile probe against the live fix.
5. **Notify** affected users if identity/data was exposed, per the privacy
   policy and applicable law (US state breach-notification timelines;
   GDPR 72h if EU territories are ever enabled).
6. **Write it down** — append a dated entry below and add the permanent
   test so it can never recur.

**Rollback:** Firestore has point-in-time recovery (7-day) + delete
protection; rules/functions/hosting can be redeployed from the last-good
git commit.

## 7. Responsible disclosure

We publish `/.well-known/security.txt`. Researchers: email
`salte@saltedevelopments.com` before public disclosure; we respond in good faith
and credit you if you wish. A de-anonymization finding is our top severity.

## 8. Penetration test log

### 2026-09-29 — internal pentest (AI-assisted red team)

Scope: Firestore authorization, anonymity surfaces, Cloud Functions
callables, public HTTP endpoints, business-logic abuse. Out of scope
(deferred to external paid pass): mobile-binary reverse engineering,
on-device network interception, independent third-party attestation.

**Findings:**
- **HIGH — post/reply like lists enumerable (de-anonymization).** On live
  content, `list posts/{id}/likes` returned every liker's uid. FIXED
  (own-doc-or-admin read rule) + deployed staging/prod + regression test
  (deanon-redteam) + 3 stale tests that had asserted the vulnerable
  behavior flipped. _Closed same day._
- No other findings.

**Attacked and verified clean:**
- Callables: `giphyProxy` (auth + App Check + rate limit), `reconcileMyCounts`
  (operates on token-derived uid only — no IDOR), `adminDeleteAccount`
  (server-side admin-role gate), `confirmAdult` (App Check). No
  `exportMyData` callable exists; data export is client-side and reads only
  the caller's own rules-permitted data.
- Public HTTP: `sharePage` (HTML-escaped, no reflected XSS; refuses
  non-live / non-shareable / letter / whisper / midnight → 404),
  `publicFeed` (anonymized projection `{text, tag, felt, ageHours}` — no
  authorId/handle), `postsSitemap`, `shareCardImage` (image only).
- Business logic: notification forging blocked (`fromUserId` pinned to
  caller, deterministic notifId, `isRead` must be false); counts are
  server-only; Most-Felt ranking derives from server counters.
- Anonymity invariants (§4) all hold.

## 9. Incident log

_(none to date — append dated entries here)_
