#!/usr/bin/env bash
#
# check-raw-colors.sh — fail if a raw Color(hex: "...") re-introduces a hex
# that has already been promoted to a named token in ToskaTheme.swift.
#
# These hexes have semantic tokens (Color.toska*). Use the token instead of a
# raw literal so the palette stays centralized and color-preserving.
# The ONE legitimate place each hex may appear as a literal is its own token
# definition in ToskaTheme.swift; that file is excluded from the scan.
#
# Usage:  scripts/check-raw-colors.sh
# Exit:   0 = clean, 1 = raw tokenized hex found (prints file:line)

set -euo pipefail

# Directory containing the Swift sources (relative to repo root).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/toska"

# Tokenized hexes (lowercase). Keep in sync with the token block in ToskaTheme.swift.
HEXES="e4e6ea c45c5c c9a97a 0a0908 c47a8a cccccc 6ba58e c49a6c 999999 8b7ec8 c8c8c8 5a9e8f 7a97b5 14130f dfe1e5"

# Build a single case-insensitive alternation: Color(hex: "#?<hex>")
alt="$(echo "$HEXES" | tr ' ' '|')"
pattern="Color\(hex:[[:space:]]*\"#?(${alt})\"\)"

# Scan all Swift files except ToskaTheme.swift (holds the token definitions).
found="$(
  grep -rniE --include='*.swift' "$pattern" "$SRC_DIR" \
    | grep -v '/ToskaTheme.swift:' \
    || true
)"

if [[ -n "$found" ]]; then
  echo "ERROR: raw Color(hex:) found for a tokenized hex. Use the Color.toska* token instead:" >&2
  echo "$found" >&2
  exit 1
fi

echo "OK: no raw Color(hex:) uses of tokenized hexes."
