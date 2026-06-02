#!/usr/bin/env bash
#
# Create Toska's log-based alert policies in Cloud Monitoring from the JSON
# definitions in this directory. Idempotent on the notification channel
# (reuses an existing email channel for the address); creating the same policy
# twice makes two policies, so prune duplicates if you re-run (see README).
#
# Usage:
#   ./setup_alerts.sh <PROJECT_ID> <ALERT_EMAIL>
#   ./setup_alerts.sh toska-4ebf4 salte@saltedevelopments.com
#
# Requires: gcloud authenticated with roles/monitoring.editor and
# roles/monitoring.notificationChannelEditor on the project.

set -euo pipefail

PROJECT_ID="${1:?usage: setup_alerts.sh <PROJECT_ID> <ALERT_EMAIL>}"
ALERT_EMAIL="${2:?usage: setup_alerts.sh <PROJECT_ID> <ALERT_EMAIL>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Project:  $PROJECT_ID"
echo "Email:    $ALERT_EMAIL"

# --- 1. Find or create the email notification channel -----------------------
echo "Resolving email notification channel…"
# Match the email in awk rather than via gcloud's filter parser (which treats
# an unquoted '@' value as a field reference and errors).
CHANNEL="$(gcloud beta monitoring channels list \
  --project="$PROJECT_ID" \
  --format='value(name,type,labels.email_address)' \
  | awk -v e="$ALERT_EMAIL" '$2=="email" && $3==e {print $1; exit}')"

if [[ -z "$CHANNEL" ]]; then
  echo "  no existing channel — creating one"
  CHANNEL="$(gcloud beta monitoring channels create \
    --project="$PROJECT_ID" \
    --display-name="Toska Alerts" \
    --type=email \
    --channel-labels="email_address=$ALERT_EMAIL" \
    --format='value(name)')"
else
  echo "  reusing $CHANNEL"
fi
echo "Channel:  $CHANNEL"

# --- 2. Create each policy with the channel substituted in ------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$HERE"/policy_*.json; do
  name="$(basename "$f")"
  out="$TMP/$name"
  # Substitute the channel placeholder. Use | as the sed delimiter because
  # the channel resource name contains slashes.
  sed "s|__CHANNEL__|$CHANNEL|g" "$f" > "$out"
  echo "Creating policy from ${name} ..."
  gcloud alpha monitoring policies create \
    --project="$PROJECT_ID" \
    --policy-from-file="$out" \
    --format='value(name)'
done

echo "Done. List with:"
echo "  gcloud alpha monitoring policies list --project=$PROJECT_ID --filter='displayName:\"Toska —\"' --format='table(name,displayName)'"
