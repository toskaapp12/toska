# Incident: credentials committed to the repository (2026-07-22)

Location note: `incidents/` at repo root, not `docs/` — `docs/` is the
published GitHub Pages site. The repo is public, so this document is public
by design (transparent post-mortem); it contains no secret values.

## What happened
Account passwords (three accounts: the App Review demo account and two
staging test accounts) existed in plain text inside internal working
documents (markdown planning/handoff files) that were committed to the
repository. GitGuardian's public-repo monitoring alerted on 2026-07-22.

## Exposure
- Leaked: 3 account passwords (App Review demo + staging test A/B). No API
  keys, no signing keys, no service-account credentials, no user data.
- Exposure window: committed at an earlier date, detected 2026-07-22.
  _Exact first-commit date of each credential: not reconstructed (history
  was subsequently rewritten; fill in only if the pre-scrub mirror is ever
  needed)._
- Evidence of misuse: none observed. The accounts are test/demo accounts
  with no privileged access. _Formal Cloud Audit Log review for the window:
  not performed — accepted, given same-day rotation + token revocation._

## Response (same day, 2026-07-22)
1. All three passwords rotated; refresh tokens revoked for all three
   accounts (sessions killed).
2. The App Store Connect demo-account password updated via the ASC API so
   App Review always has the current credential.
3. 39 internal documents untracked from the repository; a root `/*.md`
   gitignore quarantine added so working notes can't be committed again.
4. Git history rewritten (`git filter-repo`, two passes) and force-pushed:
   the credential-bearing blobs are no longer reachable from any ref.
5. Current credentials moved to a local gitignored file outside version
   control.

## Residual risk
- GitHub may retain unreachable ("dangling") pre-rewrite commits accessible
  by SHA until a support-side garbage collection. A support purge request
  was identified as the closing step. _Status: unconfirmed — owner to
  verify whether the ticket was filed/completed; if not, file via GitHub
  Support ("remove cached views / run gc for repository")._
- Anyone who cloned the repository before 2026-07-22 retains the old
  history; the rotated passwords make this moot.

## Prevention now in place
- `gitleaks` full-history scan on every push (CI) + GitHub secret scanning
  with push protection enabled.
- Root-markdown gitignore quarantine (`/*.md`) + explicit credential-file
  ignores; `.env.*` and key-material patterns added 2026-10 (GIT-03).
- Runtime secrets live exclusively in Secret Manager / deploy-time params.
- Public-repo decision (2026-10-23) made with a full tracked-file PII scrub
  (fix(ACC-06)) and commit identity moved to a noreply address.
