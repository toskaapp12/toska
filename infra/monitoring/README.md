# Toska — Cloud Monitoring alert policies (as code)

The Cloud Functions in `functions/index.js` emit structured logs that are
**designed to be matched by log-based alert policies** in Cloud Monitoring.
Those policies live in GCP, not in the repo, so a code reviewer can't confirm
they exist. This directory makes them reviewable and reproducible: one JSON
policy per alert, plus a script that creates them.

> The audit flagged these as "unverifiable from the repo." Running
> `setup_alerts.sh` against each project and committing any edits here closes
> that gap — the policies become version-controlled and re-creatable.

## What each policy watches

| File | Fires when | Source in code |
|---|---|---|
| `policy_new_report.json` | a user files a report (24h SLA, Apple 1.2) | `notifyAdminsOfNewReport` → `jsonPayload.tag="new_report_for_review"` |
| `policy_counter_drift.json` | a counter trigger drifts by one | `logCounterDrift` → `jsonPayload.tag="counter_drift"` (severity ERROR) |
| `policy_pending_deletion_stuck.json` | an account deletion is retried/stuck | `monitorPendingDeletions` → `"Retry failed for pending deletion"` |
| `policy_crisis_paging.json` | crisis admin-paging fails or is misconfigured | `onPostCreatedAlertAdmins` → `textPayload =~ "crisis-alert: (failed to alert admins|tripped explicit-crisis but no)"` |
| `policy_critical_fn_errors.json` | a load-bearing function logs an ERROR | severity≥ERROR on `validatePost` / `onUserDocDeleted` / `sendPushNotification` |
| `policy_fn_errors_all_other.json` | any OTHER function logs an ERROR (broad net) | severity≥ERROR on every function except the three above, excluding "will retry" |
| `policy_abuse_spike.json` | per-author or global surge of auto-held content | `abuseSpikeWatch` → `jsonPayload.tag="abuse_spike_author"` / `"abuse_spike_global"` |
| `policy_crisis_email_backup.json` | a crisis post/reply was detected (email backup to the FCM page) | `pageAdminsForCrisis` → `jsonPayload.tag="crisis_needs_review"` |

> The three policies above were first created live via gcloud on 2026-07-28
> (session work) and exported here afterward; the live prod policies and these
> JSONs are in sync as of that date. The prod web uptime check
> ("Uptime failure — toska prod web") is console-managed and intentionally not
> in this directory.

## Deploy

Requires the `gcloud` CLI authenticated against the target project with the
`roles/monitoring.editor` (and `roles/monitoring.notificationChannelEditor`)
roles.

```bash
cd infra/monitoring

# prod
./setup_alerts.sh toska-4ebf4 salte@saltedevelopments.com

# staging (optional)
./setup_alerts.sh toskastaging salte@saltedevelopments.com
```

The script is idempotent on the notification channel (it reuses an existing
email channel for the address if one exists) but **creating a policy twice
makes two policies** — list/prune with:

```bash
gcloud alpha monitoring policies list --project=PROJECT_ID \
  --filter='displayName:"Toska —"' --format='table(name,displayName)'
```

## Notes

- Log-based alert policies fire on the *first* matching log entry within each
  `notificationRateLimit` window (default 5 min here) — they are not metric
  threshold policies, so there's no backfill.
- Filters are intentionally not pinned to `resource.type` so they keep matching
  if functions move between Gen2 runtimes. Tighten with
  `resource.labels.service_name="<fn>"` if cross-project log noise appears.
- If you change a log `tag` or message string in `functions/index.js`, update
  the matching filter here in the same change.
