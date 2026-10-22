# Data recovery runbook (BAK-03 / BAK-05)

Location note: lives in `runbooks/` (repo root), NOT `docs/` — `docs/` is the
published GitHub Pages site. Nothing here is secret, but ops procedure doesn't
belong on the marketing domain.

## 1. Firestore restore (verified by drill)

Backups are **weekly** (Sundays, 56-day retention) in `toska-4ebf4`; PITR gives
7-day/1-minute granularity on top. **Cross-project restores are NOT supported**
(verified 2026-10-23): a prod backup restores only inside `toska-4ebf4`, always
into a NEW named database — never `(default)`.

```
gcloud firestore backups list --project toska-4ebf4
gcloud firestore databases restore \
  --source-backup="<backup name>" \
  --destination-database="restore-drill-$(date +%Y%m%d)" \
  --project=toska-4ebf4
# poll: gcloud firestore operations list --database="restore-drill-…" --project toska-4ebf4
```

Immediately after restore:
1. The new database inherits delete protection from the source (observed in
   drill) — leave it until teardown.
2. It has NO rules release → clients are denied by default, but bind an
   explicit deny-all release anyway (firebaserules API, release name
   `projects/toska-4ebf4/releases/cloud.firestore/<dbId>`) — it holds real user
   data.
3. Verify via Admin SDK only (`getFirestore(app, "<dbId>")`): collection
   counts vs `(default)`, spot-open one document.

Teardown: delete the deny-all release, then
`gcloud firestore databases update --database="<dbId>" --no-delete-protection --project toska-4ebf4`
then `gcloud firestore databases delete --database="<dbId>" --project toska-4ebf4 --quiet`.

### Post-restore obligation: re-apply deletions newer than the backup

A restored database RESURRECTS every account and post deleted after the
backup's snapshot time. Before promoting restored data anywhere, re-run the
deletion cascade for each such account (delete its `users/{uid}` doc with the
Admin SDK — `onUserDocDeleted` does the rest; verify its Auth record is also
absent).

How to find post-backup deletions, in order of reliability:
- **Admin-initiated deletions** — `adminAuditLog` (durable, admin-only):
  `account_deleted`-type entries from `adminDeleteAccount`, timestamped.
  Always traceable.
- **Self-deletions of accounts that had ≥1 post** — `adminAuditLog` again:
  the cascade's post deletions each write a permanent per-post entry carrying
  the author uid + handle (`auditPostDeletion`; disclosed in privacy policy
  §7). Query entries with timestamps after the backup snapshot.
- **Self-deletions of ZERO-post accounts** — ⚠ **TRACEABILITY GAP**: the
  `pendingDeletions` marker is itself deleted at cascade end, no audit entry
  is written, and the only trace is Cloud Function logs (uid lines in
  `onPendingDeletionCreated` / `monitorPendingDeletions`) with **30-day
  retention** — shorter than the 56-day backup window. A zero-post account
  self-deleted 31–56 days before the backup-restore moment cannot be
  re-identified from our records. Practical exposure is small (an account
  with no posts has almost nothing to resurrect — a user doc shell, likes,
  follows) but it is real residue. Remediation options (owner decision,
  Phase 2+): (a) cascade writes a minimal uid-only erasure tombstone to an
  admin-only collection (GDPR Art. 17 "record of erasure" — standard
  practice), (b) raise function-log retention to ≥56 days, or (c) shorten
  backup retention to ≤30 days. **Owner note (2026-10-23, decision deferred):
  option (a) is the closest fit as a MINIMAL record — an admin-only
  `erasureTombstones/{uid}` doc holding ONLY `{deletedAt}` (uid is the doc id),
  written by the cascade as its final step, with a Firestore TTL policy on
  `deletedAt` + ~60 days so tombstones self-delete once no backup can
  resurrect the account. Rules: `allow read, write: if false` (Admin SDK
  only). No handle, no email, no content — just enough to re-run a cascade
  after a restore.**
- Cross-check: Firebase Auth has no queryable deleted-user tombstones; don't
  rely on it.

### Drill log
| Date | Backup | Duration | Outcome |
|---|---|---|---|
| 2026-07-17 | (pre-launch prep) | — | passed (per launch-prep records) |
| 2026-10-23 | 2026-10-18 weekly | **9m16s restore (556s)**; verify + teardown ~10m total | PASSED — counts matched modulo expected post-backup deletion (orphan account); client lockout proven by probe |

## 2. Hosting rollback (app.toskaapp.com)
Firebase console → Hosting → release history → "Rollback" on a previous
release (instant, no build). CLI alternative: `firebase hosting:clone`.
www.toskaapp.com (GitHub Pages): `git revert` the offending commit and push —
Pages redeploys in ~1 minute. Never force-push (branch protection blocks it).

## 3. Functions rollback
No one-command rollback exists. Procedure: `git checkout <last-good-tag-or-sha> -- functions/`
(or `git revert` the offending commit), then deploy with explicit project:
`npx firebase-tools deploy --only functions --project <target>`. Partial
rollback of a single function: `--only functions:<name>`. Mitigations while
rolling back: the `config/clientPolicy` kill switches
(`scripts/set_client_policy.js`) can disable compose/search/share client-side
immediately.

## 4. Firestore rules rollback
`firebase deploy --only firestore:rules` from the last-good commit, or
firebaserules API: re-release a previous ruleset id (list with
`GET /v1/projects/<p>/rulesets`). Staging first, always.
