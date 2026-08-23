#!/usr/bin/env bash
#
# Compares a freshly built database against the last published one and refuses
# implausible movement. This is what catches an extract that silently loses a
# region while remaining a perfectly valid SQLite file.
#
# Thresholds assume MONTHLY publishing. Measured drift is 0.43% per 12 days,
# so a month is ~1.1% and 4% leaves ~3.6x headroom. If the cadence ever moves
# to fortnightly, drop MAX_CHURN_PCT to 2 — at monthly a 2% ceiling would trip
# on ordinary months.
#
# Usage: churn_guard.sh <new.sqlite> [state.json]
# Env:   FORCE=true  bypasses the ceiling (still reports), for genuine large changes
set -euo pipefail

DB="${1:?usage: churn_guard.sh <new.sqlite> [state.json]}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${2:-$REPO_ROOT/dataset-state.json}"
REGIONS="$REPO_ROOT/regions.tsv"
FORCE="${FORCE:-false}"

MAX_CHURN_PCT=4          # total row-count movement, either direction
MIN_REGION_PCT=50        # a region may not fall below this share of its baseline

fail=0
note() { printf '  %s\n' "$*"; }

NEW_ROWS="$(sqlite3 "$DB" 'SELECT count(*) FROM parking;')"

# ---------------------------------------------------------------- first run
if [ ! -f "$STATE" ] || [ "$(jq -r '.rows // 0' "$STATE")" = "0" ]; then
  note "No previous state — seeding baselines from this build ($NEW_ROWS rows)."
  note "The churn ceiling starts applying from the next run."
else
  PREV_ROWS="$(jq -r '.rows' "$STATE")"
  DELTA=$(( NEW_ROWS - PREV_ROWS ))
  PCT="$(awk -v d="$DELTA" -v p="$PREV_ROWS" 'BEGIN{printf "%.2f", (d<0?-d:d)*100/p}')"
  printf '  total: %d → %d (%+d, %s%%)\n' "$PREV_ROWS" "$NEW_ROWS" "$DELTA" "$PCT"

  if awk -v pct="$PCT" -v max="$MAX_CHURN_PCT" 'BEGIN{exit !(pct>max)}'; then
    if [ "$FORCE" = "true" ]; then
      note "CHURN ${PCT}% exceeds ${MAX_CHURN_PCT}% — overridden by FORCE."
    else
      note "FAIL churn: ${PCT}% movement exceeds the ${MAX_CHURN_PCT}% ceiling."
      note "     Either an extract is damaged, or OSM genuinely changed a lot."
      note "     Re-run with FORCE=true once you have confirmed which."
      fail=1
    fi
  fi

  # ------------------------------------------------------------- per region
  while IFS=$'\t' read -r name minLat maxLat minLon maxLon; do
    case "$name" in ''|\#*) continue ;; esac
    prev="$(jq -r --arg n "$name" '.regions[$n] // 0' "$STATE")"
    [ "$prev" -gt 0 ] || { note "region $name: no baseline, skipping"; continue; }
    cur="$(sqlite3 "$DB" "SELECT count(*) FROM parking
                          WHERE lat BETWEEN $minLat AND $maxLat
                            AND lon BETWEEN $minLon AND $maxLon;")"
    share="$(awk -v c="$cur" -v p="$prev" 'BEGIN{printf "%.1f", c*100/p}')"
    if awk -v s="$share" -v m="$MIN_REGION_PCT" 'BEGIN{exit !(s<m)}'; then
      note "FAIL region $name: $cur rows is ${share}% of baseline $prev (floor ${MIN_REGION_PCT}%)"
      fail=1
    else
      printf '  region %-20s %6d → %6d (%s%% of baseline)\n' "$name" "$prev" "$cur" "$share"
    fi
  done < "$REGIONS"
fi

# ------------------------------------------------------------- emit new state
# Written regardless of pass/fail; the caller only commits it after a successful
# publish, so a rejected build can never move the baseline.
{
  printf '{\n  "version": %s,\n  "rows": %s,\n  "regions": {\n' \
    "$(sqlite3 "$DB" 'SELECT user_version FROM pragma_user_version();')" "$NEW_ROWS"
  first=1
  while IFS=$'\t' read -r name minLat maxLat minLon maxLon; do
    case "$name" in ''|\#*) continue ;; esac
    cur="$(sqlite3 "$DB" "SELECT count(*) FROM parking
                          WHERE lat BETWEEN $minLat AND $maxLat
                            AND lon BETWEEN $minLon AND $maxLon;")"
    [ $first -eq 1 ] || printf ',\n'; first=0
    printf '    "%s": %s' "$name" "$cur"
  done < "$REGIONS"
  printf '\n  },\n  "lastRunAt": "%s"\n}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$REPO_ROOT/build/dataset-state.next.json"

[ "$fail" -eq 0 ] || { echo ""; echo "[FAIL] churn guard rejected this build." >&2; exit 1; }
echo ""
echo "[OK] churn within limits."
