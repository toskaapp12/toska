# Heartbeat (watchdog stopped-running) alert — 2 steps

Log-match alerts can't express ABSENCE, so this needs a log-based metric + a
metric-absence policy.

## 1. log-based counter metric
gcloud logging metrics create crisis_watchdog_heartbeat \
  --project toska-4ebf4 \
  --description="Crisis delivery watchdog ran" \
  --log-filter='resource.labels.service_name="crisisdeliverywatchdog" AND jsonPayload.tag="crisis_watchdog_heartbeat"'

## 2. absence policy (policy-heartbeat.json) — alerts if no heartbeat for 20 min
(condition: conditionAbsent on metric logging.googleapis.com/user/crisis_watchdog_heartbeat, duration 1200s)

## Watchdog ERRORING is already covered
The existing "Toska — function error (all other functions)" policy matches any
function's errors (filter excludes only validatepost/onuserdocdeleted/
sendpushnotification + "will retry"), so crisisDeliveryWatchdog exceptions alert
via that policy. This heartbeat covers the OTHER failure mode: it silently stops.
