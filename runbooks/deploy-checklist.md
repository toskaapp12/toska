# Deploy checklist

Quick post-deploy verification. Keep it short; these are the checks that have
actually caught real incidents.

## After ANY `firebase deploy --only functions` (staging or prod)

1. **Watchdog heartbeat within 10 minutes.** Confirm the crisis watchdog is
   still emitting a fresh heartbeat with `scanErrors:0` after the deploy — a
   functions deploy rotates the Cloud Run revision, and a crash or a broken
   schedule would leave crisis-delivery monitoring blind. Run (swap project):
   ```
   gcloud logging read 'resource.labels.service_name="crisisdeliverywatchdog" AND jsonPayload.tag="crisis_watchdog_heartbeat"' \
     --project <PROJECT> --freshness=12m --limit=2 \
     --format="value(timestamp,jsonPayload.scanErrors,resource.labels.revision_name)"
   ```
   Expect a timestamp from the last few minutes, `scanErrors` = 0, and the NEW
   revision name. If stale/absent → the watchdog didn't come back up; investigate
   the scheduler job + function logs immediately (crisis delivery is unmonitored).

   Note: the "crisis watchdog STALLED" absence policy aggregates across revisions
   (`crossSeriesReducer: REDUCE_SUM`) as of 2026-10-25, so a normal revision
   rotation no longer false-alarms it. A real alert after a deploy means the
   function genuinely stopped.

2. **No new function errors** in the first few minutes:
   ```
   gcloud logging read 'severity>=ERROR AND resource.type="cloud_run_revision"' \
     --project <PROJECT> --freshness=10m --limit=10
   ```

## After `firebase deploy --only hosting`
- Load the signed-in web feed and check the console (a latent JS error can break
  the whole feed — see the 09-21 TDZ incident). JS caches ~1h; hard-refresh.

## After `firebase deploy --only firestore:rules`
- Record which commit/tag is live (prod rules provenance in SESSION_HANDOFF).
- Confirm the main feed still loads for a normal user; check Cloud Logging for
  permission errors.

## Before ANY `firebase deploy --only firestore:indexes` to prod
- Run the **staging↔prod index drift check** so staging stays a valid proxy:
  ```
  cd firestore-tests && node index-drift-check.mjs
  ```
  Exit 0 = in sync. If it lists indexes present in one project but not the other,
  deploy indexes to the lagging project. (CI runs the staging **smoke-probe**
  automatically; the drift check skips in CI until a prod read-only WIF SA is
  added — this local run is the stopgap.)
- A new index-dependent query also needs a row in
  `firestore-tests/index-smoke-probe.mjs` (the manifest), or CI won't guard it.
