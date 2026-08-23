#!/usr/bin/env bash
# Runs guards.sql against $1 and fails if any check reports FAIL.
set -euo pipefail
DB="${1:?usage: run_guards.sh <database>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$DB" ] || { echo "[FAIL] no such database: $DB" >&2; exit 1; }

OUT="$(sqlite3 "$DB" < "$SCRIPT_DIR/guards.sql")"
echo "$OUT" | sed 's/^/  /'

if echo "$OUT" | grep -q '^FAIL'; then
  echo ""
  echo "[FAIL] $(echo "$OUT" | grep -c '^FAIL') guard(s) failed. Refusing to publish." >&2
  exit 1
fi
echo ""
echo "[OK] all $(echo "$OUT" | grep -c '^PASS') guards passed."
