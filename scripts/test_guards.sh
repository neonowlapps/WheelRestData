#!/usr/bin/env bash
#
# Negative tests for guards.sql. Builds deliberately-broken databases and
# asserts the intended guard fires for each. A guard that passes good data but
# misses bad data is worse than no guard, because it manufactures confidence.
#
# Usage: test_guards.sh <known-good.sqlite>
set -uo pipefail
GOOD="${1:?usage: test_guards.sh <known-good.sqlite>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILURES=0

# Stamp a plausible version so user-version is not the guard that fires.
base="$TMP/base.sqlite"; cp "$GOOD" "$base"
sqlite3 "$base" 'PRAGMA user_version = 20260814;'

expect_fail() {                       # expect_fail <name> <guard-substring> <mutation-sql>
  local name="$1" guard="$2" sql="$3" db="$TMP/$1.sqlite"
  cp "$base" "$db"
  sqlite3 "$db" "$sql" 2>/dev/null
  local out; out="$("$DIR/run_guards.sh" "$db" 2>&1)"
  if echo "$out" | grep -q "^  FAIL $guard"; then
    printf '  ok    %-24s caught by %s\n' "$name" "$guard"
  else
    printf '  NOT OK %-23s NOT caught by %s\n' "$name" "$guard"
    FAILURES=$((FAILURES+1))
  fi
}

echo "Negative tests (each database below MUST be rejected):"

# The failure that integrity_check, quick_check and rtreecheck all miss.
expect_fail parity-loss  table-index-parity \
  "DELETE FROM parking WHERE id IN (SELECT id FROM parking LIMIT 500);"

# Latitude and longitude swapped in the index only.
expect_fail rtree-transposed index-agreement \
  "DELETE FROM parking_index;
   INSERT INTO parking_index(id,minLat,maxLat,minLon,maxLon)
   SELECT id, lon, lon, lat, lat FROM parking;"

# A trigger in the payload — the thing that would make it 'code'.
expect_fail trigger-present no-triggers-or-views \
  "CREATE TRIGGER t AFTER INSERT ON parking BEGIN SELECT 1; END;"

expect_fail view-present no-triggers-or-views \
  "CREATE VIEW v AS SELECT * FROM parking;"

# Mass row loss from both tables together — parity still holds, floor catches it.
expect_fail mass-row-loss row-floor \
  "DELETE FROM parking WHERE id > 1000;
   DELETE FROM parking_index WHERE id > 1000;"

# A single row dragged outside the British Isles.
expect_fail out-of-bbox bbox-table \
  "UPDATE parking SET lat = 12.34, lon = 56.78 WHERE id = (SELECT min(id) FROM parking);"

expect_fail unstamped-version user-version "PRAGMA user_version = 0;"

echo ""
echo "Positive control (this one MUST pass):"
if "$DIR/run_guards.sh" "$base" >/dev/null 2>&1; then
  echo "  ok    known-good database accepted"
else
  echo "  NOT OK known-good database was REJECTED"
  FAILURES=$((FAILURES+1))
fi

echo ""
[ "$FAILURES" -eq 0 ] && { echo "[OK] all guard tests passed."; exit 0; }
echo "[FAIL] $FAILURES guard test(s) failed." >&2; exit 1
