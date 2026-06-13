#!/usr/bin/env bash
# Toska pre-launch green/red signal — runs every automated gate in one shot.
#
#   bash scripts/prelaunch-check.sh
#
# Runs all stages even if earlier ones fail, then prints a summary. Exit 0 only
# if everything passed. Requires: Node, a macOS Swift toolchain (for parity +
# the iOS build), Java/openjdk (for the emulator-backed rules suite). The rules
# suite needs the Firebase emulator; if Java/emulator isn't set up it will be
# reported as FAIL with a hint — that's expected on a bare machine.
#
# NOTE: SourceKit "No such module" warnings are FALSE POSITIVES. Only the
# "BUILD SUCCEEDED/FAILED" line and the test pass-counts matter.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

declare -a NAMES RESULTS
record() { NAMES+=("$1"); RESULTS+=("$2"); }
run() { # run "<label>" "<cmd>" "<success-grep>"
  local label="$1" cmd="$2" ok="$3"
  echo ""; echo "════════ $label ════════"
  local out; out="$(bash -c "$cmd" 2>&1)"; echo "$out" | tail -8
  if echo "$out" | grep -qE "$ok"; then record "$label" "PASS"; else record "$label" "FAIL"; fi
}

# 1. Moderation detector unit tests (server) — expect ~154 passing
run "moderation (154)" \
  "cd firestore-tests && npm run --silent test:moderation" \
  "[1-9][0-9]+ passing"

# 2. Client↔server detector PARITY — expect 31/31
run "detector parity (31)" \
  "cd firestore-tests && npm run --silent test:parity" \
  "parity: [0-9]+/[0-9]+ cases"

# 3. firestore.rules + hostile-user (emulator) — expect ~191 passing
run "rules + hostile-user (191)" \
  "cd firestore-tests && npm run --silent test:rules" \
  "[1-9][0-9]+ passing"

# 4. iOS compile — expect BUILD SUCCEEDED (ignore SourceKit noise)
run "iOS build" \
  "xcodebuild -project toska.xcodeproj -scheme toska -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO" \
  "BUILD SUCCEEDED"

echo ""; echo "════════════════ SUMMARY ════════════════"
fail=0
for i in "${!NAMES[@]}"; do
  if [ "${RESULTS[$i]}" = "PASS" ]; then echo "  ✅ ${NAMES[$i]}"; else echo "  ❌ ${NAMES[$i]}"; fail=1; fi
done
echo "═════════════════════════════════════════"
if [ "$fail" = "0" ]; then
  echo "ALL GREEN — automated gates pass. (Still owner-only: crisis FCM token,"
  echo "ASC privacy labels, prod demo account, real-device sign-in — see APP_REVIEW_NOTES.md.)"
else
  echo "RED — at least one gate failed. A FAIL on 'rules' usually means the Firebase"
  echo "emulator / Java isn't set up locally, not that rules are broken — check the output above."
fi
exit "$fail"
